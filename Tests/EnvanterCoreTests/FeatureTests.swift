import XCTest
@testable import EnvanterCore

/// Sağlamlık düzeltmeleri ve NextGen özellikleri (tolerans, kritik stok, sipariş önerisi, pano) testleri.
final class FeatureTests: XCTestCase {
    func fixtureURL(_ path: String) throws -> URL {
        let ns = path as NSString
        guard let url = Bundle.module.url(forResource: "Fixtures/" + ns.deletingPathExtension, withExtension: ns.pathExtension) else {
            throw XCTSkip("\(path) bulunamadı")
        }
        return url
    }

    // MARK: - DEFLATE

    /// Python'daki üreticinin aynısı
    func inflateText() -> Data {
        Data((0..<3000).map { "satır \($0) " + String(repeating: "x", count: $0 % 13) + " Çıtır Peynir / Kg" }
            .joined(separator: "\n").utf8)
    }

    func lcgBytes() -> Data {
        var x: UInt32 = 12345
        var out = [UInt8]()
        out.reserveCapacity(70000)
        for _ in 0..<70000 {
            x = (x &* 1_103_515_245 &+ 12345) & 0x7fff_ffff
            out.append(UInt8((x >> 16) & 0xff))
        }
        return Data(out)
    }

    func testInflateAllBlockTypes() throws {
        let plain = inflateText()
        for name in ["dynamic", "fixed", "huffman_only"] {
            let raw = try Data(contentsOf: fixtureURL("inflate/\(name).deflate"))
            XCTAssertEqual(try Inflate.decompress(raw, expectedSize: plain.count), plain, name)
        }
        let random = lcgBytes()
        let raw = try Data(contentsOf: fixtureURL("inflate/random.deflate"))
        XCTAssertEqual(try Inflate.decompress(raw, expectedSize: random.count), random, "stored bloklar")
    }

    func testInflateRejectsGarbage() {
        XCTAssertThrowsError(try Inflate.decompress(Data([0xFF, 0xFF, 0xFF]), expectedSize: 10))
        XCTAssertThrowsError(try Inflate.decompress(Data(), expectedSize: 0))
        // Geçersiz geri başvuru: boş çıktıdan kopyalama (sabit Huffman, uzunluk 3, mesafe 1)
        XCTAssertThrowsError(try Inflate.decompress(Data([0x03, 0x02]), expectedSize: 10))
    }

    // MARK: - Sıkıştırılmış .xlsx

    func testDeflatedXlsxSalesReport() throws {
        let url = try fixtureURL("deflated_report.xlsx")
        let sheets = try XlsxReader.read(url: url)
        XCTAssertEqual(sheets.map { $0.name }, ["Rapor", "Ref yok"])

        let r = try SalesParser.parse(fileURL: url)
        XCTAssertEqual(r.dateFrom, "2026-08-01")
        XCTAssertFalse(r.isMultiDay)
        let byCode = Dictionary(uniqueKeysWithValues: r.lines.map { ($0.code, $0) })
        XCTAssertEqual(byCode["11100"]?.qty, 1120)
        XCTAssertEqual(byCode["11100"]?.name, "MEDIUM BURGER", "ad sütunu 'Ürün Tipi' olmalı, 'Ürün Grubu' değil")
        XCTAssertEqual(byCode["11152"]?.qty, 1120, "metin hücredeki '1.120' binlik ayırıcıdır")
        XCTAssertEqual(byCode["19001"]?.qty, 1.125, "sayısal hücredeki 1.125 binlik ayırıcı sanılmamalı")
        XCTAssertNil(byCode["12102"], "adedi 0 olan satır atılır")
        XCTAssertFalse(r.lines.contains { $0.name.contains("*****") })
    }

    func testCellsWithoutReferences() throws {
        let sheets = try XlsxReader.read(url: fixtureURL("deflated_report.xlsx"))
        let s = sheets[1]
        XCTAssertEqual(s.value(row: 1, col: 1), "a")
        XCTAssertEqual(s.number(row: 1, col: 2), 2.5)
        XCTAssertTrue(s.isNumeric(row: 1, col: 2))
        XCTAssertEqual(s.value(row: 2, col: 2), "b")
    }

    func testResolveRelationshipTargets() {
        XCTAssertEqual(XlsxReader.resolve("worksheets/sheet1.xml"), "xl/worksheets/sheet1.xml")
        XCTAssertEqual(XlsxReader.resolve("/xl/worksheets/sheet1.xml"), "xl/worksheets/sheet1.xml")
        XCTAssertEqual(XlsxReader.resolve("../xl/worksheets/a.xml"), "xl/worksheets/a.xml")
    }

    // MARK: - Biçim / giriş doğrulama

    func testParseRejectsExoticInput() {
        XCTAssertNil(Fmt.parse("1e300"))
        XCTAssertNil(Fmt.parse("inf"))
        XCTAssertNil(Fmt.parse("nan"))
        XCTAssertNil(Fmt.parse("0x10"))
        XCTAssertNil(Fmt.parse("-"))
        XCTAssertNil(Fmt.parse("12 kg"))
        XCTAssertNil(Fmt.parse("99999999999999"))
        XCTAssertEqual(Fmt.parse("\u{2212}3,5"), -3.5)
        XCTAssertEqual(Fmt.parse("1\u{00A0}234,5"), 1234.5)
        XCTAssertEqual(Fmt.machine("4.4408920985006262E-16")!, 4.4408920985006262E-16, accuracy: 1e-30)
        XCTAssertEqual(Fmt.number(.nan), "—")
        XCTAssertEqual(Fmt.number(0.0146, maxFraction: 3), "0,015")
        XCTAssertEqual(Fmt.number(-12.5, maxFraction: 0), "-13")
        XCTAssertEqual(Fmt.number(3, maxFraction: 0), "3")
    }

