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
    /// Mac: rol ve şube adı (şube listesi) en fazla bu kadar saniyede bir yeniden okunur; uygulama öne gelince de okunur
    public static let roleCheckSeconds: Double = 300
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
    public var canWriteCatalog: Bool { CloudRole.canWriteCatalog(role) }
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

    /// Tanım belgelerini (kalem, reçete, ayar, personel, sipariş) yazabilir mi: personel yazamaz.
    /// Rol bilinmiyorsa (web eşitlemesi yok) her şey serbesttir.
    public static func canWriteCatalog(_ role: String?) -> Bool { role != staff }

    /// Belgeyi yazabilir mi (docs/SYNC.md §2 "Roller")
    public static func canWrite(_ role: String?, key: String) -> Bool { canWriteCatalog(role) || DocKey.isDay(key) }

    /// Kapatılmış (kilitli) günü değiştirebilir, kilidini açabilir ya da silebilir mi: personel yapamaz
    /// (docs/SYNC.md §2 "Kapatılmış gün"; sunucu da 42501 ile reddeder).
    public static func canChangeLockedDay(_ role: String?) -> Bool { role != staff }
}

/// Bir yerel değişikliğin rol kurallarına takılması. Uygulama işlemi bütünüyle reddeder: yarısı gönderilip yarısı
/// sunucuca geri alınan işlem (ör. teslim alma: gün + sipariş) veriyi bozardı.
public struct LocalChangeRefusal: Equatable, Sendable {
    /// Personelin yazamadığı tanım belgeleri (sıralı)
    public var catalogKeys: [String]
    /// Değiştirilmek istenen kapatılmış günler (yyyy-MM-dd, sıralı)
    public var lockedDates: [String]

    public var title: String {
        catalogKeys.isEmpty ? "Gün kapatılmış" : "Bu işlem için müdür yetkisi gerekir"
    }

    public var message: String {
        if catalogKeys.contains(DocKey.orders) {
            return "\(CloudPermission.ordersStaffNote) Personel hesabıyla yalnızca günlük kayıtlar (sayım, satış, vardiya, not) değiştirilebilir; işlem uygulanmadı."
        }
        if !catalogKeys.isEmpty {
            let labels = catalogKeys.map { DocKey.title($0) }.joined(separator: ", ")
            return "Personel hesabıyla yalnızca günlük kayıtlar (sayım, satış, vardiya, not) değiştirilebilir. \(labels) bölümündeki değişikliği patron ya da müdür web panelinden yapabilir; işlem uygulanmadı."
        }
        let dates = lockedDates.map { DateKey.short($0) }.joined(separator: ", ")
        let what = lockedDates.count == 1 ? "\(dates) günü kapatılmış." : "\(dates) günleri kapatılmış."
        return "\(what) \(CloudPermission.lockedDayMessage) Değişiklik uygulanmadı."
    }
}

/// Yerel değişikliklerde rol kuralları (web: src/lib/store/docs.ts canEditKey / dayChangeAllowed ile aynı)
public enum CloudPermission {
    /// Sunucunun personel için kapatılmış gün hatası (42501) ile aynı metin
    public static let lockedDayMessage = "Kapatılmış günü yalnızca müdür veya patron değiştirebilir."
    /// Personel hesabıyla salt okunur bölümlerin açıklaması (stok kalemleri, reçeteler, personel, siparişler, ayarlar)
    public static let catalogReadOnlyNote = "Personel hesabı: bu bölümü yalnızca patron veya müdür değiştirebilir (web paneli). Burada web panelindeki hal gösterilir."
    /// Personel hesabıyla kapatılmış günde gösterilen açıklama
    public static let lockedDayStaffNote = "Gün kapatıldı. Kilidi yalnızca patron veya müdür açabilir."
    /// Personel hesabıyla sipariş ve teslimat işlemleri kapalıdır (yarım kalan teslim alma Gelen'i iki kez yazdırırdı)
    public static let ordersStaffNote = "Teslimatı ve siparişleri patron / müdür işler (web paneli)."
    /// Personel hesabıyla kapatılmış güne satış aktarılmak istendiğinde (kilidi kendisi açamaz)
    public static let lockedDayPickAnotherNote = "Kapatılmış günün kilidini yalnızca patron veya müdür açabilir; başka bir gün seçin."
    /// Personel hesabıyla satış dökümünde reçetesi tanımsız ürün varken (reçete tanımlamak tanım belgesidir)
    public static let recipeStaffNote = "Reçetesi tanımsız ürünlerin reçetesini patron veya müdür tanımlar (web paneli → Reçeteler); tanımlanınca bu Mac'te de stoktan düşer."

