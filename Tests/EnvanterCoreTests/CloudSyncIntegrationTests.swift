import Foundation
import XCTest
@testable import EnvanterCore

/// Gerçek Supabase bileşenlerine (GoTrue + PostgREST + migration'lı Postgres) karşı uçtan uca eşitleme testi.
/// Yalnızca ENVANTER_SUPABASE_TEST_URL tanımlıysa çalışır (yerel ortam: envantersite/scripts/local-supabase):
///
///   docker run --rm --network host -e ENVANTER_SUPABASE_TEST_URL=http://127.0.0.1:54321 \
///     -v $PWD:/src -v envanter-sync-build:/build -w /src swift:6.0-noble \
///     swift test --scratch-path /build --filter CloudSyncIntegrationTests
///
/// ENVANTER_SUPABASE_TEST_KEY: publishable key (yerel ağ geçidinde herhangi bir metin; varsayılan sb_publishable_local).
/// Test kullanıcıları @macsync.envanter alan adındadır. Patron hesabı sabittir: ilk şube kuralı (yalnızca hiç şube
/// yokken ya da başka bir şubenin patronuyken yeni şube açılabilir) her çalıştırmada sağlansın diye.
/// Test, açtığı şubeleri silemez (API'de silme yoktur); yerel ortamı temizlemek için:
///
///   docker exec -i -e PGPASSWORD=postgres sb-db psql -U supabase_admin -h localhost -d postgres -c \
///     "delete from public.envanter_workspaces where created_by in (select id from auth.users where email like '%@macsync.envanter');
///      delete from auth.users where email like '%@macsync.envanter';"
final class CloudSyncIntegrationTests: XCTestCase {
    private var baseURL = ""
    private let key = ProcessInfo.processInfo.environment["ENVANTER_SUPABASE_TEST_KEY"] ?? "sb_publishable_local"
    private let ownerEmail = "mac-owner@macsync.envanter"
    private let ownerPassword = "Mac-sifre-12345"

    override func setUpWithError() throws {
        guard let u = ProcessInfo.processInfo.environment["ENVANTER_SUPABASE_TEST_URL"], !u.isEmpty else {
            throw XCTSkip("ENVANTER_SUPABASE_TEST_URL tanımlı değil (yerel Supabase ortamı gerekir)")
        }
        guard let host = URL(string: u)?.host, ["127.0.0.1", "localhost", "::1"].contains(host) else {
            throw XCTSkip("Bu test yalnızca yerel Supabase ortamında çalışır: \(u)")
        }
        baseURL = u
    }

    private func api() throws -> SupabaseAPI { try SupabaseAPI(url: baseURL, publishableKey: key) }

    private func signUpOrIn(_ email: String, _ password: String) async throws -> SupabaseAPI {
        let a = try api()
        do { _ = try await a.signUp(email: email, password: password) } catch {
            _ = try await a.signIn(email: email, password: password)
        }
        return a
    }

