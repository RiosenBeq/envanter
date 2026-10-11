import Foundation

// Hesaplar ve ekip: kullanıcı adıyla giriş (ad → ad@envanter.local), eski sayan adlarından ekip üyesi kimliği, şifre
// kuralı, şube üyeleri (envanter_members_list) ve web panelindeki Yönetim → Kullanıcılar ile aynı yetki kuralları ve
// metinler (envantersite: src/lib/accounts.ts, src/lib/password.ts, src/components/management/users/logic.ts).
// Kurallar web ile birebir; ortak test vektörleri: Tests/EnvanterCoreTests/Fixtures/account-vectors.json.

// MARK: - Metin katlama

/// Türkçe harfleri ve aksanları ASCII'ye indirger: ç ğ ı İ I ö ş ü (büyükleri dahil) → c g i i i o s u; kanonik
/// ayrıştırmadan (NFD) sonra birleşen işaretler (U+0300–U+036F) atılır ve yalnızca A–Z küçültülür. Karakter karakter
/// çalışır, yerel ayardan bağımsızdır (web: `foldAscii`). "Ayşe Yılmaz" → "ayse yilmaz", "José" → "jose".
public enum TextFold {
    public static func ascii(_ s: String) -> String {
        var mapped = String.UnicodeScalarView()
        for u in s.unicodeScalars { mapped.append(turkish(u)) }
        var out = String.UnicodeScalarView()
        for u in String(mapped).decomposedStringWithCanonicalMapping.unicodeScalars where !(0x300...0x36F).contains(u.value) {
            out.append(lowerASCII(u))
        }
        return String(out)
    }

    /// Yalnızca A–Z küçültülür (e-posta adresleri için; yerel ayardan bağımsız)
    public static func asciiLowercased(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars { out.append(lowerASCII(u)) }
        return String(out)
    }

    private static func lowerASCII(_ u: Unicode.Scalar) -> Unicode.Scalar {
        (0x41...0x5A).contains(u.value) ? Unicode.Scalar(UInt8(u.value + 32)) : u
    }

    private static func turkish(_ u: Unicode.Scalar) -> Unicode.Scalar {
        switch u {
        case "ç", "Ç": return "c"
        case "ğ", "Ğ": return "g"
        case "ı", "İ", "I": return "i"
        case "ö", "Ö": return "o"
        case "ş", "Ş": return "s"
        case "ü", "Ü": return "u"
        default: return u
        }
    }
}

// MARK: - Kullanıcı adıyla giriş

/// Giriş adı: "@" içermeyen giriş bir kullanıcı adıdır ve `<ad>@envanter.local` e-postasına çevrilir (e-posta gerekmez).
/// Giriş adının yazıldığı her yerde (Mac'te bağlanma, web'de giriş, hesap oluşturma) kullanılır.
public enum LoginName {
    public static let domain = "envanter.local"

    /// Yazılan giriş adının e-postası (boş ya da geçersiz kullanıcı adıysa nil):
    /// "ahmet" → "ahmet@envanter.local", "Ayşe Yılmaz" → "ayse.yilmaz@envanter.local", "Ali@Isletme.com" → "ali@isletme.com".
    /// E-postanın geçerliliği ayrıca denetlenir (`CloudMembers.isValidEmail`).
    public static func email(from input: String) -> String? {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if t.contains("@") { return TextFold.asciiLowercased(t) }
        var name = String.UnicodeScalarView()
        var inSpace = false
        for u in TextFold.ascii(t).unicodeScalars {
            if u.properties.isWhitespace {
                if !inSpace { name.append(".") }
                inSpace = true
                continue
            }
            inSpace = false
            if isAllowed(u) { name.append(u) }
        }
        // Art arda noktalar teke iner, baştaki/sondaki noktalar atılır
        let user = String(name).split(separator: ".").joined(separator: ".")
        return user.isEmpty ? nil : user + "@" + domain
    }

    /// Ekranda gösterilecek ad: kullanıcı adı hesaplarında "@" öncesi ("ali@envanter.local" → "ali"), diğerlerinde e-posta
    public static func display(_ email: String) -> String {
        guard isUsernameEmail(email), let at = email.lastIndex(of: "@") else { return email }
        return String(email[..<at])
    }