    func testDateKeyValidationAndArithmetic() {
        XCTAssertFalse(DateKey.isValid("2026-02-30"))
        XCTAssertFalse(DateKey.isValid("2026-13-01"))
        XCTAssertFalse(DateKey.isValid("2026-8-1"))
        XCTAssertFalse(DateKey.isValid("abc"))
        XCTAssertTrue(DateKey.isValid("2028-02-29"))
        XCTAssertEqual(DateKey.addDays(1, to: "2028-02-28"), "2028-02-29")
        XCTAssertEqual(DateKey.addDays(-1, to: "2027-01-01"), "2026-12-31")
        XCTAssertEqual(DateKey.addDays(365, to: "2026-08-01"), "2027-08-01")
        XCTAssertEqual(DateKey.distance(from: "2026-08-01", to: "2026-09-01"), 31)
        XCTAssertEqual(DateKey.short("2026-08-01"), "01.08.2026")
        XCTAssertEqual(DateKey.startOfPreviousMonth("2026-03-31"), "2026-02-01")
        XCTAssertEqual(DateKey.endOfMonth("2028-02-01"), "2028-02-29")
        XCTAssertEqual(DateKey.fromExcelSerial(46235), "2026-08-01")
        XCTAssertEqual(DateKey.fromExcelSerial(46235.75), "2026-08-01")
        XCTAssertNil(DateKey.fromExcelSerial(.infinity))
        for key in ["1999-12-31", "2000-02-29", "2026-08-01", "2100-03-01"] {
            XCTAssertEqual(DateKey.fromExcelSerial(DateKey.excelSerial(key)!), key)
        }
        // Takvim -> anahtar -> takvim
        let d = DateKey.date(from: "2026-08-01")!
        XCTAssertEqual(DateKey.string(from: d), "2026-08-01")
        XCTAssertTrue(DateKey.long("2026-08-01").contains("Ağustos"))
    }

    func testXlsxWriterHandlesExtremeNumbers() throws {
        XCTAssertEqual(XlsxWriter.num(1e300), "1e+300")
        XCTAssertNil(XlsxWriter.num(.nan))
        XCTAssertNil(XlsxWriter.num(.infinity))
        XCTAssertEqual(XlsxWriter.num(-0.0), "0")
        XCTAssertEqual(XlsxWriter.num(12), "12")
        let data = XlsxWriter.build(sheets: [XlsxSheetData(name: "T", header: ["a"], rows: [[.number(.nan)], [.number(1e300)]])])
        let back = try XlsxReader.read(data: data)
        XCTAssertNil(back[0].value(row: 2, col: 1))
        XCTAssertEqual(back[0].number(row: 3, col: 1), 1e300)
    }

    // MARK: - Satış metni

    func testTextEncodingsAndQuotedCSV() {
        let text = "Kodu;Ürün Tipi;Adedi\n11100;\"MEDIUM; BURGER\";94\n12102;\"DUBLEX \"\"ÖZEL\"\" MENÜ\";9\n"
        var utf16 = Data([0xFF, 0xFE])
        utf16.append(text.data(using: .utf16LittleEndian)!)
        let decoded = SalesParser.decodeText(utf16)
        XCTAssertEqual(decoded, text)
        let r = SalesParser.parse(text: decoded, sourceName: "x")
        XCTAssertEqual(r.lines.map { $0.code }, ["11100", "12102"])
        XCTAssertEqual(r.lines[0].name, "MEDIUM; BURGER")
        XCTAssertEqual(r.lines[0].qty, 94)
        XCTAssertEqual(r.lines[1].name, "DUBLEX \"ÖZEL\" MENÜ")

        var bom8 = Data([0xEF, 0xBB, 0xBF]); bom8.append(Data("11100\tA\t2".utf8))
        XCTAssertEqual(SalesParser.decodeText(bom8), "11100\tA\t2")
        XCTAssertEqual(SalesParser.decodeText(Data([0x53, 0xFD, 0x6E])), "Sın", "Windows-1254")
        XCTAssertEqual(SalesParser.decodeText(Data([0xDD, 0xD0, 0xDE, 0xF0, 0xFE, 0xE7, 0xD6, 0x80])), "İĞŞğşçÖ€")
    }

    // MARK: - Kayıt

    func testRecoveryPrefersNewestBackupAndReportsUnreadable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("envanter-rec-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = Persistence(directory: dir)

        // Hiç yedek yokken bozuk dosya -> unreadable (sessizce boş veriyle başlamamalı)
        try Data("{bozuk".utf8).write(to: p.dataFile)
        guard case .unreadable(let moved) = p.load() else { return XCTFail("unreadable beklenirdi") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(moved).path))

