import Foundation

/// Stok kalemi (Excel'deki "Envanter" sayfasının bir satırı): 90 Gr, Peynir, Patates ...
public struct Item: Codable, Identifiable, Hashable {
    public var id: String
    public var name: String
    /// Envanterde sayılan birim: "Adet" veya "Kg"
    public var unit: String
    /// Reçetede kullanılan birim ("adet", "dilim", "kg" ...)
    public var recipeUnit: String
    /// 1 reçete birimi kaç envanter birimi eder (ör. 1 dilim peynir = 0,014 kg)
    public var factor: Double
    public var active: Bool
    /// Kritik stok seviyesi (envanter birimi). Kapanış bunun altına düşerse uyarı verilir,
    /// sipariş önerisinde emniyet stoğu olarak kullanılır.
    public var minStock: Double?
    /// Kabul edilebilir fark (envanter birimi, ±). Bu kadarlık fark "normal" sayılır.
    public var tolerance: Double?

    public init(id: String, name: String, unit: String, recipeUnit: String, factor: Double, active: Bool = true,
                minStock: Double? = nil, tolerance: Double? = nil) {
        self.id = id; self.name = name; self.unit = unit
        self.recipeUnit = recipeUnit; self.factor = factor; self.active = active
        self.minStock = minStock; self.tolerance = tolerance
    }

    public var isKg: Bool { unit.lowercased() == "kg" }
    /// Ekranda gösterilecek en fazla ondalık basamak
    public var maxFraction: Int { isKg ? 3 : 2 }

    /// Bir farkın değerlendirmesi (tolerans ve gösterim hassasiyeti dikkate alınır).
    public func severity(of diff: Double) -> DiffSeverity {
        let eps = 0.5 / pow(10.0, Double(maxFraction))
        if abs(diff) < eps { return .zero }
        if abs(diff) <= max(tolerance ?? 0, 0) + eps { return .withinTolerance }
        return diff < 0 ? .shortage : .surplus
    }

    /// Kapanış kritik seviyenin altında mı?
    public func isBelowMinimum(_ closing: Double?) -> Bool {
        guard let closing, let minStock, minStock > 0 else { return false }
        return closing < minStock
    }
}

// MARK: - Ekip

/// Ekip üyesi (eleman). Giriş hesabıyla bağlanabilir (`account`); sayımı yapan kişi seçiminde (Sayan) aktif üyelerin
/// adları gösterilir (`Team.counterNames`).
public struct Employee: Codable, Identifiable, Hashable {
    public var id: String
    public var name: String
    /// Görev: Müdür, Usta, Kasiyer, Kurye ...
    public var role: String
    public var phone: String?
    /// Ekip listesinde ve Sayan seçiminde görünür
    public var active: Bool
    /// İşe giriş / çıkış (yyyy-MM-dd)
    public var startDate: String?
    public var endDate: String?
    public var note: String?
    /// Bağlı giriş hesabının e-postası (kullanıcı adıyla açılanlarda <ad>@envanter.local)
    public var account: String?

    public init(id: String = UUID().uuidString, name: String, role: String = "", phone: String? = nil, active: Bool = true,
                startDate: String? = nil, endDate: String? = nil, note: String? = nil, account: String? = nil) {
        self.id = id; self.name = name; self.role = role; self.phone = phone; self.active = active
        self.startDate = startDate; self.endDate = endDate; self.note = note; self.account = account
    }

    enum CodingKeys: String, CodingKey { case id, name, role, phone, active, startDate, endDate, note, account }

    // Eksik alanlar varsayılanla doldurulur; eski sürümlerin ücret alanları (payType, rate, …) yok sayılır
    // (yerel yedekler hoşgörülü okumadan geçmez)
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? ""
        phone = try c.decodeIfPresent(String.self, forKey: .phone)
        active = try c.decodeIfPresent(Bool.self, forKey: .active) ?? true
        startDate = try c.decodeIfPresent(String.self, forKey: .startDate)
        endDate = try c.decodeIfPresent(String.self, forKey: .endDate)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        account = try c.decodeIfPresent(String.self, forKey: .account)
    }

    /// O gün işte kayıtlı mı (giriş/çıkış tarihlerine göre)
    public func isEmployed(on date: String) -> Bool {
        if let s = startDate, date < s { return false }
        if let e = endDate, date > e { return false }
        return true
    }
}

// MARK: - Satın alma siparişi

public enum OrderStatus: String, Codable {
    case open, received, cancelled
    public var title: String {
        switch self {
        case .open: return "Bekliyor"
        case .received: return "Teslim alındı"
        case .cancelled: return "İptal"
        }
    }
}

public struct OrderLine: Codable, Hashable, Identifiable {
    public var itemID: String
    /// Sipariş edilen miktar (envanter birimi)
    public var qty: Double
    /// Teslim alınan miktar
    public var received: Double?
    public var id: String { itemID }
    public init(itemID: String, qty: Double, received: Double? = nil) {
        self.itemID = itemID; self.qty = qty; self.received = received
    }
}

