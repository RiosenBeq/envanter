import XCTest
@testable import EnvanterCore

/// Sayım Excel'i: yükleme kuralları web ile ortak vektörlerden (Fixtures/countimport-vectors.json; web
/// test/fixtures/countimport-vectors.json, birebir aynı dosya), şablonun gidiş-dönüşü ve sayım ekranı metinleri.
final class CountImportVectorTests: XCTestCase {
    private func cell(_ v: JSONValue) -> CountImport.Cell? {
        switch v {
        case .number(let n): return .number(n)
        case .string(let s): return .text(s)
        default: return nil
        }
    }

    private func items(_ v: JSONValue?) -> [Item] {
        (v?.arrayValue ?? []).map {
            Item(id: $0["id"]?.stringValue ?? "", name: $0["name"]?.stringValue ?? "", unit: $0["unit"]?.stringValue ?? "",
                 recipeUnit: "", factor: 1)
        }
    }

    func testVectors() throws {
        let root = try VectorSupport.load("countimport-vectors")
        // Başlık adları ve şablon düzeni iki istemcide aynı
        let aliases = (root["aliases"]?.arrayValue ?? []).map { pair -> String in
            let a = pair.arrayValue ?? []
            return (a.first?.stringValue ?? "") + ":" + (a.last?.arrayValue ?? []).compactMap { $0.stringValue }.joined(separator: ",")
        }
        XCTAssertEqual(aliases, CountImport.aliases.map { $0.column.rawValue + ":" + $0.names.joined(separator: ",") })
        let t = root["template"]
        XCTAssertEqual(t?["sheet"]?.stringValue, CountImport.sheetName)
        XCTAssertEqual((t?["header"]?.arrayValue ?? []).compactMap { $0.stringValue }, CountImport.templateHeader)
        XCTAssertEqual((t?["widths"]?.arrayValue ?? []).compactMap { $0.doubleValue }, CountImport.templateWidths)
        XCTAssertEqual(CountImport.title(branch: "Tuzla Marina", date: "2026-08-31"), "Tuzla Marina · Sayım 31.08.2026")

        let list = items(root["items"])
        let cases = root["cases"]?.arrayValue ?? []
        XCTAssertGreaterThanOrEqual(cases.count, 6)
        for c in cases {
            let name = c["name"]?.stringValue ?? "?"
            let grid = (c["grid"]?.arrayValue ?? []).map { ($0.arrayValue ?? []).map(cell) }
            let got = CountImport.parse(grid: grid, items: list)
            let want = try XCTUnwrap(c["expected"], name)
            XCTAssertEqual(got.headerRow.map(Double.init), want["headerRow"]?.doubleValue, "\(name): başlık satırı")
            XCTAssertEqual(got.message, want["message"]?.stringValue, "\(name): ileti")

            let updates = want["updates"]?.arrayValue ?? []
            XCTAssertEqual(got.updates.map { $0.itemID }, updates.compactMap { $0["itemID"]?.stringValue }, "\(name): kalemler")
            for (u, w) in zip(got.updates, updates) {
                let fields = w["fields"]?.objectValue ?? [:]
                let gotFields = u.values.filter { $0.key != .waste }
                XCTAssertEqual(Set(gotFields.keys.map { $0.rawValue }), Set(fields.keys), "\(name): \(u.itemID) alanları")
                for (k, v) in fields {
                    guard let f = CountImport.Field(rawValue: k), let got = u.values[f], let want = v.doubleValue else {
                        XCTFail("\(name): \(u.itemID).\(k) yok"); continue
                    }
                    XCTAssertEqual(got, want, accuracy: 1e-9, "\(name): \(u.itemID).\(k)")
                }
                if let w = w["waste"]?.doubleValue {
                    XCTAssertEqual(u.values[.waste] ?? -1, w, accuracy: 1e-9, "\(name): \(u.itemID) zayi")
                } else {
                    XCTAssertNil(u.values[.waste], "\(name): \(u.itemID) zayi olmamalı")
                }
            }

            let unknown = want["unknown"]?.arrayValue ?? []
            XCTAssertEqual(got.unknown.map { "\($0.row):\($0.name)" },
                           unknown.map { "\(Int($0["row"]?.doubleValue ?? 0)):\($0["name"]?.stringValue ?? "")" }, "\(name): bulunamayan")

            let errors = want["errors"]?.arrayValue ?? []
            XCTAssertEqual(got.errors.count, errors.count, "\(name): hatalı hücre sayısı")
            for (e, w) in zip(got.errors, errors) {
                XCTAssertEqual(Double(e.row), w["row"]?.doubleValue, "\(name): hata satırı")
                XCTAssertEqual(e.column.rawValue, w["column"]?.stringValue, "\(name): hata sütunu")
                XCTAssertEqual(e.value, w["value"].flatMap(cell), "\(name): hücre değeri olduğu gibi")
            }

            let dups = want["duplicates"]?.arrayValue ?? []
            XCTAssertEqual(got.duplicates.map { "\($0.row):\($0.itemID)" },
                           dups.map { "\(Int($0["row"]?.doubleValue ?? 0)):\($0["itemID"]?.stringValue ?? "")" }, "\(name): yinelenen")
        }
    }

