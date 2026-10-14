import Foundation

/// Stok kalemi işlemlerinin saf (Linux'ta test edilen) kuralları: silme, yeni kimlik, ad denetimi, birim ve katsayı
/// değişikliğinin etkisi. AppStore ve web (`src/lib/catalog.ts`) aynı kuralı kullanır; ortak vektörler
/// `Fixtures/catalog-vectors.json` (docs/SYNC.md §1 "Stok kalemleri").
public enum CatalogOps {
    private static let tr = Locale(identifier: "tr_TR")

    // MARK: - Silme

    public struct DeleteResult {
        public var data: AppData
        /// Reçetesinden kalemin miktarı çıkarılan ürün sayısı
        public var products: Int
        /// Kaydı silinen (açık) gün sayısı
        public var days: Int
        /// Kapatılmış olduğu için kaydı olduğu gibi kalan gün sayısı
        public var keptLockedDays: Int
    }

    /// Kalemin bu günde kaydı (sayım, Excel'den gelen satılan / zayi) var mı
    static func dayMentions(_ day: DayRecord, _ id: String) -> Bool {
        day.entries[id] != nil || day.legacySold?[id] != nil || day.legacyWaste?[id] != nil
    }

    /// Kalemi siler: reçetelerdeki miktarları ve açık günlerdeki kayıtları da kaldırır; boşalan açık gün silinir.
    /// Kapatılmış günlere hiç dokunulmaz (kayıtları olduğu gibi kalır; kalem olmadığından hesaba girmez).
    public static func deleteItem(_ id: String, in data: AppData) -> DeleteResult {
        var d = data
        d.items.removeAll { $0.id == id }
        var products = 0
        for i in d.products.indices where d.products[i].amounts[id] != nil {
            d.products[i].amounts[id] = nil
            products += 1
        }
        var removed = 0, kept = 0
        for (k, day) in data.days where dayMentions(day, id) {
            if day.isLocked { kept += 1; continue }
            var next = day
            next.entries[id] = nil
            next.legacySold?[id] = nil
            next.legacyWaste?[id] = nil
            d.days[k] = next.isEmpty ? nil : next
            removed += 1
        }
        return DeleteResult(data: d, products: products, days: removed, keptLockedDays: kept)
    }

    // MARK: - Kimlik ve ad

    /// Bir kalem kimliği olarak kullanılmış (ya da hâlâ geçen) kimlikler: kalemler, reçete miktarları, günlerin kayıtları
    /// (kapatılmış günlerde silinen kalemlerinkiler dahil) ve sipariş satırları. Yeni kalem bunlardan birini alırsa silinmiş
    /// bir kalemin eski kayıtlarını devralırdı.
    public static func reservedItemIDs(_ data: AppData) -> Set<String> {
        var ids = Set(data.items.map { $0.id })
        for p in data.products { ids.formUnion(p.amounts.keys) }
        for day in data.days.values {
            ids.formUnion(day.entries.keys)
            ids.formUnion((day.legacySold ?? [:]).keys)
            ids.formUnion((day.legacyWaste ?? [:]).keys)
        }
        for o in data.purchaseOrders { ids.formUnion(o.lines.map { $0.itemID }) }
        return ids
    }

    /// Addan kimlik tabanı: Türkçe küçük harf, yalnızca harf ve rakam ("Soğan Halkası" → "soğanhalkası"); boşsa "kalem"
    public static func idBase(_ name: String) -> String {
        let base = String(name.lowercased(with: tr).filter { $0.isLetter || $0.isNumber })
        return base.isEmpty ? "kalem" : base
    }

    /// Yeni kalemin kimliği: taban kullanılmışsa (`reservedItemIDs`) "…2", "…3"
    public static func newItemID(name: String, data: AppData) -> String {
        let base = idBase(name)
        let taken = reservedItemIDs(data)
        var id = base, n = 2
        while taken.contains(id) { id = "\(base)\(n)"; n += 1 }
        return id
    }