    /// `old` → `new` değişikliği `role` için reddedilir mi (nil: izinli). Personel tanım belgelerini değiştiremez;
    /// yerelde kapatılmış bir günü de hiçbir şekilde değiştiremez (kilidini açmak ve silmek dahil). Açık günü kapatmak serbesttir.
    public static func refusal(role: String?, old: AppData, new: AppData) -> LocalChangeRefusal? {
        refusal(role: role, old: old, keys: DocCodec.changedKeys(old, new))
    }

    /// `keys`: değişen belge anahtarları (`DocCodec.changedKeys(old, new)`)
    public static func refusal(role: String?, old: AppData, keys: Set<String>) -> LocalChangeRefusal? {
        guard role == CloudRole.staff, !keys.isEmpty else { return nil }
        let catalog = DocKey.sorted(keys.filter { !CloudRole.canWrite(role, key: $0) })
        let locked = keys.compactMap { DocKey.date(of: $0) }.filter { old.days[$0]?.isLocked == true }.sorted()
        if catalog.isEmpty && locked.isEmpty { return nil }
        return LocalChangeRefusal(catalogKeys: catalog, lockedDates: locked)
    }
}

/// "Günü Kapat / Kilidi Aç" isteğinin sonucu. Gün menüsü (⌘L) ve Günlük Sayım düğmesi aynı kuralı kullanır:
/// sayım yapılmamış (boş ya da ileri tarihli) gün kapatılmaz; personel kapatmadan önce onaylar, çünkü kapatılan günün
/// kilidini yalnızca patron veya müdür açabilir (docs/SYNC.md §2 "Kapatılmış gün").
public enum DayLockAction: Equatable, Sendable {
    /// Gün kapatılır
    case close
    /// Personel: gün onaydan sonra kapatılır
    case confirmClose
    /// Kilit açılır
    case unlock
    /// Hiçbir kalem sayılmamış: gün kapatılamaz
    case nothingCounted
    /// Personel kapatılmış günün kilidini açamaz
    case unlockNotAllowed

    /// - Parameters:
    ///   - locked: gün kapatılmış mı
    ///   - counted: en az bir (aktif) kalemin kapanışı girilmiş mi (`Engine.hasCount`)
    ///   - role: web eşitlemesindeki rol (`AppStore.enforcedRole`; eşleşme yoksa nil)
    public static func resolve(locked: Bool, counted: Bool, role: String?) -> DayLockAction {
        let canChange = CloudRole.canChangeLockedDay(role)
        if locked { return canChange ? .unlock : .unlockNotAllowed }
        if !counted { return .nothingCounted }
        return canChange ? .close : .confirmClose
    }

    /// Menü öğesi / düğme etkin mi
    public var isAvailable: Bool { self != .nothingCounted && self != .unlockNotAllowed }

    /// Personelin gün kapatma onayı
    public static func confirmTitle(date: String) -> String { "\(DateKey.short(date)) günü kapatılsın mı?" }
    public static let confirmMessage = "Günü kapatınca sayım, satış ve vardiya değiştirilemez; kilidi yalnızca patron veya müdür açabilir."

    /// Onay penceresinin metni: günün sayım ve satış durumu (kapatmadan önce eksik kalan görülsün), sonra kural.
    /// - Parameters:
    ///   - counted, total: kapanışı girilmiş ve toplam aktif kalem sayısı
    ///   - hasSales: satış raporu (ya da Excel'den gelen satış) var mı
    public static func confirmDetail(counted: Int, total: Int, hasSales: Bool) -> String {
        var lines: [String] = []
        if total > 0 {
            lines.append(counted >= total
                         ? "Sayım tamam: \(total) / \(total) kalem sayıldı."
                         : "Sayım eksik: \(counted) / \(total) kalem sayıldı, \(total - counted) kalem sayılmadı.")
        }
        lines.append(hasSales ? "Satış raporu aktarıldı."
                              : "Satış raporu aktarılmadı: satılan miktarlar ve farklar eksik hesaplanır.")
        return lines.joined(separator: "\n") + "\n\n" + confirmMessage
    }

