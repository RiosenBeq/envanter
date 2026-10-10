import Foundation
import XCTest
@testable import EnvanterCore

/// İkinci inceleme turunun Mac bulguları: oturum açıkken rolün güncellenmesi (MACFIX-1), ⌘L ile gün kapatma kuralı
/// (MACFIX-2) ve eşitleme kayıt noktasının arayüzü bekletmeden, sırayı koruyarak yazılması (MACFIX-5).
final class RoleRefreshAndDiskQueueTests: XCTestCase {
    let ws = "44444444-4444-4444-4444-444444444444"
    /// DemoData son iki gün dışındaki günleri kapatır (6 gün: 26–29 Ağustos kapalı, 30–31 açık)
    let lockedDate = "2026-08-29"
    let today = "2026-08-31"

    /// A (patron) buluta yükler, B (personel; yeni kurulum) indirir
    private func connectedStaffPair() async throws -> (FakeServer, SimClient, SimClient) {
        let server = FakeServer()
        server.addWorkspace(ws, name: "Tuzla Marina", owner: "patron")
        server.addMember(ws, user: "personel", role: CloudRole.staff)
        let a = SimClient(data: DemoData.make(endingAt: today, days: 6), api: FakeAPI(server: server, user: "patron"), workspace: ws)
        try await a.connect()
        let oa = try await a.sync()
        XCTAssertNil(oa.error)
        let b = SimClient(data: AppData.seeded(), api: FakeAPI(server: server, user: "personel"), workspace: ws, role: CloudRole.staff)
        b.state.config?.workspaceName = "Tuzla Marina"
        try await b.connect()
        let ob = try await b.sync()
        XCTAssertNil(ob.error)
        XCTAssertSameDocs(a.data, b.data)
        return (server, a, b)
    }

    /// CloudSyncController.applyRoleRefresh gibi: şube listesi okunur, değişiklik varsa veri ve durum güncellenir
    @discardableResult
    private func refreshRole(_ c: SimClient) async throws -> Bool {
        var st = c.state
        let list = try await c.api.myWorkspaces()
        guard let data = CloudSyncEngine.refreshRole(workspaces: list, local: c.data, state: &st) else {
            XCTAssertEqual(st, c.state, "değişiklik yokken durum değişmemeli")
            return false
        }
        c.data = data
        c.state = st
        return true
    }

    private func costEdit(_ d: inout AppData, _ cost: Double) {
        if let i = d.items.firstIndex(where: { $0.id == "patates" }) { d.items[i].unitCost = cost }
    }

    // MARK: - MACFIX-1: rol oturum açıkken güncellenir

