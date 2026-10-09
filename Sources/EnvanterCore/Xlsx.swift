import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

// MARK: - Okuma

public struct XlsxSheet {
    public var name: String
    /// satır (1'den) -> sütun (1'den) -> metin değeri
    public var rows: [Int: [Int: String]]
    /// Sayısal hücreler (değerleri makine biçiminde: "1234.5"): satır -> sütunlar
    public var numericCells: [Int: Set<Int>] = [:]

    public init(name: String, rows: [Int: [Int: String]], numericCells: [Int: Set<Int>] = [:]) {
        self.name = name; self.rows = rows; self.numericCells = numericCells
    }

    public func value(row: Int, col: Int) -> String? { rows[row]?[col] }
    public var maxRow: Int { rows.keys.max() ?? 0 }
    public func isNumeric(row: Int, col: Int) -> Bool { numericCells[row]?.contains(col) ?? false }

    /// Hücrenin sayı değeri: sayısal hücrede makine biçimi, metin hücrede Türkçe/İngilizce yazım.
    public func number(row: Int, col: Int) -> Double? {
        guard let raw = value(row: row, col: col) else { return nil }
        return isNumeric(row: row, col: col) ? Fmt.machine(raw) : Fmt.parse(raw)
    }

    /// Satış adedi: metin hücrede "1.120" gibi binlik ayırıcılı yazımı da tanır.
    /// Sayısal hücrede "1.125" gerçekten 1,125'tir (binlik ayırıcı sanılmamalı).
    public func quantity(row: Int, col: Int) -> Double? {
        guard let raw = value(row: row, col: col) else { return nil }
        return isNumeric(row: row, col: col) ? Fmt.machine(raw) : Fmt.parseQuantity(raw)
    }
}

public enum XlsxReader {
    public static func read(url: URL) throws -> [XlsxSheet] {
        let data = try Data(contentsOf: url)
        return try read(data: data)
    }

    public static func read(data: Data) throws -> [XlsxSheet] {
        try read(zip: try ZipReader(data: data))
    }

    static func read(zip: ZipReader) throws -> [XlsxSheet] {
        guard zip.contains("xl/workbook.xml") else { throw ZipError.missing("xl/workbook.xml") }

        let wb = WorkbookParser()
        wb.parse(try zip.read("xl/workbook.xml"))
        let rels = RelsParser()
        if zip.contains("xl/_rels/workbook.xml.rels") { rels.parse(try zip.read("xl/_rels/workbook.xml.rels")) }

        var shared: [String] = []
        let sharedPath = rels.target(ofTypeSuffix: "/sharedStrings").map(resolve) ?? "xl/sharedStrings.xml"
        if zip.contains(sharedPath) {
            let p = SharedStringsParser()
            p.parse(try zip.read(sharedPath))
            shared = p.strings
        }

        var sheets: [XlsxSheet] = []
        for (i, s) in wb.sheets.enumerated() {
            let target = rels.targets[s.rid].map(resolve) ?? "xl/worksheets/sheet\(i + 1).xml"
            guard zip.contains(target) else { continue }
            let sp = SheetParser(shared: shared)
            sp.parse(try zip.read(target))
            sheets.append(XlsxSheet(name: s.name, rows: sp.rows, numericCells: sp.numeric))
        }
        guard !sheets.isEmpty else { throw ZipError.missing("çalışma sayfası") }
        return sheets
    }

    /// İlişki hedefini zip içindeki yola çevirir ("worksheets/sheet1.xml" -> "xl/worksheets/sheet1.xml")
    static func resolve(_ target: String) -> String {
        if target.hasPrefix("/") { return String(target.dropFirst()) }
        var parts = ["xl"]
        for p in target.split(separator: "/") {
            if p == ".." { if !parts.isEmpty { parts.removeLast() } } else if p != "." { parts.append(String(p)) }
        }
        return parts.joined(separator: "/")
    }

    /// "B9" -> (satır 9, sütun 2)
    static func position(_ ref: String) -> (row: Int, col: Int)? {
        var col = 0, rowStr = ""
        for ch in ref.unicodeScalars {
            if ch.value >= 65 && ch.value <= 90 { col = col * 26 + Int(ch.value - 64) }
            else if ch.value >= 97 && ch.value <= 122 { col = col * 26 + Int(ch.value - 96) }
            else if ch.value >= 48 && ch.value <= 57 { rowStr.unicodeScalars.append(ch) }
        }
        guard col > 0, let row = Int(rowStr) else { return nil }
        return (row, col)
    }
}

private final class SharedStringsParser: NSObject, XMLParserDelegate {
    var strings: [String] = []
    private var current = ""
    private var inSI = false, inT = false, inPhonetic = false

