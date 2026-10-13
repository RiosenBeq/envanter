import SwiftUI
import AppKit
import EnvanterCore

/// "Web Paneline Bağlan" penceresinin açılma isteği: elle (Web'e Bağlan düğmeleri, menü komutu) ya da
/// envanter://baglan… bağlantısıyla (kod, sunucu adresi ve anahtar dolu gelir)
struct ConnectRequest: Identifiable {
    let id = UUID()
    /// Bağlantı kodu (16 karakter, tiresiz); elle açılınca boş
    var code = ""
    /// Bağlantıdaki sunucu adresi ve publishable key (yoksa nil: kayıtlı sunucu ya da varsayılan)
    var url: String? = nil
    var key: String? = nil
    /// Bağlantıyla açıldı ve bu Mac henüz bir şubeyle eşleşmemiş: hemen bağlanılır
    var autoConnect = false
}

/// "Web Paneline Bağlan" penceresinin içeriği: bağlantı kodu (ya da kullanıcı adı ve şifre). Bağlanınca kendiliğinden
/// kapanır. Şube seçimi ya da ilk bağlantı kararı gerekirse kapanır ve Ayarlar ekranındaki eşitleme kartına geçilir
/// (seçim ve karar her zamanki gibi orada yapılır).
struct ConnectPanel: View {
    @ObservedObject var cloud: CloudSyncController
    let request: ConnectRequest
    /// Pencereyi kapatır
    var close: () -> Void
    /// Ayarlar ekranına geçer (şube seçimi / ilk bağlantı kararı)
    var openSettings: () -> Void
    /// Ekran görüntüsü önizlemesi: çalışma modu notu gösterilmez
    var isPreview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Web Paneline Bağlan", systemImage: "link.icloud").font(.title2.weight(.semibold))
                Text("Bağlanınca sayım ve satışlar patron ve müdürlerin web paneline gider; web panelindeki veriler bu Mac'e kendiliğinden gelir.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let issue = cloud.issue { CloudIssueBox(issue: issue) }
            if let notice = cloud.notice {
                Label(notice, systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            CloudConnectForm(cloud: cloud, request: request, focusOnAppear: true)
            if !cloud.enabled && !isPreview {
                Text("Bu çalışma modunda (otomatik test / ekran görüntüsü) web eşitlemesi kapalıdır.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            HStack {
                Spacer()
                Button("Kapat", action: close).keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 560, alignment: .leading)
        .onChange(of: cloud.isConnected) { _, connected in
            if connected { close() }
        }
        .onChange(of: cloud.workspaces.isEmpty) { _, empty in
            if !empty { handOff() }
        }
        .onChange(of: cloud.decision != nil) { _, pending in
            if pending { handOff() }
        }
    }

    /// Şube seçimi / ilk bağlantı kararı Ayarlar'daki eşitleme kartında yapılır
    private func handOff() {
        openSettings()
        close()
    }
}

/// Bağlanma formu (bağlanma penceresi ve Ayarlar > Web paneli ile eşitleme kartı): önce bağlantı kodu; "Kullanıcı adı ve
/// şifreyle bağlan" ile kullanıcı adı / şifre formuna geçilir (sunucu ayarları yalnızca orada). Bu Mac daha önce kodla
/// bağlanıp çıkış yaptıysa kod sorulmadan "Yeniden Bağlan".
struct CloudConnectForm: View {
    @ObservedObject var cloud: CloudSyncController
    /// Bağlantıyla açıldıysa kod ve sunucu ayarı
    var request: ConnectRequest? = nil
    /// Açılınca kod alanına odaklan (bağlanma penceresi)
    var focusOnAppear = false
    @State private var code = ""
    @State private var linkURL: String?
    @State private var linkKey: String?
    @State private var usePassword = false
    @State private var started = false
    @FocusState private var codeFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Oturum süresi doldu / çıkış yapıldı: şube eşleşmesi korunuyor
            if cloud.needsSignIn || cloud.isSignedOutWithLink {
                Label(cloud.linkedNote, systemImage: "building.2")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if usePassword {
                CloudSignInFields(cloud: cloud)
                Button("Bağlantı koduyla bağlan") { usePassword = false }
                    .buttonStyle(.link)
            } else {
                codeEntry
            }
        }
        .onAppear(perform: start)
    }

    private var codeEntry: some View {
        VStack(alignment: .leading, spacing: 10) {
            if cloud.canReconnectDevice {
                HStack(spacing: 10) {
                    Button(action: reconnect) { Label("Yeniden Bağlan", systemImage: "arrow.clockwise") }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(cloud.busy)
                    Text("Bu Mac daha önce bağlantı koduyla bağlanmıştı; yeni kod gerekmez.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text("Ya da patronunuzdan aldığınız yeni bir kodu yazın:")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Patronunuzdan aldığınız bağlantı kodunu yazın ya da yapıştırın.").font(.callout.weight(.medium))
            }
            HStack(spacing: 8) {
                TextField("XXXX-XXXX-XXXX-XXXX", text: codeBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .autocorrectionDisabled()
                    .frame(width: 340)
                    .focused($codeFocused)
                    .onSubmit(connect)
                Button(action: paste) { Label("Yapıştır", systemImage: "doc.on.clipboard") }
                    .buttonStyle(SoftButtonStyle())
                    .help("Panodaki kodu, kodlu mesajı ya da envanter:// bağlantısını yapıştırır")
            }
            if let problem = PairCode.inputProblem(code) {
                Text(problem).font(.caption).foregroundStyle(Brand.negative).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button(action: connect) { Label("Bağlan", systemImage: "link") }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(cloud.busy || PairCode.parse(code) == nil)
                if cloud.busy {
                    ProgressView().controlSize(.small)
                    Text("Bağlanıyor…").font(.callout).foregroundStyle(.secondary)
                }
            }
            Text(CloudSyncGuide.pairCodeHelp)
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let server = foreignServer {
                // Bağlantı varsayılan ya da bu Mac'te kayıtlı olmayan bir sunucuyu gösteriyor: kendiliğinden bağlanılmaz
                Label("Bu bağlantı başka bir sunucuya bağlanıyor: \(server). Bağlanınca bu Mac'teki veriler o sunucuya gönderilir; yalnızca bağlantıyı patronunuzdan aldıysanız “Bağlan”a basın.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Brand.warn).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let warning = cloud.serverChangeWarning(to: linkURL ?? "") {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Brand.warn).fixedSize(horizontal: false, vertical: true)
            }
            Button("Kullanıcı adı ve şifreyle bağlan") { usePassword = true }
                .buttonStyle(.link)
                .help("Web paneli hesabınızın kullanıcı adı (ya da e-postası) ve şifresiyle bağlanın")
        }
    }

    /// Yazarken biçimlendirme: büyük harf, 4'erli gruplar; kodlu mesaj yapıştırılınca yalnızca kod kalır. envanter://
    /// bağlantısı yapıştırılınca (⌘V) "Yapıştır" düğmesindeki gibi sunucu ayarı da alınır.
    private var codeBinding: Binding<String> {
        Binding(get: { code }, set: { value in
            if !applyLink(value) { code = PairCode.formatInput(value) }
        })
    }

    /// Metin bir envanter:// bağlantısıysa kodu ve sunucu ayarını alır
    /// - Returns: bağlantı mıydı
    private func applyLink(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix(PairLink.scheme + ":"), let url = URL(string: trimmed),
              let link = PairLink.parse(url) else { return false }
        code = PairCode.display(link.code)
        linkURL = link.url
        linkKey = link.key
        return true
    }

    /// Bağlantıdan gelen, bilinmeyen sunucu (varsayılan ya da bu Mac'te kayıtlı değil): uyarı gösterilir
    private var foreignServer: String? {
        guard let u = linkURL, !PairLink.isKnownServer(u, saved: cloud.state.config?.url) else { return nil }
        return u
    }

    private func start() {
        guard !started else { return }
        started = true
        var personAccount = false
        if let r = request, !r.code.isEmpty || r.url != nil {
            if !r.code.isEmpty { code = PairCode.display(r.code) }
            linkURL = r.url
            linkKey = r.key
            // Bağlantıyla açıldı, bu Mac henüz bir şubeyle eşleşmemiş ve sunucu biliniyor: hemen bağlanılır
            if r.autoConnect && PairLink.isKnownServer(r.url, saved: cloud.state.config?.url) {
                submit(code: r.code, url: r.url, key: r.key)
            }
        } else if let e = cloud.state.config?.email, !e.isEmpty, !PairCode.isDeviceAccount(e), cloud.isLinked {
            // Bu Mac bir kişi hesabıyla eşleşmiş: kullanıcı adı / şifre formu açık gelir
            personAccount = true
            usePassword = true
        }
        if focusOnAppear && !personAccount {
            DispatchQueue.main.async { codeFocused = true }
        }
    }

    /// Panodaki metin: envanter:// bağlantısıysa kod ve sunucu ayarı, değilse içindeki kod
    private func paste() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        if !applyLink(text) { code = PairCode.formatInput(text) }
    }

    private func connect() {
        submit(code: code, url: linkURL, key: linkKey)
    }

    private func submit(code c: String, url u: String?, key k: String?) {
        guard !cloud.busy, PairCode.parse(c) != nil else { return }
        Task { @MainActor in await cloud.connect(code: c, url: u, key: k) }
    }

    private func reconnect() {
        guard !cloud.busy else { return }
        Task { @MainActor in await cloud.reconnectDevice() }
    }
}

/// Kullanıcı adı (ya da e-posta) ve şifreyle bağlanma: web paneli hesabıyla giriş; sunucu ayarları "Gelişmiş" bölümünde.
/// Giriş adı kullanıcı adı ("ayse") ya da e-posta olabilir (`LoginName`).
struct CloudSignInFields: View {
    @ObservedObject var cloud: CloudSyncController
    @State private var email = ""
    @State private var password = ""
    @State private var serverURL = CloudDefaults.url
    @State private var serverKey = CloudDefaults.publishableKey
    @State private var showAdvanced = false
    @FocusState private var passwordFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !cloud.needsSignIn && !cloud.isSignedOutWithLink {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Web paneli hesabınızın kullanıcı adı (ya da e-postası) ve şifresiyle bağlanın.").font(.callout.weight(.medium))
                    Text(CloudSyncCard.accountHelp)
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    Text("Kullanıcı adı veya e-posta").foregroundStyle(.secondary)
                    TextField("ali.veli ya da ornek@isletme.com", text: $email)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .frame(width: 300)
                        .onSubmit { passwordFocused = true }
                }
                if let preview = loginPreview {
                    GridRow {
                        Color.clear.frame(width: 1, height: 1)
                        Text(preview.text)
                            .font(.caption).foregroundStyle(preview.isError ? Brand.negative : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: 300, alignment: .leading)
                    }
                }
                GridRow {
                    Text("Şifre").foregroundStyle(.secondary)
                    SecureField("Şifre", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 300)
                        .focused($passwordFocused)
                        .onSubmit(connect)
                }
            }
            HStack(spacing: 10) {
                Button(action: connect) { Label("Bağlan", systemImage: "link") }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(cloud.busy || LoginName.email(from: email) == nil || password.isEmpty)
                if cloud.busy {
                    ProgressView().controlSize(.small)
                    Text("Bağlanıyor…").font(.callout).foregroundStyle(.secondary)
                }
            }
            if !cloud.needsSignIn && !cloud.isSignedOutWithLink {
                Text(CloudSyncGuide.firstBranchNote)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            advancedSettings
        }
        .onAppear {
            if let c = cloud.state.config {
                // Kullanıcı adı hesabında "@envanter.local" gösterilmez: kişi kullanıcı adını yazar. Bağlantı koduyla
                // bağlanmış Mac'in cihaz hesabı buraya yazılmaz.
                if email.isEmpty && !PairCode.isDeviceAccount(c.email) { email = LoginName.display(c.email) }
                serverURL = c.url
                serverKey = c.publishableKey
            }
        }
    }

    private var advancedSettings: some View {
        DisclosureGroup("Gelişmiş", isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 8) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                    GridRow {
                        Text("Sunucu adresi").foregroundStyle(.secondary)
                        TextField(CloudDefaults.url, text: $serverURL).textFieldStyle(.roundedBorder).frame(width: 380)
                    }
                    GridRow {
                        Text("Publishable key").foregroundStyle(.secondary)
                        TextField(CloudDefaults.publishableKey, text: $serverKey).textFieldStyle(.roundedBorder).frame(width: 380)
                    }
                }
                if let warning = cloud.serverChangeWarning(to: serverURL) {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(Brand.warn).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Varsayılana Dön") {
                        serverURL = CloudDefaults.url
                        serverKey = CloudDefaults.publishableKey
                    }
                    .buttonStyle(SoftButtonStyle())
                    Text("Yalnızca farklı bir Supabase projesi kullanılıyorsa değiştirin. Publishable key herkese açık bir anahtardır; yetkiyi sunucudaki kurallar uygular.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 6)
        }
        .font(.callout)
    }

    /// Giriş alanının altındaki ipucu: kullanıcı adının hangi adla deneneceği (Türkçe harfler ve boşluklar çevrilir)
    private var loginPreview: (text: String, isError: Bool)? {
        guard LoginName.isUsername(email) else { return nil }
        guard let mapped = LoginName.email(from: email) else {
            return ("Kullanıcı adında en az bir harf ya da rakam olmalı (harf, rakam, nokta, alt çizgi ve tire kullanılabilir).", true)
        }
        return ("Kullanıcı adı olarak “\(LoginName.display(mapped))” ile giriş yapılacak.", false)
    }

    private func connect() {
        guard !cloud.busy else { return }
        let e = email, p = password, u = serverURL, k = serverKey
        Task { @MainActor in
            await cloud.connect(email: e, password: p, url: u, key: k)
            if cloud.isConnected || !cloud.workspaces.isEmpty || cloud.decision != nil { password = "" }
        }
    }
}

/// Yan menünün altındaki "Web'e Bağlan" düğmesi: bu Mac web paneline bağlı değilken (ya da çıkış yapılmışken) görünür;
/// bağlıyken yerini kayıt durumunun altındaki eşitleme satırı alır. Oturumun süresi dolduysa ("giriş gerekli") eşitleme
/// satırıyla birlikte görünür: hata metinleri yeniden giriş için buraya yönlendirir.
struct SidebarConnectButton: View {
    @ObservedObject var cloud: CloudSyncController
    var open: () -> Void

