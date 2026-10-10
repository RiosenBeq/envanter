import Foundation

public enum Fmt {
    /// 7,5 / 12 / 0,014 gibi Türkçe gösterim (binlik ayırıcı yok).
    /// Ekranda her hücre için çağrıldığından NumberFormatter yerine doğrudan biçimlendirilir.
    public static func number(_ value: Double, maxFraction: Int = 3) -> String {
        guard value.isFinite else { return "—" }
        let digits = max(0, min(maxFraction, 9))
        let step = pow(10.0, Double(digits))
        var s = String(format: "%.\(digits)f", (value * step).rounded() / step)
        if digits > 0 {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        if s == "-0" { s = "0" }  // -0 gösterme
        return s.replacingOccurrences(of: ".", with: ",")
    }

    /// Para tutarı: 12.450 ₺ / 1.234,50 ₺ (binlik ayırıcı nokta, ondalık virgül)
    public static func money(_ value: Double, fraction: Int? = nil) -> String {
        guard value.isFinite else { return "—" }
        let digits = fraction ?? (abs(value) >= 1000 ? 0 : 2)
        let step = pow(10.0, Double(digits))
        let rounded = (value * step).rounded() / step
        let negative = rounded < 0
        let parts = String(format: "%.\(digits)f", abs(rounded)).split(separator: ".")
        var intPart = String(parts[0])
        var grouped = ""
        while intPart.count > 3 {
            grouped = "." + intPart.suffix(3) + grouped
            intPart.removeLast(3)
        }
        grouped = intPart + grouped
        let frac = parts.count > 1 ? "," + parts[1] : ""
        return (negative ? "-" : "") + grouped + frac + " ₺"
    }

    /// Elle girilen sayı: hem "7,5" hem "7.5" kabul eder. Boş / geçersiz ise nil.
    /// Yalnızca rakam, ayırıcı ve işaret kabul edilir ("1e300", "inf", "0x10" gibi girişler reddedilir).
    public static func parse(_ raw: String) -> Double? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: "\u{202F}", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{2212}", with: "-")  // tipografik eksi
        if s.isEmpty { return nil }
        if s.hasPrefix("+") { s.removeFirst() }
        guard s.range(of: #"^-?[0-9.,]*[0-9][0-9.,]*$"#, options: .regularExpression) != nil else { return nil }
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
        guard let d = Double(s), d.isFinite, abs(d) < 1e12 else { return nil }
        return d
    }

    /// Satış adetleri için: "1.120" gibi binlik ayırıcılı tam sayıları da tanır (yalnızca metin girişlerde kullanın).
    public static func parseQuantity(_ raw: String) -> Double? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.range(of: #"^-?\d{1,3}(\.\d{3})+$"#, options: .regularExpression) != nil {
            return Double(s.replacingOccurrences(of: ".", with: ""))
        }
        return parse(s)
    }

    /// Para tutarı girişi (birim maliyet, fatura fiyatı, ücret, ek ödeme): ekranda tutarlar binlik ayırıcı noktayla
    /// gösterildiğinden "35.000" / "1.050" / "1.295.867" binlik ayırıcılı tam sayı okunur (35.000 ₺ maaş 35 ₺ olmasın).
    /// İlk grup 0 ile başlarsa ("0.125") ya da grup üç haneli değilse ("1.05", "12.5") ondalık sayılır: `parse` ile aynı.
    /// Web: src/lib/format.ts `parseAmount` (/^-?[1-9][0-9]{0,2}(\.[0-9]{3})+$/).
    public static func parseAmount(_ raw: String) -> Double? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: "\u{202F}", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{2212}", with: "-")
        if s.hasPrefix("+") { s.removeFirst() }
        if s.range(of: #"^-?[1-9][0-9]{0,2}(\.[0-9]{3})+$"#, options: .regularExpression) != nil {
            guard let d = Double(s.replacingOccurrences(of: ".", with: "")), d.isFinite, abs(d) < 1e12 else { return nil }
            return d
        }
        return parse(s)
    }

    /// Excel'in sayısal hücrelerindeki makine biçimi ("1234.5", "4.4408920985006262E-16").
    public static func machine(_ raw: String) -> Double? {
        guard let d = Double(raw.trimmingCharacters(in: .whitespaces)), d.isFinite else { return nil }
        return d
    }
}

