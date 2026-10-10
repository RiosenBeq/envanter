import Foundation
import XCTest
@testable import EnvanterCore

/// Bellek içi sunucu: `envanter_put` ve okuma sorgusunun anlamı migration'daki SQL ile birebir
/// (supabase/migrations/20261009120000_envanter.sql, docs/SYNC.md §2).
final class FakeServer: @unchecked Sendable {
    struct Doc { var rev: Int64; var body: JSONValue; var deleted: Bool }
    struct Activity { var workspace: String; var user: String; var key: String; var summary: String; var client: String? }

    private let lock = NSLock()
    private var seq: Int64 = 0
    private(set) var docs: [String: [String: Doc]] = [:]
    private var members: [String: [String: String]] = [:]   // şube → kullanıcı → rol
    private var names: [String: String] = [:]
    private(set) var activity: [Activity] = []
    private(set) var putCount = 0
    /// Her `put` işlenmeden önce çağrılır (ör. araya başka bir istemcinin yazmasını sokmak için)
    var beforePut: ((_ key: String) -> Void)?

    func addWorkspace(_ id: String, name: String, owner: String) {
        locked { names[id] = name; members[id, default: [:]][owner] = CloudRole.owner }
    }

    func addMember(_ ws: String, user: String, role: String) {
        locked { members[ws, default: [:]][user] = role }
    }

    func workspaces(of user: String) -> [CloudWorkspace] {
        locked {
            members.compactMap { ws, m in m[user].map { CloudWorkspace(id: ws, name: names[ws] ?? ws, role: $0) } }
                .sorted { $0.name < $1.name }
        }
    }

    func doc(_ ws: String, _ key: String) -> Doc? { locked { docs[ws]?[key] } }

    func pull(user: String, ws: String, since: Int64) -> [RemoteDoc] {
        locked {
            guard members[ws]?[user] != nil else { return [] }   // RLS: üye olmayan hiçbir şey görmez
            return (docs[ws] ?? [:]).filter { $0.value.rev > since }
                .map { RemoteDoc(key: $0.key, body: $0.value.body, rev: $0.value.rev, deleted: $0.value.deleted) }
                .sorted { $0.rev < $1.rev }
        }
    }

    func put(user: String, ws: String, key: String, body: JSONValue, baseRev: Int64, deleted: Bool,
             client: String?, summary: String?, runHook: Bool = true) throws -> PutResult {
        if runHook { beforePut?(key) }
        return try locked {
            putCount += 1
            guard let role = members[ws]?[user] else { throw CloudSyncError.forbidden("Bu şubeye erişiminiz yok.") }
            guard DocKey.isValid(key) else { throw CloudSyncError.invalidRequest("Geçersiz belge anahtarı: \"\(key)\".") }
            if role == CloudRole.staff && !DocKey.isDay(key) {
                throw CloudSyncError.forbidden("Personel (staff) yalnızca gün kayıtlarını (sayım, satış, vardiya, not) değiştirebilir.")
            }
            let stored: JSONValue
            if deleted {
                stored = .object([:])
            } else {
                if body.isNull { throw CloudSyncError.invalidRequest("Belge gövdesi boş olamaz") }
                let wantsArray = [DocKey.items, DocKey.products, DocKey.employees, DocKey.orders].contains(key)
                if wantsArray && body.arrayValue == nil { throw CloudSyncError.invalidRequest("dizi olmalı") }
                if !wantsArray && body.objectValue == nil { throw CloudSyncError.invalidRequest("nesne olmalı") }
                stored = body
            }
            if let cur = docs[ws]?[key] {
                guard cur.rev == baseRev else { return PutResult(ok: false, rev: cur.rev, body: cur.body, deleted: cur.deleted) }
                // Kapatılmış gün (docs/SYNC.md §2): personel sunucudaki güncel hali kilitli olan günü değiştiremez, kilidini
                // açamaz, silemez; aynı gövdeyi yeniden yazmak serbest. Denetim rev karşılaştırmasından sonra (SQL ile aynı).
                if role == CloudRole.staff && DocKey.isDay(key) && !cur.deleted && cur.body["locked"] == .bool(true)
                    && (deleted || stored != cur.body) {
                    throw CloudSyncError.forbidden("Kapatılmış günü yalnızca müdür veya patron değiştirebilir.")
                }
            } else if baseRev != 0 {
                return PutResult(ok: false, rev: 0, body: nil, deleted: false)
            }
            seq += 1
            docs[ws, default: [:]][key] = Doc(rev: seq, body: stored, deleted: deleted)
            let s = (summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            activity.append(Activity(workspace: ws, user: user, key: key, summary: s.isEmpty ? "güncellendi" : s, client: client))
            return PutResult(ok: true, rev: seq, body: stored, deleted: deleted)
        }
    }

    /// Başka bir istemcinin (ör. web paneli) doğrudan yazması
    @discardableResult
    func write(ws: String, user: String, key: String, body: JSONValue?) -> PutResult {
        let base = doc(ws, key)?.rev ?? 0
        return try! put(user: user, ws: ws, key: key, body: body ?? .object([:]), baseRev: base, deleted: body == nil,
                        client: "web", summary: nil, runHook: false)
    }

    private func locked<T>(_ f: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try f()
    }
}

/// Sahte sunucuya bir kullanıcı olarak bağlanan API
final class FakeAPI: SupabaseAPIProtocol, @unchecked Sendable {
    let server: FakeServer
    let user: String
    var canCreate = true
    private(set) var pullCalls: [Int64] = []

