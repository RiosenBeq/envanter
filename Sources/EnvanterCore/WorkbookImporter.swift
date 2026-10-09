import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Eski Excel envanter dosyasındaki (01.08.xlsm gibi) verileri uygulamaya aktarır:
///  • Alımlar sayfası ve (sayfa temizlenmişse) onun pivot önbelleğindeki geçmiş günlük kayıtlar
///  • Envanter sayfasındaki güncel gün: Açılış / Gelen / Transferler / Kapanış
///  • Envanter sayfasının sağına (AA:AC) yapıştırılmış ModPos satışları
public struct WorkbookImport {
    public var days: [String: DayRecord] = [:]
    public var sourceName: String = ""
    /// Geçmiş (Alımlar / pivot önbelleği) günleri
    public var historyDates: [String] = []
    /// Envanter sayfasındaki güncel gün (varsa)
    public var currentDate: String?
    public var currentSalesLines = 0
    public var currentCountedItems = 0
    /// Aynı gün/kalem için birden fazla kayıt vardı; kapanışı olan kullanıldı
    public var duplicatesResolved = 0
    public var skippedItemNames: [String] = []
    public var notes: [String] = []

    public var isEmpty: Bool { days.isEmpty }
}

public struct WorkbookImportReport {
    public var added = 0
    public var replaced = 0
    public var skippedExisting = 0
    public init() {}
}

public enum WorkbookImportError: Error, LocalizedError {
    case unsupported, nothingFound
    public var errorDescription: String? {
        switch self {
        case .unsupported: return "Bu dosya okunamadı. Lütfen Excel envanter dosyasını (.xlsm veya .xlsx) seçin."
        case .nothingFound: return "Dosyada aktarılabilir envanter verisi bulunamadı (Envanter / Alımlar sayfası boş görünüyor)."
        }
    }
}

public enum WorkbookImporter {
    // MARK: - Ürün adı eşleme

    /// "90 Gr / Adet", "Fillet Kg", "Dana Füme / Kg" -> karşılaştırma anahtarı
    static func key(_ s: String) -> String {
        var t = s.lowercased(with: Locale(identifier: "tr_TR")).replacingOccurrences(of: "/", with: " ")
        t = t.split(whereSeparator: { $0 == " " || $0 == "\u{00A0}" }).joined(separator: " ")
        for suffix in [" adet", " kg"] where t.hasSuffix(suffix) { t.removeLast(suffix.count) }
        return t
    }

    private static let aliases: [String: String] = [
        "150 gr": "g130", "smash 80 gr": "smash70", "füme": "fume", "peynir": "peynir",
        "tavuk 90 gr": "lezita90", "soğan halkası": "soganHalkasi",
    ]

    static func itemID(for label: String, items: [Item]) -> String? {
        let k = key(label)
        if let it = items.first(where: { key($0.name) == k || key(Exporter.label($0)) == k }) { return it.id }
        if let id = aliases[k], items.contains(where: { $0.id == id }) { return id }
        return nil
    }

    // MARK: - Ayrıştırma

    public static func parse(url: URL, items: [Item]) throws -> WorkbookImport {
        let data = try Data(contentsOf: url)
        return try parse(data: data, sourceName: url.lastPathComponent, items: items)
    }

    struct Rec {
        var date: String
        var itemID: String
        var opening, incoming, trIn, trOut, closing, sold, waste: Double?
    }

