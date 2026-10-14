import Foundation

/// Açılış ve devir metinleri: Günlük Sayım, hesap dökümü, sözlük ve yardım aynı ifadeleri kullanır.
/// Web `src/lib/engine/stockText.ts` ile birebir (ortak test vektörleri: carry-vectors.json).
public enum OpeningText {
    /// Günlük Sayım alt satırındaki açıklama
    public static let legend = "Açılış boşsa son sayım ve aradaki sayılmayan günlerin hareketleri kullanılır (≈ tahmini)"
    /// Sözlük: Açılış
    public static let glossary = "Günün başındaki stok. Boşsa son sayımın kapanışı ile aradaki sayılmayan günlerin gelen, transfer, satış ve zayisi kullanılır (≈ tahmini). Önceki sayım yoksa ya da 31 günden eskiyse o günün sayımı başlangıç kabul edilir ve fark hesaplanmaz."
    /// Yardım: "Sayımı girin" adımındaki cümle
    public static let helpStep = "Açılış son sayımdan kendiliğinden gelir; arada sayılmayan günler varsa onların gelen, transfer, satış ve zayisi eklenir (≈ tahmini)."
    public static let noBase = "Önceki sayım yok; ilk sayım başlangıç kabul edilir"
    public static let manual = "Elle girilmiş açılış. Silerseniz son sayımdan devreden değer kullanılır."
    public static let baselinePill = "İlk sayım"
    public static let baselineHelp = "Bu kalemin ilk sayımı: önceki kapanış olmadığı için fark hesaplanmaz. Açılışı 0 kabul etmek için Açılış'a 0 yazın."
    public static let fillHelp = "Hiç hareketi (gelen, transfer, satış, zayi) olmayan ve sayılmamış kalemlere kapanış = açılış yazar; tahmini (≈) açılışlara yazmaz"
    public static let fillNoSales = "Önce günün satış raporunu aktarın; satış olmadan hangi kalemin hareketsiz olduğu bilinemez."
    public static let fillNothing = "Doldurulacak hareketsiz kalem yok"
    public static func fillDone(_ n: Int) -> String { "\(n) kalemin kapanışı açılışla dolduruldu" }

    /// Açılış alanındaki soluk değer: tahminiyse "≈ 25", değilse "25"; elle girilmişse boş
    public static func placeholder(_ c: ItemCalc, item: Item) -> String {
        switch c.openingSource {
        case .manual: return ""
        case .carried: return "≈ " + num(c.opening, item)
        case .closing, .noBase: return num(c.opening, item)
        }
    }

    /// Açılış alanının ipucu (`breakdown`: `Engine.carryBreakdown`)
    public static func help(_ c: ItemCalc, item: Item, date: String, breakdown: [CarryDay]) -> String {
        switch c.openingSource {
        case .manual:
            if let j = c.openingJump, j != 0 {
                return "Elle girilmiş açılış: beklenen ≈ \(num(Engine.clean(c.opening - j), item)), fark \(signed(j, item)) \(unit(item)). Silerseniz beklenen değer kullanılır."
            }
            return manual
        case .closing:
            return "Önceki sayımdan (\(DateKey.short(c.openingBaseDate ?? ""))) devreden"
        case .carried:
            let base = DateKey.short(c.openingBaseDate ?? "")
            if c.carriedDays == 0 { return "Elle girilen açılıştan (\(base)) devreden" }
            let who = c.openingBaseKind == .manualOpening ? "Elle girilen açılış" : "Son sayım"
            let baseValue = Engine.clean(c.opening - c.carriedNet)
            return "\(who) \(base): \(num(baseValue, item)) + sayılmayan \(c.carriedDays) günün hareketleri (\(moves(breakdown, item))) ≈ \(num(c.opening, item))"
        case .noBase:
            if let b = c.openingBaseDate, let gap = DateKey.distance(from: b, to: date) {
                return c.isCounted ? "Son sayım \(gap) gün önce; bu sayım başlangıç kabul edildi"
                                   : "Son sayım \(gap) gün önce; ilk sayım başlangıç kabul edilir"
            }
            return noBase
        }
    }

    /// Hesap dökümündeki açılış satırının adı
    public static func breakdownLabel(_ c: ItemCalc) -> String {
        switch c.openingSource {
        case .manual: return "Açılış (elle)"
        case .closing: return "Açılış (önceki sayımdan)"
        case .carried: return "Açılış (≈ devreden)"
        case .noBase: return "Açılış (önceki sayım yok)"
        }
    }

    /// İlk sayım satırının ipucu (Fiili / Fark hücresi)
    public static func baselineHelp(_ c: ItemCalc, date: String) -> String {
        if c.hasStaleBase, let b = c.openingBaseDate, let gap = DateKey.distance(from: b, to: date) {
            return "Son sayım \(gap) gün önce; bu sayım başlangıç kabul edildi, fark hesaplanmaz. Açılışı elle yazarsanız fark hesaplanır."
        }
        return baselineHelp
    }

    /// Fark ipucuna eklenen açılış sıçraması: "Açılış beklenenden 5 kg fazla girildi (beklenen ≈ 20)"
    public static func jumpText(_ c: ItemCalc, item: Item) -> String? {
        guard let j = c.openingJump, j != 0 else { return nil }
        return "Açılış beklenenden \(num(abs(j), item)) \(unit(item)) \(j > 0 ? "fazla" : "eksik") girildi (beklenen ≈ \(num(Engine.clean(c.opening - j), item)))"
    }

