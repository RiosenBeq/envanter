import Foundation

// Günü kapatmadan önce ortak kontrol listesi, kapatılmamış günler ve personelin eski güne giriş uyarısı (web
// `src/lib/engine/dayClose.ts`). Kurallar ve metinler iki istemcide aynı; ortak test vektörleri:
// Fixtures/dayclose-vectors.json (web test/fixtures/, aynı içerik).

/// Günü kapatmadan önce gösterilen kontrol listesi: sayım, satış raporu, tanımsız reçete ve (bilgi olarak) tolerans dışı
/// fark. Personel her zaman onaylar (kilidi açamaz); patron / müdür yalnızca eksik varsa onaylar.
public struct DayCloseCheck: Equatable, Sendable {
    public enum Tone: String, Equatable, Sendable {
        /// Tamam (✓)
        case ok
        /// Eksik (⚠): onay penceresi açılır, düğme "Yine de Kapat"
        case warn
        /// Bilgi (•): onay gerektirmez
        case info
    }

    public struct Line: Equatable, Sendable, Identifiable {
        public var id: String { kind }
        /// counted | sales | unknown | problems
        public var kind: String
        public var tone: Tone
        public var text: String

        public init(kind: String, tone: Tone, text: String) {
            self.kind = kind; self.tone = tone; self.text = text
        }

        /// Uyarı değil (tamam ya da bilgi)
        public var ok: Bool { tone != .warn }

        /// Mac onay penceresindeki işaret
        public var mark: String {
            switch tone {
            case .ok: return "✓"
            case .warn: return "⚠"
            case .info: return "•"
            }
        }
    }

    /// Onay penceresi gerekli mi: personel, eksik sayım, satış raporu yok ya da tanımsız reçete
    public var needsConfirm: Bool
    public var lines: [Line]
    /// Kilit kuralı (personel / patron-müdür)
    public var ruleText: String
    public var counted: Int
    public var total: Int

    /// Uyarı satırı yok
    public var allOK: Bool { lines.allSatisfy { $0.ok } }
    /// Onay düğmesi: her satır tamamsa "Günü Kapat", değilse "Yine de Kapat"
    public var confirmLabel: String { allOK ? Self.closeLabel : Self.closeAnywayLabel }
    /// Sayılmayan kalem var ("Sayılmayanları Göster" bağlantısı)
    public var hasUncounted: Bool { counted < total }
    /// Satış raporu aktarılmamış ("Satış raporu aktar" bağlantısı)
    public var missingSales: Bool { lines.contains { $0.kind == "sales" && $0.tone == .warn } }

    /// Mac onay penceresinin metni: işaretli satırlar, boş satır, kural
    public var message: String {
        lines.map { "\($0.mark) \($0.text)" }.joined(separator: "\n") + "\n\n" + ruleText
    }

    public static let closeLabel = "Günü Kapat"
    public static let closeAnywayLabel = "Yine de Kapat"
    public static let showUncountedLabel = "Sayılmayanları Göster"
    /// Personelin kuralı (kilidi açamaz)
    public static let staffRule = "Günü kapatınca sayım ve satış değiştirilemez; kilidi yalnızca patron veya müdür açabilir."
    /// Patron / müdürün kuralı
    public static let managerRule = "Sayım ve satış kilitlenir; kilidi daha sonra Günlük Sayım'dan açabilirsiniz."
    /// Personel tanımsız reçeteyi kendisi tanımlayamaz
    public static let unknownStaffNote = "Reçetesini patron veya müdür tanımlar."

    /// "13.10.2026 günü kapatılsın mı?"
    public static func title(date: String) -> String { "\(DateKey.short(date)) günü kapatılsın mı?" }
    /// Onaysız kapatmadan sonraki bildirim: "13.10.2026 günü kapatıldı"
    public static func closedText(date: String) -> String { "\(DateKey.short(date)) günü kapatıldı" }

