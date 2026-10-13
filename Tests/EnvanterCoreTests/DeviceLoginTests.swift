import Foundation
import XCTest
@testable import EnvanterCore

/// Bağlantı koduyla bağlanan bilgisayarın cihaz hesabı: tek kullanımlık kod (şifre değiştirme), kayıtlı şifrelerle sessiz
/// giriş, durum dosyası ve çevrimiçi bilgisi
final class DeviceLoginTests: XCTestCase {
    let code = "7KQ2M9XP4TRAHW3D"
    let email = "pc-7kq2m9@envanter.local"

    private func session(_ token: String = "A1", expires: Date? = Date().addingTimeInterval(3600)) -> AuthSession {
        AuthSession(accessToken: token, refreshToken: "R1", expiresAt: expires, email: email)
    }

    // MARK: - Şifre değiştirme

    func testRotationKeepsTheRightPasswords() {
        let rotating = DeviceLogin.rotating(email: email, newPassword: "yeni-Sifre_1", code: code)
        XCTAssertEqual(rotating.passwords, ["yeni-Sifre_1", code])
        XCTAssertEqual(rotating.after(.applied).passwords, ["yeni-Sifre_1"])
        XCTAssertEqual(rotating.after(.rejected).passwords, [code])
        XCTAssertEqual(rotating.after(.unknown), rotating)
        // Tek şifrede değişiklik yok
        let single = DeviceLogin(email: email, passwords: ["p"])
        XCTAssertEqual(single.after(.applied), single)
        XCTAssertEqual(single.after(.rejected), single)

        XCTAssertEqual(PasswordChangeOutcome(error: CloudSyncError.network("timeout")), .unknown)
        XCTAssertEqual(PasswordChangeOutcome(error: CloudSyncError.server(status: 502, message: "")), .unknown)
        XCTAssertEqual(PasswordChangeOutcome(error: CloudSyncError.invalidResponse("x")), .unknown)
        XCTAssertEqual(PasswordChangeOutcome(error: URLError(.timedOut)), .unknown)
        XCTAssertEqual(PasswordChangeOutcome(error: CloudSyncError.invalidRequest("weak_password")), .rejected)
        XCTAssertEqual(PasswordChangeOutcome(error: CloudSyncError.sessionExpired), .rejected)
        XCTAssertEqual(PasswordChangeOutcome(error: CloudSyncError.rateLimited), .rejected)
        XCTAssertEqual(PasswordChangeOutcome(error: CloudSyncError.forbidden("")), .rejected)
    }

