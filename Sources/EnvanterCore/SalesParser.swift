import Foundation

/// Kodu olan ama adedi okunamayan rapor satırı (yalnızca önizlemede gösterilir; kaydedilmez)
public struct SkippedRow: Hashable, Sendable {
    /// Dosyadaki satır numarası (1'den)
    public var row: Int
    /// Satırın ham metni
    public var text: String
    public var reason: String
    public init(row: Int, text: String, reason: String) { self.row = row; self.text = text; self.reason = reason }
}

public struct SalesReport {
    public var lines: [SaleLine]
    public var dateFrom: String?
    public var dateTo: String?
    public var periodText: String?
    public var sourceName: String
    /// Adedi okunamadığı için alınmayan satırlar (yalnızca bellekte)
    public var skipped: [SkippedRow] = []
    /// Kodu olan satır sayısı (birleştirmeden önce, okunamayanlar dahil)
    public var codeRows: Int = 0

    /// Rapor birden fazla günü kapsıyor mu (ör. 1.08.2026 - 31.08.2026)
    public var isMultiDay: Bool { dateFrom != nil && dateTo != nil && dateFrom != dateTo }
    public var totalQty: Double { lines.reduce(0) { $0 + $1.qty } }
}

public enum SalesParseError: Error, LocalizedError {
    case noLines
    case unsupportedExtension(String)
    public var errorDescription: String? {
        switch self {
        case .noLines:
            return "Dosyada satış satırı bulunamadı. ModPos satış raporunda \"Kodu\", \"Ürün Tipi\" ve \"Adedi\" sütunları olmalı."
        case .unsupportedExtension(let e):
            return "\"\(e)\" dosya türü desteklenmiyor. Lütfen .xlsx, .csv veya .txt kullanın (.xls ise Excel'de .xlsx olarak kaydedin)."
        }
    }
}

public enum SalesParser {
    public static func parse(fileURL: URL) throws -> SalesReport {
        let ext = fileURL.pathExtension.lowercased()
        let name = fileURL.lastPathComponent
        switch ext {
        case "xlsx", "xlsm":
            let sheets = try XlsxReader.read(url: fileURL)
            // İlk satış satırı bulunan sayfayı kullan
            for s in sheets {
                if let r = try? parse(sheet: s, sourceName: name), !r.lines.isEmpty { return r }
            }
            throw SalesParseError.noLines
        case "csv", "tsv", "txt":
            let r = parse(text: decodeText(try Data(contentsOf: fileURL)), sourceName: name)
            if r.lines.isEmpty { throw SalesParseError.noLines }
            return r
        default:
            throw SalesParseError.unsupportedExtension(ext.isEmpty ? name : ".\(ext)")
        }
    }

    // MARK: Excel sayfası

    public static func parse(sheet: XlsxSheet, sourceName: String) throws -> SalesReport {
        // Başlık satırını bul: "Kodu" ve "Adedi" içeren satır (sütunlar soldan sağa taranır).
        // Tutar sütunu okunmaz (yalnızca miktarlar); "Ürün Tutarı" gibi başlığı ürün adı sanılmasın diye atlanır.
        var codeCol = 2, nameCol = 3, qtyCol = 4
        var headerRow = 0
        for r in 1...max(1, min(sheet.maxRow, 40)) {
            guard let row = sheet.rows[r] else { continue }
            if let h = headerColumns(row.keys.sorted().map { ($0, normalize(row[$0] ?? "")) }) {
                codeCol = h.code; qtyCol = h.qty; nameCol = h.name; headerRow = r; break
            }
        }
        var lines: [SaleLine] = []
        var skipped: [SkippedRow] = []
        var codeRows = 0
        for r in (headerRow + 1)...max(headerRow + 1, sheet.maxRow) {
            guard let row = sheet.rows[r], let code = row[codeCol]?.trimmingCharacters(in: .whitespaces),
                  isCode(code) else { continue }
            codeRows += 1
            let raw = row[qtyCol] ?? ""
            guard let qty = sheet.isNumeric(row: r, col: qtyCol) ? Fmt.machine(raw) : quantity(raw) else {
                let text = row.keys.sorted().compactMap { row[$0] }.joined(separator: " · ")
                skipped.append(SkippedRow(row: r, text: text, reason: unreadableQuantity))
                continue
            }
            lines.append(SaleLine(code: code, name: (row[nameCol] ?? "").trimmingCharacters(in: .whitespaces), qty: qty))
        }
        // Tarih bilgisi: ilk satırlardaki metinler
        var headerText = ""
        for r in 1...max(1, min(headerRow == 0 ? 8 : headerRow, 12)) {
            for col in (sheet.rows[r] ?? [:]).keys.sorted() { headerText += " " + (sheet.rows[r]?[col] ?? "") }
        }
        let dates = extractDates(headerText)
        var report = build(lines: lines, dates: dates, periodText: periodText(from: headerText), source: sourceName)
        report.skipped = skipped
        report.codeRows = codeRows
        return report
    }

