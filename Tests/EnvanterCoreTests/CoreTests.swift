import XCTest
@testable import EnvanterCore

final class CoreTests: XCTestCase {
    func fixture(_ name: String, _ ext: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: ext) else {
            throw XCTSkip("\(name).\(ext) deposuna konmadı (iş verisi içerir)")
        }
        return url
    }

    // MARK: Biçim

    func testParseNumbers() {
        XCTAssertEqual(Fmt.parse("7,5"), 7.5)
        XCTAssertEqual(Fmt.parse("7.5"), 7.5)
        XCTAssertEqual(Fmt.parse(" 12 "), 12)
        XCTAssertEqual(Fmt.parse("1.234,5"), 1234.5)
        XCTAssertEqual(Fmt.parse("1,234.5"), 1234.5)
        XCTAssertEqual(Fmt.parse("-3,25"), -3.25)
        XCTAssertNil(Fmt.parse(""))
        XCTAssertNil(Fmt.parse("abc"))
        XCTAssertEqual(Fmt.parseQuantity("1.120"), 1120)
        XCTAssertEqual(Fmt.parseQuantity("94"), 94)
        XCTAssertEqual(Fmt.parseQuantity("2,5"), 2.5)
    }

    func testFormatNumbers() {
        XCTAssertEqual(Fmt.number(7.5, maxFraction: 3), "7,5")
        XCTAssertEqual(Fmt.number(10.864000000000001, maxFraction: 3), "10,864")
        XCTAssertEqual(Fmt.number(-0.0001, maxFraction: 2), "0")
        XCTAssertEqual(Fmt.number(1234, maxFraction: 2), "1234")
    }

    func testDates() {
        XCTAssertEqual(DateKey.excelSerial("2026-08-01"), 46235)
        XCTAssertEqual(DateKey.excelSerial("2026-03-01"), 46082)
        XCTAssertEqual(DateKey.addDays(1, to: "2026-08-31"), "2026-09-01")
        XCTAssertEqual(DateKey.endOfMonth("2026-02-10"), "2026-02-28")
        XCTAssertEqual(DateKey.startOfPreviousMonth("2026-01-15"), "2025-12-01")
    }

    // MARK: Zip / Xlsx

    func testZipRoundTrip() throws {
        var w = ZipWriter()
        w.add("a.txt", text: "merhaba dünya")
        w.add("dir/b.xml", text: String(repeating: "x", count: 5000))
        let r = try ZipReader(data: w.finish())
        XCTAssertEqual(String(decoding: try r.read("a.txt"), as: UTF8.self), "merhaba dünya")
        XCTAssertEqual(try r.read("dir/b.xml").count, 5000)
    }

    func testXlsxWriteThenRead() throws {
        let sheet = XlsxSheetData(name: "Test", header: ["A", "B"],
                                  rows: [[.text("Çıtır & <Peynir>"), .number(12.5)], [.text("x"), .diff(-3)]])
        let data = XlsxWriter.build(sheets: [sheet])
        let back = try XlsxReader.read(data: data)
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back[0].name, "Test")
        XCTAssertEqual(back[0].value(row: 1, col: 1), "A")
        XCTAssertEqual(back[0].value(row: 2, col: 1), "Çıtır & <Peynir>")
        XCTAssertEqual(back[0].value(row: 2, col: 2), "12.5")
        XCTAssertEqual(back[0].value(row: 3, col: 2), "-3")
    }

    // MARK: Satış raporu

    func testParseRealSalesReport() throws {
        let report = try SalesParser.parse(fileURL: fixture("aug_report", "xlsx"))
        XCTAssertEqual(report.dateFrom, "2026-08-01")
        XCTAssertEqual(report.dateTo, "2026-08-31")
        XCTAssertTrue(report.isMultiDay)
        let byCode = Dictionary(uniqueKeysWithValues: report.lines.map { ($0.code, $0) })
        XCTAssertEqual(byCode["11152"]?.qty, 120)               // KASAP BURGER
        XCTAssertEqual(byCode["11152"]?.name, "KASAP BURGER")
        XCTAssertEqual(byCode["12102"]?.qty, 900)               // DUBLEX BURGER MENÜ
        XCTAssertEqual(byCode["17001"]?.qty, 39)                // ZAYİ 100 GR KÖFTE
        XCTAssertNil(byCode["11106"])                           // adedi 0 olan satır atılır
        XCTAssertNil(byCode["10000"])
        XCTAssertGreaterThan(report.lines.count, 150)
        // Başlık satırları (***** BURGERLER *****) satır olarak girmemeli
        XCTAssertFalse(report.lines.contains { $0.name.contains("*****") })
    }

    func testParsePastedText() {
        let text = "11100\tMEDIUM BURGER\t94\n\t***** MENÜLER *****\t\n12102\tDUBLEX BURGER MENÜ\t900\t516603\n"
        let r = SalesParser.parse(text: text, sourceName: "Pano")
        XCTAssertEqual(r.lines.map { $0.code }, ["11100", "12102"])
        XCTAssertEqual(r.lines.map { $0.qty }, [94, 900])
        XCTAssertEqual(r.lines[1].name, "DUBLEX BURGER MENÜ")
    }

    func testDuplicateCodesAreSummed() {
        let r = SalesParser.parse(text: "11100\tA\t2\n11100\tA\t3\n", sourceName: "x")
        XCTAssertEqual(r.lines.count, 1)
        XCTAssertEqual(r.lines[0].qty, 5)
    }

    // MARK: Motor — Excel'in kendi sonuçlarıyla karşılaştırma

    /// ModPos Ağustos raporu için sonradan eklenen (Excel'de olmayan) ürünler.
    static let addedCodes: Set<String> = ["11105", "18204", "18301", "18118", "18119", "11411", "15101", "15102",
                                          "15103", "18130", "18201", "11510", "17047", "17052", "17050"]

    /// Excel'in reçete tablosunun aynısı: sonradan eklenen ürünler çıkarılır ve Excel'in "Kocaman Çıtır Menü"
    /// çapraz-satır hatası (Jr Tavuk=E361*0,6; Tender=E359*0,1) aynen yeniden üretilir.
    func excelEquivalentData() -> AppData {
        var data = AppData.seeded()
        data.products.removeAll { Self.addedCodes.contains($0.code) }
        for i in data.products.indices {
            switch data.products[i].code {
            case "18127": data.products[i].amounts["jrTavuk"] = nil; data.products[i].amounts["tender"] = nil
            case "19211": data.products[i].amounts["jrTavuk"] = 0.6      // Excel: E361*0,6
            case "18126": data.products[i].amounts["tender"] = 0.1       // Excel: E359*0,1
            default: break
            }
        }
        return data
    }

    /// 01.08.xlsm'deki KOD/pivot toplamları (reçete birimiyle) ile uygulamanın hesabı birebir tutmalı.
    func testEngineMatchesExcelPivotTotals() throws {
        let tsv = try String(contentsOf: fixture("aug1_paste", "tsv"), encoding: .utf8)
        let report = SalesParser.parse(text: tsv, sourceName: "01.08")
        XCTAssertEqual(report.lines.count, 97)       // 113 satırın 16'sı adedi 0

        let engine = Engine(data: excelEquivalentData())
        let analysis = engine.analyze(sales: report.lines)
        // Excel'de reçetesi olmayan ürünler (12226, 15107 + sonradan eklenip burada çıkarılanlar) "tanımsız" görünür
        let unknown = Set(analysis.unknownLines.map { $0.code })
        XCTAssertTrue(unknown.isSuperset(of: ["12226", "15107"]))
        XCTAssertTrue(unknown.isSubset(of: Self.addedCodes.union(["12226", "15107"])), "\(unknown)")

        let map: [String: String] = [
            "Toplam 90 gr": "g90", "Toplam 120 gr": "g120", "Toplam 150 gr": "g130", "Toplam 220 gr": "g220",
            "Toplam Smash 80 gr": "smash70", "Toplam Peynir ": "peynir", "Toplam Patates Kg": "patates",
            "Toplam Ekmek Susamlı": "ekmekSusamli", "Toplam 60 Gr": "g60", "Toplam Ekmek Susamsız": "ekmekSusamsiz",
            "Toplam Füme": "fume", "Toplam Soğan Halkası": "soganHalkasi", "Toplam Çıtır Peynir": "citirPeynir",
            "Toplam Fillet": "fillet", "Toplam Tender": "tender", "Toplam Kanat": "kanat", "Toplam Hot Shots": "hotShots",
            "Toplam Tavuk 160 gr": "tavuk160", "Toplam 90 Gr Lezita": "lezita90", "Toplam Jr Tavuk": "jrTavuk",
        ]
        let exp = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture("aug1_expected", "json"))) as! [String: Any]
        let pivot = exp["pivot_total"] as! [String: Double]
        var checked = 0
        for (header, id) in map {
            guard let want = pivot[header] else { continue }
            let item = try XCTUnwrap(engine.itemsByID[id])
            let got = ((analysis.sold[id] ?? 0) + (analysis.waste[id] ?? 0)) / item.factor
            XCTAssertEqual(got, want, accuracy: 1e-6, "\(header)")
            checked += 1
        }
        XCTAssertEqual(checked, 20)
    }

    /// Excel'in Envanter sayfasındaki "Satılan" (H sütunu) değerleri ile karşılaştırma.
    /// Excel'in Smash, Peynir ve 60 Gr formülleri bazı kategorileri atladığından bu üçünde (bilinçli) fark vardır.
    func testEngineVsExcelSoldColumn() throws {
        let tsv = try String(contentsOf: fixture("aug1_paste", "tsv"), encoding: .utf8)
        let engine = Engine(data: excelEquivalentData())
        let a = engine.analyze(sales: SalesParser.parse(text: tsv, sourceName: "x").lines)
        let exp = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture("aug1_expected", "json"))) as! [String: Any]
        let env = exp["envanter"] as! [String: [String: Double]]
        let pairs: [(String, String)] = [
            ("90 Gr / Adet", "g90"), ("120 Gr / Adet", "g120"), ("130 Gr / Adet", "g130"), ("220 Gr / Adet", "g220"),
            ("Patates / Kg", "patates"), ("Ekmek Susamlı / Adet", "ekmekSusamli"), ("Ekmek Susamsız / Adet", "ekmekSusamsiz"),
            ("Dana Füme / Kg", "fume"), ("Soğan Halkası / Kg", "soganHalkasi"), ("Çıtır Peynir / Kg", "citirPeynir"),
            ("Fillet Kg", "fillet"), ("Tender Kg", "tender"), ("Kanat Kg", "kanat"), ("Hot Shots Kg", "hotShots"),
        ]
        for (excelName, id) in pairs {
            XCTAssertEqual(a.sold[id] ?? 0, env[excelName]!["sold"]!, accuracy: 1e-6, excelName)
        }
        // Excel formülleri YAN ÜRÜNLER / TAVUK YİYELİM kategorilerini atladığı için eksik gösteriyordu:
        XCTAssertEqual(env["Smash 70 Gr / Adet"]!["sold"]!, 288)
        XCTAssertEqual(a.sold["smash70"] ?? 0, 292, accuracy: 1e-9)
        XCTAssertEqual(env["Peynir / Kg"]!["sold"]!, 10.864, accuracy: 1e-9)
        XCTAssertEqual(a.sold["peynir"] ?? 0, 792 * 0.014, accuracy: 1e-9)
        XCTAssertEqual(env["60 Gr / Adet"]!["sold"]!, 0)
        XCTAssertEqual(a.sold["g60"] ?? 0, 86, accuracy: 1e-9)
    }

    func testWhatsAppExamples() {
        // "kasapta 1 tane 130 gr var ve kasap 1 tane satıldı → 130 gr'a 1 ekliyor"
        // "dublex satılırsa 2 tane 90 kullanıldığını anlıyor → 90 gr'a 2 yazıyor"
        let engine = Engine(data: AppData.seeded())
        let a = engine.analyze(sales: [SaleLine(code: "11152", name: "KASAP BURGER", qty: 1),
                                       SaleLine(code: "11101", name: "DUBLEX BURGER", qty: 1)])
        XCTAssertEqual(a.sold["g130"], 1)
        XCTAssertEqual(a.sold["g90"], 2)
        XCTAssertEqual(a.sold["ekmekSusamli"], 2)
        XCTAssertEqual(a.sold["peynir"] ?? 0, 3 * 0.014, accuracy: 1e-12)
        XCTAssertEqual(a.sold["fume"] ?? 0, 3 * 0.016, accuracy: 1e-12)
    }

    func testWasteGoesToWasteColumn() {
        let engine = Engine(data: AppData.seeded())
        let a = engine.analyze(sales: [SaleLine(code: "17001", name: "ZAYİ 100 GR KÖFTE", qty: 39),
                                       SaleLine(code: "17031", name: "ZAYİ SOĞAN HALKASI ADET", qty: 80)])
        XCTAssertEqual(a.waste["g90"], 39)
        XCTAssertEqual(a.waste["soganHalkasi"] ?? 0, 1.2, accuracy: 1e-12)
        XCTAssertNil(a.sold["g90"])
    }

    func testRealMonthlyReportCoverage() throws {
        let report = try SalesParser.parse(fileURL: fixture("aug_report", "xlsx"))
        let a = Engine(data: AppData.seeded()).analyze(sales: report.lines)
        let unknown = Set(a.unknownLines.map { $0.code })
        // Kullanıcının karar vermesi gereken belirsiz ürünler
        XCTAssertEqual(unknown, ["19991", "19112", "19113", "19114", "12913", "12107", "15107", "15028"])  // kullanıcıdan reçete beklenenler
        XCTAssertGreaterThan(a.trackedLines.count, 100)
    }

    // MARK: Günlük hesap

    func testDayCalcAndOpeningCarryOver() {
        var data = AppData.seeded()
        data.days["2026-08-01"] = DayRecord(
            date: "2026-08-01",
            entries: ["g90": DayEntry(opening: 100, incoming: 50, transferIn: 5, transferOut: 3, closing: 120)],
            sales: [SaleLine(code: "11101", name: "DUBLEX BURGER", qty: 10),       // 20 adet 90 gr
                    SaleLine(code: "17001", name: "ZAYİ 100 GR KÖFTE", qty: 2)])   // 2 adet zayi
        data.days["2026-08-02"] = DayRecord(date: "2026-08-02", entries: ["g90": DayEntry(incoming: 10, closing: 90)])
        let engine = Engine(data: data)

        let d1 = engine.calc(date: "2026-08-01").rows.first { $0.itemID == "g90" }!
        XCTAssertEqual(d1.opening, 100)
        XCTAssertFalse(d1.openingIsAuto)
        XCTAssertEqual(d1.actual, 100 + 50 + 5 - (3 + 120))     // 32
        XCTAssertEqual(d1.sold, 20)
        XCTAssertEqual(d1.waste, 2)
        XCTAssertEqual(d1.diff, 20 + 2 - 32)                    // -10

        // Ertesi günün açılışı = önceki gün kapanışı (otomatik)
        let d2 = engine.calc(date: "2026-08-02").rows.first { $0.itemID == "g90" }!
        XCTAssertEqual(d2.opening, 120)
        XCTAssertTrue(d2.openingIsAuto)
        XCTAssertEqual(d2.actual, 120 + 10 - 90)
        // Kapanışı girilmeyen kalemde fark hesaplanmaz
        let other = engine.calc(date: "2026-08-02").rows.first { $0.itemID == "g120" }!
        XCTAssertNil(other.diff)
        XCTAssertNil(other.actual)
    }

    func testOpeningSkipsUncountedDays() {
        var data = AppData.seeded()
        data.days["2026-08-01"] = DayRecord(date: "2026-08-01", entries: ["peynir": DayEntry(closing: 7.5)])
        data.days["2026-08-02"] = DayRecord(date: "2026-08-02", entries: ["peynir": DayEntry(incoming: 2)])  // kapanış yok
        let engine = Engine(data: data)
        let r = engine.calc(date: "2026-08-03").rows.first { $0.itemID == "peynir" }!
        XCTAssertEqual(r.opening, 7.5)
    }

    func testSummaryIdentity() {
        var data = AppData.seeded()
        data.days["2026-08-01"] = DayRecord(date: "2026-08-01", entries: ["g90": DayEntry(opening: 100, closing: 80)],
                                            sales: [SaleLine(code: "11100", name: "MEDIUM BURGER", qty: 15)])
        data.days["2026-08-02"] = DayRecord(date: "2026-08-02", entries: ["g90": DayEntry(incoming: 40, closing: 90)],
                                            sales: [SaleLine(code: "11100", name: "MEDIUM BURGER", qty: 25)])
        data.days["2026-08-03"] = DayRecord(date: "2026-08-03", entries: [:],
                                            sales: [SaleLine(code: "11100", name: "MEDIUM BURGER", qty: 99)]) // sayılmadı
        let s = Engine(data: data).summary(from: "2026-08-01", to: "2026-08-31").first { $0.item.id == "g90" }!
        XCTAssertEqual(s.daysCounted, 2)
        XCTAssertEqual(s.sold, 40)                      // sayılmayan günün satışı dahil edilmez
        XCTAssertEqual(s.actual, (100 - 80) + (80 + 40 - 90))
        XCTAssertEqual(s.diff, s.sold + s.waste - s.actual, accuracy: 1e-9)
        XCTAssertEqual(s.firstOpening, 100)
        XCTAssertEqual(s.lastClosing, 90)
    }

    // MARK: Kayıt

    func testPersistenceRoundTripAndRecovery() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("envanter-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = Persistence(directory: dir)
        guard case .fresh = p.load() else { return XCTFail("boş klasör fresh olmalı") }

        var data = AppData.seeded()
        data.days["2026-08-01"] = DayRecord(date: "2026-08-01", entries: ["g90": DayEntry(opening: 5, closing: 3)],
                                            sales: [SaleLine(code: "11100", name: "X", qty: 2)],
                                            salesSource: "x.xlsx", salesImportedAt: Date())
        let encoded = try p.encode(data)
        try p.write(encoded)
        p.dailyBackup(encoded, today: "2026-08-01")
        guard case .loaded(let back) = p.load() else { return XCTFail("yüklenmeli") }
        XCTAssertEqual(back.days["2026-08-01"]?.entries["g90"]?.closing, 3)
        XCTAssertEqual(back.products.count, data.products.count)

        // Dosyayı boz -> yedekten dönmeli
        try Data("{bozuk".utf8).write(to: p.dataFile)
        guard case .recovered(let rec, _) = p.load() else { return XCTFail("yedekten dönmeli") }
        XCTAssertEqual(rec.days["2026-08-01"]?.sales.first?.qty, 2)
    }

    func testExportBuildsReadableXlsx() throws {
        var data = AppData.seeded()
        data.days["2026-08-01"] = DayRecord(date: "2026-08-01", entries: ["g90": DayEntry(opening: 100, closing: 80)],
                                            sales: [SaleLine(code: "11100", name: "MEDIUM BURGER", qty: 15)])
        let xlsx = Exporter.day(engine: Engine(data: data), date: "2026-08-01")
        let sheets = try XlsxReader.read(data: xlsx)
        XCTAssertEqual(sheets.map { $0.name }, ["Envanter", "Satışlar"])
        XCTAssertEqual(sheets[0].value(row: 1, col: 2), "Ürün")
        XCTAssertEqual(sheets[0].value(row: 2, col: 1), "46235")
        XCTAssertEqual(sheets[0].value(row: 2, col: 2), "90 Gr / Adet")
        XCTAssertEqual(sheets[0].value(row: 2, col: 11), "-5")     // 15 satılan - 20 fiili = -5
        XCTAssertEqual(sheets[1].value(row: 2, col: 3), "15")
    }
}
