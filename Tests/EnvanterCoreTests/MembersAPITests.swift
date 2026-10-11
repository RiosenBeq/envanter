import Foundation
import XCTest
@testable import EnvanterCore

/// Kullanıcı yönetimi istekleri, hata eşlemesi, oturum gözlemcisi ve erişim anahtarı (sahte taşıyıcı)
final class MembersAPITests: XCTestCase {
    let ws = "11111111-1111-1111-1111-111111111111"
    let user = "22222222-2222-2222-2222-222222222222"

    private func session(_ token: String = "A1", expires: Date? = Date().addingTimeInterval(3600)) -> AuthSession {
        AuthSession(accessToken: token, refreshToken: "R1", expiresAt: expires, email: "patron@ornek.com")
    }

    private func api(_ t: MockTransport, session s: AuthSession? = nil) throws -> SupabaseAPI {
        try SupabaseAPI(url: "https://p.supabase.co", publishableKey: "pk", session: s ?? session(), transport: t)
    }

    /// base64url yüklü sahte JWT
    private func jwt(_ payload: String) -> String {
        let b = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJIUzI1NiJ9.\(b).imza"
    }

    // MARK: - İstekler

    func testMembersListRequestAndDecoding() async throws {
        let t = MockTransport { _ in
            .json(200, #"""
            [{"user_id":"u1","email":"patron@ornek.com","role":"owner","added_at":"2026-10-09T12:00:00.123456+00:00","pending":false,"can_set_password":false},
             {"user_id":"u2","email":"kasa_1@envanter.local","role":"staff","added_at":"2026-10-10T08:15:30+00:00","pending":false,"can_set_password":true},
             {"user_id":null,"email":"davet@ornek.com","role":"manager","added_at":"2026-10-11T06:00:00.5+00:00","pending":true,"can_set_password":false}]
            """#)
        }
        let members = try await api(t).membersList(workspace: ws)
        let req = t.requests[0]
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.url.absoluteString, "https://p.supabase.co/rest/v1/rpc/envanter_members_list")
        XCTAssertEqual(req.headers["apikey"], "pk")
        XCTAssertEqual(req.headers["Authorization"], "Bearer A1")
        XCTAssertEqual(req.headers["Content-Type"], "application/json")
        XCTAssertEqual(req.jsonBody, j(#"{"p_workspace":"\#(ws)"}"#))
        XCTAssertEqual(members.map(\.id), ["u1", "u2", "davet:davet@ornek.com"])
        XCTAssertEqual(members[0].addedAt!.timeIntervalSince1970, 1_791_547_200.123456, accuracy: 1e-5)
        XCTAssertEqual(members[1], CloudMember(userID: "u2", email: "kasa_1@envanter.local", role: CloudRole.staff,
                                               addedAt: Date(timeIntervalSince1970: 1_791_620_130), canSetPassword: true))
        XCTAssertEqual(members[1].displayName, "kasa_1")
        XCTAssertTrue(members[2].pending)
        XCTAssertNil(members[2].userID)
        XCTAssertEqual(members[2].addedAt, Date(timeIntervalSince1970: 1_791_698_400.5))
        // Dizi değilse beklenmeyen yanıt
        t.handler = { _ in .json(200, #"{"x":1}"#) }
        do { _ = try await api(t).membersList(workspace: ws); XCTFail() } catch {
            XCTAssertEqual(error as? CloudSyncError, .invalidResponse("envanter_members_list"))
        }
    }

    func testCreateAccountRequestMapsUsername() async throws {
        let t = MockTransport { _ in .json(200, #""created""#) }
        let a = try api(t)
        let created = try await a.createAccount(workspace: ws, email: " Kasa 1 ", password: "Gecici-sifre-1", role: CloudRole.staff)
        XCTAssertEqual(created, .created)
        let req = t.requests[0]
        XCTAssertEqual(req.url.path, "/rest/v1/rpc/envanter_create_account")
        XCTAssertEqual(req.headers["Authorization"], "Bearer A1")
        XCTAssertEqual(req.jsonBody, j(#"{"p_workspace":"\#(ws)","p_email":"kasa.1@envanter.local","p_password":"Gecici-sifre-1","p_role":"staff"}"#))
        // E-posta küçük harfe iner
        t.handler = { _ in .json(200, #"["member"]"#) }
        let member = try await a.createAccount(workspace: ws, email: "Ali@Isletme.com", password: "x", role: CloudRole.manager)
        XCTAssertEqual(member, .member)
        XCTAssertEqual(t.requests[1].jsonBody?["p_email"], .string("ali@isletme.com"))
        t.handler = { _ in .json(200, #""unconfirmed""#) }
        let unconfirmed = try await a.createAccount(workspace: ws, email: "yeni@ornek.com", password: "Gecici-sifre-1", role: CloudRole.staff)
        XCTAssertEqual(unconfirmed, .unconfirmed)
        t.handler = { _ in .json(200, #""invited""#) }
        do { _ = try await a.createAccount(workspace: ws, email: "x@y.z", password: "Gecici-sifre-1", role: CloudRole.staff); XCTFail() } catch {
            XCTAssertEqual(error as? CloudSyncError, .invalidResponse("envanter_create_account"))
        }
    }

    func testVoidMemberRPCs() async throws {
        let t = MockTransport { req in req.url.path.hasSuffix("envanter_remove_member") ? .json(204, "") : .json(200, "null") }
        let a = try api(t)
        try await a.setRole(workspace: ws, user: user, role: CloudRole.manager)
        try await a.setMemberPassword(workspace: ws, user: user, password: "Yeni-sifre-12")
        try await a.removeMember(workspace: ws, user: user)
        try await a.cancelInvite(workspace: ws, email: "davet@ornek.com")
        XCTAssertEqual(t.requests.map(\.url.path), ["/rest/v1/rpc/envanter_set_role", "/rest/v1/rpc/envanter_set_member_password",
                                                    "/rest/v1/rpc/envanter_remove_member", "/rest/v1/rpc/envanter_cancel_invite"])
        XCTAssertTrue(t.requests.allSatisfy { $0.method == "POST" && $0.headers["Authorization"] == "Bearer A1" && $0.headers["apikey"] == "pk" })
        XCTAssertEqual(t.requests[0].jsonBody, j(#"{"p_workspace":"\#(ws)","p_user":"\#(user)","p_role":"manager"}"#))
        XCTAssertEqual(t.requests[1].jsonBody, j(#"{"p_workspace":"\#(ws)","p_user":"\#(user)","p_password":"Yeni-sifre-12"}"#))
        XCTAssertEqual(t.requests[2].jsonBody, j(#"{"p_workspace":"\#(ws)","p_user":"\#(user)"}"#))
        XCTAssertEqual(t.requests[3].jsonBody, j(#"{"p_workspace":"\#(ws)","p_email":"davet@ornek.com"}"#))
        // Protokol üzerinden de çağrılabilir (Mac paneli sahte API ile sınanabilir)
        let members: CloudMembersAPI = a
        _ = try await members.invite(workspace: ws, email: "yeni@ornek.com", role: CloudRole.staff)
        XCTAssertEqual(t.requests.last?.url.path, "/rest/v1/rpc/envanter_invite")
    }

    func testMemberErrorsAreTurkish() async throws {
        let cases: [(Int, String, Error)] = [
            (409, #"{"code":"23505","details":null,"hint":"Rolünü değiştirmek için üyeler listesindeki yetki düzenlemeyi kullanın.","message":"Bu kullanıcı zaten bu şubenin üyesi (rolü: staff)."}"#,
             CloudMemberError(kind: .alreadyMember, message: "Bu kişi zaten şubenin üyesi (Personel). Yetkisini üyeler listesinden değiştirin.")),
            (400, #"{"code":"22023","details":null,"hint":null,"message":"Şifre en az 8 karakter olmalıdır."}"#,
             CloudMemberError(kind: .invalid, message: "Şifre en az 8 karakter olmalıdır.")),
            (400, #"{"code":"22023","message":"Geçersiz rol: \"admin\".","hint":"Rol owner (patron), manager (müdür) ya da staff (personel) olmalıdır."}"#,
             CloudMemberError(kind: .invalid, message: "Geçersiz rol: \"admin\". Rol owner (patron), manager (müdür) ya da staff (personel) olmalıdır.")),
            (403, #"{"code":"42501","message":"Bu kullanıcı başka bir patronun şubesinde de çalışıyor; şifresini yalnızca kendisi değiştirebilir.","hint":"Kişi giriş ekranındaki \"Şifremi unuttum\" bağlantısını ya da Ayarlar → Şifremi değiştir'i kullanabilir."}"#,
             CloudMemberError(kind: .forbidden, message: "Bu kullanıcı başka bir patronun şubesinde de çalışıyor; şifresini yalnızca kendisi değiştirebilir. Kişi giriş ekranındaki \"Şifremi unuttum\" bağlantısını ya da Ayarlar → Şifremi değiştir'i kullanabilir.")),
            (400, #"{"code":"P0001","message":"Şubenin son patronunun (owner) rolü değiştirilemez.","hint":"Önce başka bir üyeyi patron yapın."}"#,
             CloudMemberError(kind: .lastOwner, message: "Şubenin son patronunun (owner) rolü değiştirilemez. Önce başka bir üyeyi patron yapın.")),
            (404, #"{"code":"PGRST202","message":"Could not find the function public.envanter_set_role"}"#, CloudSyncError.notProvisioned),
            (429, #"{"message":"too many"}"#, CloudSyncError.rateLimited),
            (503, "Service Unavailable", CloudSyncError.server(status: 503, message: "Service Unavailable")),
        ]
        for (status, body, expected) in cases {
            let a = try api(MockTransport { _ in .json(status, body) })
            do {
                try await a.setRole(workspace: ws, user: user, role: CloudRole.staff)
                XCTFail("hata bekleniyordu: \(body)")
            } catch let e as CloudMemberError {
                XCTAssertEqual(e, expected as? CloudMemberError, body)
                XCTAssertEqual(e.localizedDescription, e.message)
            } catch let e as CloudSyncError {
                XCTAssertEqual(e, expected as? CloudSyncError, body)
            }
        }
        // Belge yazmasında eşleme değişmedi (42501 → CloudSyncError.forbidden)
        let doc = try api(MockTransport { _ in .json(403, #"{"code":"42501","message":"Bu şubeye erişiminiz yok."}"#) })
        do { _ = try await doc.put(workspace: ws, key: "items", body: j("[]"), baseRev: 0, deleted: false, client: "mac", summary: nil); XCTFail() } catch {
            XCTAssertEqual(error as? CloudSyncError, .forbidden("Bu şubeye erişiminiz yok."))
        }
    }

    func testMemberRPCRefreshesExpiredToken() async throws {
        let t = MockTransport { req in
            if req.url.path == "/auth/v1/token" {
                return .json(200, #"{"access_token":"A2","refresh_token":"R2","expires_in":3600,"user":{"id":"u","email":"patron@ornek.com"}}"#)
            }
            if req.headers["Authorization"] == "Bearer A1" { return .json(401, #"{"code":"PGRST303","message":"JWT expired"}"#) }
            return .json(200, "[]")
        }
        let members = try await api(t).membersList(workspace: ws)
        XCTAssertEqual(members, [])
        XCTAssertEqual(t.requests.map(\.url.path), ["/rest/v1/rpc/envanter_members_list", "/auth/v1/token", "/rest/v1/rpc/envanter_members_list"])
        XCTAssertEqual(t.requests[2].headers["Authorization"], "Bearer A2")
    }

    // MARK: - Giriş, oturum gözlemcisi, erişim anahtarı

    final class SessionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _seen: [AuthSession?] = []
        var seen: [AuthSession?] { lock.lock(); defer { lock.unlock() }; return _seen }
        func add(_ s: AuthSession?) { lock.lock(); _seen.append(s); lock.unlock() }
    }

    func testSignInWithUsernameAndSessionObserver() async throws {
        let t = MockTransport { req in
            if req.url.query == "grant_type=password" {
                return .json(200, #"{"access_token":"AT","expires_in":3600,"refresh_token":"RT","user":{"id":"u9","email":"kasa_1@envanter.local"}}"#)
            }
            if req.jsonBody?["refresh_token"] == .string("RT") {
                return .json(200, #"{"access_token":"AT2","expires_in":3600,"refresh_token":"RT2"}"#)
            }
            return .json(400, #"{"error_code":"refresh_token_already_used","msg":"Invalid Refresh Token: Already Used"}"#)
        }
        let a = try SupabaseAPI(url: "https://p.supabase.co", publishableKey: "pk", transport: t)
        let box = SessionBox()
        await a.setSessionObserver { box.add($0) }
        let s = try await a.signIn(email: " Kasa_1 ", password: "Gecici-sifre-1")
        XCTAssertEqual(t.requests[0].jsonBody, j(#"{"email":"kasa_1@envanter.local","password":"Gecici-sifre-1"}"#))
        XCTAssertEqual(s.email, "kasa_1@envanter.local")
        XCTAssertEqual(LoginName.display(s.email ?? ""), "kasa_1")
        // Yenileme: yeni (dönen) yenileme anahtarı gözlemciye hemen bildirilir
        let r = try await a.refresh()
        XCTAssertEqual(r.refreshToken, "RT2")
        XCTAssertEqual(r.email, "kasa_1@envanter.local")
        // Yenileme reddi → nil
        do { _ = try await a.refresh(); XCTFail() } catch { XCTAssertEqual(error as? CloudSyncError, .sessionExpired) }
        XCTAssertEqual(box.seen.map { $0?.refreshToken }, ["RT", "RT2", nil])
        // Gözlemci kaldırılabilir
        await a.setSessionObserver(nil)
        _ = try await a.signIn(email: "kasa_1", password: "x")
        XCTAssertEqual(box.seen.count, 3)
    }

    func testValidAccessToken() async throws {
        let t = MockTransport { req in
            if req.url.path == "/auth/v1/token" { return .json(200, #"{"access_token":"A2","refresh_token":"R2","expires_in":3600}"#) }
            return .json(500, "beklenmeyen")
        }
        // Süresi yeterli: istek yok
        let fresh = try api(t, session: session(expires: Date().addingTimeInterval(600)))
        let a1 = try await fresh.validAccessToken()
        XCTAssertEqual(a1, "A1")
        XCTAssertEqual(t.requests.count, 0)
        // 120 sn içinde doluyor: bir kez yenilenir (eşzamanlı istekler birleşir)
        let soon = try api(t, session: session(expires: Date().addingTimeInterval(90)))
        async let x = soon.validAccessToken()
        async let y = soon.validAccessToken()
        let (tx, ty) = try await (x, y)
        XCTAssertEqual([tx, ty], ["A2", "A2"])
        XCTAssertEqual(t.requests.count, 1)
        let after = try await soon.validAccessToken()
        XCTAssertEqual(after, "A2")
        XCTAssertEqual(t.requests.count, 1)
        // Bitiş zamanı bilinmiyorsa anahtarın exp'i kullanılır
        let token = jwt(#"{"sub":"u1","exp":\#(Int(Date().timeIntervalSince1970) + 30)}"#)
        let noExpiry = try api(t, session: AuthSession(accessToken: token, refreshToken: "R1"))
        let refreshed = try await noExpiry.validAccessToken(minValidity: 60)
        XCTAssertEqual(refreshed, "A2")
        // Oturum yok
        let none = try SupabaseAPI(url: "https://p.supabase.co", publishableKey: "pk", transport: t)
        do { _ = try await none.validAccessToken(); XCTFail() } catch { XCTAssertEqual(error as? CloudSyncError, .sessionExpired) }
    }

    func testJWTClaims() {
        let token = jwt(#"{"sub":"9f0c2b1e-0000-4000-8000-00000000000a","exp":1800000000,"email":"ayşe@ornek.com","role":"authenticated"}"#)
        XCTAssertEqual(JWTClaims.subject(token), "9f0c2b1e-0000-4000-8000-00000000000a")
        XCTAssertEqual(JWTClaims.expiry(token), Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(JWTClaims.payload(token)?["email"], .string("ayşe@ornek.com"))
        XCTAssertNil(JWTClaims.subject("gecersiz-anahtar"))
        XCTAssertNil(JWTClaims.subject("a.%%%.c"))
        XCTAssertNil(JWTClaims.subject(jwt(#"{"exp":1}"#)))
        XCTAssertNil(JWTClaims.subject(jwt(#"["dizi"]"#)))
    }
}