    /// Yazılan giriş bir kullanıcı adı mı ("@" yok): arayüz "→ ad@envanter.local" ipucunu gösterebilir
    public static func isUsername(_ input: String) -> Bool {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && !t.contains("@")
    }

    /// E-posta bir kullanıcı adı hesabının mı (…@envanter.local; gerçek posta kutusu yok, "Şifremi unuttum" çalışmaz)
    public static func isUsernameEmail(_ email: String) -> Bool {
        TextFold.asciiLowercased(email).hasSuffix("@" + domain)
    }

    private static func isAllowed(_ u: Unicode.Scalar) -> Bool {
        switch u {
        case "a"..."z", "0"..."9", ".", "_", "-": return true
        default: return false
        }
    }
}

// MARK: - Ekip üyesi kimliği

/// Eski sayan adlarından (`settings.staff`) ekip üyesine geçişte belirlenimci kimlik: Mac ve web aynı adı aynı kimliğe
/// çevirir, eşzamanlı geçişler kimliğe göre birleşir (merge3).
public enum TeamID {
    public static let prefix = "staff-"

    /// Türkçe harfler ve aksanlar ASCII'ye indirgenir, küçültülür; [a-z0-9] dışındaki karakter dizileri "-" olur,
    /// baştaki/sondaki "-" atılır: "Ayşe Yılmaz" → "ayse-yilmaz", "Mehmet (Usta)" → "mehmet-usta", "---" → "".
    public static func slug(_ name: String) -> String {
        var out = String.UnicodeScalarView()
        var gap = false
        for u in TextFold.ascii(name).unicodeScalars {
            switch u {
            case "a"..."z", "0"..."9":
                if gap && !out.isEmpty { out.append("-") }
                gap = false
                out.append(u)
            default:
                gap = true
            }
        }
        return String(out)
    }

    /// "staff-<slug>"; kimlik alınmışsa "-2", "-3" … eklenir. Slug boşsa nil (ad taşınmaz). Birden çok ad taşınırken
    /// dönen kimlik `taken`'a eklenip sıradaki ad öyle sorulmalıdır (`settings.staff` sırasıyla).
    public static func id(for name: String, taken: Set<String>) -> String? {
        let s = slug(name)
        guard !s.isEmpty else { return nil }
        let base = prefix + s
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }
}

// MARK: - Şifre kuralı

/// Patronun hesap açarken / şifre belirlerken verdiği şifrenin kuralı: sunucudaki envanter_check_password ile aynı
/// (en az 8 karakter, en fazla 72 bayt — bcrypt sınırı). Metinler web paneliyle aynı (src/lib/password.ts).
public enum PasswordRule {
    public static let minLength = 8
    public static let maxBytes = 72
    /// "Güçlü şifre üret" uzunluğu
    public static let generatedLength = 12
    /// Karışmayan karakterler: 0/O/o, 1/l/I/i yok
    public static let lowercase = "abcdefghjkmnpqrstuvwxyz"
    public static let uppercase = "ABCDEFGHJKLMNPQRSTUVWXYZ"
    public static let digits = "23456789"

    /// Kural hatası (yoksa nil)
    public static func error(_ password: String) -> String? {
        if password.isEmpty { return "Şifre yazın ya da “Güçlü şifre üret”e basın." }
        if password.unicodeScalars.count < minLength { return "Şifre en az \(minLength) karakter olmalı." }
        if password.utf8.count > maxBytes {
            return "Şifre en fazla \(maxBytes) bayt olabilir (Türkçe harfler 2 bayt sayılır); daha kısa bir şifre seçin."
        }
        return nil
    }