    init(server: FakeServer, user: String) { self.server = server; self.user = user }

    var currentSession: AuthSession? {
        get async { AuthSession(accessToken: "access-\(user)", refreshToken: "refresh-\(user)", email: "\(user)@test") }
    }

    func signIn(email: String, password: String) async throws -> AuthSession {
        guard password == "dogru-sifre" else { throw CloudSyncError.invalidCredentials }
        return await currentSession!
    }

    func refresh() async throws -> AuthSession { await currentSession! }
    func myWorkspaces() async throws -> [CloudWorkspace] { server.workspaces(of: user) }

    func createWorkspace(name: String) async throws -> String {
        guard canCreate else { throw CloudSyncError.forbidden("Yeni şubeyi yalnızca patron açabilir.") }
        let id = UUID().uuidString.lowercased()
        server.addWorkspace(id, name: name, owner: user)
        return id
    }

    func pull(workspace: String, since: Int64) async throws -> [RemoteDoc] {
        pullCalls.append(since)
        return server.pull(user: user, ws: workspace, since: since)
    }

    func put(workspace: String, key: String, body: JSONValue, baseRev: Int64, deleted: Bool, client: String, summary: String?) async throws -> PutResult {
        try server.put(user: user, ws: workspace, key: key, body: body, baseRev: baseRev, deleted: deleted, client: client, summary: summary)
    }
}

/// İstekleri kaydeden ve yanıtı bir işleyiciden alan sahte taşıyıcı
final class MockTransport: SyncTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [SyncRequest] = []
    var handler: (SyncRequest) throws -> SyncResponse

    init(_ handler: @escaping (SyncRequest) throws -> SyncResponse) { self.handler = handler }

    var requests: [SyncRequest] { lock.lock(); defer { lock.unlock() }; return _requests }

    func send(_ request: SyncRequest) async throws -> SyncResponse {
        try record(request)(request)
    }

    private func record(_ request: SyncRequest) -> (SyncRequest) throws -> SyncResponse {
        lock.lock(); defer { lock.unlock() }
        _requests.append(request)
        return handler
    }
}

extension SyncResponse {
    static func json(_ status: Int, _ text: String) -> SyncResponse { SyncResponse(status: status, body: Data(text.utf8)) }
}

extension SyncRequest {
    var jsonBody: JSONValue? { body.flatMap { try? JSONCoding.parse($0) } }
    var query: [String: String] {
        var out: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] { out[item.name] = item.value ?? "" }
        return out
    }
}

/// Eşitleme yapan bir istemci (Mac uygulaması gibi): yerel veri + durum
final class SimClient {
    var data: AppData
    var state: SyncState
    let api: SupabaseAPIProtocol

    init(data: AppData, api: SupabaseAPIProtocol, workspace: String, role: String = CloudRole.owner, url: String = "https://test.local") {
        self.data = data
        self.api = api
        state = SyncState(config: CloudConfig(url: url, publishableKey: "sb_publishable_test", workspaceID: workspace,
                                              workspaceName: "Test Şubesi", email: "test@test", role: role))
    }

    /// Kullanıcı değişikliği: değişen anahtarlar "dirty" olur (AppStore'daki gibi)
    func edit(_ f: (inout AppData) -> Void) {
        let old = data
        f(&data)
        state.dirty.formUnion(DocCodec.changedKeys(old, data))
    }