    public static func parse(data: Data, sourceName: String, items: [Item]) throws -> WorkbookImport {
        guard let zip = try? ZipReader(data: data), zip.contains("xl/workbook.xml") else { throw WorkbookImportError.unsupported }
        let sheets = try XlsxReader.read(zip: zip)
        var result = WorkbookImport()
        result.sourceName = sourceName
        var skipped = Set<String>()

        /// Aynı kaynakta aynı gün/kalem için birden fazla kayıt olabilir (makro iki kez çalıştırılmış gibi):
        /// kapanışı olan en son kayıt kullanılır.
        func collect(_ rows: [(date: String, label: String, values: [Double?])]) -> [String: Rec] {
            var grouped: [String: [Rec]] = [:]
            var order: [String] = []
            for row in rows {
                guard let id = itemID(for: row.label, items: items) else {
                    if !row.label.isEmpty { skipped.insert(row.label) }
                    continue
                }
                let v = row.values
                let key = row.date + "|" + id
                if grouped[key] == nil { order.append(key) }
                grouped[key, default: []].append(Rec(date: row.date, itemID: id, opening: v[0], incoming: v[1], trIn: v[2],
                                                     trOut: v[3], closing: v[4], sold: v[5], waste: v[6]))
            }
            var out: [String: Rec] = [:]
            for key in order {
                let list = grouped[key]!
                if list.count > 1 { result.duplicatesResolved += 1 }
                out[key] = list.last { $0.closing != nil } ?? list.last!
            }
            return out
        }

        // 1) Geçmiş: pivot önbelleği (Alımlar sayfası temizlenmiş olabilir)
        let cached = collect(PivotHistory.rows(zip: zip).map { ($0.date, $0.item, $0.values) })
        // 2) Geçmiş: Alımlar sayfasındaki satırlar (önbellekteki aynı gün/kalem kaydının yerine geçer)
        var sheetRows: [(date: String, label: String, values: [Double?])] = []
        if let alim = sheets.first(where: { key($0.name) == "alımlar" }) {
            for r in 1...max(1, alim.maxRow) {
                guard let row = alim.rows[r], let dateCell = row[1], let label = row[2] else { continue }
                guard let date = dateKey(from: dateCell) else { continue }
                sheetRows.append((date, label, (3...9).map { alim.number(row: r, col: $0) }))
            }
        }
        let chosen = Array(cached.merging(collect(sheetRows)) { _, sheet in sheet }.values)

        var days: [String: DayRecord] = [:]
        for r in chosen {
            var entry = DayEntry(opening: r.opening, incoming: r.incoming, transferIn: r.trIn,
                                 transferOut: r.trOut, closing: r.closing)
            if entry.isEmpty && (r.sold ?? 0) == 0 && (r.waste ?? 0) == 0 { continue }
            // Excel boş hücreyi 0 gibi okurdu; 0 olan transfer/gelen değerlerini boş bırak
            if entry.incoming == 0 { entry.incoming = nil }
            if entry.transferIn == 0 { entry.transferIn = nil }
            if entry.transferOut == 0 { entry.transferOut = nil }
            var day = days[r.date] ?? DayRecord(date: r.date, importedFrom: sourceName)
            if !entry.isEmpty { day.entries[r.itemID] = entry }
            if let s = r.sold, s != 0 { day.legacySold = (day.legacySold ?? [:]).merging([r.itemID: s]) { $1 } }
            if let w = r.waste, w != 0 { day.legacyWaste = (day.legacyWaste ?? [:]).merging([r.itemID: w]) { $1 } }
            days[r.date] = day
        }
        // Ne kapanış sayımı ne de satış verisi olan günleri (boş taslaklar) alma.
        // Satışı olup sayımı yapılmamış günler korunur; özet raporlarda sayılmazlar.
        days = days.filter { _, d in d.entries.values.contains { $0.closing != nil } || !(d.legacySold ?? [:]).isEmpty }
        result.historyDates = days.keys.sorted()

        // 3) Güncel gün: Envanter sayfası
        if let env = sheets.first(where: { key($0.name) == "envanter" }) {
            let date = env.value(row: 1, col: 28).flatMap { dateKey(from: $0) }
            var entries: [String: DayEntry] = [:]
            for r in 4...max(4, min(env.maxRow, 60)) {
                guard let row = env.rows[r], let label = row[2], let id = itemID(for: label, items: items) else { continue }
                func n(_ c: Int) -> Double? { env.number(row: r, col: c) }
                var e = DayEntry(opening: n(3), incoming: n(4), transferIn: n(5), transferOut: n(6), closing: n(7))
                if e.incoming == 0 { e.incoming = nil }
                if e.transferIn == 0 { e.transferIn = nil }
                if e.transferOut == 0 { e.transferOut = nil }
                if !e.isEmpty { entries[id] = e }
            }
            var lines: [SaleLine] = []
            for r in 1...max(1, env.maxRow) {
                guard let row = env.rows[r], let code = row[27]?.trimmingCharacters(in: .whitespaces), SalesParser.isCode(code) else { continue }
                lines.append(SaleLine(code: code, name: (row[28] ?? "").trimmingCharacters(in: .whitespaces),
                                      qty: env.quantity(row: r, col: 29) ?? 0))
            }
            lines = SalesParser.mergeLines(lines)
            if let date, !(entries.isEmpty && lines.isEmpty) {
                var day = DayRecord(date: date, entries: entries, sales: lines, importedFrom: sourceName)
                if !lines.isEmpty {
                    day.salesSource = "\(sourceName) (Envanter sayfası)"
                    day.salesPeriod = nil
                    day.salesImportedAt = Date()
                }
                days[date] = day
                result.currentDate = date
                result.currentSalesLines = lines.count
                result.currentCountedItems = entries.count
            } else if date == nil && !(entries.isEmpty && lines.isEmpty) {
                result.notes.append("Envanter sayfasında tarih (AB1) okunamadığı için güncel gün aktarılamadı.")
            }
        }

        result.days = days
        result.skippedItemNames = skipped.sorted()
        if days.isEmpty { throw WorkbookImportError.nothingFound }
        return result
    }

    /// Excel hücresi: seri numarası ("46082") ya da metin tarih ("01.03.2026", "2026-03-01")
    static func dateKey(from cell: String) -> String? {
        let t = cell.trimmingCharacters(in: .whitespaces)
        if let d = Fmt.machine(t), let k = DateKey.fromExcelSerial(d) { return k }
        if t.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil {
            let k = String(t.prefix(10)); return DateKey.isValid(k) ? k : nil
        }
        return SalesParser.extractDates(t).first
    }

