import Foundation

// Bağlantı koduyla bağlanan bilgisayarın cihaz hesabı (PairCode.swift): kod tek kullanımlıktır. Bilgisayar kodla giriş
// yapınca hesaba kendi ürettiği rastgele bir şifre verir (PUT auth/v1/user); kod bir daha geçmez. Şifre hiçbir yerde
// gösterilmez ve günlüğe yazılmaz; oturum süresi dolarsa (ya da çıkış yapıldıktan sonra "Yeniden Bağlan"da) bu kayıtla
// sessizce yeniden girilir. Kayıt esitleme.json'da (0600) oturum anahtarlarıyla birlikte durur.

/// Cihaz hesabının giriş adı ve denenecek şifreleri (sırayla)
public struct DeviceLogin: Codable, Equatable, Sendable {
    public var email: String
    /// Denenecek şifreler, sırayla. Şifre değiştirme isteğinin sonucu bilinmiyorsa iki tane: önce yeni şifre, sonra kod.
    public var passwords: [String]

    public init(email: String, passwords: [String]) {
        self.email = email
        self.passwords = passwords
    }

    /// Kodla girişten sonra, şifre değiştirme isteği gönderilmeden önce saklanacak hal: önce yeni şifre, sonra kod
    public static func rotating(email: String, newPassword: String, code: String) -> DeviceLogin {
        DeviceLogin(email: email, passwords: [newPassword, code])
    }

    /// Şifre değiştirme isteğinin sonucuna göre saklanacak hal: kabul edildiyse yalnızca yeni şifre, kesin olarak
    /// reddedildiyse yalnızca kod (eski şifre), sonuç bilinmiyorsa ikisi de (sırayla denenir)
    public func after(_ outcome: PasswordChangeOutcome) -> DeviceLogin {
        guard passwords.count > 1, let fresh = passwords.first, let old = passwords.last else { return self }
        switch outcome {
        case .applied: return DeviceLogin(email: email, passwords: [fresh])
        case .rejected: return DeviceLogin(email: email, passwords: [old])
        case .unknown: return self
        }
    }

    /// Kayıttaki kod biçimindeki şifre (bağlantı kodu): varsa hesabın şifresi hâlâ kod olabilir (şifre değiştirme isteği
    /// reddedildi ya da sonucu bilinmiyor). Bilgisayarın ürettiği şifre hiçbir zaman kod biçiminde değildir.
    public var codePassword: String? { passwords.first(where: PairCode.isCode) }

    /// Bağlıyken yarım kalan şifre değiştirmenin sıradaki adımı (kod tek kullanımlık kalsın diye yeniden denenir)
    public var rotationRetry: RotationRetry {
        guard let code = codePassword else { return .notNeeded }
        // Birden çok şifre: önceki isteğin sonucu bilinmiyor; hangisinin geçtiği önce girişle denenir
        return passwords.count > 1 ? .verify : .rotate(code: code)
    }

    /// Bağlıyken şifre değiştirme yeniden denenmeden önce beklenen süre (saniye)
    public static let rotationRetrySeconds: TimeInterval = 300
}

/// Bağlıyken yarım kalan şifre değiştirmenin sıradaki adımı
public enum RotationRetry: Equatable, Sendable {
    /// Şifre değişmiş (kayıtta kod yok): yapılacak bir şey yok
    case notNeeded
    /// Hangi şifrenin geçtiği bilinmiyor ([yeni, kod]): kayıtlı şifrelerle giriş denenir, geçen şifre saklanır; geçen
    /// şifre kodsa yeni şifre verilir
    case verify
    /// Şifre hâlâ kod: yeni şifre verilir
    case rotate(code: String)
}

/// Cihaz hesabının şifresini değiştirme isteğinin sonucu
public enum PasswordChangeOutcome: Equatable, Sendable {
    /// Sunucu yeni şifreyi kabul etti
    case applied
    /// Sunucu kesin bir hata yanıtı verdi (ya da istek hiç gönderilmedi): eski şifre geçerli
    case rejected
    /// Sonuç bilinmiyor (ağ hatası, sunucu hatası, beklenmeyen yanıt): sunucuda uygulanmış olabilir
    case unknown