    /// Hiç sayım girilmemiş gün kapatılamaz: düğmenin yanında gösterilen açıklama
    public static let nothingCountedNote = "Sayım girilmeden gün kapatılamaz"
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
    /// Kullanıcı çıkış yaptı ya da yeniden girişte şube henüz onaylanmadı: şube eşleşmesi (taban, bekleyen
    /// değişiklikler) korunur ama eşitleme, şube yeniden seçilene (rol güncellenene) kadar çalışmaz.
    public var signedOut: Bool

    public init(config: CloudConfig? = nil, lastRev: Int64 = 0, base: [String: BaseDoc] = [:], dirty: Set<String> = [],
                accessToken: String? = nil, refreshToken: String? = nil, expiresAt: Date? = nil, lastSyncAt: Date? = nil,
                userEmail: String? = nil, initialized: Bool = false, signedOut: Bool = false) {
        self.config = config; self.lastRev = lastRev; self.base = base; self.dirty = dirty
        self.accessToken = accessToken; self.refreshToken = refreshToken; self.expiresAt = expiresAt
        self.lastSyncAt = lastSyncAt; self.userEmail = userEmail; self.initialized = initialized
        self.signedOut = signedOut
    }

    enum CodingKeys: String, CodingKey {
        case config, lastRev, base, dirty, accessToken, refreshToken, expiresAt, lastSyncAt, userEmail, initialized, signedOut
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
        signedOut = try c.decodeIfPresent(Bool.self, forKey: .signedOut) ?? false
    }

    /// Oturum var mı (erişim ya da yenileme anahtarı)
    public var isSignedIn: Bool { refreshToken != nil || accessToken != nil }
    /// Şube seçilmiş, oturum açık ve ilk karar verilmiş: düzenli eşitleme çalışabilir
    public var isActive: Bool { config?.workspaceID != nil && isSignedIn && initialized && !signedOut }

    /// Yerel değişikliklerde uygulanan rol: bu Mac bir şubeyle eşleşmişse (oturum kapalı olsa da) o şubedeki rol.
    /// Eşleşme yoksa nil (her şey serbest).
    public var enforcedRole: String? { config?.workspaceID != nil && initialized ? config?.role : nil }

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

    /// Şube eşleşmesini sıfırlar (şube değişince); bağlantı ayarları kalır
    public mutating func resetWorkspaceData() {
        lastRev = 0; base = [:]; dirty = []; initialized = false; lastSyncAt = nil; signedOut = false
    }

    /// Çıkış: oturum anahtarları silinir; şube eşleşmesi (şube, rol, taban, bekleyen değişiklikler) korunur. Yeniden
    /// girişte aynı şube seçilirse kaldığı yerden (3 yollu birleştirmeyle) devam edilir; web panelinde arada yapılan
    /// değişiklikler bu Mac'in eski haliyle ezilmez.
    public mutating func signOut() {
        store(nil)
        userEmail = nil
        signedOut = true
    }

