import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Supabase'e (Auth + PostgREST) doğrudan, kullanıcının oturumuyla bağlanan istemci (docs/SYNC.md §2).
// Gizli anahtar yoktur: yalnızca herkese açık publishable key ve kullanıcının erişim anahtarı gönderilir.

// MARK: - Hatalar

public enum CloudSyncError: Error, Equatable, LocalizedError, Sendable {
    /// E-posta ya da şifre yanlış
    case invalidCredentials
    /// E-posta adresi onaylanmamış
    case emailNotConfirmed
    /// Oturum yok ya da yenilenemedi (yeniden giriş gerekir)
    case sessionExpired
    /// Rol yetkisi yok (ör. personel gün dışı belge yazmaya çalıştı); sunucunun mesajı
    case forbidden(String)
    /// Ağ hatası (sunucuya ulaşılamadı, zaman aşımı …)
    case network(String)
    /// Çok fazla istek
    case rateLimited
    /// Supabase projesinde envanter tabloları / fonksiyonları yok (migration uygulanmamış)
    case notProvisioned
    /// Sunucu isteği geçersiz buldu (geçersiz anahtar / gövde)
    case invalidRequest(String)
    /// Sunucu hatası
    case server(status: Int, message: String)
    /// Yanıt beklenen biçimde değil
    case invalidResponse(String)
    /// Eşitleme ayarlanmamış (şube seçilmemiş)
    case notConfigured
    /// Kullanıcı hiçbir şubeye üye değil ve yeni şube açamıyor
    case noWorkspace
    /// Bağlantı ayarı (sunucu adresi / publishable key) geçersiz
    case invalidConfiguration(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "E-posta ya da şifre yanlış."
        case .emailNotConfirmed:
            return "E-posta adresi onaylanmamış. Gelen kutunuzdaki onay bağlantısına tıklayıp tekrar deneyin."
        case .sessionExpired:
            return "Oturumun süresi doldu. Web paneli hesabınızla yeniden giriş yapın."
        case .forbidden(let m):
            let detail = m.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Yetki yok: " + (detail.isEmpty ? "personel yalnızca gün verisi (sayım, satış, vardiya, not) yazabilir." : detail)
        case .network(let m):
            return "Ağ hatası: sunucuya ulaşılamadı. İnternet bağlantınızı kontrol edin." + (m.isEmpty ? "" : " (\(m))")
        case .rateLimited:
            return "Çok fazla deneme yapıldı. Birkaç dakika bekleyip tekrar deneyin."
        case .notProvisioned:
            // Ne yapılacağı: issue(connected:) (CloudSyncGuide.swift)
            return "Web panelinin veritabanı hazır değil: Supabase projesinde envanter tabloları kurulu değil."
        case .invalidRequest(let m):
            return "Sunucu isteği reddetti: \(m)"
        case .server(let status, let m):
            return "Sunucu hatası (\(status))" + (m.isEmpty ? "." : ": \(m)")
        case .invalidResponse(let m):
            return "Sunucudan beklenmeyen yanıt geldi" + (m.isEmpty ? "." : ": \(m)")
        case .notConfigured:
            return "Web paneli eşitlemesi ayarlanmamış."
        case .noWorkspace:
            return "Hesabınız henüz bir şubeye eklenmemiş."
        case .invalidConfiguration(let m):
            return "Bağlantı ayarı geçersiz: \(m)"
        }
    }

    /// Yeniden giriş gerektiren hata mı
    public var requiresSignIn: Bool { self == .sessionExpired || self == .invalidCredentials }
}

// MARK: - Taşıma katmanı

public struct SyncRequest: Sendable, Equatable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method; self.url = url; self.headers = headers; self.body = body
    }
}

public struct SyncResponse: Sendable, Equatable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) { self.status = status; self.body = body }
}

/// HTTP taşıyıcı (testlerde sahte taşıyıcıyla değiştirilir)
public protocol SyncTransport: Sendable {
    func send(_ request: SyncRequest) async throws -> SyncResponse
}

/// URLSession ile gerçek ağ isteği. Çerez / önbellek kullanılmaz.
public final class URLSessionTransport: SyncTransport, @unchecked Sendable {
    private let session: URLSession

    public init(timeout: TimeInterval = 30) {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = timeout
        c.timeoutIntervalForResource = timeout * 4
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpCookieStorage = nil
        c.urlCache = nil
        session = URLSession(configuration: c)
    }

