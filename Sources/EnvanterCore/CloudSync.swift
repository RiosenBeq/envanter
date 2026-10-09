import Foundation

// Bulut eşitlemesinin veri modeli (docs/SYNC.md): belge anahtarları, AppData ↔ belge dönüşümü,
// istemci durumu ve durumun diskte saklanması. Ağ: SupabaseAPI.swift; algoritma: CloudSyncEngine.swift.

/// Uygulamaya gömülü Supabase projesi. Publishable key tasarım gereği herkese açıktır (yetkiyi veritabanındaki
/// RLS kuralları uygular); personel yalnızca e-posta ve şifresini girer. "Gelişmiş" ayarlarla değiştirilebilir.
public enum CloudDefaults {
    public static let url = "https://eteyphpvpxmgokyfndsh.supabase.co"
    public static let publishableKey = "sb_publishable_GLfkJE9kN6OimifCDAbBFw_CO9r23Lg"
    /// envanter_activity.client değeri
    public static let client = "mac"
    /// Yerel değişiklikten sonra eşitlemeye kadar beklenen süre (saniye)
    public static let debounceSeconds: Double = 8
    /// Düzenli eşitleme aralığı (saniye)
    public static let intervalSeconds: Double = 60
    /// Çakışmada en fazla yeniden deneme
    public static let maxConflictRetries = 3
    /// Okumada sayfa boyutu
    public static let pageSize = 500
}

/// Bağlantı ayarları
public struct CloudConfig: Codable, Equatable, Sendable {
    public var url: String
    public var publishableKey: String
    /// Seçili çalışma alanı (şube); seçilmemişse nil
    public var workspaceID: String?
    public var workspaceName: String?
    public var email: String
    /// Kullanıcının bu şubedeki rolü: owner | manager | staff
    public var role: String?

    public init(url: String = CloudDefaults.url, publishableKey: String = CloudDefaults.publishableKey,
                workspaceID: String? = nil, workspaceName: String? = nil, email: String = "", role: String? = nil) {
        self.url = url; self.publishableKey = publishableKey
        self.workspaceID = workspaceID; self.workspaceName = workspaceName
        self.email = email; self.role = role
    }

    /// Personel yalnızca gün belgelerini yazabilir
    public var canWriteCatalog: Bool { role != CloudRole.staff }
}

public enum CloudRole {
    public static let owner = "owner", manager = "manager", staff = "staff"

    public static func title(_ role: String?) -> String {
        switch role {
        case owner: return "Patron"
        case manager: return "Müdür"
        case staff: return "Personel"
        default: return role ?? "—"
        }
    }
}

/// Bir belgenin sunucudan son alınan / yazılan hali
public struct BaseDoc: Codable, Equatable, Sendable {
    public var rev: Int64
    /// Sunucudaki ham gövde (bilinmeyen alanlar dahil); silinmişse nil
    public var body: JSONValue?
    public var deleted: Bool

    public init(rev: Int64, body: JSONValue?, deleted: Bool = false) {
        self.rev = rev; self.body = deleted ? nil : body; self.deleted = deleted
    }
}

/// İstemcinin eşitleme durumu (esitleme.json). Erişim anahtarları da burada tutulur; dosya yalnızca kullanıcının
/// okuyabileceği izinlerle (0600) yazılır ve yedeklere girmez.
public struct SyncState: Codable, Equatable, Sendable {
    public var config: CloudConfig?
    /// Görülen en büyük rev
    public var lastRev: Int64
    public var base: [String: BaseDoc]
    /// Yerelde değişmiş, henüz gönderilmemiş anahtarlar
    public var dirty: Set<String>
    public var accessToken: String?
    public var refreshToken: String?
    public var expiresAt: Date?
    public var lastSyncAt: Date?
    public var userEmail: String?
    /// İlk bağlantı kararı (yükle / indir) verildi; düzenli eşitleme yalnızca bundan sonra çalışır
    public var initialized: Bool

