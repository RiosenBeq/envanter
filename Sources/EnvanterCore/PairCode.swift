import Foundation

// Bağlantı kodu: patron web panelinde Yönetim → Kullanıcılar → "Bilgisayar Bağla" ile bir kod üretir (ör.
// 7KQ2-M9XP-4TRA-HW3D); mağazadaki bilgisayar kodu yazarak (ya da envanter:// bağlantısıyla) kullanıcı adı, şifre, şube
// ve sunucu ayarı sormadan bağlanır. Veritabanında ayrı bir şey yoktur: kod, bilgisayara ayrılmış bir cihaz hesabının
// giriş bilgisidir (kullanıcı adı "pc-" + kodun ilk 6 karakteri, şifre kodun kendisi). Bilgisayar girişten hemen sonra
// hesaba yeni bir şifre verir; kod bir daha kullanılamaz (DeviceLogin.swift).
// Kurallar web ile birebir; ortak test vektörleri: Tests/EnvanterCoreTests/Fixtures/pair-vectors.json.

public enum PairCode {
    /// Karışmayan karakterler: 0, 1, I, L, O yok (31 karakter)
    public static let alphabet = "23456789ABCDEFGHJKMNPQRSTUVWXYZ"
    public static let length = 16
    /// Cihaz hesabının kullanıcı adı öneki (Mac ve Windows bilgisayarları için ortak)
    public static let usernamePrefix = "pc-"
    /// Cihaz hesabının kullanıcı adında koddan alınan karakter sayısı
    public static let usernameCodeLength = 6

    private static let alphabetScalars: [Unicode.Scalar] = Array(alphabet.unicodeScalars)
    private static let alphabetSet = Set(alphabet.unicodeScalars)
    private static let lowerAlphabetSet = Set(alphabet.lowercased().unicodeScalars)

    // MARK: Okuma

    /// Yazılan ya da yapıştırılan metindeki bağlantı kodu (16 büyük harf, tiresiz); yoksa nil. Metin bir WhatsApp mesajı
    /// ya da envanter://baglan?kod=… bağlantısı olabilir; küçük harf, tire ve boşluk fark etmez.
    ///   1. Metinde "kod=" varsa (büyük/küçük harf fark etmez) ilk "kod=" sonrasından ilk &, #, boşluk ya da metin sonuna
    ///      kadarki kısım alınır ve yüzde kodlaması çözülür.
    ///   2. Yalnızca a–z büyütülür.
    ///   3. Soldan sağa, önünde ve arkasında harf/rakam olmayan "XXXX[- ]XXXX[- ]XXXX[- ]XXXX" kalıbı aranır; tire ve
    ///      boşluklar atılınca 16 karakterin hepsi alfabedeyse kod odur, değilse aramaya o grubun ikinci karakterinden
    ///      devam edilir (web'deki düzenli ifade `(?:^|[^0-9A-Z])([0-9A-Z]{4}(?:[- ]?[0-9A-Z]{4}){3})(?=$|[^0-9A-Z])` ile aynı).
    public static func parse(_ input: String) -> String? {
        var text = input
        let scalars = Array(input.unicodeScalars)
        if let start = indexAfterKod(scalars) {
            var end = start
            while end < scalars.count, !isValueTerminator(scalars[end]) { end += 1 }
            var value = String.UnicodeScalarView()
            value.append(contentsOf: scalars[start..<end])
            text = percentDecoded(String(value))
        }
        let s = Array(upperASCII(text).unicodeScalars)
        // pos: aramanın başladığı konum (reddedilen grubun ikinci karakteri); g: denenen grup başı. Grup metnin başında
        // (yalnızca arama baştan başlıyorsa) ya da aramanın içinde kalan, harf/rakam olmayan bir karakterin hemen
        // sonrasında başlayabilir.
        var pos = 0
        var g = 0
        while g < s.count {
            let allowed = g == 0 ? pos == 0 : (g - 1 >= pos && !isAlnum(s[g - 1]))
            if allowed, let end = matchGroup(s, at: g), end == s.count || !isAlnum(s[end]) {
                let code = s[g..<end].filter { $0 != "-" && $0 != " " }
                if code.count == length && code.allSatisfy({ alphabetSet.contains($0) }) {
                    var out = String.UnicodeScalarView()
                    out.append(contentsOf: code)
                    return String(out)
                }
                pos = g + 1
            }
            g += 1
        }
        return nil
    }

    /// Metin tam olarak bir bağlantı kodu mu (16 karakter, hepsi alfabede; tire yok). Cihaz hesabının şifresi hâlâ kodun
    /// kendisiyse girişten sonra yeni şifre verilir.
    public static func isCode(_ s: String) -> Bool {
        let u = Array(s.unicodeScalars)
        return u.count == length && u.allSatisfy { alphabetSet.contains($0) }
    }

    // MARK: Türetme

    /// Ekrandaki hali: 4'erli gruplar tireyle ("7KQ2-M9XP-4TRA-HW3D")
    public static func display(_ code: String) -> String {
        grouped(Array(code.unicodeScalars))
    }

