import SwiftUI
import AppKit
import EnvanterCore

/// Ayarlar > "Web paneli ile eşitleme" kartı: bağlanma, şube seçimi, ilk bağlantı kararı, durum ve çıkış.
/// Durumlar: bağlı değil (bağlanma formu: önce bağlantı kodu, istenirse kullanıcı adı ve şifre — `CloudConnectForm`) ·
/// bağlanıyor · şube seçimi · bağlı (hesap, rol, şube, son eşitleme, canlı bağlantı, bekleyen) · hata (ne oldu + ne
/// yapılmalı; kartın üstünde tek kutu) · oturum süresi doldu / çıkış yapıldı (şube eşleşmesi korunur).
struct CloudSyncCard: View {
    @ObservedObject var cloud: CloudSyncController
    /// Patronun "Kullanıcılar…" düğmesi (verilmezse Ekip ekranına geçilir; Kullanıcılar bölümü orada)
    var openUsers: (() -> Void)? = nil
    @State private var showRoles = false
    @State private var confirmSignOut = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                header
                Text(Self.intro)
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                // Hata kartın üstünde bir kez: ne oldu, ne yapılmalı (bağlıyken değişikliklerin bu Mac'te beklediği)
                if let issue = cloud.issue { CloudIssueBox(issue: issue) }
                // Şubede bu Mac'ten yeni bir sürüm çalışıyor (canlı kanaldaki veri biçimi düzeyi)
                if let level = cloud.newerFormat {
                    Label(DataFormat.newerPeerMessage(level), systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(Brand.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content
                if let notice = cloud.notice {
                    Label(notice, systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                rolesDisclosure
            }
        }
        .alert(decisionTitle, isPresented: Binding(get: { cloud.decision != nil }, set: { _ in }),
               presenting: cloud.decision) { d in
            if d.switchingFrom != nil {
                // Başka şubeden boş şubeye geçiş: kendiliğinden yüklenmez, ne kopyalanacağı sorulur
                Button("Yalnızca Tanımları Kopyala") { cloud.resolveDecision(.copyCatalog) }
                Button("Her Şeyi Kopyala") { cloud.resolveDecision(.upload) }
                Button("Vazgeç", role: .cancel) { cloud.cancelDecision() }
            } else {
                Button("Buluttakini İndir") { cloud.resolveDecision(.download) }
                Button("Bu Mac'tekini Yükle") { cloud.resolveDecision(.upload) }
                Button("Vazgeç", role: .cancel) { cloud.cancelDecision() }
            }
        } message: { d in
            Text(decisionMessage(d))
        }
        .confirmationDialog("Web panelinden çıkış yapılsın mı?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Çıkış Yap") { cloud.signOut() }
            Button("Çıkış Yap ve Bu Mac'i Şubeden Ayır", role: .destructive) { cloud.signOut(detach: true) }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text(signOutMessage)
        }
    }

    // MARK: - Bölümler

    private var header: some View {
        HStack(spacing: 8) {
            Label("Web paneli ile eşitleme", systemImage: "arrow.triangle.2.circlepath.icloud").font(.headline)
            Spacer(minLength: 8)
            statusPill
        }
    }

    @ViewBuilder private var content: some View {
        if !cloud.enabled {
            // Otomatik test / ekran görüntüsü modu: form görünür ama bağlantı kurulmaz
            CloudConnectForm(cloud: cloud).disabled(true)
            Text("Bu çalışma modunda (otomatik test / ekran görüntüsü) web eşitlemesi kapalıdır.")
                .font(.caption).foregroundStyle(.tertiary)
        } else if !cloud.workspaces.isEmpty {
            // Bağlıyken de ("Şube Değiştir…") seçim listesi önce gösterilir
            workspacePicker
        } else if cloud.isConnected {
            connectedSection
        } else {
            CloudConnectForm(cloud: cloud)
        }
    }

    private var workspacePicker: some View {
        let current = cloud.state.initialized ? cloud.state.config?.workspaceID : nil
        return VStack(alignment: .leading, spacing: 8) {
            Text("Hangi şubeyle eşitlensin?").font(.callout.weight(.semibold))
            ForEach(cloud.workspaces) { w in
                Button {
                    Task { @MainActor in await cloud.choose(w) }
                } label: {
                    HStack {
                        Image(systemName: "building.2")
                        Text(w.name).fontWeight(.medium)
                        Pill(text: CloudRole.title(w.role), color: roleColor(w.role))
                        if w.id == current { Text("bu Mac").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .buttonStyle(SoftButtonStyle())
                .disabled(cloud.busy)
            }
            if current != nil {
                Text(switchHelpText)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button("Vazgeç") { cloud.dismissWorkspacePicker() }
                    .buttonStyle(SoftButtonStyle())
                    .disabled(cloud.busy)
                if cloud.busy {
                    ProgressView().controlSize(.small)
                    Text("Şube verisi okunuyor…").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Bağlıyken bir bakışta: hesap ve rol, şube, son eşitleme, bekleyen değişiklikler; rolün neye izin verdiği
    private var connectedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    Text("Hesap").foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Text(accountText).textSelection(.enabled)
                        Pill(text: CloudRole.title(cloud.role), color: roleColor(cloud.role))
                    }
                }
                GridRow {
                    Text("Şube").foregroundStyle(.secondary)
                    Text(cloud.state.config?.workspaceName ?? "—").fontWeight(.medium)
                }
                GridRow {
                    Text("Son eşitleme").foregroundStyle(.secondary)
                    syncTime
                }
                GridRow {
                    Text("Canlı bağlantı").foregroundStyle(.secondary)
                    RealtimeStatusLabel(cloud: cloud)
                }
                GridRow {
                    Text("Bekleyen").foregroundStyle(.secondary)
                    Text(CloudSyncGuide.pendingText(cloud.pendingChanges, issue: cloud.issue))
                        .foregroundStyle(.secondary)
                }
            }
            Label(CloudRole.summary(cloud.role) + (cloud.canManageMembers ? " Bu Mac'te de Ekip → Kullanıcılar bölümünden hesap açabilir, yetki ve şifre belirleyebilirsiniz." : ""),
                  systemImage: roleIcon(cloud.role))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button { cloud.syncNow() } label: { Label("Şimdi Eşitle", systemImage: "arrow.triangle.2.circlepath") }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(cloud.status == .syncing)
                    .help("Bekleyen değişiklikleri hemen gönderir ve web panelindeki değişiklikleri alır")
                Button { Task { @MainActor in await cloud.showWorkspacePicker() } } label: { Label("Şube Değiştir…", systemImage: "building.2") }
                    .buttonStyle(SoftButtonStyle())
                    .disabled(cloud.busy || cloud.status == .syncing || cloud.pendingChanges > 0)
                    .help(cloud.pendingChanges > 0 ? "Bekleyen değişiklikler gönderildikten sonra şube değiştirilebilir" : "Bu hesabın üye olduğu şubeler")
                if cloud.canManageMembers {
                    Button { if let openUsers { openUsers() } else { cloud.showUsers() } } label: {
                        Label("Kullanıcılar…", systemImage: "person.badge.key")
                    }
                    .buttonStyle(SoftButtonStyle())
                    .help("Ekip ekranındaki Kullanıcılar bölümü: hesap aç, yetki ve şifre belirle")
                }
                Button { confirmSignOut = true } label: { Label("Çıkış Yap", systemImage: "rectangle.portrait.and.arrow.right") }
                    .buttonStyle(SoftButtonStyle())
            }
        }
    }

    private var rolesDisclosure: some View {
        DisclosureGroup("Roller ve yetkiler", isExpanded: $showRoles) {
            VStack(alignment: .leading, spacing: 6) {
                roleRow("Patron", "Tüm veriler, kullanıcı hesapları ve yetkileri (hesap açma, şifre belirleme: Ekip → Kullanıcılar ya da web paneli; e-postayla davet: web paneli), şube adı. Birden çok şubeyi tek hesaptan karşılaştırır.")
                roleRow("Müdür", "Tüm verileri görür ve değiştirir: stok kalemleri, reçeteler, ekip, siparişler, ayarlar ve günlük kayıtlar. Kapatılmış günün kilidini açabilir.")
                roleRow("Personel", "Tüm verileri görür; yalnızca günlük kayıtları (sayım, satış, not) değiştirebilir ve günü kapatabilir. Kapatılmış günü yalnızca patron veya müdür değiştirebilir ya da kilidini açabilir. Stok kalemi, reçete, ekip, sipariş (teslim alma dahil) ve ayar değişiklikleri için müdür yetkisi gerekir.")
                Text(Self.accountHelp + " E-postayla davet edildiyseniz aynı e-postayla kendiniz hesap açarsınız.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)
        }
        .font(.callout)
    }

    // MARK: - Parçalar

    @ViewBuilder private var statusPill: some View {
        if cloud.enabled {
            if cloud.busy && !cloud.isConnected {
                Pill(text: "Bağlanıyor", color: Brand.positive)
            } else {
                switch cloud.status {
                case .syncing: Pill(text: "Eşitleniyor", color: Brand.positive)
                case .error: Pill(text: cloud.issue?.title ?? "Hata", color: issueColor(cloud.issue))
                case .idle: Pill(text: cloud.isLive ? "Bağlı · Canlı" : "Bağlı", color: Brand.ok)
                case .off: Pill(text: cloud.isSignedOutWithLink ? "Çıkış yapıldı" : "Bağlı değil", color: .secondary)
                }
            }
        }
    }

    /// "Son eşitleme" satırı: eşitlenirken ilerleme, sonra son başarılı eşitlemenin zamanı ("Bugün 14:05")
    @ViewBuilder private var syncTime: some View {
        if cloud.status == .syncing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(cloud.progress.map { "Eşitleniyor… \($0.done)/\($0.total)" } ?? "Eşitleniyor…")
            }
        } else if let last = cloud.state.lastSyncAt {
            Text(CloudSyncGuide.lastSyncText(last))
        } else {
            Text("İlk eşitleme bekleniyor").foregroundStyle(.secondary)
        }
    }

    private func roleRow(_ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title).fontWeight(.semibold).frame(width: 70, alignment: .leading)
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func roleColor(_ role: String?) -> Color {
        switch role {
        case CloudRole.owner: return Brand.accent
        case CloudRole.manager: return Brand.positive
        default: return Brand.ok
        }
    }

    private func roleIcon(_ role: String?) -> String {
        switch role {
        case CloudRole.owner: return "crown"
        case CloudRole.manager: return "person.crop.circle.badge.checkmark"
        default: return "person.badge.shield.checkmark"
        }
    }

    private func issueColor(_ issue: CloudIssue?) -> Color {
        issue?.severity == .temporary ? Brand.warn : Brand.negative
    }

    /// Şube listesinde, bu Mac bir şubeyle eşleşmişken gösterilen açıklama
    private var switchHelpText: String {
        var text = "Başka bir şube seçerseniz: şubede veri varsa o şubenin verisi bu Mac'e indirilir (bu Mac'in hali önce Yedekler klasörüne kaydedilir); şube boşsa ne kopyalanacağı sorulur."
        if cloud.pendingChanges > 0 {
            text += " \"\(cloud.state.config?.workspaceName ?? "")\" şubesine gönderilmemiş \(cloud.pendingChanges) değişiklik o şubeye gönderilmez."
        }
        return text
    }

    private var decisionTitle: String {
        guard let d = cloud.decision else { return "" }
        return d.switchingFrom != nil ? "\"\(d.workspace.name)\" şubesi boş" : "Bu Mac'te de web panelinde de veri var"
    }

    private func decisionMessage(_ d: InitialDecision) -> String {
        if let from = d.switchingFrom {
            return "Bu Mac'teki veri \"\(from)\" şubesine ait (\(d.localDays) günlük kayıt). \"\(d.workspace.name)\" şubesi web panelinde henüz boş.\n\n"
                + "Yalnızca Tanımları Kopyala: stok kalemleri, reçeteler ve ayarlar yeni şubeye kopyalanır. Günlük kayıtlar, ekip ve siparişler \"\(from)\" şubesinde kalır; bu Mac'te boşalır (önceki hali Yedekler klasörüne kaydedilir).\n\n"
                + "Her Şeyi Kopyala: günlük kayıtlar dahil bu Mac'teki her şey yeni şubeye yüklenir; iki şubenin raporları aynı günleri gösterir.\n\n"
                + "Vazgeç: \"\(from)\" şubesiyle eşitleme sürer."
                + (d.workspace.role == CloudRole.staff ? " Personel hesabıyla tanımlar yüklenemez; yeni şubenin tanımlarını patron ya da müdür girer." : "")
        }
        return "\"\(d.workspace.name)\" şubesinde \(d.remoteDays) günlük kayıt var; bu Mac'te \(d.localDays) günlük kayıt var.\n\n"
            + "Buluttakini İndir: bu Mac'teki veri önce Yedekler klasörüne kaydedilir, sonra web panelindeki veriyle değiştirilir.\n\n"
            + "Bu Mac'tekini Yükle: aynı kayıtlarda bu Mac'teki geçerli olur; yalnızca web panelinde olan günler korunur ve bu Mac'e de gelir. Web panelindeki önceki hal Yedekler klasörüne kaydedilir."
            + (d.workspace.role == CloudRole.staff ? " Personel hesabıyla yalnızca günlük kayıtlar yüklenir; stok kalemleri, reçeteler, ekip, siparişler ve ayarlarda web panelindeki hal geçerli olur. Web panelinde kapatılmış günler değiştirilmez." : "")
    }

    /// Kartın kısa tanıtımı (canlı bağlantıyla)
    static let intro = "Sayım ve satışlar birkaç saniye içinde patron ve müdürlerin web paneline gider; web panelinde yapılan düzeltmeler (sayım, stok kalemi, reçete, sipariş, ekip) canlı bağlantıyla anında, bağlantı kurulamazsa en geç bir dakika içinde bu Mac'e gelir. İnternet yokken çalışmaya devam edilir; değişiklikler bağlantı gelince gönderilir."

    /// Hesabı kim açar, şifre unutulunca ne yapılır (web panelinin giriş ekranıyla aynı yollar)
    static let accountHelp = "Hesabınızı patron açar (web panelinde Yönetim → Kullanıcılar ya da kendi Mac'inde Ekip → Kullanıcılar → “Hesap oluştur”) ve kullanıcı adınızı (ya da e-postanızı) ve geçici şifrenizi size WhatsApp/SMS ile iletir; e-posta gelmesini beklemeyin. Şifrenizi unuttuysanız: kullanıcı adı hesabında patronunuz “Şifre belirle” ile yeni bir geçici şifre verir; e-posta hesabında web panelinin giriş ekranındaki “Şifremi unuttum”u kullanın. Kendi şifrenizi web panelinde Ayarlar → Hesap → “Şifremi değiştir” bölümünden değiştirirsiniz."

    /// Bağlı hesabın ekrandaki adı (kullanıcı adı hesabında yalnızca kullanıcı adı; bağlantı koduyla bağlanan Mac'te
    /// cihaz hesabının adıyla "Bağlantı kodu")
    private var accountText: String {
        guard let e = cloud.state.userEmail ?? cloud.state.config?.email, !e.isEmpty else { return "—" }
        if PairCode.isDeviceAccount(e) { return "Bağlantı kodu (\(LoginName.display(e)))" }
        return LoginName.display(e)
    }

    /// Çıkış onayının metni: bekleyen değişiklikler; bağlantı koduyla bağlanan Mac'te "Yeniden Bağlan"
    private var signOutMessage: String {
        var text = cloud.pendingChanges > 0
            ? "Henüz gönderilmemiş \(cloud.pendingChanges) değişiklik var; yeniden giriş yaptığınızda gönderilir. Bu Mac'teki veriler silinmez. Bu Mac'i şubeden ayırırsanız bekleyen değişiklikler gönderilmez."
            : "Eşitleme durur; bu Mac'teki veriler silinmez. Yeniden giriş yaptığınızda kaldığınız yerden devam edilir. Bu Mac'i şubeden ayırırsanız yeniden bağlanırken ilk bağlantıdaki gibi sorulur."
        if cloud.isDeviceAccount {
            text += " Bağlantı koduyla bağlanan bu Mac, çıkıştan sonra \"Yeniden Bağlan\" ile kod sorulmadan bağlanır; şubeden ayırırsanız yeni bir kod gerekir."
        }
        return text
    }
}

/// Eşitleme sorunu kutusu: ne oldu (kalın) ve ne yapılmalı. Geçici sorunlar (bağlantı, sunucu) turuncu, birinin bir
/// şey yapması gereken sorunlar (şifre, veritabanı kurulumu, şube üyeliği) kırmızı.
struct CloudIssueBox: View {
    let issue: CloudIssue

    var body: some View {
        let color = issue.severity == .temporary ? Brand.warn : Brand.negative
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: issue.severity == .temporary ? "wifi.exclamationmark" : "exclamationmark.triangle.fill")
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(issue.message).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                if let hint = issue.hint {
                    Text(hint).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.10)))
        .textSelection(.enabled)
    }
}