    public init(config: CloudConfig? = nil, lastRev: Int64 = 0, base: [String: BaseDoc] = [:], dirty: Set<String> = [],
                accessToken: String? = nil, refreshToken: String? = nil, expiresAt: Date? = nil, lastSyncAt: Date? = nil,
                userEmail: String? = nil, initialized: Bool = false) {
        self.config = config; self.lastRev = lastRev; self.base = base; self.dirty = dirty
        self.accessToken = accessToken; self.refreshToken = refreshToken; self.expiresAt = expiresAt
        self.lastSyncAt = lastSyncAt; self.userEmail = userEmail; self.initialized = initialized
    }

    enum CodingKeys: String, CodingKey {
        case config, lastRev, base, dirty, accessToken, refreshToken, expiresAt, lastSyncAt, userEmail, initialized
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        config = try c.decodeIfPresent(CloudConfig.self, forKey: .config)
        lastRev = try c.decodeIfPresent(Int64.self, forKey: .lastRev) ?? 0
        base = try c.decodeIfPresent([String: BaseDoc].self, forKey: .base) ?? [:]
        dirty = try c.decodeIfPresent(Set<String>.self, forKey: .dirty) ?? []
        accessToken = try c.decodeIfPresent(String.self, forKey: .accessToken)
        refreshToken = try c.decodeIfPresent(String.self, forKey: .refreshToken)
        expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
        lastSyncAt = try c.decodeIfPresent(Date.self, forKey: .lastSyncAt)
        userEmail = try c.decodeIfPresent(String.self, forKey: .userEmail)
        initialized = try c.decodeIfPresent(Bool.self, forKey: .initialized) ?? false
    }

    /// Oturum var mı (erişim ya da yenileme anahtarı)
    public var isSignedIn: Bool { refreshToken != nil || accessToken != nil }
    /// Şube seçilmiş, oturum açık ve ilk karar verilmiş: düzenli eşitleme çalışabilir
    public var isActive: Bool { config?.workspaceID != nil && isSignedIn && initialized }

    public var session: AuthSession? {
        guard let accessToken else { return nil }
        return AuthSession(accessToken: accessToken, refreshToken: refreshToken ?? "", expiresAt: expiresAt, email: userEmail)
    }

    public mutating func store(_ s: AuthSession?) {
        accessToken = s?.accessToken
        refreshToken = s.flatMap { $0.refreshToken.isEmpty ? nil : $0.refreshToken }
        expiresAt = s?.expiresAt
        if let e = s?.email { userEmail = e }
    }

    /// Şube eşleşmesini sıfırlar (şube değişince / çıkışta); bağlantı ayarları kalır
    public mutating func resetWorkspaceData() {
        lastRev = 0; base = [:]; dirty = []; initialized = false; lastSyncAt = nil
    }
}

/// esitleme.json dosyasını veri klasöründe saklar (0600 izinle; yedeklere girmez).
public struct SyncStore: Sendable {
    public static let fileName = "esitleme.json"
    public let directory: URL
    public var file: URL { directory.appendingPathComponent(Self.fileName) }

    public init(directory: URL) { self.directory = directory }

    /// Dosya yoksa ya da okunamazsa boş durum döner
    public func load() -> SyncState {
        guard let d = try? Data(contentsOf: file), let s = try? Self.decoder().decode(SyncState.self, from: d) else {
            return SyncState()
        }
        // Eski bir sürüm geniş izinle yazdıysa düzelt
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return s
    }

    /// Atomik yazma: dosya önce 0600 izinle geçici adla oluşturulur, sonra yerine taşınır.
    public func save(_ state: SyncState) throws {
        let data = try Self.encoder().encode(state)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tmp = directory.appendingPathComponent(".\(Self.fileName).\(UUID().uuidString).tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: tmp.path]) }
        var ok = true
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 { ok = false; break }
                offset += n
            }
        }
        if fsync(fd) != 0 { ok = false }
        close(fd)
        guard ok, rename(tmp.path, file.path) == 0 else {
            unlink(tmp.path)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path])
        }
    }

    public func delete() { try? FileManager.default.removeItem(at: file) }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static func decoder() -> JSONDecoder { JSONCoding.decoder() }
}

