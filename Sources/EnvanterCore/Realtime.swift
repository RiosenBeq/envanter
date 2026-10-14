import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Anlık eşitleme: Supabase Realtime (Phoenix kanal protokolü, vsn 1.0.0). Mac, şubenin envanter_docs satırları
// değişince (web panelinden düzeltme, başka Mac) hemen eşitler ve çevrimiçi olduğunu (presence) web paneline bildirir.
// Konu "realtime:envanter-canli:<şube>"; web paneli aynı kanala katılır (docs/SYNC.md §2 "Canlı güncelleme").
// Protokol mantığı (RealtimeSession) G/Ç ve zamanlayıcı içermez; RealtimeClient onu bir websocket taşıyıcısı ve
// zamanlayıcıyla birleştirir. Bağlantı yokken 60 saniyelik düzenli eşitleme güvenlik ağı olarak sürer.

// MARK: - Mesaj

/// Phoenix mesajı (vsn 1.0.0 JSON nesnesi: topic, event, payload, ref, join_ref)
public struct RealtimeMessage: Codable, Equatable, Sendable {
    public var topic: String
    public var event: String
    public var payload: JSONValue
    public var ref: String?
    public var joinRef: String?

    public init(topic: String, event: String, payload: JSONValue = .object([:]), ref: String? = nil, joinRef: String? = nil) {
        self.topic = topic; self.event = event; self.payload = payload; self.ref = ref; self.joinRef = joinRef
    }

    enum CodingKeys: String, CodingKey { case topic, event, payload, ref, joinRef = "join_ref" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        topic = try c.decode(String.self, forKey: .topic)
        event = try c.decode(String.self, forKey: .event)
        payload = try c.decodeIfPresent(JSONValue.self, forKey: .payload) ?? .null
        ref = Self.refString(try c.decodeIfPresent(JSONValue.self, forKey: .ref))
        joinRef = Self.refString(try c.decodeIfPresent(JSONValue.self, forKey: .joinRef))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(topic, forKey: .topic)
        try c.encode(event, forKey: .event)
        try c.encode(payload, forKey: .payload)
        try c.encodeIfPresent(ref, forKey: .ref)
        try c.encodeIfPresent(joinRef, forKey: .joinRef)
    }

    /// Metinden (geçersiz JSON ya da eksik alan → nil)
    public init?(text: String) {
        guard let m = try? JSONDecoder().decode(RealtimeMessage.self, from: Data(text.utf8)) else { return nil }
        self = m
    }