    /// Kurala uyan ama zayıf şifre için öneri (yalnızca harf ya da yalnızca rakam); yoksa nil
    public static func advice(_ password: String) -> String? {
        guard error(password) == nil else { return nil }
        let letter = password.unicodeScalars.contains { u in
            switch u.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
            default: return false
            }
        }
        let digit = password.unicodeScalars.contains { ("0"..."9").contains($0) }
        return letter && digit ? nil : "Daha güçlü olması için harf ve rakam karıştırın."
    }

    /// Güçlü, okunması kolay rastgele şifre: en az bir küçük harf, bir büyük harf ve bir rakam; karışan karakterler yok.
    /// `random(n)` [0, n) aralığında tam sayı döner (varsayılan: sistemin güvenli üreteci; testlerde değiştirilebilir).
    public static func generate(length: Int = generatedLength, random: (Int) -> Int = { Int.random(in: 0..<$0) }) -> String {
        let lower = Array(lowercase), upper = Array(uppercase), digit = Array(digits)
        let all = lower + upper + digit
        func pick(_ set: [Character]) -> Character { set[random(set.count)] }
        var chars = [pick(lower), pick(upper), pick(digit)]
        while chars.count < max(length, 3) { chars.append(pick(all)) }
        // Zorunlu karakterler başta kalmasın (Fisher–Yates)
        for i in stride(from: chars.count - 1, to: 0, by: -1) { chars.swapAt(i, random(i + 1)) }
        return String(chars)
    }
}

// MARK: - Şube üyeleri

/// Şubenin bir üyesi ya da bekleyen daveti (envanter_members_list satırı)
public struct CloudMember: Codable, Equatable, Identifiable, Sendable {
    /// Kullanıcı kimliği; bekleyen davette nil
    public var userID: String?
    public var email: String
    /// owner | manager | staff (`CloudRole`)
    public var role: String
    public var addedAt: Date?
    /// Bekleyen davet (hesap henüz yok); davetleri yalnızca patron görür
    public var pending: Bool
    /// Çağıran patron bu üyenin şifresini "Şifre belirle" ile belirleyebilir mi (sunucu kuralı)
    public var canSetPassword: Bool

    public init(userID: String?, email: String, role: String, addedAt: Date? = nil, pending: Bool = false, canSetPassword: Bool = false) {
        self.userID = userID; self.email = email; self.role = role; self.addedAt = addedAt
        self.pending = pending; self.canSetPassword = canSetPassword
    }

    public var id: String { userID ?? "davet:" + email.lowercased() }

    /// Ekrandaki ad (kullanıcı adı hesaplarında "@envanter.local" gösterilmez)
    public var displayName: String { LoginName.display(email) }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id", email, role, addedAt = "added_at", pending, canSetPassword = "can_set_password"
    }

    /// Hoşgörülü okuma (web: membersList): bilinmeyen rol personel sayılır, eksik alanlar varsayılanı alır;
    /// tarih Postgres biçiminde de olabilir ("2026-10-09T12:00:00.123456+00:00").
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userID = try? c.decodeIfPresent(String.self, forKey: .userID)
        email = (try? c.decodeIfPresent(String.self, forKey: .email)) ?? ""
        let r = (try? c.decodeIfPresent(String.self, forKey: .role)) ?? ""
        role = [CloudRole.owner, CloudRole.manager, CloudRole.staff].contains(r) ? r : CloudRole.staff
        addedAt = (try? c.decodeIfPresent(String.self, forKey: .addedAt)).flatMap(PostgresTime.parse)
        pending = (try? c.decodeIfPresent(Bool.self, forKey: .pending)) ?? false
        canSetPassword = (try? c.decodeIfPresent(Bool.self, forKey: .canSetPassword)) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(userID, forKey: .userID)
        try c.encode(email, forKey: .email)
        try c.encode(role, forKey: .role)
        try c.encode(addedAt.map(PostgresTime.format), forKey: .addedAt)
        try c.encode(pending, forKey: .pending)
        try c.encode(canSetPassword, forKey: .canSetPassword)
    }
}

/// envanter_create_account sonucu
public enum CreateAccountResult: String, Codable, Sendable {
    /// Hesap açıldı (ya da onaylanmamış kayıt verilen şifreyle açıldı) ve şubeye eklendi
    case created
    /// E-postası onaylı hesap zaten vardı: şubeye eklendi, şifresine dokunulmadı
    case member
    /// Hesap var ama e-postası onaylanmamış ve şifresi buradan belirlenemiyor: hiçbir şey değişmedi
    case unconfirmed
}