    /// İsteğin hatasından sonuç
    public init(error: Error) {
        guard let e = error as? CloudSyncError else { self = .unknown; return }
        switch e {
        case .network, .server, .invalidResponse: self = .unknown
        default: self = .rejected
        }
    }
}

/// Cihaz hesabına verilen rastgele şifre: 32 karakter; küçük harf, büyük harf, rakam ve bir tane - _ . karakteri
/// içerir (Supabase'in en sıkı şifre kuralı da kabul eder). Kişiye gösterilmez.
public enum DevicePassword {
    public static let length = 32
    public static let symbols = "-_."

    public static func generate() -> String {
        var g = SystemRandomNumberGenerator()
        return generate(using: &g)
    }

    public static func generate<G: RandomNumberGenerator>(using generator: inout G) -> String {
        let lower = Array("abcdefghijklmnopqrstuvwxyz"), upper = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let digits = Array("0123456789"), symbol = Array(symbols)
        let all = lower + upper + digits
        var chars: [Character] = []
        for set in [lower, upper, digits, symbol] { chars.append(set[Int.random(in: 0..<set.count, using: &generator)]) }
        while chars.count < length { chars.append(all[Int.random(in: 0..<all.count, using: &generator)]) }
        chars.shuffle(using: &generator)
        return String(chars)
    }
}

/// Kayıtlı şifrelerle giriş (bağlantı kodu, "Yeniden Bağlan" ve oturum süresi dolunca sessiz giriş)
public enum DeviceSignIn {
    public struct Result: Sendable {
        /// Başarılı girişin oturumu (başarısızsa nil)
        public var session: AuthSession?
        /// Girişte kullanılan şifre (başarısızsa nil)
        public var password: String?
        /// Başarısızlığın nedeni
        public var error: CloudSyncError?
        /// Saklanacak kayıt: başarılıysa yalnızca geçen şifre; ağ / sunucu hatasında kayıt olduğu gibi; şifrelerin hepsi
        /// kesin olarak reddedildiyse nil (kayıt silinir, yeni bağlantı kodu gerekir)
        public var login: DeviceLogin?

        /// Geçen şifre hâlâ bağlantı kodu: hesaba yeni şifre verilmeli (kod tek kullanımlık)
        public var needsNewPassword: Bool { password.map(PairCode.isCode) ?? false }
    }

    /// Şifreleri sırayla dener: ilk başarılı girişte durur; şifre yanlışsa sıradakine geçer; başka bir hatada (bağlantı,
    /// sunucu, çok fazla deneme) durur ve kayda dokunmaz.
    public static func attempt(_ login: DeviceLogin,
                               signIn: @Sendable (_ email: String, _ password: String) async throws -> AuthSession) async -> Result {
        var tried = Set<String>()
        for password in login.passwords where !tried.contains(password) {
            tried.insert(password)
            do {
                let session = try await signIn(login.email, password)
                return Result(session: session, password: password, error: nil,
                              login: DeviceLogin(email: login.email, passwords: [password]))
            } catch let e as CloudSyncError {
                if e == .invalidCredentials { continue }
                return Result(session: nil, password: nil, error: e, login: login)
            } catch {
                return Result(session: nil, password: nil, error: .network(error.localizedDescription), login: login)
            }
        }
        return Result(session: nil, password: nil, error: .invalidCredentials, login: nil)
    }

    /// Sessiz giriş geçici bir hatayla başarısız olunca kendiliğinden yeniden denemeden önce beklenecek süre (saniye);
    /// nil: kendiliğinden yeniden denenmez (kartta hata ve "Yeniden Bağlan" görünür). `failures`: art arda başarısız
    /// deneme sayısı (1'den başlar). Bağlantı yok: bir sonraki düzenli turda (ya da uygulama öne gelince). Sunucu hatası
    /// ya da beklenmeyen yanıt: 1 dk'dan başlayıp her denemede ikiye katlanır; çok fazla deneme (429): 5 dk'dan başlar.
    /// İkisi de en fazla `maxRetrySeconds`.
    public static func retryDelay(after error: CloudSyncError, failures: Int) -> TimeInterval? {
        let doublings = min(max(failures, 1) - 1, 10)
        func backoff(_ base: TimeInterval) -> TimeInterval { min(base * Double(1 << doublings), maxRetrySeconds) }
        switch error {
        case .network: return 0
        case .server, .invalidResponse: return backoff(60)
        case .rateLimited: return backoff(300)
        default: return nil
        }
    }