    /// Girişte kullanılacak durum. Aynı sunucudaysa şube eşleşmesi korunur (hesap farklı olsa da): şube listesi
    /// gelip şube yeniden seçilene kadar eşitleme bekler (`signedOut`). Farklı sunucuda yeni durum başlar.
    public static func forSignIn(existing: SyncState, url: String, publishableKey: String, email: String) -> SyncState {
        guard let c = existing.config, c.url == url else {
            return SyncState(config: CloudConfig(url: url, publishableKey: publishableKey, email: email))
        }
        var s = existing
        s.config?.publishableKey = publishableKey
        s.config?.email = email
        s.signedOut = c.workspaceID != nil
        return s
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

extension AppSettings {
    /// "Sayımı yapan" adını hızlı seçim listesine (Ayarlar > Sayım yapanlar) ekler. Personel hesabıyla ayarlar
    /// yazılamadığından eklenmez (web: saveDayNote ile aynı); yoksa her yeni ad reddedilen bir ayar yazması olurdu.
    /// - Returns: güncellenmiş ayarlar; değişiklik yoksa nil
    public func rememberingStaff(_ name: String, role: String?) -> AppSettings? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CloudRole.canWriteCatalog(role), !n.isEmpty, !staff.contains(n) else { return nil }
        var s = self
        s.staff.append(n)
        return s
    }
}

/// Eşitlemenin diske yazılma sırası: yerel veri değiştiyse önce veri dosyası, sonra eşitleme durumu (esitleme.json).
/// Ters sırada bir çökme / zorla kapatma, tabanı ilerlemiş durumu eski veriyle bırakırdı: yeniden açılışta eski belgeler
/// "değişmiş" sanılıp güncel tabanla (çakışmasız) gönderilir, web panelindeki değişiklik ezilirdi. Veri yazılamazsa
/// durum da yazılmaz (yeni veri + eski taban güvenlidir: gönderim çakışır ve merge3 ile birleşir).
public enum SyncCheckpoint {
    /// - Returns: durum yazıldı mı
    @discardableResult
    public static func persist(dataChanged: Bool, writeData: () -> Bool, writeState: () -> Void) -> Bool {
        if dataChanged && !writeData() { return false }
        writeState()
        return true
    }
}

/// Veri dosyası ve eşitleme durumu (esitleme.json) için ortak seri yazma kuyruğu. Mac uygulamasında yerel kayıtlar,
/// eşitlemenin kayıt noktaları (`SyncCheckpoint`) ve durum kayıtları hep bu kuyruktan geçer: kodlama ve yazma ana iş
/// parçacığını (arayüzü) bekletmez, sıra yine korunur. Kayıt noktasında önce veri, sonra durum yazılır (veri yazılamazsa
/// durum yazılmaz); sonradan kuyruğa giren durum kaydı, kayıt noktasının verisinden önce diske ulaşamaz. (Durum ayrı bir
/// kuyrukta yazılsaydı tabanı ilerlemiş durum, bekleyen veri yazmasının önüne geçip çökme penceresini yeniden açardı.)
public final class DiskWriteQueue: @unchecked Sendable {
    private let queue: DispatchQueue

    public init(label: String, qos: DispatchQoS = .utility) {
        queue = DispatchQueue(label: label, qos: qos)
    }

    /// Arka planda, kuyruğa giriş sırasıyla
    public func async(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }

    /// Kuyruktakiler bittikten sonra eşzamanlı (uygulama kapanırken; testlerde kuyruğu beklemek için)
    public func sync<T>(_ work: () throws -> T) rethrows -> T {
        try queue.sync(execute: work)
    }

    /// Kayıt noktası (`SyncCheckpoint.persist` sırasıyla), arka planda: `writeData` verildiyse önce o çalışır ve false
    /// dönerse durum yazılmaz; `writeData` nil ise (yerel veri değişmedi) yalnızca durum yazılır.
    /// `completion` kuyrukta çağrılır: durum yazıldı mı.
    public func checkpoint(writeData: (@Sendable () -> Bool)?, writeState: @escaping @Sendable () -> Void,
                           completion: (@Sendable (_ stateWritten: Bool) -> Void)? = nil) {
        queue.async {
            let written = SyncCheckpoint.persist(dataChanged: writeData != nil, writeData: { writeData?() ?? true },
                                                 writeState: writeState)
            completion?(written)
        }
    }
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

    /// Kullanıcıya gösterilen ad: "Stok kalemleri", … gün belgesinde tarih (dd.MM.yyyy)
    public static func title(_ key: String) -> String {
        switch key {
        case items: return "Stok kalemleri"
        case products: return "Reçeteler"
        case settings: return "Ayarlar"
        case employees: return "Personel"
        case orders: return "Siparişler"
        default: return date(of: key).map { DateKey.short($0) } ?? key
        }
    }

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

    /// Geri alma: `old` → `new` işlemini, işlemden sonra gelen başka değişiklikleri (`current`; ör. web panelinden
    /// aynı günde düzeltilen başka bir kalem ya da not) koruyarak geri alır. Her belge için
    /// merge3(taban = new, yerel = current, uzak = old): işlemin değiştirdiği alanlar eski haline döner, sonradan
    /// değişen alanlar korunur (ikisi de değiştiyse sonradan gelen kalır). Belge işlemden sonra hiç değişmediyse
    /// birebir eski hali gelir (sıra dahil). Yineleme de aynı yoldan geçer.
    public static func undoing(keys: Set<String>, old: AppData, new: AppData, current: AppData) -> AppData {
        var out = current
        for k in keys {
            let n = body(for: k, in: new), c = body(for: k, in: current)
            if n == c {
                out = replacing([k], in: out, from: old)
                continue
            }
            let merged = JSONMerge.merge3(base: n, local: c, remote: body(for: k, in: old))
            if merged == c { continue }
            if !apply(key: k, body: merged, to: &out) { out = replacing([k], in: out, from: old) }
        }
        return out
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