    /// Devreden günler bloğunun satırı: "02.08 · Gelen +10 · Satılan −5 → +5"
    public static func carryLine(_ d: CarryDay, item: Item) -> String {
        let parts = moveParts(incoming: d.incoming, transferIn: d.transferIn, transferOut: d.transferOut, sold: d.sold, waste: d.waste, item: item)
        return DateKey.dayMonth(d.date) + " · " + parts.joined(separator: " · ") + " → " + signed(d.net, item)
    }

    /// Yürünen günlerin toplam hareketi: "Gelen +10, Satılan −5"
    static func moves(_ days: [CarryDay], _ item: Item) -> String {
        func sum(_ f: (CarryDay) -> Double) -> Double { Engine.clean(days.reduce(0) { $0 + f($1) }) }
        return moveParts(incoming: sum { $0.incoming }, transferIn: sum { $0.transferIn }, transferOut: sum { $0.transferOut },
                         sold: sum { $0.sold }, waste: sum { $0.waste }, item: item).joined(separator: ", ")
    }

    static func moveParts(incoming: Double, transferIn: Double, transferOut: Double, sold: Double, waste: Double, item: Item) -> [String] {
        var out: [String] = []
        if incoming != 0 { out.append("Gelen " + signed(incoming, item)) }
        if transferIn != 0 { out.append("Gelen transfer " + signed(transferIn, item)) }
        if transferOut != 0 { out.append("Giden transfer " + signed(-transferOut, item)) }
        if sold != 0 { out.append("Satılan " + signed(-sold, item)) }
        if waste != 0 { out.append("Zayi " + signed(-waste, item)) }
        return out
    }

    /// İşaretli sayı: "+10", "−5" (eksi işareti U+2212), "0"
    public static func signed(_ v: Double, _ item: Item) -> String {
        if v > 0 { return "+" + num(v, item) }
        if v < 0 { return "\u{2212}" + num(-v, item) }
        return "0"
    }

    static func num(_ v: Double, _ item: Item) -> String { Fmt.number(v, maxFraction: item.maxFraction) }
    static func unit(_ item: Item) -> String { item.unit.lowercased() }
}

/// Tahmini stok metinleri (Stok Kalemleri sütunu, Genel Bakış). Web `stockText.ts` ile birebir.
public enum StockEstimateText {
    public static let pill = "tahmini"
    public static let noEstimate = "Tahmin yok: son 31 günde sayım yok"

    /// "≈ 4,2 kg" (sayılmadıysa; eksi tahmin "≈ 0") ya da bugün sayıldıysa "6 kg"
    public static func value(_ e: StockEstimate, item: Item) -> String {
        let u = OpeningText.unit(item)
        if e.counted { return "\(OpeningText.num(e.stock, item)) \(u)" }
        return "≈ \(OpeningText.num(max(e.stock, 0), item)) \(u)"
    }

    /// "Son sayım 12.10.2026: 6 kg + sonraki hareketler"
    public static func help(_ e: StockEstimate, item: Item) -> String {
        let u = OpeningText.unit(item)
        if e.counted { return "Sayım \(DateKey.short(e.baseDate)): \(OpeningText.num(e.stock, item)) \(u)" }
        let who = e.baseKind == .manualOpening ? "Elle girilen açılış" : "Son sayım"
        let base = "\(who) \(DateKey.short(e.baseDate)): \(OpeningText.num(e.baseValue, item)) \(u) + sonraki hareketler"
        return e.stock < 0 ? "Tahmin sıfırın altında: girilmemiş Gelen olabilir. " + base : base
    }

    /// Dikkat listesindeki satırın ayrıntısı: "≈ 4,2 kg · kritik 8 · son sayım 12.10"
    public static func attention(_ e: StockEstimate, item: Item) -> String {
        let who = e.baseKind == .manualOpening ? "açılış" : "son sayım"
        return "≈ \(OpeningText.num(max(e.stock, 0), item)) \(OpeningText.unit(item)) · kritik \(OpeningText.num(e.minStock ?? 0, item)) · \(who) \(DateKey.dayMonth(e.baseDate))"
    }
}

/// Genel Bakış "Kritik seviye altı" kartı: sayım varsa sayılanlar (+ tahmini sayılmayanlar), yoksa tahminler
public struct BelowMinimumCard: Equatable, Sendable {
    public var value: String
    public var detail: String
    public var warn: Bool

    public static func make(_ o: DayOverview, estimates: [StockEstimate]) -> BelowMinimumCard {
        if o.hasAnyCount {
            let extra = estimates.filter { !$0.counted && $0.below }.count
            let detail = extra > 0 ? "+\(extra) tahmini (sayılmayan)"
                : (o.belowMinimumItems > 0 ? "Sipariş önerisine bakın" : "Kritik seviyenin altında kalem yok")
            return BelowMinimumCard(value: "\(o.belowMinimumItems)", detail: detail, warn: o.belowMinimumItems > 0 || extra > 0)
        }
        if estimates.isEmpty { return BelowMinimumCard(value: "—", detail: "Sayım girilince hesaplanır", warn: false) }
        let n = estimates.filter { $0.below }.count
        return BelowMinimumCard(value: "\(n)", detail: "tahmini · sayım girilmedi", warn: n > 0)
    }
}