        var old = AppData.seeded(); old.settings.branchName = "eski"
        var new = AppData.seeded(); new.settings.branchName = "yeni"
        // "geri-yukleme-oncesi" adı alfabetik olarak önde ama daha ESKİ
        let snap = p.snapshot(try p.encode(old), label: "geri-yukleme-oncesi")!
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86_400)], ofItemAtPath: snap.path)
        p.dailyBackup(try p.encode(new), today: "2026-08-01")

        try Data("{bozuk".utf8).write(to: p.dataFile)
        guard case .recovered(let rec, let from) = p.load() else { return XCTFail("yedekten dönmeli") }
        XCTAssertEqual(rec.settings.branchName, "yeni")
        XCTAssertEqual(from, "envanter-2026-08-01.json")
    }

    func testDecodesOldDataWithoutNewFields() throws {
        let json = #"""
        {"schemaVersion":1,"items":[{"id":"g90","name":"90 Gr","unit":"Adet","recipeUnit":"adet","factor":1,"active":true}],
         "products":[],"days":{"2026-08-01":{"date":"2026-08-01","entries":{"g90":{"closing":3}},"sales":[]}}}
        """#
        let d = try Persistence.decode(Data(json.utf8))
        XCTAssertEqual(d.settings, AppSettings())
        XCTAssertNil(d.items[0].minStock)
        XCTAssertFalse(d.days["2026-08-01"]!.isLocked)

        // Yeni alanlar kaydedilip geri okunabilmeli
        var data = d
        data.items[0].minStock = 50; data.items[0].tolerance = 2
        data.settings = AppSettings(branchName: "Kadıköy", orderLookbackDays: 7, orderCoverDays: 2, staff: ["Ali"])
        data.days["2026-08-01"]!.note = "not"; data.days["2026-08-01"]!.locked = true
        let back = try Persistence.decode(try Persistence.encoder().encode(data))
        XCTAssertEqual(back.items[0].minStock, 50)
        XCTAssertEqual(back.items[0].tolerance, 2)
        XCTAssertEqual(back.settings.branchName, "Kadıköy")
        XCTAssertEqual(back.settings.staff, ["Ali"])
        XCTAssertTrue(back.days["2026-08-01"]!.isLocked)
        XCTAssertEqual(back.days["2026-08-01"]!.note, "not")
    }

    func testDayWithOnlyNoteIsNotEmpty() {
        XCTAssertFalse(DayRecord(date: "2026-08-01", note: "kapalıydık").isEmpty)
        XCTAssertTrue(DayRecord(date: "2026-08-01", note: "").isEmpty)
    }

    // MARK: - Motor

    func testDuplicateItemIDsDoNotCrash() {
        var data = AppData.seeded()
        data.items.append(Item(id: "g90", name: "Kopya", unit: "Adet", recipeUnit: "adet", factor: 1))
        let engine = Engine(data: data)
        XCTAssertEqual(engine.itemsByID["g90"]?.name, "90 Gr")
        XCTAssertEqual(engine.calc(date: "2026-08-01").rows.filter { $0.itemID == "g90" }.count, 1)
    }

    func testPreviousClosingBinarySearch() {
        var data = AppData.seeded()
        for (i, d) in ["2026-07-30", "2026-08-01", "2026-08-03", "2026-08-05"].enumerated() {
            data.days[d] = DayRecord(date: d, entries: ["g90": DayEntry(closing: Double(i + 1))])
        }
        data.days["2026-08-04"] = DayRecord(date: "2026-08-04", entries: ["g90": DayEntry(incoming: 5)])
        let e = Engine(data: data)
        XCTAssertNil(e.previousClosing(itemID: "g90", before: "2026-07-30"))
        XCTAssertEqual(e.previousClosing(itemID: "g90", before: "2026-07-31"), 1)
        XCTAssertEqual(e.previousClosing(itemID: "g90", before: "2026-08-03"), 2)
        XCTAssertEqual(e.previousClosing(itemID: "g90", before: "2026-08-05"), 3)
        XCTAssertEqual(e.previousClosing(itemID: "g90", before: "2027-01-01"), 4)
        XCTAssertEqual(e.lastClosing(itemID: "g90", before: "2026-08-05")?.date, "2026-08-03")
    }

    func testToleranceAndMinimum() {
        var data = AppData.seeded()
        let i = data.items.firstIndex { $0.id == "patates" }!
        data.items[i].tolerance = 0.5    // ±0,5 kg normal
        data.items[i].minStock = 20
        // 10 kg satış bekleniyor, 10,3 kg çıkmış -> -0,3 (tolerans içinde)
        data.products.append(Product(code: "99001", name: "PATATES 1 KG", category: "YAN ÜRÜNLER", amounts: ["patates": 1]))
        data.days["2026-08-01"] = DayRecord(date: "2026-08-01", entries: ["patates": DayEntry(opening: 30, closing: 19.7)],
                                            sales: [SaleLine(code: "99001", name: "PATATES 1 KG", qty: 10)])
        var e = Engine(data: data)
        var r = e.calc(date: "2026-08-01").rows.first { $0.itemID == "patates" }!
        XCTAssertEqual(r.diff!, -0.3, accuracy: 1e-9)
        XCTAssertEqual(r.severity, .withinTolerance)
        XCTAssertTrue(r.belowMinimum)

        // 2 kg fazla çıkış -> kayıp
        data.days["2026-08-01"]!.entries["patates"]!.closing = 18
        e = Engine(data: data)
        r = e.calc(date: "2026-08-01").rows.first { $0.itemID == "patates" }!
        XCTAssertEqual(r.severity, .shortage)
        let o = e.overview(date: "2026-08-01")
        XCTAssertEqual(o.shortageItems, 1)
        XCTAssertEqual(o.problemItems, 1)
        XCTAssertEqual(o.belowMinimumItems, 1)
        XCTAssertEqual(o.countedItems, 1)
        XCTAssertTrue(o.hasSales)

        let s = e.summary(from: "2026-08-01", to: "2026-08-31").first { $0.item.id == "patates" }!
        XCTAssertEqual(s.diff, -2, accuracy: 1e-9)
        XCTAssertEqual(s.shortageQty, 2, accuracy: 1e-9)
        XCTAssertEqual(s.shortageDays, 1)
        XCTAssertEqual(s.severity, .shortage)
        let g90 = e.summary(from: "2026-08-01", to: "2026-08-31").first { $0.item.id == "g90" }!
        XCTAssertEqual(g90.daysCounted, 0)
        XCTAssertEqual(g90.shortageQty, 0)
    }

    /// Takip şeridi renkleri (web ile aynı tam sayı hesabı): sayılanların %10'unda fark dikkat, %20'sinde belirgin
    func testTrackerFlagThresholds() {
        func day(counted: Int, problems: Int, items: Int = 20) -> DayOverview {
            DayOverview(date: "2026-08-01", itemCount: items, countedItems: counted, hasSales: true, salesLines: 1, unknownLines: 0,
                        problemItems: problems, shortageItems: problems, belowMinimumItems: 0, isLocked: false)
        }
        XCTAssertFalse(day(counted: 20, problems: 0).hasNotableProblems)
        XCTAssertFalse(day(counted: 20, problems: 0).hasSignificantProblems)
        XCTAssertFalse(day(counted: 20, problems: 1).hasNotableProblems, "%5")
        XCTAssertTrue(day(counted: 20, problems: 2).hasNotableProblems, "%10 sınırı dahil")
        XCTAssertFalse(day(counted: 20, problems: 3).hasSignificantProblems, "%15")
        XCTAssertTrue(day(counted: 20, problems: 4).hasSignificantProblems, "%20 sınırı dahil")
        XCTAssertTrue(day(counted: 21, problems: 3).hasNotableProblems)       // 30 ≥ 21
        XCTAssertFalse(day(counted: 21, problems: 4).hasSignificantProblems)  // 20 < 21
        XCTAssertTrue(day(counted: 21, problems: 5).hasSignificantProblems)
        // Az kalem sayıldıysa tek sorun da belirgindir; sayım yoksa sorun da yoktur
        XCTAssertTrue(day(counted: 3, problems: 1).hasSignificantProblems)
        XCTAssertFalse(day(counted: 0, problems: 0).hasNotableProblems)
        XCTAssertTrue(day(counted: 20, problems: 0).isFullyCounted)
        XCTAssertFalse(day(counted: 19, problems: 0).isFullyCounted)
    }

    /// Takip şeridi renk kuralı (Ek B #3): boş / yalnızca satış / kötü / dikkat / iyi; sıra önemli
    func testTrackerStateRule() {
        func day(counted: Int, problems: Int, items: Int = 20, sales: Bool = true) -> DayOverview {
            DayOverview(date: "2026-08-01", itemCount: items, countedItems: counted, hasSales: sales, salesLines: sales ? 1 : 0,
                        unknownLines: 0, problemItems: problems, shortageItems: 0, belowMinimumItems: 0, isLocked: false)
        }
        // Veri yok / yalnızca satış
        XCTAssertEqual(day(counted: 0, problems: 0, sales: false).trackerState, .empty)
        XCTAssertEqual(day(counted: 0, problems: 0, items: 0, sales: false).trackerState, .empty)
        XCTAssertEqual(day(counted: 0, problems: 0, sales: true).trackerState, .salesOnly)
        // Sayım tam, fark az (satış olmasa da sayım rengi gösterilir)
        XCTAssertEqual(day(counted: 20, problems: 0).trackerState, .ok)
        XCTAssertEqual(day(counted: 20, problems: 1).trackerState, .ok, "%5 fark: iyi")
        XCTAssertEqual(day(counted: 20, problems: 0, sales: false).trackerState, .ok)
        // Eksik sayım fark olmasa da dikkat
        XCTAssertEqual(day(counted: 19, problems: 0).trackerState, .warn)
        XCTAssertEqual(day(counted: 1, problems: 0).trackerState, .warn)
        // %10 sınırı dikkat, %20 sınırı kötü (kötü, eksik sayımdan önce gelir)
        XCTAssertEqual(day(counted: 20, problems: 2).trackerState, .warn)
        XCTAssertEqual(day(counted: 20, problems: 3).trackerState, .warn)
        XCTAssertEqual(day(counted: 20, problems: 4).trackerState, .bad)
        XCTAssertEqual(day(counted: 10, problems: 2).trackerState, .bad, "eksik sayım + %20 fark: kötü")
        XCTAssertEqual(day(counted: 3, problems: 1, sales: false).trackerState, .bad)
        // Kalem listesi boşken (itemCount 0) sayım tam sayılmaz: dikkat
        XCTAssertEqual(day(counted: 1, problems: 0, items: 0).trackerState, .warn)

        // Motorun ürettiği özetle uçtan uca: tohum verisinde boş gün, yalnızca satış, eksik sayım
        var data = AppData.seeded()
        let first = data.items[0].id
        data.days["2026-08-02"] = DayRecord(date: "2026-08-02", sales: [SaleLine(code: "11103", name: "MEDIUM CHEESE BURGER", qty: 3)])
        data.days["2026-08-03"] = DayRecord(date: "2026-08-03", entries: [first: DayEntry(opening: 5, closing: 5)])
        let e = Engine(data: data)
        XCTAssertEqual(e.overview(date: "2026-08-01").trackerState, .empty)
        XCTAssertEqual(e.overview(date: "2026-08-02").trackerState, .salesOnly)
        let partial = e.overview(date: "2026-08-03")
        XCTAssertEqual(partial.countedItems, 1)
        XCTAssertGreaterThan(partial.itemCount, 1)
        XCTAssertEqual(partial.trackerState, .warn, "tek kalem sayıldı: eksik sayım")

        // Renk açıklaması: web anahtarları ve metinleri
        XCTAssertEqual(TrackerState.legendOrder, [.ok, .warn, .bad, .salesOnly, .empty])
        XCTAssertEqual(Set(TrackerState.legendOrder), Set(TrackerState.allCases))
        XCTAssertEqual(TrackerState.legendOrder.map(\.rawValue), ["ok", "warn", "bad", "salesOnly", "none"])
        XCTAssertEqual(TrackerState.ok.label, "Sayım tam, fark az")
        XCTAssertEqual(TrackerState.warn.label, "Eksik sayım ya da sayılanların %10'unda fark")
        XCTAssertEqual(TrackerState.bad.label, "Sayılanların %20'sinde fark")
        XCTAssertEqual(TrackerState.salesOnly.label, "Yalnızca satış")
        XCTAssertEqual(TrackerState.empty.label, "Veri yok")
        for s in TrackerState.allCases {
            XCTAssertFalse(s.label.contains("₺") || s.label.lowercased().contains("kayıp"), "maliyet dili kalmamalı: \(s.label)")
        }
    }

    func testSeverityWithoutTolerance() {
        let kg = Item(id: "a", name: "A", unit: "Kg", recipeUnit: "kg", factor: 1)
        XCTAssertEqual(kg.severity(of: 0.0004), .zero)
        XCTAssertEqual(kg.severity(of: -0.002), .shortage)
        XCTAssertEqual(kg.severity(of: 0.002), .surplus)
        let adet = Item(id: "b", name: "B", unit: "Adet", recipeUnit: "adet", factor: 1, tolerance: 2)
        XCTAssertEqual(adet.severity(of: -2), .withinTolerance)
        XCTAssertEqual(adet.severity(of: -3), .shortage)
        XCTAssertFalse(adet.isBelowMinimum(1))
    }

    func testOrderSuggestions() {
        var data = AppData.seeded()
        let i = data.items.firstIndex { $0.id == "g90" }!
        data.items[i].minStock = 50
        // Günlük fiili tüketim: 100, 120, 80 -> ortalama 100
        data.days["2026-08-01"] = DayRecord(date: "2026-08-01", entries: ["g90": DayEntry(opening: 500, closing: 400)])
        data.days["2026-08-02"] = DayRecord(date: "2026-08-02", entries: ["g90": DayEntry(closing: 280)])
        data.days["2026-08-03"] = DayRecord(date: "2026-08-03", entries: ["g90": DayEntry(closing: 200)])
        // Sayımı olmayan kalem (peynir) için satıştan tahmin: 30 cheese burger × 1 dilim × 0,014 kg
        data.days["2026-08-03"]!.sales = [SaleLine(code: "11103", name: "MEDIUM CHEESE BURGER", qty: 30)]
        let e = Engine(data: data)
        let list = e.orderSuggestions(asOf: "2026-08-03", lookbackDays: 7, coverDays: 3)
        let g90 = list.first { $0.item.id == "g90" }!
        XCTAssertEqual(g90.dailyUsage, 100, accuracy: 1e-9)
        XCTAssertEqual(g90.sampleDays, 3)
        XCTAssertEqual(g90.stock, 200)
        XCTAssertEqual(g90.stockDate, "2026-08-03")
        XCTAssertEqual(g90.daysOfCover!, 2, accuracy: 1e-9)
        XCTAssertEqual(g90.target, 350, accuracy: 1e-9)        // 100 × 3 + 50 emniyet
        XCTAssertEqual(g90.suggested, 150, accuracy: 1e-9)

        let peynir = list.first { $0.item.id == "peynir" }!
        XCTAssertEqual(peynir.dailyUsage, 0.42, accuracy: 1e-9)
        XCTAssertEqual(peynir.sampleDays, 1)
        XCTAssertNil(peynir.stock)
        XCTAssertEqual(peynir.suggested, 1.3, accuracy: 1e-9)   // 0,42 × 3 = 1,26 -> 1,3

        // Yeterli stok -> 0
        let none = e.orderSuggestions(asOf: "2026-08-03", lookbackDays: 7, coverDays: 1).first { $0.item.id == "g90" }!
        XCTAssertEqual(none.suggested, 0)

        let text = Exporter.orderText(list, date: "2026-08-03", branch: "Kadıköy")
        XCTAssertTrue(text.hasPrefix("Kadıköy · Sipariş listesi – 03.08.2026"))
        XCTAssertTrue(text.contains("• 90 Gr: 150 adet"))
        XCTAssertEqual(Exporter.orderText([], date: "2026-08-03", branch: ""), "Sipariş listesi – 03.08.2026\nSipariş gerekmiyor.")
    }

    func testOrderRoundingForKg() {
        var data = AppData.seeded()
        data.days["2026-08-01"] = DayRecord(date: "2026-08-01", entries: ["patates": DayEntry(opening: 10, closing: 8.73)])
        let s = Engine(data: data).orderSuggestions(asOf: "2026-08-01", lookbackDays: 3, coverDays: 10)
            .first { $0.item.id == "patates" }!
        // tüketim 1,27 kg/gün × 10 = 12,7 hedef; stok 8,73 -> 3,97 -> 4,0'a yuvarlanır
        XCTAssertEqual(s.suggested, 4.0, accuracy: 1e-9)
    }

    func testTrend() {
        var data = AppData.seeded()
        data.days["2026-08-02"] = DayRecord(date: "2026-08-02", entries: ["g90": DayEntry(opening: 5, closing: 3)])
        let t = Engine(data: data).trend(endingAt: "2026-08-03", days: 3)
        XCTAssertEqual(t.map { $0.date }, ["2026-08-01", "2026-08-02", "2026-08-03"])
        XCTAssertEqual(t.map { $0.countedItems }, [0, 1, 0])
    }

    func testExportSummaryAndOrderSheets() throws {
        var data = AppData.seeded()
        data.days["2026-08-01"] = DayRecord(date: "2026-08-01", entries: ["g90": DayEntry(opening: 100, closing: 80)])
        let e = Engine(data: data)
        let sheets = try XlsxReader.read(data: Exporter.history(engine: e, from: "2026-08-01", to: "2026-08-31"))
        XCTAssertEqual(sheets.map { $0.name }, ["Alımlar", "Özet", "Günlük Durum"])
        XCTAssertEqual(sheets[1].value(row: 1, col: 12), "Fazla Çıkış Miktarı")
        XCTAssertEqual(sheets[2].value(row: 1, col: 2), "Sayılan Kalem")
        XCTAssertEqual(sheets[2].number(row: 2, col: 2), 1)
        let orders = try XlsxReader.read(data: Exporter.orders(e.orderSuggestions(asOf: "2026-08-01", lookbackDays: 7, coverDays: 3), date: "2026-08-01"))
        XCTAssertEqual(orders[0].name, "Sipariş")
        XCTAssertEqual(orders[0].value(row: 2, col: 1), "90 Gr / Adet")
        XCTAssertEqual(orders[0].value(row: 1, col: 11), "Önerilen Sipariş")
        XCTAssertNil(orders[0].value(row: 1, col: 12), "tutar sütunu yok")
    }

    // MARK: - Excel envanter dosyası

    /// Alımlar sayfası + aynı kayıtları içeren pivot önbelleği: aynı kayıt iki kaynakta olduğu için "yinelenen" sayılmamalı.
    func testWorkbookImportDoesNotCountPivotMirrorAsDuplicate() throws {
        let alim = XlsxSheetData(name: "Alımlar", header: Exporter.inventoryHeader, rows: [
            [.date(serial: 46235), .text("90 Gr / Adet"), .number(100), .number(0), .number(0), .number(0), .number(80), .number(15), .number(0)],
            [.date(serial: 46235), .text("Peynir / Kg"), .number(5), .number(2), .number(0), .number(0), .number(6.5), .number(0.4), .number(0)],
            // Aynı sayfada gerçek tekrar: kapanışsız taslak + kapanışlı kayıt
            [.date(serial: 46236), .text("90 Gr / Adet"), .number(80), .number(0), .number(0), .number(0), .blankCell, .number(0), .number(0)],
            [.date(serial: 46236), .text("90 Gr / Adet"), .number(80), .number(10), .number(0), .number(0), .number(70), .number(18), .number(1)],
            [.date(serial: 46236), .text("Bilinmeyen Kalem"), .number(1), .number(0), .number(0), .number(0), .number(1), .number(0), .number(0)],
        ])
        var zip = ZipReader.rewrap(XlsxWriter.build(sheets: [alim]))
        let fields = ["Tarih", "Ürün", "Açılış", "Gelen", "Gelen Transfer (+)", "Giden Transfer (-)", "Kapanış", "Satılan", "Zaiyat", "Fiili Tüketim", "Fark"]
        var def = #"<?xml version="1.0"?><pivotCacheDefinition xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><cacheSource type="worksheet"><worksheetSource ref="A1:K3" sheet="Alımlar"/></cacheSource><cacheFields count="11">"#
        for (i, f) in fields.enumerated() {
            if i == 1 { def += #"<cacheField name="\#(f)"><sharedItems><s v="90 Gr / Adet"/><s v="Peynir / Kg"/></sharedItems></cacheField>"# }
            else { def += #"<cacheField name="\#(f)"><sharedItems/></cacheField>"# }
        }
        def += "</cacheFields></pivotCacheDefinition>"
        let rec = #"<?xml version="1.0"?><pivotCacheRecords xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><r><d v="2026-08-01T00:00:00"/><x v="0"/><n v="100"/><n v="0"/><n v="0"/><n v="0"/><n v="80"/><n v="15"/><n v="0"/><n v="20"/><n v="-5"/></r><r><n v="46235"/><x v="1"/><n v="5"/><n v="2"/><n v="0"/><n v="0"/><n v="6.5"/><n v="0.4"/><n v="0"/><n v="0.5"/><n v="-0.1"/></r><r><n v="46234"/><x v="1"/><n v="4"/><n v="0"/><n v="0"/><n v="0"/><n v="5"/><n v="0"/><n v="0"/><n v="-1"/><n v="1"/></r></pivotCacheRecords>"#
        zip.add("xl/pivotCache/pivotCacheDefinition1.xml", text: def)
        zip.add("xl/pivotCache/pivotCacheRecords1.xml", text: rec)

        let imp = try WorkbookImporter.parse(data: zip.finish(), sourceName: "test.xlsm", items: AppData.seeded().items)
        XCTAssertEqual(imp.duplicatesResolved, 1, "yalnızca Alımlar sayfasındaki gerçek tekrar sayılmalı")
        XCTAssertEqual(imp.historyDates, ["2026-07-31", "2026-08-01", "2026-08-02"], "yalnızca pivotta kalan eski gün de alınmalı")
        XCTAssertEqual(imp.skippedItemNames, ["Bilinmeyen Kalem"])
        let d2 = imp.days["2026-08-02"]!
        XCTAssertEqual(d2.entries["g90"]?.closing, 70)
        XCTAssertEqual(d2.entries["g90"]?.incoming, 10)
        XCTAssertEqual(d2.legacySold?["g90"], 18)
        XCTAssertEqual(d2.legacyWaste?["g90"], 1)
        XCTAssertEqual(imp.days["2026-08-01"]?.entries["peynir"]?.closing, 6.5)
    }
}

// MARK: - Dönem ve kalem analizi

final class PeriodTests: XCTestCase {
    func testSalesAmountColumnIsIgnored() throws {
        // "Tutar" sütunu ve adetten sonraki sayılar okunmaz; yalnızca miktarlar aktarılır
        let text = "Kodu\tÜrün Tipi\tAdedi\tTutar\n11100\tMEDIUM BURGER\t10\t1.500,50\n11100\tMEDIUM BURGER\t2\t300\n11103\tCHEESE\t5\n"
        let r = SalesParser.parse(text: text, sourceName: "x")
        XCTAssertEqual(r.lines.map { $0.code }, ["11100", "11103"])
        XCTAssertEqual(r.lines[0].qty, 12)
        XCTAssertEqual(r.lines[0].name, "MEDIUM BURGER")
        XCTAssertEqual(r.totalQty, 17)
        let encoded = String(decoding: try JSONCoding.encoder().encode(r.lines), as: UTF8.self)
        XCTAssertFalse(encoded.contains("amount"), encoded)

        // .xlsx: "Ürün Tutarı" başlığı ürün adı sanılmaz (ad "Ürün…" ile başlayan ilk başlıktan alınır)
        var rows: [Int: [Int: String]] = [1: [1: "Kodu", 2: "Ürün Tutarı", 3: "Ürün Grubu Adı", 4: "Adedi"]]
        rows[2] = [1: "11100", 2: "1500", 3: "MEDIUM BURGER", 4: "10"]
        let x = try SalesParser.parse(sheet: XlsxSheet(name: "Rapor", rows: rows), sourceName: "x.xlsx")
        XCTAssertEqual(x.lines.first?.name, "MEDIUM BURGER")
        XCTAssertEqual(x.lines.first?.qty, 10)
    }

    func testPeriodStatsCountsDays() {
        var data = AppData.seeded()
        data.days["2026-08-01"] = DayRecord(date: "2026-08-01", entries: ["g90": DayEntry(opening: 100, incoming: 20, closing: 88)],
                                            sales: [SaleLine(code: "11100", name: "MEDIUM BURGER", qty: 10)])
        data.days["2026-08-02"] = DayRecord(date: "2026-08-02", sales: [SaleLine(code: "11100", name: "MEDIUM BURGER", qty: 5)])
        data.days["2026-08-03"] = DayRecord(date: "2026-08-03", note: "kapalıydık")
        data.days["2026-08-04"] = DayRecord(date: "2026-08-04")                  // boş gün sayılmaz
        data.days["2026-09-01"] = DayRecord(date: "2026-09-01", entries: ["g90": DayEntry(closing: 50)])
        let p = Engine(data: data).periodStats(from: "2026-08-01", to: "2026-08-31")
        XCTAssertEqual(p.days.map { $0.date }, ["2026-08-01", "2026-08-02", "2026-08-03"])
        XCTAssertEqual(p.countedDays, 1)
        XCTAssertEqual(p.salesDays, 2)
        // 90 gr: fiili 32, beklenen 10 → 22 adet fazla çıkış (tolerans yok)
        XCTAssertEqual(p.days[0].problemItems, 1)
        XCTAssertEqual(p.days[0].shortageItems, 1)
        XCTAssertTrue(p.days[0].hasSignificantProblems)
        XCTAssertEqual(p.days[1].countedItems, 0)
    }

    func testItemSeries() {
        var data = AppData.seeded()
        data.days["2026-08-01"] = DayRecord(date: "2026-08-01", entries: ["g90": DayEntry(opening: 100, closing: 90)],
                                            sales: [SaleLine(code: "11100", name: "M", qty: 8)])
        data.days["2026-08-02"] = DayRecord(date: "2026-08-02", sales: [SaleLine(code: "11100", name: "M", qty: 3)])
        data.days["2026-08-03"] = DayRecord(date: "2026-08-03", entries: ["peynir": DayEntry(closing: 2)])
        let e = Engine(data: data)
        let s = e.itemSeries(itemID: "g90", from: "2026-08-01", to: "2026-08-31")
        XCTAssertEqual(s.map { $0.date }, ["2026-08-01", "2026-08-02", "2026-08-03"])
        XCTAssertEqual(s[0].expected, 8)
        XCTAssertEqual(s[0].actual, 10)
        XCTAssertEqual(s[0].diff, -2)
        XCTAssertEqual(s[0].closing, 90)
        XCTAssertNil(s[1].actual)
        XCTAssertEqual(s[1].expected, 3)
        XCTAssertTrue(e.itemSeries(itemID: "fume", from: "2026-08-01", to: "2026-08-31").isEmpty, "hareketsiz kalem")
    }

    /// Web paneli eşlik testinin alanları (docs/SYNC.md §4): yalnızca envanter metrikleri
    func testMetricsJSONFieldSet() throws {
        let e = Engine(data: DemoData.make(endingAt: "2026-08-31", days: 35))
        let data = Metrics.json(engine: e, date: "2026-08-31", from: "2026-08-01", to: "2026-08-31")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        func keys(_ v: Any?) -> Set<String> { Set((v as? [String: Any]).map { Array($0.keys) } ?? []) }
        func rows(_ k: String) -> [Any] { root[k] as? [Any] ?? [] }
        XCTAssertEqual(Set(root.keys), ["date", "from", "to", "calc", "overview", "summary", "period", "daily", "orders", "trend"])
        XCTAssertEqual(keys(rows("calc").first), ["itemID", "opening", "openingIsAuto", "incoming", "transferIn", "transferOut",
                                                  "closing", "sold", "waste", "actual", "diff", "severity", "belowMinimum"])
        XCTAssertEqual(keys(root["overview"]), ["itemCount", "countedItems", "hasSales", "salesLines", "unknownLines", "problemItems",
                                                "shortageItems", "belowMinimumItems", "isLocked", "isFullyCounted",
                                                "hasNotableProblems", "hasSignificantProblems"])
        XCTAssertEqual(keys(rows("summary").first), ["itemID", "daysCounted", "firstOpening", "lastClosing", "incoming", "transferIn",
                                                     "transferOut", "sold", "waste", "actual", "diff", "shortageQty", "shortageDays"])
        XCTAssertEqual(keys(root["period"]), ["days", "countedDays", "salesDays"])
        XCTAssertEqual(keys(rows("daily").first), ["date", "countedItems", "problemItems", "shortageItems", "belowMinimumItems",
                                                   "hasSales", "isLocked"])
        XCTAssertEqual(keys(rows("orders").first), ["itemID", "stock", "countedStock", "stockDate", "onOrder", "dailyUsage",
                                                    "sampleDays", "daysOfCover", "target", "suggested"])
        XCTAssertEqual(keys(rows("trend").first), ["date", "countedItems", "problemItems", "shortageItems"])
        XCTAssertEqual(rows("trend").count, 14)
        XCTAssertEqual(rows("daily").count, 31)
        // Değerler motorla aynı
        let o = e.overview(date: "2026-08-31")
        let ov = try XCTUnwrap(root["overview"] as? [String: Any])
        XCTAssertEqual(ov["problemItems"] as? Int, o.problemItems)
        XCTAssertEqual(ov["hasNotableProblems"] as? Bool, o.hasNotableProblems)
        XCTAssertEqual(ov["hasSignificantProblems"] as? Bool, o.hasSignificantProblems)
        XCTAssertEqual(ov["isFullyCounted"] as? Bool, false)
        let text = String(decoding: data, as: UTF8.self)
        for removed in ["diffValue", "lossValue", "netValue", "revenue", "Cost", "labor", "priceAlerts", "stockValue", "shortageValue", "₺"] {
            XCTAssertFalse(text.contains(removed), removed)
        }
    }

    func testCountSheetAndDailyExport() throws {
        var data = AppData.seeded()
        data.days["2026-08-01"] = DayRecord(date: "2026-08-01", entries: ["g90": DayEntry(opening: 100, incoming: 5, closing: 80)],
                                            note: "deneme", countedBy: "Ali", locked: true)
        let e = Engine(data: data)
        let form = try XlsxReader.read(data: Exporter.countSheet(engine: e, date: "2026-08-02", branch: "Kadıköy"))
        XCTAssertEqual(form[0].name, "Sayım Formu")
        XCTAssertEqual(form[0].value(row: 1, col: 1), "Kadıköy · Sayım 02.08.2026")
        XCTAssertEqual(form[0].value(row: 2, col: 1), "90 Gr")
        XCTAssertEqual(form[0].number(row: 2, col: 3), 80, "açılış = önceki kapanış")
        XCTAssertNil(form[0].value(row: 2, col: 7), "kapanış boş")

        let hist = try XlsxReader.read(data: Exporter.history(engine: e, from: "2026-08-01", to: "2026-08-31"))
        XCTAssertEqual(hist.map { $0.name }, ["Alımlar", "Özet", "Günlük Durum", "Notlar"])
        let daily = hist[2]
        XCTAssertEqual(daily.number(row: 2, col: 2), 1, "sayılan kalem")
        XCTAssertEqual(daily.number(row: 2, col: 4), 1, "sorunlu kalem (25 adet fazla çıkış)")
        XCTAssertEqual(daily.value(row: 2, col: 7), "Yok")
        XCTAssertEqual(daily.value(row: 2, col: 8), "Kapatıldı")
        XCTAssertEqual(hist[3].value(row: 2, col: 2), "Ali")
        XCTAssertEqual(hist[3].value(row: 2, col: 4), "deneme")
    }
}

final class DemoDataTests: XCTestCase {
    func testDemoDataIsConsistentAndRich() throws {
        let data = DemoData.make(endingAt: "2026-08-31", days: 35)
        XCTAssertEqual(data.days.count, 35)
        XCTAssertEqual(data.days.keys.min(), "2026-07-28")
        // Kaydedilip geri okunabilmeli
        let back = try Persistence.decode(try Persistence.encoder().encode(data))
        XCTAssertEqual(back.days.count, 35)

        let e = Engine(data: data)
        let last = e.overview(date: "2026-08-31")
        XCTAssertGreaterThan(last.countedItems, 0)
        XCTAssertLessThan(last.countedItems, last.itemCount, "son gün sayımı yarım")
        XCTAssertEqual(last.unknownLines, 2)
        XCTAssertFalse(last.isLocked)
        XCTAssertTrue(e.overview(date: "2026-08-20").isLocked)

        let p = e.periodStats(from: "2026-08-01", to: "2026-08-31")
        XCTAssertEqual(p.countedDays, 31)
        XCTAssertEqual(p.salesDays, 31)
        // Takip şeridinde üç renk de görünür (sorunsuz, dikkat, belirgin)
        let full = p.days.filter { $0.isFullyCounted }
        XCTAssertTrue(full.contains { !$0.hasNotableProblems }, "farkı az gün")
        XCTAssertTrue(full.contains { $0.hasNotableProblems && !$0.hasSignificantProblems }, "dikkat edilecek gün")
        XCTAssertTrue(full.contains { $0.hasSignificantProblems }, "belirgin farklı gün")
        let summary = e.summary(from: "2026-08-01", to: "2026-08-31")
        XCTAssertGreaterThan(summary.first { $0.item.id == "patates" }!.shortageQty, 0, "demo verisinde fire var")
        // Özet özdeşliği korunur
        for r in summary where r.daysCounted > 0 {
            XCTAssertEqual(r.diff, r.sold + r.waste - r.actual, accuracy: 1e-6, r.item.name)
        }
        XCTAssertFalse(e.orderSuggestions(asOf: "2026-08-31", lookbackDays: 14, coverDays: 3).filter { $0.suggested > 0 }.isEmpty)
        XCTAssertEqual(data.purchaseOrders.map { $0.id }, ["demo-siparis-1", "demo-siparis-2"])
        XCTAssertEqual(data.purchaseOrders.filter { $0.status == .open }.count, 1)
        // Açık siparişin notu tedarikçiye gider: kopyalanan metnin son satırı (iç açıklama değil)
        let open = data.purchaseOrders.first { $0.status == .open }!
        XCTAssertEqual(Purchasing.text(open, items: e.itemsByID, branch: "").components(separatedBy: "\n").last,
                       "Not: Sabah 9'dan önce teslim edin")
        XCTAssertEqual(data.settings.branchName, "Burger Yiyelim · Tuzla Marina")

        // Ekip: görevli birkaç üye; sayımı yapanlar ekipten, eski sayan listesi boş
        XCTAssertEqual(data.employees.count, 5)
        XCTAssertTrue(data.employees.allSatisfy { !$0.role.isEmpty })
        XCTAssertTrue(data.settings.staff.isEmpty)
        let names = Set(Team.counterNames(data))
        XCTAssertTrue(data.days.values.allSatisfy { names.contains($0.countedBy ?? "") })
    }

    /// Demo tekrarlanabilir (web fikstürleri bundan üretilir) ve kaldırılan maliyet / ücret / vardiya alanlarını içermez:
    /// ne kayıt dosyasında ne de buluta yazılan belgelerde (anahtarlar tek tek gezilir; reçetenin "amounts" alanı ayrıdır)
    func testDemoIsDeterministicAndInventoryOnly() throws {
        let demo = DemoData.make(endingAt: "2026-08-31", days: 35)
        let a = try Persistence.encoder().encode(demo)
        XCTAssertEqual(a, try Persistence.encoder().encode(DemoData.make(endingAt: "2026-08-31", days: 35)))
        let removed: Set<String> = ["unitCost", "costHistory", "unitPrice", "amount", "payType", "rate", "costFactor", "payHistory",
                                    "defaultHours", "shifts", "otherLabor", "targetFoodCostPct", "targetLaborPct",
                                    "targetPrimeCostPct", "priceAlertPct", "salesRevenue", "revenue", "diffValue", "cost"]
        func keys(_ v: JSONValue) -> Set<String> {
            switch v {
            case .object(let o): return o.values.reduce(Set(o.keys)) { $0.union(keys($1)) }
            case .array(let a): return a.reduce([]) { $0.union(keys($1)) }
            default: return []
            }
        }
        // Gün kayıtlarında kalem kimlikleri de anahtardır; yalnızca alan adlarına bakılır
        XCTAssertEqual(keys(try JSONCoding.parse(a)).intersection(removed), [])
        for (key, body) in DocCodec.split(demo) {
            XCTAssertEqual(keys(body).intersection(removed), [], key)
        }
        let team = try XCTUnwrap(DocCodec.split(demo)[DocKey.employees])
        XCTAssertTrue(keys(team).isSubset(of: ["id", "name", "role", "phone", "active", "startDate", "endDate", "note", "account"]))
        XCTAssertFalse(String(decoding: a, as: UTF8.self).contains("₺"))
    }
}

private extension XlsxCell {
    static var blankCell: XlsxCell { XlsxCell(.blank) }
}

private extension ZipReader {
    /// Yazılmış bir zip'in dosyalarını yeni bir ZipWriter'a aktarır (üzerine dosya eklemek için)
    static func rewrap(_ data: Data) -> ZipWriter {
        var w = ZipWriter()
        let r = try! ZipReader(data: data)
        for name in r.names.sorted() { w.add(name, try! r.read(name)) }
        return w
    }
}
