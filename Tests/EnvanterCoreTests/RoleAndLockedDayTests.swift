import XCTest
@testable import EnvanterCore

/// Personel kuralları (kapatılmış gün — D1 —, tanım belgeleri), eşitlemede "sunucu kazanır", geri alma, çıkış /
/// yeniden giriş, şube değişimi, diske yazma sırası ve tutar girişi (Mac inceleme bulguları).
final class RoleAndLockedDayTests: XCTestCase {
    let ws = "22222222-2222-2222-2222-222222222222"
    /// DemoData son iki gün dışındaki günleri kapatır (6 gün: 26–29 Ağustos kapalı, 30–31 açık)
    let lockedDate = "2026-08-29"
    let today = "2026-08-31"

    private func makeServer(staff: Bool) -> (FakeServer, FakeAPI, FakeAPI) {
        let server = FakeServer()
        server.addWorkspace(ws, name: "Tuzla Marina", owner: "patron")
        server.addMember(ws, user: "personel", role: staff ? CloudRole.staff : CloudRole.manager)
        return (server, FakeAPI(server: server, user: "patron"), FakeAPI(server: server, user: "personel"))
    }

    /// A (patron) buluta yükler, B (personel ya da müdür; yeni kurulum) indirir
    private func connectedPair(staff: Bool, days: Int = 6) async throws -> (FakeServer, SimClient, SimClient) {
        let (server, apiA, apiB) = makeServer(staff: staff)
        let a = SimClient(data: DemoData.make(endingAt: today, days: days), api: apiA, workspace: ws)
        try await a.connect()
        let oa = try await a.sync()
        XCTAssertNil(oa.error)
        let b = SimClient(data: AppData.seeded(), api: apiB, workspace: ws, role: staff ? CloudRole.staff : CloudRole.manager)
        try await b.connect()
        let ob = try await b.sync()
        XCTAssertNil(ob.error)
        XCTAssertSameDocs(a.data, b.data)
        return (server, a, b)
    }

    /// AppStore.setData'daki rol denetimiyle değişiklik: reddedilirse veri ve "dirty" değişmez
    @discardableResult
    private func guardedEdit(_ c: SimClient, _ f: (inout AppData) -> Void) -> LocalChangeRefusal? {
        var d = c.data
        f(&d)
        if let r = CloudPermission.refusal(role: c.state.enforcedRole, old: c.data, new: d) { return r }
        c.edit { $0 = d }
        return nil
    }

    private func deleteItem(_ id: String, _ d: inout AppData) {
        d.items.removeAll { $0.id == id }
        for i in d.products.indices { d.products[i].amounts[id] = nil }
        for (k, var day) in d.days {
            day.entries[id] = nil
            d.days[k] = day.isEmpty ? nil : day
        }
    }

    // MARK: - Sunucu kuralı (FakeServer = SQL envanter_put)