/// Kenar çubuğu: şubede bu Mac'ten yeni bir sürüm çalışıyorsa "Yeni sürüm var" (ayrıntı ipucunda)
struct CloudFormatWarning: View {
    @ObservedObject var cloud: CloudSyncController

    var body: some View {
        if let level = cloud.newerFormat {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Brand.warn)
                Text("Yeni sürüm var: güncelleyin")
            }
            .help(DataFormat.newerPeerMessage(level))
        }
    }
}

/// Kenar çubuğundaki kayıt durumunun altındaki eşitleme satırı
struct CloudStatusLine: View {
    @ObservedObject var cloud: CloudSyncController

    var body: some View {
        if cloud.showsStatus {
            HStack(spacing: 6) {
                switch cloud.status {
                case .syncing:
                    ProgressView().controlSize(.mini)
                    Text("Eşitleniyor…")
                case .error:
                    Image(systemName: "exclamationmark.icloud")
                        .foregroundStyle(cloud.issue?.severity == .temporary ? Brand.warn : Brand.negative)
                    Text(errorTitle)
                case .idle(let date):
                    Image(systemName: cloud.isLive ? "bolt.horizontal.icloud" : "checkmark.icloud").foregroundStyle(Brand.ok)
                    Text(date.map { (cloud.isLive ? "Canlı · " : "Web ile eşitlendi · ") + Self.time.string(from: $0) } ?? "Web ile eşitlenmeyi bekliyor")
                case .off:
                    Image(systemName: "icloud.slash").foregroundStyle(.secondary)
                    Text("Web eşitlemesi kapalı")
                }
            }
            .help(helpText)
        }
    }

