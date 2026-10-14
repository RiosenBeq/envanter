import Foundation

/// Bir kalem için tolerans ve kritik seviye önerisi (Stok Kalemleri → "Eşik önerileri"; web `ThresholdSuggestion`)
public struct ThresholdSuggestion: Equatable, Sendable {
    public var itemID: String
    /// Önerilen tolerans (± birim): sayılmış günlerdeki |fark|'ın %80'lik dilimi, yukarı yuvarlanmış; az veride nil
    public var tolerance: Double?
    /// Toleransın hesaplandığı sayılmış gün (ilk sayım hariç)
    public var countedDays: Int
    /// Önerilen kritik seviye: günlük tüketim × 1,5, yukarı yuvarlanmış; az veride nil
    public var minStock: Double?
    public var dailyUsage: Double
    /// Günlük tüketimin hesaplandığı gün
    public var usageDays: Int
}

extension Engine {
    /// Öneri için gereken en az gün (sayılmış gün ya da tüketim örneği)
    public static let thresholdMinDays = 7
    /// Önerilerin baktığı geçmiş gün sayısı (varsayılan)
    public static let thresholdLookbackDays = 28

    /// `date` dahil son `lookbackDays` güne göre tolerans ve kritik seviye önerileri (yalnızca en az bir önerisi olan
    /// aktif kalemler, kalem sırasıyla).
    ///  • Tolerans: sayılmış günlerin |fark| değerlerinin %80'lik dilimi (en yakın sıra: ⌈0,8·n⌉. değer); en az 7 gün.
    ///    Adet tam sayıya, kg 0,01'e yukarı yuvarlanır; en az 1 adet / 0,01 kg.
    ///  • Kritik seviye: sipariş önerisindeki günlük tüketim × 1,5 (aynı geçmiş gün sayısıyla); en az 7 örnek gün.
    ///    Adet tam sayıya, kg 0,1'e yukarı yuvarlanır.
    public func thresholdSuggestions(asOf date: String, lookbackDays: Int = Engine.thresholdLookbackDays) -> [ThresholdSuggestion] {
        let lookback = max(1, lookbackDays)
        let window = (0..<lookback).map { DateKey.addDays(-$0, to: date) }.filter { data.days[$0] != nil }
        var diffs: [String: [Double]] = [:]
        for d in window {
            for c in calc(date: d).rows { if let x = c.diff { diffs[c.itemID, default: []].append(abs(x)) } }
        }
        let usage = Dictionary(orderSuggestions(asOf: date, lookbackDays: lookback, coverDays: 0).map { ($0.item.id, $0) },
                               uniquingKeysWith: { a, _ in a })
        return activeItems.compactMap { item in
            let values = (diffs[item.id] ?? []).sorted()
            var tolerance: Double?
            if values.count >= Self.thresholdMinDays {
                // ⌈0,8·n⌉ tam sayıyla (kayan nokta yuvarlaması iki istemcide farklılaşmasın)
                let rank = (4 * values.count + 4) / 5
                tolerance = Self.roundUp(values[rank - 1], step: item.isKg ? 0.01 : 1, atLeastOneStep: true)
            }
            let u = usage[item.id]
            var minStock: Double?
            if let u, u.sampleDays >= Self.thresholdMinDays, u.dailyUsage > 0 {
                minStock = Self.roundUp(u.dailyUsage * 1.5, step: item.isKg ? 0.1 : 1, atLeastOneStep: false)
            }
            guard tolerance != nil || minStock != nil else { return nil }
            return ThresholdSuggestion(itemID: item.id, tolerance: tolerance, countedDays: values.count, minStock: minStock,
                                       dailyUsage: u?.dailyUsage ?? 0, usageDays: u?.sampleDays ?? 0)
        }
    }

    /// `step` katına yukarı yuvarlar (1e-9 pay: 0,07 / 0,01 = 7,000000000000001 → 7)
    static func roundUp(_ v: Double, step: Double, atLeastOneStep: Bool) -> Double {
        var q = (v / step - 1e-9).rounded(.up)
        if atLeastOneStep { q = max(q, 1) }
        return clean(max(q, 0) * step)
    }
}

