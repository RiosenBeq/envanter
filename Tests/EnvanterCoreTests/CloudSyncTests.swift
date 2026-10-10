import XCTest
@testable import EnvanterCore

/// JSON metninden değer (testlerde okunaklı girdiler için)
func j(_ s: String) -> JSONValue { try! JSONCoding.parse(Data(s.utf8)) }

final class CloudSyncTests: XCTestCase {
    let ws = "11111111-1111-1111-1111-111111111111"

    // MARK: - merge3

    func testMerge3Vectors() throws {
        guard let url = Bundle.module.url(forResource: "Fixtures/merge3-vectors", withExtension: "json") else {
            return XCTFail("merge3-vectors.json fikstürü yok")
        }
        guard case .array(let vectors) = try JSONCoding.parse(Data(contentsOf: url)) else { return XCTFail("dizi bekleniyordu") }
        XCTAssertGreaterThanOrEqual(vectors.count, 16)
        for v in vectors {
            let name = v["name"]?.stringValue ?? "?"
            let got = JSONMerge.merge3(base: v["base"], local: v["local"], remote: v["remote"])
            XCTAssertEqual(got, v["expected"], name)
            // Statik kısayol aynı sonucu verir
            XCTAssertEqual(JSONValue.merge3(base: v["base"], local: v["local"], remote: v["remote"]), v["expected"], name)
        }
    }