    /// Metin dosyasının kodlamasını tahmin eder: BOM'lu UTF-8/UTF-16 (Excel "Unicode Metin"), UTF-8, Windows-1254.
    public static func decodeText(_ data: Data) -> String {
        let b = [UInt8](data.prefix(3))
        if b.count >= 2 && b[0] == 0xFF && b[1] == 0xFE, let s = String(data: data, encoding: .utf16LittleEndian) {
            return s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s
        }
        if b.count >= 2 && b[0] == 0xFE && b[1] == 0xFF, let s = String(data: data, encoding: .utf16BigEndian) {
            return s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s
        }
        if b.count == 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF, let s = String(data: data.dropFirst(3), encoding: .utf8) {
            return s
        }
        return String(data: data, encoding: .utf8) ?? windows1254(data)
    }

    /// Windows-1254 (Türkçe ANSI; eski Excel/ModPos CSV'leri). Latin-1'den farkı 0x80–0x9F aralığı ve 6 Türkçe harftir.
    /// Kod sayfası her platformda bulunmadığından (ör. Linux) elle çözülür.
    static func windows1254(_ data: Data) -> String {
        let high: [UInt32] = [
            0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8D, 0x8E, 0x8F,
            0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D, 0x9E, 0x0178,
        ]
        let turkish: [UInt8: UInt32] = [0xD0: 0x011E, 0xDD: 0x0130, 0xDE: 0x015E, 0xF0: 0x011F, 0xFD: 0x0131, 0xFE: 0x015F]
        var out = String.UnicodeScalarView()
        for b in data {
            let v: UInt32 = (0x80...0x9F).contains(b) ? high[Int(b) - 0x80] : (turkish[b] ?? UInt32(b))
            if let u = Unicode.Scalar(v) { out.append(u) }
        }
        return String(out)
    }

