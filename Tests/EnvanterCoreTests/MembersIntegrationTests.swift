import Foundation
import XCTest
@testable import EnvanterCore

/// Kullanıcılar paneli işlemlerinin gerçek Supabase'e (GoTrue + PostgREST + migration'lı Postgres) karşı uçtan uca
/// testi. Yalnızca ENVANTER_SUPABASE_TEST_URL tanımlıysa çalışır (bkz. CloudSyncIntegrationTests):
///
///   docker run --rm --network host -e ENVANTER_SUPABASE_TEST_URL=http://127.0.0.1:54321 \
///     -v $PWD:/src -v envanter-sync-build:/build -w /src swift:6.0-noble \
///     swift test --scratch-path /build --filter MembersIntegrationTests
///
/// Her çalıştırma yeni adlar kullanır (veritabanı başka testlerle paylaşılır). Açılan hesaplar kullanıcı adı hesaplarıdır
/// (kasa1-<çalıştırma>@envanter.local); yerel ortamı temizlemek için CloudSyncIntegrationTests'teki sorguya ek olarak:
///
///   delete from auth.users where email like 'kasa%-%@envanter.local';
final class MembersIntegrationTests: XCTestCase {
    private var baseURL = ""
    private let key = ProcessInfo.processInfo.environment["ENVANTER_SUPABASE_TEST_KEY"] ?? "sb_publishable_local"
    // CloudSyncIntegrationTests ile aynı patron: yeni şube kuralı (yalnızca patron yeni şube açar) her çalıştırmada sağlanır
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

    private func expectMemberError(_ kind: CloudMemberError.Kind, _ message: String? = nil, file: StaticString = #filePath, line: UInt = #line,
                                   _ f: () async throws -> Void) async {
        do {
            try await f()
            XCTFail("\(kind) hatası bekleniyordu", file: file, line: line)
        } catch let e as CloudMemberError {
            XCTAssertEqual(e.kind, kind, e.message, file: file, line: line)
            if let message { XCTAssertEqual(e.message, message, file: file, line: line) }
        } catch {
            XCTFail("beklenmeyen hata: \(error)", file: file, line: line)
        }
    }