    func testPromotedStaffGetsManagerRightsWithoutSigningOut() async throws {
        let (server, _, b) = try await connectedStaffPair()
        XCTAssertEqual(b.state.enforcedRole, CloudRole.staff)
        // Personelken eskimiş kalmış tanımlar (ör. eski sürümde "yükle" seçilmiş): yerel değişiklik değil
        let serverItems = try XCTUnwrap(server.doc(ws, DocKey.items))
        costEdit(&b.data, 999)
        XCTAssertEqual(b.state.dirty, [])
        var itemsEdit = b.data
        costEdit(&itemsEdit, 41)
        XCTAssertNotNil(CloudPermission.refusal(role: b.state.enforcedRole, old: b.data, new: itemsEdit))
        var unlock = b.data
        unlock.days[lockedDate]?.locked = nil
        XCTAssertNotNil(CloudPermission.refusal(role: b.state.enforcedRole, old: b.data, new: unlock))

        // Rol değişmeden yenileme: hiçbir şey değişmez
        let unchanged = try await refreshRole(b)
        XCTAssertFalse(unchanged)

        // Patron web panelinden müdüre yükseltir; Mac oturumu kapanmaz. Önceki davranış: birkaç eşitleme turundan sonra
        // da rol "staff" kalıyor, kalem düzeltmesi yerelde reddediliyordu.
        server.addMember(ws, user: "personel", role: CloudRole.manager)
        for _ in 0..<2 { try await b.sync() }
        XCTAssertEqual(b.state.enforcedRole, CloudRole.staff)                // eşitleme tek başına rolü güncellemez
        costEdit(&b.data, 999)                                              // eşitleme eskimiş tanımı düzeltmişti

        let changed = try await refreshRole(b)
        XCTAssertTrue(changed)
        XCTAssertEqual(b.state.enforcedRole, CloudRole.manager)
        XCTAssertEqual(b.state.config?.role, CloudRole.manager)
        XCTAssertEqual(b.state.config?.workspaceName, "Tuzla Marina")
        // Eskimiş tanım (eski rolle) sunucudaki haline döndü: terfiyle "yerel değişiklik" sanılıp gönderilmez
        XCTAssertEqual(DocCodec.body(for: DocKey.items, in: b.data), DocCodec.normalize(key: DocKey.items, body: serverItems.body))
        XCTAssertEqual(b.state.dirty, [])
        var managerEdit = b.data
        costEdit(&managerEdit, 41)
        var managerUnlock = b.data
        managerUnlock.days[lockedDate]?.locked = nil
        XCTAssertNil(CloudPermission.refusal(role: b.state.enforcedRole, old: b.data, new: managerEdit))
        XCTAssertNil(CloudPermission.refusal(role: b.state.enforcedRole, old: b.data, new: managerUnlock))
        let quiet = try await b.sync()
        XCTAssertNil(quiet.error)
        XCTAssertEqual(quiet.pushed, [])
        XCTAssertEqual(server.doc(ws, DocKey.items)?.rev, serverItems.rev)

        // Müdür olarak kalem maliyeti ve kapatılmış günün kilidi değiştirilir; sunucu kabul eder
        b.edit { self.costEdit(&$0, 41) }
        b.edit { $0.days[self.lockedDate]?.locked = nil }
        let out = try await b.sync()
        XCTAssertNil(out.error)
        XCTAssertEqual(out.rejected, [:])
        XCTAssertEqual(Set(out.pushed), [DocKey.items, DocKey.day(lockedDate)])
        XCTAssertEqual(Lenient.items(try XCTUnwrap(server.doc(ws, DocKey.items)?.body))?.first { $0.id == "patates" }?.unitCost, 41)
        XCTAssertNil(server.doc(ws, DocKey.day(lockedDate))?.body["locked"])
    }

    func testDemotedManagerGetsStaffRulesAndPendingCatalogEditEndsWithServerVersion() async throws {
        let (server, a, b) = try await connectedStaffPair()
        server.addMember(ws, user: "personel", role: CloudRole.manager)
        try await refreshRole(b)
        XCTAssertEqual(b.state.enforcedRole, CloudRole.manager)
        // Müdürken gönderilmemiş tanım değişikliği; bu arada personele alınır
        b.edit { self.costEdit(&$0, 55) }
        XCTAssertEqual(b.state.dirty, [DocKey.items])
        server.addMember(ws, user: "personel", role: CloudRole.staff)
        let demoted = try await refreshRole(b)
        XCTAssertTrue(demoted)
        XCTAssertEqual(b.state.enforcedRole, CloudRole.staff)
        XCTAssertEqual(b.state.dirty, [DocKey.items])                       // bekleyen değişikliğe dokunulmaz
        var edit = b.data
        costEdit(&edit, 60)
        XCTAssertEqual(CloudPermission.refusal(role: b.state.enforcedRole, old: b.data, new: edit)?.catalogKeys, [DocKey.items])
        // Gönderim reddedilir, sunucudaki hal geri gelir ve yeniden denenmez
        let out = try await b.sync()
        XCTAssertEqual(Array(out.rejected.keys), [DocKey.items])
        XCTAssertEqual(b.state.dirty, [])
        XCTAssertEqual(b.data.items, a.data.items)
        let again = try await b.sync()
        XCTAssertEqual(again.rejected, [:])
        XCTAssertEqual(again.pushed, [])
    }