    /// Tırnak içindeki ayırıcıları bölmeden satırı alanlara ayırır ("MENÜ, BÜYÜK" tek alan kalır).
    static func splitFields(_ line: String, delimiter: Character) -> [String] {
        guard line.contains("\"") else {
            return line.split(separator: delimiter, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        }
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var chars = line.makeIterator()
        var pending: Character? = nil
        while let ch = pending ?? chars.next() {
            pending = nil
            if inQuotes {
                if ch == "\"" {
                    if let next = chars.next() {
                        if next == "\"" { current.append("\"") } else { inQuotes = false; pending = next }
                    } else { inQuotes = false }
                } else { current.append(ch) }
            } else if ch == "\"" && current.trimmingCharacters(in: .whitespaces).isEmpty {
                inQuotes = true; current = ""
            } else if ch == delimiter {
                fields.append(current.trimmingCharacters(in: .whitespaces)); current = ""
            } else { current.append(ch) }
        }
        fields.append(current.trimmingCharacters(in: .whitespaces))
        return fields
    }

    // MARK: Metin (panodan yapıştırma / csv)

    /// Metin satırları: başlık satırı ("Kodu" + "Adedi" sütunları) varsa sütunlar ondan alınır; yoksa satırdaki ilk kod
    /// alanı kod, sonraki ilk sayı olmayan alan ürün adı, ilk sayı adettir (sonraki sayılar, ör. tutar, okunmaz).
    /// Kodu olup adedi okunamayan satırlar `skipped`'e yazılır.
    public static func parse(text: String, sourceName: String) -> SalesReport {
        var lines: [SaleLine] = []
        var skipped: [SkippedRow] = []
        var codeRows = 0
        var headerText = ""
        var columns: HeaderColumns?
        let rows = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines)
        for (index, raw) in rows.enumerated() {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r\u{FEFF}"))
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let delim: Character = line.contains("\t") ? "\t" : (line.contains(";") ? ";" : ",")
            let fields = splitFields(line, delimiter: delim)
            let found: Int?
            if let cols = columns {
                found = cols.code < fields.count && isCode(fields[cols.code]) ? cols.code : nil
            } else {
                found = fields.firstIndex(where: { isCode($0) })
            }
            guard let codeIdx = found else {
                // Başlık satırı sütunları belirler (sonradan tekrar eden başlık da)
                if let h = headerColumns(fields.enumerated().map { ($0.offset, normalize($0.element)) }) { columns = h }
                if codeRows == 0 { headerText += " " + line }
                continue
            }
            codeRows += 1
            let code = fields[codeIdx]
            var name = ""
            var qty: Double?
            if let cols = columns {
                name = cols.name < fields.count ? fields[cols.name] : ""
                qty = cols.qty < fields.count ? quantity(fields[cols.qty]) : nil
            } else {
                for f in fields[(codeIdx + 1)...] where !f.isEmpty {
                    if let v = quantity(f) {
                        qty = v
                        break
                    } else if name.isEmpty { name = f }
                }
            }
            guard let qty else {
                skipped.append(SkippedRow(row: index + 1, text: line.trimmingCharacters(in: .whitespaces), reason: unreadableQuantity))
                continue
            }
            lines.append(SaleLine(code: code, name: name, qty: qty))
        }
        var report = build(lines: lines, dates: extractDates(headerText), periodText: periodText(from: headerText), source: sourceName)
        report.skipped = skipped
        report.codeRows = codeRows
        return report
    }

    // MARK: Yardımcılar

    /// "Tutar", "Tutarı", "Toplam Tutar", "Net Tutar", "Ciro" gibi başlıklar (okunmayan tutar sütunu)
    static func isAmountHeader(_ k: String) -> Bool {
        k == "tutar" || k == "tutari" || k == "ciro" || k == "toplam" || k == "net"
            || k.hasSuffix(" tutar") || k.hasSuffix(" tutari") || k.hasPrefix("tutar ")
    }

    /// Okunmayan diğer sütunlar: sıra numarası, fiyat, KDV ("Birim Fiyat" adet sanılmasın, "Ürün Fiyatı" ad sanılmasın)
    static func isIgnoredHeader(_ k: String) -> Bool {
        ["sira", "sira no", "no", "fiyat", "fiyati", "birim fiyat", "birim fiyati", "kdv"].contains(k)
            || k.hasSuffix(" fiyat") || k.hasSuffix(" fiyati") || k.hasPrefix("kdv ")
    }

    struct HeaderColumns: Equatable { var code: Int, name: Int, qty: Int }

    /// Başlık satırı: "Kodu" ve "Adedi" sütunları olan satır (sütunlar soldan sağa; değerler `normalize` edilmiş).
    /// Ad sütunu "Ürün Tipi" / "Ürün Adı" / "Ürün", yoksa "Ürün…" ile başlayan ilk başlık, o da yoksa koddan sonraki sütun.
    static func headerColumns(_ cells: [(Int, String)]) -> HeaderColumns? {
        var c: Int?, n: Int?, exactName: Int?, q: Int?
        for (col, k) in cells {
            if c == nil, k == "kodu" || k == "kod" || k == "urun kodu" { c = col; continue }
            if q == nil, k == "adedi" || k == "adet" || k == "miktar" || k == "miktari" { q = col; continue }
            if isAmountHeader(k) || isIgnoredHeader(k) { continue }
            if exactName == nil, k == "urun tipi" || k == "urun adi" || k == "urun" { exactName = col }
            if n == nil, k.hasPrefix("urun") { n = col }
        }
        guard let c, let q else { return nil }
        return HeaderColumns(code: c, name: exactName ?? n ?? (c + 1), qty: q)
    }

    static let unreadableQuantity = "Adet okunamadı"

    /// Adet yanındaki birimler ("12 adet", "12,00 Ad.", "3 porsiyon")
    static let quantityUnits: Set<String> = ["adet", "ad", "adt", "tane", "tn", "porsiyon", "pors", "prs", "kg", "gr", "g",
                                             "lt", "l", "ml", "pk", "paket", "kutu", "koli"]