    // MARK: - Uygulama

    /// İçe aktarılan günleri veriye ekler. `overwrite` false ise veri girilmiş mevcut günlere dokunulmaz.
    @discardableResult
    public static func apply(_ imp: WorkbookImport, to data: inout AppData, overwrite: Bool) -> WorkbookImportReport {
        var report = WorkbookImportReport()
        for (date, day) in imp.days {
            if let existing = data.days[date], !existing.isEmpty {
                if overwrite { data.days[date] = day; report.replaced += 1 } else { report.skippedExisting += 1 }
            } else {
                data.days[date] = day; report.added += 1
            }
        }
        return report
    }

    /// Mevcut günlerden hangileri çakışır
    public static func conflicts(_ imp: WorkbookImport, in data: AppData) -> [String] {
        imp.days.keys.filter { !(data.days[$0]?.isEmpty ?? true) }.sorted()
    }
}

// MARK: - Pivot önbelleğinden Alımlar geçmişi

enum PivotHistory {
    struct Row { var date: String; var item: String; var values: [Double?] }

    static func rows(zip: ZipReader) -> [Row] {
        var best: [Row] = []
        for name in zip.names where name.hasPrefix("xl/pivotCache/pivotCacheDefinition") && name.hasSuffix(".xml") {
            guard let defData = try? zip.read(name) else { continue }
            let def = DefinitionParser()
            def.parse(defData)
            guard def.sheet == "Alımlar", def.fields.count >= 11,
                  def.fields[0].name == "Tarih", def.fields[1].name == "Ürün" else { continue }
            // kayıtlar: ilişki dosyasından, yoksa aynı numara
            let num = name.replacingOccurrences(of: "xl/pivotCache/pivotCacheDefinition", with: "").replacingOccurrences(of: ".xml", with: "")
            let recName = "xl/pivotCache/pivotCacheRecords\(num).xml"
            guard let recData = try? zip.read(recName) else { continue }
            let rp = RecordsParser(fields: def.fields)
            rp.parse(recData)
            if rp.rows.count > best.count { best = rp.rows }
        }
        return best
    }

    enum Cell { case missing, number(Double), text(String) }
    struct Field { var name: String; var shared: [Cell] }

    final class DefinitionParser: NSObject, XMLParserDelegate {
        var sheet = ""
        var fields: [Field] = []
        private var inShared = false
        func parse(_ d: Data) { let p = XMLParser(data: d); p.delegate = self; _ = p.parse() }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
            switch name {
            case "worksheetSource": sheet = a["sheet"] ?? ""
            case "cacheField": fields.append(Field(name: a["name"] ?? "", shared: []))
            case "sharedItems": inShared = true
            case "s", "d": if inShared, !fields.isEmpty { fields[fields.count - 1].shared.append(.text(a["v"] ?? "")) }
            case "n": if inShared, !fields.isEmpty { fields[fields.count - 1].shared.append(.number(Double(a["v"] ?? "") ?? 0)) }
            case "m": if inShared, !fields.isEmpty { fields[fields.count - 1].shared.append(.missing) }
            default: break
            }
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "sharedItems" { inShared = false }
        }
    }

    final class RecordsParser: NSObject, XMLParserDelegate {
        let fields: [Field]
        var rows: [Row] = []
        private var current: [Cell] = []
        init(fields: [Field]) { self.fields = fields }
        func parse(_ d: Data) { let p = XMLParser(data: d); p.delegate = self; _ = p.parse() }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
            switch name {
            case "r": current = []
            case "x":
                let i = current.count
                let idx = Int(a["v"] ?? "") ?? -1
                if i < fields.count, idx >= 0, idx < fields[i].shared.count { current.append(fields[i].shared[idx]) } else { current.append(.missing) }
            case "n": current.append(.number(Double(a["v"] ?? "") ?? 0))
            case "s", "d": current.append(.text(a["v"] ?? ""))
            case "m", "b", "e": current.append(.missing)
            default: break
            }
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            guard name == "r", current.count >= 11 else { return }
            var date: String?
            switch current[0] {
            case .text(let t): date = t.count >= 10 ? String(t.prefix(10)) : nil
            case .number(let n): date = DateKey.fromExcelSerial(n)
            case .missing: date = nil
            }
            guard let date, DateKey.isValid(date), case .text(let item) = current[1], !item.isEmpty else { return }
            func num(_ i: Int) -> Double? { if case .number(let n) = current[i] { return n } else { return nil } }
            // Açılış, Gelen, Gelen Transfer, Giden Transfer, Kapanış, Satılan, Zaiyat
            rows.append(Row(date: date, item: item, values: [num(2), num(3), num(4), num(5), num(6), num(7), num(8)]))
        }
    }
}
