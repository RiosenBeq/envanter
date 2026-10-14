import XCTest
@testable import EnvanterCore

/// Ortak satış vektörleri (web ile aynı dosyalar): rapor metni okuma (Fixtures/sales-vectors.json) ve aktarım uyarıları
/// (Fixtures/salesimport-vectors.json).
final class SalesVectorTests: XCTestCase {
    private func load(_ name: String) throws -> JSONValue {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json"))
        return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    }

    private func saleLines(_ v: JSONValue?) throws -> [SaleLine] { try JSONCoding.decode([SaleLine].self, from: v ?? .array([])) }

    private func skipped(_ v: JSONValue?) -> [SkippedRow] {
        (v?.arrayValue ?? []).map {
            SkippedRow(row: Int($0["row"]?.doubleValue ?? -1), text: $0["text"]?.stringValue ?? "", reason: $0["reason"]?.stringValue ?? "")
        }
    }

    func testParserVectors() throws {
        for c in try load("sales-vectors")["cases"]?.arrayValue ?? [] {
            let name = c["name"]?.stringValue ?? "?"
            let r = SalesParser.parse(text: c["text"]?.stringValue ?? "", sourceName: c["sourceName"]?.stringValue ?? "")
            let e = try XCTUnwrap(c["expected"])
            XCTAssertEqual(r.lines, try saleLines(e["lines"]), name)
            XCTAssertEqual(r.dateFrom, e["dateFrom"]?.stringValue, name)
            XCTAssertEqual(r.dateTo, e["dateTo"]?.stringValue, name)
            XCTAssertEqual(r.periodText, e["periodText"]?.stringValue, name)
            XCTAssertEqual(r.skipped, skipped(e["skipped"]), name)
            XCTAssertEqual(Double(r.codeRows), e["codeRows"]?.doubleValue, name)
            XCTAssertEqual(r.sourceName, c["sourceName"]?.stringValue, name)
        }
    }

    func testImportWarningVectors() throws {
        for c in try load("salesimport-vectors")["cases"]?.arrayValue ?? [] {
            let name = c["name"]?.stringValue ?? "?"
            let rv = try XCTUnwrap(c["report"])
            var report = SalesReport(lines: try saleLines(rv["lines"]), dateFrom: rv["dateFrom"]?.stringValue, dateTo: rv["dateTo"]?.stringValue,
                                     periodText: rv["periodText"]?.stringValue, sourceName: rv["sourceName"]?.stringValue ?? "")
            report.skipped = skipped(rv["skipped"])
            report.codeRows = Int(rv["codeRows"]?.doubleValue ?? 0)
            let data = try JSONCoding.decode(AppData.self, from: .object([
                "items": .array([]), "products": .array([]), "days": c["days"] ?? .object([:]),
            ]))
            let got = SalesImportCheck.warnings(report: report, targetDate: c["targetDate"]?.stringValue ?? "", data: data)
            let expected = (c["expected"]?.arrayValue ?? []).map { w in
                SalesImportWarning(kind: SalesImportWarning.Kind(rawValue: w["kind"]?.stringValue ?? "") ?? .skipped,
                                   tone: SalesImportWarning.Tone(rawValue: w["tone"]?.stringValue ?? "") ?? .info,
                                   text: w["text"]?.stringValue ?? "", date: w["date"]?.stringValue,
                                   blocking: w["blocking"]?.boolValue ?? false)
            }
            XCTAssertEqual(got, expected, name)
            XCTAssertEqual(SalesImportCheck.needsConfirmation(got), expected.contains { $0.blocking }, name)
        }
    }

    /// Excel yolu: okunamayan adet hücresi atlanır ve satır numarasıyla bildirilir; birimli metin adet okunur
    func testSheetSkippedRowsAndUnitQuantities() throws {
        var rows: [Int: [Int: String]] = [1: [1: "Tarih: 12.10.26"], 2: [1: "Kodu", 2: "Ürün Tipi", 3: "Birim Fiyatı", 4: "Adedi"]]
        rows[3] = [1: "11100", 2: "MEDIUM", 3: "185", 4: "12 adet"]
        rows[4] = [1: "11103", 2: "CHEESE", 3: "210"]
        rows[5] = [1: "19001", 2: "PATATES", 4: "1.125"]
        rows[6] = [1: "11152", 2: "KASAP", 4: "?"]
        let r = try SalesParser.parse(sheet: XlsxSheet(name: "Rapor", rows: rows, numericCells: [5: [4]]), sourceName: "x.xlsx")
        XCTAssertEqual(r.lines, [SaleLine(code: "11100", name: "MEDIUM", qty: 12), SaleLine(code: "19001", name: "PATATES", qty: 1.125)])
        XCTAssertEqual(r.skipped, [SkippedRow(row: 4, text: "11103 · CHEESE · 210", reason: "Adet okunamadı"),
                                   SkippedRow(row: 6, text: "11152 · KASAP · ?", reason: "Adet okunamadı")])
        XCTAssertEqual(r.codeRows, 4)
        XCTAssertEqual(r.dateFrom, "2026-10-12")
    }

    func testQuantityHelper() {
        XCTAssertEqual(SalesParser.quantity("1.120"), 1120)
        XCTAssertEqual(SalesParser.quantity("12,5"), 12.5)
        XCTAssertEqual(SalesParser.quantity("12 ADET"), 12)
        XCTAssertEqual(SalesParser.quantity("3pors."), 3)
        XCTAssertEqual(SalesParser.quantity("-"), 0)
        XCTAssertNil(SalesParser.quantity("2 KÖFTELİ"), "ürün adı adet sanılmaz")
        XCTAssertNil(SalesParser.quantity("MEDIUM"))
        XCTAssertNil(SalesParser.quantity(""))
    }
}
