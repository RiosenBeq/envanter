import XCTest
@testable import EnvanterCore

/// Ortak dışa aktarım vektörleri (Fixtures/export-vectors.json; web: test/people/exportVectors.test.ts aynı dosyayı okur):
/// sayım şablonu (başlık satırıyla), gün kitabı ve sipariş önerisinin sayfa adları, başlıkları ve sütun genişlikleri; satış durumu metinleri;
/// dosya adları. Web paneli (Windows mağaza bilgisayarı) aynı Excel dosyalarını üretir.
final class ExportVectorTests: XCTestCase {
    private func vectors() throws -> JSONValue {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/export-vectors", withExtension: "json"))
        return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    }

    private func strings(_ v: JSONValue?) -> [String] { (v?.arrayValue ?? []).compactMap { $0.stringValue } }
    private func numbers(_ v: JSONValue?) -> [Double] { (v?.arrayValue ?? []).compactMap { $0.doubleValue } }

    private func text(_ c: XlsxCell) -> String? { if case .text(let t) = c.kind { return t } else { return nil } }
    private func number(_ c: XlsxCell) -> Double? { if case .number(let n) = c.kind { return n } else { return nil } }

    private func assertSheet(_ s: XlsxSheetData, _ v: JSONValue?, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(s.name, v?["name"]?.stringValue, file: file, line: line)
        XCTAssertEqual(s.header, strings(v?["header"]), s.name, file: file, line: line)
        XCTAssertEqual(s.widths, numbers(v?["widths"]), s.name, file: file, line: line)
    }

    func testSheetHeadersAndWidths() throws {
        let v = try vectors()
        let date = try XCTUnwrap(v["date"]?.stringValue), branch = try XCTUnwrap(v["branch"]?.stringValue)
        let engine = Engine(data: AppData(items: [], products: []))
        let count = Exporter.countSheetData(engine: engine, date: date, branch: branch)
        assertSheet(count, v["countSheet"])
        // Sayım şablonu: 1. satır başlık, 2. satır sütunlar (CountImport, countimport-vectors.json "template")
        XCTAssertEqual(count.title, v["countSheet"]?["title"]?.stringValue)
        XCTAssertEqual(count.headerRow, 2)
        XCTAssertEqual(Exporter.countSheetData(engine: engine, date: date).title, v["countSheetTitleWithoutBranch"]?.stringValue)
        let day = Exporter.daySheets(engine: engine, date: date)
        let expectedDay = v["daySheets"]?.arrayValue ?? []
        XCTAssertEqual(day.count, expectedDay.count)
        for (s, e) in zip(day, expectedDay) { assertSheet(s, e) }
        assertSheet(Exporter.orderSheet([], date: date), v["orderSheet"])
    }

    func testSalesStatusRows() throws {
        let v = try vectors()
        let date = try XCTUnwrap(v["date"]?.stringValue)
        let c = try XCTUnwrap(v["sales"])
        var data = AppData(items: try JSONCoding.decode([Item].self, from: c["items"] ?? .array([])),
                           products: try JSONCoding.decode([Product].self, from: c["products"] ?? .array([])))
        data.days[date] = DayRecord(date: date, sales: try JSONCoding.decode([SaleLine].self, from: c["sales"] ?? .array([])))
        let sheet = Exporter.salesSheet(engine: Engine(data: data), date: date)
        let rows = c["rows"]?.arrayValue ?? []
        XCTAssertEqual(sheet.rows.count, rows.count)
        for (r, e) in zip(sheet.rows, rows) {
            let ev = e.arrayValue ?? []
            XCTAssertEqual(r.count, ev.count)
            XCTAssertEqual(text(r[0]), ev[0].stringValue)
            XCTAssertEqual(text(r[1]), ev[1].stringValue)
            XCTAssertEqual(number(r[2]), ev[2].doubleValue)
            XCTAssertEqual(text(r[3]), ev[3].stringValue)
        }
    }

    func testOrderStatusAndFileNames() throws {
        let v = try vectors()
        let date = try XCTUnwrap(v["date"]?.stringValue)
        // Kritik seviyesi olan, hiç sayılmamış kalem sipariş ister; diğeri yeterli
        let items = [Item(id: "a", name: "90 Gr", unit: "Adet", recipeUnit: "adet", factor: 1, minStock: 10),
                     Item(id: "b", name: "Peynir", unit: "Kg", recipeUnit: "dilim", factor: 0.014)]
        let engine = Engine(data: AppData(items: items, products: []))
        let rows = Exporter.orderSheet(engine.orderSuggestions(asOf: date, lookbackDays: 14, coverDays: 3), date: date).rows
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(text(rows[0][9]), v["orderStatus"]?["order"]?.stringValue)
        XCTAssertEqual(text(rows[1][9]), v["orderStatus"]?["enough"]?.stringValue)
        for f in v["fileNames"]?.arrayValue ?? [] {
            let name = Exporter.fileName(branch: f["branch"]?.stringValue ?? "", base: f["base"]?.stringValue ?? "",
                                         ext: f["ext"]?.stringValue ?? "xlsx")
            XCTAssertEqual(name, f["expected"]?.stringValue)
        }
    }
}