// MARK: - Belge anahtarları

public enum DocKey {
    public static let items = "items", products = "products", settings = "settings"
    public static let employees = "employees", orders = "orders"
    /// Gün dışı belgeler (eşitlemede önce gönderilir)
    public static let catalog = [items, products, settings, employees, orders]
    public static let dayPrefix = "day:"

    public static func day(_ date: String) -> String { dayPrefix + date }

    /// "day:2026-08-01" → "2026-08-01" (geçerli gün anahtarı değilse nil)
    public static func date(of key: String) -> String? {
        guard key.hasPrefix(dayPrefix) else { return nil }
        let d = String(key.dropFirst(dayPrefix.count))
        return DateKey.isValid(d) ? d : nil
    }

    public static func isDay(_ key: String) -> Bool { date(of: key) != nil }

    /// Sunucunun kabul ettiği anahtar mı
    public static func isValid(_ key: String) -> Bool { catalog.contains(key) || isDay(key) }

    /// Gönderim sırası: önce tanımlar (items, products, …), sonra günler tarih sırasıyla
    public static func sorted(_ keys: some Sequence<String>) -> [String] {
        keys.sorted { a, b in
            let ia = catalog.firstIndex(of: a) ?? Int.max, ib = catalog.firstIndex(of: b) ?? Int.max
            return ia != ib ? ia < ib : a < b
        }
    }
}

// MARK: - AppData ↔ belgeler

/// `AppData`'yı belgelere böler ve belgelerden geri kurar (docs/SYNC.md §1).
/// Okuma hoşgörülüdür (web istemcisinin `normalize*` fonksiyonlarıyla aynı): eksik zorunlu alanlar varsayılanla
/// doldurulur, geçersiz elemanlar (kimliksiz kalem vb.) atılır.
public enum DocCodec {
    /// Bulutta tutulacak gün mü: boş günler silinir (kilitli boş gün korunur)
    public static func storedDay(_ day: DayRecord?) -> DayRecord? {
        guard let day, !day.isEmpty || day.isLocked else { return nil }
        return day
    }

