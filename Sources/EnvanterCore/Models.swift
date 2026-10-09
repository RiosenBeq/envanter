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

    public init(id: String, name: String, unit: String, recipeUnit: String, factor: Double, active: Bool = true) {
        self.id = id; self.name = name; self.unit = unit
        self.recipeUnit = recipeUnit; self.factor = factor; self.active = active
    }

    public var isKg: Bool { unit.lowercased() == "kg" }
    /// Ekranda gösterilecek en fazla ondalık basamak
    public var maxFraction: Int { isKg ? 3 : 2 }
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

    public init(date: String, entries: [String: DayEntry] = [:], sales: [SaleLine] = [],
                salesSource: String? = nil, salesPeriod: String? = nil, salesImportedAt: Date? = nil,
                legacySold: [String: Double]? = nil, legacyWaste: [String: Double]? = nil, importedFrom: String? = nil) {
        self.date = date; self.entries = entries; self.sales = sales
        self.salesSource = salesSource; self.salesPeriod = salesPeriod; self.salesImportedAt = salesImportedAt
        self.legacySold = legacySold; self.legacyWaste = legacyWaste; self.importedFrom = importedFrom
    }

    /// Satış dökümü yok ama Excel'den gelen Satılan/Zaiyat değerleri var
    public var usesLegacySales: Bool {
        sales.isEmpty && !((legacySold ?? [:]).isEmpty && (legacyWaste ?? [:]).isEmpty)
    }

    public var isEmpty: Bool {
        sales.isEmpty && entries.values.allSatisfy { $0.isEmpty }
            && (legacySold ?? [:]).isEmpty && (legacyWaste ?? [:]).isEmpty
    }
}

public struct AppData: Codable {
    public static let currentSchema = 1
    public var schemaVersion: Int
    public var items: [Item]
    public var products: [Product]
    public var days: [String: DayRecord]

    public init(schemaVersion: Int = AppData.currentSchema, items: [Item], products: [Product], days: [String: DayRecord] = [:]) {
        self.schemaVersion = schemaVersion; self.items = items; self.products = products; self.days = days
    }

    /// İlk açılışta kullanılan varsayılan reçeteler ve stok kalemleri.
    public static func seeded() -> AppData {
        struct Seed: Decodable { var items: [Item]; var products: [Product] }
        let seed = try! JSONDecoder().decode(Seed.self, from: Data(SeedData.json.utf8))
        return AppData(items: seed.items, products: seed.products)
    }
}