    // MARK: - Şablon ve uygulama

    private let date = "2026-08-02"

    /// 01.08 sayımı (devreden), 02.08'de Gelen, elle zayi ve Excel zayi kaydı olan veri
    private func sampleData() -> AppData {
        var data = AppData.seeded()
        data.settings.branchName = "Kadıköy"
        data.days["2026-08-01"] = DayRecord(date: "2026-08-01", entries: ["g90": DayEntry(closing: 100), "patates": DayEntry(closing: 20)])
        var day = DayRecord(date: date, entries: ["g90": DayEntry(incoming: 50)])
        day.wasteLog = [WasteEntry(id: "elle-1", itemID: "patates", qty: 0.5, reason: "burnt", note: "Yanan", by: "Murat")]
        data.days[date] = day
        return data
    }

    private func row(of itemID: String, in grid: [[CountImport.Cell?]]) -> Int? {
        grid.firstIndex { $0.count > 1 && $0[1] == .text(itemID) }
    }

    /// Hücre (satır son dolu hücrede biter; ötesi boş)
    private func at(_ grid: [[CountImport.Cell?]], _ r: Int, _ c: Int) -> CountImport.Cell? {
        c < grid[r].count ? grid[r][c] : nil
    }

    private func set(_ grid: inout [[CountImport.Cell?]], _ r: Int, _ c: Int, _ v: CountImport.Cell?) {
        while grid[r].count <= c { grid[r].append(nil) }
        grid[r][c] = v
    }

