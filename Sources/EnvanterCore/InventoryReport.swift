import Foundation

/// Dönem envanter raporu (komut satırı `report`): sayılan ve satışlı günler, sorunlu kalemler, fazla çıkış, dönem sonunda
/// kritik seviyenin altındakiler, açık siparişler. Yalnızca miktar; para birimi yok.
public struct InventoryReport {
    /// Dönemde tolerans dışı fazla çıkış olan kalem
    public struct Shortage: Identifiable, Equatable {
        public var id: String { item.id }
        public var item: Item
        /// Fazla çıkış miktarı (envanter birimi; az çıkışlarla mahsup edilmez)
        public var qty: Double
        /// Fazla çıkış olan gün sayısı
        public var days: Int

        public init(item: Item, qty: Double, days: Int) { self.item = item; self.qty = qty; self.days = days }
    }

    /// Dönem sonunda kritik seviyenin altındaki kalem: `to` ya da öncesindeki son sayılan kapanışa göre
    public struct BelowMinimum: Identifiable, Equatable {
        public var id: String { item.id }
        public var item: Item
        public var closing: Double
        /// Kapanışın sayıldığı gün
        public var date: String
    }

    public var from: String
    public var to: String
    /// Verisi olan günler, sayımlı ve satışlı gün sayıları
    public var period: PeriodStats
    /// Aktif kalem sayısı
    public var itemCount: Int
    /// Dönem farkı tolerans dışı ya da en az bir gün fazla çıkış olan kalemler (kalem listesi sırasıyla)
    public var problemItems: [Item]
    /// Fazla çıkış olan kalemler, `shortageOrder` sırasıyla
    public var shortages: [Shortage]
    /// Kritik seviyenin altındakiler (kalem listesi sırasıyla)
    public var belowMinimum: [BelowMinimum]
    /// Teslim alınmamış sipariş sayısı
    public var openOrders: Int

    public init(engine: Engine, from: String, to: String) {
        self.from = from
        self.to = to
        period = engine.periodStats(from: from, to: to)
        let rows = engine.summary(from: from, to: to)
        itemCount = rows.count
        problemItems = rows.filter { $0.severity.isProblem || $0.shortageDays > 0 }.map { $0.item }
        shortages = rows.filter { $0.shortageQty > 0 }
            .map { Shortage(item: $0.item, qty: $0.shortageQty, days: $0.shortageDays) }
            .sorted(by: Self.shortageOrder)
        let next = DateKey.addDays(1, to: to)
        belowMinimum = engine.activeItems.compactMap { item in
            guard let c = engine.lastClosing(itemID: item.id, before: next), item.isBelowMinimum(c.value) else { return nil }
            return BelowMinimum(item: item, closing: c.value, date: c.date)
        }
        openOrders = engine.data.purchaseOrders.filter { $0.status == .open }.count
    }

    /// Fazla çıkış sırası: önce gün sayısı (sürekli sorun önde), eşitse birim, aynı birimde miktar (çoktan aza), sonra ad.
    /// Farklı birimlerin miktarları (adet ile kg) birbiriyle kıyaslanmaz.
    public static func shortageOrder(_ a: Shortage, _ b: Shortage) -> Bool {
        if a.days != b.days { return a.days > b.days }
        let ua = unitKey(a.item), ub = unitKey(b.item)
        if ua != ub { return ua < ub }
        if a.qty != b.qty { return a.qty > b.qty }
        if a.item.name != b.item.name { return a.item.name < b.item.name }
        return a.item.id < b.item.id
    }

    static func unitKey(_ item: Item) -> String {
        TextFold.ascii(item.unit.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Komut satırı metni; fazla çıkış listesinde en çok `top` kalem
    public func text(branch: String, top: Int = 5) -> String {
        func qty(_ v: Double, _ item: Item) -> String { "\(Fmt.number(v, maxFraction: item.maxFraction)) \(item.unit.lowercased())" }
        let b = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = ["\(b.isEmpty ? "Dönem özeti" : b) · \(DateKey.short(from)) – \(DateKey.short(to))"]
        lines.append("Gün                 : \(period.days.count) (sayım \(period.countedDays), satış \(period.salesDays))")
        lines.append("Sorunlu kalem       : \(problemItems.count) / \(itemCount)"
                     + (problemItems.isEmpty ? "" : " (\(problemItems.map { $0.name }.joined(separator: ", ")))"))
        lines.append("Fazla çıkış         : " + (shortages.isEmpty ? "yok" : "\(shortages.count) kalem (en sık olanlar)"))
        for s in shortages.prefix(max(top, 0)) {
            lines.append("  • \(s.item.name): \(qty(s.qty, s.item)) (\(s.days) gün)")
        }
        lines.append("Kritik seviye altı  : "
                     + (belowMinimum.isEmpty ? "yok" : "\(belowMinimum.count) kalem (\(DateKey.short(to)) itibarıyla son sayım)"))
        for m in belowMinimum {
            let when = m.date == to ? "" : " · sayım \(DateKey.short(m.date))"
            lines.append("  • \(m.item.name): \(qty(m.closing, m.item)) (kritik \(qty(m.item.minStock ?? 0, m.item))\(when))")
        }
        lines.append("Açık sipariş        : \(openOrders)")
        return lines.joined(separator: "\n")
    }
}