    func testTwoMacClientsSyncThroughRealSupabase() async throws {
        let run = String(UUID().uuidString.prefix(8)).lowercased()

        // --- Hesaplar ve şube
        let owner = try await signUpOrIn(ownerEmail, ownerPassword)
        do {
            _ = try await api().signIn(email: ownerEmail, password: "yanlis-sifre")
            XCTFail("yanlış şifre kabul edildi")
        } catch {
            XCTAssertEqual(error as? CloudSyncError, .invalidCredentials)
        }

        let wsName = "Mac Eşitleme Testi \(run)"
        let wsID: String
        do {
            wsID = try await owner.createWorkspace(name: wsName)
        } catch CloudSyncError.forbidden(let m) {
            return XCTFail("Şube açılamadı (\(m)). Yerel veritabanında başka patronların şubeleri var; "
                + "envantersite/db-tests/run.sh ortamı boşaltır.")
        }
        let ownerWorkspaces = try await owner.myWorkspaces()
        XCTAssertTrue(ownerWorkspaces.contains(CloudWorkspace(id: wsID, name: wsName, role: CloudRole.owner)))

        // Personel kayıt olmadan önce davet edilir; kayıt olunca otomatik üye olur
        let staffEmail = "mac-staff-\(run)@macsync.envanter"
        let invited = try await owner.invite(workspace: wsID, email: staffEmail, role: CloudRole.staff)
        XCTAssertEqual(invited, "invited")
        let staff = try api()
        let staffSession = try await staff.signUp(email: staffEmail, password: "Personel-sifre-1")
        XCTAssertFalse(staffSession.refreshToken.isEmpty)
        let staffWorkspaces = try await staff.myWorkspaces()
        XCTAssertEqual(staffWorkspaces.first { $0.id == wsID }?.role, CloudRole.staff)

        // --- A (patron): ilk bağlantı, bulut boş → her şey yüklenir
        var demo = DemoData.make(endingAt: "2026-08-31", days: 35)
        demo.days = demo.days.filter { $0.key >= "2026-08-28" }
        let a = SimClient(data: demo, api: owner, workspace: wsID, role: CloudRole.owner, url: baseURL)
        let modeA = try await a.connect()
        XCTAssertEqual(modeA, .upload)
        let oa = try await a.sync()
        XCTAssertNil(oa.error)
        XCTAssertEqual(Set(oa.pushed), Set(DocCodec.split(demo).keys))
        XCTAssertEqual(a.state.dirty, [])

        // --- B (personel): yeni kurulum → buluttakini indirir
        let b = SimClient(data: AppData.seeded(), api: staff, workspace: wsID, role: CloudRole.staff, url: baseURL)
        let modeB = try await b.connect()
        XCTAssertEqual(modeB, .download)
        let ob = try await b.sync()
        XCTAssertNil(ob.error)
        XCTAssertEqual(ob.pushed, [])
        XCTAssertEqual(ob.rejected, [:])
        XCTAssertSameDocs(a.data, b.data)
        XCTAssertEqual(b.data.settings.branchName, "Burger Yiyelim · Tuzla Marina")

        // --- Aynı günde eşzamanlı değişiklikler birleşir
        let date = "2026-08-31", dayKey = "day:2026-08-31"
        a.edit { $0.days[date]?.entries["g90", default: DayEntry()].closing = 140 }
        b.edit { d in
            d.days[date]?.entries["peynir", default: DayEntry()].closing = 3.25
            d.days[date]?.note = "Personel notu"
        }
        let oa2 = try await a.sync()
        XCTAssertEqual(oa2.pushed, [dayKey])
        let ob2 = try await b.sync()
        XCTAssertNil(ob2.error)
        XCTAssertTrue(ob2.conflicts.contains(dayKey))
        XCTAssertEqual(ob2.pushed, [dayKey])
        let oa3 = try await a.sync()
        XCTAssertEqual(oa3.appliedRemote, [dayKey])
        for c in [a, b] {
            XCTAssertEqual(c.data.days[date]?.entries["g90"]?.closing, 140)
            XCTAssertEqual(c.data.days[date]?.entries["peynir"]?.closing, 3.25)
            XCTAssertEqual(c.data.days[date]?.note, "Personel notu")
        }
        XCTAssertSameDocs(a.data, b.data)

        // --- Personel stok kalemlerini değiştiremez: 403 bildirilir, sunucu sürümü geri gelir
        b.edit { d in
            if let i = d.items.firstIndex(where: { $0.id == "patates" }) { d.items[i].unitCost = 1 }
        }
        XCTAssertEqual(b.state.dirty, ["items"])
        let ob3 = try await b.sync()
        XCTAssertNil(ob3.error)
        XCTAssertTrue(ob3.rejected["items"]?.contains("Personel") ?? false, "\(ob3.rejected)")
        XCTAssertEqual(b.data.items, a.data.items)
        XCTAssertEqual(b.state.dirty, [])
        // Doğrudan çağrı da reddedilir
        do {
            _ = try await staff.put(workspace: wsID, key: "settings", body: j("{}"), baseRev: 0, deleted: false, client: "mac", summary: nil)
            XCTFail("personel ayar yazabildi")
        } catch {
            guard case .forbidden? = error as? CloudSyncError else { return XCTFail("\(error)") }
        }

        // --- Kapatılmış gün (D1): personel değiştiremez, kilidini açamaz, silemez. Sunucu 42501 döner; Mac sunucudaki
        // hali geri yükler, yeniden denemez ve sonraki günleri göndermeye devam eder.
        let lockedDay = "2026-08-29", lockedKey = "day:2026-08-29"
        XCTAssertEqual(b.data.days[lockedDay]?.isLocked, true)
        let lockedRev = try XCTUnwrap(b.state.base[lockedKey]?.rev)
        b.edit { d in
            d.days[lockedDay]?.locked = nil
            d.days[lockedDay]?.note = "personel kilidi açtı"
        }
        b.edit { $0.days[date]?.entries["patates", default: DayEntry()].closing = 21.5 }
        let ob5 = try await b.sync()
        XCTAssertNil(ob5.error)
        XCTAssertEqual(Array(ob5.rejected.keys), [lockedKey])
        XCTAssertEqual(ob5.rejected[lockedKey], CloudPermission.lockedDayMessage)
        XCTAssertEqual(ob5.pushed, [dayKey])
        XCTAssertEqual(b.state.dirty, [])
        XCTAssertEqual(b.data.days[lockedDay]?.isLocked, true)
        XCTAssertEqual(DocCodec.body(for: lockedKey, in: b.data), DocCodec.body(for: lockedKey, in: a.data))
        let ob6 = try await b.sync()
        XCTAssertEqual(ob6.rejected, [:])
        XCTAssertEqual(ob6.pushed, [])
        // Doğrudan çağrılar: silme ve kilit açma 403; aynı gövdeyi yeniden yazmak serbest
        for (body, deleted) in [(j("{}"), true), (j(#"{"entries":{}}"#), false)] {
            do {
                _ = try await staff.put(workspace: wsID, key: lockedKey, body: body, baseRev: lockedRev, deleted: deleted, client: "mac", summary: nil)
                XCTFail("personel kapatılmış günü değiştirebildi")
            } catch {
                XCTAssertEqual(error as? CloudSyncError, .forbidden(CloudPermission.lockedDayMessage))
            }
        }
        let lockedBody = try XCTUnwrap(b.state.base[lockedKey]?.body)
        let same = try await staff.put(workspace: wsID, key: lockedKey, body: lockedBody, baseRev: lockedRev, deleted: false, client: "mac", summary: nil)
        XCTAssertTrue(same.ok)
        // Patron değiştirebilir (kilidi açmadan not ekler)
        try await a.sync()
        a.edit { $0.days[lockedDay]?.note = "patron notu" }
        let oa5 = try await a.sync()
        XCTAssertNil(oa5.error)
        XCTAssertEqual(oa5.pushed, [lockedKey])
        try await b.sync()
        XCTAssertEqual(b.data.days[lockedDay]?.note, "patron notu")
        XCTAssertEqual(b.data.days[lockedDay]?.isLocked, true)
        XCTAssertEqual(b.data.days[date]?.entries["patates"]?.closing, 21.5)
        XCTAssertEqual(a.data.days[date]?.entries["patates"]?.closing, 21.5)

        // --- Silinen gün diğer istemciden de kalkar
        a.edit { $0.days["2026-08-28"] = nil }
        let oa4 = try await a.sync()
        XCTAssertEqual(oa4.pushed, ["day:2026-08-28"])
        let ob4 = try await b.sync()
        XCTAssertTrue(ob4.appliedRemote.contains("day:2026-08-28"))
        XCTAssertNil(b.data.days["2026-08-28"])

        // --- Eski tabanla yazma çakışma döndürür (karşılaştır-ve-yaz)
        let stale = try await owner.put(workspace: wsID, key: dayKey, body: j(#"{"note":"eski"}"#), baseRev: 1,
                                        deleted: false, client: "mac", summary: nil)
        XCTAssertFalse(stale.ok)
        XCTAssertEqual(stale.rev, a.state.base[dayKey]?.rev)
        XCTAssertEqual(stale.body?["note"]?.stringValue, "Personel notu")

        // --- Değişiklik geçmişi özetlerle yazıldı
        let activity = try await owner.activity(workspace: wsID, limit: 200)
        // Belge yazmaları Mac'ten; patronun üyelik işlemleri `members` satırıdır (istemci yok, belge değil)
        XCTAssertTrue(activity.filter { $0.key != "members" }.allSatisfy { $0.client == CloudDefaults.client && !$0.summary.isEmpty })
        XCTAssertTrue(activity.contains { $0.key == "members" && $0.client == nil && $0.email == ownerEmail
                && $0.summary == "Davet edildi: \(staffEmail) (Personel)" })
        XCTAssertTrue(activity.contains { $0.key == "items" && $0.summary.hasPrefix("Stok kalemleri: ") && $0.email == ownerEmail })
        XCTAssertTrue(activity.contains { $0.key == dayKey && $0.email == ownerEmail && $0.summary.contains("31.08.2026 sayımı: 90 Gr kapanış") })
        XCTAssertTrue(activity.contains { $0.key == dayKey && $0.email == staffEmail && $0.summary.contains("Peynir kapanış") })
        XCTAssertTrue(activity.contains { $0.key == "day:2026-08-28" && $0.summary == "28.08.2026 günü silindi" })
        XCTAssertFalse(activity.contains { $0.email == staffEmail && !DocKey.isDay($0.key) })
        // Personelin kapatılmış güne tek yazması aynı gövdenin yeniden yazılmasıdır
        XCTAssertEqual(activity.filter { $0.email == staffEmail && $0.key == lockedKey }.count, 1)

        // --- Rol oturum açıkken değişir (patron web panelinden yükseltir / düşürür; oturum kapanmaz): Mac şube
        // listesinden günceller (CloudSyncEngine.refreshRole); eskimiş tanımlar gönderilmez, müdür yazması kabul edilir
        func rpc(_ name: String, _ params: [String: JSONValue]) async throws -> JSONValue {
            let r = try await owner.authorized("POST", owner.url("rest/v1/rpc/\(name)"), body: .object(params))
            return r.body.isEmpty ? .null : try JSONCoding.parse(r.body)
        }
        func refreshRole(_ c: SimClient) async throws -> Bool {
            var st = c.state
            guard let data = CloudSyncEngine.refreshRole(workspaces: try await staff.myWorkspaces(), local: c.data, state: &st) else { return false }
            c.data = data
            c.state = st
            return true
        }
        let members = try await rpc("envanter_members_list", ["p_workspace": .string(wsID)])
        let staffID = try XCTUnwrap(members.arrayValue?.first { $0["email"]?.stringValue == staffEmail }?["user_id"]?.stringValue)
        b.state.config?.workspaceName = wsName
        let unchangedRole = try await refreshRole(b)
        XCTAssertFalse(unchangedRole)
        let itemsRev = try XCTUnwrap(b.state.base["items"]?.rev)
        if let i = b.data.items.firstIndex(where: { $0.id == "patates" }) { b.data.items[i].unitCost = 7777 }  // eskimiş tanım
        _ = try await rpc("envanter_set_role", ["p_workspace": .string(wsID), "p_user": .string(staffID), "p_role": .string(CloudRole.manager)])
        let promoted = try await refreshRole(b)
        XCTAssertTrue(promoted)
        XCTAssertEqual(b.state.enforcedRole, CloudRole.manager)
        XCTAssertEqual(b.data.items, a.data.items)
        let ob7 = try await b.sync()
        XCTAssertNil(ob7.error)
        XCTAssertEqual(ob7.pushed, [])
        XCTAssertEqual(b.state.base["items"]?.rev, itemsRev)
        var managerEdit = b.data
        if let i = managerEdit.items.firstIndex(where: { $0.id == "patates" }) { managerEdit.items[i].unitCost = 42.5 }
        XCTAssertNil(CloudPermission.refusal(role: b.state.enforcedRole, old: b.data, new: managerEdit))
        b.edit { $0 = managerEdit }
        let ob8 = try await b.sync()
        XCTAssertNil(ob8.error)
        XCTAssertEqual(ob8.rejected, [:])
        XCTAssertEqual(ob8.pushed, ["items"])
        try await a.sync()
        XCTAssertEqual(a.data.items.first { $0.id == "patates" }?.unitCost, 42.5)
        _ = try await rpc("envanter_set_role", ["p_workspace": .string(wsID), "p_user": .string(staffID), "p_role": .string(CloudRole.staff)])
        let demoted = try await refreshRole(b)
        XCTAssertTrue(demoted)
        XCTAssertEqual(b.state.enforcedRole, CloudRole.staff)
        var staffEdit = b.data
        if let i = staffEdit.items.firstIndex(where: { $0.id == "patates" }) { staffEdit.items[i].unitCost = 1 }
        XCTAssertEqual(CloudPermission.refusal(role: b.state.enforcedRole, old: b.data, new: staffEdit)?.catalogKeys, ["items"])
        let roleRows = try await owner.activity(workspace: wsID, limit: 200).filter { $0.key == "members" }.map { $0.summary }
        XCTAssertTrue(roleRows.contains("Yetki değişti: \(staffEmail) (Personel → Müdür)"), "\(roleRows)")
        XCTAssertTrue(roleRows.contains("Yetki değişti: \(staffEmail) (Müdür → Personel)"), "\(roleRows)")

        // --- Oturum yenileme (gerçek GoTrue): süresi dolmak üzere → önceden; geçersiz anahtar → 401 sonrası
        guard let s0 = await owner.currentSession else { return XCTFail("oturum yok") }
        await owner.setSession(AuthSession(accessToken: s0.accessToken, refreshToken: s0.refreshToken,
                                           expiresAt: Date().addingTimeInterval(-5), email: s0.email))
        _ = try await owner.myWorkspaces()
        guard let s1 = await owner.currentSession else { return XCTFail("oturum yok") }
        XCTAssertNotEqual(s1.refreshToken, s0.refreshToken)
        // 401 yanıtı (WWW-Authenticate: Bearer) Linux'taki URLSession'ı çökertir; bu adım yerel HTTP istemcisiyle
        #if canImport(FoundationNetworking)
        let transport401: SyncTransport = LoopbackHTTPTransport()
        #else
        let transport401: SyncTransport = URLSessionTransport()
        #endif
        let expired = try SupabaseAPI(url: baseURL, publishableKey: key, transport: transport401)
        await expired.setSession(AuthSession(accessToken: "gecersiz-anahtar", refreshToken: s1.refreshToken,
                                             expiresAt: Date().addingTimeInterval(3600), email: s1.email))
        let again = try await expired.myWorkspaces()
        XCTAssertTrue(again.contains { $0.id == wsID })
        let s2 = await expired.currentSession
        XCTAssertNotEqual(s2?.accessToken, "gecersiz-anahtar")
        XCTAssertNotEqual(s2?.refreshToken, s1.refreshToken)
        // Yenileme anahtarı da geçersizse yeniden giriş gerekir
        await expired.setSession(AuthSession(accessToken: "gecersiz-anahtar", refreshToken: "gecersiz-yenileme"))
        do {
            _ = try await expired.myWorkspaces()
            XCTFail("geçersiz oturum kabul edildi")
        } catch {
            XCTAssertEqual(error as? CloudSyncError, .sessionExpired)
        }
        let cleared = await expired.currentSession
        XCTAssertNil(cleared)
    }
}