/// Patronun kullanıcı işlemlerinde (hesap açma, yetki, şifre belirleme, çıkarma) sunucu kuralının reddi. Mesaj
/// sunucunun Türkçe metnidir (varsa ipucuyla); web panelindeki gibi olduğu gibi gösterilir.
public struct CloudMemberError: Error, Equatable, LocalizedError, Sendable {
    public enum Kind: String, Sendable {
        /// Kişi zaten şubenin üyesi, farklı yetkiyle (23505)
        case alreadyMember
        /// Geçersiz bilgi: e-posta, rol, şifre kuralı, üye değil, kendi şifresi (22023 …)
        case invalid
        /// Yetki yok: patron değil, patron hedef, başka patronun çalışanı (42501)
        case forbidden
        /// Şubenin son patronu düşürülemez / çıkarılamaz (P0001)
        case lastOwner
    }

    public var kind: Kind
    public var message: String

    public init(kind: Kind, message: String) { self.kind = kind; self.message = message }

    public var errorDescription: String? { message }

    /// SQLSTATE'ten (yoksa nil: olağan hata eşlemesi geçerli)
    init?(code: String, message: String, hint: String = "") {
        let kind: Kind
        switch code {
        case "23505": kind = .alreadyMember
        case "42501": kind = .forbidden
        case "P0001": kind = .lastOwner
        case _ where code.hasPrefix("22") || code.hasPrefix("23"): kind = .invalid
        default: return nil
        }
        let m = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let h = hint.trimmingCharacters(in: .whitespacesAndNewlines)
        // "Bu kullanıcı zaten bu şubenin üyesi (rolü: manager)." → web panelindeki form metni
        if kind == .alreadyMember, let r = m.range(of: "(rolü: "), let end = m[r.upperBound...].firstIndex(of: ")") {
            let role = String(m[r.upperBound..<end])
            self.init(kind: kind, message: "Bu kişi zaten şubenin üyesi (\(CloudRole.title(role))). " + CloudMembers.changeRoleHint)
            return
        }
        let text: String
        if m.isEmpty {
            switch kind {
            case .alreadyMember: text = "Bu kişi zaten şubenin üyesi (farklı yetkiyle). " + CloudMembers.changeRoleHint
            case .invalid: text = "Geçersiz bilgi: e-posta, yetki ve şifreyi kontrol edin."
            case .forbidden: text = CloudMembers.ownerOnlyReason
            case .lastOwner: text = CloudMembers.lastOwnerReason
            }
        } else {
            text = h.isEmpty ? m : m + " " + h
        }
        self.init(kind: kind, message: text)
    }
}

/// Yetki işlemlerinin durumu (düğmeler kapalıysa nedeni ipucu olarak gösterilir)
public struct MemberPermissions: Equatable, Sendable {
    public var canChangeRole: Bool
    public var canRemove: Bool
    public var reason: String?

    public init(canChangeRole: Bool, canRemove: Bool, reason: String?) {
        self.canChangeRole = canChangeRole; self.canRemove = canRemove; self.reason = reason
    }
}

/// "Şifre belirle" düğmesinin durumu
public struct PasswordPermission: Equatable, Sendable {
    public var can: Bool
    public var reason: String?

    public init(can: Bool, reason: String?) { self.can = can; self.reason = reason }
}