    func testFakeServerEnforcesLockedDayLikeSQL() throws {
        let server = FakeServer()
        server.addWorkspace(ws, name: "Tuzla", owner: "patron")
        server.addMember(ws, user: "personel", role: CloudRole.staff)
        server.addMember(ws, user: "mudur", role: CloudRole.manager)
        let key = "day:2026-10-05"
        let lockedBody = j(#"{"locked":true,"entries":{"g90":{"closing":110}}}"#)
        let r = server.write(ws: ws, user: "mudur", key: key, body: lockedBody)
        XCTAssertTrue(r.ok)
        func staffPut(_ key: String, _ body: JSONValue, base: Int64, deleted: Bool = false) throws -> PutResult {
            try server.put(user: "personel", ws: ws, key: key, body: body, baseRev: base, deleted: deleted, client: "mac", summary: nil)
        }
        let attempts: [(String, JSONValue, Bool)] = [
            ("değiştirme", j(#"{"locked":true,"entries":{"g90":{"closing":5}}}"#), false),
            ("kilit açma", j(#"{"entries":{"g90":{"closing":110}}}"#), false),
            ("silme", j("{}"), true),
        ]
        let activityBefore = server.activity.count
        for (name, body, deleted) in attempts {
            XCTAssertThrowsError(try staffPut(key, body, base: r.rev, deleted: deleted), name) { e in
                XCTAssertEqual(e as? CloudSyncError, .forbidden(CloudPermission.lockedDayMessage), name)
            }
        }
        XCTAssertEqual(server.doc(ws, key)?.rev, r.rev)
        XCTAssertEqual(server.doc(ws, key)?.body, lockedBody)
        XCTAssertEqual(server.activity.count, activityBefore)
        // Eski taban: hata değil, kilitli gövdeyle olağan çakışma
        let stale = try staffPut(key, j(#"{"note":"x"}"#), base: r.rev - 1)
        XCTAssertFalse(stale.ok)
        XCTAssertEqual(stale.body?["locked"], .bool(true))
        // Aynı gövdeyi yeniden yazmak serbest
        XCTAssertTrue(try staffPut(key, lockedBody, base: r.rev).ok)
        // Açık günü kapatmak ve yeni kapalı gün eklemek serbest
        let open = server.write(ws: ws, user: "mudur", key: "day:2026-10-06", body: j(#"{"note":"açık"}"#))
        XCTAssertTrue(try staffPut("day:2026-10-06", j(#"{"note":"açık","locked":true}"#), base: open.rev).ok)
        XCTAssertTrue(try staffPut("day:2026-10-07", j(#"{"locked":true}"#), base: 0).ok)
        // Boolean olmayan "locked" kilit sayılmaz
        let odd = server.write(ws: ws, user: "mudur", key: "day:2026-10-08", body: j(#"{"locked":"evet"}"#))
        XCTAssertTrue(try staffPut("day:2026-10-08", j(#"{"note":"y"}"#), base: odd.rev).ok)
        // Müdür kilidi açar; sonra personel değiştirebilir
        let cur = try XCTUnwrap(server.doc(ws, key))
        let unlocked = try server.put(user: "mudur", ws: ws, key: key, body: j(#"{"entries":{"g90":{"closing":110}}}"#),
                                      baseRev: cur.rev, deleted: false, client: "web", summary: nil)
        XCTAssertTrue(unlocked.ok)
        XCTAssertTrue(try staffPut(key, j(#"{"entries":{"g90":{"closing":7}}}"#), base: unlocked.rev).ok)
    }

    // MARK: - D1 istemci: sunucu kazanır, yeniden denenmez, sonraki günler gönderilir

    func testStaffChangeToLockedDayRestoresServerVersionWithoutRetry() async throws {
        let (server, a, b) = try await connectedPair(staff: true)
        let key = DocKey.day(lockedDate), todayKey = DocKey.day(today)
        XCTAssertEqual(b.data.days[lockedDate]?.isLocked, true)
        let serverBefore = try XCTUnwrap(server.doc(ws, key))
        let serverNote = b.data.days[lockedDate]?.note
        // Kural dışı değişiklik (ör. eski sürümün "Kilidi Aç"ı): AppStore denetimi olmadan yapılmış
        b.edit { d in
            d.days[self.lockedDate]?.locked = nil
            d.days[self.lockedDate]?.note = "personel değiştirdi"
        }
        b.edit { $0.days[self.today]?.note = "bugünün notu" }
        XCTAssertEqual(b.state.dirty, [key, todayKey])
        let putsBefore = server.putCount
        let out = try await b.sync()
        XCTAssertNil(out.error)
        XCTAssertEqual(Array(out.rejected.keys), [key])
        XCTAssertEqual(out.rejected[key], CloudPermission.lockedDayMessage)
        XCTAssertEqual(out.pushed, [todayKey])                               // sonraki gün bekletilmez
        XCTAssertTrue(out.appliedRemote.contains(key))
        XCTAssertEqual(b.state.dirty, [])
        XCTAssertEqual(b.data.days[lockedDate]?.isLocked, true)             // sunucudaki hal geri geldi
        XCTAssertEqual(b.data.days[lockedDate]?.note, serverNote)
        XCTAssertEqual(DocCodec.body(for: key, in: b.data), DocCodec.normalize(key: key, body: serverBefore.body))
        XCTAssertEqual(server.doc(ws, key)?.rev, serverBefore.rev)
        XCTAssertEqual(server.doc(ws, todayKey)?.body["note"]?.stringValue, "bugünün notu")
        XCTAssertEqual(server.putCount - putsBefore, 2)
        // Yeniden denenmez
        let puts = server.putCount
        let again = try await b.sync()
        XCTAssertEqual(server.putCount, puts)
        XCTAssertNil(again.error)
        XCTAssertEqual(again.rejected, [:])
        XCTAssertEqual(again.pushed, [])
        XCTAssertEqual(CloudSyncEngine.divergentKeys(local: b.data, state: b.state), [])
        try await a.sync()
        XCTAssertSameDocs(a.data, b.data)
        XCTAssertFalse(server.activity.contains { $0.user == "personel" && $0.key == key })
    }

    func testStaffDeleteOfLockedDayIsRestored() async throws {
        let (server, _, b) = try await connectedPair(staff: true)
        let key = DocKey.day(lockedDate)
        let before = try XCTUnwrap(server.doc(ws, key))
        b.edit { $0.days[self.lockedDate] = nil }
        let out = try await b.sync()
        XCTAssertNil(out.error)
        XCTAssertEqual(Array(out.rejected.keys), [key])
        XCTAssertEqual(b.data.days[lockedDate]?.isLocked, true)
        XCTAssertEqual(server.doc(ws, key)?.deleted, false)
        XCTAssertEqual(server.doc(ws, key)?.rev, before.rev)
        XCTAssertEqual(b.state.dirty, [])
    }

    /// Kilit, çekme ile gönderme arasında gelir: önce çakışma (kilitli gövde), sonra 42501 → yerelde sunucudaki hal
    func testLockArrivingBetweenPullAndPushEndsWithServerVersion() async throws {
        let (server, _, b) = try await connectedPair(staff: true)
        let date = "2026-08-30", key = DocKey.day(date)
        XCTAssertFalse(b.data.days[date]?.isLocked ?? false)
        b.edit { $0.days[date]?.entries["g90", default: DayEntry()].closing = 5 }
        var injected = false
        server.beforePut = { k in
            guard !injected, k == key else { return }
            injected = true
            var body = server.doc(self.ws, k)!.body.objectValue!
            body["locked"] = .bool(true)
            server.write(ws: self.ws, user: "patron", key: k, body: .object(body))
        }
        let out = try await b.sync()
        XCTAssertTrue(injected)
        XCTAssertNil(out.error)
        XCTAssertTrue(out.conflicts.contains(key))
        XCTAssertEqual(Array(out.rejected.keys), [key])
        XCTAssertEqual(b.state.dirty, [])
        let stored = try XCTUnwrap(server.doc(ws, key))
        XCTAssertEqual(DocCodec.body(for: key, in: b.data), DocCodec.normalize(key: key, body: stored.body))
        XCTAssertEqual(b.data.days[date]?.isLocked, true)
        XCTAssertNotEqual(b.data.days[date]?.entries["g90"]?.closing, 5)
        XCTAssertEqual(b.state.base[key]?.rev, stored.rev)
        server.beforePut = nil
        let puts = server.putCount
        _ = try await b.sync()
        XCTAssertEqual(server.putCount, puts)
    }

    /// Sık değişen bir belge çakışma sınırını aşsa da diğer anahtarlar (bugünün sayımı) aynı turda gönderilir
    func testConflictExhaustionDoesNotBlockLaterKeys() async throws {
        let (server, a, _) = try await connectedPair(staff: false)
        a.edit { $0.settings.priceAlertPct = 0.33 }
        a.edit { $0.days[self.today]?.note = "bugünün notu" }
        var n = 0
        server.beforePut = { key in
            guard key == DocKey.settings else { return }
            n += 1
            var body = server.doc(self.ws, key)!.body.objectValue!
            body["orderCoverDays"] = .number(Double(n))
            server.write(ws: self.ws, user: "personel", key: key, body: .object(body))
        }
        let out = try await a.sync()
        XCTAssertEqual(n, 1 + CloudDefaults.maxConflictRetries)
        if case .server(status: 409, message: _)? = out.error {} else { XCTFail("409 bekleniyordu: \(String(describing: out.error))") }
        XCTAssertEqual(out.pushed, [DocKey.day(today)])
        XCTAssertEqual(a.state.dirty, [DocKey.settings])
        XCTAssertEqual(server.doc(ws, DocKey.day(today))?.body["note"]?.stringValue, "bugünün notu")
        server.beforePut = nil
        let again = try await a.sync()
        XCTAssertNil(again.error)
        XCTAssertEqual(server.doc(ws, DocKey.settings)?.body["priceAlertPct"]?.doubleValue, 0.33)
    }

    // MARK: - Yerel rol denetimi (AppStore.setData)

    func testStaffRefusalCoversMixedActionsAndLockedDays() throws {
        let demo = DemoData.make(endingAt: today, days: 6)
        let open = try XCTUnwrap(demo.purchaseOrders.first { $0.status == .open })
        var received = demo
        try Purchasing.receive(orderID: open.id, on: today, data: &received)
        XCTAssertEqual(DocCodec.changedKeys(demo, received), [DocKey.orders, DocKey.day(today)])
        let r = CloudPermission.refusal(role: CloudRole.staff, old: demo, new: received)
        XCTAssertEqual(r?.catalogKeys, [DocKey.orders])
        XCTAssertEqual(r?.title, "Bu işlem için müdür yetkisi gerekir")
        XCTAssertTrue(r?.message.hasPrefix("Teslimatı ve siparişleri patron / müdür işler (web paneli).") ?? false)
        var priced = demo
        try Purchasing.receive(orderID: open.id, on: today, prices: [open.lines[0].itemID: 41], data: &priced)
        XCTAssertEqual(CloudPermission.refusal(role: CloudRole.staff, old: demo, new: priced)?.catalogKeys, [DocKey.items, DocKey.orders])
        for role in [CloudRole.owner, CloudRole.manager, nil] {
            XCTAssertNil(CloudPermission.refusal(role: role, old: demo, new: priced))
        }
        // Personelin günlük işi (açık gün) serbest; açık günü kapatmak da
        var counted = demo
        counted.days[today]?.entries["g90", default: DayEntry()].closing = 3
        XCTAssertNil(CloudPermission.refusal(role: CloudRole.staff, old: demo, new: counted))
        var closed = demo
        closed.days[today]?.locked = true
        XCTAssertNil(CloudPermission.refusal(role: CloudRole.staff, old: demo, new: closed))
        // Kalem silme: tanımlar ve (kapalı günler dahil) günler birlikte reddedilir
        var deleted = demo
        deleteItem("g90", &deleted)
        let rd = CloudPermission.refusal(role: CloudRole.staff, old: demo, new: deleted)
        XCTAssertEqual(rd?.catalogKeys, [DocKey.items, DocKey.products])
        XCTAssertTrue(rd?.lockedDates.contains(lockedDate) ?? false)
        var settings = demo
        settings.settings.staff.append("Yeni")
        XCTAssertEqual(CloudPermission.refusal(role: CloudRole.staff, old: demo, new: settings)?.message,
                       "Personel hesabıyla yalnızca günlük kayıtlar (sayım, satış, vardiya, not) değiştirilebilir. Ayarlar bölümündeki değişikliği patron ya da müdür web panelinden yapabilir; işlem uygulanmadı.")
        // Kapatılmış gün: değiştirme, kilit açma, silme reddedilir (müdür / patron için yeni kısıt yok)
        var edited = demo
        edited.days[lockedDate]?.note = "x"
        var unlocked = demo
        unlocked.days[lockedDate]?.locked = nil
        var removed = demo
        removed.days[lockedDate] = nil
        for d in [edited, unlocked, removed] {
            let x = CloudPermission.refusal(role: CloudRole.staff, old: demo, new: d)
            XCTAssertEqual(x?.lockedDates, [lockedDate])
            XCTAssertEqual(x?.catalogKeys, [])
            XCTAssertEqual(x?.title, "Gün kapatılmış")
            XCTAssertEqual(x?.message, "29.08.2026 günü kapatılmış. Kapatılmış günü yalnızca müdür veya patron değiştirebilir. Değişiklik uygulanmadı.")
            XCTAssertNil(CloudPermission.refusal(role: CloudRole.manager, old: demo, new: d))
            XCTAssertNil(CloudPermission.refusal(role: nil, old: demo, new: d))
        }
        XCTAssertTrue(CloudRole.canChangeLockedDay(CloudRole.manager))
        XCTAssertTrue(CloudRole.canChangeLockedDay(nil))
        XCTAssertFalse(CloudRole.canChangeLockedDay(CloudRole.staff))
        XCTAssertEqual(DocKey.title("day:2026-08-29"), "29.08.2026")
        XCTAssertEqual(DocKey.title(DocKey.orders), "Siparişler")
    }

    func testEnforcedRoleRequiresWorkspaceLink() {
        var s = SyncState(config: CloudConfig(role: CloudRole.staff))
        XCTAssertNil(s.enforcedRole)                                         // şube yok
        s.config?.workspaceID = ws
        XCTAssertNil(s.enforcedRole)                                         // ilk karar verilmedi
        s.initialized = true
        XCTAssertEqual(s.enforcedRole, CloudRole.staff)
        s.signOut()
        XCTAssertEqual(s.enforcedRole, CloudRole.staff)                      // çıkışta eşleşme ve rol korunur
    }

    /// Personel "Teslim al": işlem bütünüyle reddedilir; müdür teslim alınca Gelen bir kez artar (çift sayım yok)
    func testStaffReceiveIsRefusedSoDeliveryIsNotCountedTwice() async throws {
        let (server, a, b) = try await connectedPair(staff: true)
        let open = try XCTUnwrap(b.data.purchaseOrders.first { $0.status == .open })
        let item = open.lines[0].itemID, qty = open.lines[0].qty
        let before = b.data.days[today]?.entries[item]?.incoming ?? 0
        let refusal = guardedEdit(b) { _ = try? Purchasing.receive(orderID: open.id, on: self.today, data: &$0) }
        XCTAssertEqual(refusal?.catalogKeys, [DocKey.orders])
        XCTAssertEqual(b.state.dirty, [])
        XCTAssertEqual(b.data.days[today]?.entries[item]?.incoming ?? 0, before)
        let ob = try await b.sync()
        XCTAssertEqual(ob.pushed, [])
        XCTAssertEqual(ob.rejected, [:])
        XCTAssertNil(guardedEdit(a) { _ = try? Purchasing.receive(orderID: open.id, on: self.today, data: &$0) })
        try await a.sync()
        try await b.sync()
        XCTAssertEqual(server.doc(ws, DocKey.day(today))?.body["entries"]?[item]?["incoming"]?.doubleValue, before + qty)
        XCTAssertEqual(b.data.purchaseOrders.first { $0.id == open.id }?.status, .received)
    }

    /// Personel kalem silme: reddedilir; sunucuda kalemin sayım geçmişi (kapalı günler dahil) yerinde kalır
    func testStaffDeleteItemIsRefusedAndHistoryStays() async throws {
        let (server, _, b) = try await connectedPair(staff: true)
        func countedDays() -> Int {
            (server.docs[ws] ?? [:]).filter { DocKey.isDay($0.key) && $0.value.body["entries"]?["g90"] != nil }.count
        }
        let before = countedDays()
        XCTAssertGreaterThan(before, 2)
        XCTAssertNotNil(guardedEdit(b) { self.deleteItem("g90", &$0) })
        XCTAssertEqual(b.state.dirty, [])
        let out = try await b.sync()
        XCTAssertEqual(out.pushed, [])
        XCTAssertEqual(countedDays(), before)
        XCTAssertTrue(b.data.items.contains { $0.id == "g90" })
    }

    /// "Sayımı yapan" adı personel hesabıyla ayarlara yazılmaz: yalnızca gün gönderilir, yetki uyarısı çıkmaz
    func testStaffCountedByDoesNotWriteSettings() async throws {
        let s = AppSettings()
        XCTAssertNil(s.rememberingStaff("Selin", role: CloudRole.staff))
        XCTAssertEqual(s.rememberingStaff("Selin", role: CloudRole.manager)?.staff.last, "Selin")
        XCTAssertEqual(s.rememberingStaff(" Selin ", role: nil)?.staff.last, "Selin")
        XCTAssertNil(s.rememberingStaff("  ", role: nil))
        var named = s
        named.staff = ["Selin"]
        XCTAssertNil(named.rememberingStaff("Selin", role: CloudRole.owner))

        let (server, _, b) = try await connectedPair(staff: true)
        let name = "Yeni Personel", role = b.state.enforcedRole
        XCTAssertEqual(role, CloudRole.staff)
        b.edit { d in
            d.days[self.today]?.countedBy = name
            if let st = d.settings.rememberingStaff(name, role: role) { d.settings = st }
        }
        XCTAssertEqual(b.state.dirty, [DocKey.day(today)])
        let out = try await b.sync()
        XCTAssertEqual(out.rejected, [:])
        XCTAssertEqual(out.pushed, [DocKey.day(today)])
        XCTAssertEqual(server.doc(ws, DocKey.day(today))?.body["countedBy"]?.stringValue, name)
    }

    // MARK: - Personelin tanımları web'le aynı kalır (ilk bağlantıda "yükle", terfi)

    func testStaffUploadTakesServerCatalogAndPromotionDoesNotOverwrite() async throws {
        let (server, a, _) = try await connectedPair(staff: true)
        // Patron web'de yeni kalem ekler
        a.edit { $0.items.append(Item(id: "yeni-kalem", name: "Yeni Kalem", unit: "Adet", recipeUnit: "adet", factor: 1)) }
        try await a.sync()
        let itemsRev = try XCTUnwrap(server.doc(ws, DocKey.items)).rev
        // Kendi günleri ve eski tanımları olan personel Mac'i "Bu Mac'tekini Yükle" ile bağlanır
        var own = DemoData.make(endingAt: "2026-07-31", days: 3, seed: 5)
        own.items.removeAll { $0.id == "patates" }
        let c = SimClient(data: own, api: FakeAPI(server: server, user: "personel"), workspace: ws, role: CloudRole.staff)
        let mode = try await c.connect()
        XCTAssertEqual(mode, .ask)
        try await c.connect(.upload)
        XCTAssertTrue(c.data.items.contains { $0.id == "yeni-kalem" })
        for k in DocKey.catalog {
            XCTAssertEqual(DocCodec.body(for: k, in: c.data), DocCodec.normalize(key: k, body: server.doc(ws, k)?.body), k)
        }
        XCTAssertTrue(c.state.dirty.allSatisfy { DocKey.isDay($0) })
        XCTAssertTrue(c.state.dirty.contains("day:2026-07-31"))
        let out = try await c.sync()
        XCTAssertNil(out.error)
        XCTAssertEqual(out.rejected, [:])
        XCTAssertNotNil(server.doc(ws, "day:2026-07-31"))
        // Rol müdüre yükselir: tanımlar "yerel değişiklik" sayılmaz, sunucudakinin üzerine yazılmaz
        var st = c.state
        c.data = CloudSyncEngine.resume(workspace: CloudWorkspace(id: ws, name: "Tuzla Marina", role: CloudRole.manager),
                                        local: c.data, state: &st)
        c.state = st
        XCTAssertEqual(c.state.config?.role, CloudRole.manager)
        XCTAssertEqual(c.state.dirty.filter { !DocKey.isDay($0) }, [])
        let out2 = try await c.sync()
        XCTAssertEqual(out2.pushed.filter { !DocKey.isDay($0) }, [])
        XCTAssertEqual(server.doc(ws, DocKey.items)?.rev, itemsRev)
        XCTAssertTrue(server.doc(ws, DocKey.items)?.body.arrayValue?.contains { $0["id"]?.stringValue == "yeni-kalem" } ?? false)
    }

    /// Eskimiş tanımlar (eski sürümde "yükle" seçilmiş personel Mac'i) eşitlemede sunucudaki haline döner
    func testStaffSyncRestoresStaleCatalogFromServer() async throws {
        let (server, _, b) = try await connectedPair(staff: true)
        b.data.items[0].unitCost = 999
        b.data.settings.orderCoverDays = 9
        XCTAssertEqual(b.state.dirty, [])
        let out = try await b.sync()
        XCTAssertEqual(out.appliedRemote, [DocKey.items, DocKey.settings])
        XCTAssertEqual(out.pushed, [])
        XCTAssertEqual(out.rejected, [:])
        for k in [DocKey.items, DocKey.settings] {
            XCTAssertEqual(DocCodec.body(for: k, in: b.data), DocCodec.normalize(key: k, body: server.doc(ws, k)?.body), k)
        }
        // Müdürün yereldeki tanım değişikliğine dokunulmaz (gönderilmek üzere ayrışan anahtar olarak bulunur)
        let (_, m, _) = try await connectedPair(staff: false)
        m.data.items[0].unitCost = 999
        let om = try await m.sync()
        XCTAssertEqual(om.appliedRemote, [])
        XCTAssertEqual(m.data.items[0].unitCost, 999)
    }

    // MARK: - Geri alma (başka kullanıcıların sonradan gelen değişiklikleri korunur)

    func testUndoingKeepsLaterEditsFromOtherUsers() {
        let date = "2026-09-15", key = DocKey.day(date)
        var old = AppData(items: DemoData.make(endingAt: today, days: 1).items, products: [])
        old.days[date] = DayRecord(date: date, entries: ["g90": DayEntry(closing: 120), "peynir": DayEntry(closing: 4)])
        var new = old
        new.days[date]?.entries["g90"]?.closing = 110                       // Mac'in işlemi
        let keys = DocCodec.changedKeys(old, new)
        XCTAssertEqual(keys, [key])
        var current = new                                                   // web'den gelen düzeltme ve not
        current.days[date]?.entries["peynir"]?.closing = 9
        current.days[date]?.note = "Müdür düzeltmesi"
        let undone = DocCodec.undoing(keys: keys, old: old, new: new, current: current)
        XCTAssertEqual(undone.days[date]?.entries["g90"]?.closing, 120)
        XCTAssertEqual(undone.days[date]?.entries["peynir"]?.closing, 9)
        XCTAssertEqual(undone.days[date]?.note, "Müdür düzeltmesi")
        // Eski davranış bütün belgeyi geri getirip notu ve düzeltmeyi silerdi
        XCTAssertNil(DocCodec.replacing(keys, in: current, from: old).days[date]?.note)
        // Aynı alan sonradan değiştiyse sonraki değer kalır
        var later = new
        later.days[date]?.entries["g90"]?.closing = 130
        XCTAssertEqual(DocCodec.undoing(keys: keys, old: old, new: new, current: later).days[date]?.entries["g90"]?.closing, 130)
        // Yineleme (undo'nun kaydettiği adım) simetrik
        let redo = DocCodec.undoing(keys: DocCodec.changedKeys(current, undone), old: current, new: undone, current: undone)
        XCTAssertEqual(redo.days[date], current.days[date])

        // Tanım belgesi: A'nın adını geri alırken B'nin sonradan değişen maliyeti korunur
        var c0 = old
        c0.days = [:]
        var c1 = c0
        c1.items[0].name = "Yeni Ad"
        var c2 = c1
        c2.items[1].unitCost = 77
        XCTAssertNotEqual(c0.items[1].unitCost, 77)
        let u = DocCodec.undoing(keys: DocCodec.changedKeys(c0, c1), old: c0, new: c1, current: c2)
        XCTAssertEqual(u.items[0].name, c0.items[0].name)
        XCTAssertEqual(u.items[1].unitCost, 77)
        // Belge işlemden sonra değişmediyse birebir eski hal (sıra dahil): silinen kalem yerine döner
        var d1 = c0
        d1.items.remove(at: 1)
        XCTAssertEqual(DocCodec.undoing(keys: DocCodec.changedKeys(c0, d1), old: c0, new: d1, current: d1).items, c0.items)
    }

    // MARK: - Çıkış ve yeniden giriş: taban korunur, 3 yollu birleştirmeyle devam edilir

    func testSignOutKeepsLinkAndReloginResumesWithoutOverwritingWebEdits() async throws {
        let (server, a, b) = try await connectedPair(staff: false)
        let date = "2026-08-30", other = today
        a.state.signOut()
        XCTAssertFalse(a.state.isActive)
        XCTAssertFalse(a.state.isSignedIn)
        XCTAssertTrue(a.state.signedOut)
        XCTAssertEqual(a.state.config?.workspaceID, ws)
        XCTAssertTrue(a.state.initialized)
        XCTAssertFalse(a.state.base.isEmpty)
        // Oturum kapalıyken web'de müdür düzeltir; Mac'te başka bir gün değişir
        b.edit { $0.days[date]?.entries["g90", default: DayEntry()].closing = 12 }
        try await b.sync()
        a.edit { $0.days[other]?.note = "çıkıştayken" }

        // Aynı hesapla yeniden giriş
        var s = SyncState.forSignIn(existing: a.state, url: "https://test.local", publishableKey: "sb_publishable_yeni", email: "test@test")
        s.store(await a.api.currentSession)
        XCTAssertTrue(s.isSignedIn)
        XCTAssertFalse(s.isActive)                                           // şube onaylanana kadar beklenir
        XCTAssertEqual(s.config?.publishableKey, "sb_publishable_yeni")
        XCTAssertEqual(CloudSyncEngine.workspaceChoice(state: s, workspaceID: ws), .resume)
        a.data = CloudSyncEngine.resume(workspace: CloudWorkspace(id: ws, name: "Tuzla Marina", role: CloudRole.owner), local: a.data, state: &s)
        XCTAssertTrue(s.isActive)
        a.state = s
        let out = try await a.sync()
        XCTAssertNil(out.error)
        XCTAssertEqual(out.pushed, [DocKey.day(other)])
        XCTAssertEqual(a.data.days[date]?.entries["g90"]?.closing, 12)
        XCTAssertEqual(server.doc(ws, DocKey.day(date))?.body["entries"]?["g90"]?["closing"]?.doubleValue, 12)
        XCTAssertEqual(server.doc(ws, DocKey.day(other))?.body["note"]?.stringValue, "çıkıştayken")

        // Başka hesapla (aynı sunucu; şubenin müdürü) giriş: eşleşme yine korunur
        a.state.signOut()
        b.edit { $0.days[date]?.entries["g90", default: DayEntry()].closing = 13 }
        try await b.sync()
        a.edit { $0.days[other]?.note = "ikinci çıkış" }
        let c = SimClient(data: a.data, api: b.api, workspace: ws)
        var s2 = SyncState.forSignIn(existing: a.state, url: "https://test.local", publishableKey: "sb_publishable_test", email: "mudur@test")
        s2.store(await b.api.currentSession)
        XCTAssertEqual(s2.config?.email, "mudur@test")
        XCTAssertEqual(CloudSyncEngine.workspaceChoice(state: s2, workspaceID: ws), .resume)
        c.data = CloudSyncEngine.resume(workspace: CloudWorkspace(id: ws, name: "Tuzla Marina", role: CloudRole.manager), local: c.data, state: &s2)
        c.state = s2
        let out2 = try await c.sync()
        XCTAssertNil(out2.error)
        XCTAssertEqual(out2.pushed, [DocKey.day(other)])
        XCTAssertEqual(c.data.days[date]?.entries["g90"]?.closing, 13)
        XCTAssertEqual(server.doc(ws, DocKey.day(date))?.body["entries"]?["g90"]?["closing"]?.doubleValue, 13)
        XCTAssertEqual(server.doc(ws, DocKey.day(other))?.body["note"]?.stringValue, "ikinci çıkış")

        // Farklı sunucuda eşleşme başlamaz
        let fresh = SyncState.forSignIn(existing: a.state, url: "https://baska.local", publishableKey: "k", email: "x@y")
        XCTAssertNil(fresh.config?.workspaceID)
        XCTAssertFalse(fresh.initialized)
        XCTAssertEqual(fresh.base, [:])
        XCTAssertFalse(fresh.signedOut)
    }

    func testSignedOutStateRoundTrips() throws {
        var s = SyncState(config: CloudConfig(workspaceID: ws, role: CloudRole.staff), initialized: true)
        s.accessToken = "a"
        s.refreshToken = "r"
        XCTAssertTrue(s.isActive)
        s.signOut()
        let back = try SyncStore.decoder().decode(SyncState.self, from: SyncStore.encoder().encode(s))
        XCTAssertTrue(back.signedOut)
        XCTAssertFalse(back.isActive)
        XCTAssertNil(back.accessToken)
        XCTAssertNil(back.refreshToken)
        XCTAssertEqual(back.config?.workspaceID, ws)
        XCTAssertEqual(back.enforcedRole, CloudRole.staff)
        XCTAssertFalse(try SyncStore.decoder().decode(SyncState.self, from: Data("{}".utf8)).signedOut)
        var r = back
        r.resetWorkspaceData()
        XCTAssertFalse(r.signedOut)
    }

    // MARK: - Şube değişimi: boş şubeye başka şubenin günleri yüklenmez

    func testSwitchingToEmptyBranchNeverUploadsOtherBranchDays() async throws {
        XCTAssertEqual(CloudSyncEngine.initialMode(localIsSeedOnly: false, remoteEmpty: true, switchingFromOtherWorkspace: true), .ask)
        XCTAssertEqual(CloudSyncEngine.initialMode(localIsSeedOnly: false, remoteEmpty: false, switchingFromOtherWorkspace: true), .download)
        XCTAssertEqual(CloudSyncEngine.initialMode(localIsSeedOnly: true, remoteEmpty: true, switchingFromOtherWorkspace: true), .upload)
        XCTAssertEqual(CloudSyncEngine.initialMode(localIsSeedOnly: false, remoteEmpty: true), .upload)

        let (server, a, _) = try await connectedPair(staff: false)
        let ws2 = "33333333-3333-3333-3333-333333333333"
        server.addWorkspace(ws2, name: "Kadıköy", owner: "patron")
        XCTAssertEqual(CloudSyncEngine.workspaceChoice(state: a.state, workspaceID: ws), .resume)
        XCTAssertEqual(CloudSyncEngine.workspaceChoice(state: a.state, workspaceID: ws2), .initial(switching: true))
        XCTAssertEqual(CloudSyncEngine.workspaceChoice(state: SyncState(), workspaceID: ws2), .initial(switching: false))
        let ws1Revs = (server.docs[ws] ?? [:]).mapValues { $0.rev }

        // CloudSyncController.choose: durum sıfırlanır, yeni şube seçilir, tam okuma
        var s = a.state
        s.resetWorkspaceData()
        s.config?.workspaceID = ws2
        s.config?.workspaceName = "Kadıköy"
        let rows = try await a.api.pull(workspace: ws2, since: 0)
        let mode = CloudSyncEngine.initialMode(localIsSeedOnly: DocCodec.isSeedOnly(a.data), remoteEmpty: CloudSyncEngine.isRemoteEmpty(rows),
                                               switchingFromOtherWorkspace: true)
        XCTAssertEqual(mode, .ask)
        let catalog = a.data
        a.data = CloudSyncEngine.prepareInitial(mode: .copyCatalog, local: a.data, rows: rows, state: &s)
        a.state = s
        XCTAssertEqual(a.data.days.count, 0)
        XCTAssertEqual(a.data.settings.branchName, "Kadıköy")
        let out = try await a.sync()
        XCTAssertNil(out.error)
        let docs2 = server.docs[ws2] ?? [:]
        XCTAssertEqual(docs2.keys.filter { DocKey.isDay($0) }, [])
        XCTAssertEqual(Set(docs2.keys), Set(DocKey.catalog))
        XCTAssertEqual(docs2[DocKey.settings]?.body["branchName"]?.stringValue, "Kadıköy")
        XCTAssertEqual(docs2[DocKey.employees]?.body, j("[]"))
        XCTAssertEqual(docs2[DocKey.orders]?.body, j("[]"))
        XCTAssertEqual(Lenient.items(try XCTUnwrap(docs2[DocKey.items]?.body)), catalog.items)
        XCTAssertEqual(Lenient.products(try XCTUnwrap(docs2[DocKey.products]?.body)), catalog.products)
        XCTAssertEqual((server.docs[ws] ?? [:]).mapValues { $0.rev }, ws1Revs)        // eski şube değişmedi
    }

    // MARK: - Diske yazma sırası

    func testCheckpointWritesDataBeforeState() {
        final class Log { var calls: [String] = [] }
        let log = Log()
        XCTAssertTrue(SyncCheckpoint.persist(dataChanged: true, writeData: { log.calls.append("veri"); return true },
                                             writeState: { log.calls.append("durum") }))
        XCTAssertEqual(log.calls, ["veri", "durum"])
        log.calls = []
        XCTAssertFalse(SyncCheckpoint.persist(dataChanged: true, writeData: { log.calls.append("veri"); return false },
                                              writeState: { log.calls.append("durum") }))
        XCTAssertEqual(log.calls, ["veri"])                                  // veri yazılamadıysa durum da yazılmaz
        log.calls = []
        XCTAssertTrue(SyncCheckpoint.persist(dataChanged: false, writeData: { log.calls.append("veri"); return true },
                                             writeState: { log.calls.append("durum") }))
        XCTAssertEqual(log.calls, ["durum"])
    }

    /// Kalan tek pencere (veri yazıldı, durum yazılamadan kapandı) güvenlidir: eski taban çakışma verir, ezilme olmaz
    func testRelaunchWithNewerDataThanStateDoesNotOverwriteServer() async throws {
        let (server, a, b) = try await connectedPair(staff: false)
        let date = "2026-08-30", key = DocKey.day(date)
        let savedState = a.state
        b.edit { $0.days[date]?.entries["g90", default: DayEntry()].closing = 77 }
        try await b.sync()
        try await a.sync()
        XCTAssertEqual(a.data.days[date]?.entries["g90"]?.closing, 77)
        let c = SimClient(data: a.data, api: a.api, workspace: ws)
        c.state = savedState
        c.state.dirty.formUnion(CloudSyncEngine.divergentKeys(local: c.data, state: c.state))
        XCTAssertTrue(c.state.dirty.contains(key))
        let out = try await c.sync()
        XCTAssertNil(out.error)
        XCTAssertEqual(server.doc(ws, key)?.body["entries"]?["g90"]?["closing"]?.doubleValue, 77)
        XCTAssertEqual(c.data.days[date]?.entries["g90"]?.closing, 77)
        XCTAssertEqual(c.state.dirty, [])
    }

    // MARK: - Tutar girişi (web: Fmt.parseAmount ile aynı)

    func testParseAmountReadsTurkishThousands() {
        let cases: [(String, Double?)] = [
            ("35.000", 35000), ("1.050", 1050), ("1.295.867", 1_295_867), ("0.125", 0.125), ("1.05", 1.05),
            ("7,5", 7.5), ("1.050,5", 1050.5), ("12.5", 12.5), ("85000", 85000), (" 35.000 ", 35000),
            ("+1.050", 1050), ("\u{2212}1.050", -1050), ("0.500", 0.5), ("1.0500", 1.05), ("35\u{00A0}000", 35000),
            ("abc", nil), ("", nil), ("1e5", nil),
        ]
        for (s, v) in cases { XCTAssertEqual(Fmt.parseAmount(s), v, s) }
        // Miktar alanlarında kural değişmez (nokta ondalık)
        XCTAssertEqual(Fmt.parse("1.050"), 1.05)
    }
}