    /// Tüm belgeler (boş günler yazılmaz)
    public static func split(_ data: AppData) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for k in DocKey.catalog { if let v = body(for: k, in: data) { out[k] = v } }
        for (date, day) in data.days where DateKey.isValid(date) {
            if let d = storedDay(day), let v = try? JSONCoding.value(dated(d, date)) { out[DocKey.day(date)] = v }
        }
        return out
    }

    /// Tek belgenin gövdesi (gün yoksa / boşsa nil)
    public static func body(for key: String, in data: AppData) -> JSONValue? {
        switch key {
        case DocKey.items: return try? JSONCoding.value(data.items)
        case DocKey.products: return try? JSONCoding.value(data.products)
        case DocKey.settings: return try? JSONCoding.value(data.settings)
        case DocKey.employees: return try? JSONCoding.value(data.employees)
        case DocKey.orders: return try? JSONCoding.value(data.purchaseOrders)
        default:
            guard let date = DocKey.date(of: key), let d = storedDay(data.days[date]) else { return nil }
            return try? JSONCoding.value(dated(d, date))
        }
    }

    private static func dated(_ d: DayRecord, _ date: String) -> DayRecord {
        var d = d
        d.date = date
        return d
    }

    /// Belgelerden `AppData` kurar. Belgede olmayan anahtarlar `base`'den alınır; değeri JSON `null` olan belge
    /// silinmiş sayılır (gün kaldırılır; dizi belgeleri boşalır; ayarlar varsayılana döner — web istemcisiyle aynı).
    public static func assemble(_ docs: [String: JSONValue], base: AppData) -> AppData {
        var failures = Set<String>()
        return assemble(docs, base: base, failures: &failures)
    }

    /// `failures`: çözülemeyen (bozuk) belgeler; bunlarda `base`'deki değer korunur.
    public static func assemble(_ docs: [String: JSONValue], base: AppData, failures: inout Set<String>) -> AppData {
        var out = base
        for (key, body) in docs {
            if !apply(key: key, body: body.isNull ? nil : body, to: &out) { failures.insert(key) }
        }
        return out
    }

    /// Tek belgeyi uygular (`nil` = silinmiş). Çözülemezse veriye dokunmaz ve false döner.
    @discardableResult
    public static func apply(key: String, body: JSONValue?, to data: inout AppData) -> Bool {
        switch key {
        case DocKey.items:
            guard let body else { data.items = []; return true }
            guard let v = Lenient.items(body) else { return false }
            data.items = v
        case DocKey.products:
            guard let body else { data.products = []; return true }
            guard let v = Lenient.products(body) else { return false }
            data.products = v
        case DocKey.settings:
            guard let body else { data.settings = AppSettings(); return true }
            guard let v = Lenient.settings(body) else { return false }
            data.settings = v
        case DocKey.employees:
            guard let body else { data.employees = []; return true }
            guard let v = Lenient.employees(body) else { return false }
            data.employees = v
        case DocKey.orders:
            guard let body else { data.purchaseOrders = []; return true }
            guard let v = Lenient.orders(body) else { return false }
            data.purchaseOrders = v
        default:
            guard let date = DocKey.date(of: key) else { return true }  // bilinmeyen anahtar yok sayılır
            guard let body else { data.days[date] = nil; return true }
            guard let day = Lenient.day(body, date: date) else { return false }
            data.days[date] = storedDay(day)
        }
        return true
    }

    /// Belgenin Mac'teki karşılığı (çözülüp yeniden kodlanmış hali): bilinmeyen alanlar düşer, eksik alanlar
    /// varsayılanla dolar. Yerel değerle karşılaştırırken kullanılır. Yok / silinmiş / boş gün / bozuksa nil.
    public static func normalize(key: String, body: JSONValue?) -> JSONValue? {
        guard let body, !body.isNull else { return nil }
        var d = AppData(items: [], products: [])
        guard apply(key: key, body: body, to: &d) else { return nil }
        return Self.body(for: key, in: d)
    }

    /// İki veri arasında değişen belge anahtarları (silinen / boşalan günler dahil)
    public static func changedKeys(_ old: AppData, _ new: AppData) -> Set<String> {
        var keys = Set<String>()
        if old.items != new.items { keys.insert(DocKey.items) }
        if old.products != new.products { keys.insert(DocKey.products) }
        if old.settings != new.settings { keys.insert(DocKey.settings) }
        if old.employees != new.employees { keys.insert(DocKey.employees) }
        if old.purchaseOrders != new.purchaseOrders { keys.insert(DocKey.orders) }
        if old.days != new.days {
            for date in Set(old.days.keys).union(new.days.keys) where DateKey.isValid(date) {
                let a = old.days[date], b = new.days[date]
                if a == b { continue }
                if storedDay(a).map({ dated($0, date) }) != storedDay(b).map({ dated($0, date) }) {
                    keys.insert(DocKey.day(date))
                }
            }
        }
        return keys
    }

    /// `data`'nın verilen anahtarlarını `source`'takilerle değiştirir (diğer anahtarlara dokunmaz).
    /// Geri alma işlemleri bununla yalnızca kendi değiştirdiği belgeleri geri getirir.
    public static func replacing(_ keys: Set<String>, in data: AppData, from source: AppData) -> AppData {
        var d = data
        for k in keys {
            switch k {
            case DocKey.items: d.items = source.items
            case DocKey.products: d.products = source.products
            case DocKey.settings: d.settings = source.settings
            case DocKey.employees: d.employees = source.employees
            case DocKey.orders: d.purchaseOrders = source.purchaseOrders
            default:
                if let date = DocKey.date(of: k) { d.days[date] = source.days[date] }
            }
        }
        return d
    }

    /// Eşitleme sürerken kullanıcı veriyi değiştirdiyse: eşitlemenin sonucuna (`synced`) kullanıcının değişikliklerini
    /// (`started` → `current`) yeniden uygular. Aynı belge iki tarafta da değiştiyse merge3 ile birleştirilir.
    /// Dönen `changed`: kullanıcının eşitleme sırasında değiştirdiği anahtarlar (yeniden "dirty" işaretlenmeli).
    public static func rebase(started: AppData, current: AppData, synced: AppData) -> (data: AppData, changed: Set<String>) {
        let changed = changedKeys(started, current)
        guard !changed.isEmpty else { return (synced, []) }
        var out = synced
        for k in changed {
            let s = body(for: k, in: started), y = body(for: k, in: synced)
            if s == y {
                out = replacing([k], in: out, from: current)
            } else {
                let merged = JSONMerge.merge3(base: s, local: body(for: k, in: current), remote: y)
                if !apply(key: k, body: merged, to: &out) { out = replacing([k], in: out, from: current) }
            }
        }
        return (out, changed)
    }

    /// Yerel veri yalnızca varsayılan (ilk açılış) halinde mi: gün, personel ve sipariş yok; kalemler ve reçeteler
    /// varsayılanla aynı. (Ayarlar dikkate alınmaz: şube adı bağlanmadan önce yazılmış olabilir.)
    public static func isSeedOnly(_ data: AppData) -> Bool {
        guard data.days.values.allSatisfy({ storedDay($0) == nil }), data.employees.isEmpty, data.purchaseOrders.isEmpty else {
            return false
        }
        let seed = AppData.seeded()
        return data.items == seed.items && data.products == seed.products
    }
}