    /// - Parameters:
    ///   - counted, total: kapanışı girilmiş ve toplam aktif kalem
    ///   - hasSales: satış raporu (ya da Excel'den gelen satış) var mı
    ///   - unknownLines: reçetesi tanımsız satış satırı
    ///   - problemItems: tolerans dışı fark olan kalem (yalnızca bilgi; onay gerektirmez)
    ///   - canChangeLockedDay: patron / müdür (kilidi açabilir)
    public static func evaluate(counted: Int, total: Int, hasSales: Bool, unknownLines: Int, problemItems: Int,
                                canChangeLockedDay: Bool) -> DayCloseCheck {
        var lines: [Line] = []
        if total > 0 {
            lines.append(counted >= total
                         ? Line(kind: "counted", tone: .ok, text: "Sayım tamam: \(total) / \(total) kalem sayıldı.")
                         : Line(kind: "counted", tone: .warn,
                                text: "Sayım eksik: \(counted) / \(total) kalem sayıldı, \(total - counted) kalem sayılmadı."))
        }
        lines.append(hasSales
                     ? Line(kind: "sales", tone: .ok, text: "Satış raporu aktarıldı.")
                     : Line(kind: "sales", tone: .warn, text: "Satış raporu aktarılmadı: satılan miktarlar ve farklar eksik hesaplanır."))
        if unknownLines > 0 {
            var text = "\(unknownLines) satış ürününün reçetesi tanımlı değil: stoğa yansımadı."
            if !canChangeLockedDay { text += " " + unknownStaffNote }
            lines.append(Line(kind: "unknown", tone: .warn, text: text))
        }
        if problemItems > 0 {
            lines.append(Line(kind: "problems", tone: .info, text: "Tolerans dışı fark: \(problemItems) kalem."))
        }
        let needsConfirm = !canChangeLockedDay || counted < total || !hasSales || unknownLines > 0
        return DayCloseCheck(needsConfirm: needsConfirm, lines: lines,
                             ruleText: canChangeLockedDay ? managerRule : staffRule, counted: counted, total: total)
    }

    /// Günün özetinden (`Engine.overview`)
    public static func evaluate(_ o: DayOverview, canChangeLockedDay: Bool) -> DayCloseCheck {
        evaluate(counted: o.countedItems, total: o.itemCount, hasSales: o.hasSales, unknownLines: o.unknownLines,
                 problemItems: o.problemItems, canChangeLockedDay: canChangeLockedDay)
    }
}

/// Sayılmış ama kapatılmamış gün (Genel Bakış'taki liste; patron / müdür seçilenleri topluca kapatır)
public struct UnclosedDay: Identifiable, Sendable {
    public var id: String { date }
    public var date: String
    public var check: DayCloseCheck
}

public enum UnclosedDays {
    /// Listenin baktığı geçmiş gün sayısı (seçili gün dahil)
    public static let lookbackDays = 60

    /// `asOf` dahil geriye `lookbackDays` günde verisi olan, en az bir kalemi sayılmış ve kapatılmamış günler (yeniden
    /// eskiye), her biri kontrol listesiyle
    public static func list(engine: Engine, asOf: String, lookbackDays: Int = lookbackDays,
                            canChangeLockedDay: Bool) -> [UnclosedDay] {
        let from = DateKey.addDays(-(max(lookbackDays, 1) - 1), to: asOf)
        return engine.datesWithData.reversed().compactMap { d in
            guard d >= from && d <= asOf else { return nil }
            let o = engine.overview(date: d)
            guard o.hasAnyCount && !o.isLocked else { return nil }
            return UnclosedDay(date: d, check: DayCloseCheck.evaluate(o, canChangeLockedDay: canChangeLockedDay))
        }
    }

    /// Toplu kapatmada önceden seçili günler: kontrol listesinde uyarı yok (sayım tam, satış raporu var, reçeteler tanımlı)
    public static func preselected(_ days: [UnclosedDay]) -> [String] {
        days.filter { $0.check.allOK }.map { $0.date }
    }

    /// "Kapatılmamış günler (3)"
    public static func title(_ count: Int) -> String { "Kapatılmamış günler (\(count))" }
    public static let subtitle = "Son 60 gün: sayımı girilmiş ama kapatılmamış günler. Kapatılan günün sayım ve satışı kilitlenir."
    public static let emptyText = "Son 60 günde sayılmış ama kapatılmamış gün yok."
    public static let closeSelectedLabel = "Seçilenleri Kapat"
    /// "3 gün kapatıldı"
    public static func closedText(_ count: Int) -> String { "\(count) gün kapatıldı" }
}

/// Personel 7 günden eski bir güne yazarken bir kez (oturum başına) uyarılır: yanlış güne giriş olmasın
public enum OldDayWarning {
    /// Bu kadar günden eski gün (bugün − gün > 7)
    public static let days = 7
    public static let title = "7 günden eski bir güne giriş yapıyorsunuz"

    public static func message(date: String) -> String {
        "\(DateKey.short(date)) günü seçili. Doğru günü seçtiğinizden emin olun; bu uyarı oturum başına bir kez gösterilir."
    }

    /// Uyarı gerekir mi: personel ve gün bugünden `days` günden eski
    public static func applies(role: String?, date: String, today: String) -> Bool {
        guard role == CloudRole.staff, let age = DateKey.distance(from: date, to: today) else { return false }
        return age > days
    }
}