/// Günler "yyyy-MM-dd" anahtarlarıyla tutulur (sözlük sırası = tarih sırası).
/// Anahtar aritmetiği saat diliminden bağımsız, tam sayı takvim hesabıyla yapılır.
public enum DateKey {
    struct YMD: Equatable { var y: Int, m: Int, d: Int }

    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.locale = Locale(identifier: "tr_TR")
        c.timeZone = .autoupdatingCurrent
        return c
    }()

    private static let longFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = Locale(identifier: "tr_TR")
        f.timeZone = .autoupdatingCurrent
        f.dateFormat = "d MMMM yyyy, EEEE"
        return f
    }()

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = Locale(identifier: "tr_TR")
        f.timeZone = .autoupdatingCurrent
        f.dateFormat = "LLLL yyyy"
        return f
    }()

    // MARK: Takvim hesabı (H. Hinnant, "chrono-compatible low-level date algorithms")

    static func ymd(_ key: String) -> YMD? {
        let u = Array(key.utf8)
        guard u.count == 10, u[4] == 45, u[7] == 45 else { return nil }  // "-"
        func num(_ r: Range<Int>) -> Int? {
            var v = 0
            for i in r { guard u[i] >= 48 && u[i] <= 57 else { return nil }; v = v * 10 + Int(u[i] - 48) }
            return v
        }
        guard let y = num(0..<4), let m = num(5..<7), let d = num(8..<10),
              (1...12).contains(m), d >= 1, d <= daysInMonth(y, m) else { return nil }
        return YMD(y: y, m: m, d: d)
    }

    static func daysInMonth(_ y: Int, _ m: Int) -> Int {
        switch m {
        case 2: return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// 1970-01-01'den bu yana gün sayısı
    static func days(_ v: YMD) -> Int {
        let y = v.m <= 2 ? v.y - 1 : v.y
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (v.m > 2 ? v.m - 3 : v.m + 9) + 2) / 5 + v.d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func ymd(days z0: Int) -> YMD {
        let z = z0 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return YMD(y: yoe + era * 400 + (m <= 2 ? 1 : 0), m: m, d: d)
    }

    static func key(_ v: YMD) -> String { String(format: "%04ld-%02ld-%02ld", v.y, v.m, v.d) }

    // MARK: Genel API

    public static func string(from date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return key(YMD(y: c.year ?? 1970, m: c.month ?? 1, d: c.day ?? 1))
    }

    /// Yerel saatle günün başlangıcı (DatePicker ve grafikler için)
    public static func date(from key: String) -> Date? {
        guard let v = ymd(key) else { return nil }
        return calendar.date(from: DateComponents(year: v.y, month: v.m, day: v.d)).map { calendar.startOfDay(for: $0) }
    }

    public static func addDays(_ n: Int, to key: String) -> String {
        guard let v = ymd(key) else { return key }
        return Self.key(ymd(days: days(v) + n))
    }

    /// İki gün arasındaki fark (to - from), gün olarak
    public static func distance(from: String, to: String) -> Int? {
        guard let a = ymd(from), let b = ymd(to) else { return nil }
        return days(b) - days(a)
    }

    public static func today() -> String { string(from: Date()) }

    /// 1 Ağustos 2026, Cumartesi
    public static func long(_ key: String) -> String {
        guard let d = date(from: key) else { return key }
        return longFormatter.string(from: d)
    }

    /// Ağustos 2026
    public static func monthTitle(_ key: String) -> String {
        guard let d = date(from: key) else { return key }
        return monthFormatter.string(from: d)
    }

    /// 01.08.2026
    public static func short(_ key: String) -> String {
        guard let v = ymd(key) else { return key }
        return String(format: "%02ld.%02ld.%04ld", v.d, v.m, v.y)
    }

    private static let excelEpoch = days(YMD(y: 1899, m: 12, d: 30))

    /// Excel seri numarası (1900 sistemi): 2026-08-01 -> 46235
    public static func excelSerial(_ key: String) -> Double? {
        guard let v = ymd(key) else { return nil }
        return Double(days(v) - excelEpoch)
    }

    /// Excel seri numarası -> yyyy-MM-dd (46235 -> 2026-08-01)
    public static func fromExcelSerial(_ serial: Double) -> String? {
        guard serial.isFinite, serial > 1, serial < 2_958_465 else { return nil }
        return key(ymd(days: excelEpoch + Int(serial.rounded(.down))))
    }

    public static func startOfMonth(_ key: String) -> String {
        guard var v = ymd(key) else { return key }
        v.d = 1
        return Self.key(v)
    }

    public static func endOfMonth(_ key: String) -> String {
        guard var v = ymd(key) else { return key }
        v.d = daysInMonth(v.y, v.m)
        return Self.key(v)
    }

    public static func startOfPreviousMonth(_ key: String) -> String {
        guard var v = ymd(key) else { return key }
        v.d = 1
        if v.m == 1 { v.m = 12; v.y -= 1 } else { v.m -= 1 }
        return Self.key(v)
    }

    public static func isValid(_ key: String) -> Bool { ymd(key) != nil }
}