    func testTemplateLayoutAndRoundTrip() throws {
        var data = sampleData()
        let engine = Engine(data: data)
        let sheets = try XlsxReader.read(data: Exporter.countSheet(engine: engine, date: date, branch: data.settings.branchName))
        let sheet = try XCTUnwrap(sheets.first)
        XCTAssertEqual(sheet.name, "Sayım Formu")
        XCTAssertEqual(sheet.value(row: 1, col: 1), "Kadıköy · Sayım 02.08.2026")
        XCTAssertEqual((1...9).map { sheet.value(row: 2, col: $0) ?? "" }, CountImport.templateHeader)
        XCTAssertEqual(sheet.value(row: 3, col: 1), engine.activeItems.first?.name, "kalemler 3. satırdan, ekrandaki sırayla")
        XCTAssertEqual(sheet.maxRow, engine.activeItems.count + 2)

        var grid = CountImport.grid(sheet: sheet)
        let parsed = CountImport.parse(grid: grid, items: engine.activeItems)
        XCTAssertEqual(parsed.headerRow, 2)
        XCTAssertTrue(parsed.unknown.isEmpty && parsed.errors.isEmpty && parsed.duplicates.isEmpty)
        XCTAssertTrue(CountImport.changes(parsed.updates, day: data.days[date]).isEmpty, "indirilen şablon geri yüklenince değişiklik yok")
        let g90 = try XCTUnwrap(row(of: "g90", in: grid))
        XCTAssertEqual(at(grid, g90, 3), .number(100), "Devreden hesaplanan değer (yüklenmez)")
        XCTAssertEqual(at(grid, g90, 4), .number(50), "Giren güncel değer")
        XCTAssertNil(at(grid, g90, 7), "girilmemiş Kalan boş")

        // Depoda doldurulan şablon: g90 Kalan "120+28", patates Zayi 1,5 ve Kalan 18,5; Devreden değiştirilse de yüklenmez
        let pat = try XCTUnwrap(row(of: "patates", in: grid))
        set(&grid, g90, 7, .text("120+28"))
        set(&grid, g90, 3, .number(999))
        set(&grid, pat, 6, .text("1,5"))
        set(&grid, pat, 7, .number(18.5))
        let filled = CountImport.parse(grid: grid, items: engine.activeItems)
        let changes = CountImport.changes(filled.updates, day: data.days[date])
        XCTAssertEqual(changes.map { $0.itemID }, ["g90", "patates"])
        XCTAssertEqual(changes.first?.changes, [CountImport.FieldChange(field: .closing, old: nil, new: 148)])
        XCTAssertEqual(changes.last?.change(.waste), CountImport.FieldChange(field: .waste, old: nil, new: 1.5))

        let stamp = Date(timeIntervalSince1970: 1_790_000_000)
        let applied = CountImport.apply(filled.updates, to: data.days[date] ?? DayRecord(date: date), wasteBy: "Ayşe", at: stamp)
        XCTAssertEqual(applied.entries["g90"], DayEntry(incoming: 50, closing: 148))
        XCTAssertNil(applied.entries["g90"]?.opening, "Devreden yüklenmedi")
        XCTAssertEqual(applied.entries["patates"]?.closing, 18.5)
        let excel = try XCTUnwrap(CountImport.excelWaste(applied, itemID: "patates"))
        XCTAssertEqual(excel.id, "excel-patates")
        XCTAssertEqual(excel.qty, 1.5)
        XCTAssertEqual(excel.reason, "other")
        XCTAssertEqual(excel.note, "Excel'den yüklendi")
        XCTAssertEqual(excel.by, "Ayşe")
        XCTAssertEqual(applied.wasteLog?.map { $0.id }, ["elle-1", "excel-patates"], "elle girilen kayıt korunur")

        // Yeniden indirilen şablonda Zayi = Excel zayi kaydı (elle girilen dahil değil)
        data.days[date] = applied
        let again = CountImport.grid(sheet: try XCTUnwrap(XlsxReader.read(data: Exporter.countSheet(engine: Engine(data: data), date: date)).first))
        let pat2 = try XCTUnwrap(row(of: "patates", in: again))
        XCTAssertEqual(at(again, pat2, 6), .number(1.5))
        XCTAssertEqual(at(again, pat2, 7), .number(18.5))

        // Zayi 2 → kayıt güncellenir (yeri değişmez); 0 → kayıt silinir
        var edit = again
        set(&edit, pat2, 6, .number(2))
        let updated = CountImport.apply(CountImport.parse(grid: edit, items: engine.activeItems).updates, to: applied, wasteBy: "Ayşe", at: stamp)
        XCTAssertEqual(updated.wasteLog?.map { $0.id }, ["elle-1", "excel-patates"])
        XCTAssertEqual(CountImport.excelWaste(updated, itemID: "patates")?.qty, 2)
        set(&edit, pat2, 6, .number(0))
        let removed = CountImport.apply(CountImport.parse(grid: edit, items: engine.activeItems).updates, to: updated, wasteBy: nil, at: stamp)
        XCTAssertEqual(removed.wasteLog?.map { $0.id }, ["elle-1"], "0: Excel zayi kaydı silindi, elle girilen kaldı")
        XCTAssertNil(CountImport.excelWaste(removed, itemID: "patates"))
    }

    func testChangeRules() {
        let day = DayRecord(date: date, entries: ["g90": DayEntry(incoming: 5, closing: 10)])
        let u = CountImport.Update(row: 3, itemID: "g90", values: [.incoming: 5, .closing: 10, .waste: 0])
        XCTAssertTrue(CountImport.changes([u], day: day).isEmpty, "aynı değerler; Zayi 0 kayıt yokken değişiklik değil")
        let zero = CountImport.Update(row: 3, itemID: "g90", values: [.transferOut: 0])
        XCTAssertEqual(CountImport.changes([zero], day: day).first?.changes, [CountImport.FieldChange(field: .transferOut, old: nil, new: 0)],
                       "boş girişe yazılan 0 değişikliktir (web ile aynı)")
        let p = CountImport.Update(row: 4, itemID: "peynir", values: [.closing: 0])
        XCTAssertEqual(CountImport.changes([p], day: day).first?.changes, [CountImport.FieldChange(field: .closing, old: nil, new: 0)],
                       "Kalan 0 sayılmış demektir")
    }

