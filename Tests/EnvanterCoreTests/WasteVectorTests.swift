import XCTest
@testable import EnvanterCore

/// Elle zayi (Zayi Ekle, `DayRecord.wasteLog`) — web ile ortak vektörler (Fixtures/waste-vectors.json; web test/waste.test.ts)
/// ve Mac'e özgü kayıt, okuma ve birleştirme kuralları.
final class WasteVectorTests: XCTestCase {
    func testWasteVectors() throws {
        let root = try VectorSupport.load("waste-vectors")

        // Ortak metinler
        let k = root["constants"]
        let texts: [String: String] = [
            "addTitle": WasteText.addTitle, "glossary": WasteText.glossary, "noteHint": WasteText.noteHint, "helpTip": WasteText.helpTip,
            "section": WasteText.section, "manualSection": WasteText.manualSection, "posSection": WasteText.posSection,
            "lockedNote": WasteText.lockedNote, "empty": WasteText.empty, "emptyItem": WasteText.emptyItem, "qtyRequired": WasteText.qtyRequired,
            "itemRequired": WasteText.itemRequired, "reasonRequired": WasteText.reasonRequired,
            "listLink2": WasteText.listLink(2),
        ]
        for (key, v) in texts { XCTAssertEqual(k?[key]?.stringValue, v, key) }
        XCTAssertEqual(Set(k?.objectValue?.keys.map { $0 } ?? []), Set(texts.keys).union(["noteMaxLength"]))
        XCTAssertEqual(k?["noteMaxLength"]?.doubleValue, Double(WasteLog.noteMaxLength))

        // Neden adları (bilinmeyen değer Diğer) ve seçenek sırası
        let reasons = root["reasons"]?.arrayValue ?? []
        for r in reasons {
            XCTAssertEqual(WasteReason.title(r["raw"]?.stringValue ?? "?"), r["title"]?.stringValue, r["raw"]?.stringValue ?? "")
        }
        XCTAssertEqual(WasteReason.allCases.map { $0.rawValue }, reasons.prefix(7).compactMap { $0["raw"]?.stringValue })

        // Hoşgörülü okuma
        for n in root["normalize"]?.arrayValue ?? [] {
            let name = n["name"]?.stringValue ?? "?"
            let day = try XCTUnwrap(Lenient.day(n["raw"] ?? .null, date: "2026-08-02"), name)
            if n["expected"]?.isNull ?? true {
                XCTAssertNil(day.wasteLog, name)
            } else {
                XCTAssertEqual(try JSONCoding.value(day.wasteLog ?? []), n["expected"], name)
            }
        }

        // Motor
        for c in root["cases"]?.arrayValue ?? [] {
            let name = c["name"]?.stringValue ?? "?"
            let engine = Engine(data: try VectorSupport.appData(c["data"]))
            func item(_ id: String) throws -> Item { try XCTUnwrap(engine.itemsByID[id], "\(name): kalem yok \(id)") }
            func row(_ v: JSONValue) -> ItemCalc? {
                let date = v["date"]?.stringValue ?? "", id = v["itemID"]?.stringValue ?? ""
                return engine.calc(date: date).rows.first { $0.itemID == id }
            }

            for v in c["calc"]?.arrayValue ?? [] {
                let at = "\(name) \(v["date"]?.stringValue ?? "") \(v["itemID"]?.stringValue ?? "")"
                guard let r = row(v) else { XCTFail("\(at): satır yok"); continue }
                VectorSupport.check(VectorSupport.calc(r), v["expect"], at)
                XCTAssertEqual(r.manualWaste, engine.manualWaste(date: v["date"]?.stringValue ?? "")[r.itemID] ?? 0, at)
            }
            for v in c["breakdown"]?.arrayValue ?? [] {
                let date = v["date"]?.stringValue ?? "", id = v["itemID"]?.stringValue ?? ""
                let days = engine.carryBreakdown(itemID: id, date: date)
                VectorSupport.match(.array(days.map { .object(VectorSupport.carryDay($0)) }), v["expect"] ?? .null, "\(name) döküm \(date)")
                let it = try item(id)
                XCTAssertEqual(days.map { OpeningText.carryLine($0, item: it) }, (v["lines"]?.arrayValue ?? []).compactMap { $0.stringValue }, name)
            }
            for v in c["summary"]?.arrayValue ?? [] {
                let from = v["from"]?.stringValue ?? "", to = v["to"]?.stringValue ?? "", id = v["itemID"]?.stringValue ?? ""
                guard let r = engine.summary(from: from, to: to).first(where: { $0.item.id == id }) else { XCTFail("\(name): özet yok"); continue }
                VectorSupport.check(VectorSupport.summary(r), v["expect"], "\(name) özet")
                XCTAssertEqual(r.diff, r.sold + r.waste - r.actual, accuracy: 1e-6, "\(name): özdeşlik")
            }
            for v in c["estimates"]?.arrayValue ?? [] {
                let date = v["date"]?.stringValue ?? "", id = v["itemID"]?.stringValue ?? ""
                guard let e = engine.stockEstimate(itemID: id, date: date) else { XCTFail("\(name) tahmin \(date): yok"); continue }
                VectorSupport.check(VectorSupport.estimate(e), v["expect"], "\(name) tahmin \(date)")
            }
            for v in c["fill"]?.arrayValue ?? [] {
                let date = v["date"]?.stringValue ?? ""
                let r = DayOps.fillUncountedWithOpening(engine: engine, date: date)
                XCTAssertEqual(VectorSupport.str(r.refusal?.rawValue), v["expect"]?["refusal"] ?? .null, "\(name) doldur \(date)")
                let before = engine.data.days[date]
                var written: [String: JSONValue] = [:]
                for (id, e) in r.day?.entries ?? [:] where e.closing != nil && before?.entries[id]?.closing == nil {
                    written[id] = .number(e.closing ?? 0)
                }
                XCTAssertEqual(JSONValue.object(written), v["expect"]?["closings"] ?? .null, "\(name) doldur \(date)")
            }
            for v in c["texts"]?.arrayValue ?? [] {
                let date = v["date"]?.stringValue ?? "", id = v["itemID"]?.stringValue ?? ""
                guard let r = row(v) else { XCTFail("\(name): satır yok"); continue }
                let it = try item(id), day = engine.data.days[date], legacy = day?.usesLegacySales ?? false
                let actual: [String: String?] = [
                    "duplicateHint": WasteText.duplicateHint(r, day: day, item: it),
                    "cellHelp": WasteText.cellHelp(r, legacy: legacy, item: it),
                    "legacyLine": WasteText.legacyLine(r, legacy: legacy, item: it),
                ]
                for (key, expected) in v["expect"]?.objectValue ?? [:] {
                    guard let value = actual[key] else { XCTFail("\(name): bilinmeyen alan \(key)"); continue }
                    XCTAssertEqual(VectorSupport.str(value), expected, "\(name) \(key) \(date)")
                }
            }
        }

        // Kayıt metinleri
        let textItems = try JSONCoding.decode([Item].self, from: root["entryTextItems"] ?? .array([]))
        for t in root["entryTexts"]?.arrayValue ?? [] {
            let entry = try JSONCoding.decode(WasteEntry.self, from: t["entry"] ?? .null)
            let item = t["itemID"]?.stringValue.flatMap { id in textItems.first { $0.id == id } }
            VectorSupport.check(["saved": .string(WasteText.saved(entry, item: item)), "removed": .string(WasteText.removed(entry, item: item)),
                                 "detail": .string(WasteText.detail(entry)), "amount": .string(WasteText.amount(entry.qty, item: item))],
                                t["expect"], entry.id)
        }

        // Değişiklik geçmişi özetleri
        var data = AppData(items: [], products: [])
        data.items = try JSONCoding.decode([Item].self, from: root["activityItems"] ?? .array([]))
        let key = DocKey.day(root["activityDate"]?.stringValue ?? "")
        for a in root["activity"]?.arrayValue ?? [] {
            let before = a["before"].flatMap { $0.isNull ? nil : $0 }, after = a["after"].flatMap { $0.isNull ? nil : $0 }
            XCTAssertEqual(ChangeSummary.summarize(key: key, before: before, after: after, data: data), a["expected"]?.stringValue,
                           a["name"]?.stringValue ?? "")
        }
    }