    /// Gönderilecek metin (anahtarlar sıralı, belirlenimci)
    public var text: String {
        let data = (try? JSONCoding.encoder().encode(self)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private static func refString(_ v: JSONValue?) -> String? {
        switch v {
        case .string(let s)?: return s
        case .number(let n)? where n.isFinite: return n == n.rounded() ? String(Int64(n)) : String(n)
        default: return nil
        }
    }
}

// MARK: - Protokol durumu

/// Gelen mesajların anlamı
public enum RealtimeEvent: Equatable, Sendable {
    /// Kanala katılındı
    case joined
    /// Katılma reddedildi (sunucunun nedeni); yeniden bağlanılmalı
    case joinFailed(String)
    /// envanter_docs değişti: hemen eşitlenmeli
    case changed
    /// Sunucu kanalı kapattı (phx_close); yeniden bağlanılmalı
    case closed
    /// Kanal / bağlantı hatası (phx_error, sistem hatası, kalp atışı reddi); yeniden bağlanılmalı
    case errored(String)
    /// Çevrimiçi olanlar: anahtar (cihaz) → bildirdikleri bilgiler
    case presence([String: [JSONValue]])
}

/// Tek bir websocket bağlantısının protokol durumu (G/Ç ve zamanlayıcı yok): giden mesajları üretir, gelenleri
/// olaylara çevirir, ref'leri izler (bilinmeyen ref'lere gelen yanıtlar yok sayılır).
public struct RealtimeSession: Sendable {
    /// Kanal adı öneki (web: supabase.channel("envanter-canli:<şube>"))
    public static let channelPrefix = "envanter-canli:"
    public static let vsn = "1.0.0"

    public let workspaceID: String
    public let topic: String
    /// Presence anahtarı: kuruluma özgü kalıcı cihaz kimliği
    public let deviceKey: String
    public private(set) var accessToken: String
    public private(set) var joinRef: String?
    public private(set) var isJoined = false
    /// Son bilinen çevrimiçi durumu (presence_state + presence_diff)
    public private(set) var presence: [String: [JSONValue]] = [:]
    private var lastRef = 0
    private var pendingHeartbeat: String?
    private var pendingReplies: Set<String> = []

    public init(workspaceID: String, accessToken: String, deviceKey: String) {
        self.workspaceID = workspaceID
        self.topic = Self.topic(workspaceID: workspaceID)
        self.accessToken = accessToken
        self.deviceKey = deviceKey
    }

    public static func topic(workspaceID: String) -> String { "realtime:" + channelPrefix + workspaceID }

    /// Websocket adresi: https → wss, http → ws; ".../realtime/v1/websocket?apikey=<key>&vsn=1.0.0"
    public static func url(config: CloudConfig) -> URL? { url(base: config.url, publishableKey: config.publishableKey) }

    public static func url(base: String, publishableKey: String) -> URL? {
        var u = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while u.hasSuffix("/") { u.removeLast() }
        let key = publishableKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, var c = URLComponents(string: u), c.host != nil else { return nil }
        switch c.scheme?.lowercased() {
        case "https": c.scheme = "wss"
        case "http": c.scheme = "ws"
        default: return nil
        }
        c.path += "/realtime/v1/websocket"
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        c.percentEncodedQuery = "apikey=\(key.addingPercentEncoding(withAllowedCharacters: unreserved) ?? key)&vsn=\(vsn)"
        return c.url
    }

    /// Katılma isteğinin gövdesi: tüm envanter_docs değişiklikleri (RLS: yalnızca üye olunan şube) + presence
    public var joinPayload: JSONValue {
        .object([
            "config": .object([
                "broadcast": .object(["ack": .bool(false), "self": .bool(false)]),
                "presence": .object(["key": .string(deviceKey), "enabled": .bool(true)]),
                "postgres_changes": .array([.object([
                    "event": .string("*"), "schema": .string("public"), "table": .string("envanter_docs"),
                    "filter": .string("workspace_id=eq.\(workspaceID)"),
                ])]),
                "private": .bool(false),
            ]),
            "access_token": .string(accessToken),
        ])
    }

    /// Yeni bağlantı açıldı: durum sıfırlanır, katılma (phx_join) mesajı döner
    public mutating func start() -> RealtimeMessage {
        reset()
        let ref = nextRef()
        joinRef = ref
        return RealtimeMessage(topic: topic, event: "phx_join", payload: joinPayload, ref: ref, joinRef: ref)
    }

    /// Bağlantı kapandı: katılım, bekleyen yanıtlar ve çevrimiçi durumu unutulur (erişim anahtarı kalır)
    public mutating func reset() {
        lastRef = 0
        isJoined = false
        joinRef = nil
        pendingHeartbeat = nil
        pendingReplies = []
        presence = [:]
    }

    /// Kalp atışı. nil: öncekine yanıt gelmedi → bağlantı kopmuş sayılır, yeniden bağlanılmalı
    public mutating func heartbeat() -> RealtimeMessage? {
        guard pendingHeartbeat == nil else { return nil }
        let ref = nextRef()
        pendingHeartbeat = ref
        return RealtimeMessage(topic: "phoenix", event: "heartbeat", payload: .object([:]), ref: ref)
    }

    /// Yenilenen erişim anahtarı. Kanala katılmışsa "access_token" mesajı döner; değilse anahtar sonraki katılmada kullanılır.
    public mutating func updateToken(_ token: String) -> RealtimeMessage? {
        guard token != accessToken else { return nil }
        accessToken = token
        guard isJoined else { return nil }
        return push("access_token", .object(["access_token": .string(token)]))
    }

    /// Çevrimiçi bilgisini bildirir (katıldıktan sonra)
    public mutating func track(presence meta: [String: JSONValue]) -> RealtimeMessage? {
        guard isJoined else { return nil }
        return push("presence", .object(["type": .string("presence"), "event": .string("track"), "payload": .object(meta)]))
    }

    /// Gelen mesaj → olaylar. Başka konular, bilinmeyen ref'lere yanıtlar ve yayınlar (broadcast) yok sayılır.
    public mutating func receive(_ text: String) -> [RealtimeEvent] {
        guard let m = RealtimeMessage(text: text) else { return [] }
        if m.topic == "phoenix" {
            guard m.event == "phx_reply", let ref = m.ref, ref == pendingHeartbeat else { return [] }
            pendingHeartbeat = nil
            return Self.status(m.payload) == "ok" ? [] : [.errored("Kalp atışı reddedildi: " + Self.reason(m.payload))]
        }
        guard m.topic == topic else { return [] }
        switch m.event {
        case "phx_reply":
            guard let ref = m.ref else { return [] }
            if ref == joinRef && !isJoined {
                if Self.status(m.payload) == "ok" {
                    isJoined = true
                    return [.joined]
                }
                return [.joinFailed(Self.reason(m.payload))]
            }
            pendingReplies.remove(ref)
            return []
        case "postgres_changes":
            return [.changed]
        case "system":
            // "Subscribed to PostgreSQL" gibi bilgi mesajları değişiklik değildir; hata durumu yeniden bağlanmayı gerektirir
            if Self.status(m.payload) == "error" { return [.errored(m.payload["message"]?.stringValue ?? "Sistem hatası")] }
            return []
        case "presence_state":
            presence = Self.metas(m.payload)
            return [.presence(presence)]
        case "presence_diff":
            applyDiff(m.payload)
            return [.presence(presence)]
        case "phx_close":
            isJoined = false
            return [.closed]
        case "phx_error":
            isJoined = false
            return [.errored("Kanal hatası")]
        default:
            return []
        }
    }

    // MARK: Yardımcılar

    private mutating func nextRef() -> String {
        lastRef += 1
        return String(lastRef)
    }

    private mutating func push(_ event: String, _ payload: JSONValue) -> RealtimeMessage {
        let ref = nextRef()
        pendingReplies.insert(ref)
        return RealtimeMessage(topic: topic, event: event, payload: payload, ref: ref, joinRef: joinRef)
    }

    private static func status(_ payload: JSONValue) -> String? { payload["status"]?.stringValue }

    private static func reason(_ payload: JSONValue) -> String {
        let r = payload["response"]
        if let s = r?["reason"]?.stringValue ?? r?["message"]?.stringValue ?? r?.stringValue { return s }
        if let r, r != .object([:]), let data = try? JSONCoding.data(r) { return String(decoding: data, as: UTF8.self) }
        return "bilinmeyen neden"
    }

    /// {anahtar: {metas: [...]}} → anahtar → metas
    private static func metas(_ v: JSONValue?) -> [String: [JSONValue]] {
        guard let o = v?.objectValue else { return [:] }
        var out: [String: [JSONValue]] = [:]
        for (k, entry) in o {
            let list = entry["metas"]?.arrayValue ?? []
            if !list.isEmpty { out[k] = list }
        }
        return out
    }

    private mutating func applyDiff(_ payload: JSONValue) {
        func refs(_ list: [JSONValue]) -> Set<String> { Set(list.compactMap { $0["phx_ref"]?.stringValue }) }
        for (k, list) in Self.metas(payload["leaves"]) {
            let gone = refs(list)
            let kept = (presence[k] ?? []).filter { m in m["phx_ref"]?.stringValue.map { !gone.contains($0) } ?? false }
            presence[k] = kept.isEmpty ? nil : kept
        }
        for (k, list) in Self.metas(payload["joins"]) {
            let known = refs(presence[k] ?? [])
            presence[k] = (presence[k] ?? []) + list.filter { m in m["phx_ref"]?.stringValue.map { !known.contains($0) } ?? true }
        }
    }
}

/// Mac'in çevrimiçi bilgisi (presence): istemci, şube adı, uygulama sürümü, veri biçimi düzeyi (`fmt`, `DataFormat.level`:
/// web paneli eski sürümü tanır), bağlanma zamanı; bağlantı koduyla bağlanan bilgisayarda cihaz hesabının kullanıcı adı
/// (`device`, ör. "pc-7kq2m9": web panelindeki bağlı bilgisayarlar listesi çevrimiçi olanı tanır). E-posta ya da kişisel
/// bilgi yoktur (kanal herkese açıktır; değişiklik içeriği RLS ile korunur).
public enum RealtimePresence {
    public static func mac(branch: String, app: String, since: Date, device: String? = nil) -> [String: JSONValue] {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        var meta: [String: JSONValue] = ["client": .string(CloudDefaults.client), "branch": .string(branch), "app": .string(app),
                                         "fmt": .number(Double(DataFormat.level)), "since": .string(f.string(from: since))]
        if let device, !device.isEmpty { meta["device"] = .string(device) }
        return meta
    }
}

// MARK: - Taşıyıcı ve zamanlayıcı

/// Websocket taşıyıcısı. Geri çağrılar herhangi bir iş parçacığından gelebilir; `close()` sonrasında gelenler yok sayılır.
public protocol RealtimeTransport: AnyObject {
    func connect(url: URL, onOpen: @escaping () -> Void, onText: @escaping (String) -> Void, onClose: @escaping (String?) -> Void)
    func send(_ text: String)
    func close()
}

public protocol RealtimeCancellable: AnyObject {
    func cancel()
}

/// Gecikmeli iş zamanlayıcısı (testlerde anında ilerleyen sahte zamanlayıcıyla değiştirilir). İş herhangi bir iş
/// parçacığında çalışabilir.
public protocol RealtimeScheduler: AnyObject {
    func schedule(after seconds: TimeInterval, _ work: @escaping () -> Void) -> RealtimeCancellable
}

extension DispatchWorkItem: RealtimeCancellable {}

/// DispatchQueue ile zamanlayıcı
public final class DispatchRealtimeScheduler: RealtimeScheduler, @unchecked Sendable {
    private let queue: DispatchQueue

    public init(queue: DispatchQueue = DispatchQueue.global(qos: .utility)) { self.queue = queue }

    public func schedule(after seconds: TimeInterval, _ work: @escaping () -> Void) -> RealtimeCancellable {
        let item = DispatchWorkItem(block: work)
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
        return item
    }
}

// MARK: - İstemci

public enum RealtimeStatus: Equatable, Sendable {
    case connecting
    /// Kanala katılındı: değişiklikler anında gelir
    case connected
    /// Bağlı değil (yeniden bağlanma bekleniyor ya da durduruldu); düzenli eşitleme sürer
    case disconnected
}

/// Anlık eşitleme istemcisi: oturum durumu + taşıyıcı + zamanlayıcılar. Kalp atışı 25 sn; kopunca 1, 2, 5, 10, 30 sn
/// (sonra hep 30) bekleyip yeniden bağlanır, başarılı katılmada sayaç sıfırlanır. Ardışık değişiklikler 0,3 sn içinde
/// tek `onChange` olur. Tüm durum tek bir seri kuyrukta değişir; geri çağrılar `callbackQueue`'da (varsayılan ana
/// kuyruk; nil: istemcinin kuyruğunda) çağrılır.
public final class RealtimeClient: @unchecked Sendable {
    public static let heartbeatSeconds: TimeInterval = 25
    public static let backoffSeconds: [TimeInterval] = [1, 2, 5, 10, 30]
    public static let joinTimeoutSeconds: TimeInterval = 10
    public static let coalesceSeconds: TimeInterval = 0.3

    /// Erişim anahtarı kaynağı (tamamlanınca anahtarı ya da nil'i verir)
    typealias TokenSource = (@escaping (String?) -> Void) -> Void

    private let transport: RealtimeTransport
    private let scheduler: RealtimeScheduler
    private let queue = DispatchQueue(label: "envanter.realtime")
    private let onQueue = DispatchSpecificKey<Bool>()
    private let callbackQueue: DispatchQueue?
    private let coalesce: TimeInterval

    private let lock = NSLock()
    private var changeHandler: (() -> Void)?
    private var statusHandler: ((RealtimeStatus) -> Void)?
    private var presenceHandler: (([String: [JSONValue]]) -> Void)?

    // Yalnızca `queue` üzerinde
    private var url: URL?
    private var session: RealtimeSession?
    private var presence: [String: JSONValue] = [:]
    private var tokenSource: TokenSource?
    private var running = false
    private var generation = 0
    private var attempt = 0
    private var status = RealtimeStatus.disconnected
    private var heartbeatTimer: RealtimeCancellable?
    private var joinTimer: RealtimeCancellable?
    private var reconnectTimer: RealtimeCancellable?
    private var changeTimer: RealtimeCancellable?
    private(set) var lastProblem: String?

    /// - Parameters:
    ///   - transport: websocket (macOS: `URLSessionRealtimeTransport()`)
    ///   - scheduler: zamanlayıcı (varsayılan DispatchQueue)
    ///   - callbackQueue: geri çağrıların kuyruğu (varsayılan ana kuyruk; nil: istemcinin kendi kuyruğu)
    ///   - coalesce: ardışık değişikliklerin birleştirildiği süre (0: her değişiklik ayrı bildirilir)
    public init(transport: RealtimeTransport, scheduler: RealtimeScheduler = DispatchRealtimeScheduler(),
                callbackQueue: DispatchQueue? = .main, coalesce: TimeInterval = RealtimeClient.coalesceSeconds) {
        self.transport = transport
        self.scheduler = scheduler
        self.callbackQueue = callbackQueue
        self.coalesce = coalesce
        queue.setSpecific(key: onQueue, value: true)
    }

    /// envanter_docs değişti (birleştirilmiş): hemen eşitle
    public var onChange: (() -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return changeHandler }
        set { lock.lock(); changeHandler = newValue; lock.unlock() }
    }

    /// Bağlantı durumu değişti. `.connected` olunca bir kez eşitlemek, kopukken kaçan değişiklikleri getirir.
    public var onStatus: ((RealtimeStatus) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return statusHandler }
        set { lock.lock(); statusHandler = newValue; lock.unlock() }
    }

