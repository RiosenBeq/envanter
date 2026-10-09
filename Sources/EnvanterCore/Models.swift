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
    /// Birim maliyet (₺ / envanter birimi). Tanımlıysa farkın parasal karşılığı hesaplanır.
    public var unitCost: Double?
    /// Kritik stok seviyesi (envanter birimi). Kapanış bunun altına düşerse uyarı verilir,
    /// sipariş önerisinde emniyet stoğu olarak kullanılır.
    public var minStock: Double?
    /// Kabul edilebilir fark (envanter birimi, ±). Bu kadarlık fark "normal" sayılır.
    public var tolerance: Double?
    /// Birim maliyet geçmişi (eskiden yeniye). Maliyet değiştikçe eklenir; fiyat artışı uyarıları için.
    public var costHistory: [PricePoint]?

    public init(id: String, name: String, unit: String, recipeUnit: String, factor: Double, active: Bool = true,
                unitCost: Double? = nil, minStock: Double? = nil, tolerance: Double? = nil, costHistory: [PricePoint]? = nil) {
        self.id = id; self.name = name; self.unit = unit
        self.recipeUnit = recipeUnit; self.factor = factor; self.active = active
        self.unitCost = unitCost; self.minStock = minStock; self.tolerance = tolerance; self.costHistory = costHistory
    }

    /// Birim maliyeti `date` gününden geçerli olarak değiştirir ve geçmişe tarih sırasıyla yazar
    /// (aynı güne ait değişiklikler tek kayıt olur). Daha yeni tarihli bir fiyat zaten varsa (ör. geçmiş tarihli
    /// bir fatura sonradan girildiğinde) güncel maliyet değişmez; fiyat yalnızca geçmişe işlenir.
    /// `nil` maliyeti kaldırır (geçmiş korunur).
    public mutating func setCost(_ cost: Double?, on date: String) {
        guard let cost else { unitCost = nil; return }
        var h = costHistory ?? []
        if h.isEmpty {
            guard cost != unitCost else { return }
            if let old = unitCost { h.append(PricePoint(date: nil, cost: old)) }
        }
        if let i = h.firstIndex(where: { $0.date == date }) {
            h[i].cost = cost
        } else {
            // O gün zaten bu fiyat geçerliyse yeni kayıt açılmaz
            if !h.isEmpty, Self.cost(in: h, on: date) == cost, unitCost != nil { costHistory = h; return }
            let at = h.firstIndex(where: { ($0.date ?? "") > date }) ?? h.count
            h.insert(PricePoint(date: date, cost: cost), at: at)
        }
        costHistory = h
        unitCost = h.last?.cost
    }

    /// `date` gününde geçerli birim maliyet: o güne kadarki son fiyat kaydı (geçmiş yoksa güncel maliyet).
    /// Geçmiş dönemlerin maliyet oranları o günkü fiyatla hesaplansın diye kullanılır.
    public func cost(on date: String) -> Double? {
        guard unitCost != nil, let h = costHistory, !h.isEmpty else { return unitCost }
        return Self.cost(in: h, on: date)
    }

    static func cost(in h: [PricePoint], on date: String) -> Double? {
        if let p = h.last(where: { $0.date.map { $0 <= date } ?? true }) { return p.cost }
        return h.first?.cost
    }

    /// Son fiyat değişimi: önceki ve yeni maliyet, oran (ör. 0,12 = %12 artış)
    public var lastPriceChange: (from: Double, to: Double, ratio: Double, date: String?)? {
        guard let h = costHistory, h.count >= 2 else { return nil }
        let a = h[h.count - 2].cost, b = h[h.count - 1].cost
        guard a > 0 else { return nil }
        return (a, b, (b - a) / a, h[h.count - 1].date)
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

/// Bir maliyet kaydı
public struct PricePoint: Codable, Hashable {
    /// yyyy-MM-dd (bilinmiyorsa nil: geçmiş tutulmadan önceki maliyet)
    public var date: String?
    public var cost: Double
    public init(date: String?, cost: Double) { self.date = date; self.cost = cost }
}

// MARK: - Personel

/// Ücret türü
public enum PayType: String, Codable, CaseIterable, Identifiable {
    /// Aylık maaş: ayın günlerine eşit dağıtılır (çalışılan gün sayısından bağımsız)
    case monthly
    /// Günlük yevmiye: çalıştığı günler için
    case daily
    /// Saatlik ücret: girilen saat kadar
    case hourly

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .monthly: return "Aylık maaş"
        case .daily: return "Günlük yevmiye"
        case .hourly: return "Saatlik ücret"
        }
    }
    public var rateLabel: String {
        switch self {
        case .monthly: return "₺ / ay"
        case .daily: return "₺ / gün"
        case .hourly: return "₺ / saat"
        }
    }
}