    func testMerge3AbsentValues() {
        let x = j(#"{"a":1}"#), y = j(#"{"a":2}"#)
        XCTAssertEqual(JSONMerge.merge3(base: nil, local: nil, remote: x), x)          // yalnızca uzakta var
        XCTAssertNil(JSONMerge.merge3(base: x, local: nil, remote: x))                 // yerelde silindi
        XCTAssertNil(JSONMerge.merge3(base: x, local: x, remote: nil))                 // uzakta silindi
        XCTAssertNil(JSONMerge.merge3(base: x, local: nil, remote: y))                 // yerel silme kazanır (kural 6)
        XCTAssertEqual(JSONMerge.merge3(base: x, local: y, remote: nil), y)            // yerel değişiklik kazanır
        XCTAssertEqual(JSONMerge.merge3(base: .null, local: x, remote: x), x)
        // Taban dizi, iki taraf nesne: nesne birleştirme yapılmaz → yerel
        XCTAssertEqual(JSONMerge.merge3(base: j("[1]"), local: x, remote: y), x)
        // Yinelenen kimlikli dizi kimliksiz sayılır → yerel kazanır
        let dupL = j(#"[{"id":"a","v":1},{"id":"a","v":2}]"#), dupR = j(#"[{"id":"a","v":3}]"#)
        XCTAssertEqual(JSONMerge.merge3(base: j("[]"), local: dupL, remote: dupR), dupL)
    }

    func testJSONValueNumbersAndCoding() throws {
        XCTAssertEqual(j("1.0"), j("1"))
        XCTAssertEqual(j(#"{"b":2,"a":[1,true,null,"x"]}"#), j(#"{"a":[1.0,true,null,"x"],"b":2.0}"#))
        XCTAssertNotEqual(j("true"), j("1"))
        XCTAssertNotEqual(j(#"{"a":null}"#), j("{}"))
        XCTAssertEqual(String(decoding: try JSONCoding.data(.number(120)), as: UTF8.self), "120")
        XCTAssertEqual(String(decoding: try JSONCoding.data(.number(0.014)), as: UTF8.self), "0.014")
        XCTAssertEqual(String(decoding: try JSONCoding.data(j(#"{"b":1,"a":"ş"}"#)), as: UTF8.self), #"{"a":"ş","b":1}"#)
        let nested = j(#"{"a":[{"id":"x","n":-2.5e3}],"b":{"c":false}}"#)
        XCTAssertEqual(try JSONCoding.parse(JSONCoding.data(nested)), nested)
        XCTAssertEqual(nested["a"]?.arrayValue?.first?["n"]?.doubleValue, -2500)
    }

    // MARK: - Belgeler

    func testSplitAssembleRoundTripOnDemoData() {
        var demo = DemoData.make(endingAt: "2026-08-31", days: 35)
        demo.days["2026-08-30"]?.salesImportedAt = JSONCoding.parseISODate("2026-08-30T10:40:00Z")
        let docs = DocCodec.split(demo)
        XCTAssertEqual(Set(DocKey.catalog).subtracting(docs.keys), [])
        let dayKeys = docs.keys.filter { DocKey.isDay($0) }
        XCTAssertEqual(dayKeys.count, demo.days.values.filter { DocCodec.storedDay($0) != nil }.count)
        XCTAssertGreaterThanOrEqual(dayKeys.count, 30)
        XCTAssertEqual(docs["day:2026-08-30"]?["salesImportedAt"]?.stringValue, "2026-08-30T10:40:00Z")
        XCTAssertEqual(docs["settings"]?["branchName"]?.stringValue, "Burger Yiyelim · Tuzla Marina")

        var failures = Set<String>()
        let back = DocCodec.assemble(docs, base: AppData(items: [], products: []), failures: &failures)
        XCTAssertEqual(failures, [])
        XCTAssertSameDocs(back, demo)
        XCTAssertEqual(back.items, demo.items)
        XCTAssertEqual(back.products, demo.products)
        XCTAssertEqual(back.settings, demo.settings)
        XCTAssertEqual(back.employees, demo.employees)
        XCTAssertEqual(back.purchaseOrders, demo.purchaseOrders)
        XCTAssertEqual(back.days, demo.days.filter { DocCodec.storedDay($0.value) != nil })
        // Her belge kendi normal halidir (Mac'in bildiği alanlar)
        for (k, v) in docs { XCTAssertEqual(DocCodec.normalize(key: k, body: v), v, k) }
    }

    func testSplitSkipsEmptyDaysButKeepsLockedOnes() {
        var d = AppData(items: [], products: [])
        d.days["2026-08-01"] = DayRecord(date: "2026-08-01")
        d.days["2026-08-02"] = DayRecord(date: "2026-08-02", locked: true)
        d.days["2026-08-03"] = DayRecord(date: "2026-08-03", note: "not")
        d.days["bozuk"] = DayRecord(date: "bozuk", note: "x")
        let keys = Set(DocCodec.split(d).keys.filter { DocKey.isDay($0) })
        XCTAssertEqual(keys, ["day:2026-08-02", "day:2026-08-03"])
        XCTAssertNil(DocCodec.body(for: "day:2026-08-01", in: d))
        XCTAssertNil(DocCodec.body(for: "day:2026-13-01", in: d))
    }

    func testAssembleKeepsMissingAndDeletesNull() {
        var base = DemoData.make(endingAt: "2026-08-10", days: 5)
        base.days["2026-08-10"]?.note = "yerel"
        let docs: [String: JSONValue] = [
            "day:2026-08-09": .null,
            "day:2026-08-20": j(#"{"entries":{"g90":{"closing":5}},"sales":[]}"#),
            "settings": j(#"{"branchName":"Web Şubesi"}"#),
            "bilinmeyen": j("{}"),
        ]
        let out = DocCodec.assemble(docs, base: base)
        XCTAssertNil(out.days["2026-08-09"])
        XCTAssertEqual(out.days["2026-08-20"]?.date, "2026-08-20")              // tarih anahtardan
        XCTAssertEqual(out.days["2026-08-20"]?.entries["g90"]?.closing, 5)
        XCTAssertEqual(out.days["2026-08-10"]?.note, "yerel")                  // belgede olmayan korunur
        XCTAssertEqual(out.items, base.items)
        XCTAssertEqual(out.settings.branchName, "Web Şubesi")
        XCTAssertEqual(out.settings.orderLookbackDays, 14)                    // eksik ayar varsayılanla
        // Silinmiş tanım belgesi web istemcisindeki gibi boşalır
        XCTAssertEqual(DocCodec.assemble(["items": .null], base: base).items, [])
        // Boş gün belgesi günü kaldırır
        XCTAssertNil(DocCodec.assemble(["day:2026-08-10": j(#"{"entries":{}}"#)], base: base).days["2026-08-10"])
    }

    func testLenientDecodingMatchesWebNormalization() {
        let items = j(#"""
        [{"id":"g90","name":"90 Gr","unit":"Adet","recipeUnit":"adet","factor":1,"active":true,"webOnly":{"x":1}},
         {"id":7,"name":"Yedi"},
         {"name":"kimliksiz"},
         "bozuk",
         {"id":"p","name":"P","unitCost":"pahalı","costHistory":[{"cost":5},{"date":"2026-08-01"}]}]
        """#)
        var d = AppData(items: [], products: [])
        XCTAssertTrue(DocCodec.apply(key: "items", body: items, to: &d))
        XCTAssertEqual(d.items.map { $0.id }, ["g90", "7", "p"])
        XCTAssertEqual(d.items[1].unit, "Adet")
        XCTAssertEqual(d.items[1].recipeUnit, "adet")
        XCTAssertEqual(d.items[1].factor, 1)
        XCTAssertTrue(d.items[1].active)
        XCTAssertNil(d.items[2].unitCost)
        XCTAssertEqual(d.items[2].costHistory, [PricePoint(date: nil, cost: 5)])

        let day = j(#"""
        {"date":"2026-01-01","entries":{"g90":{"closing":12,"opening":"x"},"bad":3},
         "sales":[{"code":11101,"qty":2,"amount":500},{"name":"kodsuz"}],
         "salesImportedAt":"2026-08-01T10:15:00.123Z","locked":"evet",
         "shifts":{"e1":{"hours":6,"worked":1}},"otherLabor":250,"futureField":true}
        """#)
        XCTAssertTrue(DocCodec.apply(key: "day:2026-08-01", body: day, to: &d))
        let r = d.days["2026-08-01"]!
        XCTAssertEqual(r.date, "2026-08-01")
        XCTAssertEqual(r.entries, ["g90": DayEntry(closing: 12)])
        XCTAssertEqual(r.sales, [SaleLine(code: "11101", name: "", qty: 2, amount: 500)])
        XCTAssertEqual(r.salesImportedAt.map { Int($0.timeIntervalSince1970) },
                       JSONCoding.parseISODate("2026-08-01T10:15:00Z").map { Int($0.timeIntervalSince1970) })
        XCTAssertNotNil(r.salesImportedAt)
        XCTAssertNil(r.locked)
        XCTAssertEqual(r.shifts, ["e1": ShiftEntry(hours: 6)])
        XCTAssertEqual(r.otherLabor, 250)

        let settings = j(#"{"branchName":"Kadıköy","orderLookbackDays":10.6,"staff":["Ali",3,"Ayşe"],"targetLaborPct":"x"}"#)
        XCTAssertTrue(DocCodec.apply(key: "settings", body: settings, to: &d))
        XCTAssertEqual(d.settings.orderLookbackDays, 11)
        XCTAssertEqual(d.settings.staff, ["Ali", "Ayşe"])
        XCTAssertNil(d.settings.targetLaborPct)
        XCTAssertEqual(d.settings.priceAlertPct, 0.05)

        let orders = j(#"[{"id":"o1","lines":[{"itemID":"g90","qty":10},{"qty":3}],"status":"garip"}]"#)
        XCTAssertTrue(DocCodec.apply(key: "orders", body: orders, to: &d))
        XCTAssertEqual(d.purchaseOrders.first?.status, .open)
        XCTAssertEqual(d.purchaseOrders.first?.lines.map { $0.itemID }, ["g90"])

        let employees = j(#"[{"id":"e1","name":"Can","payType":"weekly","payHistory":[{"rate":10}]}]"#)
        XCTAssertTrue(DocCodec.apply(key: "employees", body: employees, to: &d))
        XCTAssertEqual(d.employees.first?.payType, .monthly)
        XCTAssertEqual(d.employees.first?.costFactor, 1)
        XCTAssertEqual(d.employees.first?.payHistory, [PayTerms(from: nil, payType: .monthly, rate: 10, costFactor: 1)])

        // Gövde nesne değilse gün çözülemez → veri değişmez
        XCTAssertFalse(DocCodec.apply(key: "day:2026-08-02", body: j("[1,2]"), to: &d))
        XCTAssertNil(d.days["2026-08-02"])
    }

    func testChangedKeys() {
        let a = DemoData.make(endingAt: "2026-08-10", days: 5)
        XCTAssertEqual(DocCodec.changedKeys(a, a), [])
        var b = a
        b.items[0].unitCost = 999
        b.days["2026-08-10"]?.entries["g90", default: DayEntry()].closing = 1
        b.days["2026-08-06"] = nil                                       // silinen gün
        b.days["2026-09-01"] = DayRecord(date: "2026-09-01")             // boş gün: belge değil
        b.days["2026-09-02"] = DayRecord(date: "2026-09-02", locked: true)
        b.days["gecersiz"] = DayRecord(date: "gecersiz", note: "x")
        b.settings.staff.append("Yeni")
        b.purchaseOrders.removeAll()
        XCTAssertEqual(DocCodec.changedKeys(a, b),
                       ["items", "settings", "orders", "day:2026-08-10", "day:2026-08-06", "day:2026-09-02"])
        var c = a
        c.employees[0].rate += 1
        c.products[0].note = "x"
        XCTAssertEqual(DocCodec.changedKeys(a, c), ["employees", "products"])
    }

    func testReplacingAndRebase() {
        let started = DemoData.make(endingAt: "2026-08-10", days: 5)
        // Eşitleme sunucudan: aynı günde g90, ayrıca kalem maliyeti
        var synced = started
        synced.days["2026-08-10"]?.entries["g90", default: DayEntry()].closing = 77
        synced.items[0].unitCost = 41
        // Kullanıcı eşitleme sürerken: aynı günde peynir, başka bir gün ve ayarlar
        var current = started
        current.days["2026-08-10"]?.entries["peynir", default: DayEntry()].closing = 3.5
        current.days["2026-08-09"]?.note = "eşitleme sırasında"
        current.settings.priceAlertPct = 0.1

        let (out, changed) = DocCodec.rebase(started: started, current: current, synced: synced)
        XCTAssertEqual(changed, ["day:2026-08-10", "day:2026-08-09", "settings"])
        XCTAssertEqual(out.days["2026-08-10"]?.entries["g90"]?.closing, 77)
        XCTAssertEqual(out.days["2026-08-10"]?.entries["peynir"]?.closing, 3.5)
        XCTAssertEqual(out.days["2026-08-09"]?.note, "eşitleme sırasında")
        XCTAssertEqual(out.items[0].unitCost, 41)
        XCTAssertEqual(out.settings.priceAlertPct, 0.1)
        // Değişiklik yoksa eşitleme sonucu aynen
        XCTAssertEqual(DocCodec.rebase(started: started, current: started, synced: synced).changed, [])

        // replacing: yalnızca verilen anahtarlar
        let r = DocCodec.replacing(["items", "day:2026-08-09"], in: synced, from: current)
        XCTAssertEqual(r.items, current.items)
        XCTAssertEqual(r.days["2026-08-09"], current.days["2026-08-09"])
        XCTAssertEqual(r.days["2026-08-10"], synced.days["2026-08-10"])
        XCTAssertEqual(r.settings, synced.settings)
    }

    func testSeedOnlyAndInitialMode() {
        var seed = AppData.seeded()
        XCTAssertTrue(DocCodec.isSeedOnly(seed))
        seed.settings.branchName = "Bağlanmadan önce yazıldı"
        XCTAssertTrue(DocCodec.isSeedOnly(seed))
        seed.days["2026-08-01"] = DayRecord(date: "2026-08-01")          // boş gün sayılmaz
        XCTAssertTrue(DocCodec.isSeedOnly(seed))
        seed.days["2026-08-01"]?.note = "x"
        XCTAssertFalse(DocCodec.isSeedOnly(seed))
        var edited = AppData.seeded()
        edited.items[0].unitCost = 10
        XCTAssertFalse(DocCodec.isSeedOnly(edited))

        XCTAssertEqual(CloudSyncEngine.initialMode(localIsSeedOnly: true, remoteEmpty: true), .upload)
        XCTAssertEqual(CloudSyncEngine.initialMode(localIsSeedOnly: false, remoteEmpty: true), .upload)
        XCTAssertEqual(CloudSyncEngine.initialMode(localIsSeedOnly: true, remoteEmpty: false), .download)
        XCTAssertEqual(CloudSyncEngine.initialMode(localIsSeedOnly: false, remoteEmpty: false), .ask)
        XCTAssertTrue(CloudSyncEngine.isRemoteEmpty([]))
        XCTAssertTrue(CloudSyncEngine.isRemoteEmpty([RemoteDoc(key: "day:2026-08-01", body: j("{}"), rev: 3, deleted: true)]))
        XCTAssertFalse(CloudSyncEngine.isRemoteEmpty([RemoteDoc(key: "items", body: j("[]"), rev: 1)]))
    }

    func testBodyPreservesUnknownFields() {
        let raw = j(#"[{"id":"g90","name":"90 Gr","unit":"Adet","recipeUnit":"adet","factor":1,"active":true,"unitCost":40,"supplier":"web"}]"#)
        let baseN = DocCodec.normalize(key: "items", body: raw)!
        XCTAssertNil(baseN.arrayValue?.first?["supplier"])
        var d = AppData(items: [], products: [])
        DocCodec.apply(key: "items", body: raw, to: &d)
        d.items[0].unitCost = 44
        let local = DocCodec.body(for: "items", in: d)!
        let body = CloudSyncEngine.bodyPreservingUnknownFields(local: local, baseRaw: raw, baseNormalized: baseN)
        XCTAssertEqual(body.arrayValue?.first?["supplier"]?.stringValue, "web")
        XCTAssertEqual(body.arrayValue?.first?["unitCost"]?.doubleValue, 44)
        // Taban yoksa yerel aynen
        XCTAssertEqual(CloudSyncEngine.bodyPreservingUnknownFields(local: local, baseRaw: nil, baseNormalized: nil), local)
    }

    // MARK: - Değişiklik özetleri

    func testChangeSummaries() {
        let data = DemoData.make(endingAt: "2026-10-09", days: 3)
        let day = "day:2026-10-09"
        XCTAssertEqual(ChangeSummary.summarize(key: day, before: j(#"{"entries":{"g90":{"closing":120}},"sales":[]}"#),
                                               after: j(#"{"entries":{"g90":{"closing":110}},"sales":[]}"#), data: data),
                       "09.10.2026 sayımı: 90 Gr kapanış 120 → 110")
        XCTAssertEqual(ChangeSummary.summarize(key: day, before: j(#"{"entries":{"g90":{"closing":110}}}"#),
                                               after: j(#"{"entries":{"g90":{"closing":110},"peynir":{"incoming":5,"closing":2.25}}}"#), data: data),
                       "09.10.2026 sayımı: Peynir gelen 5, kapanış 2,25")
        XCTAssertEqual(ChangeSummary.summarize(key: day, before: nil,
                                               after: j(#"{"sales":[{"code":"11101","name":"A","qty":3,"amount":1200},{"code":"13001","name":"K","qty":1,"amount":50}],"salesImportedAt":"2026-10-09T20:00:00Z"}"#),
                                               data: data),
                       "09.10.2026 satış raporu aktarıldı (2 satır, 1.250 ₺)")
        XCTAssertEqual(ChangeSummary.summarize(key: day, before: j(#"{"note":"x"}"#), after: j(#"{"note":"x","locked":true}"#)),
                       "09.10.2026 günü kapatıldı")
        XCTAssertEqual(ChangeSummary.summarize(key: day, before: j(#"{"note":"x","locked":true}"#), after: j(#"{"note":"x"}"#)),
                       "09.10.2026 günün kilidi açıldı")
        XCTAssertEqual(ChangeSummary.summarize(key: day, before: j(#"{"note":"x"}"#),
                                               after: j(#"{"note":"x","shifts":{"e8":{"hours":6}},"otherLabor":500}"#), data: data),
                       "Vardiya 09.10.2026: Can Ö. 6 saat, diğer personel gideri 500 ₺")
        XCTAssertEqual(ChangeSummary.summarize(key: day, before: j(#"{"note":"x"}"#), after: nil), "09.10.2026 günü silindi")
        XCTAssertEqual(ChangeSummary.summarize(key: day, before: j(#"{"note":"a"}"#), after: j(#"{"note":"b","countedBy":"Selin"}"#)),
                       "09.10.2026 sayımı yapan: Selin; 09.10.2026 notu: b")
        XCTAssertEqual(ChangeSummary.summarize(key: day, before: j(#"{"note":"a"}"#), after: j(#"{"note":"a"}"#)),
                       "09.10.2026 günü güncellendi")

        let item = #"{"id":"patates","name":"Patates","unit":"Kg","recipeUnit":"kg","factor":1,"active":true,"unitCost":60}"#
        XCTAssertEqual(ChangeSummary.summarize(key: "items", before: j("[\(item)]"),
                                               after: j("[\(item.replacingOccurrences(of: "60", with: "68"))]")),
                       "Stok kalemleri: Patates birim maliyet 60 → 68 ₺")
        XCTAssertEqual(ChangeSummary.summarize(key: "items", before: j("[\(item)]"), after: j("[]")), "Stok kalemleri: Patates silindi")
        XCTAssertEqual(ChangeSummary.summarize(key: "products",
                                               before: j(#"[{"code":"11101","name":"Dublex","category":"BURGERLER","amounts":{"g90":2}}]"#),
                                               after: j(#"[{"code":"11101","name":"Dublex","category":"BURGERLER","amounts":{"g90":2,"peynir":2}}]"#),
                                               data: data),
                       "Reçeteler: Dublex: Peynir 2")
        XCTAssertEqual(ChangeSummary.summarize(key: "employees",
                                               before: j(#"[{"id":"e1","name":"Murat","role":"Müdür","payType":"monthly","rate":85000,"costFactor":1.2,"active":true}]"#),
                                               after: j(#"[{"id":"e1","name":"Murat","role":"Müdür","payType":"monthly","rate":90000,"costFactor":1.2,"active":true}]"#)),
                       "Personel: Murat ücret 85.000 → 90.000 ₺")
        XCTAssertEqual(ChangeSummary.summarize(key: "orders",
                                               before: j(#"[{"id":"o1","date":"2026-10-08","supplier":"Et Tedarik","lines":[{"itemID":"g90","qty":100}],"status":"open"}]"#),
                                               after: j(#"[{"id":"o1","date":"2026-10-08","supplier":"Et Tedarik","lines":[{"itemID":"g90","qty":100,"received":100}],"status":"received","receivedOn":"2026-10-09"}]"#)),
                       "Sipariş teslim alındı (Et Tedarik)")
        XCTAssertEqual(ChangeSummary.summarize(key: "settings", before: j(#"{"branchName":"A"}"#),
                                               after: j(#"{"branchName":"A","targetFoodCostPct":0.309,"staff":["Ali"]}"#)),
                       "Ayarlar: hammadde hedefi %30,9, sayım ekibine Ali eklendi")

        // Uzun özet 140 karakteri aşmaz ve sığmayanları sayar
        var entries: [String: JSONValue] = [:]
        for it in data.items { entries[it.id] = j(#"{"closing":1}"#) }
        let long = ChangeSummary.summarize(key: day, before: j("{}"), after: .object(["entries": .object(entries)]), data: data)
        XCTAssertLessThanOrEqual(long.utf16.count, ChangeSummary.maxLength)
        XCTAssertTrue(long.hasPrefix("09.10.2026 sayımı: 90 Gr kapanış 1, 120 Gr kapanış 1"), long)
        XCTAssertTrue(long.contains(" değişiklik"), long)
    }

    // MARK: - Durum dosyası

    func testSyncStoreRoundTripWithPrivatePermissions() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("envanter-sync-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = Persistence(directory: dir)
        try p.save(AppData.seeded())
        p.dailyBackup(try p.encode(AppData.seeded()))
        let store = SyncStore(directory: dir)
        XCTAssertEqual(store.load(), SyncState())   // dosya yok → boş durum
        var s = SyncState(config: CloudConfig(workspaceID: ws, workspaceName: "Tuzla", email: "a@b.c", role: "staff"),
                          lastRev: 42, base: ["items": BaseDoc(rev: 40, body: j("[]")), "day:2026-08-01": BaseDoc(rev: 41, body: nil, deleted: true)],
                          dirty: ["settings"], accessToken: "gizli-erisim", refreshToken: "gizli-yenileme",
                          expiresAt: Date(timeIntervalSince1970: 1_800_000_000), lastSyncAt: Date(timeIntervalSince1970: 1_799_000_000),
                          userEmail: "a@b.c", initialized: true)
        try store.save(s)
        XCTAssertEqual(store.load(), s)
        let attrs = try FileManager.default.attributesOfItem(atPath: store.file.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? (attrs[.posixPermissions] as? Int)
        XCTAssertEqual(perms, 0o600)
        // Yedeklere girmez
        XCTAssertFalse(p.backups().contains { $0.lastPathComponent == SyncStore.fileName })
        XCTAssertEqual(store.file.deletingLastPathComponent().standardizedFileURL.path, dir.standardizedFileURL.path)
        // Üzerine yazma da 0600 kalır, geçici dosya kalmaz
        s.lastRev = 43
        try store.save(s)
        XCTAssertEqual(store.load().lastRev, 43)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers, [])
        XCTAssertTrue(s.isActive)
        XCTAssertFalse(s.config!.canWriteCatalog)
        // Eski sürüm alanları olmadan da okunur
        let minimal = try JSONCoding.decoder().decode(SyncState.self, from: Data(#"{"lastRev":5}"#.utf8))
        XCTAssertEqual(minimal.lastRev, 5)
        XCTAssertFalse(minimal.initialized)
    }

    func testRetiredDefaultServerMovesToNewDefault() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("envanter-sync-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SyncStore(directory: dir)
        let tokyo = "https://eteyphpvpxmgokyfndsh.supabase.co"
        XCTAssertEqual(CloudDefaults.retiredURLs, [tokyo])
        XCTAssertNotEqual(CloudDefaults.url, tokyo)

        // Önceki sürümün eski varsayılanla yazdığı, şubeye bağlı ve oturumu açık durum
        let old = SyncState(config: CloudConfig(url: tokyo, publishableKey: "sb_publishable_eski",
                                                workspaceID: ws, workspaceName: "Tuzla", email: "patron@ornek.com", role: CloudRole.owner),
                            lastRev: 42, base: ["items": BaseDoc(rev: 40, body: j("[]"))], dirty: ["settings"],
                            accessToken: "eski-erisim", refreshToken: "eski-yenileme", lastSyncAt: Date(timeIntervalSince1970: 1_799_000_000),
                            userEmail: "patron@ornek.com", initialized: true)
        XCTAssertTrue(old.isActive)
        try store.save(old)
        let moved = try XCTUnwrap(store.load().movingOffRetiredDefault())
        // Yeni varsayılan sunucu ve anahtar; e-posta korunur
        XCTAssertEqual(moved.config?.url, CloudDefaults.url)
        XCTAssertEqual(moved.config?.publishableKey, CloudDefaults.publishableKey)
        XCTAssertEqual(moved.config?.email, "patron@ornek.com")
        // Eski veritabanına ait şube, rol, taban, bekleyen değişiklikler ve oturum taşınmaz
        XCTAssertNil(moved.config?.workspaceID)
        XCTAssertNil(moved.config?.role)
        XCTAssertEqual(moved.lastRev, 0)
        XCTAssertEqual(moved.base, [:])
        XCTAssertEqual(moved.dirty, [])
        XCTAssertFalse(moved.isSignedIn)
        XCTAssertFalse(moved.initialized)
        XCTAssertFalse(moved.signedOut)
        XCTAssertNil(moved.enforcedRole)
        // Bir kez geçince yeniden geçmez
        try store.save(moved)
        XCTAssertEqual(store.load(), moved)
        XCTAssertNil(moved.movingOffRetiredDefault())

        // Elle yazılmış biçim farkları (boşluk, sondaki "/", büyük harf) da eski varsayılan sayılır
        for variant in [" \(tokyo)/ ", "https://ETEYPHPVPXMGOKYFNDSH.supabase.co//"] {
            let s = SyncState(config: CloudConfig(url: variant, workspaceID: ws, email: "a@b.c"), initialized: true)
            XCTAssertEqual(s.movingOffRetiredDefault()?.config?.url, CloudDefaults.url, variant)
        }

        // Gelişmiş bölümünden girilmiş başka proje ve yeni varsayılan olduğu gibi kalır; hiç bağlanılmamışsa da bir şey yapılmaz
        let custom = SyncState(config: CloudConfig(url: "https://ozelproje.supabase.co", publishableKey: "sb_publishable_ozel",
                                                   workspaceID: ws, email: "a@b.c", role: CloudRole.manager),
                               lastRev: 7, accessToken: "a", refreshToken: "r", initialized: true)
        XCTAssertNil(custom.movingOffRetiredDefault())
        XCTAssertNil(SyncState(config: CloudConfig(workspaceID: ws, email: "a@b.c"), initialized: true).movingOffRetiredDefault())
        XCTAssertNil(SyncState().movingOffRetiredDefault())
        try store.save(custom)
        XCTAssertNil(store.load().movingOffRetiredDefault())
        XCTAssertEqual(store.load(), custom)
    }

    // MARK: - İki istemci (bellek içi sunucu)

    private func makeServer(staff: Bool = false) -> (FakeServer, FakeAPI, FakeAPI) {
        let server = FakeServer()
        server.addWorkspace(ws, name: "Tuzla Marina", owner: "patron")
        server.addMember(ws, user: "personel", role: staff ? CloudRole.staff : CloudRole.manager)
        return (server, FakeAPI(server: server, user: "patron"), FakeAPI(server: server, user: "personel"))
    }

    /// A buluta yükler, B (yeni kurulum) indirir
    private func connectedPair(staff: Bool = false, days: Int = 6) async throws -> (FakeServer, SimClient, SimClient) {
        let (server, apiA, apiB) = makeServer(staff: staff)
        let a = SimClient(data: DemoData.make(endingAt: "2026-08-31", days: days), api: apiA, workspace: ws)
        let modeA = try await a.connect()
        XCTAssertEqual(modeA, .upload)
        let outA = try await a.sync()
        XCTAssertNil(outA.error)
        let b = SimClient(data: AppData.seeded(), api: apiB, workspace: ws, role: staff ? CloudRole.staff : CloudRole.manager)
        let modeB = try await b.connect()
        XCTAssertEqual(modeB, .download)
        let outB = try await b.sync()
        XCTAssertNil(outB.error)
        XCTAssertEqual(outB.pushed, [])
        XCTAssertEqual(outB.rejected, [:])
        XCTAssertSameDocs(a.data, b.data)
        return (server, a, b)
    }

    func testFirstUploadThenDownloadIntoFreshClient() async throws {
        let (server, a, b) = try await connectedPair()
        let docs = server.docs[ws] ?? [:]
        XCTAssertEqual(Set(docs.keys), Set(DocCodec.split(a.data).keys))
        XCTAssertEqual(a.state.dirty, [])
        XCTAssertEqual(b.state.dirty, [])
        XCTAssertEqual(a.state.lastRev, 0)                      // gönderim lastRev'i ilerletmez (araya girenler kaçmasın)
        XCTAssertEqual(b.state.lastRev, Int64(docs.count))
        XCTAssertTrue(a.state.initialized)
        // Tabanlar sunucudaki rev'lerle aynı
        for (k, d) in docs { XCTAssertEqual(a.state.base[k]?.rev, d.rev, k); XCTAssertEqual(b.state.base[k]?.rev, d.rev, k) }
        // Etkinlik özetleri Mac istemcisinden
        XCTAssertTrue(server.activity.allSatisfy { $0.client == "mac" && !$0.summary.isEmpty })
        XCTAssertTrue(server.activity.contains { $0.key == "items" && $0.summary.hasPrefix("Stok kalemleri: ") })
        // A'nın sonraki eşitlemesi kendi yazdıklarını yeniden uygulamaz
        let again = try await a.sync()
        XCTAssertEqual(again.appliedRemote, [])
        XCTAssertEqual(again.pushed, [])
        XCTAssertEqual(a.state.lastRev, b.state.lastRev)
    }

    func testDifferentDaysOnTwoClients() async throws {
        let (_, a, b) = try await connectedPair()
        a.edit { $0.days["2026-09-01", default: DayRecord(date: "2026-09-01")].entries["g90"] = DayEntry(closing: 50) }
        b.edit { $0.days["2026-09-02", default: DayRecord(date: "2026-09-02")].note = "B notu" }
        try await a.sync()
        let ob = try await b.sync()
        XCTAssertEqual(ob.appliedRemote, ["day:2026-09-01"])
        XCTAssertEqual(ob.pushed, ["day:2026-09-02"])
        try await a.sync()
        XCTAssertSameDocs(a.data, b.data)
        XCTAssertEqual(a.data.days["2026-09-02"]?.note, "B notu")
        XCTAssertEqual(b.data.days["2026-09-01"]?.entries["g90"]?.closing, 50)
    }

    func testSameDayDifferentItemsAreMerged() async throws {
        let (_, a, b) = try await connectedPair()
        let date = "2026-08-31"
        a.edit { $0.days[date]?.entries["g90", default: DayEntry()].closing = 111 }
        b.edit { $0.days[date]?.entries["peynir", default: DayEntry()].closing = 2.5 }
        b.edit { $0.days[date]?.countedBy = "Selin" }
        try await a.sync()
        let ob = try await b.sync()
        XCTAssertTrue(ob.conflicts.contains("day:\(date)"))
        XCTAssertEqual(ob.pushed, ["day:\(date)"])
        try await a.sync()
        for c in [a, b] {
            XCTAssertEqual(c.data.days[date]?.entries["g90"]?.closing, 111)
            XCTAssertEqual(c.data.days[date]?.entries["peynir"]?.closing, 2.5)
            XCTAssertEqual(c.data.days[date]?.countedBy, "Selin")
        }
        XCTAssertSameDocs(a.data, b.data)
    }

    func testSameFieldLastWriterWins() async throws {
        let (server, a, b) = try await connectedPair()
        let date = "2026-08-31"
        // Son demo gününde 90 Gr sayılmamış (yarım sayım): ilk yazma "kapanış 110" olur
        let original = a.data.days[date]?.entries["g90"]?.closing
        a.edit { $0.days[date]?.entries["g90", default: DayEntry()].closing = 110 }
        b.edit { $0.days[date]?.entries["g90", default: DayEntry()].closing = 115 }
        try await a.sync()
        try await b.sync()                                     // B'nin değişikliği yereldir ve sonra yazar → kazanır
        try await a.sync()
        XCTAssertEqual(a.data.days[date]?.entries["g90"]?.closing, 115)
        XCTAssertEqual(b.data.days[date]?.entries["g90"]?.closing, 115)
        XCTAssertEqual(server.doc(ws, "day:\(date)")?.body["entries"]?["g90"]?["closing"]?.doubleValue, 115)
        let summaries = server.activity.filter { $0.key == "day:\(date)" }.map { $0.summary }
        let first = original.map { "31.08.2026 sayımı: 90 Gr kapanış \(Fmt.number($0, maxFraction: 2)) → 110" }
            ?? "31.08.2026 sayımı: 90 Gr kapanış 110"
        XCTAssertEqual(summaries.suffix(2), [first, "31.08.2026 sayımı: 90 Gr kapanış 110 → 115"])
    }

    func testDeletedDayPropagates() async throws {
        let (server, a, b) = try await connectedPair()
        let date = "2026-08-30"
        XCTAssertNotNil(b.data.days[date])
        a.edit { $0.days[date] = nil }
        let oa = try await a.sync()
        XCTAssertEqual(oa.pushed, ["day:\(date)"])
        XCTAssertEqual(server.doc(ws, "day:\(date)")?.deleted, true)
        XCTAssertEqual(server.doc(ws, "day:\(date)")?.body, j("{}"))
        XCTAssertEqual(server.activity.last?.summary, "30.08.2026 günü silindi")
        let ob = try await b.sync()
        XCTAssertEqual(ob.appliedRemote, ["day:\(date)"])
        XCTAssertNil(b.data.days[date])
        // Silinen günü B yeniden oluşturursa tombstone'un rev'i üzerine yazılır
        b.edit { $0.days[date] = DayRecord(date: date, note: "yeniden") }
        let ob2 = try await b.sync()
        XCTAssertEqual(ob2.pushed, ["day:\(date)"])
        XCTAssertEqual(server.doc(ws, "day:\(date)")?.deleted, false)
        try await a.sync()
        XCTAssertEqual(a.data.days[date]?.note, "yeniden")
    }

    func testConflictBetweenPullAndPushIsMergedAndRetried() async throws {
        let (server, a, _) = try await connectedPair()
        let date = "2026-08-31"
        a.edit { $0.days[date]?.entries["g90", default: DayEntry()].closing = 99 }
        // A çektikten sonra, göndermeden hemen önce web paneli aynı günde başka bir kalemi değiştirir
        var injected = false
        server.beforePut = { key in
            guard !injected, key == "day:\(date)" else { return }
            injected = true
            var body = server.doc(self.ws, key)!.body.objectValue!
            var entries = body["entries"]!.objectValue!
            var peynir = entries["peynir"]?.objectValue ?? [:]
            peynir["closing"] = .number(7.25)
            entries["peynir"] = .object(peynir)
            body["entries"] = .object(entries)
            body["webOnly"] = .string("korunmalı")
            server.write(ws: self.ws, user: "personel", key: key, body: .object(body))
        }
        let out = try await a.sync()
        XCTAssertTrue(injected)
        XCTAssertNil(out.error)
        XCTAssertEqual(out.conflicts, ["day:\(date)"])
        XCTAssertEqual(out.pushed, ["day:\(date)"])
        XCTAssertEqual(a.data.days[date]?.entries["g90"]?.closing, 99)
        XCTAssertEqual(a.data.days[date]?.entries["peynir"]?.closing, 7.25)
        let stored = server.doc(ws, "day:\(date)")!
        XCTAssertEqual(stored.body["entries"]?["g90"]?["closing"]?.doubleValue, 99)
        XCTAssertEqual(stored.body["entries"]?["peynir"]?["closing"]?.doubleValue, 7.25)
        XCTAssertEqual(stored.body["webOnly"]?.stringValue, "korunmalı")   // bilinmeyen alan kaybolmaz
        XCTAssertEqual(a.state.base["day:\(date)"]?.rev, stored.rev)
        XCTAssertEqual(a.state.dirty, [])
    }

    func testConflictRetriesAreLimited() async throws {
        let (server, a, _) = try await connectedPair()
        let date = "2026-08-31"
        a.edit { $0.days[date]?.note = "A" }
        var n = 0
        server.beforePut = { key in
            n += 1
            server.write(ws: self.ws, user: "personel", key: key, body: j(#"{"note":"web \#(n)","entries":{}}"#))
        }
        let putsBefore = server.putCount
        let out = try await a.sync()
        XCTAssertEqual(n, 1 + CloudDefaults.maxConflictRetries)                       // ilk deneme + 3 yeniden deneme
        XCTAssertEqual(server.putCount - putsBefore, 2 * n)                           // her denemeden önce bir web yazması
        XCTAssertNotNil(out.error)
        XCTAssertTrue(a.state.dirty.contains("day:\(date)"))               // sonraki turda yeniden denenir
        XCTAssertEqual(a.data.days[date]?.note, "A")                        // yerel değişiklik korunur
        server.beforePut = nil
        let again = try await a.sync()
        XCTAssertNil(again.error)
        XCTAssertEqual(server.doc(ws, "day:\(date)")?.body["note"]?.stringValue, "A")
    }

    func testStaffCannotChangeCatalogServerWins() async throws {
        let (server, a, b) = try await connectedPair(staff: true)
        let date = "2026-08-31"
        let serverItems = server.doc(ws, "items")!.rev
        b.edit { d in
            if let i = d.items.firstIndex(where: { $0.id == "patates" }) { d.items[i].unitCost = 1 }
            d.days[date]?.entries["patates", default: DayEntry()].closing = 12.5
        }
        XCTAssertEqual(b.state.dirty, ["items", "day:\(date)"])
        let out = try await b.sync()
        XCTAssertNil(out.error)
        XCTAssertEqual(out.rejected.keys.sorted(), ["items"])
        XCTAssertTrue(out.rejected["items"]!.contains("Personel"))
        XCTAssertEqual(out.pushed, ["day:\(date)"])                          // gün verisi yazılır
        XCTAssertEqual(b.state.dirty, [])
        XCTAssertEqual(b.data.items, a.data.items)                           // sunucu sürümü geri geldi
        XCTAssertEqual(server.doc(ws, "items")!.rev, serverItems)
        XCTAssertEqual(b.data.days[date]?.entries["patates"]?.closing, 12.5)
        try await a.sync()
        XCTAssertEqual(a.data.days[date]?.entries["patates"]?.closing, 12.5)
        XCTAssertSameDocs(a.data, b.data)
        // Staff yeni kurulumda indirirken tanım belgelerini yüklemeye çalışmaz
        XCTAssertFalse(server.activity.contains { $0.user == "personel" && !DocKey.isDay($0.key) })
    }

    func testRemovedMemberKeepsLocalDayWork() async throws {
        let (_, _, b) = try await connectedPair(staff: true)
        let date = "2026-08-31"
        b.edit { $0.days[date]?.note = "çevrimdışı not" }
        // Üyelik kaldırıldı: sunucu her yazmayı reddeder, okuma boş döner
        let removed = FakeServer()
        let api = FakeAPI(server: removed, user: "personel")
        let c = SimClient(data: b.data, api: api, workspace: ws, role: CloudRole.staff)
        c.state = b.state
        let out = try await c.sync()
        XCTAssertNotNil(out.error)
        if case .forbidden? = out.error {} else { XCTFail("yetki hatası bekleniyordu: \(String(describing: out.error))") }
        XCTAssertEqual(c.data.days[date]?.note, "çevrimdışı not")
        XCTAssertTrue(c.state.dirty.contains("day:\(date)"))
    }

    func testUnknownFieldsFromWebSurviveMacEdits() async throws {
        let (server, a, b) = try await connectedPair()
        // Web paneli kalemlere Mac'in bilmediği bir alan ekler
        var items = server.doc(ws, "items")!.body.arrayValue!
        var first = items[0].objectValue!
        first["supplierCode"] = .string("TDK-42")
        items[0] = .object(first)
        server.write(ws: ws, user: "patron", key: "items", body: .array(items))
        try await a.sync()
        XCTAssertEqual(a.state.dirty, [])
        // Mac başka bir kalemin maliyetini değiştirir
        a.edit { $0.items[1].unitCost = 123 }
        let out = try await a.sync()
        XCTAssertEqual(out.pushed, ["items"])
        let stored = server.doc(ws, "items")!.body.arrayValue!
        XCTAssertEqual(stored[0]["supplierCode"]?.stringValue, "TDK-42")
        XCTAssertEqual(stored[1]["unitCost"]?.doubleValue, 123)
        try await b.sync()
        XCTAssertEqual(b.data.items[1].unitCost, 123)
    }

    func testRevertedChangeIsNotPushed() async throws {
        let (server, a, _) = try await connectedPair()
        let before = server.putCount
        let old = a.data.settings.priceAlertPct
        a.edit { $0.settings.priceAlertPct = 0.2 }
        a.edit { $0.settings.priceAlertPct = old }
        XCTAssertEqual(a.state.dirty, ["settings"])
        let out = try await a.sync()
        XCTAssertEqual(out.pushed, [])
        XCTAssertEqual(server.putCount, before)
        XCTAssertEqual(a.state.dirty, [])
    }

    func testAskWhenBothSidesHaveDataAndUploadKeepsCloudOnlyDays() async throws {
        let (server, a, _) = try await connectedPair()
        // Başka bir Mac'te kendi verisi olan biri bağlanır
        var other = DemoData.make(endingAt: "2026-07-31", days: 3, seed: 7)
        other.settings.branchName = "Eski Mac"
        let c = SimClient(data: other, api: FakeAPI(server: server, user: "patron"), workspace: ws)
        let mode = try await c.connect()
        XCTAssertEqual(mode, .ask)
        XCTAssertEqual(c.state.initialized, false)
        try await c.connect(.upload)
        XCTAssertTrue(c.state.initialized)
        let out = try await c.sync()
        XCTAssertNil(out.error)
        // Bu Mac'tekiler yüklendi; buluttaki günler korunup bu Mac'e geldi
        XCTAssertEqual(server.doc(ws, "settings")?.body["branchName"]?.stringValue, "Eski Mac")
        XCTAssertNotNil(c.data.days["2026-08-31"])
        XCTAssertNotNil(c.data.days["2026-07-31"])
        try await a.sync()
        XCTAssertSameDocs(a.data, c.data)
    }

    func testDownloadReplacesLocalDays() async throws {
        let (server, a, _) = try await connectedPair()
        let local = DemoData.make(endingAt: "2026-07-31", days: 3, seed: 9)
        let c = SimClient(data: local, api: FakeAPI(server: server, user: "patron"), workspace: ws)
        try await c.connect(.download)
        XCTAssertNil(c.data.days["2026-07-31"])
        XCTAssertSameDocs(c.data, a.data)
        XCTAssertEqual(c.state.dirty, [])
        let out = try await c.sync()
        XCTAssertEqual(out.pushed, [])
    }

    func testDivergentKeysFindChangesSavedWithoutState() async throws {
        let (_, a, _) = try await connectedPair()
        XCTAssertEqual(CloudSyncEngine.divergentKeys(local: a.data, state: a.state), [])
        // Uygulama kaydetti ama durum dosyası yazılamadan kapandı
        var changed = a.data
        changed.days["2026-08-31"]?.note = "kapanmadan önce"
        changed.days["2026-08-30"] = nil
        changed.items[0].minStock = 3
        XCTAssertEqual(CloudSyncEngine.divergentKeys(local: changed, state: a.state), ["day:2026-08-31", "day:2026-08-30", "items"])
        var staffState = a.state
        staffState.config?.role = CloudRole.staff
        XCTAssertEqual(CloudSyncEngine.divergentKeys(local: changed, state: staffState), ["day:2026-08-31", "day:2026-08-30"])
    }

    func testPushErrorKeepsPulledChanges() async throws {
        let (server, a, b) = try await connectedPair()
        a.edit { $0.days["2026-08-31"]?.note = "A'dan" }
        try await a.sync()
        b.edit { $0.days["2026-08-29"]?.note = "B'den" }
        _ = server
        // B'nin gönderimi ağ hatasıyla kesilir
        final class FailingAPI: SupabaseAPIProtocol, @unchecked Sendable {
            let inner: FakeAPI
            init(_ inner: FakeAPI) { self.inner = inner }
            var currentSession: AuthSession? { get async { await inner.currentSession } }
            func signIn(email: String, password: String) async throws -> AuthSession { try await inner.signIn(email: email, password: password) }
            func refresh() async throws -> AuthSession { try await inner.refresh() }
            func myWorkspaces() async throws -> [CloudWorkspace] { try await inner.myWorkspaces() }
            func createWorkspace(name: String) async throws -> String { try await inner.createWorkspace(name: name) }
            func pull(workspace: String, since: Int64) async throws -> [RemoteDoc] { try await inner.pull(workspace: workspace, since: since) }
            func put(workspace: String, key: String, body: JSONValue, baseRev: Int64, deleted: Bool, client: String, summary: String?) async throws -> PutResult {
                throw CloudSyncError.network("bağlantı koptu")
            }
        }
        let c = SimClient(data: b.data, api: FailingAPI(b.api as! FakeAPI), workspace: ws)
        c.state = b.state
        let out = try await c.sync()
        XCTAssertEqual(out.error, .network("bağlantı koptu"))
        XCTAssertEqual(c.data.days["2026-08-31"]?.note, "A'dan")          // çekilen uygulandı
        XCTAssertEqual(c.data.days["2026-08-29"]?.note, "B'den")          // yerel korunur
        XCTAssertEqual(c.state.dirty, ["day:2026-08-29"])
        XCTAssertGreaterThan(c.state.lastRev, b.state.lastRev)
        XCTAssertEqual(c.state.lastSyncAt, b.state.lastSyncAt)            // hatalı tur "eşitlendi" sayılmaz
    }

    func testNotConfiguredThrows() async {
        let api = FakeAPI(server: FakeServer(), user: "x")
        var st = SyncState()
        do {
            _ = try await CloudSyncEngine.syncOnce(local: AppData.seeded(), state: &st, api: api)
            XCTFail("hata bekleniyordu")
        } catch {
            XCTAssertEqual(error as? CloudSyncError, .notConfigured)
        }
    }

    // MARK: - Supabase istekleri (sahte taşıyıcı)

    private func session(_ token: String = "A1", refresh: String = "R1", expires: Date? = Date().addingTimeInterval(3600)) -> AuthSession {
        AuthSession(accessToken: token, refreshToken: refresh, expiresAt: expires, email: "a@b.c")
    }

    func testSignInRequestAndSession() async throws {
        let t = MockTransport { _ in
            .json(200, #"{"access_token":"AT","token_type":"bearer","expires_in":3600,"expires_at":1800000000,"refresh_token":"RT","user":{"id":"u1","email":"selin@ornek.com"}}"#)
        }
        let api = try SupabaseAPI(url: "https://proje.supabase.co/", publishableKey: "sb_publishable_x", transport: t)
        let s = try await api.signIn(email: " selin@ornek.com ", password: "şifre 1")
        XCTAssertEqual(s, AuthSession(accessToken: "AT", refreshToken: "RT", expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
                                      userID: "u1", email: "selin@ornek.com"))
        let r = t.requests[0]
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.url.absoluteString, "https://proje.supabase.co/auth/v1/token?grant_type=password")
        XCTAssertEqual(r.headers["apikey"], "sb_publishable_x")
        XCTAssertEqual(r.headers["Content-Type"], "application/json")
        XCTAssertNil(r.headers["Authorization"])
        XCTAssertEqual(r.jsonBody, j(#"{"email":"selin@ornek.com","password":"şifre 1"}"#))
        let current = await api.currentSession
        XCTAssertEqual(current?.accessToken, "AT")
    }

    func testSignInErrorsAreTurkish() async throws {
        let cases: [(Int, String, CloudSyncError)] = [
            (400, #"{"code":400,"error_code":"invalid_credentials","msg":"Invalid login credentials"}"#, .invalidCredentials),
            (400, #"{"error":"invalid_grant","error_description":"Invalid login credentials"}"#, .invalidCredentials),
            (400, #"{"code":400,"error_code":"email_not_confirmed","msg":"Email not confirmed"}"#, .emailNotConfirmed),
            (429, #"{"code":429,"error_code":"over_request_rate_limit","msg":"Request rate limit reached"}"#, .rateLimited),
            (500, "Internal", .server(status: 500, message: "Internal")),
        ]
        for (status, body, expected) in cases {
            let api = try SupabaseAPI(url: "https://p.supabase.co", publishableKey: "k", transport: MockTransport { _ in .json(status, body) })
            do {
                _ = try await api.signIn(email: "a@b.c", password: "x")
                XCTFail("hata bekleniyordu")
            } catch {
                XCTAssertEqual(error as? CloudSyncError, expected, body)
            }
        }
        XCTAssertEqual(CloudSyncError.invalidCredentials.localizedDescription, "E-posta ya da şifre yanlış.")
        XCTAssertTrue(CloudSyncError.emailNotConfirmed.localizedDescription.contains("onaylanmamış"))
        XCTAssertEqual(CloudSyncError.forbidden("").localizedDescription,
                       "Yetki yok: personel yalnızca gün verisi (sayım, satış, vardiya, not) yazabilir.")
        XCTAssertTrue(CloudSyncError.network("timeout").localizedDescription.hasPrefix("Ağ hatası"))
        // Ağ hatası
        let down = try SupabaseAPI(url: "https://p.supabase.co", publishableKey: "k",
                                   transport: MockTransport { _ in throw URLError(.notConnectedToInternet) })
        do { _ = try await down.signIn(email: "a@b.c", password: "x"); XCTFail() } catch {
            guard case .network? = error as? CloudSyncError else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try SupabaseAPI(url: "ftp://x", publishableKey: "k")) { e in
            guard case .invalidConfiguration? = e as? CloudSyncError else { return XCTFail("\(e)") }
            XCTAssertTrue(e.localizedDescription.hasPrefix("Bağlantı ayarı geçersiz"))
        }
        XCTAssertThrowsError(try SupabaseAPI(url: "https://x.supabase.co", publishableKey: " "))
        XCTAssertThrowsError(try SupabaseAPI(url: "mnpzjbpwsrscjrjnkkav.supabase.co", publishableKey: "k"))
        XCTAssertNoThrow(try SupabaseAPI(url: CloudDefaults.url, publishableKey: CloudDefaults.publishableKey))
    }

    func testPutRequestBuilding() async throws {
        let t = MockTransport { _ in .json(200, #"[{"ok":true,"rev":17,"body":{"note":"x"},"deleted":false}]"#) }
        let api = try SupabaseAPI(url: "https://p.supabase.co", publishableKey: "pk", session: session(), transport: t)
        let r = try await api.put(workspace: ws, key: "day:2026-10-09", body: j(#"{"note":"x"}"#), baseRev: 12, deleted: false,
                                  client: "mac", summary: "09.10.2026 notu: x")
        XCTAssertEqual(r, PutResult(ok: true, rev: 17, body: j(#"{"note":"x"}"#), deleted: false))
        let req = t.requests[0]
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.url.absoluteString, "https://p.supabase.co/rest/v1/rpc/envanter_put")
        XCTAssertEqual(req.headers["apikey"], "pk")
        XCTAssertEqual(req.headers["Authorization"], "Bearer A1")
        XCTAssertEqual(req.headers["Content-Type"], "application/json")
        XCTAssertEqual(req.jsonBody, .object([
            "p_workspace": .string(ws), "p_key": .string("day:2026-10-09"), "p_body": j(#"{"note":"x"}"#),
            "p_base_rev": .number(12), "p_deleted": .bool(false), "p_client": .string("mac"), "p_summary": .string("09.10.2026 notu: x"),
        ]))
        XCTAssertEqual(String(decoding: req.body!, as: UTF8.self).contains(#""p_base_rev":12"#), true)
        // Çakışma yanıtı (belge yok)
        t.handler = { _ in .json(200, #"[{"ok":false,"rev":0,"body":null,"deleted":false}]"#) }
        let c = try await api.put(workspace: ws, key: "items", body: j("[]"), baseRev: 3, deleted: false, client: "mac", summary: nil)
        XCTAssertEqual(c, PutResult(ok: false, rev: 0, body: nil, deleted: false))
        XCTAssertNil(t.requests[1].jsonBody?["p_summary"])
    }

    func testPullPagesThroughResults() async throws {
        let page1 = (1...CloudDefaults.pageSize).map { #"{"key":"day:2026-08-01","body":{"note":"\#($0)"},"rev":\#(100 + $0),"deleted":false,"updated_at":"2026-10-09T10:00:00+00:00","updated_by":"u"}"# }
        let t = MockTransport { req in
            let gt = req.query["rev"] ?? ""
            if gt == "gt.100" { return .json(200, "[" + page1.joined(separator: ",") + "]") }
            if gt == "gt.\(100 + CloudDefaults.pageSize)" {
                return .json(200, #"[{"key":"items","body":[],"rev":9000,"deleted":false},{"key":"day:2026-08-02","body":{},"rev":9001,"deleted":true}]"#)
            }
            return .json(500, "beklenmeyen")
        }
        let api = try SupabaseAPI(url: "https://p.supabase.co", publishableKey: "pk", session: session(), transport: t)
        let rows = try await api.pull(workspace: ws, since: 100)
        XCTAssertEqual(rows.count, CloudDefaults.pageSize + 2)
        XCTAssertEqual(rows.last, RemoteDoc(key: "day:2026-08-02", body: j("{}"), rev: 9001, deleted: true))
        XCTAssertEqual(rows.first?.updatedBy, "u")
        XCTAssertEqual(t.requests.count, 2)
        let q = t.requests[0].query
        XCTAssertEqual(t.requests[0].method, "GET")
        XCTAssertEqual(t.requests[0].url.path, "/rest/v1/envanter_docs")
        XCTAssertEqual(q, ["workspace_id": "eq.\(ws)", "rev": "gt.100", "order": "rev.asc",
                           "select": "key,body,rev,deleted,updated_at,updated_by", "limit": "500"])
        XCTAssertEqual(t.requests[0].headers["Authorization"], "Bearer A1")
        XCTAssertNil(t.requests[0].body)
    }

    func testTokenRefreshOn401ThenRetry() async throws {
        let t = MockTransport { req in
            if req.url.path == "/auth/v1/token" {
                return .json(200, #"{"access_token":"A2","refresh_token":"R2","expires_in":3600,"user":{"id":"u","email":"a@b.c"}}"#)
            }
            if req.headers["Authorization"] == "Bearer A1" { return .json(401, #"{"code":"PGRST303","message":"JWT expired"}"#) }
            return .json(200, #"[{"id":"w1","name":"Tuzla","role":"staff"}]"#)
        }
        let api = try SupabaseAPI(url: "https://p.supabase.co", publishableKey: "pk", session: session(), transport: t)
        let wss = try await api.myWorkspaces()
        XCTAssertEqual(wss, [CloudWorkspace(id: "w1", name: "Tuzla", role: "staff")])
        XCTAssertEqual(t.requests.map { $0.url.path }, ["/rest/v1/rpc/envanter_my_workspaces", "/auth/v1/token", "/rest/v1/rpc/envanter_my_workspaces"])
        let refreshReq = t.requests[1]
        XCTAssertEqual(refreshReq.url.query, "grant_type=refresh_token")
        XCTAssertEqual(refreshReq.jsonBody, j(#"{"refresh_token":"R1"}"#))
        XCTAssertEqual(refreshReq.headers["apikey"], "pk")
        XCTAssertEqual(t.requests[2].headers["Authorization"], "Bearer A2")
        XCTAssertEqual(t.requests[0].jsonBody, j("{}"))
        let s = await api.currentSession
        XCTAssertEqual(s?.refreshToken, "R2")
        // Motor yenilenen anahtarları duruma yazar
        var st = SyncState()
        st.store(s)
        XCTAssertEqual(st.accessToken, "A2")
        XCTAssertEqual(st.refreshToken, "R2")
    }

    func testRefreshFailureMeansSignInAgain() async throws {
        let t = MockTransport { req in
            if req.url.path == "/auth/v1/token" { return .json(400, #"{"error_code":"refresh_token_not_found","msg":"Invalid Refresh Token"}"#) }
            return .json(401, #"{"code":"PGRST303","message":"JWT expired"}"#)
        }
        let api = try SupabaseAPI(url: "https://p.supabase.co", publishableKey: "pk", session: session(), transport: t)
        do { _ = try await api.myWorkspaces(); XCTFail() } catch {
            XCTAssertEqual(error as? CloudSyncError, .sessionExpired)
            XCTAssertTrue(CloudSyncError.sessionExpired.requiresSignIn)
        }
        let s = await api.currentSession
        XCTAssertNil(s)
        // Oturum yoksa istek gönderilmez
        do { _ = try await api.pull(workspace: ws, since: 0); XCTFail() } catch { XCTAssertEqual(error as? CloudSyncError, .sessionExpired) }
        XCTAssertEqual(t.requests.count, 2)
    }

    func testProactiveRefreshBeforeExpiry() async throws {
        let t = MockTransport { req in
            if req.url.path == "/auth/v1/token" { return .json(200, #"{"access_token":"A2","refresh_token":"R2","expires_in":3600}"#) }
            return .json(200, "[]")
        }
        let api = try SupabaseAPI(url: "https://p.supabase.co", publishableKey: "pk",
                                  session: session(expires: Date().addingTimeInterval(20)), transport: t)
        _ = try await api.pull(workspace: ws, since: 0)
        XCTAssertEqual(t.requests.map { $0.url.path }, ["/auth/v1/token", "/rest/v1/envanter_docs"])
        XCTAssertEqual(t.requests[1].headers["Authorization"], "Bearer A2")
        let s = await api.currentSession
        XCTAssertEqual(s?.email, "a@b.c")    // yenileme yanıtında kullanıcı yoksa e-posta korunur
    }

    func testServerErrorMapping() async throws {
        let cases: [(Int, String, CloudSyncError)] = [
            (403, #"{"code":"42501","details":null,"hint":null,"message":"Personel (staff) yalnızca gün kayıtlarını (sayım, satış, vardiya, not) değiştirebilir."}"#,
             .forbidden("Personel (staff) yalnızca gün kayıtlarını (sayım, satış, vardiya, not) değiştirebilir.")),
            (404, #"{"code":"PGRST202","message":"Could not find the function public.envanter_put"}"#, .notProvisioned),
            (404, #"{"code":"PGRST205","message":"Could not find the table 'public.envanter_docs'"}"#, .notProvisioned),
            (400, #"{"code":"22023","message":"Geçersiz belge anahtarı: \"x\"."}"#, .invalidRequest("Geçersiz belge anahtarı: \"x\".")),
            (502, "Bad gateway", .server(status: 502, message: "Bad gateway")),
        ]
        for (status, body, expected) in cases {
            let api = try SupabaseAPI(url: "https://p.supabase.co", publishableKey: "pk", session: session(),
                                      transport: MockTransport { _ in .json(status, body) })
            do {
                _ = try await api.put(workspace: ws, key: "items", body: j("[]"), baseRev: 0, deleted: false, client: "mac", summary: nil)
                XCTFail("hata bekleniyordu")
            } catch {
                XCTAssertEqual(error as? CloudSyncError, expected, body)
            }
        }
    }

    func testWorkspaceRPCs() async throws {
        let t = MockTransport { req in
            switch req.url.path {
            case "/rest/v1/rpc/envanter_create_workspace": return .json(200, #""9b2c7d2e-0000-4000-8000-000000000001""#)
            case "/rest/v1/rpc/envanter_invite": return .json(200, #""invited""#)
            case "/rest/v1/envanter_activity": return .json(200, #"[{"id":5,"email":"a@b.c","at":"2026-10-09T10:00:00+00:00","client":"mac","key":"items","summary":"Stok kalemleri: Patates eklendi"}]"#)
            default: return .json(404, "{}")
            }
        }
        let api = try SupabaseAPI(url: "https://p.supabase.co", publishableKey: "pk", session: session(), transport: t)
        let id = try await api.createWorkspace(name: "Burger Yiyelim · Tuzla Marina")
        XCTAssertEqual(id, "9b2c7d2e-0000-4000-8000-000000000001")
        XCTAssertEqual(t.requests[0].jsonBody, j(#"{"p_name":"Burger Yiyelim · Tuzla Marina"}"#))
        let inv = try await api.invite(workspace: ws, email: "personel@ornek.com", role: "staff")
        XCTAssertEqual(inv, "invited")
        XCTAssertEqual(t.requests[1].jsonBody, j(#"{"p_workspace":"\#(ws)","p_email":"personel@ornek.com","p_role":"staff"}"#))
        let act = try await api.activity(workspace: ws, limit: 10)
        XCTAssertEqual(act.first?.summary, "Stok kalemleri: Patates eklendi")
        XCTAssertEqual(t.requests[2].query["order"], "id.desc")
        XCTAssertEqual(t.requests[2].query["limit"], "10")
    }

    func testEngineStoresRefreshedSession() async throws {
        let (_, a, _) = try await connectedPair()
        XCTAssertEqual(a.state.accessToken, "access-patron")
        XCTAssertEqual(a.state.refreshToken, "refresh-patron")
        XCTAssertNotNil(a.state.lastSyncAt)
    }
}

extension CloudSyncTests {
    func testAssembleRemoteAndLogout() async throws {
        let rows = [
            RemoteDoc(key: "settings", body: j(#"{"branchName":"Bulut"}"#), rev: 1),
            RemoteDoc(key: "day:2026-08-01", body: j(#"{"note":"bulut notu"}"#), rev: 2),
            RemoteDoc(key: "day:2026-08-02", body: j("{}"), rev: 3, deleted: true),
            RemoteDoc(key: "bilinmeyen", body: j("{}"), rev: 4),
        ]
        let d = CloudSyncEngine.assembleRemote(rows)
        XCTAssertEqual(d.settings.branchName, "Bulut")
        XCTAssertEqual(Array(d.days.keys), ["2026-08-01"])
        XCTAssertEqual(d.items, [])

        let t = MockTransport { _ in .json(204, "") }
        let api = try SupabaseAPI(url: "https://p.supabase.co", publishableKey: "pk",
                                  session: AuthSession(accessToken: "A1", refreshToken: "R1"), transport: t)
        await api.logout()
        XCTAssertEqual(t.requests.first?.url.absoluteString, "https://p.supabase.co/auth/v1/logout")
        XCTAssertEqual(t.requests.first?.headers["Authorization"], "Bearer A1")
        let s = await api.currentSession
        XCTAssertNil(s)
        await api.logout()                      // oturum yoksa istek gönderilmez
        XCTAssertEqual(t.requests.count, 1)
    }

    func testProgressIsReported() async throws {
        let (_, a, _) = try await connectedPair()
        a.edit { d in
            d.days["2026-09-01"] = DayRecord(date: "2026-09-01", note: "1")
            d.days["2026-09-02"] = DayRecord(date: "2026-09-02", note: "2")
        }
        final class Box: @unchecked Sendable { var calls: [(Int, Int)] = []; let lock = NSLock() }
        let box = Box()
        var st = a.state
        _ = try await CloudSyncEngine.syncOnce(local: a.data, state: &st, api: a.api) { done, total in
            box.lock.lock(); box.calls.append((done, total)); box.lock.unlock()
        }
        XCTAssertEqual(box.calls.map { $0.0 }, [0, 1, 2])
        XCTAssertEqual(box.calls.map { $0.1 }, [2, 2, 2])
    }
}