public struct PurchaseOrder: Codable, Hashable, Identifiable {
    public var id: String
    /// Siparişin verildiği gün
    public var date: String
    public var supplier: String
    public var lines: [OrderLine]
    public var status: OrderStatus
    public var receivedOn: String?
    public var note: String?

    public init(id: String = UUID().uuidString, date: String, supplier: String = "", lines: [OrderLine],
                status: OrderStatus = .open, receivedOn: String? = nil, note: String? = nil) {
        self.id = id; self.date = date; self.supplier = supplier; self.lines = lines
        self.status = status; self.receivedOn = receivedOn; self.note = note
    }
}

/// Fark değerlendirmesi
public enum DiffSeverity: Equatable {
    /// Fark yok
    case zero
    /// Tolerans içinde (normal sayılır)
    case withinTolerance
    /// Satışlara göre beklenenden FAZLA stok çıkmış (kayıp / fire)
    case shortage
    /// Satışlara göre beklenenden AZ stok çıkmış (sayım veya reçete hatası olabilir)
    case surplus

    public var isProblem: Bool { self == .shortage || self == .surplus }
}

public enum Category {
    public static let waste = "ZAYİLER"
    public static let standard = [
        "BURGERLER", "MENÜLER", "ÖZEL MENÜLER-KAMPANYALAR", "TAVUK YİYELİM", "YAN ÜRÜNLER", "EXTRALAR",
        "İÇECEKLER", "SICAK İÇECEKLER", "TATLILAR", "DONDURMALAR", "SOSLAR", "EKMEK", "ZAYİLER", "DİĞER",
    ]
}

/// ModPos'taki bir satış ürünü ve 1 adetinin hangi stok kaleminden ne kadar tükettiği (reçete).
public struct Product: Codable, Identifiable, Hashable {
    public var code: String
    public var name: String
    public var category: String
    /// stok kalemi id -> 1 adet satışta tüketilen miktar (reçete birimiyle)
    public var amounts: [String: Double]
    public var note: String?

    public var id: String { code }
    public var isWaste: Bool { category == Category.waste }
    public var isTracked: Bool { amounts.values.contains { $0 != 0 } }

    public init(code: String, name: String, category: String, amounts: [String: Double] = [:], note: String? = nil) {
        self.code = code; self.name = name; self.category = category
        self.amounts = amounts; self.note = note
    }
}

public struct SaleLine: Codable, Hashable, Identifiable {
    public var code: String
    public var name: String
    public var qty: Double
    public var id: String { code }

    public init(code: String, name: String, qty: Double) {
        self.code = code; self.name = name; self.qty = qty
    }
}

/// Bir günde, bir stok kalemi için elle girilen değerler.
public struct DayEntry: Codable, Hashable {
    /// Elle girilmişse açılış; boşsa önceki günün kapanışı kullanılır.
    public var opening: Double?
    public var incoming: Double?
    public var transferIn: Double?
    public var transferOut: Double?
    public var closing: Double?

    public init(opening: Double? = nil, incoming: Double? = nil, transferIn: Double? = nil,
                transferOut: Double? = nil, closing: Double? = nil) {
        self.opening = opening; self.incoming = incoming; self.transferIn = transferIn
        self.transferOut = transferOut; self.closing = closing
    }

    public var isEmpty: Bool {
        opening == nil && incoming == nil && transferIn == nil && transferOut == nil && closing == nil
    }
}

public struct DayRecord: Codable, Hashable {
    /// yyyy-MM-dd
    public var date: String
    public var entries: [String: DayEntry]
    public var sales: [SaleLine]
    public var salesSource: String?
    public var salesPeriod: String?
    public var salesImportedAt: Date?
    /// Excel'den aktarılan geçmiş günlerde satış dökümü yoktur; Excel'in hesapladığı Satılan/Zaiyat değerleri burada tutulur.
    /// Günün satış dökümü sonradan aktarılırsa bu değerler yerine döküm kullanılır.
    public var legacySold: [String: Double]?
    public var legacyWaste: [String: Double]?
    /// Verinin geldiği Excel dosyası (varsa)
    public var importedFrom: String?
    /// Günün notu (ör. "Dondurucu arızası, 3 kg patates atıldı")
    public var note: String?
    /// Sayımı yapan kişi
    public var countedBy: String?
    /// Gün kapatıldı: girişler kilitli, yanlışlıkla değiştirilemez
    public var locked: Bool?

    public init(date: String, entries: [String: DayEntry] = [:], sales: [SaleLine] = [],
                salesSource: String? = nil, salesPeriod: String? = nil, salesImportedAt: Date? = nil,
                legacySold: [String: Double]? = nil, legacyWaste: [String: Double]? = nil, importedFrom: String? = nil,
                note: String? = nil, countedBy: String? = nil, locked: Bool? = nil) {
        self.date = date; self.entries = entries; self.sales = sales
        self.salesSource = salesSource; self.salesPeriod = salesPeriod; self.salesImportedAt = salesImportedAt
        self.legacySold = legacySold; self.legacyWaste = legacyWaste; self.importedFrom = importedFrom
        self.note = note; self.countedBy = countedBy; self.locked = locked
    }