/// Personel kaydı
public struct Employee: Codable, Identifiable, Hashable {
    public var id: String
    public var name: String
    /// Görev: Müdür, Usta, Kasiyer, Kurye ...
    public var role: String
    public var payType: PayType
    /// Ücret (ücret türüne göre aylık / günlük / saatlik, ₺)
    public var rate: Double
    /// İşveren maliyet çarpanı: ücrete eklenen yasal yükler vb. için (1 = ek yok, ör. 1,2 = %20 ek)
    public var costFactor: Double
    /// Günlük vardiya listesinde görünür mü
    public var active: Bool
    /// İşe giriş / çıkış (yyyy-MM-dd). Aylık maaş yalnızca bu aralıktaki günlere dağıtılır.
    public var startDate: String?
    public var endDate: String?
    /// Saatlik çalışanlar için varsayılan vardiya süresi (saat)
    public var defaultHours: Double?
    /// Ücret değişiklikleri (tarih sırasıyla). Zam gibi değişiklikler geçmiş günlerin maliyetini değiştirmesin diye
    /// her gün o gün geçerli koşullarla hesaplanır. Boşsa `payType`/`rate`/`costFactor` her gün için geçerlidir.
    public var payHistory: [PayTerms]?

    public init(id: String = UUID().uuidString, name: String, role: String = "", payType: PayType, rate: Double,
                costFactor: Double = 1, active: Bool = true, startDate: String? = nil, endDate: String? = nil,
                defaultHours: Double? = nil, payHistory: [PayTerms]? = nil) {
        self.id = id; self.name = name; self.role = role; self.payType = payType; self.rate = rate
        self.costFactor = costFactor; self.active = active; self.startDate = startDate; self.endDate = endDate
        self.defaultHours = defaultHours; self.payHistory = payHistory
    }

    /// O gün işte kayıtlı mı (giriş/çıkış tarihlerine göre)
    public func isEmployed(on date: String) -> Bool {
        if let s = startDate, date < s { return false }
        if let e = endDate, date > e { return false }
        return true
    }

    /// `date` gününde geçerli ücret koşulları
    public func terms(on date: String) -> PayTerms {
        let current = PayTerms(from: nil, payType: payType, rate: rate, costFactor: costFactor)
        guard let h = payHistory, !h.isEmpty else { return current }
        return h.last(where: { $0.from.map { $0 <= date } ?? true }) ?? h[0]
    }