    /// Kendiliğinden yeniden denemeler arasındaki en uzun bekleme (saniye)
    public static let maxRetrySeconds: TimeInterval = 1800

    /// Başarılı sessiz girişten sonra, yeni oturumla bir eşitleme başarılı olmadan önce bir sonraki sessiz giriş için
    /// beklenecek süre (saniye): sunucu yeni oturumu hemen reddediyorsa (ör. yanlış yapılandırılmış sunucu) giriş
    /// döngüye girmesin
    public static let cooldownAfterSuccess: TimeInterval = 300
}

extension SyncState {
    /// Oturumun süresi dolunca sessizce yeniden girilecek cihaz hesabı: bilgisayar bağlantı koduyla bağlanmış, şubeyle
    /// eşleşmiş, oturum yok, çıkış yapılmamış ve kayıt bağlı hesabın. nil: "Giriş gerekli" gösterilir.
    public var silentSignIn: DeviceLogin? {
        guard let login = reconnectableDevice, config?.workspaceID != nil, initialized, !signedOut else { return nil }
        return login
    }

    /// Tek tıkla ("Yeniden Bağlan") yeniden bağlanılabilecek cihaz hesabı: bu Mac bir şubeyle eşitlenmiyor (oturum
    /// yok, çıkış yapıldı, ilk bağlantı kararından ya da şube seçiminden vazgeçildi) ve kayıt bağlı hesabın. Bağlıyken
    /// nil.
    public var reconnectableDevice: DeviceLogin? {
        guard let login = deviceLogin, !login.passwords.isEmpty, !isActive, let c = config,
              TextFold.asciiLowercased(login.email) == TextFold.asciiLowercased(c.email) else { return nil }
        return login
    }

    /// Bağlantı koduyla girişte denenecek şifreler: kod bu Mac'in kayıtlı cihaz hesabınınsa (aynı hesap, aynı sunucu)
    /// önce kayıtlı şifreler, sonra kod. Kullanılmış kod yeniden yazılınca (ya da bağlantı yeniden açılınca) bilgisayar
    /// kayıtlı şifresiyle girer; kod reddedildi diye kayıt silinmez.
    public func devicePasswords(forCode code: String, url: String) -> [String] {
        let password = PairCode.password(code)
        guard let stored = storedDeviceLogin(email: PairCode.email(code), url: url) else { return [password] }
        var out: [String] = []
        for p in stored.passwords + [password] where !out.contains(p) { out.append(p) }
        return out
    }

    /// Giriş reddedildikten sonra cihaz kaydı silinsin mi: kayıt bu hesabın, bu sunucunun ve kayıtlı şifrelerin hepsi
    /// denenip reddedildi (bağlantı web panelinden kaldırıldı). Başka bir şifre ya da kullanılmış kod reddedildiyse
    /// kayıt korunur ("Yeniden Bağlan" ve sessiz giriş çalışmaya devam eder).
    public func shouldForgetDeviceLogin(email: String, tried: [String], url: String) -> Bool {
        guard let stored = storedDeviceLogin(email: email, url: url) else { return false }
        return Set(stored.passwords).isSubset(of: Set(tried))
    }

    /// Bu hesabın (büyük/küçük harf fark etmez) bu sunucudaki cihaz kaydı
    private func storedDeviceLogin(email: String, url: String) -> DeviceLogin? {
        guard let stored = deviceLogin, let c = config, CloudDefaults.sameServer(c.url, url),
              TextFold.asciiLowercased(stored.email) == TextFold.asciiLowercased(email) else { return nil }
        return stored
    }
}