// MARK: - Hoşgörülü okuma (web: src/lib/model.ts normalize*)

enum Lenient {
    typealias Obj = [String: JSONValue]

    static func items(_ v: JSONValue) -> [Item]? { list(v) { item($0) } }
    static func products(_ v: JSONValue) -> [Product]? { list(v) { product($0) } }
    static func employees(_ v: JSONValue) -> [Employee]? { list(v) { employee($0) } }
    static func orders(_ v: JSONValue) -> [PurchaseOrder]? { list(v) { order($0) } }

    /// Dizi değilse boş liste (web ile aynı); geçersiz elemanlar atılır
    private static func list<T: Decodable>(_ v: JSONValue, _ f: (JSONValue) -> JSONValue?) -> [T]? {
        guard case .array(let arr) = v else { return [] }
        return arr.compactMap { el in f(el).flatMap { try? JSONCoding.decode(T.self, from: $0) } }
    }

    static func settings(_ v: JSONValue) -> AppSettings? {
        guard case .object(let raw) = v else { return AppSettings() }
        var o = raw
        let d = AppSettings()
        o["branchName"] = .string(raw["branchName"]?.stringValue ?? d.branchName)
        o["orderLookbackDays"] = .number(finite(raw["orderLookbackDays"]).map { $0.rounded() } ?? Double(d.orderLookbackDays))
        o["orderCoverDays"] = .number(finite(raw["orderCoverDays"]) ?? d.orderCoverDays)
        if case .array(let s)? = raw["staff"] {
            o["staff"] = .array(s.filter { $0.stringValue != nil })
        } else {
            o["staff"] = .array(d.staff.map { .string($0) })
        }
        for k in ["targetFoodCostPct", "targetLaborPct", "targetPrimeCostPct"] { o[k] = finite(raw[k]).map { .number($0) } }
        o["priceAlertPct"] = .number(finite(raw["priceAlertPct"]) ?? d.priceAlertPct)
        return try? JSONCoding.decode(AppSettings.self, from: .object(o))
    }