    func testTextAndCSVGrids() throws {
        let tsv = CountImport.grid(text: "Kalem\tGiren\tKalan\r\nPeynir\t\t14,28\r\n\r\n90 Gr\t1.200\t5")
        XCTAssertEqual(tsv.count, 4)
        XCTAssertEqual(tsv[1], [.text("Peynir"), nil, .text("14,28")])
        XCTAssertEqual(tsv[2], [], "boş satır satır numarasını korur")
        let list = [Item(id: "peynir", name: "Peynir", unit: "Kg", recipeUnit: "dilim", factor: 0.014),
                    Item(id: "g90", name: "90 Gr", unit: "Adet", recipeUnit: "adet", factor: 1)]
        let r = CountImport.parse(grid: tsv, items: list)
        XCTAssertEqual(r.updates, [CountImport.Update(row: 2, itemID: "peynir", values: [.closing: 14.28]),
                                   CountImport.Update(row: 4, itemID: "g90", values: [.incoming: 1200, .closing: 5])])
        let csv = CountImport.grid(text: "\u{FEFF}Kod;Kalem;Sayım\npeynir;Peynir;\"1,5\"\n")
        XCTAssertEqual(CountImport.parse(grid: csv, items: list).updates.first?.values[.closing], 1.5)
        XCTAssertEqual(try CountImport.readGrid(data: Data("Kalem,Kalan\n90 Gr,7".utf8), fileName: "sayim.csv").last, [.text("90 Gr"), .text("7")])
        XCTAssertThrowsError(try CountImport.readGrid(data: Data(), fileName: "sayim.pdf")) {
            XCTAssertEqual($0 as? CountImportError, .unsupported(".pdf"))
        }
        XCTAssertFalse(CountImport.isCountSheet(CountImport.grid(text: "Kodu\tÜrün Tipi\tAdedi\n11101\tDUBLEX\t14")),
                       "ModPos satış raporu sayım tablosu sanılmaz")
    }

    // MARK: - Sayım ekranı metinleri

    private let peynir = Item(id: "peynir", name: "Peynir", unit: "Kg", recipeUnit: "dilim", factor: 0.014, tolerance: 0.05)

    private func calc(opening: Double, incoming: Double = 0, transferIn: Double = 0, transferOut: Double = 0, closing: Double?,
                      sold: Double, waste: Double = 0, source: OpeningSource = .closing, item: Item) -> ItemCalc {
        let expected = opening + incoming + transferIn - transferOut - sold - waste
        let diff = closing.map { Engine.clean($0 - expected) }
        var c = ItemCalc(itemID: item.id, opening: opening, openingIsAuto: source != .manual, incoming: incoming,
                         transferIn: transferIn, transferOut: transferOut, closing: closing, sold: sold, waste: waste,
                         actual: closing.map { Engine.clean(opening + incoming + transferIn - transferOut - $0) },
                         diff: source == .noBase ? nil : diff, severity: source == .noBase ? nil : diff.map { item.severity(of: $0) },
                         belowMinimum: false)
        c.openingSource = source
        c.isBaseline = source == .noBase && closing != nil
        return c
    }