    func parse(_ data: Data) {
        let p = XMLParser(data: data); p.delegate = self; _ = p.parse()
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        switch name {
        case "si": inSI = true; current = ""
        case "t": inT = inSI && !inPhonetic
        case "rPh": inPhonetic = true
        default: break
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if inT { current += string } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "t": inT = false
        case "rPh": inPhonetic = false
        case "si": strings.append(current); inSI = false
        default: break
        }
    }
}

private final class WorkbookParser: NSObject, XMLParserDelegate {
    var sheets: [(name: String, rid: String)] = []
    func parse(_ data: Data) { let p = XMLParser(data: data); p.delegate = self; _ = p.parse() }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        guard name == "sheet" || name.hasSuffix(":sheet") else { return }
        // İlişki kimliği genelde "r:id"dir ama önek dosyadan dosyaya değişebilir
        let rid = attributes["r:id"] ?? attributes.first { $0.key.hasSuffix(":id") }?.value ?? attributes["id"] ?? ""
        sheets.append((attributes["name"] ?? "Sayfa", rid))
    }
}

private final class RelsParser: NSObject, XMLParserDelegate {
    var targets: [String: String] = [:]
    var types: [String: String] = [:]
    func parse(_ data: Data) { let p = XMLParser(data: data); p.delegate = self; _ = p.parse() }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if name == "Relationship", let id = attributes["Id"], let t = attributes["Target"] {
            targets[id] = t
            types[id] = attributes["Type"] ?? ""
        }
    }
    func target(ofTypeSuffix suffix: String) -> String? {
        types.first { $0.value.hasSuffix(suffix) }.flatMap { targets[$0.key] }
    }
}

private final class SheetParser: NSObject, XMLParserDelegate {
    var rows: [Int: [Int: String]] = [:]
    var numeric: [Int: Set<Int>] = [:]
    private let shared: [String]
    private var ref = "", type = "", text = ""
    private var inV = false, inT = false, inCell = false
    /// "r" niteliği olmayan satır/hücreler için sıra takibi (bazı programlar yazmaz)
    private var currentRow = 0, nextCol = 1

    init(shared: [String]) { self.shared = shared }
    func parse(_ data: Data) { let p = XMLParser(data: data); p.delegate = self; _ = p.parse() }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        switch name {
        case "row":
            currentRow = attributes["r"].flatMap { Int($0) } ?? (currentRow + 1)
            nextCol = 1
        case "c": inCell = true; ref = attributes["r"] ?? ""; type = attributes["t"] ?? ""; text = ""
        case "v": inV = true
        case "t": if inCell { inT = true }
        default: break
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inV || inT { text += string }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "v": inV = false
        case "t": inT = false
        case "c":
            inCell = false
            let pos = XlsxReader.position(ref) ?? (currentRow > 0 ? (currentRow, nextCol) : nil)
            guard let pos else { return }
            nextCol = pos.col + 1
            var value = text
            if type == "s", let idx = Int(text.trimmingCharacters(in: .whitespaces)), idx >= 0, idx < shared.count {
                value = shared[idx]
            }
            if !value.isEmpty {
                rows[pos.row, default: [:]][pos.col] = value
                if type.isEmpty || type == "n" { numeric[pos.row, default: []].insert(pos.col) }
            }
        default: break
        }
    }
}

// MARK: - Yazma

public struct XlsxCell {
    public enum Kind { case text(String), number(Double), date(Double), diff(Double), blank }
    public var kind: Kind
    public var bold: Bool
    public init(_ kind: Kind, bold: Bool = false) { self.kind = kind; self.bold = bold }
    public static func text(_ s: String, bold: Bool = false) -> XlsxCell { XlsxCell(.text(s), bold: bold) }
    public static func number(_ v: Double) -> XlsxCell { XlsxCell(.number(v)) }
    public static func optNumber(_ v: Double?) -> XlsxCell { v.map { .number($0) } ?? XlsxCell(.blank) }
    public static func date(serial: Double) -> XlsxCell { XlsxCell(.date(serial)) }
    public static func diff(_ v: Double?) -> XlsxCell { v.map { XlsxCell(.diff($0)) } ?? XlsxCell(.blank) }
}

public struct XlsxSheetData {
    public var name: String
    public var header: [String]
    public var rows: [[XlsxCell]]
    public var widths: [Double]
    public init(name: String, header: [String], rows: [[XlsxCell]], widths: [Double] = []) {
        self.name = name; self.header = header; self.rows = rows; self.widths = widths
    }
}

