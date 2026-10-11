import XCTest
@testable import EnvanterCore

/// Kullanıcı adıyla giriş, ekip kimliği, şifre kuralı ve Kullanıcılar panelinin kuralları (web ile aynı vektörler)
final class AccountsTests: XCTestCase {
    private func vectors() throws -> JSONValue {
        guard let url = Bundle.module.url(forResource: "Fixtures/account-vectors", withExtension: "json") else {
            throw XCTSkip("account-vectors.json fikstürü yok")
        }
        return try JSONCoding.parse(Data(contentsOf: url))
    }

    // MARK: - Ortak vektörler (envantersite: test/fixtures/account-vectors.json)

    func testAccountVectors() throws {
        let v = try vectors()
        let login = try XCTUnwrap(v["loginEmail"]?.arrayValue)
        let display = try XCTUnwrap(v["loginDisplay"]?.arrayValue)
        let team = try XCTUnwrap(v["teamID"]?.arrayValue)
        XCTAssertEqual(login.count, 13)
        XCTAssertEqual(display.count, 3)
        XCTAssertEqual(team.count, 8)
        for row in login {
            let input = try XCTUnwrap(row["input"]?.stringValue)
            XCTAssertEqual(LoginName.email(from: input), row["email"]?.stringValue, "loginEmail(\(input))")
        }
        for row in display {
            let email = try XCTUnwrap(row["email"]?.stringValue)
            XCTAssertEqual(LoginName.display(email), row["display"]?.stringValue, "loginDisplay(\(email))")
        }
        for row in team {
            let name = try XCTUnwrap(row["name"]?.stringValue)
            XCTAssertEqual(TeamID.id(for: name, taken: []), row["id"]?.stringValue, "teamID(\(name))")
        }
    }

    // MARK: - Metin katlama

    func testTextFold() {
        XCTAssertEqual(TextFold.ascii("Ayşe Yılmaz"), "ayse yilmaz")
        XCTAssertEqual(TextFold.ascii("ÇĞİIÖŞÜ çğıiöşü"), "cgiiosu cgiiosu")
        XCTAssertEqual(TextFold.ascii("José Ñandú"), "jose nandu")
        // Ayrıştırılmış (NFD) girdi de aynı sonucu verir
        XCTAssertEqual(TextFold.ascii("c\u{327}ag\u{306}ri I\u{307}"), "cagri i")
        // Yalnızca A–Z küçültülür; ASCII dışı harfler olduğu gibi kalır
        XCTAssertEqual(TextFold.ascii("ΑΒΓ ß"), "ΑΒΓ ß")
        XCTAssertEqual(TextFold.asciiLowercased("ALİ@Isletme.COM"), "alİ@isletme.com")
    }

    func testLoginNameHelpers() {
        XCTAssertEqual(LoginName.email(from: " . ali .. veli . "), "ali.veli@envanter.local")
        XCTAssertEqual(LoginName.email(from: "Kasa\t2"), "kasa.2@envanter.local")
        XCTAssertNil(LoginName.email(from: "   "))
        XCTAssertNil(LoginName.email(from: "..."))
        XCTAssertEqual(LoginName.email(from: " Selin@Ornek.COM "), "selin@ornek.com")
        XCTAssertTrue(LoginName.isUsername(" ahmet "))
        XCTAssertFalse(LoginName.isUsername("ahmet@isletme.com"))
        XCTAssertFalse(LoginName.isUsername("  "))
        XCTAssertTrue(LoginName.isUsernameEmail("kasa_1@Envanter.Local"))
        XCTAssertFalse(LoginName.isUsernameEmail("kasa@envanter.local.com"))
        XCTAssertEqual(LoginName.display("kasa_1@envanter.local"), "kasa_1")
        // Kullanıcı adı → e-posta → ekrandaki ad
        XCTAssertEqual(LoginName.email(from: "Çağrı Öz").map(LoginName.display), "cagri.oz")
    }

    func testTeamIDCollisions() {
        XCTAssertEqual(TeamID.slug("  Ayşe  Yılmaz (Kasa) "), "ayse-yilmaz-kasa")
        XCTAssertEqual(TeamID.slug("___"), "")
        XCTAssertEqual(TeamID.id(for: "Ahmet", taken: ["staff-ahmet"]), "staff-ahmet-2")
        XCTAssertEqual(TeamID.id(for: "AHMET", taken: ["staff-ahmet", "staff-ahmet-2"]), "staff-ahmet-3")
        XCTAssertEqual(TeamID.id(for: "Ahmet", taken: ["staff-ahmet-2"]), "staff-ahmet")
        XCTAssertNil(TeamID.id(for: "  ", taken: []))
        // settings.staff sırasıyla: dönen kimlik alınmışlara eklenir
        var taken: Set<String> = ["staff-ali"]
        var ids: [String] = []
        for name in ["Ali", "ALİ", "Veli"] {
            if let id = TeamID.id(for: name, taken: taken) { ids.append(id); taken.insert(id) }
        }
        XCTAssertEqual(ids, ["staff-ali-2", "staff-ali-3", "staff-veli"])
    }

