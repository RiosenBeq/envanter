import SwiftUI
import AppKit
import EnvanterCore

/// Ayarlar ve Veri > "Web paneli ile eşitleme" kartı: giriş, şube seçimi, ilk bağlantı kararı, durum ve çıkış.
/// Durumlar: bağlı değil (giriş formu) · bağlanıyor · şube seçimi · bağlı (hesap, rol, şube, son eşitleme, bekleyen) ·
/// hata (ne oldu + ne yapılmalı; kartın üstünde tek kutu) · oturum süresi doldu / çıkış yapıldı (şube eşleşmesi korunur).
struct CloudSyncCard: View {
    @ObservedObject var cloud: CloudSyncController
    @State private var email = ""
    @State private var password = ""
    @State private var serverURL = CloudDefaults.url
    @State private var serverKey = CloudDefaults.publishableKey
    @State private var showAdvanced = false
    @State private var showRoles = false
    @State private var confirmSignOut = false
    @FocusState private var passwordFocused: Bool

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                header
                Text(CloudSyncGuide.intro)
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                // Hata kartın üstünde bir kez: ne oldu, ne yapılmalı (bağlıyken değişikliklerin bu Mac'te beklediği)
                if let issue = cloud.issue { CloudIssueBox(issue: issue) }
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
        .onAppear {
            if let c = cloud.state.config {
                if email.isEmpty { email = c.email }
                serverURL = c.url
                serverKey = c.publishableKey
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
            Button("Çıkış Yap") { cloud.signOut(); password = "" }
            Button("Çıkış Yap ve Bu Mac'i Şubeden Ayır", role: .destructive) { cloud.signOut(detach: true); password = "" }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text(cloud.pendingChanges > 0
                 ? "Henüz gönderilmemiş \(cloud.pendingChanges) değişiklik var; yeniden giriş yaptığınızda gönderilir. Bu Mac'teki veriler silinmez. Bu Mac'i şubeden ayırırsanız bekleyen değişiklikler gönderilmez."
                 : "Eşitleme durur; bu Mac'teki veriler silinmez. Yeniden giriş yaptığınızda kaldığınız yerden devam edilir. Bu Mac'i şubeden ayırırsanız yeniden bağlanırken ilk bağlantıdaki gibi sorulur.")
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
            signInForm.disabled(true)
            Text("Bu çalışma modunda (otomatik test / ekran görüntüsü) web eşitlemesi kapalıdır.")
                .font(.caption).foregroundStyle(.tertiary)
        } else if !cloud.workspaces.isEmpty {
            // Bağlıyken de ("Şube Değiştir…") seçim listesi önce gösterilir
            workspacePicker
        } else if cloud.isConnected {
            connectedSection
        } else {
            signInForm
        }
    }

    private var signInForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            signInIntro
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    Text("E-posta").foregroundStyle(.secondary)
                    TextField("ornek@isletme.com", text: $email)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .frame(width: 300)
                        .onSubmit { passwordFocused = true }
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
                    .disabled(cloud.busy || email.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
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
    }