    // MARK: - Kayıt kuralları

    func testMakeAddRemove() throws {
        let at = Date(timeIntervalSince1970: 1_791_927_605.123)  // 2026-10-13T21:40:05Z
        XCTAssertNil(WasteLog.make(itemID: "patates", qty: 0, reason: .spoiled))
        XCTAssertNil(WasteLog.make(itemID: "patates", qty: -1, reason: .spoiled))
        XCTAssertNil(WasteLog.make(itemID: "patates", qty: .nan, reason: .spoiled))
        XCTAssertNil(WasteLog.make(itemID: "", qty: 1, reason: .spoiled))
        let e = try XCTUnwrap(WasteLog.make(id: "x", itemID: "patates", qty: 1.23456789, reason: .dropped, note: "  ", by: " Murat A. ", at: at))
        XCTAssertEqual(e, WasteEntry(id: "x", itemID: "patates", qty: 1.234568, reason: "dropped", note: nil, by: "Murat A.", at: "2026-10-13T21:40:05Z"))
        XCTAssertEqual(WasteLog.make(itemID: "patates", qty: 1, reason: .other, note: String(repeating: "a", count: 250), at: at)?.note?.count, 200)

        let day = DayRecord(date: "2026-08-02")
        let e1 = WasteEntry(id: "e1", itemID: "patates", qty: 2, reason: "spoiled")
        let e2 = WasteEntry(id: "e2", itemID: "g90", qty: 1, reason: "burnt")
        let d1 = WasteLog.adding(e2, to: WasteLog.adding(e1, to: day))
        XCTAssertEqual(d1.wasteLog, [e1, e2])
        XCTAssertTrue(d1.hasInventoryData)
        XCTAssertFalse(d1.isEmpty)
        XCTAssertEqual(WasteLog.entries(d1, itemID: "g90"), [e2])
        // Son kayıt silinince [] kalır; boş gün sayılır ve bulutta tutulmaz
        let d2 = WasteLog.removing(id: "e2", from: WasteLog.removing(id: "e1", from: d1))
        XCTAssertEqual(d2.wasteLog, [])
        XCTAssertTrue(d2.isEmpty)
        XCTAssertNil(DocCodec.storedDay(d2))
        var noted = d2
        noted.note = "x"
        let body = try XCTUnwrap(DocCodec.storedDay(noted).flatMap { try? JSONCoding.value($0) })
        XCTAssertEqual(body["wasteLog"], .array([]), "[] yazılır (anahtar silinmez)")
        // Olmayan kayıt: gün aynen
        XCTAssertEqual(WasteLog.removing(id: "yok", from: d1), d1)
        XCTAssertNil(WasteLog.removing(id: "e1", from: day).wasteLog)
        XCTAssertEqual(WasteLog.time(WasteEntry(itemID: "p", qty: 1, reason: "x", at: "2026-08-26T19:30:00Z"),
                                     timeZone: TimeZone(identifier: "Europe/Istanbul")!), "22:30")
        XCTAssertNil(WasteLog.time(WasteEntry(itemID: "p", qty: 1, reason: "x")))
    }