    func testCountTexts() {
        XCTAssertEqual(CountText.columns, ["Ürün", "Devreden", "Giren", "Çıkan", "Satılan", "Zayi", "Kalan", "Fark"])
        let item = Item(id: "peynir", name: "Peynir", unit: "Kg", recipeUnit: "dilim", factor: 0.014)
        let c = calc(opening: 16.8, closing: 14.28, sold: 2.394, item: item)
        XCTAssertEqual(c.expectedClosing ?? -1, 14.406, accuracy: 1e-9)
        XCTAssertEqual(CountText.formula(c, item: item),
                       "Devreden 16,8 + Giren 0 − Çıkan 0 − Satılan 2,394 − Zayi 0 = Olması gereken 14,406 · Sayılan 14,28 → 0,126 kg eksik")
        XCTAssertEqual(CountText.diffPill(c, item: item), "0,126 kg eksik")
        XCTAssertEqual(CountText.closingPlaceholder(c, item: item), "≈ 14,406")
        XCTAssertEqual(CountText.openingValue(c, item: item), "16,8")

        let ok = calc(opening: 16.8, closing: 14.43, sold: 2.394, item: peynir)
        XCTAssertEqual(CountText.diffPill(ok, item: peynir), "Tamam", "tolerans içinde")
        XCTAssertTrue(CountText.formula(ok, item: peynir).hasSuffix("→ Tamam (fark 0,024 kg, tolerans ±0,05)"))
        XCTAssertEqual(CountText.closingPlaceholder(calc(opening: 1, closing: nil, sold: 3, item: peynir), item: peynir), "≈ 0", "eksi tahmin ≈ 0")
        let g90 = Item(id: "g90", name: "90 Gr", unit: "Adet", recipeUnit: "adet", factor: 1)
        let same = calc(opening: 303, transferIn: 5, closing: 216, sold: 92, source: .carried, item: g90)
        XCTAssertEqual(CountText.diffPill(same, item: g90), "Tamam", "fark yok")
        let more = calc(opening: 303, transferIn: 5, closing: 220, sold: 92, source: .carried, item: g90)
        XCTAssertEqual(CountText.diffPill(more, item: g90), "4 adet fazla")
        XCTAssertEqual(CountText.openingValue(more, item: g90), "≈ 303")
        XCTAssertEqual(CountText.transferInNote(more, item: g90), "+5 şubeden")
        XCTAssertEqual(CountText.formula(more, item: g90),
                       "Devreden ≈ 303 + Giren 0 + Şubeden gelen 5 − Çıkan 0 − Satılan 92 − Zayi 0 = Olması gereken 216 · Sayılan 220 → 4 adet fazla")
        let open = calc(opening: 303, closing: nil, sold: 92, item: g90)
        XCTAssertEqual(CountText.diffPill(open, item: g90), "—")
        XCTAssertTrue(CountText.formula(open, item: g90).hasSuffix("= Olması gereken 211 · Kalan henüz sayılmadı"))
        XCTAssertNil(CountText.transferInNote(open, item: g90))
        let first = calc(opening: 0, closing: 40, sold: 0, source: .noBase, item: g90)
        XCTAssertEqual(CountText.diffPill(first, item: g90), "İlk sayım")
        XCTAssertNil(first.expectedClosing)
        XCTAssertEqual(CountText.openingValue(first, item: g90), "—")
        XCTAssertEqual(CountText.closingPlaceholder(first, item: g90), "")
        XCTAssertEqual(CountText.formula(first, item: g90), "Önceki sayım yok: bu sayım başlangıç kabul edilir, fark hesaplanmaz · Sayılan 40")
        XCTAssertEqual(CountText.diffHelp(more, item: g90), "Kalan, olması gerekenden 4 adet fazla — sayımı, girilmeyen Giren'i ya da reçeteyi kontrol edin")
        XCTAssertEqual(CountImportText.summary(changed: 4, unchanged: 3, unknown: 1, errors: 2, duplicates: 1),
                       "4 kalem değişecek · 3 kalem aynı · 1 bilinmeyen kalem · 2 okunamayan hücre · 1 yinelenen satır")
    }

    /// Gün kitabındaki "Olması Gereken" sütunu = Devreden + Giren + Şubeden gelen − Çıkan − Satılan − Zayi
    func testDayBookExpectedColumn() throws {
        var data = AppData.seeded()
        data.days["2026-08-01"] = DayRecord(date: "2026-08-01", entries: ["g90": DayEntry(closing: 100)])
        data.days["2026-08-02"] = DayRecord(date: "2026-08-02", entries: ["g90": DayEntry(incoming: 50, transferIn: 4, transferOut: 3, closing: 120)],
                                            sales: [SaleLine(code: "11100", name: "MEDIUM BURGER", qty: 15)])
        let sheets = try XlsxReader.read(data: Exporter.day(engine: Engine(data: data), date: "2026-08-02"))
        let header = (1...11).map { sheets[0].value(row: 1, col: $0) ?? "" }
        XCTAssertEqual(header, Exporter.dayHeader)
        let r = try XCTUnwrap((2...sheets[0].maxRow).first { sheets[0].value(row: $0, col: 2) == "90 Gr / Adet" })
        XCTAssertEqual(sheets[0].value(row: r, col: 10), "136", "100 + 50 + 4 − 3 − 15 = 136")
        XCTAssertEqual(sheets[0].value(row: r, col: 11), "-16", "Fark = Kalan − Olması gereken")
    }
}