    static func day(_ v: JSONValue, date: String) -> DayRecord? {
        guard case .object(let raw) = v else { return nil }
        var o = raw
        o["date"] = .string(date)
        o["entries"] = .object(record(raw["entries"]) { entry($0) } ?? [:])
        o["sales"] = .array(arrayOf(raw["sales"]) { saleLine($0) })
        o["salesSource"] = str(raw["salesSource"])
        o["salesPeriod"] = str(raw["salesPeriod"])
        o["salesImportedAt"] = raw["salesImportedAt"]?.stringValue.flatMap { JSONCoding.parseISODate($0) != nil ? .string($0) : nil }
        o["legacySold"] = numberRecord(raw["legacySold"]).map { .object($0) }
        o["legacyWaste"] = numberRecord(raw["legacyWaste"]).map { .object($0) }
        o["importedFrom"] = str(raw["importedFrom"])
        o["note"] = str(raw["note"])
        o["countedBy"] = str(raw["countedBy"])
        o["locked"] = raw["locked"]?.boolValue.map { .bool($0) }
        o["shifts"] = record(raw["shifts"]) { shift($0) }.map { .object($0) }
        o["otherLabor"] = num(raw["otherLabor"])
        return try? JSONCoding.decode(DayRecord.self, from: .object(o))
    }

    // MARK: Elemanlar

    static func item(_ v: JSONValue) -> JSONValue? {
        guard case .object(let raw) = v, let id = idString(raw["id"]) else { return nil }
        var o = raw
        o["id"] = .string(id)
        o["name"] = .string(raw["name"]?.stringValue ?? "")
        o["unit"] = .string(raw["unit"]?.stringValue ?? "Adet")
        o["recipeUnit"] = .string(raw["recipeUnit"]?.stringValue ?? "adet")
        o["factor"] = .number(finite(raw["factor"]) ?? 1)
        o["active"] = .bool(raw["active"]?.boolValue ?? true)
        for k in ["unitCost", "minStock", "tolerance"] { o[k] = num(raw[k]) }
        if case .array(let h)? = raw["costHistory"] {
            o["costHistory"] = .array(h.compactMap { p -> JSONValue? in
                guard case .object(let pr) = p, let cost = finite(pr["cost"]) else { return nil }
                var po = pr
                po["cost"] = .number(cost)
                po["date"] = str(pr["date"])
                return .object(po)
            })
        } else {
            o["costHistory"] = nil
        }
        return .object(o)
    }

    static func product(_ v: JSONValue) -> JSONValue? {
        guard case .object(let raw) = v, let code = idString(raw["code"]) else { return nil }
        var o = raw
        o["code"] = .string(code)
        o["name"] = .string(raw["name"]?.stringValue ?? "")
        o["category"] = .string(raw["category"]?.stringValue ?? "")
        o["amounts"] = .object(numberRecord(raw["amounts"]) ?? [:])
        o["note"] = str(raw["note"])
        return .object(o)
    }

    static func payTerms(_ v: JSONValue) -> JSONValue? {
        guard case .object(let raw) = v else { return nil }
        var o = raw
        o["from"] = str(raw["from"])
        o["payType"] = .string(payType(raw["payType"]) ?? "monthly")
        o["rate"] = .number(finite(raw["rate"]) ?? 0)
        o["costFactor"] = .number(finite(raw["costFactor"]) ?? 1)
        return .object(o)
    }

    static func employee(_ v: JSONValue) -> JSONValue? {
        guard case .object(let raw) = v, let id = idString(raw["id"]) else { return nil }
        var o = raw
        o["id"] = .string(id)
        o["name"] = .string(raw["name"]?.stringValue ?? "")
        o["role"] = .string(raw["role"]?.stringValue ?? "")
        o["payType"] = .string(payType(raw["payType"]) ?? "monthly")
        o["rate"] = .number(finite(raw["rate"]) ?? 0)
        o["costFactor"] = .number(finite(raw["costFactor"]) ?? 1)
        o["active"] = .bool(raw["active"]?.boolValue ?? true)
        o["startDate"] = str(raw["startDate"])
        o["endDate"] = str(raw["endDate"])
        o["defaultHours"] = num(raw["defaultHours"])
        if case .array(let h)? = raw["payHistory"] {
            o["payHistory"] = .array(h.compactMap { payTerms($0) })
        } else {
            o["payHistory"] = nil
        }
        return .object(o)
    }