    // MARK: - Şifre

    func testPasswordRule() {
        XCTAssertEqual(PasswordRule.error(""), "Şifre yazın ya da “Güçlü şifre üret”e basın.")
        XCTAssertEqual(PasswordRule.error("1234567"), "Şifre en az 8 karakter olmalı.")
        XCTAssertNil(PasswordRule.error("12345678"))
        XCTAssertNil(PasswordRule.error("şşşşşşşş"))                       // 8 karakter, 16 bayt
        XCTAssertNil(PasswordRule.error(String(repeating: "a", count: 72)))
        XCTAssertEqual(PasswordRule.error(String(repeating: "a", count: 73)),
                       "Şifre en fazla 72 bayt olabilir (Türkçe harfler 2 bayt sayılır); daha kısa bir şifre seçin.")
        XCTAssertNotNil(PasswordRule.error(String(repeating: "ş", count: 37)))  // 37 karakter, 74 bayt
        XCTAssertEqual(PasswordRule.advice("abcdefgh"), "Daha güçlü olması için harf ve rakam karıştırın.")
        XCTAssertEqual(PasswordRule.advice("12345678"), "Daha güçlü olması için harf ve rakam karıştırın.")
        XCTAssertNil(PasswordRule.advice("abcd1234"))
        XCTAssertNil(PasswordRule.advice("abc"))                            // kural hatası varken öneri yok
    }

    func testGeneratedPasswords() {
        for _ in 0..<50 {
            let p = PasswordRule.generate()
            XCTAssertEqual(p.count, 12)
            XCTAssertNil(PasswordRule.error(p))
            XCTAssertNil(PasswordRule.advice(p))
            XCTAssertTrue(p.contains { PasswordRule.lowercase.contains($0) })
            XCTAssertTrue(p.contains { PasswordRule.uppercase.contains($0) })
            XCTAssertTrue(p.contains { PasswordRule.digits.contains($0) })
            XCTAssertFalse(p.contains { "0O1lIi".contains($0) })
        }
        // Belirlenimci üreteçle: her zaman ilk eleman seçilir, karıştırma yer değiştirmez
        XCTAssertEqual(PasswordRule.generate(length: 5, random: { _ in 0 }).sorted(), Array("2Aaaa").sorted())
    }

    // MARK: - Üyeler