    /// Bilinen gün alanı; bulut belgesinde gidiş-dönüş; [] okunurken korunur; eski istemcinin gövdesiyle birleştirme
    func testDocumentsAndMerge() throws {
        XCTAssertTrue(DocCodec.knownDayKeys.contains("wasteLog"))
        let raw = try JSONCoding.parse(Data(#"{"date":"2026-08-02","entries":{},"sales":[],"wasteLog":[{"id":"a","itemID":"patates","qty":2,"reason":"spoiled","photo":"x.jpg"}]}"#.utf8))
        XCTAssertFalse(DocCodec.hasForeignContent(raw), "wasteLog bilinmeyen içerik sayılmaz")
        var data = AppData(items: [], products: [])
        XCTAssertTrue(DocCodec.apply(key: "day:2026-08-02", body: raw, to: &data))
        XCTAssertEqual(data.days["2026-08-02"]?.wasteLog?.first?.qty, 2)
        // Yalnızca boş listesi olan gün saklanmaz; notlu günde [] kalır
        XCTAssertTrue(DocCodec.apply(key: "day:2026-08-03", body: try JSONCoding.parse(Data(#"{"wasteLog":[]}"#.utf8)), to: &data))
        XCTAssertNil(data.days["2026-08-03"])
        XCTAssertTrue(DocCodec.apply(key: "day:2026-08-04", body: try JSONCoding.parse(Data(#"{"note":"x","wasteLog":[]}"#.utf8)), to: &data))
        XCTAssertEqual(data.days["2026-08-04"]?.wasteLog, [])

        // Bilinmeyen eleman alanı (ileriki sürüm) gönderimde korunur: taban = Mac'in görünümü, uzak = ham gövde
        let baseView = DocCodec.decoded(key: "day:2026-08-02", body: raw)
        var local = try XCTUnwrap(data.days["2026-08-02"])
        local = WasteLog.adding(WasteEntry(id: "b", itemID: "patates", qty: 1, reason: "dropped"), to: local)
        let localBody = try JSONCoding.value(local)
        let sent = CloudSyncEngine.bodyPreservingUnknownFields(local: localBody, baseRaw: raw, baseNormalized: baseView)
        XCTAssertEqual(sent["wasteLog"]?.arrayValue?.count, 2)
        XCTAssertEqual(sent["wasteLog"]?.arrayValue?.first?["photo"], .string("x.jpg"))

        // Eski istemcinin (wasteLog bilmeyen) gövdesi yenisiyle birleşir: alan korunur, eski istemcinin notu gelir
        let e1 = try JSONCoding.value(WasteEntry(id: "e1", itemID: "patates", qty: 2, reason: "spoiled"))
        let base = JSONValue.object(["note": .string("a")])
        let mine = JSONValue.object(["note": .string("a"), "wasteLog": .array([e1])])
        let old = JSONValue.object(["note": .string("b")])
        XCTAssertEqual(JSONMerge.merge3(base: base, local: mine, remote: old), .object(["note": .string("b"), "wasteLog": .array([e1])]))
    }

    /// Dönem Excel'i "üzerine yaz" ile geri aktarılınca elle zayi iki kez sayılmaz: Alımlar'daki Zaiyat elle girileni içerir
    func testHistoryReimportDoesNotDoubleCountManualWaste() throws {
        var data = DemoData.make(endingAt: "2026-08-31", days: 35)
        let d = "2026-08-26"
        data.days[d]?.locked = nil  // demo geçmiş günleri kapatır; kapatılmış güne aktarım dokunmaz
        let before = try XCTUnwrap(Engine(data: data).calc(date: d).rows.first { $0.itemID == "patates" })
        XCTAssertEqual(before.manualWaste, 2)

        let xlsx = Exporter.history(engine: Engine(data: data), from: "2026-08-01", to: "2026-08-31")
        let imp = try WorkbookImporter.parse(data: xlsx, sourceName: "envanter-2026-08.xlsx", items: data.items)
        XCTAssertEqual(try XCTUnwrap(imp.days[d]?.legacyWaste?["patates"]), before.waste, accuracy: 1e-9, "Zaiyat = toplam zayi")
        let report = WorkbookImporter.apply(imp, to: &data, overwrite: true)
        XCTAssertEqual(report.wasteReconciled, 1)
        XCTAssertNotNil(report.wasteNote)

        let day = try XCTUnwrap(data.days[d])
        XCTAssertTrue(day.usesLegacySales)
        XCTAssertEqual(day.wasteLog?.map { $0.id }, ["demo-zayi-1"], "elle kayıt kalır")
        let after = try XCTUnwrap(Engine(data: data).calc(date: d).rows.first { $0.itemID == "patates" })
        XCTAssertEqual(after.manualWaste, 2)
        XCTAssertEqual(after.waste, before.waste, accuracy: 1e-6, "Zayi değişmez")
        XCTAssertEqual(try XCTUnwrap(after.diff), try XCTUnwrap(before.diff), accuracy: 1e-6, "Fark değişmez")
        let s0 = try XCTUnwrap(Engine(data: DemoData.make(endingAt: "2026-08-31", days: 35)).summary(from: "2026-08-01", to: "2026-08-31")
            .first { $0.item.id == "patates" })
        let s1 = try XCTUnwrap(Engine(data: data).summary(from: "2026-08-01", to: "2026-08-31").first { $0.item.id == "patates" })
        XCTAssertEqual(s1.waste, s0.waste, accuracy: 1e-6, "dönem zayisi değişmez")
    }

    /// Zaiyat ile elle zayinin uzlaştırılması: Zaiyat ≥ elle → düşülür; Zaiyat < elle → o kalemin kayıtları silinir ([] kalır);
    /// Zaiyat'ı olmayan kalemin kayıtları kalır
    func testReconcileManualWaste() {
        let p1 = WasteEntry(id: "p1", itemID: "patates", qty: 1.5, reason: "spoiled")
        let p2 = WasteEntry(id: "p2", itemID: "patates", qty: 0.5, reason: "dropped")
        let g = WasteEntry(id: "g", itemID: "g90", qty: 3, reason: "burnt")
        let peynir = WasteEntry(id: "y", itemID: "peynir", qty: 1, reason: "other")

        var r = WorkbookImporter.reconcileManualWaste(legacyWaste: ["patates": 2.5, "g90": 1], wasteLog: [p1, g, p2, peynir])
        XCTAssertEqual(r.legacyWaste, ["patates": 0.5, "g90": 1], "patates 2,5 − 2 = 0,5; g90 Zaiyat'ı elle girilenden az: aynen kalır")
        XCTAssertEqual(r.wasteLog, [p1, p2, peynir], "g90 kaydı silinir, Zaiyat'ı olmayan peynir kalır")
        XCTAssertEqual(r.items, 2)

        r = WorkbookImporter.reconcileManualWaste(legacyWaste: ["patates": 2], wasteLog: [p1, p2])
        XCTAssertNil(r.legacyWaste, "Zaiyat tamamen elle girilen: Excel zayisi kalmaz")
        XCTAssertEqual(r.wasteLog, [p1, p2])

        r = WorkbookImporter.reconcileManualWaste(legacyWaste: ["g90": 1], wasteLog: [g])
        XCTAssertEqual(r.legacyWaste, ["g90": 1])
        XCTAssertEqual(r.wasteLog, [], "son kayıt silinince [] kalır")

        r = WorkbookImporter.reconcileManualWaste(legacyWaste: nil, wasteLog: [g])
        XCTAssertNil(r.legacyWaste)
        XCTAssertEqual(r.wasteLog, [g])
        XCTAssertEqual(r.items, 0)
        r = WorkbookImporter.reconcileManualWaste(legacyWaste: ["g90": 1], wasteLog: nil)
        XCTAssertEqual(r.legacyWaste, ["g90": 1])
        XCTAssertNil(r.wasteLog)
    }

    /// Demo verisi: Dondurucu arızası günü patates için elle 2 kg zayi
    func testDemoWaste() throws {
        let data = DemoData.make(endingAt: "2026-08-31", days: 35)
        let d = "2026-08-26"
        XCTAssertEqual(data.days[d]?.wasteLog?.map { $0.id }, ["demo-zayi-1"])
        let engine = Engine(data: data)
        let row = try XCTUnwrap(engine.calc(date: d).rows.first { $0.itemID == "patates" })
        XCTAssertEqual(row.manualWaste, 2)
        XCTAssertEqual(row.waste, Engine.clean(engine.analysis(date: d).waste["patates", default: 0] + 2), accuracy: 1e-9)
        // Excel: Zayi Kayıtları sayfası
        let sheet = try XCTUnwrap(Exporter.wasteSheet(engine: engine, dates: engine.datesWithData))
        XCTAssertEqual(sheet.header, Exporter.wasteHeader)
        XCTAssertEqual(sheet.rows.count, 1)
        XCTAssertNil(Exporter.wasteSheet(engine: engine, dates: ["2026-08-25"]))
    }
}
