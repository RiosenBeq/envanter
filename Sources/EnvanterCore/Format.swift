import Foundation

public enum Fmt {
    private static let trLocale = Locale(identifier: "tr_TR")

    /// 7,5 / 12 / 0,014 gibi Türkçe gösterim (binlik ayırıcı yok).
    public static func number(_ value: Double, maxFraction: Int = 3) -> String {
        let step = pow(10.0, Double(maxFraction))
        var v = (value * step).rounded() / step
        if v == 0 { v = 0 } // -0 gösterme
        let f = NumberFormatter()
        f.locale = trLocale
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = maxFraction
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }

    /// Hem "7,5" hem "7.5" kabul eder. Boş / geçersiz ise nil.
    public static func parse(_ raw: String) -> Double? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: " ", with: "")
        if s.isEmpty { return nil }
        if s.hasPrefix("+") { s.removeFirst() }
        let hasComma = s.contains(","), hasDot = s.contains(".")
        if hasComma && hasDot {
            // 1.234,5 (TR) veya 1,234.5 (EN): sonradan gelen ondalık ayırıcıdır
            if let lastComma = s.lastIndex(of: ","), let lastDot = s.lastIndex(of: ".") {
                if lastComma > lastDot {
                    s = s.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
                } else {
                    s = s.replacingOccurrences(of: ",", with: "")
                }
            }
        } else if hasComma {
            s = s.replacingOccurrences(of: ",", with: ".")
        }
        guard let d = Double(s), d.isFinite else { return nil }
        return d
    }

    /// Satış adetleri için: "1.120" gibi binlik ayırıcılı tam sayıları da tanır.
    public static func parseQuantity(_ raw: String) -> Double? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.range(of: #"^-?\d{1,3}(\.\d{3})+$"#, options: .regularExpression) != nil {
            return Double(s.replacingOccurrences(of: ".", with: ""))
        }
        return parse(s)
    }
}

public enum DateKey {
    private static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.locale = Locale(identifier: "tr_TR")
        return c
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = Locale(identifier: "tr_TR")
        f.dateFormat = format
        return f
    }

    public static func string(from date: Date) -> String { formatter("yyyy-MM-dd").string(from: date) }

    public static func date(from key: String) -> Date? {
        formatter("yyyy-MM-dd").date(from: key).map { calendar.startOfDay(for: $0) }
    }

    public static func addDays(_ n: Int, to key: String) -> String {
        guard let d = date(from: key), let r = calendar.date(byAdding: .day, value: n, to: d) else { return key }
        return string(from: r)
    }

    public static func today() -> String { string(from: Date()) }

    /// 1 Ağustos 2026 Cumartesi
    public static func long(_ key: String) -> String {
        guard let d = date(from: key) else { return key }
        return formatter("d MMMM yyyy, EEEE").string(from: d)
    }

    /// 01.08.2026
    public static func short(_ key: String) -> String {
        guard let d = date(from: key) else { return key }
        return formatter("dd.MM.yyyy").string(from: d)
    }

    /// Excel seri numarası (1900 sistemi): 2026-08-01 -> 46235
    public static func excelSerial(_ key: String) -> Double? {
        guard let d = date(from: key) else { return nil }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let comps = calendar.dateComponents([.year, .month, .day], from: d)
        guard let u = utc.date(from: comps),
              let base = utc.date(from: DateComponents(year: 1899, month: 12, day: 30)) else { return nil }
        return (u.timeIntervalSince(base) / 86400).rounded()
    }

    /// Excel seri numarası -> yyyy-MM-dd (46235 -> 2026-08-01)
    public static func fromExcelSerial(_ serial: Double) -> String? {
        guard serial > 1, serial < 2_958_465 else { return nil }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        guard let base = utc.date(from: DateComponents(year: 1899, month: 12, day: 30)),
              let d = utc.date(byAdding: .day, value: Int(serial.rounded(.down)), to: base) else { return nil }
        let c = utc.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    public static func startOfMonth(_ key: String) -> String {
        guard let d = date(from: key) else { return key }
        let comps = calendar.dateComponents([.year, .month], from: d)
        return string(from: calendar.date(from: comps) ?? d)
    }

    public static func endOfMonth(_ key: String) -> String {
        guard let d = date(from: key) else { return key }
        let comps = calendar.dateComponents([.year, .month], from: d)
        guard let s = calendar.date(from: comps),
              let e = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: s) else { return key }
        return string(from: e)
    }

    public static func startOfPreviousMonth(_ key: String) -> String {
        guard let d = date(from: key), let p = calendar.date(byAdding: .month, value: -1, to: d) else { return key }
        return startOfMonth(string(from: p))
    }

    /// Anahtarları (yyyy-MM-dd) karşılaştırmak için: sözlük sırası = tarih sırası
    public static func isValid(_ key: String) -> Bool { date(from: key) != nil }
}