    func testOwnerManagesAccountsThroughRealSupabase() async throws {
        let run = "\(Int(Date().timeIntervalSince1970))\(Int.random(in: 100...999))"
        let username = "kasa1-\(run)"
        let email = try XCTUnwrap(LoginName.email(from: username))
        XCTAssertEqual(email, "\(username)@envanter.local")

        // --- Patron ve şube
        let owner = try api()
        do { _ = try await owner.signUp(email: ownerEmail, password: ownerPassword) } catch {
            _ = try await owner.signIn(email: ownerEmail, password: ownerPassword)
        }
        let currentOwner = await owner.currentSession
        let ownerSession = try XCTUnwrap(currentOwner)
        let ownerID = try XCTUnwrap(JWTClaims.subject(ownerSession.accessToken))
        if let id = ownerSession.userID { XCTAssertEqual(ownerID, id) }
        let wsName = "Mac Kullanıcılar Testi \(run)"
        let wsID: String
        do {
            wsID = try await owner.createWorkspace(name: wsName)
        } catch CloudSyncError.forbidden(let m) {
            return XCTFail("Şube açılamadı (\(m)). Yerel veritabanında başka patronların şubeleri var; "
                + "envantersite/db-tests/run.sh ortamı boşaltır.")
        }

        // --- Kullanıcı adıyla hesap: e-posta gerekmez
        let created = try await owner.createAccount(workspace: wsID, email: username, password: "Gecici-sifre-1", role: CloudRole.staff)
        XCTAssertEqual(created, .created)
        let staff = try api()
        let staffSession = try await staff.signIn(email: " \(username.uppercased()) ", password: "Gecici-sifre-1")
        XCTAssertEqual(staffSession.email, email)
        XCTAssertEqual(LoginName.display(staffSession.email ?? ""), username)
        let staffID = try XCTUnwrap(staffSession.userID)
        XCTAssertEqual(JWTClaims.subject(staffSession.accessToken), staffID)
        let staffWorkspaces = try await staff.myWorkspaces()
        XCTAssertEqual(staffWorkspaces.first { $0.id == wsID }?.role, CloudRole.staff)

        // --- Üye listesi (Postgres zaman damgaları çözülür) ve panel kuralları
        var list = try await owner.membersList(workspace: wsID)
        let row = try XCTUnwrap(list.first { $0.email == email })
        XCTAssertEqual(row.userID, staffID)
        XCTAssertEqual(row.role, CloudRole.staff)
        XCTAssertFalse(row.pending)
        XCTAssertTrue(row.canSetPassword)
        XCTAssertEqual(row.displayName, username)
        XCTAssertLessThan(abs(try XCTUnwrap(row.addedAt).timeIntervalSinceNow), 600)
        let ownerRow = try XCTUnwrap(list.first { $0.userID == ownerID })
        XCTAssertEqual(ownerRow.role, CloudRole.owner)
        XCTAssertTrue(CloudMembers.isLastOwner(ownerRow, in: list))
        XCTAssertEqual(CloudMembers.passwordPermission(ownerRow, myRole: CloudRole.owner, myUserID: ownerID).reason, CloudMembers.passwordSelfReason)
        XCTAssertEqual(CloudMembers.passwordPermission(row, myRole: CloudRole.owner, myUserID: ownerID), PasswordPermission(can: true, reason: nil))
        XCTAssertEqual(CloudMembers.accountError(username, members: list),
                       "Bu kişi zaten şubenin üyesi (Personel). Yetkisini üyeler listesinden değiştirin.")

        // --- Zaten üye: aynı yetkiyle 'member' (şifreye dokunulmaz), farklı yetkiyle 23505
        let same = try await owner.createAccount(workspace: wsID, email: email, password: "Baska-sifre-99", role: CloudRole.staff)
        XCTAssertEqual(same, .member)
        await expectMemberError(.alreadyMember, "Bu kişi zaten şubenin üyesi (Personel). Yetkisini üyeler listesinden değiştirin.") {
            _ = try await owner.createAccount(workspace: wsID, email: email, password: "Baska-sifre-99", role: CloudRole.manager)
        }
        _ = try await api().signIn(email: username, password: "Gecici-sifre-1")
        // Şifre kuralı (22023)
        await expectMemberError(.invalid, "Şifre en az 8 karakter olmalıdır.") {
            _ = try await owner.createAccount(workspace: wsID, email: "kasa2-\(run)", password: "kisa", role: CloudRole.staff)
        }

        // --- Yetki değişikliği; son patron korunur (P0001); patron olmayan hesap açamaz (42501)
        try await owner.setRole(workspace: wsID, user: staffID, role: CloudRole.manager)
        let promoted = try await staff.myWorkspaces()
        XCTAssertEqual(promoted.first { $0.id == wsID }?.role, CloudRole.manager)
        await expectMemberError(.lastOwner) { try await owner.setRole(workspace: wsID, user: ownerID, role: CloudRole.staff) }
        await expectMemberError(.lastOwner) { try await owner.removeMember(workspace: wsID, user: ownerID) }
        await expectMemberError(.forbidden) {
            _ = try await staff.createAccount(workspace: wsID, email: "kasa3-\(run)", password: "Gecici-sifre-1", role: CloudRole.staff)
        }
        await expectMemberError(.invalid) { try await owner.setMemberPassword(workspace: wsID, user: ownerID, password: "Yeni-sifre-12") }

        // --- Şifre belirleme: eski şifre geçmez, yenisi geçer, eski oturum yenilenemez
        try await owner.setMemberPassword(workspace: wsID, user: staffID, password: "Yeni-sifre-12")
        do {
            _ = try await api().signIn(email: username, password: "Gecici-sifre-1")
            XCTFail("eski şifre kabul edildi")
        } catch {
            XCTAssertEqual(error as? CloudSyncError, .invalidCredentials)
            XCTAssertEqual(error.localizedDescription, "E-posta ya da şifre yanlış.")
        }
        let renewed = try api()
        _ = try await renewed.signIn(email: username, password: "Yeni-sifre-12")
        do { _ = try await staff.refresh(); XCTFail("eski oturum yenilendi") } catch {
            XCTAssertEqual(error as? CloudSyncError, .sessionExpired)
        }

        // --- Şubeden çıkarma: erişim hemen kesilir
        try await owner.removeMember(workspace: wsID, user: staffID)
        let removed = try await renewed.myWorkspaces()
        XCTAssertEqual(removed, [])
        list = try await owner.membersList(workspace: wsID)
        XCTAssertFalse(list.contains { $0.email == email })

        // --- Onaylı hesap yeniden eklenir: 'member', şifresi değişmez
        let back = try await owner.createAccount(workspace: wsID, email: username, password: "Hic-kullanilmayan-1", role: CloudRole.staff)
        XCTAssertEqual(back, .member)
        let backSession = try api()
        _ = try await backSession.signIn(email: username, password: "Yeni-sifre-12")
        let backWorkspaces = try await backSession.myWorkspaces()
        XCTAssertEqual(backWorkspaces.first { $0.id == wsID }?.role, CloudRole.staff)

        // --- Bekleyen davet listede görünür, iptal edilir
        let inviteEmail = "davet-\(run)@macsync.envanter"
        let invited = try await owner.invite(workspace: wsID, email: inviteEmail, role: CloudRole.manager)
        XCTAssertEqual(invited, "invited")
        list = try await owner.membersList(workspace: wsID)
        let pending = try XCTUnwrap(list.first { $0.email == inviteEmail })
        XCTAssertTrue(pending.pending)
        XCTAssertNil(pending.userID)
        XCTAssertEqual(pending.role, CloudRole.manager)
        XCTAssertEqual(CloudMembers.memberPermissions(pending, in: list, myRole: CloudRole.owner).canRemove, true)
        try await owner.cancelInvite(workspace: wsID, email: inviteEmail)
        list = try await owner.membersList(workspace: wsID)
        XCTAssertFalse(list.contains { $0.email == inviteEmail })

        // --- Değişiklik geçmişi (key = members)
        let rows = try await owner.activity(workspace: wsID, limit: 100).filter { $0.key == "members" }.map(\.summary)
        XCTAssertTrue(rows.contains("Hesap oluşturuldu: \(email) (Personel)"), "\(rows)")
        XCTAssertTrue(rows.contains("Yetki değişti: \(email) (Personel → Müdür)"), "\(rows)")
        XCTAssertTrue(rows.contains { $0.hasPrefix("Şifre belirlendi: \(email)") }, "\(rows)")
        XCTAssertTrue(rows.contains("Şubeden çıkarıldı: \(email) (Müdür)"), "\(rows)")
        XCTAssertTrue(rows.contains("Mevcut hesap şubeye eklendi: \(email) (Personel)"), "\(rows)")

        // --- Erişim anahtarı önceden yenilenir; yeni yenileme anahtarı gözlemciye hemen bildirilir
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var _tokens: [String?] = []
            var tokens: [String?] { lock.lock(); defer { lock.unlock() }; return _tokens }
            func add(_ t: String?) { lock.lock(); _tokens.append(t); lock.unlock() }
        }
        let box = Box()
        await owner.setSessionObserver { box.add($0?.refreshToken) }
        let current = await owner.currentSession
        let before = try XCTUnwrap(current)
        let unchanged = try await owner.validAccessToken()
        XCTAssertEqual(unchanged, before.accessToken)
        await owner.setSession(AuthSession(accessToken: before.accessToken, refreshToken: before.refreshToken,
                                           expiresAt: Date().addingTimeInterval(30), userID: before.userID, email: before.email))
        let rotated = try await owner.validAccessToken()
        let currentAfter = await owner.currentSession
        let after = try XCTUnwrap(currentAfter)
        XCTAssertEqual(rotated, after.accessToken)
        XCTAssertNotEqual(after.refreshToken, before.refreshToken)
        XCTAssertEqual(box.tokens, [after.refreshToken])
        XCTAssertEqual(JWTClaims.subject(rotated), ownerID)
    }
}
