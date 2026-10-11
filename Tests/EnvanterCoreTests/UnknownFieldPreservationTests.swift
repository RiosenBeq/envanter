import XCTest
@testable import EnvanterCore

/// Bulutta Mac'in bilmediği alanların korunması (docs/SYNC.md §1): eski sürümlerin maliyet, fiyat, ücret ve vardiya
/// alanları artık "bilinmeyen" alandır ve Mac bir belgeyi değiştirirken kaybolmamalıdır (eski Mac'ler onları okur).
/// Ayrıca eski sayan adlarının (settings.staff) eşitlemede ekibe taşınması.
final class UnknownFieldPreservationTests: XCTestCase {
    let ws = "22222222-2222-2222-2222-222222222222"

    private func connectedPair(staff: Bool = false) async throws -> (FakeServer, SimClient, SimClient) {
        let server = FakeServer()
        server.addWorkspace(ws, name: "Tuzla Marina", owner: "patron")
        server.addMember(ws, user: "personel", role: staff ? CloudRole.staff : CloudRole.manager)
        let a = SimClient(data: DemoData.make(endingAt: "2026-08-31", days: 6), api: FakeAPI(server: server, user: "patron"), workspace: ws)
        try await a.connect()
        let o1 = try await a.sync()
        XCTAssertNil(o1.error)
        let b = SimClient(data: AppData.seeded(), api: FakeAPI(server: server, user: "personel"), workspace: ws,
                          role: staff ? CloudRole.staff : CloudRole.manager)
        try await b.connect()
        let o2 = try await b.sync()
        XCTAssertNil(o2.error)
        XCTAssertSameDocs(a.data, b.data)
        return (server, a, b)
    }

