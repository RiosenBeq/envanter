import Foundation

// Kullanıcılar paneli (Mac: Ekip → Kullanıcılar; web: Yönetim → Kullanıcılar) için sunucu işlemleri. Hepsi yalnızca
// patron (owner) içindir; kurallar ve hata kodları docs/SYNC.md §2. Kurallara takılan istekler `CloudMemberError`
// (sunucunun Türkçe metniyle), oturum / ağ / kurulum hataları `CloudSyncError` olarak döner.

/// Kullanıcı yönetimi işlemleri (testlerde sahte sunucuyla değiştirilebilir)
public protocol CloudMembersAPI: AnyObject, Sendable {
    func membersList(workspace: String) async throws -> [CloudMember]
    func createAccount(workspace: String, email: String, password: String, role: String) async throws -> CreateAccountResult
    func setRole(workspace: String, user: String, role: String) async throws
    func setMemberPassword(workspace: String, user: String, password: String) async throws
    func removeMember(workspace: String, user: String) async throws
    func invite(workspace: String, email: String, role: String) async throws -> String
    func cancelInvite(workspace: String, email: String) async throws
}

extension SupabaseAPI: CloudMembersAPI {
    /// Üyeler ve bekleyen davetler (davetleri yalnızca patron görür)
    public func membersList(workspace: String) async throws -> [CloudMember] {
        let r = try await memberRPC("envanter_members_list", ["p_workspace": .string(workspace)])
        do { return try JSONCoding.decoder().decode([CloudMember].self, from: r.body) } catch {
            throw CloudSyncError.invalidResponse("envanter_members_list")
        }
    }

    /// E-posta gerektirmeden hesap açar ve şubeye ekler. `email`: e-posta ya da kullanıcı adı (kullanıcı adı
    /// `ad@envanter.local` e-postasına çevrilir, `LoginName`). Şifre `PasswordRule` kuralına uymalı (sunucu da denetler).
    public func createAccount(workspace: String, email: String, password: String, role: String) async throws -> CreateAccountResult {
        let login = LoginName.email(from: email) ?? email.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = try await memberRPC("envanter_create_account", [
            "p_workspace": .string(workspace), "p_email": .string(login), "p_password": .string(password), "p_role": .string(role),
        ])
        let v = try? JSONCoding.parse(r.body)
        guard let text = v?.stringValue ?? v?.arrayValue?.first?.stringValue, let result = CreateAccountResult(rawValue: text) else {
            throw CloudSyncError.invalidResponse("envanter_create_account")
        }
        return result
    }

    /// Üyenin yetkisini değiştirir (son patron düşürülemez: `CloudMemberError.lastOwner`)
    public func setRole(workspace: String, user: String, role: String) async throws {
        _ = try await memberRPC("envanter_set_role", ["p_workspace": .string(workspace), "p_user": .string(user), "p_role": .string(role)])
    }

    /// Üyenin şifresini belirler: eski şifre hemen geçmez, açık oturumları en geç 1 saat içinde kapanır
    public func setMemberPassword(workspace: String, user: String, password: String) async throws {
        _ = try await memberRPC("envanter_set_member_password",
                                ["p_workspace": .string(workspace), "p_user": .string(user), "p_password": .string(password)])
    }

    /// Üyeyi şubeden çıkarır (son patron çıkarılamaz); erişimi hemen kesilir
    public func removeMember(workspace: String, user: String) async throws {
        _ = try await memberRPC("envanter_remove_member", ["p_workspace": .string(workspace), "p_user": .string(user)])
    }

    /// Bekleyen daveti iptal eder (davetin "çıkarılması")
    public func cancelInvite(workspace: String, email: String) async throws {
        _ = try await memberRPC("envanter_cancel_invite", ["p_workspace": .string(workspace), "p_email": .string(email)])
    }

    private func memberRPC(_ name: String, _ params: [String: JSONValue]) async throws -> SyncResponse {
        try await authorized("POST", url("rest/v1/rpc/\(name)"), body: .object(params), validate: Self.checkMember)
    }

    /// Üyelik kurallarının SQLSTATE kodları (23505, 22023, 42501, P0001 …) `CloudMemberError`; diğerleri olağan eşleme
    static func checkMember(_ r: SyncResponse) throws {
        if !(200..<300).contains(r.status) {
            let e = ServerError(r.body)
            if let m = CloudMemberError(code: e.code, message: e.message, hint: e.hint) { throw m }
        }
        try check(r)
    }
}
