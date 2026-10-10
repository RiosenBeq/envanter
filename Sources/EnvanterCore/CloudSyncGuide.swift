import Foundation

// Web eşitlemesinin kullanıcıya gösterilen metinleri: hesap açma / şifre yolları (web panelindeki adlarla aynı),
// hataların ne anlama geldiği ve ne yapılacağı, rol özetleri, son eşitleme zamanı. Mac'te Ayarlar ve Veri >
// "Web paneli ile eşitleme" kartı, yan menüdeki durum satırı ve Nasıl Kullanılır? ekranı bunları kullanır.

/// Web eşitlemesindeki bir sorunun ekrandaki hali
public struct CloudIssue: Equatable, Sendable {
    public enum Severity: Equatable, Sendable {
        /// Geçici (bağlantı, sunucu yoğunluğu): eşitleme kendiliğinden yeniden denenir, değişiklikler bu Mac'te bekler
        case temporary
        /// Birinin bir şey yapması gerekir (şifre, veritabanı kurulumu, şubeye ekleme, yetki)
        case actionNeeded
    }

    /// Kısa durum adı (kart rozeti, yan menü): "Bağlantı yok", "Kurulum eksik", "Giriş gerekli" …
    public var title: String
    /// Ne oldu
    public var message: String
    /// Ne yapılmalı (yoksa nil)
    public var hint: String?
    public var severity: Severity

    public init(title: String, message: String, hint: String? = nil, severity: Severity) {
        self.title = title; self.message = message; self.hint = hint; self.severity = severity
    }

    /// Açıklama ve yapılacak iş tek metinde (ipuçları için)
    public var text: String { hint.map { message + " " + $0 } ?? message }
}

public enum CloudSyncGuide {
    /// Kartın kısa tanıtımı
    public static let intro = "Sayım, satış ve vardiyalar birkaç saniye içinde patron ve müdürlerin web paneline gider; web panelinde yapılan düzeltmeler (sayım, maliyet, sipariş, hedef) en geç bir dakika içinde bu Mac'e gelir. İnternet yokken çalışmaya devam edilir; değişiklikler bağlantı gelince gönderilir."

    /// Hesabı kim, nereden açar (web paneli: Yönetim → Kullanıcılar → "Hesap oluştur")
    public static let accountHelp = "Hesabınızı patron web panelinde Yönetim → Kullanıcılar ekranında \"Hesap oluştur\" ile açar ve giriş e-postanızı ve geçici şifrenizi size (WhatsApp/SMS ile) iletir; e-posta gelmesini beklemeyin."

    /// Şifre unutulunca / değiştirilirken (web paneli: "Şifre belirle", Ayarlar → Hesap → "Şifremi değiştir")
    public static let forgotPassword = "Şifrenizi unuttuysanız patronunuz web panelinde Yönetim → Kullanıcılar ekranında \"Şifre belirle\" ile yeni bir geçici şifre verir. Patron hesaplarında (ve başka bir patronun şubesinde de çalışanlarda) bu yol kapalıdır: web panelinin giriş ekranındaki \"Şifremi unuttum\" bağlantısını kullanın. Kendi şifrenizi web panelinde Ayarlar → Hesap → \"Şifremi değiştir\" bölümünden değiştirirsiniz."

    /// İlk kurulum: web panelinde hiç şube yoksa
    public static let firstBranchNote = "İlk kurulum: web panelinde hiç şube yoksa bu hesapla, işletme adıyla yeni bir şube açılır ve hesap patron olur."

    /// Bağlıyken bağlantı koptuğunda
    public static let offlineKeepsChanges = "Çalışmaya devam edebilirsiniz: değişiklikler bu Mac'te saklanır, bağlantı gelince kendiliğinden gönderilir."

    /// Web panelinin veritabanı kurulmamışken (Supabase'de envanter tabloları yok)
    public static func setupMissingHint(connected: Bool) -> String {
        "Bu, Mac'teki bir sorun değil: web panelinin veritabanı kurulumu henüz yapılmamış. Patron (ya da paneli kuran kişi) web panelinin kurulum talimatındaki veritabanı dosyasını (supabase/migrations/…_envanter.sql) Supabase paneli → SQL Editor'de bir kez çalıştırmalı. "
            + (connected
                ? "Kurulum bitince eşitleme kendiliğinden sürer; bu sırada değişiklikler bu Mac'te saklanır."
                : "Kurulum bitince yeniden \"Bağlan\"a basın; bu sırada uygulamayı kullanmaya devam edebilirsiniz, veriler bu Mac'e kaydedilir.")
    }

    /// Bekleyen (henüz gönderilmemiş) değişiklikler. `issue`: eşitlemedeki güncel sorun (yoksa nil). Geçici sorunda
    /// (bağlantı) değişiklikler bağlantı gelince, birinin bir şey yapması gereken sorunda (giriş, kurulum, yetki)
    /// sorun giderilince gönderilir.
    public static func pendingText(_ count: Int, issue: CloudIssue?) -> String {
        guard count > 0 else { return "Yok, tüm değişiklikler gönderildi" }
        guard let issue else { return "\(count) değişiklik gönderilmeyi bekliyor" }
        switch issue.severity {
        case .temporary:
            return "\(count) değişiklik bu Mac'te saklanıyor; bağlantı gelince gönderilir"
        case .actionNeeded:
            return "\(count) değişiklik bu Mac'te saklanıyor; sorun giderilince gönderilir"
        }
    }