    public func send(_ request: SyncRequest) async throws -> SyncResponse {
        var r = URLRequest(url: request.url)
        r.httpMethod = request.method
        for (k, v) in request.headers { r.setValue(v, forHTTPHeaderField: k) }
        r.httpBody = request.body
        let session = self.session
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<SyncResponse, Error>) in
            let task = session.dataTask(with: r) { data, response, error in
                if let error {
                    cont.resume(throwing: CloudSyncError.network(error.localizedDescription))
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    cont.resume(throwing: CloudSyncError.invalidResponse("HTTP yanıtı yok"))
                    return
                }
                cont.resume(returning: SyncResponse(status: http.statusCode, body: data ?? Data()))
            }
            task.resume()
        }
    }
}

// MARK: - Modeller

public struct AuthSession: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date?
    public var userID: String?
    public var email: String?

    public init(accessToken: String, refreshToken: String, expiresAt: Date? = nil, userID: String? = nil, email: String? = nil) {
        self.accessToken = accessToken; self.refreshToken = refreshToken; self.expiresAt = expiresAt
        self.userID = userID; self.email = email
    }
}

/// Kullanıcının üye olduğu şube
public struct CloudWorkspace: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var role: String

    public init(id: String, name: String, role: String) { self.id = id; self.name = name; self.role = role }
}

/// envanter_docs satırı
public struct RemoteDoc: Codable, Equatable, Sendable {
    public var key: String
    public var body: JSONValue?
    public var rev: Int64
    public var deleted: Bool
    public var updatedAt: String?
    public var updatedBy: String?

    public init(key: String, body: JSONValue?, rev: Int64, deleted: Bool = false, updatedAt: String? = nil, updatedBy: String? = nil) {
        self.key = key; self.body = body; self.rev = rev; self.deleted = deleted
        self.updatedAt = updatedAt; self.updatedBy = updatedBy
    }

    enum CodingKeys: String, CodingKey {
        case key, body, rev, deleted
        case updatedAt = "updated_at", updatedBy = "updated_by"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        body = try c.decodeIfPresent(JSONValue.self, forKey: .body)
        if body?.isNull == true { body = nil }
        rev = try c.decode(Int64.self, forKey: .rev)
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
        updatedBy = try c.decodeIfPresent(String.self, forKey: .updatedBy)
    }
}

/// envanter_put sonucu: ok = false ise çakışma (sunucudaki güncel rev/body/deleted döner;
/// belge hiç yoksa rev = 0, body = nil)
public struct PutResult: Codable, Equatable, Sendable {
    public var ok: Bool
    public var rev: Int64
    public var body: JSONValue?
    public var deleted: Bool

    public init(ok: Bool, rev: Int64, body: JSONValue?, deleted: Bool) {
        self.ok = ok; self.rev = rev; self.body = body; self.deleted = deleted
    }

    enum CodingKeys: String, CodingKey { case ok, rev, body, deleted }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.decode(Bool.self, forKey: .ok)
        rev = try c.decodeIfPresent(Int64.self, forKey: .rev) ?? 0
        body = try c.decodeIfPresent(JSONValue.self, forKey: .body)
        if body?.isNull == true { body = nil }
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
    }
}

/// envanter_activity satırı
public struct ActivityRow: Codable, Equatable, Sendable {
    public var id: Int64
    public var email: String?
    public var at: String?
    public var client: String?
    public var key: String
    public var summary: String
}

// MARK: - API

/// Eşitleme motorunun kullandığı sunucu işlemleri (testlerde bellek içi sahte sunucuyla değiştirilir)
public protocol SupabaseAPIProtocol: AnyObject, Sendable {
    /// Geçerli oturum (yenilenmiş anahtarlar dahil; durum dosyasına yazılır)
    var currentSession: AuthSession? { get async }
    func signIn(email: String, password: String) async throws -> AuthSession
    func refresh() async throws -> AuthSession
    func myWorkspaces() async throws -> [CloudWorkspace]
    func createWorkspace(name: String) async throws -> String
    /// rev > since olan tüm belgeler (rev sırasıyla, sayfalı okunur)
    func pull(workspace: String, since: Int64) async throws -> [RemoteDoc]
    func put(workspace: String, key: String, body: JSONValue, baseRev: Int64, deleted: Bool, client: String, summary: String?) async throws -> PutResult
}

