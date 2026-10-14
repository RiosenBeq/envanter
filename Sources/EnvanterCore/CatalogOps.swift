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
        var ids = historyItemIDs(data)
        ids.formUnion(data.items.map { $0.id })
        for p in data.products { ids.formUnion(p.amounts.keys) }
        return ids
    }

    /// Kayıtlarda geçen kalem kimlikleri: günlerin (kapatılmışlar dahil) kayıt anahtarları ve sipariş satırları. Bu kimlikle
    /// eklenen kalem bu kayıtları devralırdı.
    public static func historyItemIDs(_ data: AppData) -> Set<String> {
        var ids = Set<String>()
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
        itemNamed(name, in: items, except: except) != nil
    }

    /// Aynı adlı (boşluklar kırpılmış, Türkçe büyük/küçük harf duyarsız) ilk kalem; `except` kimlikli kalem sayılmaz
    public static func itemNamed(_ name: String, in items: [Item], except: String? = nil) -> Item? {
        let n = foldName(name)
        return items.first { $0.id != except && foldName($0.name) == n }
    }

    private static func foldName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(with: tr)
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

    // MARK: - Eksik tanımları ekleme

    public struct MergeResult {
        public var data: AppData
        /// Eklenen stok kalemi sayısı
        public var addedItems: Int
        /// Eklenen reçete sayısı
        public var addedProducts: Int
    }

    /// Eksik tanımları ekler ("Eksik varsayılanları geri ekle"; web'de başka şubeden "Eksikleri ekle"). Kaynağın her kalemi:
    /// hedefte aynı adlı kalem varsa eklenmez, gelen reçetelerde onun yerine hedefteki kullanılır; aynı kimlikli kalem varsa
    /// (adı değiştirilmiş olabilir) eklenmez; kimlik kayıtlarda geçiyorsa (silinmiş kalem, `historyItemIDs`) `newItemID` ile
    /// yeni kimlikle eklenir, gelen reçetelerdeki miktarlar yeni kimliğe taşınır; yoksa olduğu gibi eklenir. Kodu hedefte
    /// olmayan reçeteler sona eklenir (aynı kaleme düşen miktarlar toplanır). Hedefteki kalem ve reçetelere dokunulmaz.
    public static func mergeDefinitions(items: [Item], products: [Product], into data: AppData) -> MergeResult {
        var d = data
        let history = historyItemIDs(data)
        var map: [String: String] = [:]
        var addedItems = 0
        for source in items {
            if let same = itemNamed(source.name, in: d.items) { map[source.id] = same.id; continue }
            if d.items.contains(where: { $0.id == source.id }) { continue }
            var item = source
            if history.contains(source.id) {
                item.id = newItemID(name: source.name, data: d)
                map[source.id] = item.id
            }
            d.items.append(item)
            addedItems += 1
        }
        let codes = Set(d.products.map { $0.code })
        var addedProducts = 0
        for source in products where !codes.contains(source.code) {
            var product = source
            var amounts: [String: Double] = [:]
            for (k, v) in source.amounts {
                let key = map[k] ?? k
                amounts[key] = amounts[key].map { $0 + v } ?? v
            }
            product.amounts = amounts
            d.products.append(product)
            addedProducts += 1
        }
        return MergeResult(data: d, addedItems: addedItems, addedProducts: addedProducts)
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
        /// Bunlardan açık (teslim alınmamış, iptal edilmemiş) olanlar
        public var openOrders: Int
        /// Satış raporunda kalemi kullanan bir ürün olan gün sayısı (katsayı bunların Satılan'ını değiştirir)
        public var salesDays: Int
        /// Bunlardan kapatılmış olanlar
        public var lockedSalesDays: Int

        public init(days: Int = 0, lockedDays: Int = 0, products: Int = 0, recipes: Int = 0, orders: Int = 0,
                    openOrders: Int = 0, salesDays: Int = 0, lockedSalesDays: Int = 0) {
            self.days = days; self.lockedDays = lockedDays; self.products = products; self.recipes = recipes
            self.orders = orders; self.openOrders = openOrders; self.salesDays = salesDays; self.lockedSalesDays = lockedSalesDays
        }

        /// Silmek yerine "Pasif yap" önerilir: gün kaydı, sipariş satırı ya da reçete kullanımı var
        public var suggestsDeactivate: Bool { days > 0 || orders > 0 || recipes > 0 }
    }

    public static func history(_ id: String, in data: AppData) -> ItemHistory {
        var h = ItemHistory()
        let using = Set(data.products.filter { ($0.amounts[id] ?? 0) != 0 }.map { $0.code })
        h.products = data.products.filter { $0.amounts[id] != nil }.count
        h.recipes = using.count
        let orders = data.purchaseOrders.filter { o in o.lines.contains { $0.itemID == id } }
        h.orders = orders.count
        h.openOrders = orders.filter { $0.status == .open }.count
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

    /// "Yeni kalem olarak aç" açık siparişte geçen kalemde yapılmaz: teslimat (Gelen) pasif kalan eski kaleme işlenir,
    /// sayımda ve raporlarda görünmez; yeni kalem için de aynı mal yeniden önerilir.
    public static func splitBlocked(_ h: ItemHistory) -> Bool { h.openOrders > 0 }

    /// Eski kalemin bölünmede alacağı ad: "Patates (adet)", doluysa "Patates (adet) 2", "… 3"
    public static func splitOldName(_ item: Item, in items: [Item]) -> String {
        let base = "\(item.name) (\(item.unit.lowercased(with: tr)))"
        var name = base, n = 2
        while hasItemNamed(name, in: items, except: item.id) { name = "\(base) \(n)"; n += 1 }
        return name
    }

    /// "Yeni kalem olarak aç": eski kalem "Patates (adet)" adıyla pasif kalır, sayım geçmişi ona aittir. Hemen ardına aynı
    /// adla, yeni birimle yeni kalem açılır (reçete birimi ve katsayı eskisinden; kritik seviye ve tolerans yok). Reçetelerdeki
    /// miktarlar yeni kaleme taşınır: katsayının yeni birime göre girilmesi gerekir. Kalem yoksa, birim aynıysa ya da kalem
    /// açık bir siparişte geçiyorsa (`splitBlocked`) nil.
    public static func splitForUnit(_ id: String, unit: String, in data: AppData) -> UnitSplit? {
        guard let i = data.items.firstIndex(where: { $0.id == id }), data.items[i].unit != unit,
              !splitBlocked(history(id, in: data)) else { return nil }
        var d = data
        let old = d.items[i]
        let oldName = splitOldName(old, in: d.items)
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

    /// Birim onayındaki açıklama (işlemden önce): "Yeni kalem olarak açılınca eski kayıtlar “Patates (adet)” adıyla pasif
    /// kalır; sayıma Kg biriminde yeni kalemle devam edilir. 3 reçetedeki miktar yeni kaleme taşınır: katsayıyı (1 adet kaç
    /// kg) yeni birime göre güncelleyin." `oldName`: `splitOldName`.
    public static func splitExplanation(item: Item, newUnit: String, oldName: String, movedRecipes: Int) -> String {
        var s = "Yeni kalem olarak açılınca eski kayıtlar “\(oldName)” adıyla pasif kalır; sayıma \(newUnit) biriminde yeni kalemle devam edilir."
        if movedRecipes > 0 {
            s += " \(movedRecipes) reçetedeki miktar yeni kaleme taşınır: katsayıyı (1 \(item.recipeUnit) kaç \(newUnit.lowercased(with: tr))) yeni birime göre güncelleyin."
        }
        return s
    }

    /// Açık siparişte geçen kalemde "Yeni kalem olarak aç" yerine: "“Patates” 2 açık siparişte var; yeni kalem olarak
    /// açılırsa teslimat pasif kalan eski kaleme işlenir ve sayımda görünmez. Önce siparişleri teslim alın ya da iptal edin."
    public static func splitBlockedMessage(item: Item, openOrders: Int) -> String {
        "“\(item.name)” \(openOrders) açık siparişte var; yeni kalem olarak açılırsa teslimat pasif kalan eski kaleme işlenir ve sayımda görünmez. Önce siparişleri teslim alın ya da iptal edin."
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