/// Kullanıcılar panelinin saf kuralları (web: components/management/users/logic.ts). Sunucu kuralları (docs/SYNC.md §2):
/// hesap açma, şifre belirleme, davet, iptal, yetki değiştirme ve çıkarma yalnızca patron; son patron düşürülemez /
/// çıkarılamaz; şifre yalnızca patron olmayan ve yalnızca bu patronun şubelerinde çalışan üyeler için belirlenir.
public enum CloudMembers {
    public static let lastOwnerReason = "Şubenin son patronu: önce başka bir üyeyi patron yapın."
    public static let ownerOnlyReason = "Bu işlemi yalnızca patron yapabilir."
    public static let passwordSelfReason = "Kendi şifrenizi Ayarlar → Hesap → Şifremi değiştir bölümünden değiştirin."
    public static let passwordOwnerReason = "Patronların şifresi buradan belirlenemez; her patron kendi şifresini Ayarlar → Hesap → Şifremi değiştir'den değiştirir."
    public static let passwordForeignReason = "Bu kullanıcı başka bir şubede patron ya da başka bir patronun şubesinde de çalışıyor; şifresini yalnızca kendisi değiştirebilir (Ayarlar → Şifremi değiştir ya da giriş ekranındaki “Şifremi unuttum”)."
    public static let passwordPendingReason = "Davet edilen kişinin henüz hesabı yok; “Hesap oluştur” ile hesabını açın."
    static let changeRoleHint = "Yetkisini üyeler listesinden değiştirin."

    /// Şubedeki (davet değil) patron sayısı
    public static func ownerCount(_ members: [CloudMember]) -> Int {
        members.filter { !$0.pending && $0.role == CloudRole.owner }.count
    }

    /// Üye şubenin son patronu mu (yetkisi düşürülemez, çıkarılamaz)
    public static func isLastOwner(_ member: CloudMember, in members: [CloudMember]) -> Bool {
        !member.pending && member.role == CloudRole.owner && ownerCount(members) <= 1
    }

    /// Ekrandaki kullanıcının (rolü `myRole`) bu üye üzerindeki işlem yetkileri. Bekleyen davetin yetkisi aynı adrese
    /// yeni yetkiyle yeniden davet gönderilerek değiştirilir; "çıkarma" daveti iptal eder.
    public static func memberPermissions(_ member: CloudMember, in members: [CloudMember], myRole: String?) -> MemberPermissions {
        guard myRole == CloudRole.owner else { return MemberPermissions(canChangeRole: false, canRemove: false, reason: ownerOnlyReason) }
        if member.pending { return MemberPermissions(canChangeRole: true, canRemove: true, reason: nil) }
        if isLastOwner(member, in: members) { return MemberPermissions(canChangeRole: false, canRemove: false, reason: lastOwnerReason) }
        return MemberPermissions(canChangeRole: true, canRemove: true, reason: nil)
    }

    /// "Şifre belirle" düğmesi: sunucu kuralı üye listesindeki `canSetPassword` ile gelir; burada yalnızca kapalı
    /// düğmenin açıklaması seçilir.
    public static func passwordPermission(_ member: CloudMember, myRole: String?, myUserID: String?) -> PasswordPermission {
        guard myRole == CloudRole.owner else { return PasswordPermission(can: false, reason: ownerOnlyReason) }
        guard !member.pending, let user = member.userID else { return PasswordPermission(can: false, reason: passwordPendingReason) }
        if let me = myUserID, user == me { return PasswordPermission(can: false, reason: passwordSelfReason) }
        if member.canSetPassword { return PasswordPermission(can: true, reason: nil) }
        if member.role == CloudRole.owner { return PasswordPermission(can: false, reason: passwordOwnerReason) }
        return PasswordPermission(can: false, reason: passwordForeignReason)
    }

    /// Yetki değişikliği onay ister mi: patronluk vermek ya da kendi yetkisini düşürmek
    public static func roleChangeNeedsConfirm(_ member: CloudMember, to next: String, myUserID: String?) -> Bool {
        if next == member.role { return false }
        if next == CloudRole.owner { return true }
        return myUserID != nil && member.userID == myUserID
    }

    /// Sıralama: önce üyeler (patron → müdür → personel, e-posta), sonra davetler
    public static func sorted(_ members: [CloudMember]) -> [CloudMember] {
        let order = [CloudRole.owner: 0, CloudRole.manager: 1, CloudRole.staff: 2]
        let tr = Locale(identifier: "tr_TR")
        return members.sorted { a, b in
            if a.pending != b.pending { return !a.pending }
            let ra = order[a.role] ?? 3, rb = order[b.role] ?? 3
            if ra != rb { return ra < rb }
            let c = a.email.compare(b.email, locale: tr)
            if c != .orderedSame { return c == .orderedAscending }
            return (a.addedAt ?? .distantPast) < (b.addedAt ?? .distantPast)
        }
    }

