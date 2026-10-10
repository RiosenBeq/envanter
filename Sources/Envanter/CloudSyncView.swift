import SwiftUI
import AppKit
import EnvanterCore

/// Ayarlar ve Veri > "Web paneli ile eşitleme" kartı: giriş, şube seçimi, ilk bağlantı kararı, durum ve çıkış.
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
                HStack(spacing: 8) {
                    Label("Web paneli ile eşitleme", systemImage: "arrow.triangle.2.circlepath.icloud").font(.headline)
                    Spacer(minLength: 8)
                    statusPill
                }
                Text("Patron ve müdürler web panelinden her yerden raporları, uyarıları ve kimin neyi değiştirdiğini izler; gerektiğinde sayımı düzeltir, siparişleri onaylar, maliyet ve hedefleri değiştirir. Personel günlük işleri (sayım, satış aktarımı, vardiya) bu uygulamada yapar; değişiklikler birkaç saniye içinde arka planda web paneline gönderilir, web panelindeki değişiklikler de en geç bir dakika içinde buraya gelir.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

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

                if let notice = cloud.notice {
                    Text(notice)
                        .font(.callout)
                        .foregroundStyle(isErrorNotice ? Brand.negative : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                DisclosureGroup("Roller ve yetkiler", isExpanded: $showRoles) {
                    VStack(alignment: .leading, spacing: 6) {
                        roleRow("Patron", "Tüm veriler, kullanıcı daveti ve yetkileri, şube adı. Birden çok şubeyi tek hesaptan karşılaştırır.")
                        roleRow("Müdür", "Tüm verileri görür ve değiştirir: stok kalemleri, reçeteler, personel, siparişler, ayarlar ve günlük kayıtlar.")
                        roleRow("Personel", "Tüm verileri görür; yalnızca günlük kayıtları (sayım, satış, vardiya, not) değiştirebilir ve günü kapatabilir. Kapatılmış günü yalnızca patron veya müdür değiştirebilir ya da kilidini açabilir. Stok kalemi, reçete, personel, sipariş (teslim alma dahil) ve ayar değişiklikleri için müdür yetkisi gerekir.")
                        Text("Kullanıcılar web panelinde Kullanıcılar bölümünden e-posta adresiyle davet edilir. Davet edilen kişi aynı e-postayla hesap açınca şubeye otomatik eklenir.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 6)
                }
                .font(.callout)
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

    private var signInForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            if cloud.needsSignIn {
                Label("Oturumun süresi doldu. Eşitlemeye devam etmek için yeniden giriş yapın; bekleyen değişiklikler korunuyor.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Brand.warn).fixedSize(horizontal: false, vertical: true)
            } else if cloud.isSignedOutWithLink {
                Label(signedOutText, systemImage: "building.2")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Web paneli hesabınızın e-posta adresi ve şifresiyle bağlanın. Hesabınız yoksa patronunuz web panelinden sizi davet etmelidir. Hiç şube yoksa bu hesapla, işletme adıyla yeni bir şube açılır ve hesap patron olur.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
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
                if cloud.busy { ProgressView().controlSize(.small) }
            }
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
                if cloud.busy { ProgressView().controlSize(.small) }
            }
        }
    }

    private var connectedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    Text("Şube").foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Text(cloud.state.config?.workspaceName ?? "—").fontWeight(.medium)
                        Pill(text: CloudRole.title(cloud.role), color: roleColor(cloud.role))
                    }
                }
                GridRow {
                    Text("Hesap").foregroundStyle(.secondary)
                    Text(cloud.state.userEmail ?? cloud.state.config?.email ?? "—").textSelection(.enabled)
                }
                GridRow {
                    Text("Durum").foregroundStyle(.secondary)
                    statusText
                }
                if cloud.pendingChanges > 0 {
                    GridRow {
                        Text("Bekleyen").foregroundStyle(.secondary)
                        Text("\(cloud.pendingChanges) değişiklik gönderilmeyi bekliyor").foregroundStyle(.secondary)
                    }
                }
            }
            if cloud.role == CloudRole.staff {
                Label("Personel hesabı: stok kalemleri, reçeteler, personel, siparişler ve ayarlar bu Mac'te salt okunurdur ve web panelindeki halleriyle güncel tutulur. Kapatılmış günü yalnızca patron veya müdür değiştirebilir ya da kilidini açabilir.",
                      systemImage: "person.badge.shield.checkmark")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button { cloud.syncNow() } label: { Label("Şimdi Eşitle", systemImage: "arrow.triangle.2.circlepath") }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(cloud.status == .syncing)
                Button { Task { @MainActor in await cloud.showWorkspacePicker() } } label: { Label("Şube Değiştir…", systemImage: "building.2") }
                    .buttonStyle(SoftButtonStyle())
                    .disabled(cloud.busy || cloud.status == .syncing || cloud.pendingChanges > 0)
                    .help(cloud.pendingChanges > 0 ? "Bekleyen değişiklikler gönderildikten sonra şube değiştirilebilir" : "Bu hesabın üye olduğu şubeler")
                Button { confirmSignOut = true } label: { Label("Çıkış Yap", systemImage: "rectangle.portrait.and.arrow.right") }
                    .buttonStyle(SoftButtonStyle())
            }
        }
    }

    // MARK: - Parçalar

    @ViewBuilder private var statusPill: some View {
        if cloud.enabled {
            switch cloud.status {
            case .syncing: Pill(text: "Eşitleniyor", color: Brand.positive)
            case .error: Pill(text: cloud.needsSignIn ? "Giriş gerekli" : "Hata", color: Brand.negative)
            case .idle: Pill(text: "Bağlı", color: Brand.ok)
            case .off: Pill(text: "Bağlı değil", color: .secondary)
            }
        }
    }

    @ViewBuilder private var statusText: some View {
        switch cloud.status {
        case .syncing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                if let p = cloud.progress {
                    Text("Eşitleniyor… \(p.done)/\(p.total)")
                } else {
                    Text("Eşitleniyor…")
                }
            }
        case .idle(let date):
            Text(date.map { "Son eşitleme \(Self.timeFormatter.string(from: $0))" } ?? "İlk eşitleme bekleniyor")
        case .error(let message):
            Text(message).foregroundStyle(Brand.negative).fixedSize(horizontal: false, vertical: true)
        case .off:
            Text("Kapalı").foregroundStyle(.secondary)
        }
    }

    private var isErrorNotice: Bool {
        if case .error = cloud.status { return true }
        return false
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

    /// Çıkış yapılmış ama şube eşleşmesi korunan durumda giriş formunun üstündeki açıklama
    private var signedOutText: String {
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

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "tr_TR")
        f.dateFormat = "d MMMM HH:mm"
        return f
    }()
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
                case .error(let message):
                    Image(systemName: "exclamationmark.icloud").foregroundStyle(Brand.negative)
                    Text("Eşitleme hatası").help(message)
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

    private var helpText: String {
        let branch = cloud.state.config?.workspaceName.map { "Şube: \($0)" } ?? ""
        switch cloud.status {
        case .error(let message): return [message, branch].filter { !$0.isEmpty }.joined(separator: "\n")
        default:
            let pending = cloud.pendingChanges > 0 ? "\(cloud.pendingChanges) değişiklik gönderilmeyi bekliyor" : ""
            return [branch, pending].filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }

    private static let time: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "tr_TR"); f.dateFormat = "HH:mm"; return f
    }()
}