    /// Aynı adlı (boşluklar kırpılmış, Türkçe büyük/küçük harf duyarsız) kalem var mı; `except` kimlikli kalem sayılmaz
    public static func hasItemNamed(_ name: String, in items: [Item], except: String? = nil) -> Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(with: tr)
        return items.contains { $0.id != except && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(with: tr) == n }
    }

    /// Aynı adlı kalem uyarısı (web bildirimiyle aynı)
    public static let duplicateTitle = "Bu adla bir kalem zaten var"

    public static func duplicateMessage(_ name: String) -> String {
        "“\(name.trimmingCharacters(in: .whitespacesAndNewlines))” adı başka bir kalemde kullanılıyor."
    }

    /// Ad ve birim seçilerek eklenen yeni kalem (reçete birimi kg / adet, katsayı 1, aktif)
    public static func newItem(name: String, unit: String, data: AppData) -> Item {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return Item(id: newItemID(name: n, data: data), name: n, unit: unit, recipeUnit: unit == "Kg" ? "kg" : "adet", factor: 1)
    }

    // MARK: - Geçmiş (silme, birim ve katsayı onayı)

    /// Kalemin kullanıldığı yerler
    public struct ItemHistory: Equatable {
        /// Kaydı olan gün sayısı (kapatılmışlar dahil)
        public var days: Int
        /// Bunlardan kapatılmış olanlar
        public var lockedDays: Int
        /// Silmede miktarı çıkarılacak ürün sayısı (reçetede anahtarı olan)
        public var products: Int
        /// Kalemi kullanan (miktarı sıfırdan farklı) reçete sayısı
        public var recipes: Int
        /// Satırında kalem olan sipariş sayısı
        public var orders: Int
        /// Satış raporunda kalemi kullanan bir ürün olan gün sayısı (katsayı bunların Satılan'ını değiştirir)
        public var salesDays: Int
        /// Bunlardan kapatılmış olanlar
        public var lockedSalesDays: Int

        public init(days: Int = 0, lockedDays: Int = 0, products: Int = 0, recipes: Int = 0, orders: Int = 0,
                    salesDays: Int = 0, lockedSalesDays: Int = 0) {
            self.days = days; self.lockedDays = lockedDays; self.products = products; self.recipes = recipes
            self.orders = orders; self.salesDays = salesDays; self.lockedSalesDays = lockedSalesDays
        }

        /// Silmek yerine "Pasif yap" önerilir: gün kaydı, sipariş satırı ya da reçete kullanımı var
        public var suggestsDeactivate: Bool { days > 0 || orders > 0 || recipes > 0 }
    }

    public static func history(_ id: String, in data: AppData) -> ItemHistory {
        var h = ItemHistory()
        let using = Set(data.products.filter { ($0.amounts[id] ?? 0) != 0 }.map { $0.code })
        h.products = data.products.filter { $0.amounts[id] != nil }.count
        h.recipes = using.count
        h.orders = data.purchaseOrders.filter { o in o.lines.contains { $0.itemID == id } }.count
        for day in data.days.values {
            if dayMentions(day, id) {
                h.days += 1
                if day.isLocked { h.lockedDays += 1 }
            }
            if day.sales.contains(where: { using.contains($0.code) }) {
                h.salesDays += 1
                if day.isLocked { h.lockedSalesDays += 1 }
            }
        }
        return h
    }

    // MARK: - Onay metinleri (web ile aynı)

    /// Kalıcı silme onayı: "Kalem, 34 günün sayım kayıtları ve 12 reçetedeki miktarlarıyla birlikte silinir. Kapatılmış
    /// 20 gündeki kayıtlar olduğu gibi kalır."
    public static func deleteDescription(openDays: Int, products: Int, lockedDays: Int) -> String {
        let head: String
        switch (openDays > 0, products > 0) {
        case (true, true): head = "Kalem, \(openDays) günün sayım kayıtları ve \(products) reçetedeki miktarlarıyla birlikte silinir."
        case (true, false): head = "Kalem, \(openDays) günün sayım kayıtlarıyla birlikte silinir."
        case (false, true): head = "Kalem, \(products) reçetedeki miktarlarıyla birlikte silinir."
        case (false, false): head = "Kalem silinir."
        }
        return lockedDays > 0 ? "\(head) Kapatılmış \(lockedDays) gündeki kayıtlar olduğu gibi kalır." : head
    }

    public static func deleteDescription(_ h: ItemHistory) -> String {
        deleteDescription(openDays: h.days - h.lockedDays, products: h.products, lockedDays: h.lockedDays)
    }

    /// Birim değişikliği onaya bağlı mı: kalemin gün kaydı var
    public static func unitChangeNeedsConfirmation(_ h: ItemHistory) -> Bool { h.days > 0 }

    /// "“Patates” kaleminin 34 günlük sayım kaydı adet olarak girildi; birimi Kg yapmak geçmişi kg olarak okutur."
    /// Kritik seviye ya da tolerans tanımlıysa onların da yeni birimle okunacağı eklenir.
    public static func unitChangeMessage(item: Item, newUnit: String, days: Int) -> String {
        let old = item.unit.lowercased(with: tr), new = newUnit.lowercased(with: tr)
        var s = "“\(item.name)” kaleminin \(days) günlük sayım kaydı \(old) olarak girildi; birimi \(newUnit) yapmak geçmişi \(new) olarak okutur."
        if (item.minStock ?? 0) > 0 || (item.tolerance ?? 0) > 0 { s += " Kritik seviye ve tolerans da \(new) olarak okunur." }
        return s
    }

    /// Katsayı değişikliği onaya bağlı mı: kalemi kullanan ürünlerin satıldığı gün var
    public static func factorChangeNeedsConfirmation(_ h: ItemHistory) -> Bool { h.salesDays > 0 }

    /// "Katsayı 34 günün (kapatılmış 20 gün dahil) Satılan ve Fark değerlerini değiştirir."
    public static func factorChangeMessage(_ h: ItemHistory) -> String {
        let locked = h.lockedSalesDays > 0 ? " (kapatılmış \(h.lockedSalesDays) gün dahil)" : ""
        return "Katsayı \(h.salesDays) günün\(locked) Satılan ve Fark değerlerini değiştirir."
    }

    // MARK: - Yeni birimle yeni kalem

    public struct UnitSplit {
        public var data: AppData
        /// Açılan yeni kalemin kimliği
        public var newID: String
        /// Eski kalemin yeni adı ("Patates (adet)")
        public var oldName: String
    }

    /// "Yeni kalem olarak aç": eski kalem "Patates (adet)" adıyla pasif kalır, sayım geçmişi ona aittir. Hemen ardına aynı
    /// adla, yeni birimle yeni kalem açılır (reçete birimi ve katsayı eskisinden; kritik seviye ve tolerans yok). Reçetelerdeki
    /// miktarlar yeni kaleme taşınır: katsayının yeni birime göre girilmesi gerekir. Kalem yoksa ya da birim aynıysa nil.
    public static func splitForUnit(_ id: String, unit: String, in data: AppData) -> UnitSplit? {
        guard let i = data.items.firstIndex(where: { $0.id == id }), data.items[i].unit != unit else { return nil }
        var d = data
        let old = d.items[i]
        let base = "\(old.name) (\(old.unit.lowercased(with: tr)))"
        var oldName = base, n = 2
        while hasItemNamed(oldName, in: d.items, except: old.id) { oldName = "\(base) \(n)"; n += 1 }
        let newID = newItemID(name: old.name, data: d)
        d.items[i].name = oldName
        d.items[i].active = false
        d.items.insert(Item(id: newID, name: old.name, unit: unit, recipeUnit: old.recipeUnit, factor: old.factor), at: i + 1)
        for p in d.products.indices {
            guard let amount = d.products[p].amounts[id] else { continue }
            d.products[p].amounts[id] = nil
            d.products[p].amounts[newID] = amount
        }
        return UnitSplit(data: d, newID: newID, oldName: oldName)
    }

    /// "Yeni kalem olarak aç"ın sonucu: "“Patates” kg olarak yeni kalem açıldı; eski kayıtlar “Patates (adet)” adıyla pasif
    /// kaldı. Reçetelerdeki miktarlar yeni kaleme taşındı: katsayıyı (1 adet kaç kg) kontrol edin."
    public static func splitMessage(name: String, unit: String, oldName: String, recipeUnit: String, movedRecipes: Int) -> String {
        let u = unit.lowercased(with: tr)
        var s = "“\(name)” \(u) olarak yeni kalem açıldı; eski kayıtlar “\(oldName)” adıyla pasif kaldı."
        if movedRecipes > 0 {
            s += " \(movedRecipes) reçetedeki miktar yeni kaleme taşındı: katsayıyı (1 \(recipeUnit) kaç \(u)) kontrol edin."
        }
        return s
    }
}