    /// Son başarılı eşitleme: "Bugün 14:05", "Dün 18:20", "9 Ekim 14:05"; hiç yoksa "Henüz yok"
    public static func lastSyncText(_ date: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date else { return "Henüz yok" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "tr_TR")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "HH:mm"
        let time = f.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return "Bugün \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Dün \(time)"
        }
        f.dateFormat = "d MMMM HH:mm"
        return f.string(from: date)
    }
}

extension CloudRole {
    /// Rolün bu Mac'te neye izin verdiği (Ayarlar ve Veri kartında rol rozetinin yanında)
    public static func summary(_ role: String?) -> String {
        switch role {
        case owner:
            return "Patron: tüm verileri değiştirebilirsiniz. Kullanıcı hesapları ve yetkiler web panelinde Yönetim → Kullanıcılar ekranında, şube adı Ayarlar → İşletme bölümündedir."
        case manager:
            return "Müdür: tüm verileri (stok kalemleri, reçeteler, personel, siparişler, ayarlar, günlük kayıtlar) değiştirebilirsiniz ve kapatılmış günün kilidini açabilirsiniz. Kullanıcı hesaplarını patron yönetir."
        case staff:
            return "Personel: sayım, satış, vardiya ve notları girebilirsiniz ve günü kapatabilirsiniz. Stok kalemleri, reçeteler, personel, siparişler ve ayarlar bu Mac'te salt okunurdur; kapatılmış günün kilidini patron veya müdür açar."
        default:
            return "Rol bilinmiyor; şube listesi bir sonraki eşitlemede yeniden okunur."
        }
    }
}

extension CloudSyncError {
    /// Hatanın ekrandaki hali: ne oldu ve ne yapılmalı.
    /// - Parameter connected: bu Mac bir şubeyle eşitlenirken mi oldu (değişiklikler bu Mac'te bekler, eşitleme
    ///   kendiliğinden yeniden denenir); false: bağlanırken (kullanıcı yeniden "Bağlan"a basmalı)
    public func issue(connected: Bool) -> CloudIssue {
        let message = errorDescription ?? ""
        let retry = connected
            ? "Değişiklikler bu Mac'te saklanır; eşitleme bir dakika içinde kendiliğinden yeniden denenir. Sorun sürerse patrona ya da web panelini kuran kişiye bildirin."
            : "Birkaç dakika sonra yeniden deneyin. Sorun sürerse patrona ya da web panelini kuran kişiye bildirin."
        switch self {
        case .invalidCredentials:
            return CloudIssue(title: "Şifre yanlış", message: message,
                              hint: "Büyük/küçük harfe dikkat edin. " + CloudSyncGuide.forgotPassword, severity: .actionNeeded)
        case .emailNotConfirmed:
            return CloudIssue(title: "E-posta onaylanmamış", message: message,
                              hint: "Onay e-postası gelmediyse patronunuz web panelinde Yönetim → Kullanıcılar ekranında aynı e-postayla \"Hesap oluştur\" diyerek hesabınızı açabilir; e-posta gerekmez.",
                              severity: .actionNeeded)
        case .sessionExpired:
            return CloudIssue(title: "Giriş gerekli", message: message,
                              hint: "Şifreniz değiştiyse (ya da patron \"Şifre belirle\" ile yeni şifre verdiyse) yeni şifreyle giriş yapın. Bekleyen değişiklikler bu Mac'te korunuyor; giriş yapınca gönderilir.",
                              severity: .actionNeeded)
        case .forbidden:
            return CloudIssue(title: "Yetki yok", message: message,
                              hint: "Bu işlemi patron ya da müdür web panelinden yapabilir. Rolünüz ya da şube üyeliğiniz web panelinde değiştiyse patrona sorun.",
                              severity: .actionNeeded)
        case .network:
            return CloudIssue(title: "Bağlantı yok", message: message,
                              hint: connected ? CloudSyncGuide.offlineKeepsChanges
                                  : "Bağlantı gelince yeniden \"Bağlan\"a basın. Bu sırada uygulamayı kullanmaya devam edebilirsiniz; veriler bu Mac'e kaydedilir.",
                              severity: .temporary)
        case .rateLimited:
            return CloudIssue(title: "Çok fazla deneme", message: message,
                              hint: connected ? "Değişiklikler bu Mac'te saklanır; eşitleme kendiliğinden yeniden denenir." : nil,
                              severity: .temporary)
        case .notProvisioned:
            return CloudIssue(title: "Kurulum eksik", message: message,
                              hint: CloudSyncGuide.setupMissingHint(connected: connected), severity: .actionNeeded)
        case .invalidRequest:
            return CloudIssue(title: "İstek reddedildi", message: message, hint: retry, severity: .temporary)
        case .server:
            return CloudIssue(title: "Sunucu hatası", message: message, hint: retry, severity: .temporary)
        case .invalidResponse:
            return CloudIssue(title: "Beklenmeyen yanıt", message: message, hint: retry, severity: .temporary)
        case .notConfigured:
            return CloudIssue(title: "Bağlı değil", message: message,
                              hint: "Web paneli e-postanız ve şifrenizle bağlanın.", severity: .actionNeeded)
        case .noWorkspace:
            return CloudIssue(title: "Şube yok", message: message,
                              hint: "Patronunuz web panelinde Yönetim → Kullanıcılar ekranında bu e-postayla \"Hesap oluştur\" demeli ya da sizi şubeye davet etmeli. Sonra yeniden \"Bağlan\"a basın.",
                              severity: .actionNeeded)
        case .invalidConfiguration:
            return CloudIssue(title: "Ayar geçersiz", message: message,
                              hint: "Gelişmiş bölümünde \"Varsayılana Dön\"e basıp yeniden bağlanın.", severity: .actionNeeded)
        }
    }
}