    /// Çevrimiçi olanlar değişti (cihaz anahtarı → bildirdikleri bilgiler; isteğe bağlı)
    public var onPresence: (([String: [JSONValue]]) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return presenceHandler }
        set { lock.lock(); presenceHandler = newValue; lock.unlock() }
    }

    /// Bağlanır (açıksa önce kapatır). `accessToken` her katılmadan ve her kalp atışından önce sorulur (ör.
    /// `{ try? await api.validAccessToken() }`); anahtar değişmişse kanala "access_token" ile bildirilir. nil dönerse
    /// (oturum düştü, ağ yok) bekleyip yeniden denenir.
    public func start(config: CloudConfig, workspaceID: String, deviceKey: String, presence: [String: JSONValue],
                      accessToken: @escaping @Sendable () async -> String?) {
        start(config: config, workspaceID: workspaceID, deviceKey: deviceKey, presence: presence) { done in
            Task { done(await accessToken()) }
        }
    }

    func start(config: CloudConfig, workspaceID: String, deviceKey: String, presence: [String: JSONValue], tokenSource: @escaping TokenSource) {
        queue.async { [self] in
            shutdown()
            guard let url = RealtimeSession.url(config: config) else {
                lastProblem = "Geçersiz sunucu adresi"
                return
            }
            self.url = url
            self.presence = presence
            self.tokenSource = tokenSource
            session = RealtimeSession(workspaceID: workspaceID, accessToken: "", deviceKey: deviceKey)
            running = true
            attempt = 0
            connect()
        }
    }

    /// Bağlantıyı kapatır, zamanlayıcıları durdurur (çıkış, şube değişimi, kendi kendini sınama / ekran görüntüsü modu)
    public func stop() {
        queue.async { [self] in shutdown() }
    }

    /// Yenilenen erişim anahtarını hemen kanala bildirir (kalp atışını beklemeden)
    public func updateToken(_ token: String) {
        queue.async { [self] in applyToken(token) }
    }

    /// Çevrimiçi bilgisini değiştirir (ör. şube adı değişti)
    public func updatePresence(_ meta: [String: JSONValue]) {
        queue.async { [self] in
            presence = meta
            if running, var s = session, let m = s.track(presence: meta) {
                session = s
                transport.send(m.text)
            }
        }
    }

    /// Kuyruktaki işler bitene kadar bekler (testler)
    func waitIdle() { queue.sync {} }

    // MARK: Bağlantı (yalnızca `queue` üzerinde)

    private func connect() {
        guard running, let url, let tokenSource else { return }
        cancelConnectionTimers()
        generation += 1
        let gen = generation
        setStatus(.connecting)
        tokenSource { [weak self] token in
            self?.enqueue { me in
                guard me.generation == gen, me.running else { return }
                guard let token, !token.isEmpty else { return me.reconnect("Oturum anahtarı alınamadı") }
                if var s = me.session {
                    _ = s.updateToken(token)
                    me.session = s
                }
                // Açılış ya da katılma gecikirse (yanıtsız sunucu) yeniden bağlan
                me.joinTimer = me.schedule(Self.joinTimeoutSeconds, gen) { $0.reconnect("Bağlantı ya da kanala katılma zaman aşımına uğradı") }
                me.transport.connect(
                    url: url,
                    onOpen: { [weak me] in me?.enqueue { $0.opened(gen) } },
                    onText: { [weak me] text in me?.enqueue { $0.received(text, gen) } },
                    onClose: { [weak me] reason in me?.enqueue { $0.dropped(reason, gen) } })
            }
        }
    }

    /// İşi istemcinin kuyruğunda yapar: zaten oradaysa hemen (eşzamanlı anahtar kaynağı), değilse sıraya koyar
    /// (istemci o ana kadar bırakıldıysa iş yapılmaz)
    private func enqueue(_ work: @escaping (RealtimeClient) -> Void) {
        if DispatchQueue.getSpecific(key: onQueue) == true { return work(self) }
        queue.async { [weak self] in
            if let self { work(self) }
        }
    }

    private func opened(_ gen: Int) {
        guard gen == generation, running, var s = session else { return }
        let join = s.start()
        session = s
        transport.send(join.text)
        scheduleHeartbeat(gen)
    }

    private func scheduleHeartbeat(_ gen: Int) {
        heartbeatTimer = schedule(Self.heartbeatSeconds, gen) { me in
            guard var s = me.session else { return }
            guard let beat = s.heartbeat() else {
                me.session = s
                return me.reconnect("Kalp atışına yanıt gelmedi")
            }
            me.session = s
            me.transport.send(beat.text)
            me.scheduleHeartbeat(gen)
            // Anahtar dolmak üzereyse kaynak yeniler; değişeni kanala bildir
            me.tokenSource? { [weak me] token in
                me?.enqueue { me in
                    guard me.generation == gen, me.running, let token, !token.isEmpty else { return }
                    me.applyToken(token)
                }
            }
        }
    }

    private func received(_ text: String, _ gen: Int) {
        guard gen == generation, running, var s = session else { return }
        let events = s.receive(text)
        session = s
        for e in events {
            switch e {
            case .joined:
                joinTimer?.cancel()
                joinTimer = nil
                attempt = 0
                lastProblem = nil
                setStatus(.connected)
                if var s2 = session, let m = s2.track(presence: presence) {
                    session = s2
                    transport.send(m.text)
                }
            case .changed:
                changed()
            case .presence(let state):
                deliver { [weak self] in self?.onPresence?(state) }
            case .joinFailed(let reason):
                return reconnect("Kanala katılınamadı: " + reason)
            case .closed:
                return reconnect("Sunucu kanalı kapattı")
            case .errored(let reason):
                return reconnect(reason)
            }
        }
    }

    private func dropped(_ reason: String?, _ gen: Int) {
        guard gen == generation, running else { return }
        reconnect(reason ?? "Bağlantı koptu")
    }

    private func applyToken(_ token: String) {
        guard running, var s = session else { return }
        let m = s.updateToken(token)
        session = s
        if let m { transport.send(m.text) }
    }

    /// Bağlantıyı bırakır ve geri çekilme süresi sonra yeniden bağlanır
    private func reconnect(_ reason: String) {
        lastProblem = reason
        closeConnection()
        setStatus(.disconnected)
        let delay = Self.backoffSeconds[min(attempt, Self.backoffSeconds.count - 1)]
        attempt += 1
        reconnectTimer = schedule(delay, generation) { $0.connect() }
    }

    private func closeConnection() {
        generation += 1          // eski bağlantının geri çağrıları yok sayılır
        cancelConnectionTimers()
        session?.reset()
        transport.close()
    }

    private func shutdown() {
        guard running else { return }
        running = false
        closeConnection()
        changeTimer?.cancel()
        changeTimer = nil
        session = nil
        tokenSource = nil
        setStatus(.disconnected)
    }

    private func cancelConnectionTimers() {
        heartbeatTimer?.cancel()
        joinTimer?.cancel()
        reconnectTimer?.cancel()
        heartbeatTimer = nil
        joinTimer = nil
        reconnectTimer = nil
    }

    private func changed() {
        guard coalesce > 0 else { return deliver { [weak self] in self?.onChange?() } }
        guard changeTimer == nil else { return }
        changeTimer = schedule(coalesce, nil) { me in
            me.changeTimer = nil
            me.deliver { [weak me] in me?.onChange?() }
        }
    }

    private func setStatus(_ s: RealtimeStatus) {
        guard s != status else { return }
        status = s
        deliver { [weak self] in self?.onStatus?(s) }
    }

    private func deliver(_ f: @escaping @Sendable () -> Void) {
        if let q = callbackQueue { q.async(execute: f) } else { f() }
    }

    /// İş, istemcinin kuyruğunda ve yalnızca bağlantı (gen) hâlâ geçerliyse çalışır
    private func schedule(_ seconds: TimeInterval, _ gen: Int?, _ work: @escaping (RealtimeClient) -> Void) -> RealtimeCancellable {
        scheduler.schedule(after: seconds) { [weak self] in
            self?.enqueue { me in
                guard me.running, gen == nil || gen == me.generation else { return }
                work(me)
            }
        }
    }
}