/// Genel Bakış'taki kurulum listesi (patron / müdür; tamamlanınca gizlenir): tolerans ve kritik seviye tanımlı kalem,
/// reçetesi tanımsız satılan ürün, mağaza bilgisayarı (Mac'te: web paneli) bağlantısı. Web `setupChecklist` ile aynı.
public struct SetupChecklist: Equatable, Sendable {
    public var activeItems: Int
    /// Toleransı tanımlı (> 0) aktif kalem
    public var withTolerance: Int
    /// Kritik seviyesi tanımlı (> 0) aktif kalem
    public var withMinStock: Int
    /// Son `lookbackDays` günde reçetesi tanımsız satılan farklı ürün kodu
    public var unknownProducts: Int
    public var computerLinked: Bool

    public init(activeItems: Int, withTolerance: Int, withMinStock: Int, unknownProducts: Int, computerLinked: Bool) {
        self.activeItems = activeItems; self.withTolerance = withTolerance; self.withMinStock = withMinStock
        self.unknownProducts = unknownProducts; self.computerLinked = computerLinked
    }

    public var toleranceDone: Bool { withTolerance >= activeItems }
    public var minStockDone: Bool { withMinStock >= activeItems }
    public var recipesDone: Bool { unknownProducts == 0 }
    public var isDone: Bool { toleranceDone && minStockDone && recipesDone && computerLinked }

    public static func make(engine: Engine, date: String, computerLinked: Bool,
                            lookbackDays: Int = Engine.thresholdLookbackDays) -> SetupChecklist {
        let items = engine.activeItems
        var codes = Set<String>()
        for i in 0..<max(1, lookbackDays) {
            let d = DateKey.addDays(-i, to: date)
            guard engine.data.days[d] != nil else { continue }
            for l in engine.analysis(date: d).unknownLines { codes.insert(l.code) }
        }
        return SetupChecklist(activeItems: items.count,
                              withTolerance: items.filter { ($0.tolerance ?? 0) > 0 }.count,
                              withMinStock: items.filter { ($0.minStock ?? 0) > 0 }.count,
                              unknownProducts: codes.count, computerLinked: computerLinked)
    }
}

/// Eşik önerisinin bir alanı: mevcut değer → önerilen (Stok Kalemleri → "Eşik önerileri" penceresi; web `ThresholdChange`)
public struct ThresholdChange: Equatable, Sendable, Identifiable {
    public enum Field: String, Sendable { case tolerance, minStock }

    public var itemID: String
    public var field: Field
    /// Mevcut değer (tanımsızsa nil)
    public var current: Double?
    public var suggested: Double
    /// Varsayılan seçili: alan henüz tanımlı değilse (elle girilmiş değerin üzerine kendiliğinden yazılmaz)
    public var preselected: Bool

    public var id: String { itemID + "-" + field.rawValue }

    /// Önerilerden değişecek alanlar (kalem sırasıyla; önce tolerans, sonra kritik seviye)
    public static func changes(items: [Item], suggestions: [ThresholdSuggestion]) -> [ThresholdChange] {
        let byID = Dictionary(suggestions.map { ($0.itemID, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [ThresholdChange] = []
        for item in items where item.active {
            guard let s = byID[item.id] else { continue }
            for (field, suggested, cur) in [(Field.tolerance, s.tolerance, item.tolerance), (Field.minStock, s.minStock, item.minStock)] {
                guard let suggested else { continue }
                let current = (cur ?? 0) > 0 ? cur : nil
                if let current, abs(current - suggested) < 1e-9 { continue }
                out.append(ThresholdChange(itemID: item.id, field: field, current: current, suggested: suggested, preselected: current == nil))
            }
        }
        return out
    }

    /// Önerisi olan kalem sayısı ("Eşik önerileri (N)")
    public static func itemCount(_ changes: [ThresholdChange]) -> Int { Set(changes.map { $0.itemID }).count }

    /// Seçilen önerileri kalemlere yazar
    public static func apply(_ changes: [ThresholdChange], to items: inout [Item]) {
        for c in changes {
            guard let i = items.firstIndex(where: { $0.id == c.itemID }) else { continue }
            switch c.field {
            case .tolerance: items[i].tolerance = c.suggested
            case .minStock: items[i].minStock = c.suggested
            }
        }
    }
}