    /// Eski bir Mac'in yazdığı gün: sayım yok, yalnızca vardiya ve diğer personel gideri
    private let shifts = j(#"{"e1":{"hours":9},"e8":{"worked":true,"extra":100}}"#)

    // MARK: - Günler

    /// P1: Mac için boş olan (yalnızca vardiyası olan) güne sayım eklenince vardiyalar korunur
    func testCountOnShiftsOnlyDayKeepsShifts() async throws {
        let (server, a, _) = try await connectedPair()
        let date = "2026-09-05", key = DocKey.day(date)
        server.write(ws: ws, user: "patron", key: key,
                     body: .object(["date": .string(date), "entries": .object([:]), "sales": .array([]), "shifts": shifts,
                                    "otherLabor": .number(500)]))
        let pulled = try await a.sync()
        XCTAssertNil(a.data.days[date], "Mac için boş gün")
        XCTAssertEqual(pulled.pushed, [])
        XCTAssertEqual(a.state.dirty, [])
        XCTAssertFalse(CloudSyncEngine.divergentKeys(local: a.data, state: a.state).contains(key), "yalnızca çekmek göndermeye yol açmaz")

        a.edit { $0.days[date, default: DayRecord(date: date)].entries["g90"] = DayEntry(closing: 90) }
        let out = try await a.sync()
        XCTAssertEqual(out.pushed, [key])
        let stored = try XCTUnwrap(server.doc(ws, key))
        XCTAssertFalse(stored.deleted)
        XCTAssertEqual(stored.body["shifts"], shifts)
        XCTAssertEqual(stored.body["otherLabor"]?.doubleValue, 500)
        XCTAssertEqual(stored.body["entries"]?["g90"]?["closing"]?.doubleValue, 90)
        XCTAssertEqual(server.activity.last?.summary, "05.09.2026 sayımı: 90 Gr kapanış 90")
    }

    /// P2: vardiyası olan günün tüm sayımı silinince belge silinmez; bilinen alanları temizlenmiş hali yazılır
    func testClearingDayWithShiftsKeepsDocument() async throws {
        let (server, a, b) = try await connectedPair()
        let date = "2026-09-06", key = DocKey.day(date)
        server.write(ws: ws, user: "patron", key: key,
                     body: .object(["date": .string(date), "entries": j(#"{"g90":{"closing":5}}"#), "sales": .array([]),
                                    "note": .string("eski not"), "shifts": shifts]))
        try await a.sync()
        XCTAssertEqual(a.data.days[date]?.entries["g90"]?.closing, 5)
        a.edit { $0.days[date] = nil }
        XCTAssertEqual(a.state.dirty, [key])
        let out = try await a.sync()
        XCTAssertNil(out.error)
        XCTAssertEqual(out.pushed, [key])
        let stored = try XCTUnwrap(server.doc(ws, key))
        XCTAssertFalse(stored.deleted, "eski sürümün vardiyaları silinmez")
        XCTAssertEqual(stored.body["shifts"], shifts)
        XCTAssertEqual(stored.body["entries"], .object([:]))
        XCTAssertNil(stored.body["note"])
        XCTAssertEqual(server.activity.last?.summary, "06.09.2026 sayımı: 90 Gr kapanış silindi; 06.09.2026 notu silindi")
        XCTAssertEqual(a.state.dirty, [])
        XCTAssertEqual(a.state.base[key]?.body, stored.body)
        // Sonraki turlarda yeniden gönderilmez; diğer Mac'te gün boşalır
        let o3 = try await a.sync()
        XCTAssertEqual(o3.pushed, [])
        try await b.sync()
        XCTAssertNil(b.data.days[date])
        XCTAssertSameDocs(a.data, b.data)
    }

    /// Bilinmeyen alanı olmayan gün boşalınca eskisi gibi silinir
    func testClearingPlainDayDeletesDocument() async throws {
        let (server, a, _) = try await connectedPair()
        let date = "2026-09-08", key = DocKey.day(date)
        server.write(ws: ws, user: "patron", key: key, body: j(#"{"entries":{"g90":{"closing":5}},"sales":[],"shifts":{},"otherLabor":null}"#))
        try await a.sync()
        a.edit { $0.days[date] = nil }
        let o4 = try await a.sync()
        XCTAssertEqual(o4.pushed, [key])
        XCTAssertEqual(server.doc(ws, key)?.deleted, true)
        XCTAssertEqual(server.activity.last?.summary, "08.09.2026 günü silindi")
    }

    /// P4: Mac için boş günde yapılıp geri alınan değişiklik buluttaki belgeye dokunmaz
    func testTouchThenRevertOnShiftsOnlyDayWritesNothing() async throws {
        let (server, a, _) = try await connectedPair()
        let date = "2026-09-07", key = DocKey.day(date)
        let raw = JSONValue.object(["date": .string(date), "entries": .object([:]), "sales": .array([]), "shifts": shifts])
        server.write(ws: ws, user: "patron", key: key, body: raw)
        try await a.sync()
        a.edit { $0.days[date, default: DayRecord(date: date)].entries["g90"] = DayEntry(closing: 1) }
        a.edit { $0.days[date] = nil }
        XCTAssertEqual(a.state.dirty, [key])
        let puts = server.putCount
        let out = try await a.sync()
        XCTAssertNil(out.error)
        XCTAssertEqual(out.pushed, [])
        XCTAssertEqual(server.putCount, puts)
        XCTAssertEqual(a.state.dirty, [])
        XCTAssertEqual(server.doc(ws, key)?.body, raw)
        XCTAssertEqual(server.doc(ws, key)?.deleted, false)
    }

    /// Satış satırlarının eski tutarı (kodla eşlenir) ve günün ileriki sürüm alanları korunur
    func testSalesAmountsAndFutureDayFieldsSurvive() async throws {
        let (server, a, _) = try await connectedPair()
        let date = "2026-09-09", key = DocKey.day(date)
        server.write(ws: ws, user: "patron", key: key, body: j(#"""
            {"entries":{},"sales":[{"code":"11100","name":"MEDIUM BURGER","qty":10,"amount":1500}],"futureField":{"x":1}}
            """#))
        try await a.sync()
        a.edit { $0.days[date]?.entries["g90"] = DayEntry(closing: 3) }
        try await a.sync()
        let stored = try XCTUnwrap(server.doc(ws, key)?.body)
        XCTAssertEqual(stored["sales"]?.arrayValue?.first?["amount"]?.doubleValue, 1500)
        XCTAssertEqual(stored["futureField"], j(#"{"x":1}"#))
        XCTAssertEqual(stored["entries"]?["g90"]?["closing"]?.doubleValue, 3)
    }

    func testForeignContentDetection() {
        XCTAssertTrue(DocCodec.hasForeignContent(j(#"{"entries":{},"shifts":{"e1":{"hours":1}}}"#)))
        XCTAssertTrue(DocCodec.hasForeignContent(j(#"{"otherLabor":0}"#)))
        XCTAssertTrue(DocCodec.hasForeignContent(j(#"{"futureField":false}"#)))
        XCTAssertFalse(DocCodec.hasForeignContent(j(#"{"entries":{"g90":{"closing":1}},"note":"x","locked":true}"#)))
        XCTAssertFalse(DocCodec.hasForeignContent(j(#"{"shifts":{},"otherLabor":null,"extra":[]}"#)))
        XCTAssertFalse(DocCodec.hasForeignContent(j("[1]")))
        // Mac'in yazdığı her gün alanı "bilinen" sayılır
        let full = DayRecord(date: "2026-08-01", entries: ["g90": DayEntry(closing: 1)], sales: [SaleLine(code: "1", name: "x", qty: 1)],
                             salesSource: "s", salesPeriod: "p", salesImportedAt: Date(timeIntervalSince1970: 0),
                             legacySold: ["g90": 1], legacyWaste: ["g90": 1], importedFrom: "f", note: "n", countedBy: "c", locked: true)
        let keys = Set((try? JSONCoding.value(full))?.objectValue?.keys ?? [:].keys)
        XCTAssertEqual(keys, DocCodec.knownDayKeys)
        // Çözülmüş taban: Mac için boş gün de gövde olarak döner (normalize nil döner)
        XCTAssertNil(DocCodec.normalize(key: "day:2026-08-01", body: j(#"{"shifts":{"e1":{"hours":1}}}"#)))
        XCTAssertEqual(DocCodec.decoded(key: "day:2026-08-01", body: j(#"{"shifts":{"e1":{"hours":1}}}"#)),
                       DocCodec.emptyDayBody("2026-08-01"))
        XCTAssertEqual(DocCodec.decoded(key: "items", body: j("[]")), DocCodec.normalize(key: "items", body: j("[]")))
        XCTAssertNil(DocCodec.decoded(key: "day:2026-08-01", body: nil))
    }

    // MARK: - Tanım belgeleri

    /// P3: sipariş teslim alınırken satırların eski birim fiyatı (değişmeyen satırlarınki de) korunur
    func testReceivingOrderKeepsOldUnitPrices() async throws {
        let (server, a, _) = try await connectedPair()
        var orders = try XCTUnwrap(server.doc(ws, DocKey.orders)?.body.arrayValue)
        orders.append(j(#"""
            {"id":"o-eski","date":"2026-08-30","supplier":"Et","status":"open","note":"eski sürüm",
             "lines":[{"itemID":"g90","qty":100,"unitPrice":38},{"itemID":"g130","qty":50,"unitPrice":62,"lineNote":"web"}]}
            """#))
        server.write(ws: ws, user: "patron", key: DocKey.orders, body: .array(orders))
        try await a.sync()
        XCTAssertEqual(a.data.purchaseOrders.last?.lines, [OrderLine(itemID: "g90", qty: 100), OrderLine(itemID: "g130", qty: 50)])

        var data = a.data
        XCTAssertEqual(try Purchasing.receive(orderID: "o-eski", on: "2026-08-31", quantities: ["g90": 90], data: &data), 2)
        a.edit { $0 = data }
        XCTAssertEqual(a.state.dirty, [DocKey.orders, DocKey.day("2026-08-31")])
        let o5 = try await a.sync()
        XCTAssertNil(o5.error)
        let stored = try XCTUnwrap(server.doc(ws, DocKey.orders)?.body.arrayValue?.first { $0["id"]?.stringValue == "o-eski" })
        let lines = try XCTUnwrap(stored["lines"]?.arrayValue)
        XCTAssertEqual(lines.map { $0["unitPrice"]?.doubleValue }, [38, 62])
        XCTAssertEqual(lines.map { $0["received"]?.doubleValue }, [90, 50])
        XCTAssertEqual(lines[1]["lineNote"]?.stringValue, "web")
        XCTAssertEqual(stored["status"]?.stringValue, "received")
        XCTAssertEqual(stored["note"]?.stringValue, "eski sürüm")
    }

    /// Ortak merge3 sözleşmesi değişmez: kimliksiz (yalnızca itemID'li) dizilerde yerel kazanır; "itemID" yalnızca
    /// bilinmeyen alanları korurken kullanılır
    func testSharedMerge3ContractIgnoresItemID() {
        let base = j(#"[{"itemID":"a","qty":1},{"itemID":"b","qty":2}]"#)
        let local = j(#"[{"itemID":"a","qty":5},{"itemID":"b","qty":2}]"#)
        let remote = j(#"[{"itemID":"a","qty":1,"unitPrice":3},{"itemID":"b","qty":2,"unitPrice":4}]"#)
        XCTAssertEqual(JSONMerge.merge3(base: base, local: local, remote: remote), local)
        XCTAssertEqual(CloudSyncEngine.bodyPreservingUnknownFields(local: local, baseRaw: remote, baseNormalized: base),
                       j(#"[{"itemID":"a","qty":5,"unitPrice":3},{"itemID":"b","qty":2,"unitPrice":4}]"#))
    }

    /// Kalem düzenlenince bütün kalemlerin eski birim maliyeti ve fiyat geçmişi gönderilen gövdede kalır
    func testItemEditKeepsUnitCostAndHistory() async throws {
        let (server, a, b) = try await connectedPair()
        var items = try XCTUnwrap(server.doc(ws, DocKey.items)?.body.arrayValue)
        for i in items.indices {
            var o = try XCTUnwrap(items[i].objectValue)
            o["unitCost"] = .number(Double(10 + i))
            o["costHistory"] = j(#"[{"date":null,"cost":9},{"date":"2026-08-01","cost":\#(10 + i)}]"#)
            items[i] = .object(o)
        }
        server.write(ws: ws, user: "patron", key: DocKey.items, body: .array(items))
        let pulled = try await a.sync()
        XCTAssertEqual(pulled.pushed, [])
        XCTAssertSameDocs(a.data, b.data)

        let (name1, old1, name2) = (a.data.items[1].name, try XCTUnwrap(a.data.items[1].minStock), a.data.items[2].name)
        a.edit { $0.items[1].minStock = 77; $0.items[2].name = "Yeni Ad" }
        let o6 = try await a.sync()
        XCTAssertEqual(o6.pushed, [DocKey.items])
        let stored = try XCTUnwrap(server.doc(ws, DocKey.items)?.body.arrayValue)
        XCTAssertEqual(stored.count, items.count)
        for (i, it) in stored.enumerated() {
            XCTAssertEqual(it["unitCost"]?.doubleValue, Double(10 + i), "\(i)")
            XCTAssertEqual(it["costHistory"]?.arrayValue?.count, 2, "\(i)")
        }
        XCTAssertEqual(stored[1]["minStock"]?.doubleValue, 77)
        XCTAssertEqual(stored[2]["name"]?.stringValue, "Yeni Ad")
        XCTAssertEqual(server.activity.last?.summary,
                       "Stok kalemleri: \(name1) kritik stok \(Fmt.number(old1, maxFraction: 2)) → 77, \(name2) → Yeni Ad")
    }

    /// Ekip üyesi düzenlenince eski ücret alanları, ayar düzenlenince eski hedefler korunur
    func testTeamAndSettingsEditsKeepPayAndTargets() async throws {
        let (server, a, _) = try await connectedPair()
        var team = try XCTUnwrap(server.doc(ws, DocKey.employees)?.body.arrayValue)
        var first = try XCTUnwrap(team[0].objectValue)
        first["payType"] = .string("monthly"); first["rate"] = .number(85_000); first["costFactor"] = .number(1.2)
        first["payHistory"] = j(#"[{"from":null,"payType":"monthly","rate":80000,"costFactor":1.2}]"#)
        team[0] = .object(first)
        server.write(ws: ws, user: "patron", key: DocKey.employees, body: .array(team))
        var settings = try XCTUnwrap(server.doc(ws, DocKey.settings)?.body.objectValue)
        settings["targetFoodCostPct"] = .number(0.3); settings["priceAlertPct"] = .number(0.05)
        server.write(ws: ws, user: "patron", key: DocKey.settings, body: .object(settings))
        try await a.sync()

        a.edit { $0.employees[0].role = "Şef"; $0.employees[0].phone = "0500"; $0.settings.orderCoverDays = 4 }
        let o7 = try await a.sync()
        XCTAssertEqual(Set(o7.pushed), [DocKey.employees, DocKey.settings])
        let e0 = try XCTUnwrap(server.doc(ws, DocKey.employees)?.body.arrayValue?.first)
        XCTAssertEqual(e0["role"]?.stringValue, "Şef")
        XCTAssertEqual(e0["phone"]?.stringValue, "0500")
        XCTAssertEqual(e0["rate"]?.doubleValue, 85_000)
        XCTAssertEqual(e0["costFactor"]?.doubleValue, 1.2)
        XCTAssertEqual(e0["payHistory"]?.arrayValue?.count, 1)
        let st = try XCTUnwrap(server.doc(ws, DocKey.settings)?.body)
        XCTAssertEqual(st["orderCoverDays"]?.doubleValue, 4)
        XCTAssertEqual(st["targetFoodCostPct"]?.doubleValue, 0.3)
        XCTAssertEqual(st["priceAlertPct"]?.doubleValue, 0.05)
    }

    // MARK: - Eski sayan adlarının ekibe taşınması (eşitlemede)

    /// Çekmeden sonra taşınır: web panelinde (ya da eski bir Mac'te) eklenmiş adlar da ekibe girer; ayar ve ekip aynı
    /// turda gönderilir, eski ayar alanları korunur
    func testMigrationRunsAfterPullAndPushes() async throws {
        let (server, a, b) = try await connectedPair()
        var settings = try XCTUnwrap(server.doc(ws, DocKey.settings)?.body.objectValue)
        settings["staff"] = j(#"["Murat A.","Ayşe Yılmaz","Yeni Kişi"]"#)
        settings["priceAlertPct"] = .number(0.05)
        server.write(ws: ws, user: "patron", key: DocKey.settings, body: .object(settings))
        let before = a.data.employees

        let out = try await a.sync()
        XCTAssertNil(out.error)
        XCTAssertTrue(out.appliedRemote.isSuperset(of: [DocKey.settings, DocKey.employees]))
        XCTAssertEqual(out.pushed, [DocKey.employees, DocKey.settings], "ekip ayardan önce gönderilir")
        XCTAssertTrue(a.data.settings.staff.isEmpty)
        // "Murat A." zaten üye; diğerleri belirlenimci kimlikle eklenir
        XCTAssertEqual(a.data.employees, before + [Employee(id: "staff-ayse-yilmaz", name: "Ayşe Yılmaz"),
                                                   Employee(id: "staff-yeni-kisi", name: "Yeni Kişi")])
        XCTAssertEqual(server.doc(ws, DocKey.settings)?.body["staff"], .array([]))
        XCTAssertEqual(server.doc(ws, DocKey.settings)?.body["priceAlertPct"]?.doubleValue, 0.05)
        XCTAssertTrue(server.activity.contains { $0.summary == "Ayarlar: sayım yapanlar Ekip'e taşındı" })
        XCTAssertTrue(server.activity.contains { $0.summary == "Ekip: Ayşe Yılmaz eklendi, Yeni Kişi eklendi" })

        // Sonraki turlarda yeniden taşınmaz; diğer Mac ekibi alır
        let o8 = try await a.sync()
        XCTAssertEqual(o8.pushed, [])
        let ob = try await b.sync()
        XCTAssertEqual(ob.pushed, [])
        XCTAssertSameDocs(a.data, b.data)
    }

    /// Mac ve web aynı anda taşısa da ekip belgesi kimliğe göre birleşir (aynı üye iki kez eklenmez)
    func testConcurrentMigrationWithWebMergesByID() async throws {
        let (server, a, _) = try await connectedPair()
        var settings = try XCTUnwrap(server.doc(ws, DocKey.settings)?.body.objectValue)
        settings["staff"] = j(#"["Ali","Veli"]"#)
        server.write(ws: ws, user: "patron", key: DocKey.settings, body: .object(settings))
        let team = a.data.employees
        var injected = false
        server.beforePut = { key in
            guard !injected, key == DocKey.settings || key == DocKey.employees else { return }
            injected = true
            // Web paneli aynı anda taşıdı (aynı kurallar) ve bir üyenin görevini değiştirdi
            var webTeam = team + [Employee(id: "staff-ali", name: "Ali"), Employee(id: "staff-veli", name: "Veli")]
            webTeam[0].role = "Bölge Müdürü"
            var webSettings = settings
            webSettings["staff"] = .array([])
            server.write(ws: self.ws, user: "personel", key: DocKey.employees, body: try? JSONCoding.value(webTeam))
            server.write(ws: self.ws, user: "personel", key: DocKey.settings, body: .object(webSettings))
        }
        let out = try await a.sync()
        XCTAssertTrue(injected)
        XCTAssertNil(out.error)
        let stored = Lenient.employees(try XCTUnwrap(server.doc(ws, DocKey.employees)?.body)) ?? []
        XCTAssertEqual(stored.map { $0.id }, team.map { $0.id } + ["staff-ali", "staff-veli"])
        XCTAssertEqual(stored[0].role, "Bölge Müdürü")
        XCTAssertEqual(a.data.employees, stored)
        XCTAssertEqual(server.doc(ws, DocKey.settings)?.body["staff"], .array([]))
        XCTAssertEqual(a.state.dirty, [])
    }

    /// Açılışta (kaydedilemeyen "dirty" aranırken) çözülemeyen sunucu belgesi ayrışmış sayılmaz; kullanıcı
    /// değiştirmedikçe üzerine yazılmaz ve Mac'in bilmediği alanlar kalır
    func testUndecodableServerDocIsNotDivergentAtLaunch() async throws {
        let (server, a, _) = try await connectedPair()
        var settings = try XCTUnwrap(server.doc(ws, DocKey.settings)?.body.objectValue)
        settings["orderLookbackDays"] = .number(1e300)                       // Int'e sığmaz: belge çözülemez
        settings["futureOnly"] = .string("web-ileriki-surum")
        server.write(ws: ws, user: "patron", key: DocKey.settings, body: .object(settings))
        let serverBody = try XCTUnwrap(server.doc(ws, DocKey.settings)?.body)
        _ = try await a.sync()
        XCTAssertFalse(CloudSyncEngine.divergentKeys(local: a.data, state: a.state).contains(DocKey.settings))
        a.state.dirty.formUnion(CloudSyncEngine.divergentKeys(local: a.data, state: a.state))
        let out = try await a.sync()
        XCTAssertEqual(out.pushed, [])
        XCTAssertEqual(server.doc(ws, DocKey.settings)?.body, serverBody)
    }

    /// Sunucudaki ayar belgesi çözülemiyorsa beklenir: eski yerel liste o belgenin üzerine yazılmaz
    func testMigrationWaitsWhenServerSettingsUndecodable() async throws {
        let (server, a, _) = try await connectedPair()
        var settings = try XCTUnwrap(server.doc(ws, DocKey.settings)?.body.objectValue)
        settings["orderLookbackDays"] = .number(1e300)                       // Int'e sığmaz: belge çözülemez
        settings["futureOnly"] = .string("web-ileriki-surum")                 // Mac'in bilmediği alan
        server.write(ws: ws, user: "patron", key: DocKey.settings, body: .object(settings))
        let serverBody = try XCTUnwrap(server.doc(ws, DocKey.settings)?.body)
        a.data.settings.staff = ["Veli"]                                      // kaydedilmiş ama gönderilmemiş eski liste
        let team = a.data.employees
        let out = try await a.sync()
        XCTAssertEqual(out.undecodable, [DocKey.settings])
        XCTAssertEqual(out.pushed, [])
        XCTAssertEqual(a.data.settings.staff, ["Veli"])
        XCTAssertEqual(a.data.employees, team)
        XCTAssertEqual(a.state.dirty, [])

        // Sonraki turlarda belge yeniden çekilmez; bekleme yine sürer (sunucudaki belge ezilmez, bilinmeyen alan düşmez)
        for round in 2...3 {
            let o = try await a.sync()
            XCTAssertNil(o.error)
            XCTAssertEqual(o.pushed, [], "tur \(round)")
            XCTAssertEqual(server.doc(ws, DocKey.settings)?.body, serverBody, "tur \(round)")
            XCTAssertEqual(a.data.settings.staff, ["Veli"])
            XCTAssertEqual(a.data.employees, team)
            XCTAssertEqual(a.state.dirty, [])
        }

        // Web belgeyi düzeltince taşıma yapılır; bilinmeyen alan korunur
        settings["orderLookbackDays"] = .number(21)
        settings["staff"] = j(#"["Ali"]"#)
        server.write(ws: ws, user: "patron", key: DocKey.settings, body: .object(settings))
        let fixed = try await a.sync()
        XCTAssertNil(fixed.error)
        XCTAssertEqual(fixed.undecodable, [])
        XCTAssertEqual(fixed.pushed, [DocKey.employees, DocKey.settings])
        XCTAssertEqual(a.data.employees, team + [Employee(id: "staff-ali", name: "Ali")])
        XCTAssertEqual(a.data.settings.orderLookbackDays, 21)
        XCTAssertEqual(server.doc(ws, DocKey.settings)?.body["staff"], .array([]))
        XCTAssertEqual(server.doc(ws, DocKey.settings)?.body["futureOnly"], .string("web-ileriki-surum"))
        XCTAssertEqual(a.state.dirty, [])
    }

    /// Taşıma turu yarıda kalırsa adlar kaybolmaz: ekip ayardan önce gönderilir; ekip gönderilemezse ayar (boşaltılmış
    /// liste) hiç gönderilmez, ayar gönderilemezse sonraki tur (yerel durum kaybolmuş olsa da) aynı kimliklerle tamamlar
    func testInterruptedMigrationKeepsLegacyNames() async throws {
        let (server, a, _) = try await connectedPair()
        let api = try XCTUnwrap(a.api as? FakeAPI)
        var settings = try XCTUnwrap(server.doc(ws, DocKey.settings)?.body.objectValue)
        settings["staff"] = j(#"["Ahmet"]"#)
        server.write(ws: ws, user: "patron", key: DocKey.settings, body: .object(settings))
        let team = a.data.employees
        let snapshot = (a.data, a.state)                                      // turdan önce diske yazılmış hal
        var order: [String] = []
        server.beforePut = { order.append($0) }

        // 1) Ekip yazılırken bağlantı koptu: ayar gönderilmez, ad sunucuda ayarda kalır; yerelde ekipte bekler
        api.failPut = { $0 == DocKey.employees ? CloudSyncError.network("bağlantı koptu") : nil }
        let o1 = try await a.sync()
        XCTAssertNotNil(o1.error)
        XCTAssertEqual(o1.pushed, [])
        XCTAssertEqual(order, [])
        XCTAssertEqual(server.doc(ws, DocKey.settings)?.body["staff"], j(#"["Ahmet"]"#))
        XCTAssertEqual(a.data.employees, team + [Employee(id: "staff-ahmet", name: "Ahmet")])
        XCTAssertTrue(a.state.dirty.isSuperset(of: [DocKey.settings, DocKey.employees]))

        // 2) Bu kez ekip gitti, ayar yazılırken koptu
        api.failPut = { $0 == DocKey.settings ? CloudSyncError.network("bağlantı koptu") : nil }
        let o2 = try await a.sync()
        XCTAssertNotNil(o2.error)
        XCTAssertEqual(o2.pushed, [DocKey.employees])
        XCTAssertEqual(order, [DocKey.employees])
        XCTAssertEqual(server.doc(ws, DocKey.settings)?.body["staff"], j(#"["Ahmet"]"#))

        // 3) Uygulama kapandı, turun durumu diske yazılamadı: eski hal yüklenir; ad tek kez ekipte, ayar boşalır
        api.failPut = nil
        (a.data, a.state) = snapshot
        order = []
        let o3 = try await a.sync()
        XCTAssertNil(o3.error)
        XCTAssertEqual(o3.pushed, [DocKey.settings])
        let stored = Lenient.employees(try XCTUnwrap(server.doc(ws, DocKey.employees)?.body)) ?? []
        XCTAssertEqual(stored.map(\.id), team.map(\.id) + ["staff-ahmet"])
        XCTAssertEqual(a.data.employees, stored)
        XCTAssertEqual(server.doc(ws, DocKey.settings)?.body["staff"], .array([]))
        XCTAssertEqual(a.data.settings.staff, [])
        XCTAssertEqual(a.state.dirty, [])
        XCTAssertTrue(Team.counterNames(a.data).contains("Ahmet"))
    }

    /// Ekip belgesi art arda değiştiği için gönderilemezse (çakışma sınırı) ayar da bekler: boşaltılmış liste sunucuya gitmez
    func testSettingsWaitsWhileTeamKeepsConflicting() async throws {
        let (server, a, _) = try await connectedPair()
        var settings = try XCTUnwrap(server.doc(ws, DocKey.settings)?.body.objectValue)
        settings["staff"] = j(#"["Ahmet"]"#)
        server.write(ws: ws, user: "patron", key: DocKey.settings, body: .object(settings))
        var webEdits = 0
        server.beforePut = { key in
            guard key == DocKey.employees,
                  var team = Lenient.employees(self.server_doc(server, DocKey.employees)) else { return }
            webEdits += 1
            team[0].note = "web düzenlemesi \(webEdits)"
            server.write(ws: self.ws, user: "personel", key: DocKey.employees, body: try? JSONCoding.value(team))
        }
        let o1 = try await a.sync()
        XCTAssertNotNil(o1.error)
        XCTAssertGreaterThan(webEdits, CloudDefaults.maxConflictRetries)
        XCTAssertFalse(o1.pushed.contains(DocKey.settings))
        XCTAssertEqual(server.doc(ws, DocKey.settings)?.body["staff"], j(#"["Ahmet"]"#), "ad sunucuda kalır")
        XCTAssertTrue(a.state.dirty.isSuperset(of: [DocKey.settings, DocKey.employees]))

        server.beforePut = nil
        let o2 = try await a.sync()
        XCTAssertNil(o2.error)
        XCTAssertEqual(o2.pushed, [DocKey.employees, DocKey.settings])
        let stored = Lenient.employees(try XCTUnwrap(server.doc(ws, DocKey.employees)?.body)) ?? []
        XCTAssertEqual(stored.last, Employee(id: "staff-ahmet", name: "Ahmet"))
        XCTAssertEqual(stored[0].note, "web düzenlemesi \(webEdits)", "web'deki düzenleme korunur")
        XCTAssertEqual(server.doc(ws, DocKey.settings)?.body["staff"], .array([]))
        XCTAssertEqual(a.state.dirty, [])
    }

    /// Taşıma sırasında eski bir istemci ayara yeni bir sayan adı eklerse (gönderimde çakışma) ad kaybolmaz: ekibe taşınır,
    /// ekip yeniden ayardan önce gönderilir
    func testNameAddedByOldClientDuringMigrationPushIsKept() async throws {
        let (server, a, b) = try await connectedPair()
        var settings = try XCTUnwrap(server.doc(ws, DocKey.settings)?.body.objectValue)
        settings["staff"] = j(#"["Ahmet"]"#)
        server.write(ws: ws, user: "patron", key: DocKey.settings, body: .object(settings))
        let team = a.data.employees
        var order: [String] = []
        var injected = false
        server.beforePut = { key in
            order.append(key)
            guard !injected, key == DocKey.settings else { return }
            injected = true
            var old = settings
            old["staff"] = j(#"["Ahmet","Mehmet"]"#)                       // eski web paneli: Sayan alanına yeni ad
            server.write(ws: self.ws, user: "personel", key: DocKey.settings, body: .object(old))
        }
        let out = try await a.sync()
        XCTAssertTrue(injected)
        XCTAssertNil(out.error)
        XCTAssertTrue(out.conflicts.contains(DocKey.settings))
        XCTAssertEqual(order, [DocKey.employees, DocKey.settings, DocKey.employees, DocKey.settings])
        XCTAssertEqual(out.pushed, [DocKey.employees, DocKey.settings])
        let expected = team + [Employee(id: "staff-ahmet", name: "Ahmet"), Employee(id: "staff-mehmet", name: "Mehmet")]
        XCTAssertEqual(Lenient.employees(try XCTUnwrap(server.doc(ws, DocKey.employees)?.body)), expected)
        XCTAssertEqual(a.data.employees, expected)
        XCTAssertEqual(server.doc(ws, DocKey.settings)?.body["staff"], .array([]))
        XCTAssertEqual(a.data.settings.staff, [])
        XCTAssertEqual(a.state.dirty, [])
        server.beforePut = nil
        let again = try await a.sync()
        XCTAssertEqual(again.pushed, [])
        _ = try await b.sync()
        XCTAssertSameDocs(a.data, b.data)
    }

    /// Ayar önceki turdan gönderilmeyi beklerken (yerelde boşaltılmış) eski bir istemci ad eklerse: çekmedeki birleştirme
    /// adı korur ve taşıma onu da ekibe alır
    func testNameAddedByOldClientBeforePendingSettingsPushIsKept() async throws {
        let (server, a, _) = try await connectedPair()
        let api = try XCTUnwrap(a.api as? FakeAPI)
        var settings = try XCTUnwrap(server.doc(ws, DocKey.settings)?.body.objectValue)
        settings["staff"] = j(#"["Ahmet"]"#)
        server.write(ws: ws, user: "patron", key: DocKey.settings, body: .object(settings))
        let team = a.data.employees
        api.failPut = { $0 == DocKey.settings ? CloudSyncError.network("bağlantı koptu") : nil }
        let o1 = try await a.sync()
        XCTAssertNotNil(o1.error)
        XCTAssertEqual(o1.pushed, [DocKey.employees])
        XCTAssertTrue(a.state.dirty.contains(DocKey.settings))
        XCTAssertEqual(a.data.settings.staff, [])

        // Eski web paneli Sayan alanına yeni ad yazdı
        settings["staff"] = j(#"["Ahmet","Mehmet"]"#)
        server.write(ws: ws, user: "personel", key: DocKey.settings, body: .object(settings))
        api.failPut = nil
        let o2 = try await a.sync()
        XCTAssertNil(o2.error)
        XCTAssertTrue(o2.conflicts.contains(DocKey.settings))
        XCTAssertEqual(o2.pushed, [DocKey.employees, DocKey.settings])
        let expected = team + [Employee(id: "staff-ahmet", name: "Ahmet"), Employee(id: "staff-mehmet", name: "Mehmet")]
        XCTAssertEqual(Lenient.employees(try XCTUnwrap(server.doc(ws, DocKey.employees)?.body)), expected)
        XCTAssertEqual(a.data.employees, expected)
        XCTAssertEqual(server.doc(ws, DocKey.settings)?.body["staff"], .array([]))
        XCTAssertEqual(a.state.dirty, [])
    }

    private func server_doc(_ server: FakeServer, _ key: String) -> JSONValue {
        server.doc(ws, key)?.body ?? .null
    }

    /// Personel hesabı ekip ve ayar yazamadığından taşımaz; okuma da taşımaz (eski adlar Sayan seçiminde görünür)
    func testStaffRoleDoesNotMigrate() async throws {
        let (server, _, b) = try await connectedPair(staff: true)
        var settings = try XCTUnwrap(server.doc(ws, DocKey.settings)?.body.objectValue)
        settings["staff"] = j(#"["Ali"]"#)
        server.write(ws: ws, user: "patron", key: DocKey.settings, body: .object(settings))
        let team = b.data.employees
        let out = try await b.sync()
        XCTAssertEqual(out.pushed, [])
        XCTAssertEqual(out.rejected, [:])
        XCTAssertEqual(b.data.settings.staff, ["Ali"])
        XCTAssertEqual(b.data.employees, team)
        XCTAssertEqual(b.state.dirty, [])
        XCTAssertEqual(Team.counterNames(b.data).last, "Ali")
    }
}