    func testRefreshRoleUpdatesNameAndIgnoresMissingWorkspace() async throws {
        let (server, _, b) = try await connectedStaffPair()
        // Şube adı web panelinde değişti (FakeServer: addWorkspace adı günceller)
        server.addWorkspace(ws, name: "Tuzla Marina 2", owner: "patron")
        let before = b.data
        let renamed = try await refreshRole(b)
        XCTAssertTrue(renamed)
        XCTAssertEqual(b.state.config?.workspaceName, "Tuzla Marina 2")
        XCTAssertEqual(b.state.enforcedRole, CloudRole.staff)
        XCTAssertSameDocs(before, b.data)

        // Şube listede yok (ör. şubeden çıkarıldı): değişiklik yok, sunucu yazmaları zaten reddeder
        var st = b.state
        XCTAssertNil(CloudSyncEngine.refreshRole(workspaces: [], local: b.data, state: &st))
        XCTAssertNil(CloudSyncEngine.refreshRole(workspaces: [CloudWorkspace(id: "baska", name: "Başka", role: CloudRole.owner)],
                                                 local: b.data, state: &st))
        XCTAssertEqual(st, b.state)
        // Şube eşleşmesi yoksa ya da ilk karar verilmediyse uygulanmaz
        var fresh = SyncState(config: CloudConfig(workspaceID: ws, role: CloudRole.staff))
        XCTAssertNil(CloudSyncEngine.refreshRole(workspaces: [CloudWorkspace(id: ws, name: "x", role: CloudRole.manager)],
                                                 local: b.data, state: &fresh))
        XCTAssertEqual(fresh.config?.role, CloudRole.staff)
    }

    // MARK: - MACFIX-2: ⌘L ile gün kapatma kuralı

    func testDayLockActionRules() {
        let staff = CloudRole.staff
        XCTAssertEqual(DayLockAction.resolve(locked: false, counted: false, role: staff), .nothingCounted)
        XCTAssertEqual(DayLockAction.resolve(locked: false, counted: false, role: CloudRole.manager), .nothingCounted)
        XCTAssertEqual(DayLockAction.resolve(locked: false, counted: false, role: nil), .nothingCounted)
        XCTAssertEqual(DayLockAction.resolve(locked: false, counted: true, role: staff), .confirmClose)
        for role in [CloudRole.owner, CloudRole.manager, nil] {
            XCTAssertEqual(DayLockAction.resolve(locked: false, counted: true, role: role), .close)
            XCTAssertEqual(DayLockAction.resolve(locked: true, counted: true, role: role), .unlock)
            XCTAssertEqual(DayLockAction.resolve(locked: true, counted: false, role: role), .unlock)
        }
        XCTAssertEqual(DayLockAction.resolve(locked: true, counted: true, role: staff), .unlockNotAllowed)
        XCTAssertEqual([DayLockAction.close, .confirmClose, .unlock, .nothingCounted, .unlockNotAllowed].map { $0.isAvailable },
                       [true, true, true, false, false])
        XCTAssertEqual(DayLockAction.confirmTitle(date: "2026-08-31"), "31.08.2026 günü kapatılsın mı?")
        XCTAssertTrue(DayLockAction.confirmMessage.contains("kilidi yalnızca patron veya müdür açabilir"))
        // Personele kilidi açmasını söyleyen metin yok (satış aktarma uyarısı)
        XCTAssertTrue(CloudPermission.lockedDayPickAnotherNote.contains("patron veya müdür"))
        XCTAssertFalse(CloudPermission.lockedDayPickAnotherNote.contains("kilidini açın"))
    }

    /// Gün menüsü (⌘L) Günlük Sayım düğmesiyle aynı sayım kuralını kullanır: boş ya da ileri tarihli gün kapatılmaz
    func testHasCountMatchesDailyViewRuleAndBlocksClosingEmptyDays() {
        var demo = DemoData.make(endingAt: today, days: 6)
        let future = DateKey.addDays(1, to: today)
        demo.days[future] = DayRecord(date: future, note: "yarın teslimat var")
        let engine = Engine(data: demo)
        for date in demo.days.keys.sorted() + ["2026-09-15"] {
            XCTAssertEqual(engine.hasCount(date: date), engine.calc(date: date).rows.contains { $0.isCounted }, date)
        }
        XCTAssertTrue(engine.hasCount(date: today))
        XCTAssertFalse(engine.hasCount(date: future))                      // yalnızca notu olan gün sayılmamış
        XCTAssertEqual(DayLockAction.resolve(locked: false, counted: engine.hasCount(date: future), role: CloudRole.staff), .nothingCounted)
        XCTAssertEqual(DayLockAction.resolve(locked: false, counted: engine.hasCount(date: "2026-09-15"), role: CloudRole.staff), .nothingCounted)
        XCTAssertEqual(DayLockAction.resolve(locked: false, counted: engine.hasCount(date: today), role: CloudRole.staff), .confirmClose)
        // Pasif kalemin kapanışı sayılmaz (Günlük Sayım yalnızca aktif kalemleri gösterir)
        var onlyInactive = demo
        let first = onlyInactive.items[0].id
        onlyInactive.items[0].active = false
        onlyInactive.days[future] = DayRecord(date: future, entries: [first: DayEntry(closing: 5)])
        let e2 = Engine(data: onlyInactive)
        XCTAssertFalse(e2.hasCount(date: future))
        XCTAssertEqual(e2.hasCount(date: future), e2.calc(date: future).rows.contains { $0.isCounted })
    }