    static func orderLine(_ v: JSONValue) -> JSONValue? {
        guard case .object(let raw) = v, let itemID = idString(raw["itemID"]) else { return nil }
        var o = raw
        o["itemID"] = .string(itemID)
        o["qty"] = .number(finite(raw["qty"]) ?? 0)
        o["received"] = num(raw["received"])
        o["unitPrice"] = num(raw["unitPrice"])
        return .object(o)
    }

    static func order(_ v: JSONValue) -> JSONValue? {
        guard case .object(let raw) = v, let id = idString(raw["id"]) else { return nil }
        var o = raw
        o["id"] = .string(id)
        o["date"] = .string(raw["date"]?.stringValue ?? "")
        o["supplier"] = .string(raw["supplier"]?.stringValue ?? "")
        o["lines"] = .array(arrayOf(raw["lines"]) { orderLine($0) })
        let status = raw["status"]?.stringValue
        o["status"] = .string(["open", "received", "cancelled"].contains(status ?? "") ? status! : "open")
        o["receivedOn"] = str(raw["receivedOn"])
        o["note"] = str(raw["note"])
        return .object(o)
    }

    static func entry(_ v: JSONValue) -> JSONValue? {
        guard case .object(let raw) = v else { return nil }
        var o = raw
        for k in ["opening", "incoming", "transferIn", "transferOut", "closing"] { o[k] = num(raw[k]) }
        return .object(o)
    }

    static func shift(_ v: JSONValue) -> JSONValue? {
        guard case .object(let raw) = v else { return nil }
        var o = raw
        o["hours"] = num(raw["hours"])
        o["worked"] = raw["worked"]?.boolValue.map { .bool($0) }
        o["extra"] = num(raw["extra"])
        return .object(o)
    }

    static func saleLine(_ v: JSONValue) -> JSONValue? {
        guard case .object(let raw) = v, let code = idString(raw["code"]) else { return nil }
        var o = raw
        o["code"] = .string(code)
        o["name"] = .string(raw["name"]?.stringValue ?? "")
        o["qty"] = .number(finite(raw["qty"]) ?? 0)
        o["amount"] = num(raw["amount"])
        return .object(o)
    }

    // MARK: Yardımcılar

    static func finite(_ v: JSONValue?) -> Double? {
        guard case .number(let n)? = v, n.isFinite else { return nil }
        return n
    }

    static func num(_ v: JSONValue?) -> JSONValue? { finite(v).map { .number($0) } }
    static func str(_ v: JSONValue?) -> JSONValue? { v?.stringValue.map { .string($0) } }

    static func idString(_ v: JSONValue?) -> String? {
        switch v {
        case .string(let s)?: return s
        case .number(let n)? where n.isFinite:
            return n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        default: return nil
        }
    }

    static func payType(_ v: JSONValue?) -> String? {
        guard let s = v?.stringValue, PayType(rawValue: s) != nil else { return nil }
        return s
    }

    static func numberRecord(_ v: JSONValue?) -> Obj? {
        guard case .object(let raw)? = v else { return nil }
        return raw.compactMapValues { num($0) }
    }

    static func record(_ v: JSONValue?, _ f: (JSONValue) -> JSONValue?) -> Obj? {
        guard case .object(let raw)? = v else { return nil }
        return raw.compactMapValues(f)
    }

    static func arrayOf(_ v: JSONValue?, _ f: (JSONValue) -> JSONValue?) -> [JSONValue] {
        guard case .array(let a)? = v else { return [] }
        return a.compactMap(f)
    }
}