public enum XlsxWriter {
    public static func build(sheets: [XlsxSheetData]) -> Data {
        var zip = ZipWriter()
        let n = sheets.count
        var ct = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
        ct += #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">"#
        ct += #"<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>"#
        ct += #"<Default Extension="xml" ContentType="application/xml"/>"#
        ct += #"<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>"#
        ct += #"<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>"#
        for i in 1...max(n, 1) {
            ct += #"<Override PartName="/xl/worksheets/sheet\#(i).xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>"#
        }
        ct += "</Types>"
        zip.add("[Content_Types].xml", text: ct)

        zip.add("_rels/.rels", text: #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>"#)

        var wb = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>"#
        var rels = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
        for (i, s) in sheets.enumerated() {
            wb += #"<sheet name="\#(escape(sheetName(s.name, index: i)))" sheetId="\#(i + 1)" r:id="rId\#(i + 1)"/>"#
            rels += #"<Relationship Id="rId\#(i + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet\#(i + 1).xml"/>"#
        }
        wb += "</sheets></workbook>"
        rels += #"<Relationship Id="rId\#(n + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>"#
        zip.add("xl/workbook.xml", text: wb)
        zip.add("xl/_rels/workbook.xml.rels", text: rels)
        zip.add("xl/styles.xml", text: styles)
        for (i, s) in sheets.enumerated() { zip.add("xl/worksheets/sheet\(i + 1).xml", text: sheetXML(s)) }
        return zip.finish()
    }

    // 0 varsayılan, 1 başlık, 2 tarih, 3 fark (negatif kırmızı), 4 kalın metin
    private static let styles: String = #"""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
    <numFmts count="2"><numFmt numFmtId="164" formatCode="dd\.mm\.yyyy"/><numFmt numFmtId="165" formatCode="0.00_ ;[Red]\-0.00\ "/></numFmts>
    <fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts>
    <fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FFFCE4D6"/><bgColor indexed="64"/></patternFill></fill></fills>
    <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
    <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
    <cellXfs count="5">
    <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
    <xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1" applyAlignment="1"><alignment horizontal="center" vertical="center" wrapText="1"/></xf>
    <xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
    <xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
    <xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>
    </cellXfs>
    <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
    </styleSheet>
    """#

    private static func sheetName(_ raw: String, index: Int) -> String {
        let bad = CharacterSet(charactersIn: "[]:*?/\\")
        var s = String(raw.unicodeScalars.filter { !bad.contains($0) })
        if s.isEmpty { s = "Sayfa\(index + 1)" }
        return String(s.prefix(31))
    }

    private static func colName(_ i: Int) -> String {
        var n = i + 1, s = ""
        while n > 0 { let r = (n - 1) % 26; s = String(UnicodeScalar(65 + r)!) + s; n = (n - 1) / 26 }
        return s
    }

    private static func escape(_ s: String) -> String {
        var out = ""
        for u in s.unicodeScalars {
            switch u {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default:
                // XML 1.0'da geçersiz kontrol karakterlerini at
                if u.value < 0x20 && u.value != 9 && u.value != 10 && u.value != 13 { continue }
                out.unicodeScalars.append(u)
            }
        }
        return out
    }

    static func num(_ v: Double) -> String? {
        guard v.isFinite else { return nil }
        let r = (v * 1_000_000).rounded() / 1_000_000
        if r == 0 { return "0" }
        return r == r.rounded() && abs(r) < 1e15 ? String(Int64(r)) : String(r)
    }

    private static func sheetXML(_ s: XlsxSheetData) -> String {
        var x = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">"#
        x += #"<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>"#
        if !s.widths.isEmpty {
            x += "<cols>"
            for (i, w) in s.widths.enumerated() { x += #"<col min="\#(i + 1)" max="\#(i + 1)" width="\#(w)" customWidth="1"/>"# }
            x += "</cols>"
        }
        x += "<sheetData>"
        x += #"<row r="1" ht="32" customHeight="1">"#
        for (c, h) in s.header.enumerated() {
            x += #"<c r="\#(colName(c))1" s="1" t="inlineStr"><is><t xml:space="preserve">\#(escape(h))</t></is></c>"#
        }
        x += "</row>"
        for (r, row) in s.rows.enumerated() {
            let rn = r + 2
            x += #"<row r="\#(rn)">"#
            for (c, cell) in row.enumerated() {
                let ref = "\(colName(c))\(rn)"
                switch cell.kind {
                case .text(let t):
                    x += #"<c r="\#(ref)"\#(cell.bold ? #" s="4""# : "") t="inlineStr"><is><t xml:space="preserve">\#(escape(t))</t></is></c>"#
                case .number(let v): if let n = num(v) { x += #"<c r="\#(ref)"><v>\#(n)</v></c>"# }
                case .date(let v): if let n = num(v) { x += #"<c r="\#(ref)" s="2"><v>\#(n)</v></c>"# }
                case .diff(let v): if let n = num(v) { x += #"<c r="\#(ref)" s="3"><v>\#(n)</v></c>"# }
                case .blank: break
                }
            }
            x += "</row>"
        }
        x += "</sheetData></worksheet>"
        return x
    }
}