    // MARK: - MACFIX-5: kayıt noktası arka planda, sırayla

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = []
        private var _offMain: [Bool] = []
        var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }
        var allOffMain: Bool { lock.lock(); defer { lock.unlock() }; return _offMain.allSatisfy { $0 } }
        func record(_ s: String) {
            lock.lock(); defer { lock.unlock() }
            _calls.append(s)
            _offMain.append(!Thread.isMainThread)
        }
    }

    func testCheckpointRunsOffCallerAndKeepsDataBeforeLaterStateSaves() {
        let q = DiskWriteQueue(label: "test.disk")
        let log = Recorder()
        // Veri yazıcısı kapı açılana kadar bekler (yavaş kodlama + yazma). Kayıt noktası çağıranı bekletseydi test
        // burada takılırdı; güvenlik için kapı 5 sn sonra kendiliğinden açılır ve süre denetimi başarısız olur.
        let gate = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { gate.signal() }
        let started = Date()
        q.checkpoint(writeData: {
            gate.wait()
            log.record("veri")
            return true
        }, writeState: { log.record("durum-1") })
        // Hemen ardından gelen durum kaydı (ör. bir sonraki yerel değişiklik) veriyi geçemez
        q.async { log.record("durum-2") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "çağıran (ana iş parçacığı) yazmayı beklememeli")
        XCTAssertEqual(log.calls, [])
        gate.signal()
        q.sync {}
        XCTAssertEqual(log.calls, ["veri", "durum-1", "durum-2"])
        XCTAssertTrue(log.allOffMain)
    }

    func testCheckpointSkipsStateWhenDataWriteFails() {
        let q = DiskWriteQueue(label: "test.disk.fail")
        let log = Recorder()
        let done = expectation(description: "tamam")
        final class Box: @unchecked Sendable { var written: Bool? }
        let box = Box()
        q.checkpoint(writeData: { log.record("veri"); return false }, writeState: { log.record("durum") }) { written in
            box.written = written
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(log.calls, ["veri"])
        XCTAssertEqual(box.written, false)
        // Veri değişmediyse yalnızca durum yazılır
        let log2 = Recorder()
        q.checkpoint(writeData: nil, writeState: { log2.record("durum") })
        q.sync {}
        XCTAssertEqual(log2.calls, ["durum"])
    }

    /// Gerçek dosyalarla: durum yazılırken veri dosyası kayıt noktasının verisini içerir; sonraki durum kaydı sonra gelir
    func testCheckpointWithRealFilesWritesDataThenState() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("envanter-diskq-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = Persistence(directory: dir)
        let store = SyncStore(directory: dir)
        let q = DiskWriteQueue(label: "test.disk.files")
        let data = DemoData.make(endingAt: today, days: 60)
        let s1 = SyncState(config: CloudConfig(workspaceID: ws, role: CloudRole.owner), lastRev: 10, initialized: true)
        var s2 = s1
        s2.lastRev = 11
        final class Seen: @unchecked Sendable { var daysOnDiskWhenStateWritten: Int?; var revOnDisk: Int64? }
        let seen = Seen()
        let s1Copy = s1
        q.checkpoint(writeData: {
            do { try p.write(try p.encode(data)); return true } catch { return false }
        }, writeState: {
            seen.daysOnDiskWhenStateWritten = (try? Persistence.decode(Data(contentsOf: p.dataFile)))?.days.count
            try? store.save(s1Copy)
        })
        let s2Copy = s2
        q.async { try? store.save(s2Copy) }
        q.sync { seen.revOnDisk = store.load().lastRev }
        XCTAssertEqual(seen.daysOnDiskWhenStateWritten, data.days.count)
        XCTAssertEqual(seen.revOnDisk, 11)
    }
}