    /// Ücret koşullarını değiştirir. `from` verilirse o günden itibaren geçerli olur (önceki günler eski koşullarla
    /// kalır); `nil` ise tüm dönem için düzeltme sayılır ve geçmiş silinir.
    public mutating func setTerms(payType: PayType, rate: Double, costFactor: Double, from date: String?) {
        let new = PayTerms(from: date, payType: payType, rate: rate, costFactor: costFactor)
        if let date {
            var h = payHistory ?? [PayTerms(from: nil, payType: self.payType, rate: self.rate, costFactor: self.costFactor)]
            if let i = h.firstIndex(where: { $0.from == date }) {
                h[i] = new
            } else {
                let at = h.firstIndex(where: { ($0.from ?? "") > date }) ?? h.count
                h.insert(new, at: at)
            }
            // Art arda aynı koşullar tek kayıt olur
            var merged: [PayTerms] = []
            for t in h {
                if let l = merged.last, l.payType == t.payType, l.rate == t.rate, l.costFactor == t.costFactor { continue }
                merged.append(t)
            }
            payHistory = merged.count > 1 ? merged : nil
            let last = merged.last ?? new
            self.payType = last.payType; self.rate = last.rate; self.costFactor = last.costFactor
        } else {
            payHistory = nil
            self.payType = payType; self.rate = rate; self.costFactor = costFactor
        }
    }
}

/// Belirli bir günden itibaren geçerli ücret koşulları
public struct PayTerms: Codable, Hashable {
    /// Geçerlilik başlangıcı (yyyy-MM-dd); nil = kaydın başından beri
    public var from: String?
    public var payType: PayType
    public var rate: Double
    public var costFactor: Double
    public init(from: String?, payType: PayType, rate: Double, costFactor: Double) {
        self.from = from; self.payType = payType; self.rate = rate; self.costFactor = costFactor
    }
}

/// Bir personelin bir günlük vardiyası
public struct ShiftEntry: Codable, Hashable {
    /// Çalışılan saat (saatlik çalışanlar için zorunlu; diğerlerinde bilgi amaçlı)
    public var hours: Double?
    /// Günlük yevmiyeli çalışan o gün çalıştı mı
    public var worked: Bool?
    /// Ek ödeme (mesai, prim, yol/yemek; ₺) — işveren çarpanı uygulanır
    public var extra: Double?