    /// Sunucudaki doğrulamayla aynı (`^[^@\s]+@[^@\s]+\.[^@\s]+$`, en fazla 254 karakter)
    public static func isValidEmail(_ raw: String) -> Bool {
        let e = TextFold.asciiLowercased(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !e.isEmpty, e.count <= 254, !e.contains(where: { $0.isWhitespace }) else { return false }
        let parts = e.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, let dot = parts[1].lastIndex(of: ".") else { return false }
        let domain = parts[1]
        return dot > domain.startIndex && domain.index(after: dot) < domain.endIndex
    }

    /// "Hesap oluştur" formundaki giriş adının (kullanıcı adı ya da e-posta) hatası; yoksa nil
    public static func accountError(_ input: String, members: [CloudMember]) -> String? {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "Kullanıcı adı ya da e-posta yazın." }
        guard let email = LoginName.email(from: t) else {
            return "Kullanıcı adında en az bir harf ya da rakam olmalı (harf, rakam, nokta, alt çizgi ve tire kullanılabilir)."
        }
        if !isValidEmail(email) { return "Geçerli bir e-posta adresi yazın (ör. ad@isletme.com)." }
        if let m = members.first(where: { !$0.pending && TextFold.asciiLowercased($0.email) == email }) {
            return "Bu kişi zaten şubenin üyesi (\(CloudRole.title(m.role))). " + changeRoleHint
        }
        return nil
    }
}

// MARK: - Postgres zaman damgası

/// timestamptz metni: "2026-10-09T12:00:00.123456+00:00", "2026-10-09 12:00:00+03", "2026-10-09T12:00:00Z".
/// Kesir basamak sayısı serbesttir (ISO8601DateFormatter'ın platforma göre değişen kesir desteğine dayanmaz).
enum PostgresTime {
    static func parse(_ text: String) -> Date? {
        let s = Array(text.trimmingCharacters(in: .whitespaces).utf8)
        func digits(_ at: Int, _ n: Int) -> Int? {
            guard at + n <= s.count else { return nil }
            var v = 0
            for i in at..<at + n {
                guard (48...57).contains(s[i]) else { return nil }
                v = v * 10 + Int(s[i] - 48)
            }
            return v
        }
        guard s.count >= 19, let y = digits(0, 4), s[4] == 45, let mo = digits(5, 2), s[7] == 45, let d = digits(8, 2),
              [84, 116, 32].contains(s[10]), let h = digits(11, 2), s[13] == 58, let mi = digits(14, 2), s[16] == 58,
              let sec = digits(17, 2), (1...12).contains(mo), (1...31).contains(d), h < 24, mi < 60, sec < 61 else { return nil }
        var i = 19
        var fraction = 0.0
        if i < s.count, s[i] == 46 {
            i += 1
            var scale = 0.1
            let start = i
            while i < s.count, (48...57).contains(s[i]) { fraction += Double(s[i] - 48) * scale; scale /= 10; i += 1 }
            guard i > start else { return nil }
        }
        var offset = 0
        if i < s.count {
            switch s[i] {
            case 90, 122: i += 1                                 // Z
            case 43, 45:                                         // + / -
                let sign = s[i] == 45 ? -1 : 1
                guard let oh = digits(i + 1, 2) else { return nil }
                i += 3
                var om = 0
                if i < s.count, s[i] == 58 { i += 1 }
                if i < s.count { guard let m = digits(i, 2) else { return nil }; om = m; i += 2 }
                offset = sign * (oh * 3600 + om * 60)
            default: return nil
            }
        }
        guard i == s.count else { return nil }
        let seconds = Double(daysFromCivil(y, mo, d) * 86_400 + h * 3600 + mi * 60 + sec - offset) + fraction
        return Date(timeIntervalSince1970: seconds)
    }

    /// "2026-10-09T12:00:00.123Z"
    static func format(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    /// 1970-01-01'den bu yana gün (proleptik Gregoryen takvim; H. Hinnant'ın algoritması)
    private static func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}