    public var isLocked: Bool { locked == true }

    /// Satış dökümü yok ama Excel'den gelen Satılan/Zaiyat değerleri var
    public var usesLegacySales: Bool {
        sales.isEmpty && !((legacySold ?? [:]).isEmpty && (legacyWaste ?? [:]).isEmpty)
    }

    /// Satış verisi (döküm veya Excel'den gelen) var mı
    public var hasSalesData: Bool { !sales.isEmpty || usesLegacySales }

    public var isEmpty: Bool {
        !hasInventoryData && (note ?? "").isEmpty && (countedBy ?? "").isEmpty
    }

    /// Sayım veya satış verisi var mı (not/sayan hariç). Excel aktarımında çakışma buna göre belirlenir.
    public var hasInventoryData: Bool {
        !sales.isEmpty || !entries.values.allSatisfy { $0.isEmpty }
            || !(legacySold ?? [:]).isEmpty || !(legacyWaste ?? [:]).isEmpty
    }
}

/// İşletmeye özel ayarlar
public struct AppSettings: Codable, Hashable {
    /// Şube / işletme adı: ekranda, dışa aktarılan dosya adlarında ve raporlarda görünür
    public var branchName: String
    /// Sipariş önerisi: ortalama tüketimin hesaplanacağı geçmiş gün sayısı
    public var orderLookbackDays: Int
    /// Sipariş önerisi: siparişin kaç günlük ihtiyacı karşılayacağı
    public var orderCoverDays: Double
    /// Eski sürümlerin sayım yapan kişi listesi; Ekip'e taşınır (`Team.migrateLegacyStaff`), sonra boş kalır
    public var staff: [String]

    public init(branchName: String = "", orderLookbackDays: Int = 14, orderCoverDays: Double = 3, staff: [String] = []) {
        self.branchName = branchName; self.orderLookbackDays = orderLookbackDays
        self.orderCoverDays = orderCoverDays; self.staff = staff
    }

    enum CodingKeys: String, CodingKey {
        case branchName, orderLookbackDays, orderCoverDays, staff
    }

    // Eksik alanlar varsayılanla doldurulur (eski / yeni sürümler arasında uyumluluk)
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        branchName = try c.decodeIfPresent(String.self, forKey: .branchName) ?? d.branchName
        orderLookbackDays = try c.decodeIfPresent(Int.self, forKey: .orderLookbackDays) ?? d.orderLookbackDays
        orderCoverDays = try c.decodeIfPresent(Double.self, forKey: .orderCoverDays) ?? d.orderCoverDays
        staff = try c.decodeIfPresent([String].self, forKey: .staff) ?? d.staff
    }
}

public struct AppData: Codable {
    public static let currentSchema = 1
    public var schemaVersion: Int
    public var items: [Item]
    public var products: [Product]
    public var days: [String: DayRecord]
    public var settings: AppSettings
    public var employees: [Employee]
    public var purchaseOrders: [PurchaseOrder]

    public init(schemaVersion: Int = AppData.currentSchema, items: [Item], products: [Product],
                days: [String: DayRecord] = [:], settings: AppSettings = AppSettings(),
                employees: [Employee] = [], purchaseOrders: [PurchaseOrder] = []) {
        self.schemaVersion = schemaVersion; self.items = items; self.products = products
        self.days = days; self.settings = settings; self.employees = employees; self.purchaseOrders = purchaseOrders
    }

    enum CodingKeys: String, CodingKey { case schemaVersion, items, products, days, settings, employees, purchaseOrders }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? AppData.currentSchema
        items = try c.decode([Item].self, forKey: .items)
        products = try c.decode([Product].self, forKey: .products)
        days = try c.decodeIfPresent([String: DayRecord].self, forKey: .days) ?? [:]
        settings = try c.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
        employees = try c.decodeIfPresent([Employee].self, forKey: .employees) ?? []
        purchaseOrders = try c.decodeIfPresent([PurchaseOrder].self, forKey: .purchaseOrders) ?? []
    }

    /// İlk açılışta kullanılan varsayılan reçeteler ve stok kalemleri.
    public static func seeded() -> AppData {
        struct Seed: Decodable { var items: [Item]; var products: [Product] }
        let seed = try! JSONDecoder().decode(Seed.self, from: Data(SeedData.json.utf8))
        return AppData(items: seed.items, products: seed.products)
    }
}

// Değer tipleri iş parçacıkları arasında güvenle taşınır (arka planda kayıt için)
extension Item: Sendable {}
extension Employee: Sendable {}
extension OrderStatus: Sendable {}
extension OrderLine: Sendable {}
extension PurchaseOrder: Sendable {}
extension Product: Sendable {}
extension SaleLine: Sendable {}
extension DayEntry: Sendable {}
extension DayRecord: Sendable {}
extension AppSettings: Sendable {}
extension AppData: Sendable {}
