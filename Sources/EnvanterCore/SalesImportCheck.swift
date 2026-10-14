import Foundation

/// Satış raporu aktarılmadan önce önizlemede gösterilen uyarılardan biri
public struct SalesImportWarning: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// Aynı rapor (aynı ürün kodları ve adetler) yakın bir güne zaten aktarılmış
        case duplicate
        /// Raporun dönemi başka bir güne aktarılan raporun dönemiyle aynı
        case samePeriod
        /// Toplam adet son 14 günün ortancasının 3 katından fazla / %30'undan az
        case abnormalHigh, abnormalLow
        /// Raporun tarihi seçili günden farklı (seçili günden bir önceki gün: bilgi; diğerleri: uyarı)
        case dateGap
        /// Kodu olup adedi okunamayan satırlar
        case skipped
    }
    public enum Tone: String, Sendable { case bad, warn, info }

    public var kind: Kind
    public var tone: Tone
    public var text: String
    /// duplicate / samePeriod: raporun aktarıldığı gün ("O güne git"); dateGap: raporun tarihi ("Rapor tarihini kullan")
    public var date: String?
    /// Aktarmak için "Yine de bu güne aktar" onayı gerekir
    public var blocking: Bool

    public init(kind: Kind, tone: Tone, text: String, date: String? = nil, blocking: Bool = false) {
        self.kind = kind; self.tone = tone; self.text = text; self.date = date; self.blocking = blocking
    }
}

/// Satış aktarımı güvenliği: aynı raporun iki güne aktarılması, anormal toplam, tarih farkı ve okunamayan satırlar.
/// Web: src/lib/salesImport.ts `salesImportWarnings` (ortak vektörler: Fixtures/salesimport-vectors.json).
public enum SalesImportCheck {
    /// Aynı rapor bu kadar gün öncesine / sonrasına bakılarak aranır
    public static let duplicateWindow = 10
    /// Anormal toplam için bakılan geçmiş gün sayısı ve en az satışlı gün
    public static let abnormalLookback = 14
    public static let abnormalMinDays = 5
    /// Okunamayan satır oranı bunu aşarsa onay istenir (%20)
    public static let skippedBlockingRatio = 0.2

    public static func warnings(report: SalesReport, targetDate: String, data: AppData) -> [SalesImportWarning] {
        var out: [SalesImportWarning] = []

        // 1) Aynı rapor yakın bir güne zaten aktarılmış
        let mine = signature(report.lines)
        var duplicateDate: String?
        if !mine.isEmpty {
            var candidates: [String] = []
            for (d, day) in data.days where d != targetDate && !day.sales.isEmpty {
                guard let dist = DateKey.distance(from: targetDate, to: d), abs(dist) <= duplicateWindow else { continue }
                if signature(SalesParser.mergeLines(day.sales)) == mine { candidates.append(d) }
            }
            if let d = nearest(candidates, to: targetDate) {
                duplicateDate = d
                out.append(SalesImportWarning(kind: .duplicate, tone: .bad,
                                              text: "Bu rapor \(DateKey.short(d)) gününe zaten aktarılmış (\(report.lines.count) satırın hepsi aynı).",
                                              date: d, blocking: true))
            }
        }

        // 2) Aynı dönemin raporu başka bir güne aktarılmış (tek günlük rapor)
        if !report.isMultiDay, let period = report.periodText {
            let others = data.days.filter { $0.key != targetDate && $0.key != duplicateDate && $0.value.salesPeriod == period }.map { $0.key }
            if let d = nearest(others, to: targetDate) {
                out.append(SalesImportWarning(kind: .samePeriod, tone: .warn,
                                              text: "Raporun dönemi (\(period)) \(DateKey.short(d)) gününe aktarılan raporla aynı; aynı raporu iki güne aktarıyor olabilirsiniz.",
                                              date: d))
            }
        }

        // 3) Toplam adet son 14 günün ortancasından çok farklı
        var totals: [Double] = []
        for i in 1...abnormalLookback {
            if let day = data.days[DateKey.addDays(-i, to: targetDate)], !day.sales.isEmpty {
                totals.append(day.sales.reduce(0) { $0 + $1.qty })
            }
        }
        if totals.count >= abnormalMinDays {
            let m = median(totals), t = report.totalQty
            let head = "Toplam adet (\(Fmt.number(t, maxFraction: 0))) son \(abnormalLookback) günün ortancasının (\(Fmt.number(m, maxFraction: 0)))"
            if m > 0 && t > 3 * m {
                out.append(SalesImportWarning(kind: .abnormalHigh, tone: .warn, text: head + " 3 katından fazla; çok günlük rapor olabilir."))
            } else if m > 0 && t < 0.3 * m {
                out.append(SalesImportWarning(kind: .abnormalLow, tone: .warn, text: head + " %30'undan az; eksik rapor olabilir."))
            }
        }

        // 4) Raporun tarihi seçili günden farklı (çok günlük raporun ayrı uyarısı var). Yalnızca seçili günden bir önceki
        //    günün raporu bilgi sayılır (sayım ertesi sabah); seçili günden sonraki günün raporu her zaman yanlış gündür.
        if !report.isMultiDay, let from = report.dateFrom, let gap = DateKey.distance(from: from, to: targetDate), gap != 0 {
            let nextMorning = gap == 1
            let text = nextMorning
                ? "Raporun tarihi \(DateKey.short(from)); seçili gün \(DateKey.short(targetDate)). Sayım ertesi sabah yapılıyorsa bu normaldir."
                : "Raporun tarihi \(DateKey.short(from)); seçili gün \(DateKey.short(targetDate)) (\(abs(gap)) gün fark). Doğru günü seçtiğinizden emin olun."
            out.append(SalesImportWarning(kind: .dateGap, tone: nextMorning ? .info : .warn, text: text, date: from))
        }

        // 5) Okunamayan satırlar
        if !report.skipped.isEmpty {
            let blocking = Double(report.skipped.count) > skippedBlockingRatio * Double(max(report.codeRows, 1))
            out.append(SalesImportWarning(kind: .skipped, tone: blocking ? .bad : .warn,
                                          text: "\(report.skipped.count) satır okunamadı (adet boş ya da sayı değil); bu satırlar aktarılmaz.",
                                          blocking: blocking))
        }
        return out
    }

    /// Aktarmak için onay gerekiyor mu
    public static func needsConfirmation(_ warnings: [SalesImportWarning]) -> Bool { warnings.contains { $0.blocking } }

    /// Kod → adet (birleştirilmiş satırlar)
    static func signature(_ lines: [SaleLine]) -> [String: Double] {
        var out: [String: Double] = [:]
        for l in lines { out[l.code, default: 0] += l.qty }
        return out
    }

    /// Hedef güne en yakın gün (eşitlikte önceki gün)
    static func nearest(_ dates: [String], to target: String) -> String? {
        var best: (dist: Int, date: String)?
        for d in dates {
            guard let dist = DateKey.distance(from: target, to: d).map(abs) else { continue }
            if let b = best, b.dist < dist || (b.dist == dist && b.date < d) { continue }
            best = (dist, d)
        }
        return best?.date
    }

    static func median(_ values: [Double]) -> Double {
        let s = values.sorted()
        guard !s.isEmpty else { return 0 }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}