    func testMemberDecodingIsLenientAndReadsPostgresDates() throws {
        let json = #"""
        [{"user_id":"u1","email":"patron@ornek.com","role":"owner","added_at":"2026-10-09T12:00:00.123456+00:00","pending":false,"can_set_password":false},
         {"user_id":"u2","email":"kasa_1@envanter.local","role":"staff","added_at":"2026-10-09T15:30:00+03:00","pending":false,"can_set_password":true},
         {"user_id":null,"email":"davet@ornek.com","role":"manager","added_at":"2026-10-10 08:00:00.5+00","pending":true,"can_set_password":false},
         {"email":"eski@ornek.com","role":"admin"}]
        """#
        let members = try JSONCoding.decoder().decode([CloudMember].self, from: Data(json.utf8))
        XCTAssertEqual(members.count, 4)
        let noon = Date(timeIntervalSince1970: 1_791_547_200)      // 2026-10-09T12:00:00Z
        XCTAssertEqual(members[0].addedAt!.timeIntervalSince1970, noon.timeIntervalSince1970 + 0.123456, accuracy: 1e-6)
        XCTAssertEqual(members[1].addedAt, noon.addingTimeInterval(30 * 60))
        XCTAssertEqual(members[1].displayName, "kasa_1")
        XCTAssertTrue(members[1].canSetPassword)
        XCTAssertNil(members[2].userID)
        XCTAssertTrue(members[2].pending)
        XCTAssertEqual(members[2].id, "davet:davet@ornek.com")
        XCTAssertEqual(members[2].addedAt, Date(timeIntervalSince1970: 1_791_619_200.5))
        XCTAssertEqual(members[3], CloudMember(userID: nil, email: "eski@ornek.com", role: CloudRole.staff))
        // Kodlayıp geri okumak aynı üyeyi verir (milisaniyeye kadar)
        let back = try JSONCoding.decoder().decode([CloudMember].self, from: JSONCoding.encoder().encode(members))
        XCTAssertEqual(back.map(\.email), members.map(\.email))
        XCTAssertEqual(back[0].addedAt!.timeIntervalSince1970, members[0].addedAt!.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(back[2].userID, nil)
    }

    func testPostgresTimeParsing() {
        let base = 1_791_547_200.0
        XCTAssertEqual(PostgresTime.parse("2026-10-09T12:00:00Z")?.timeIntervalSince1970, base)
        XCTAssertEqual(PostgresTime.parse("2026-10-09T12:00:00+00:00")?.timeIntervalSince1970, base)
        XCTAssertEqual(PostgresTime.parse("2026-10-09T14:00:00+0200")?.timeIntervalSince1970, base)
        XCTAssertEqual(PostgresTime.parse("2026-10-09T08:30:00-03:30")?.timeIntervalSince1970, base)
        XCTAssertEqual(PostgresTime.parse("2026-10-09T12:00:00.1")?.timeIntervalSince1970 ?? 0, base + 0.1, accuracy: 1e-9)
        XCTAssertEqual(PostgresTime.parse("1970-01-01T00:00:00Z")?.timeIntervalSince1970, 0)
        XCTAssertEqual(PostgresTime.parse("2024-02-29T00:00:00Z")?.timeIntervalSince1970, 1_709_164_800)
        for bad in ["", "2026-10-09", "2026-13-01T00:00:00Z", "2026-10-09T12:00:00.", "2026-10-09T12:00:00+0", "2026-10-09T12:00:00 UTC"] {
            XCTAssertNil(PostgresTime.parse(bad), bad)
        }
    }

    private let owner = CloudMember(userID: "u1", email: "patron@ornek.com", role: CloudRole.owner)
    private let manager = CloudMember(userID: "u2", email: "mudur@ornek.com", role: CloudRole.manager, canSetPassword: true)
    private let invite = CloudMember(userID: nil, email: "davet@ornek.com", role: CloudRole.owner, pending: true)

    func testMemberPermissions() {
        let members = [owner, manager, invite]
        XCTAssertEqual(CloudMembers.ownerCount(members), 1)                // davet sayılmaz
        XCTAssertTrue(CloudMembers.isLastOwner(owner, in: members))
        XCTAssertFalse(CloudMembers.isLastOwner(invite, in: members))
        XCTAssertEqual(CloudMembers.memberPermissions(owner, in: members, myRole: CloudRole.owner),
                       MemberPermissions(canChangeRole: false, canRemove: false, reason: "Şubenin son patronu: önce başka bir üyeyi patron yapın."))
        XCTAssertEqual(CloudMembers.memberPermissions(manager, in: members, myRole: CloudRole.owner),
                       MemberPermissions(canChangeRole: true, canRemove: true, reason: nil))
        XCTAssertEqual(CloudMembers.memberPermissions(invite, in: members, myRole: CloudRole.owner),
                       MemberPermissions(canChangeRole: true, canRemove: true, reason: nil))
        XCTAssertEqual(CloudMembers.memberPermissions(manager, in: members, myRole: CloudRole.manager),
                       MemberPermissions(canChangeRole: false, canRemove: false, reason: "Bu işlemi yalnızca patron yapabilir."))
        // İki patron varken patron da düşürülebilir
        var second = manager
        second.role = CloudRole.owner
        XCTAssertTrue(CloudMembers.memberPermissions(owner, in: [owner, second], myRole: CloudRole.owner).canRemove)
    }

    func testPasswordPermission() {
        XCTAssertEqual(CloudMembers.passwordPermission(manager, myRole: CloudRole.owner, myUserID: "u1"), PasswordPermission(can: true, reason: nil))
        XCTAssertEqual(CloudMembers.passwordPermission(manager, myRole: CloudRole.manager, myUserID: "u2").reason, CloudMembers.ownerOnlyReason)
        XCTAssertEqual(CloudMembers.passwordPermission(invite, myRole: CloudRole.owner, myUserID: "u1").reason,
                       "Davet edilen kişinin henüz hesabı yok; “Hesap oluştur” ile hesabını açın.")
        XCTAssertEqual(CloudMembers.passwordPermission(owner, myRole: CloudRole.owner, myUserID: "u1").reason,
                       "Kendi şifrenizi Ayarlar → Hesap → Şifremi değiştir bölümünden değiştirin.")
        var otherOwner = owner
        otherOwner.userID = "u9"
        XCTAssertEqual(CloudMembers.passwordPermission(otherOwner, myRole: CloudRole.owner, myUserID: "u1").reason, CloudMembers.passwordOwnerReason)
        var foreign = manager
        foreign.canSetPassword = false
        XCTAssertEqual(CloudMembers.passwordPermission(foreign, myRole: CloudRole.owner, myUserID: "u1").reason, CloudMembers.passwordForeignReason)
    }

    func testRoleChangeConfirmAndSorting() {
        XCTAssertFalse(CloudMembers.roleChangeNeedsConfirm(manager, to: CloudRole.manager, myUserID: "u1"))
        XCTAssertTrue(CloudMembers.roleChangeNeedsConfirm(manager, to: CloudRole.owner, myUserID: "u1"))
        XCTAssertFalse(CloudMembers.roleChangeNeedsConfirm(manager, to: CloudRole.staff, myUserID: "u1"))
        XCTAssertTrue(CloudMembers.roleChangeNeedsConfirm(owner, to: CloudRole.manager, myUserID: "u1"))   // kendi yetkisi
        let staffA = CloudMember(userID: "u3", email: "ayse@ornek.com", role: CloudRole.staff)
        let staffC = CloudMember(userID: "u4", email: "çağrı@ornek.com", role: CloudRole.staff)
        let staffD = CloudMember(userID: "u5", email: "deniz@ornek.com", role: CloudRole.staff)
        let sorted = CloudMembers.sorted([invite, staffD, staffC, manager, staffA, owner])
        XCTAssertEqual(sorted.map(\.id), ["u1", "u2", "u3", "u4", "u5", "davet:davet@ornek.com"])
    }

    func testAccountFormErrors() {
        let members = [owner, manager, invite]
        XCTAssertEqual(CloudMembers.accountError("  ", members: members), "Kullanıcı adı ya da e-posta yazın.")
        XCTAssertNotNil(CloudMembers.accountError("!!!", members: members))
        XCTAssertEqual(CloudMembers.accountError("ali@isletme", members: members), "Geçerli bir e-posta adresi yazın (ör. ad@isletme.com).")
        XCTAssertEqual(CloudMembers.accountError("Mudur@Ornek.com", members: members),
                       "Bu kişi zaten şubenin üyesi (Müdür). Yetkisini üyeler listesinden değiştirin.")
        XCTAssertNil(CloudMembers.accountError("davet@ornek.com", members: members))      // bekleyen davet: hesap açılabilir
        XCTAssertNil(CloudMembers.accountError("Kasa 1", members: members))
        XCTAssertTrue(CloudMembers.isValidEmail("a@b.co"))
        XCTAssertFalse(CloudMembers.isValidEmail("a@b."))
        XCTAssertFalse(CloudMembers.isValidEmail("a@.b"))
        XCTAssertFalse(CloudMembers.isValidEmail("a b@c.de"))
        XCTAssertFalse(CloudMembers.isValidEmail("a@b@c.de"))
        XCTAssertTrue(CloudMembers.isValidEmail("kasa_1@envanter.local"))
    }

    func testMemberErrorMapping() {
        XCTAssertEqual(CloudMemberError(code: "23505", message: "Bu kullanıcı zaten bu şubenin üyesi (rolü: manager).",
                                        hint: "Rolünü değiştirmek için üyeler listesindeki yetki düzenlemeyi kullanın."),
                       CloudMemberError(kind: .alreadyMember, message: "Bu kişi zaten şubenin üyesi (Müdür). Yetkisini üyeler listesinden değiştirin."))
        XCTAssertEqual(CloudMemberError(code: "23505", message: "")?.message,
                       "Bu kişi zaten şubenin üyesi (farklı yetkiyle). Yetkisini üyeler listesinden değiştirin.")
        XCTAssertEqual(CloudMemberError(code: "P0001", message: "Şubenin son patronu (owner) çıkarılamaz.", hint: "Önce başka bir üyeyi patron yapın."),
                       CloudMemberError(kind: .lastOwner, message: "Şubenin son patronu (owner) çıkarılamaz. Önce başka bir üyeyi patron yapın."))
        XCTAssertEqual(CloudMemberError(code: "22023", message: "Şifre en az 8 karakter olmalıdır.")?.kind, .invalid)
        XCTAssertEqual(CloudMemberError(code: "22P02", message: "invalid input syntax for type uuid")?.kind, .invalid)
        XCTAssertEqual(CloudMemberError(code: "42501", message: "")?.localizedDescription, "Bu işlemi yalnızca patron yapabilir.")
        XCTAssertNil(CloudMemberError(code: "PGRST202", message: "x"))
        XCTAssertNil(CloudMemberError(code: "", message: "x"))
    }
}