    var body: some View {
        if !cloud.showsStatus || (cloud.needsSignIn && !cloud.busy) {
            Button(action: open) {
                Label(cloud.canReconnectDevice ? "Web'e Yeniden Bağlan" : "Web'e Bağlan", systemImage: "link.icloud")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SoftButtonStyle())
            .help("Patronunuzdan aldığınız bağlantı koduyla web paneline bağlanın; veriler kendiliğinden gelir")
        }
    }
}

extension CloudSyncController {
    /// Bu Mac bir şubeyle eşleşmişken başka bir sunucuya bağlanılacaksa uyarı: eşleşme (ve gönderilmemiş değişiklikler)
    /// bırakılır (`SyncState.forSignIn`). Aynı sunucuysa, adres boşsa ya da eşleşme yoksa nil.
    func serverChangeWarning(to url: String) -> String? {
        guard isLinked, let saved = state.config, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !CloudDefaults.sameServer(url, saved.url) else { return nil }
        var text = "Bu Mac başka bir sunucudaki \"\(saved.workspaceName ?? "")\" şubesiyle eşleşmiş. Bu sunucuya bağlanınca o eşleşme bırakılır"
        text += pendingChanges > 0 ? " ve gönderilmemiş \(pendingChanges) değişiklik o şubeye gönderilmez." : "."
        return text + " Bu Mac'teki veriler silinmez."
    }

    /// Oturum süresi dolduğunda ya da çıkış yapıldığında: şube eşleşmesi korunuyor
    var linkedNote: String {
        let name = state.config?.workspaceName ?? ""
        var text = "Bu Mac \"\(name)\" şubesiyle eşleşmiş durumda. Yeniden giriş yaptığınızda kaldığınız yerden devam edilir"
        text += pendingChanges > 0 ? "; \(pendingChanges) değişiklik gönderilmeyi bekliyor." : "."
        return text
    }
}