    /// İlk bağlantı (tam okuma + karar)
    @discardableResult
    func connect(_ forced: InitialSyncMode? = nil) async throws -> InitialSyncMode {
        let ws = state.config!.workspaceID!
        let rows = try await api.pull(workspace: ws, since: 0)
        let mode = forced ?? CloudSyncEngine.initialMode(localIsSeedOnly: DocCodec.isSeedOnly(data),
                                                         remoteEmpty: CloudSyncEngine.isRemoteEmpty(rows))
        if mode != .ask {
            var st = state
            data = CloudSyncEngine.prepareInitial(mode: mode, local: data, rows: rows, state: &st)
            state = st
        }
        return mode
    }

    @discardableResult
    func sync() async throws -> SyncOutcome {
        var st = state
        let out = try await CloudSyncEngine.syncOnce(local: data, state: &st, api: api)
        state = st
        data = out.data
        return out
    }
}

/// İki verinin belgeleri aynı mı (AppData Equatable değil)
func XCTAssertSameDocs(_ a: AppData, _ b: AppData, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    let da = DocCodec.split(a), db = DocCodec.split(b)
    if da != db {
        let keys = Set(da.keys).union(db.keys).filter { da[$0] != db[$0] }.sorted()
        XCTFail("Belgeler farklı: \(keys.prefix(10)) \(message)", file: file, line: line)
    }
}

/// Yerel test sunucusu için en küçük HTTP/1.1 istemcisi (yalnızca http://127.0.0.1 / localhost).
/// Linux'taki FoundationNetworking, parametresiz `WWW-Authenticate: Bearer` başlıklı 401 yanıtını ayrıştırırken
/// çöküyor (macOS'taki URLSession etkilenmez); entegrasyon testinin 401 → yenileme adımı bununla gönderilir.
final class LoopbackHTTPTransport: SyncTransport, @unchecked Sendable {
    func send(_ request: SyncRequest) async throws -> SyncResponse { try perform(request) }

    private func perform(_ request: SyncRequest) throws -> SyncResponse {
        guard request.url.scheme == "http", let host = request.url.host, ["127.0.0.1", "localhost"].contains(host) else {
            throw CloudSyncError.network("yalnızca yerel http desteklenir")
        }
        let port = UInt16(request.url.port ?? 80)
        #if os(Linux)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw CloudSyncError.network("socket") }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { throw CloudSyncError.network("bağlanılamadı") }

        var path = request.url.path.isEmpty ? "/" : request.url.path
        if let q = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.percentEncodedQuery { path += "?" + q }
        var head = "\(request.method) \(path) HTTP/1.1\r\nHost: \(host):\(port)\r\nConnection: close\r\n"
        for (k, v) in request.headers { head += "\(k): \(v)\r\n" }
        head += "Content-Length: \(request.body?.count ?? 0)\r\n\r\n"
        var out = Data(head.utf8)
        if let b = request.body { out.append(b) }
        try out.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                guard n > 0 else { throw CloudSyncError.network("yazılamadı") }
                off += n
            }
        }
        var response = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            response.append(contentsOf: buf[0..<n])
        }
        guard let sep = response.range(of: Data("\r\n\r\n".utf8)) else { throw CloudSyncError.invalidResponse("başlık yok") }
        let headerText = String(decoding: response[..<sep.lowerBound], as: UTF8.self)
        var body = Data(response[sep.upperBound...])
        let lines = headerText.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2, let status = Int(parts[1]) else { throw CloudSyncError.invalidResponse("durum satırı") }
        let chunked = lines.dropFirst().contains { $0.lowercased().hasPrefix("transfer-encoding:") && $0.lowercased().contains("chunked") }
        if chunked { body = Self.dechunk(body) }
        return SyncResponse(status: status, body: body)
    }

    static func dechunk(_ data: Data) -> Data {
        var out = Data()
        var i = data.startIndex
        while i < data.endIndex, let lineEnd = data[i...].range(of: Data("\r\n".utf8)) {
            let sizeText = String(decoding: data[i..<lineEnd.lowerBound], as: UTF8.self).split(separator: ";").first ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16), size > 0 else { break }
            let start = lineEnd.upperBound
            let end = data.index(start, offsetBy: size, limitedBy: data.endIndex) ?? data.endIndex
            out.append(data[start..<end])
            i = data.index(end, offsetBy: 2, limitedBy: data.endIndex) ?? data.endIndex
        }
        return out
    }
}
