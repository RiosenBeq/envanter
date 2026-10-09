import Foundation

public struct SalesReport {
    public var lines: [SaleLine]
    public var dateFrom: String?
    public var dateTo: String?
    public var periodText: String?
    public var sourceName: String

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
            let data = try Data(contentsOf: fileURL)
            let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .windowsCP1254)
                ?? String(decoding: data, as: UTF8.self)
            let r = parse(text: text, sourceName: name)
            if r.lines.isEmpty { throw SalesParseError.noLines }
            return r
        default:
            throw SalesParseError.unsupportedExtension(ext.isEmpty ? name : ".\(ext)")
        }
    }

    // MARK: Excel sayfası

    public static func parse(sheet: XlsxSheet, sourceName: String) throws -> SalesReport {
        // Başlık satırını bul: "Kodu" ve "Adedi" içeren satır
        var codeCol = 2, nameCol = 3, qtyCol = 4
        var headerRow = 0
        for r in 1...max(1, min(sheet.maxRow, 40)) {
            guard let row = sheet.rows[r] else { continue }
            var c: Int?, n: Int?, q: Int?
            for (col, v) in row {
                let k = normalize(v)
                if k == "kodu" || k == "kod" { c = col }
                if k.hasPrefix("urun") { n = n ?? col }
                if k == "adedi" || k == "adet" || k == "miktar" { q = col }
            }
            if let c, let q { codeCol = c; qtyCol = q; nameCol = n ?? (c + 1); headerRow = r; break }
        }
        var lines: [SaleLine] = []
        for r in (headerRow + 1)...max(headerRow + 1, sheet.maxRow) {
            guard let row = sheet.rows[r], let code = row[codeCol]?.trimmingCharacters(in: .whitespaces),
                  isCode(code) else { continue }
            let qty = row[qtyCol].flatMap { Fmt.parseQuantity($0) } ?? 0
            lines.append(SaleLine(code: code, name: (row[nameCol] ?? "").trimmingCharacters(in: .whitespaces), qty: qty))
        }
        // Tarih bilgisi: ilk satırlardaki metinler
        var headerText = ""
        for r in 1...max(1, min(headerRow == 0 ? 8 : headerRow, 12)) {
            for col in (sheet.rows[r] ?? [:]).keys.sorted() { headerText += " " + (sheet.rows[r]?[col] ?? "") }
        }
        let dates = extractDates(headerText)
        return build(lines: lines, dates: dates, periodText: periodText(from: headerText), source: sourceName)
    }

    // MARK: Metin (panodan yapıştırma / csv)

    public static func parse(text: String, sourceName: String) -> SalesReport {
        var lines: [SaleLine] = []
        var headerText = ""
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r\u{FEFF}"))
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let delim: Character = line.contains("\t") ? "\t" : (line.contains(";") ? ";" : ",")
            let fields = line.split(separator: delim, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard let codeIdx = fields.firstIndex(where: { isCode($0) }) else {
                if lines.isEmpty { headerText += " " + line }
                continue
            }
            let code = fields[codeIdx]
            var name = ""
            var qty: Double?
            for f in fields[(codeIdx + 1)...] {
                if f.isEmpty { continue }
                if name.isEmpty && Fmt.parseQuantity(f) == nil { name = f; continue }
                if !name.isEmpty || Fmt.parseQuantity(f) != nil {
                    if qty == nil, let q = Fmt.parseQuantity(f) { qty = q; break }
                }
            }
            lines.append(SaleLine(code: code, name: name, qty: qty ?? 0))
        }
        return build(lines: lines, dates: extractDates(headerText), periodText: periodText(from: headerText), source: sourceName)
    }

    // MARK: Yardımcılar

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

    /// "Tarih.:1.08.2026 31.08.2026" -> ["2026-08-01", "2026-08-31"]
    static func extractDates(_ text: String) -> [String] {
        let pattern = #"(\d{1,2})[./](\d{1,2})[./](\d{4})"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var out: [String] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let d = Int(ns.substring(with: m.range(at: 1))) ?? 0
            let mo = Int(ns.substring(with: m.range(at: 2))) ?? 0
            let y = Int(ns.substring(with: m.range(at: 3))) ?? 0
            let key = String(format: "%04d-%02d-%02d", y, mo, d)
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