    /// Cihaz hesabının kullanıcı adı: "pc-" + kodun ilk 6 karakteri küçük harfle ("pc-7kq2m9")
    public static func username(_ code: String) -> String {
        usernamePrefix + TextFold.asciiLowercased(String(String.UnicodeScalarView(code.unicodeScalars.prefix(usernameCodeLength))))
    }

    /// Cihaz hesabının giriş e-postası (kullanıcı adı hesaplarıyla aynı alan adı: `LoginName.domain`)
    public static func email(_ code: String) -> String {
        username(code) + "@" + LoginName.domain
    }

    /// Cihaz hesabının ilk şifresi: kodun kendisi (16 büyük harf, tiresiz)
    public static func password(_ code: String) -> String { code }

    /// E-posta bir cihaz hesabının mı (bağlantı koduyla bağlanan bilgisayar): baştaki/sondaki boşluk atılıp küçültülünce
    /// `^pc-[2-9a-hjkmnp-z]{6}@envanter\.local$`
    public static func isDeviceAccount(_ email: String) -> Bool {
        deviceName(forEmail: email) != nil
    }

    /// Cihaz hesabının kullanıcı adı ("pc-7kq2m9"); cihaz hesabı değilse nil. Canlı bağlantının çevrimiçi bilgisinde
    /// `device` alanı olarak gönderilir (web panelindeki "Bağlı bilgisayarlar" listesi çevrimiçi olanı tanır).
    public static func deviceName(forEmail email: String) -> String? {
        let e = Array(email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().unicodeScalars)
        let prefix = Array(usernamePrefix.unicodeScalars)
        let suffix = Array(("@" + LoginName.domain).unicodeScalars)
        guard e.count == prefix.count + usernameCodeLength + suffix.count,
              Array(e.prefix(prefix.count)) == prefix, Array(e.suffix(suffix.count)) == suffix else { return nil }
        let middle = e[prefix.count..<(prefix.count + usernameCodeLength)]
        guard middle.allSatisfy({ lowerAlphabetSet.contains($0) }) else { return nil }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: e.prefix(prefix.count + usernameCodeLength))
        return String(out)
    }

    // MARK: Üretme

    /// Rastgele kod (sistemin güvenli üreteciyle). Web paneli de aynı yolla üretir: rastgele bayt b < 248 ise
    /// alfabe[b % 31] (eşit dağılım için 248 ve üstü atılır).
    public static func random() -> String {
        var g = SystemRandomNumberGenerator()
        return random(using: &g)
    }

    public static func random<G: RandomNumberGenerator>(using generator: inout G) -> String {
        var out = String.UnicodeScalarView()
        var n = 0
        while n < length {
            let b: UInt8 = generator.next()
            guard b < 248 else { continue }
            out.append(alphabetScalars[Int(b % 31)])
            n += 1
        }
        return String(out)
    }

    // MARK: Kod alanı

    /// Kod alanına yazılan / yapıştırılan metnin gösterilecek hali: içinde geçerli bir kod varsa (kod içeren mesaj ya da
    /// bağlantı da olur) "XXXX-XXXX-XXXX-XXXX"; yalnızca harf, rakam, tire ve boşluksa büyük harfle 4'erli gruplanır (en
    /// fazla 16 karakter); değilse (kod bulunamayan mesaj) olduğu gibi kalır.
    public static func formatInput(_ input: String) -> String {
        if let code = parse(input) { return display(code) }
        var chars: [Unicode.Scalar] = []
        for u in upperASCII(input).unicodeScalars {
            if isAlnum(u) {
                chars.append(u)
            } else if u != "-" && !u.properties.isWhitespace {
                return input
            }
        }
        return grouped(Array(chars.prefix(length)))
    }

    /// Kod alanının altındaki uyarı (sorun yoksa ya da kod henüz yazılıyorsa nil)
    public static func inputProblem(_ input: String) -> String? {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, parse(t) == nil else { return nil }
        let chars = upperASCII(t).unicodeScalars.filter { $0 != "-" && !$0.properties.isWhitespace }
        guard chars.allSatisfy({ isAlnum($0) }) else {
            return "Bu metinde bağlantı kodu bulunamadı. Kod XXXX-XXXX-XXXX-XXXX biçiminde 16 karakterdir."
        }
        if chars.contains(where: { !alphabetSet.contains($0) }) {
            return "Kodda 0 ve 1 rakamları, I, L ve O harfleri yoktur; kodu yeniden kontrol edin."
        }
        return nil
    }

    // MARK: Yardımcılar

    private static func grouped(_ chars: [Unicode.Scalar]) -> String {
        var out = String.UnicodeScalarView()
        for (i, u) in chars.enumerated() {
            if i > 0 && i % 4 == 0 { out.append("-") }
            out.append(u)
        }
        return String(out)
    }

    /// Yalnızca a–z büyütülür (yerel ayardan bağımsız)
    private static func upperASCII(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            out.append((0x61...0x7A).contains(u.value) ? Unicode.Scalar(UInt8(u.value - 32)) : u)
        }
        return String(out)
    }

    private static func isAlnum(_ u: Unicode.Scalar) -> Bool {
        (0x30...0x39).contains(u.value) || (0x41...0x5A).contains(u.value)
    }

    /// İlk "kod=" (büyük/küçük harf fark etmez) sonrasının konumu
    private static func indexAfterKod(_ s: [Unicode.Scalar]) -> Int? {
        let key: [UInt32] = [0x6B, 0x6F, 0x64]   // k o d
        guard s.count >= 4 else { return nil }
        for i in 0...(s.count - 4) {
            var ok = s[i + 3] == "="
            var k = 0
            while ok && k < 3 {
                let v = s[i + k].value
                ok = v == key[k] || v == key[k] - 32
                k += 1
            }
            if ok { return i + 4 }
        }
        return nil
    }

    private static func isValueTerminator(_ u: Unicode.Scalar) -> Bool {
        u == "&" || u == "#" || u.properties.isWhitespace
    }

    /// %XX dizileri UTF-8 olarak çözülür; geçersiz diziler olduğu gibi kalır, geçersiz baytlar U+FFFD olur
    static func percentDecoded(_ s: String) -> String {
        let u = Array(s.utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(u.count)
        var i = 0
        while i < u.count {
            if u[i] == 0x25, i + 2 < u.count, let h = hexValue(u[i + 1]), let l = hexValue(u[i + 2]) {
                bytes.append(h << 4 | l)
                i += 3
            } else {
                bytes.append(u[i])
                i += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func hexValue(_ b: UInt8) -> UInt8? {
        switch b {
        case 0x30...0x39: return b - 0x30
        case 0x41...0x46: return b - 0x41 + 10
        case 0x61...0x66: return b - 0x61 + 10
        default: return nil
        }
    }

    /// "XXXX" + 3 × ("-" ya da " " isteğe bağlı + "XXXX"); eşleşirse grubun bittiği konum
    private static func matchGroup(_ s: [Unicode.Scalar], at g: Int) -> Int? {
        var i = g
        func four() -> Bool {
            guard i + 4 <= s.count else { return false }
            for k in i..<(i + 4) where !isAlnum(s[k]) { return false }
            i += 4
            return true
        }
        guard four() else { return nil }
        for _ in 0..<3 {
            if i < s.count, s[i] == "-" || s[i] == " " { i += 1 }
            guard four() else { return nil }
        }
        return i
    }
}

/// Web panelinin "Bu bilgisayardaki uygulamada aç" bağlantısı:
/// `envanter://baglan?kod=<XXXX-XXXX-XXXX-XXXX>&sunucu=<adres>&anahtar=<publishable key>` (değerler encodeURIComponent ile).
/// Uygulama bu bağlantıyla açılınca bağlantı penceresi kod (ve sunucu ayarı) dolu açılır.
public enum PairLink {
    public static let scheme = "envanter"
    public static let host = "baglan"

    /// Bağlantıdaki kod, sunucu adresi ve publishable key (sunucu / anahtar yoksa nil). Şema ya da yol farklıysa ya da
    /// geçerli kod yoksa nil.
    public static func parse(_ url: URL) -> (code: String, url: String?, key: String?)? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == host,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String? {
            guard let v = items.first(where: { $0.name.lowercased() == name })?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
            return v
        }
        guard let raw = value("kod"), let code = PairCode.parse(raw) else { return nil }
        return (code, value("sunucu"), value("anahtar"))
    }

    /// Bağlantıdaki sunucu bilinen bir sunucu mu: sunucu yok (kayıtlı sunucu ya da varsayılan kullanılır), varsayılan
    /// sunucu ya da bu Mac'te kayıtlı sunucu. Değilse bağlantı kendiliğinden bağlanmaz: bağlanma penceresi başka sunucu
    /// uyarısıyla açılır ve "Bağlan"a basılması beklenir (yabancı bir bağlantı bu Mac'in verisini başka sunucuya
    /// yükletemesin).
    public static func isKnownServer(_ url: String?, saved: String?) -> Bool {
        guard let url, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        if CloudDefaults.sameServer(url, CloudDefaults.url) { return true }
        if let saved, CloudDefaults.sameServer(url, saved) { return true }
        return false
    }

    /// Bağlantı metni (web paneli üretir; burada testler ve gidiş-dönüş için)
    public static func make(code: String, url: String, key: String) -> String {
        "\(scheme)://\(host)?kod=\(PairCode.display(code))&sunucu=\(encodeComponent(url))&anahtar=\(encodeComponent(key))"
    }

    /// JavaScript encodeURIComponent: A–Z a–z 0–9 - _ . ! ~ * ' ( ) dışındakiler %XX (UTF-8, büyük harf)
    static func encodeComponent(_ s: String) -> String {
        var allowed = CharacterSet()
        allowed.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