    /// Giriş formunun üstündeki açıklama: oturum süresi doldu / çıkış yapıldı (şube eşleşmesi korunuyor) ya da
    /// hesabın nereden açıldığı
    @ViewBuilder private var signInIntro: some View {
        if cloud.needsSignIn || cloud.isSignedOutWithLink {
            Label(linkedText, systemImage: "building.2")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Web paneli hesabınızın e-posta adresi ve şifresiyle bağlanın.").font(.callout.weight(.medium))
                Text(CloudSyncGuide.accountHelp + " " + CloudSyncGuide.forgotPassword)
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                        Text(cloud.state.userEmail ?? cloud.state.config?.email ?? "—").textSelection(.enabled)
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
                    Text("Bekleyen").foregroundStyle(.secondary)
                    Text(CloudSyncGuide.pendingText(cloud.pendingChanges, issue: cloud.issue))
                        .foregroundStyle(.secondary)
                }
            }
            Label(CloudRole.summary(cloud.role), systemImage: roleIcon(cloud.role))
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
                Button { confirmSignOut = true } label: { Label("Çıkış Yap", systemImage: "rectangle.portrait.and.arrow.right") }
                    .buttonStyle(SoftButtonStyle())
            }
        }
    }

    private var rolesDisclosure: some View {
        DisclosureGroup("Roller ve yetkiler", isExpanded: $showRoles) {
            VStack(alignment: .leading, spacing: 6) {
                roleRow("Patron", "Tüm veriler, kullanıcı hesapları (hesap açma, şifre belirleme, davet) ve yetkileri, şube adı. Birden çok şubeyi tek hesaptan karşılaştırır.")
                roleRow("Müdür", "Tüm verileri görür ve değiştirir: stok kalemleri, reçeteler, personel, siparişler, ayarlar ve günlük kayıtlar. Kapatılmış günün kilidini açabilir.")
                roleRow("Personel", "Tüm verileri görür; yalnızca günlük kayıtları (sayım, satış, vardiya, not) değiştirebilir ve günü kapatabilir. Kapatılmış günü yalnızca patron veya müdür değiştirebilir ya da kilidini açabilir. Stok kalemi, reçete, personel, sipariş (teslim alma dahil) ve ayar değişiklikleri için müdür yetkisi gerekir.")
                Text(CloudSyncGuide.accountHelp + " " + CloudSyncGuide.forgotPassword + " E-postayla davet edildiyseniz aynı e-postayla kendiniz hesap açarsınız.")
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
                case .idle: Pill(text: "Bağlı", color: Brand.ok)
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

    /// Oturum süresi dolduğunda ya da çıkış yapıldığında: şube eşleşmesi korunuyor
    private var linkedText: String {
        let name = cloud.state.config?.workspaceName ?? ""
        var text = "Bu Mac \"\(name)\" şubesiyle eşleşmiş durumda. Yeniden giriş yaptığınızda kaldığınız yerden devam edilir"
        text += cloud.pendingChanges > 0 ? "; \(cloud.pendingChanges) değişiklik gönderilmeyi bekliyor." : "."
        return text
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
                + "Yalnızca Tanımları Kopyala: stok kalemleri, reçeteler ve ayarlar yeni şubeye kopyalanır. Günlük kayıtlar, personel ve siparişler \"\(from)\" şubesinde kalır; bu Mac'te boşalır (önceki hali Yedekler klasörüne kaydedilir).\n\n"
                + "Her Şeyi Kopyala: günlük kayıtlar dahil bu Mac'teki her şey yeni şubeye yüklenir; iki şubenin raporları aynı günleri gösterir.\n\n"
                + "Vazgeç: \"\(from)\" şubesiyle eşitleme sürer."
                + (d.workspace.role == CloudRole.staff ? " Personel hesabıyla tanımlar yüklenemez; yeni şubenin tanımlarını patron ya da müdür girer." : "")
        }
        return "\"\(d.workspace.name)\" şubesinde \(d.remoteDays) günlük kayıt var; bu Mac'te \(d.localDays) günlük kayıt var.\n\n"
            + "Buluttakini İndir: bu Mac'teki veri önce Yedekler klasörüne kaydedilir, sonra web panelindeki veriyle değiştirilir.\n\n"
            + "Bu Mac'tekini Yükle: aynı kayıtlarda bu Mac'teki geçerli olur; yalnızca web panelinde olan günler korunur ve bu Mac'e de gelir. Web panelindeki önceki hal Yedekler klasörüne kaydedilir."
            + (d.workspace.role == CloudRole.staff ? " Personel hesabıyla yalnızca günlük kayıtlar yüklenir; stok kalemleri, reçeteler, personel, siparişler ve ayarlarda web panelindeki hal geçerli olur. Web panelinde kapatılmış günler değiştirilmez." : "")
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

/// Eşitleme sorunu kutusu: ne oldu (kalın) ve ne yapılmalı. Geçici sorunlar (bağlantı, sunucu) turuncu, birinin bir
/// şey yapması gereken sorunlar (şifre, veritabanı kurulumu, şube üyeliği) kırmızı.
private struct CloudIssueBox: View {
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
                    Image(systemName: "checkmark.icloud").foregroundStyle(Brand.ok)
                    Text(date.map { "Web ile eşitlendi · \(Self.time.string(from: $0))" } ?? "Web ile eşitlenmeyi bekliyor")
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
        if cloud.pendingChanges > 0 {
            lines.append(CloudSyncGuide.pendingText(cloud.pendingChanges, issue: cloud.issue))
        }
        lines.append("Ayrıntı: Ayarlar ve Veri → Web paneli ile eşitleme")
        return lines.joined(separator: "\n")
    }

    private static let time: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "tr_TR"); f.dateFormat = "HH:mm"; return f
    }()
}