    public init(hours: Double? = nil, worked: Bool? = nil, extra: Double? = nil) {
        self.hours = hours; self.worked = worked; self.extra = extra
    }
    public var isEmpty: Bool { hours == nil && worked == nil && extra == nil }
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
    /// Faturadaki birim fiyat (₺); girilirse kalemin birim maliyeti güncellenir
    public var unitPrice: Double?
    public var id: String { itemID }
    public init(itemID: String, qty: Double, received: Double? = nil, unitPrice: Double? = nil) {
        self.itemID = itemID; self.qty = qty; self.received = received; self.unitPrice = unitPrice
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
    /// Satış tutarı (₺, raporda "Tutar" sütunu varsa). Maliyet yüzdesi ve menü analizi için kullanılır.
    public var amount: Double?
    public var id: String { code }

    public init(code: String, name: String, qty: Double, amount: Double? = nil) {
        self.code = code; self.name = name; self.qty = qty; self.amount = amount
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
    /// Personel id -> günün vardiyası
    public var shifts: [String: ShiftEntry]?
    /// Kayıtlı personel dışındaki günlük personel gideri (ek eleman, dışarıdan kurye ...; ₺)
    public var otherLabor: Double?

    public init(date: String, entries: [String: DayEntry] = [:], sales: [SaleLine] = [],
                salesSource: String? = nil, salesPeriod: String? = nil, salesImportedAt: Date? = nil,
                legacySold: [String: Double]? = nil, legacyWaste: [String: Double]? = nil, importedFrom: String? = nil,
                note: String? = nil, countedBy: String? = nil, locked: Bool? = nil,
                shifts: [String: ShiftEntry]? = nil, otherLabor: Double? = nil) {
        self.date = date; self.entries = entries; self.sales = sales
        self.salesSource = salesSource; self.salesPeriod = salesPeriod; self.salesImportedAt = salesImportedAt
        self.legacySold = legacySold; self.legacyWaste = legacyWaste; self.importedFrom = importedFrom
        self.note = note; self.countedBy = countedBy; self.locked = locked
        self.shifts = shifts; self.otherLabor = otherLabor
    }

    public var isLocked: Bool { locked == true }

    /// Satış dökümü yok ama Excel'den gelen Satılan/Zaiyat değerleri var
    public var usesLegacySales: Bool {
        sales.isEmpty && !((legacySold ?? [:]).isEmpty && (legacyWaste ?? [:]).isEmpty)
    }

    /// Satış verisi (döküm veya Excel'den gelen) var mı
    public var hasSalesData: Bool { !sales.isEmpty || usesLegacySales }

    /// Günün satış tutarı (raporda tutar sütunu yoksa nil)
    public var salesRevenue: Double? {
        let amounts = sales.compactMap { $0.amount }
        return amounts.isEmpty ? nil : amounts.reduce(0, +)
    }

    public var isEmpty: Bool {
        !hasInventoryData
            && (note ?? "").isEmpty && (countedBy ?? "").isEmpty
            && (shifts ?? [:]).values.allSatisfy { $0.isEmpty } && (otherLabor ?? 0) == 0
    }

    /// Sayım veya satış verisi var mı (personel/not hariç). Excel aktarımında çakışma buna göre belirlenir.
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
    /// Sayımı yapan kişiler (hızlı seçim için)
    public var staff: [String]
    /// Hedefler (satışa oran, 0–1): hammadde maliyeti, personel maliyeti, prime cost (ikisinin toplamı)
    public var targetFoodCostPct: Double?
    public var targetLaborPct: Double?
    public var targetPrimeCostPct: Double?
    /// Birim maliyet bu orandan fazla artarsa uyarı (ör. 0,05 = %5)
    public var priceAlertPct: Double

    public init(branchName: String = "", orderLookbackDays: Int = 14, orderCoverDays: Double = 3, staff: [String] = [],
                targetFoodCostPct: Double? = nil, targetLaborPct: Double? = nil, targetPrimeCostPct: Double? = nil,
                priceAlertPct: Double = 0.05) {
        self.branchName = branchName; self.orderLookbackDays = orderLookbackDays
        self.orderCoverDays = orderCoverDays; self.staff = staff
        self.targetFoodCostPct = targetFoodCostPct; self.targetLaborPct = targetLaborPct
        self.targetPrimeCostPct = targetPrimeCostPct; self.priceAlertPct = priceAlertPct
    }

    enum CodingKeys: String, CodingKey {
        case branchName, orderLookbackDays, orderCoverDays, staff, targetFoodCostPct, targetLaborPct, targetPrimeCostPct, priceAlertPct
    }

    // Eksik alanlar varsayılanla doldurulur (eski / yeni sürümler arasında uyumluluk)
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        branchName = try c.decodeIfPresent(String.self, forKey: .branchName) ?? d.branchName
        orderLookbackDays = try c.decodeIfPresent(Int.self, forKey: .orderLookbackDays) ?? d.orderLookbackDays
        orderCoverDays = try c.decodeIfPresent(Double.self, forKey: .orderCoverDays) ?? d.orderCoverDays
        staff = try c.decodeIfPresent([String].self, forKey: .staff) ?? d.staff
        targetFoodCostPct = try c.decodeIfPresent(Double.self, forKey: .targetFoodCostPct)
        targetLaborPct = try c.decodeIfPresent(Double.self, forKey: .targetLaborPct)
        targetPrimeCostPct = try c.decodeIfPresent(Double.self, forKey: .targetPrimeCostPct)
        priceAlertPct = try c.decodeIfPresent(Double.self, forKey: .priceAlertPct) ?? d.priceAlertPct
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
extension PricePoint: Sendable {}
extension PayType: Sendable {}
extension Employee: Sendable {}
extension PayTerms: Sendable {}
extension ShiftEntry: Sendable {}
extension OrderStatus: Sendable {}
extension OrderLine: Sendable {}
extension PurchaseOrder: Sendable {}
extension Product: Sendable {}
extension SaleLine: Sendable {}
extension DayEntry: Sendable {}
extension DayRecord: Sendable {}
extension AppSettings: Sendable {}
extension AppData: Sendable {}