/// Supabase REST istemcisi. Oturum anahtarları bu aktörde tutulur; 401 / "JWT expired" yanıtında
/// bir kez yenilenip istek tekrarlanır, süresi dolmak üzereyse önceden yenilenir.
public actor SupabaseAPI: SupabaseAPIProtocol {
    public nonisolated let baseURL: URL
    public nonisolated let publishableKey: String
    private let transport: SyncTransport
    private var session: AuthSession?
    private var refreshTask: Task<AuthSession, Error>?
    private let now: @Sendable () -> Date

    public init(url: String, publishableKey: String, session: AuthSession? = nil,
                transport: SyncTransport = URLSessionTransport(), now: @escaping @Sendable () -> Date = { Date() }) throws {
        var u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while u.hasSuffix("/") { u.removeLast() }
        guard let parsed = URL(string: u), let scheme = parsed.scheme?.lowercased(), scheme == "https" || scheme == "http",
              parsed.host != nil else {
            throw CloudSyncError.invalidConfiguration("sunucu adresi \"\(url)\" bir https:// adresi olmalı.")
        }
        let key = publishableKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw CloudSyncError.invalidConfiguration("publishable key boş olamaz.") }
        self.baseURL = parsed
        self.publishableKey = key
        self.session = session
        self.transport = transport
        self.now = now
    }

    public var currentSession: AuthSession? { session }

    public func setSession(_ s: AuthSession?) { session = s }

    // MARK: Auth

    public func signIn(email: String, password: String) async throws -> AuthSession {
        let body = try JSONEncoder().encode(["email": email.trimmingCharacters(in: .whitespacesAndNewlines), "password": password])
        let r = try await send(SyncRequest(method: "POST", url: url("auth/v1/token", query: [("grant_type", "password")]),
                                           headers: baseHeaders(json: true), body: body))
        let s = try parseSession(r, fallbackEmail: email)
        session = s
        return s
    }

    /// Yeni hesap açar (yerel test ortamında e-posta onayı otomatiktir ve hemen oturum döner)
    public func signUp(email: String, password: String) async throws -> AuthSession {
        let body = try JSONEncoder().encode(["email": email.trimmingCharacters(in: .whitespacesAndNewlines), "password": password])
        let r = try await send(SyncRequest(method: "POST", url: url("auth/v1/signup"), headers: baseHeaders(json: true), body: body))
        if r.status == 200, let obj = try? JSONCoding.parse(r.body), obj["access_token"] == nil {
            // Oturum dönmedi: e-posta onayı bekleniyor
            throw CloudSyncError.emailNotConfirmed
        }
        let s = try parseSession(r, fallbackEmail: email)
        session = s
        return s
    }

    public func refresh() async throws -> AuthSession {
        if let t = refreshTask { return try await t.value }
        guard let token = session?.refreshToken, !token.isEmpty else { throw CloudSyncError.sessionExpired }
        let email = session?.email
        let req = SyncRequest(method: "POST", url: url("auth/v1/token", query: [("grant_type", "refresh_token")]),
                              headers: baseHeaders(json: true), body: try JSONEncoder().encode(["refresh_token": token]))
        let task = Task<AuthSession, Error> { [transport] in
            let r: SyncResponse
            do { r = try await transport.send(req) } catch let e as CloudSyncError { throw e } catch { throw CloudSyncError.network(error.localizedDescription) }
            if r.status == 400 || r.status == 401 || r.status == 403 { throw CloudSyncError.sessionExpired }
            return try self.parseSession(r, fallbackEmail: email)
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let s = try await task.value
            session = s
            return s
        } catch CloudSyncError.sessionExpired {
            session = nil
            throw CloudSyncError.sessionExpired
        }
    }

    public func signOut() { session = nil }

    /// Oturumu sunucuda da kapatır (yenileme anahtarı geçersizleşir). Ağ hatası yok sayılır.
    public func logout() async {
        guard let token = session?.accessToken else { return }
        session = nil
        var h = baseHeaders(json: false)
        h["Authorization"] = "Bearer \(token)"
        _ = try? await send(SyncRequest(method: "POST", url: url("auth/v1/logout"), headers: h))
    }

    // MARK: RPC / REST

    public func myWorkspaces() async throws -> [CloudWorkspace] {
        let r = try await authorized("POST", url("rest/v1/rpc/envanter_my_workspaces"), body: .object([:]))
        return try decode([CloudWorkspace].self, r.body)
    }

    public func createWorkspace(name: String) async throws -> String {
        let r = try await authorized("POST", url("rest/v1/rpc/envanter_create_workspace"), body: .object(["p_name": .string(name)]))
        let v = try decode(JSONValue.self, r.body)
        guard let id = v.stringValue ?? v.arrayValue?.first?.stringValue else { throw CloudSyncError.invalidResponse("şube kimliği yok") }
        return id
    }

    public func renameWorkspace(_ workspace: String, name: String) async throws {
        _ = try await authorized("POST", url("rest/v1/rpc/envanter_rename_workspace"),
                                 body: .object(["p_workspace": .string(workspace), "p_name": .string(name)]))
    }

    /// Kullanıcı davet eder (yalnızca owner): "member" | "invited"
    public func invite(workspace: String, email: String, role: String) async throws -> String {
        let r = try await authorized("POST", url("rest/v1/rpc/envanter_invite"),
                                     body: .object(["p_workspace": .string(workspace), "p_email": .string(email), "p_role": .string(role)]))
        return try decode(JSONValue.self, r.body).stringValue ?? ""
    }

    public func pull(workspace: String, since: Int64) async throws -> [RemoteDoc] {
        var out: [RemoteDoc] = []
        var cursor = since
        while true {
            let u = url("rest/v1/envanter_docs", query: [
                ("workspace_id", "eq.\(workspace)"), ("rev", "gt.\(cursor)"), ("order", "rev.asc"),
                ("select", "key,body,rev,deleted,updated_at,updated_by"), ("limit", "\(CloudDefaults.pageSize)"),
            ])
            let r = try await authorized("GET", u, body: nil)
            let page = try decode([RemoteDoc].self, r.body)
            out.append(contentsOf: page)
            guard page.count >= CloudDefaults.pageSize, let last = page.last?.rev, last > cursor else { break }
            cursor = last
        }
        return out
    }

    public func put(workspace: String, key: String, body: JSONValue, baseRev: Int64, deleted: Bool, client: String, summary: String?) async throws -> PutResult {
        var params: [String: JSONValue] = [
            "p_workspace": .string(workspace), "p_key": .string(key), "p_body": body,
            "p_base_rev": .number(Double(baseRev)), "p_deleted": .bool(deleted), "p_client": .string(client),
        ]
        if let summary { params["p_summary"] = .string(summary) }
        let r = try await authorized("POST", url("rest/v1/rpc/envanter_put"), body: .object(params))
        let rows = try decode([PutResult].self, r.body)
        guard let first = rows.first else { throw CloudSyncError.invalidResponse("envanter_put sonuç döndürmedi") }
        return first
    }

    /// Son değişiklik kayıtları (yeniden eskiye)
    public func activity(workspace: String, limit: Int = 50) async throws -> [ActivityRow] {
        let u = url("rest/v1/envanter_activity", query: [
            ("workspace_id", "eq.\(workspace)"), ("order", "id.desc"),
            ("select", "id,email,at,client,key,summary"), ("limit", "\(limit)"),
        ])
        return try decode([ActivityRow].self, try await authorized("GET", u, body: nil).body)
    }

    // MARK: İstek yardımcıları

    nonisolated func url(_ path: String, query: [(String, String)] = []) -> URL {
        var c = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            // PostgREST değerleri (eq.…, gt.…, rev.asc) olduğu gibi; yalnızca gerekli karakterler kodlanır
            var allowed = CharacterSet.urlQueryAllowed
            allowed.remove(charactersIn: "&=+#")
            c.percentEncodedQuery = query.map { k, v in
                "\(k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
            }.joined(separator: "&")
        }
        return c.url!
    }

    private nonisolated func baseHeaders(json: Bool) -> [String: String] {
        var h = ["apikey": publishableKey, "Accept": "application/json"]
        if json { h["Content-Type"] = "application/json" }
        return h
    }

    private func send(_ req: SyncRequest) async throws -> SyncResponse {
        do { return try await transport.send(req) } catch let e as CloudSyncError { throw e } catch {
            throw CloudSyncError.network(error.localizedDescription)
        }
    }

    /// Oturumlu istek: süresi dolmak üzereyse önce yenilenir; 401 / JWT süresi dolduysa bir kez yenilenip tekrarlanır.
    /// (Entegrasyon testi patronun üyelik RPC'lerini de bununla çağırır.)
    func authorized(_ method: String, _ url: URL, body: JSONValue?) async throws -> SyncResponse {
        guard session != nil else { throw CloudSyncError.sessionExpired }
        if let exp = session?.expiresAt, exp.timeIntervalSince(now()) < 60, !(session?.refreshToken.isEmpty ?? true) {
            _ = try await refresh()
        }
        let data = try body.map { try JSONCoding.data($0) }
        func request() throws -> SyncRequest {
            guard let token = session?.accessToken else { throw CloudSyncError.sessionExpired }
            var h = baseHeaders(json: data != nil)
            h["Authorization"] = "Bearer \(token)"
            return SyncRequest(method: method, url: url, headers: h, body: data)
        }
        var r = try await send(try request())
        if Self.isAuthExpiry(r) {
            _ = try await refresh()
            r = try await send(try request())
            if Self.isAuthExpiry(r) { throw CloudSyncError.sessionExpired }
        }
        try Self.check(r)
        return r
    }

    static func isAuthExpiry(_ r: SyncResponse) -> Bool {
        if r.status == 401 { return true }
        guard r.status == 400 || r.status == 403 else { return false }
        let e = ServerError(r.body)
        return e.message.localizedCaseInsensitiveContains("JWT expired") || e.code == "PGRST301" || e.code == "PGRST303"
    }

    /// Hata yanıtlarını türlü hataya çevirir
    static func check(_ r: SyncResponse) throws {
        guard !(200..<300).contains(r.status) else { return }
        let e = ServerError(r.body)
        switch r.status {
        case 401: throw CloudSyncError.sessionExpired
        case 403: throw CloudSyncError.forbidden(e.message)
        case 404 where e.code.hasPrefix("PGRST2") || e.code == "42P01" || e.code == "42883":
            throw CloudSyncError.notProvisioned
        case 429: throw CloudSyncError.rateLimited
        default:
            if e.code == "42501" { throw CloudSyncError.forbidden(e.message) }
            if e.code == "42P01" || e.code == "42883" || e.code == "PGRST202" || e.code == "PGRST205" { throw CloudSyncError.notProvisioned }
            if (400..<500).contains(r.status) { throw CloudSyncError.invalidRequest(e.message.isEmpty ? "HTTP \(r.status)" : e.message) }
            throw CloudSyncError.server(status: r.status, message: e.message)
        }
    }

    nonisolated func parseSession(_ r: SyncResponse, fallbackEmail: String?) throws -> AuthSession {
        guard (200..<300).contains(r.status) else {
            let e = ServerError(r.body)
            let text = (e.code + " " + e.message).lowercased()
            if text.contains("email_not_confirmed") || text.contains("email not confirmed") { throw CloudSyncError.emailNotConfirmed }
            if text.contains("invalid_credentials") || text.contains("invalid login credentials") || text.contains("invalid_grant") {
                throw CloudSyncError.invalidCredentials
            }
            if r.status == 429 || text.contains("rate limit") { throw CloudSyncError.rateLimited }
            if (400..<500).contains(r.status) { throw CloudSyncError.invalidRequest(e.message.isEmpty ? "HTTP \(r.status)" : e.message) }
            throw CloudSyncError.server(status: r.status, message: e.message)
        }
        guard let obj = try? JSONCoding.parse(r.body), let access = obj["access_token"]?.stringValue else {
            throw CloudSyncError.invalidResponse("oturum anahtarı yok")
        }
        let refresh = obj["refresh_token"]?.stringValue ?? ""
        var expires: Date?
        if let at = obj["expires_at"]?.doubleValue {
            expires = Date(timeIntervalSince1970: at)
        } else if let inSec = obj["expires_in"]?.doubleValue {
            expires = now().addingTimeInterval(inSec)
        }
        let user = obj["user"]
        return AuthSession(accessToken: access, refreshToken: refresh, expiresAt: expires,
                           userID: user?["id"]?.stringValue, email: user?["email"]?.stringValue ?? fallbackEmail)
    }

    private nonisolated func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONCoding.decoder().decode(T.self, from: data) } catch {
            throw CloudSyncError.invalidResponse(String(describing: T.self))
        }
    }
}

/// PostgREST ({code, message, details, hint}) ve GoTrue ({error_code, msg} / {error, error_description}) hata gövdesi
struct ServerError {
    var code = ""
    var message = ""

    init(_ data: Data) {
        guard let obj = try? JSONCoding.parse(data) else {
            message = String(decoding: data.prefix(300), as: UTF8.self)
            return
        }
        code = obj["error_code"]?.stringValue ?? obj["code"]?.stringValue ?? obj["error"]?.stringValue ?? ""
        message = obj["message"]?.stringValue ?? obj["msg"]?.stringValue ?? obj["error_description"]?.stringValue
            ?? obj["error"]?.stringValue ?? ""
    }
}