    /// Metin adet: "1.120" (binlik), "12,5", birimli ("12 adet", "12,00 Ad.") ya da tek başına "-" (sıfır).
    /// Okunamazsa nil.
    static func quantity(_ raw: String) -> Double? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s == "-" || s == "–" || s == "—" { return 0 }
        if let v = Fmt.parseQuantity(s) { return v }
        guard let m = s.range(of: #"^([-+]?[0-9][0-9.,]*)\s*([A-Za-zÇĞİÖŞÜçğıöşü.]+)$"#, options: .regularExpression) else { return nil }
        let part = String(s[m])
        guard let split = part.firstIndex(where: { !"+-0123456789.,".contains($0) }) else { return nil }
        var number = String(part[..<split]).trimmingCharacters(in: .whitespaces)
        let unit = normalize(String(part[split...]).replacingOccurrences(of: ".", with: ""))
        guard quantityUnits.contains(unit) else { return nil }
        // "12,00 Ad." gibi: sayının sonundaki nokta birimin kısaltma noktası değildir; sayıya ait değilse at
        while number.hasSuffix(".") || number.hasSuffix(",") { number.removeLast() }
        return Fmt.parseQuantity(number)
    }

    /// Aynı kod birden fazla kez geçerse toplar; adedi 0 olanları atar.
    public static func mergeLines(_ lines: [SaleLine]) -> [SaleLine] {
        var order: [String] = []
        var merged: [String: SaleLine] = [:]
        for l in lines {
            if var m = merged[l.code] {
                m.qty += l.qty
                if m.name.isEmpty { m.name = l.name }
                merged[l.code] = m
            } else { merged[l.code] = l; order.append(l.code) }
        }
        return order.compactMap { merged[$0] }.filter { $0.qty != 0 }
    }

    private static func build(lines: [SaleLine], dates: [String], periodText: String?, source: String) -> SalesReport {
        let clean = mergeLines(lines)
        return SalesReport(lines: clean, dateFrom: dates.first, dateTo: dates.count > 1 ? dates[1] : dates.first,
                           periodText: periodText, sourceName: source)
    }

    public static func isCode(_ s: String) -> Bool {
        s.range(of: #"^\d{3,}$"#, options: .regularExpression) != nil
    }

    static func normalize(_ s: String) -> String {
        s.lowercased(with: Locale(identifier: "tr_TR"))
            .folding(options: [.diacriticInsensitive], locale: Locale(identifier: "tr_TR"))
            .replacingOccurrences(of: "ı", with: "i")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "Tarih.:1.08.2026 31.08.2026" -> ["2026-08-01", "2026-08-31"]. Ayrıca 01-08-2026, 2026-08-01 ve 01.08.26
    /// (iki haneli yıl 20yy) yazımları.
    public static func extractDates(_ text: String) -> [String] {
        let pattern = #"(?<!\d)(?:(\d{4})-(\d{1,2})-(\d{1,2})|(\d{1,2})([./-])(\d{1,2})\5(\d{4}|\d{2}))(?!\d)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var out: [String] = []
        func group(_ m: NSTextCheckingResult, _ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let y: Int, mo: Int, d: Int
            if let iso = group(m, 1) {
                y = Int(iso) ?? 0
                mo = Int(group(m, 2) ?? "") ?? 0
                d = Int(group(m, 3) ?? "") ?? 0
            } else {
                d = Int(group(m, 4) ?? "") ?? 0
                mo = Int(group(m, 6) ?? "") ?? 0
                let ys = group(m, 7) ?? ""
                y = ys.count == 2 ? 2000 + (Int(ys) ?? -2000) : (Int(ys) ?? 0)
            }
            let key = String(format: "%04ld-%02ld-%02ld", y, mo, d)
            if DateKey.isValid(key) { out.append(key) }
        }
        return out
    }

    static func periodText(from text: String) -> String? {
        let dates = extractDates(text)
        guard let f = dates.first else { return nil }
        let l = dates.count > 1 ? dates[1] : f
        return f == l ? DateKey.short(f) : "\(DateKey.short(f)) – \(DateKey.short(l))"
    }
}