    func testDevicePasswordShape() {
        var seen = Set<String>()
        for _ in 0..<200 {
            let p = DevicePassword.generate()
            let u = Array(p.unicodeScalars)
            XCTAssertEqual(u.count, 32)
            XCTAssertTrue(u.contains { ("a"..."z").contains($0) }, p)
            XCTAssertTrue(u.contains { ("A"..."Z").contains($0) }, p)
            XCTAssertTrue(u.contains { ("0"..."9").contains($0) }, p)
            XCTAssertEqual(u.filter { "-_.".unicodeScalars.contains($0) }.count, 1, p)
            XCTAssertTrue(u.allSatisfy { $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || "-_.".unicodeScalars.contains($0)) })
            XCTAssertNil(PasswordRule.error(p))
            seen.insert(p)
        }
        XCTAssertEqual(seen.count, 200)
        // Aynı üreteçle aynı şifre (zorunlu karakterler karıştırılır)
        var a = SequenceGenerator(values: [7, 3, 11, 5, 19, 23]), b = SequenceGenerator(values: [7, 3, 11, 5, 19, 23])
        XCTAssertEqual(DevicePassword.generate(using: &a), DevicePassword.generate(using: &b))
    }

    func testUpdatePasswordRequest() async throws {
        let t = MockTransport { _ in .json(200, #"{"id":"u1","email":"pc-7kq2m9@envanter.local"}"#) }
        let api = try SupabaseAPI(url: "https://p.supabase.co", publishableKey: "pk", session: session(), transport: t)
        try await api.updatePassword("Yeni.sifre-32")
        let req = try XCTUnwrap(t.requests.first)
        XCTAssertEqual(req.method, "PUT")
        XCTAssertEqual(req.url.absoluteString, "https://p.supabase.co/auth/v1/user")
        XCTAssertEqual(req.headers["apikey"], "pk")
        XCTAssertEqual(req.headers["Authorization"], "Bearer A1")
        XCTAssertEqual(req.headers["Content-Type"], "application/json")
        XCTAssertEqual(req.jsonBody, j(#"{"password":"Yeni.sifre-32"}"#))
        // Kesin ret (ör. şifre kuralı) ve bilinmeyen sonuç
        t.handler = { _ in .json(422, #"{"code":422,"error_code":"weak_password","msg":"Password should contain at least one character of each"}"#) }
        do { try await api.updatePassword("x"); XCTFail("hata bekleniyordu") } catch {
            XCTAssertEqual(error as? CloudSyncError, .invalidRequest("Password should contain at least one character of each"))
            XCTAssertEqual(PasswordChangeOutcome(error: error), .rejected)
        }
        t.handler = { _ in throw URLError(.networkConnectionLost) }
        do { try await api.updatePassword("x"); XCTFail("hata bekleniyordu") } catch {
            XCTAssertEqual(PasswordChangeOutcome(error: error), .unknown)
        }
        // Oturum yoksa istek gönderilmez: kod geçerli kalır
        let none = try SupabaseAPI(url: "https://p.supabase.co", publishableKey: "pk", transport: t)
        let before = t.requests.count
        do { try await none.updatePassword("x"); XCTFail("hata bekleniyordu") } catch {
            XCTAssertEqual(error as? CloudSyncError, .sessionExpired)
            XCTAssertEqual(PasswordChangeOutcome(error: error), .rejected)
        }
        XCTAssertEqual(t.requests.count, before)
    }

    // MARK: - Sessiz giriş

    /// Denenen şifreler (sahte giriş)
    private final class Attempts: @unchecked Sendable {
        private let lock = NSLock()
        private var _list: [String] = []
        var list: [String] { lock.lock(); defer { lock.unlock() }; return _list }
        func add(_ p: String) { lock.lock(); _list.append(p); lock.unlock() }
    }

    func testSilentSignInTriesPasswordsInOrder() async {
        let s = session(), code = self.code, email = self.email
        // Şifre değiştirme sonucu bilinmiyordu ve sunucuda uygulanmamış: önce yeni şifre (yanlış), sonra kod
        let tried = Attempts()
        let r1 = await DeviceSignIn.attempt(DeviceLogin(email: email, passwords: ["yeni", code])) { e, p in
            tried.add(p)
            XCTAssertEqual(e, email)
            if p == "yeni" { throw CloudSyncError.invalidCredentials }
            return s
        }
        XCTAssertEqual(tried.list, ["yeni", code])
        XCTAssertEqual(r1.session, s)
        XCTAssertEqual(r1.password, code)
        XCTAssertNil(r1.error)
        XCTAssertEqual(r1.login, DeviceLogin(email: email, passwords: [code]))
        XCTAssertTrue(r1.needsNewPassword, "kod hâlâ şifre: yeni şifre verilmeli")

        // Sunucuda uygulanmış: ilk şifre geçer, kod denenmez
        let tried2 = Attempts()
        let r2 = await DeviceSignIn.attempt(DeviceLogin(email: email, passwords: ["yeni", code])) { _, p in tried2.add(p); return s }
        XCTAssertEqual(tried2.list, ["yeni"])
        XCTAssertEqual(r2.login?.passwords, ["yeni"])
        XCTAssertFalse(r2.needsNewPassword)

        // Bağlantı yok: ilk hatada durulur, kayıt olduğu gibi kalır (sonra yeniden denenir)
        let tried3 = Attempts()
        let login = DeviceLogin(email: email, passwords: ["yeni", code])
        let r3 = await DeviceSignIn.attempt(login) { _, p in tried3.add(p); throw URLError(.notConnectedToInternet) }
        XCTAssertEqual(tried3.list, ["yeni"])
        XCTAssertNil(r3.session)
        guard case .network? = r3.error else { return XCTFail("\(String(describing: r3.error))") }
        XCTAssertEqual(r3.login, login)
        let r3b = await DeviceSignIn.attempt(login) { _, _ in throw CloudSyncError.rateLimited }
        XCTAssertEqual(r3b.error, .rateLimited)
        XCTAssertEqual(r3b.login, login)

        // Hepsi kesin olarak reddedildi (bağlantı kaldırıldı): kayıt silinir; aynı şifre bir kez denenir
        let tried4 = Attempts()
        let r4 = await DeviceSignIn.attempt(DeviceLogin(email: email, passwords: [code, code])) { _, p in
            tried4.add(p); throw CloudSyncError.invalidCredentials
        }
        XCTAssertEqual(tried4.list, [code])
        XCTAssertEqual(r4.error, .invalidCredentials)
        XCTAssertNil(r4.login)
        let r5 = await DeviceSignIn.attempt(DeviceLogin(email: email, passwords: [])) { _, _ in s }
        XCTAssertEqual(r5.error, .invalidCredentials)
        XCTAssertNil(r5.login)
    }

    func testSilentSignInEligibility() {
        let login = DeviceLogin(email: email, passwords: ["yeni"])
        var s = SyncState(config: CloudConfig(workspaceID: "w1", workspaceName: "Tuzla", email: email, role: CloudRole.manager),
                          accessToken: "A", refreshToken: "R", initialized: true, deviceLogin: login)
        // Oturum açıkken gerekmez
        XCTAssertNil(s.silentSignIn)
        XCTAssertNil(s.reconnectableDevice)
        // Oturum süresi doldu: sessizce girilir
        s.store(nil)
        XCTAssertEqual(s.silentSignIn, login)
        XCTAssertEqual(s.reconnectableDevice, login)
        // E-posta büyük/küçük harf farkı önemsiz; başka hesabın kaydıyla girilmez
        s.config?.email = "PC-7KQ2M9@envanter.local"
        XCTAssertEqual(s.silentSignIn, login)
        s.config?.email = "ayse@envanter.local"
        XCTAssertNil(s.silentSignIn)
        XCTAssertNil(s.reconnectableDevice)
        s.config?.email = email
        // Çıkış yapıldı: kayıt korunur, sessiz giriş yok, "Yeniden Bağlan" var
        s.signOut()
        XCTAssertEqual(s.deviceLogin, login)
        XCTAssertNil(s.silentSignIn)
        XCTAssertEqual(s.reconnectableDevice, login)
        // Aynı sunucuya yeniden girişte kayıt korunur, farklı sunucuda yeni durum başlar
        XCTAssertEqual(SyncState.forSignIn(existing: s, url: CloudDefaults.url, publishableKey: "k", email: email).deviceLogin, login)
        XCTAssertNil(SyncState.forSignIn(existing: s, url: "https://baska.supabase.co", publishableKey: "k", email: email).deviceLogin)
        // Şube eşleşmesi yokken sessiz giriş yok
        var unlinked = SyncState(config: CloudConfig(email: email), deviceLogin: login)
        XCTAssertNil(unlinked.silentSignIn)
        XCTAssertEqual(unlinked.reconnectableDevice, login)
        unlinked.deviceLogin = DeviceLogin(email: email, passwords: [])
        XCTAssertNil(unlinked.reconnectableDevice)
    }

    /// Kullanılmış kod yeniden yazıldı (ya da bağlantı yeniden açıldı): önce kayıtlı şifreler denenir, kod reddedildi
    /// diye kayıt silinmez; kayıt yalnızca kayıtlı şifrelerin hepsi denenip reddedilince silinir
    func testReusedCodeTriesSavedPasswordsAndKeepsRecord() async {
        let saved = DeviceLogin(email: email, passwords: ["Kayitli.sifre-1"])
        var s = SyncState(config: CloudConfig(workspaceID: "w1", workspaceName: "Tuzla", email: email, role: CloudRole.manager),
                          initialized: true, signedOut: true, deviceLogin: saved)
        // Aynı kod, aynı sunucu (sondaki "/" ve büyük harf fark etmez): önce kayıtlı şifre, sonra kod
        XCTAssertEqual(s.devicePasswords(forCode: code, url: CloudDefaults.url), ["Kayitli.sifre-1", code])
        XCTAssertEqual(s.devicePasswords(forCode: code, url: CloudDefaults.url.uppercased() + "/"), ["Kayitli.sifre-1", code])
        // Başka sunucu ya da başka kod (başka cihaz hesabı): yalnızca kod
        XCTAssertEqual(s.devicePasswords(forCode: code, url: "https://baska.supabase.co"), [code])
        XCTAssertEqual(s.devicePasswords(forCode: "AB2CD3EF4GH5JK6M", url: CloudDefaults.url), ["AB2CD3EF4GH5JK6M"])
        // Kayıtta kod da varsa iki kez denenmez
        s.deviceLogin = DeviceLogin(email: email, passwords: ["yeni", code])
        XCTAssertEqual(s.devicePasswords(forCode: code, url: CloudDefaults.url), ["yeni", code])
        s.deviceLogin = saved

        // Yalnızca kod ya da yanlış bir şifre reddedildi: kayıt korunur
        XCTAssertFalse(s.shouldForgetDeviceLogin(email: email, tried: [code], url: CloudDefaults.url))
        XCTAssertFalse(s.shouldForgetDeviceLogin(email: email, tried: ["yanlis"], url: CloudDefaults.url))
        // Kayıtlı şifrelerin hepsi reddedildi (bağlantı kaldırıldı): kayıt silinir; e-posta büyük/küçük harf fark etmez
        XCTAssertTrue(s.shouldForgetDeviceLogin(email: email, tried: ["Kayitli.sifre-1", code], url: CloudDefaults.url))
        XCTAssertTrue(s.shouldForgetDeviceLogin(email: "PC-7KQ2M9@envanter.local", tried: ["Kayitli.sifre-1"], url: CloudDefaults.url + "/"))
        // Başka sunucuda ya da başka hesapla reddedilmesi bu kaydı etkilemez
        XCTAssertFalse(s.shouldForgetDeviceLogin(email: email, tried: ["Kayitli.sifre-1"], url: "https://baska.supabase.co"))
        XCTAssertFalse(s.shouldForgetDeviceLogin(email: "pc-ab2cd3@envanter.local", tried: ["Kayitli.sifre-1"], url: CloudDefaults.url))
        s.deviceLogin = nil
        XCTAssertFalse(s.shouldForgetDeviceLogin(email: email, tried: [code], url: CloudDefaults.url))
        s.deviceLogin = saved

        // Girişte: kayıtlı şifre geçer, kod denenmez ve yeni şifre gerekmez
        let tried = Attempts(), session = self.session(), stored = "Kayitli.sifre-1"
        let ok = await DeviceSignIn.attempt(DeviceLogin(email: email, passwords: s.devicePasswords(forCode: code, url: CloudDefaults.url))) { _, p in
            tried.add(p)
            if p == stored { return session }
            throw CloudSyncError.invalidCredentials
        }
        XCTAssertEqual(tried.list, [stored])
        XCTAssertEqual(ok.login?.passwords, [stored])
        XCTAssertFalse(ok.needsNewPassword)
    }

    /// İlk bağlantı kararından ya da şube seçiminden vazgeçilince (oturum açık, şube eşleşmesi yok) "Yeniden Bağlan"
    /// görünür: kod kullanıldı, kayıtlı şifreyle yeniden bağlanılır
    func testReconnectAfterCancelledDecisionOrPicker() {
        let login = DeviceLogin(email: email, passwords: ["yeni"])
        // Karardan vazgeçildi: oturum açık, şube yok
        let cancelled = SyncState(config: CloudConfig(email: email), accessToken: "A", refreshToken: "R", deviceLogin: login)
        XCTAssertTrue(cancelled.isSignedIn)
        XCTAssertEqual(cancelled.reconnectableDevice, login)
        XCTAssertNil(cancelled.silentSignIn, "şube eşleşmesi yokken sessiz giriş yok")
        // Başka şubeyle eşleşmiş Mac'te şube seçiminden vazgeçildi: oturum açık, çıkış yapılmış sayılır
        let dismissed = SyncState(config: CloudConfig(workspaceID: "w1", workspaceName: "Tuzla", email: email),
                                  accessToken: "A", refreshToken: "R", initialized: true, signedOut: true, deviceLogin: login)
        XCTAssertEqual(dismissed.reconnectableDevice, login)
        XCTAssertNil(dismissed.silentSignIn)
        // Karar bekleniyor (şube seçildi, ilk karar verilmedi): eşitlenmiyor
        let pending = SyncState(config: CloudConfig(workspaceID: "w2", email: email), accessToken: "A", refreshToken: "R", deviceLogin: login)
        XCTAssertEqual(pending.reconnectableDevice, login)
        // Eşitlenirken yok
        var active = dismissed
        active.signedOut = false
        XCTAssertTrue(active.isActive)
        XCTAssertNil(active.reconnectableDevice)
    }

    /// Bağlıyken yarım kalan şifre değiştirmenin sıradaki adımı ve sessiz girişin yeniden deneme beklemesi
    func testRotationRetryAndSilentSignInBackoff() {
        XCTAssertEqual(DeviceLogin(email: email, passwords: ["Yeni.sifre-32"]).rotationRetry, .notNeeded)
        XCTAssertNil(DeviceLogin(email: email, passwords: ["Yeni.sifre-32"]).codePassword)
        XCTAssertEqual(DeviceLogin(email: email, passwords: [code]).rotationRetry, .rotate(code: code))
        let unknown = DeviceLogin.rotating(email: email, newPassword: DevicePassword.generate(), code: code)
        XCTAssertEqual(unknown.codePassword, code)
        XCTAssertEqual(unknown.rotationRetry, .verify)
        XCTAssertEqual(unknown.after(.applied).rotationRetry, .notNeeded)
        XCTAssertEqual(unknown.after(.rejected).rotationRetry, .rotate(code: code))
        XCTAssertEqual(DeviceLogin(email: email, passwords: []).rotationRetry, .notNeeded)
        XCTAssertGreaterThan(DeviceLogin.rotationRetrySeconds, CloudDefaults.intervalSeconds)

        // Bağlantı yok: bir sonraki düzenli turda
        XCTAssertEqual(DeviceSignIn.retryDelay(after: .network("offline"), failures: 1), 0)
        XCTAssertEqual(DeviceSignIn.retryDelay(after: .network("offline"), failures: 7), 0)
        // Sunucu hatası: 1 dk, 2 dk, 4 dk … en fazla 30 dk
        XCTAssertEqual(DeviceSignIn.retryDelay(after: .server(status: 502, message: ""), failures: 1), 60)
        XCTAssertEqual(DeviceSignIn.retryDelay(after: .server(status: 503, message: ""), failures: 2), 120)
        XCTAssertEqual(DeviceSignIn.retryDelay(after: .invalidResponse("x"), failures: 3), 240)
        XCTAssertEqual(DeviceSignIn.retryDelay(after: .server(status: 500, message: ""), failures: 6), 1800)
        XCTAssertEqual(DeviceSignIn.retryDelay(after: .server(status: 500, message: ""), failures: 1000), 1800)
        XCTAssertEqual(DeviceSignIn.retryDelay(after: .server(status: 500, message: ""), failures: 0), 60)
        // Çok fazla deneme (429): 5 dk, 10 dk, 20 dk, 30 dk
        XCTAssertEqual(DeviceSignIn.retryDelay(after: .rateLimited, failures: 1), 300)
        XCTAssertEqual(DeviceSignIn.retryDelay(after: .rateLimited, failures: 2), 600)
        XCTAssertEqual(DeviceSignIn.retryDelay(after: .rateLimited, failures: 3), 1200)
        XCTAssertEqual(DeviceSignIn.retryDelay(after: .rateLimited, failures: 4), 1800)
        // Kesin hatalar kendiliğinden yeniden denenmez ("Yeniden Bağlan")
        XCTAssertNil(DeviceSignIn.retryDelay(after: .invalidCredentials, failures: 1))
        XCTAssertNil(DeviceSignIn.retryDelay(after: .invalidRequest("user_banned"), failures: 1))
        XCTAssertNil(DeviceSignIn.retryDelay(after: .emailNotConfirmed, failures: 1))
        XCTAssertGreaterThan(DeviceSignIn.cooldownAfterSuccess, CloudDefaults.intervalSeconds)
    }

    // MARK: - Durum dosyası

    func testSyncStateStoresDeviceLoginAndReadsOldFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("envanter-device-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SyncStore(directory: dir)
        let state = SyncState(config: CloudConfig(workspaceID: "w1", email: email), accessToken: "A", refreshToken: "R",
                              initialized: true, deviceLogin: DeviceLogin(email: email, passwords: ["yeni", code]))
        try store.save(state)
        XCTAssertEqual(store.load(), state)
        let raw = try JSONCoding.parse(Data(contentsOf: store.file))
        XCTAssertEqual(raw["deviceLogin"], j(#"{"email":"pc-7kq2m9@envanter.local","passwords":["yeni","7KQ2M9XP4TRAHW3D"]}"#))
        // Eski sürümün dosyası (alan yok) okunur
        let old = #"{"config":{"url":"https://p.supabase.co","publishableKey":"k","workspaceID":"w1","workspaceName":"Tuzla","email":"ayse@envanter.local","role":"staff"},"lastRev":12,"base":{},"dirty":["items"],"accessToken":"A","refreshToken":"R","initialized":true,"signedOut":false}"#
        let decoded = try SyncStore.decoder().decode(SyncState.self, from: Data(old.utf8))
        XCTAssertNil(decoded.deviceLogin)
        XCTAssertEqual(decoded.lastRev, 12)
        XCTAssertEqual(decoded.dirty, ["items"])
        XCTAssertEqual(decoded.config?.role, CloudRole.staff)
        try Data(old.utf8).write(to: store.file)
        XCTAssertEqual(store.load().config?.workspaceName, "Tuzla")
        XCTAssertNil(store.load().deviceLogin)
    }

    // MARK: - Çevrimiçi bilgisi ve "Bugün" kartı

    func testPresenceSendsDeviceOnlyForDeviceAccounts() {
        let since = Date(timeIntervalSince1970: 1_791_547_200)
        let m = RealtimePresence.mac(branch: "Tuzla", app: "2.1", since: since, device: PairCode.deviceName(forEmail: email))
        XCTAssertEqual(m["device"], .string("pc-7kq2m9"))
        XCTAssertEqual(m["client"], .string("mac"))
        let person = RealtimePresence.mac(branch: "Tuzla", app: "2.1", since: since,
                                          device: PairCode.deviceName(forEmail: "ayse.yilmaz@envanter.local"))
        XCTAssertNil(person["device"])
        XCTAssertEqual(person, RealtimePresence.mac(branch: "Tuzla", app: "2.1", since: since))
    }

    func testDaySteps() {
        var s = DaySteps(hasSales: false, counted: 0, total: 21, closed: false)
        XCTAssertEqual(s.next, .sales)
        XCTAssertEqual(s.countText, "0/21")
        s.hasSales = true
        XCTAssertTrue(s.isDone(.sales))
        XCTAssertEqual(s.next, .count)
        s.counted = 14
        XCTAssertFalse(s.isDone(.count))
        XCTAssertEqual(s.countText, "14/21")
        s.counted = 21
        XCTAssertTrue(s.isDone(.count))
        XCTAssertEqual(s.next, .close)
        s.closed = true
        XCTAssertTrue(s.isDone(.close))
        XCTAssertNil(s.next)
        // Kapatılmış günde sıradaki adım yok; stok kalemi yoksa sayım tamam sayılmaz
        XCTAssertNil(DaySteps(hasSales: false, counted: 3, total: 21, closed: true).next)
        XCTAssertFalse(DaySteps(hasSales: true, counted: 0, total: 0, closed: false).isDone(.count))
        XCTAssertEqual(DaySteps.Step.allCases.map(\.rawValue), [1, 2, 3])
    }
}