    /// "Eşitleme: bağlantı yok" / "Eşitleme: kurulum eksik" / "Eşitleme: giriş gerekli"
    private var errorTitle: String {
        guard let issue = cloud.issue else { return "Eşitleme hatası" }
        return "Eşitleme: " + issue.title.lowercased(with: Locale(identifier: "tr_TR"))
    }

    private var helpText: String {
        var lines: [String] = []
        if case .error = cloud.status { lines.append(cloud.issue?.text ?? "Eşitleme hatası") }
        if let branch = cloud.state.config?.workspaceName { lines.append("Şube: \(branch)") }
        if cloud.isConnected { lines.append(RealtimeStatusLabel.text(cloud.realtimeStatus)) }
        if cloud.pendingChanges > 0 {
            lines.append(CloudSyncGuide.pendingText(cloud.pendingChanges, issue: cloud.issue))
        }
        lines.append("Ayrıntı: Ayarlar → Web paneli ile eşitleme")
        return lines.joined(separator: "\n")
    }

    private static let time: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "tr_TR"); f.dateFormat = "HH:mm"; return f
    }()
}

/// Canlı bağlantının durumu (eşitleme kartı ve kenar çubuğu ipucu): bağlıyken web panelindeki değişiklikler anında
/// gelir; kurulamazsa 60 sn'lik düzenli eşitleme sürer.
struct RealtimeStatusLabel: View {
    @ObservedObject var cloud: CloudSyncController

    var body: some View {
        HStack(spacing: 6) {
            switch cloud.realtimeStatus {
            case .connected:
                Image(systemName: "bolt.fill").foregroundStyle(Brand.ok)
            case .connecting:
                ProgressView().controlSize(.mini)
            case .disconnected:
                Image(systemName: "bolt.slash").foregroundStyle(Brand.warn)
            }
            Text(Self.text(cloud.realtimeStatus))
                .foregroundStyle(cloud.realtimeStatus == .connected ? Color.primary : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .help("Canlı bağlantı açıkken web panelinde yapılan değişiklikler bu Mac'e anında gelir. Bağlantı kurulamazsa eşitleme 60 sn'de bir ve uygulama öne gelince yapılır; kendiliğinden yeniden bağlanılır.")
    }

    static func text(_ status: RealtimeStatus) -> String {
        switch status {
        case .connected: return "Canlı · değişiklikler anında gelir"
        case .connecting: return "Canlı bağlantı kuruluyor…"
        case .disconnected: return "Canlı bağlantı bekleniyor · bu sırada 60 sn'de bir eşitlenir"
        }
    }
}