// MARK: - URLSession websocket

/// URLSessionWebSocketTask ile gerçek websocket (macOS). Linux'ta derlenir ama çalışmaz (libcurl'de websocket yok);
/// testler sahte taşıyıcı kullanır.
public final class URLSessionRealtimeTransport: RealtimeTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var connection: Connection?

    public init() {}

    public func connect(url: URL, onOpen: @escaping () -> Void, onText: @escaping (String) -> Void, onClose: @escaping (String?) -> Void) {
        close()
        let c = Connection(onOpen: onOpen, onText: onText, onClose: onClose)
        lock.lock(); connection = c; lock.unlock()
        c.start(url: url)
    }

    public func send(_ text: String) {
        lock.lock(); let c = connection; lock.unlock()
        c?.send(text)
    }

    public func close() {
        lock.lock(); let c = connection; connection = nil; lock.unlock()
        c?.close()
    }

    /// Tek bir bağlantı (oturumun temsilcisi). Açılış temsilci geri çağrısıyla anlaşılır; kapanış bir kez bildirilir.
    /// Oturum temsilciyi kapanana kadar tutar; kapanınca geçersizleştirilir (döngü kırılır).
    private final class Connection: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var session: URLSession?
        private var task: URLSessionWebSocketTask?
        private var finished = false
        /// Gönderimler sırayla yapılır (her biri öncekini bekler)
        private var lastSend: Task<Void, Never>?
        private let onOpen: () -> Void
        private let onText: (String) -> Void
        private let onClose: (String?) -> Void

        init(onOpen: @escaping () -> Void, onText: @escaping (String) -> Void, onClose: @escaping (String?) -> Void) {
            self.onOpen = onOpen; self.onText = onText; self.onClose = onClose
            super.init()
        }

        func start(url: URL) {
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil
            config.urlCache = nil
            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            let task = session.webSocketTask(with: URLRequest(url: url))
            task.maximumMessageSize = 16 << 20
            lock.lock(); self.session = session; self.task = task; lock.unlock()
            task.resume()
            Task { [weak self] in
                while let self, !self.isFinished {
                    do {
                        switch try await task.receive() {
                        case .string(let s): self.onText(s)
                        case .data(let d): self.onText(String(decoding: d, as: UTF8.self))
                        @unknown default: break
                        }
                    } catch {
                        self.finish(error.localizedDescription)
                    }
                }
            }
        }

        func send(_ text: String) {
            lock.lock()
            defer { lock.unlock() }
            guard let task, !finished else { return }
            let previous = lastSend
            lastSend = Task { [weak self] in
                await previous?.value
                do { try await task.send(.string(text)) } catch { self?.finish(error.localizedDescription) }
            }
        }

        /// İstemci kapattı: geri çağrı yok
        func close() {
            lock.lock()
            finished = true
            let task = self.task, session = self.session
            self.task = nil; self.session = nil
            lock.unlock()
            task?.cancel(with: .goingAway, reason: nil)
            session?.invalidateAndCancel()
        }

        private var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }

        func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol proto: String?) {
            guard !isFinished else { return }
            onOpen()
        }

        func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
            finish("Sunucu bağlantıyı kapattı (\(closeCode.rawValue))")
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            finish(error?.localizedDescription ?? "Bağlantı kapandı")
        }

        private func finish(_ reason: String?) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            let task = self.task, session = self.session
            self.task = nil; self.session = nil
            lock.unlock()
            task?.cancel(with: .goingAway, reason: nil)
            session?.invalidateAndCancel()
            onClose(reason)
        }
    }
}
