import SwiftUI
import AppKit
import EnvanterCore

/// Ekip: şubede çalışanlar (ad, görev, telefon, giriş/ayrılış, not, bağlı giriş hesabı). Sayımı yapan kişi (Sayan)
/// seçimi aktif üyelerden gelir (`Team.counterNames`). Ekibi patron ve müdür değiştirir; personel hesabıyla salt okunurdur.
/// Altta yalnızca patron için, bu Mac web paneline bağlıyken "Kullanıcılar" bölümü: giriş hesabı açma, yetki ve şifre
/// belirleme, şubeden çıkarma (web panelindeki Yönetim → Kullanıcılar ile aynı kurallar ve metinler).
struct TeamView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        // Kullanıcılar bölümü eşitleme durumuna (bağlı mı, rol) bağlı: denetleyici de izlenir
        TeamScreen(store: store, cloud: store.cloud)
            .navigationTitle("Ekip")
    }
}

/// Ekranda açılan pencereler (tek `.sheet` ile)
private enum TeamSheet: Identifiable {
    case newMember
    case editMember(String)
    /// Hesap oluştur (isteğe bağlı: bağlanacak ekip üyesi önceden seçili)
    case createAccount(employeeID: String?)
    case setPassword(CloudMember)

    var id: String {
        switch self {
        case .newMember: return "yeni-uye"
        case .editMember(let id): return "uye-" + id
        case .createAccount(let id): return "hesap-" + (id ?? "")
        case .setPassword(let m): return "sifre-" + m.id
        }
    }
}

private struct TeamScreen: View {
    @ObservedObject var store: AppStore
    @ObservedObject var cloud: CloudSyncController
    @State private var sheet: TeamSheet?
    @State private var deleting: Employee?
    /// Kullanıcılar bölümünün listesi (envanter_members_list)
    @State private var members: [CloudMember] = []
    @State private var membersLoading = false
    @State private var membersError: String?
    @State private var reloadToken = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if store.employees.isEmpty {
                    emptyCard
                } else {
                    TeamListCard(store: store, canCreateAccounts: cloud.canManageMembers,
                                 onEdit: { sheet = .editMember($0.id) },
                                 onDelete: { deleting = $0 },
                                 onCreateAccount: { sheet = .createAccount(employeeID: $0.id) })
                }
                if cloud.canManageMembers {
                    UsersCard(store: store, cloud: cloud, members: members, loading: membersLoading, error: membersError,
                              sheet: $sheet, reload: { await loadMembers() })
                } else {
                    UsersInfoCard(store: store, cloud: cloud)
                }
            }
            .padding(22)
        }
        .sheet(item: $sheet) { s in
            Group {
                switch s {
                case .newMember:
                    TeamMemberSheet(store: store, employeeID: nil)
                case .editMember(let id):
                    TeamMemberSheet(store: store, employeeID: id)
                case .createAccount(let id):
                    CreateAccountSheet(store: store, cloud: cloud, members: members, presetEmployeeID: id,
                                       onDone: { await loadMembers() })
                case .setPassword(let m):
                    SetPasswordSheet(cloud: cloud, member: m)
                }
            }
            .sheetSurface()
        }
        .confirmationDialog("\"\(deleting?.name ?? "")\" silinsin mi?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { e in
            if e.active {
                Button("Pasif yap (listede kalır, Sayan'da görünmez)") { store.setEmployeeActive(e.id, false); deleting = nil }
            }
            Button("Tamamen sil", role: .destructive) { store.deleteEmployee(e.id); deleting = nil }
            Button("Vazgeç", role: .cancel) { deleting = nil }
        } message: { e in
            Text(deleteMessage(e))
        }
        // Patron ve bağlıyken üyeler okunur; şube ya da yetki değişince yeniden
        .task(id: membersTaskKey) { await loadMembers() }
    }

    // MARK: Bölümler

    private var header: some View {
        let active = store.employees.filter { $0.active }.count
        let passive = store.employees.count - active
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("Ekip").font(.title2.weight(.semibold))
                if !store.employees.isEmpty {
                    Pill(text: passive > 0 ? "\(active) aktif · \(passive) pasif" : "\(active) aktif", color: Brand.positive)
                }
                Spacer()
                Button { sheet = .newMember } label: { Label("Eleman Ekle", systemImage: "person.badge.plus") }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!store.canEditCatalog)
                    .help(store.canEditCatalog ? "Yeni ekip üyesi ekle" : CloudPermission.catalogReadOnlyNote)
            }
            Text("Şubede çalışanlar. Sayımı yapan kişi (Sayan) listesi aktif üyelerden gelir; işten ayrılan çalışanı silmek yerine pasif yapın, geçmiş sayımlardaki ad korunur.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !store.canEditCatalog { ReadOnlyNote() }
        }
    }

    private var emptyCard: some View {
        Card {
            EmptyStateView(icon: "person.2", title: "Henüz ekip üyesi yok",
                           message: store.canEditCatalog
                               ? "Çalışanları ad ve göreviyle ekleyin (ör. Usta, Kasiyer, Kurye). Sayımı yapan kişi (Sayan) listesi buradan gelir; patron, web paneline bağlıyken çalışana giriş hesabı da açabilir."
                               : "Ekip listesini patron veya müdür ekler.")
                .frame(height: 240)
        }
    }

    private func deleteMessage(_ e: Employee) -> String {
        var text = "İşten ayrılan çalışanı pasif yapın: geçmiş sayımlardaki Sayan adı korunur. Yanlış eklenen kaydı tamamen silebilirsiniz (Düzen > Geri Al ile geri alınır)."
        if let account = e.account, !account.isEmpty {
            text += " Bağlı giriş hesabı (\(LoginName.display(account))) silinmez; erişimini kesmek için Kullanıcılar bölümünden şubeden çıkarın."
        }
        return text
    }

    // MARK: Üyeler

    private var membersTaskKey: String {
        guard cloud.canManageMembers else { return "kapali" }
        return "\(cloud.state.config?.workspaceID ?? "")|\(reloadToken)"
    }

    @MainActor
    private func loadMembers() async {
        guard cloud.canManageMembers else {
            members = []
            membersError = nil
            return
        }
        membersLoading = true
        defer { membersLoading = false }
        do {
            members = try await cloud.membersList()
            membersError = nil
        } catch {
            if Task.isCancelled { return }
            membersError = CloudSyncController.memberErrorText(error)
        }
    }
}

// MARK: - Ekip listesi

private enum TW {
    static let role: CGFloat = 140
    static let phone: CGFloat = 130
    static let account: CGFloat = 150
    static let active: CGFloat = 46
    static let button: CGFloat = 28
}

private struct TeamListCard: View {
    @ObservedObject var store: AppStore
    /// Patron ve bağlı: hesabı olmayan üyede "Hesap oluştur"
    let canCreateAccounts: Bool
    var onEdit: (Employee) -> Void
    var onDelete: (Employee) -> Void
    var onCreateAccount: (Employee) -> Void

    var body: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                HStack {
                    Text("Ekip listesi").font(.headline)
                    Spacer()
                    if store.canEditCatalog {
                        Text("Satıra sağ tıklayarak da düzenleyebilir, pasif yapabilirsiniz").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .padding(14)
                Divider()
                HStack(spacing: 8) {
                    Text("Ad").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Görev").frame(width: TW.role, alignment: .leading)
                    Text("Telefon").frame(width: TW.phone, alignment: .leading)
                    Text("Giriş hesabı").frame(width: TW.account, alignment: .leading)
                        .help("Web paneline ve şubedeki Mac'e giriş yapılan hesap (kullanıcı adı ya da e-posta). Hesabı patron açar.")
                    Text("Aktif").frame(width: TW.active)
                        .help("Kapalıysa (pasif) Sayan listesinde görünmez; geçmiş sayımlardaki ad korunur")
                    Color.clear.frame(width: TW.button * 2 + 8, height: 1)
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Brand.header)
                ForEach(store.employees) { e in
                    TeamRow(store: store, employee: e, canCreateAccount: canCreateAccounts && (e.account ?? "").isEmpty,
                            onEdit: { onEdit(e) }, onDelete: { onDelete(e) }, onCreateAccount: { onCreateAccount(e) })
                    Divider().padding(.leading, 14)
                }
            }
        }
    }
}

private struct TeamRow: View {
    @ObservedObject var store: AppStore
    let employee: Employee
    let canCreateAccount: Bool
    var onEdit: () -> Void
    var onDelete: () -> Void
    var onCreateAccount: () -> Void

    var body: some View {
        let e = employee
        let editable = store.canEditCatalog
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                CommitTextField(title: "Ad Soyad", value: Binding(get: { e.name }, set: { v in
                    guard !v.isEmpty else { return }
                    store.updateEmployee(e.id) { $0.name = v }
                }))
                if let detail = detailText(e) {
                    Button(action: onEdit) {
                        Text(detail).font(.caption2).foregroundStyle(e.endDate != nil ? Brand.warn : Color.secondary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    .buttonStyle(.plain)
                    .help(detailHelp(e))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            CommitTextField(title: "ör. Usta", value: Binding(get: { e.role }, set: { v in store.updateEmployee(e.id) { $0.role = v } }))
                .frame(width: TW.role)
            CommitTextField(title: "Telefon", value: Binding(get: { e.phone ?? "" }, set: { v in
                store.updateEmployee(e.id) { $0.phone = v.isEmpty ? nil : v }
            }))
            .frame(width: TW.phone)
            accountCell(e).frame(width: TW.account, alignment: .leading)
            Toggle("", isOn: Binding(get: { e.active }, set: { v in store.setEmployeeActive(e.id, v) }))
                .labelsHidden().frame(width: TW.active)
                .help(e.active ? "Pasif yap: Sayan listesinde görünmez" : "Aktif yap: Sayan listesinde yeniden görünür")
            Button(action: onEdit) { Image(systemName: "pencil") }
                .buttonStyle(.plain).frame(width: TW.button)
                .help("Tüm bilgileri düzenle (tarihler, not)")
                .accessibilityLabel("\(e.name) düzenle")
            Button(action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundStyle(Brand.negative.opacity(0.85)).frame(width: TW.button)
                .help("Sil ya da pasif yap")
                .accessibilityLabel("\(e.name) kaydını sil")
        }
        .disabled(!editable)
        .padding(.horizontal, 14).padding(.vertical, 6)
        .opacity(e.active ? 1 : 0.6)
        .contextMenu {
            // Personel hesabıyla ekip salt okunur: menü de gösterilmez
            if editable {
                Button("Düzenle…", action: onEdit)
                Button(e.active ? "Pasif yap" : "Aktif yap") { store.setEmployeeActive(e.id, !e.active) }
                Divider()
                Button("Sil…", action: onDelete)
            }
        }
    }

    @ViewBuilder private func accountCell(_ e: Employee) -> some View {
        if let account = e.account, !account.isEmpty {
            Label(LoginName.display(account), systemImage: "person.badge.key")
                .font(.callout).lineLimit(1).truncationMode(.middle)
                .help("Giriş hesabı: \(LoginName.display(account))")
        } else if canCreateAccount {
            Button(action: onCreateAccount) { Label("Hesap oluştur", systemImage: "plus.circle") }
                .buttonStyle(.plain).foregroundStyle(Brand.accent).font(.callout)
                .help("Bu çalışana web paneli ve Mac için giriş hesabı aç (kullanıcı adıyla, e-posta gerekmez)")
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }

    /// Ad altındaki satır: giriş / ayrılış tarihi ve not
    private func detailText(_ e: Employee) -> String? {
        var parts: [String] = []
        if let s = e.startDate { parts.append("Giriş \(DateKey.short(s))") }
        if let end = e.endDate { parts.append("Ayrılış \(DateKey.short(end))") }
        if let note = e.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            parts.append(note.replacingOccurrences(of: "\n", with: " "))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func detailHelp(_ e: Employee) -> String {
        var lines: [String] = []
        if let s = e.startDate { lines.append("İşe giriş: \(DateKey.long(s))") }
        if let end = e.endDate { lines.append("Ayrılış: \(DateKey.long(end))") }
        if let note = e.note, !note.isEmpty { lines.append("Not: \(note)") }
        lines.append("Düzenlemek için tıklayın")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Eleman ekle / düzenle

private struct TeamMemberSheet: View {
    @ObservedObject var store: AppStore
    /// nil: yeni üye
    let employeeID: String?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var role = ""
    @State private var phone = ""
    @State private var note = ""
    @State private var active = true
    @State private var hasStart = false
    @State private var hasEnd = false
    /// Düzenlenen üyenin açılışta ayrılış tarihi var mıydı (kaldırılınca üye yeniden aktif olur)
    @State private var hadEnd = false
    @State private var start = Date()
    @State private var end = Date()
    /// Bağlı giriş hesabı (düzenlemede; yalnızca gösterilir ya da bağlantı kaldırılır)
    @State private var account: String?
    @State private var unlinkAccount = false

    private var isNew: Bool { employeeID == nil }
    private var datesInvalid: Bool { hasStart && hasEnd && DateKey.string(from: end) < DateKey.string(from: start) }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "Eleman ekle" : "\(trimmedName.isEmpty ? "Ekip üyesi" : trimmedName) · düzenle").font(.title2.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Ad Soyad")
                    TextField("ör. Ayşe Yılmaz", text: $name).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Görev")
                    TextField("ör. Usta, Kasiyer, Kurye", text: $role).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Telefon")
                    TextField("İsteğe bağlı", text: $phone).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Toggle("İşe giriş", isOn: $hasStart)
                    DatePicker("", selection: $start, displayedComponents: .date).labelsHidden().fixedSize().disabled(!hasStart)
                }
                GridRow {
                    Toggle("Ayrılış (son gün)", isOn: endBinding)
                    DatePicker("", selection: $end, displayedComponents: .date).labelsHidden().fixedSize().disabled(!hasEnd)
                }
                GridRow(alignment: .top) {
                    Text("Not")
                    TextEditor(text: $note)
                        .font(.body)
                        .frame(height: 60)
                        .overlay(Shapes.control.strokeBorder(Brand.line, lineWidth: 1))
                }
                if !isNew {
                    GridRow {
                        Text("Durum")
                        Toggle("Aktif (Sayan listesinde görünür)", isOn: activeBinding)
                    }
                    GridRow {
                        Text("Giriş hesabı")
                        accountRow
                    }
                }
            }
            if datesInvalid {
                Text("Ayrılış tarihi girişten önce olamaz.").font(.callout).foregroundStyle(Brand.negative)
            }
            Text(isNew
                 ? "Giriş ve ayrılış tarihleri bilgi amaçlıdır. Giriş hesabını patron, web paneline bağlıyken bu ekranın Kullanıcılar bölümünden açar."
                 : "Giriş ve ayrılış tarihleri bilgi amaçlıdır. Ayrılış kaldırılırsa üye yeniden aktif olur; pasif üye aktif yapılınca ayrılış tarihi kalkar.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Vazgeç") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Ekle" : "Kaydet") { if save() { dismiss() } }
                    .keyboardShortcut(.defaultAction).buttonStyle(PrimaryButtonStyle())
                    .disabled(trimmedName.isEmpty || datesInvalid || !store.canEditCatalog)
            }
        }
        .padding(22).frame(width: 540)
        .onAppear(perform: load)
    }

    /// Kayıtlı ayrılış kaldırılınca Durum da "Aktif"e döner (pencerede görünür; Kaydet görüneni yazar)
    private var endBinding: Binding<Bool> {
        Binding(get: { hasEnd }, set: { v in
            hasEnd = v
            if !v && hadEnd && !isNew { active = true }
        })
    }

    /// Pasif üye aktif yapılınca ayrılış tarihi kalkar (listedeki "Aktif yap" ile aynı kural)
    private var activeBinding: Binding<Bool> {
        Binding(get: { active }, set: { v in
            if v && !active { hasEnd = false }
            active = v
        })
    }

    @ViewBuilder private var accountRow: some View {
        if let account, !account.isEmpty, !unlinkAccount {
            HStack(spacing: 8) {
                Label(LoginName.display(account), systemImage: "person.badge.key").textSelection(.enabled)
                Button("Bağlantıyı kaldır") { unlinkAccount = true }
                    .buttonStyle(SoftButtonStyle())
                    .help("Hesap silinmez, yalnızca bu üyeyle bağlantısı kalkar. Erişimi kesmek için Kullanıcılar bölümünden şubeden çıkarın.")
            }
        } else if unlinkAccount {
            HStack(spacing: 8) {
                Text("Bağlantı kaydedince kaldırılacak").foregroundStyle(.secondary)
                Button("Geri al") { unlinkAccount = false }.buttonStyle(SoftButtonStyle())
            }
        } else {
            Text("Yok — hesabı patron Kullanıcılar bölümünden açar ya da bağlar").foregroundStyle(.secondary)
        }
    }

    private func load() {
        let today = DateKey.date(from: DateKey.today()) ?? Date()
        start = today
        end = today
        guard let id = employeeID, let e = store.employees.first(where: { $0.id == id }) else { return }
        name = e.name
        role = e.role
        phone = e.phone ?? ""
        note = e.note ?? ""
        active = e.active
        hasStart = e.startDate != nil
        hasEnd = e.endDate != nil
        hadEnd = hasEnd
        start = e.startDate.flatMap { DateKey.date(from: $0) } ?? today
        end = e.endDate.flatMap { DateKey.date(from: $0) } ?? today
        account = e.account
    }

    /// - Returns: kaydedildi mi (personel hesabıyla reddedilirse false; pencere açık kalır)
    private func save() -> Bool {
        func clean(_ s: String) -> String? {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        let n = trimmedName
        guard !n.isEmpty, !datesInvalid else { return false }
        let r = role.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = clean(phone), no = clean(note)
        let s = hasStart ? DateKey.string(from: start) : nil
        let en = hasEnd ? DateKey.string(from: end) : nil
        guard let id = employeeID else {
            return store.addEmployee(Employee(name: n, role: r, phone: p, active: true, startDate: s, endDate: en, note: no))
        }
        let unlink = unlinkAccount
        let isActive = active
        return store.updateEmployee(id) { e in
            e.name = n
            e.role = r
            e.phone = p
            e.note = no
            e.startDate = s
            e.endDate = en
            e.active = isActive
            if unlink { e.account = nil }
        }
    }
}

// MARK: - Kullanıcılar (patron)

/// Patron değilse ya da Mac web paneline bağlı değilse: hesapları kimin, nereden açtığı
private struct UsersInfoCard: View {
    @ObservedObject var store: AppStore
    @ObservedObject var cloud: CloudSyncController

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("Kullanıcılar (giriş hesapları)", systemImage: "person.badge.key").font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if cloud.enabled && !cloud.isConnected {
                    Button { store.openConnect() } label: { Label("Web'e Bağlan…", systemImage: "link.icloud") }
                        .buttonStyle(SoftButtonStyle())
                        .help("Web paneline bağlanın (patron hesabıyla: Kullanıcı adı ve şifreyle bağlan)")
                }
            }
        }
    }

    private var text: String {
        if cloud.isConnected {
            return "Giriş hesaplarını (kullanıcı adı ve şifre) patron açar ve yetkilerini belirler: web panelinde Yönetim → Kullanıcılar ya da patron hesabıyla bağlı bir Mac'te bu ekranın Kullanıcılar bölümü. Şifresini unutan çalışana patron “Şifre belirle” ile yeni geçici şifre verir."
        }
        return "Patron, bu Mac web paneline patron hesabıyla bağlıyken burada çalışanlara kullanıcı adıyla (e-posta gerekmez) giriş hesabı açar, yetki ve şifre belirler. Bağlanmak için: yan menüde Web'e Bağlan → “Kullanıcı adı ve şifreyle bağlan” (patron hesabıyla). Hesaplar web panelinde Yönetim → Kullanıcılar ekranından da yönetilir."
    }
}

/// Onay isteyen kullanıcı işlemleri (web panelindeki metinlerle aynı)
private enum UserConfirm: Identifiable {
    case role(CloudMember, String)
    case remove(CloudMember)

    var id: String {
        switch self {
        case .role(let m, let r): return "rol-\(m.id)-\(r)"
        case .remove(let m): return "cikar-\(m.id)"
        }
    }
}

private struct UsersCard: View {
    @ObservedObject var store: AppStore
    @ObservedObject var cloud: CloudSyncController
    let members: [CloudMember]
    let loading: Bool
    let error: String?
    @Binding var sheet: TeamSheet?
    var reload: () async -> Void
    @State private var confirm: UserConfirm?
    /// İşlemi süren üye (satırda ilerleme gösterilir)
    @State private var busyID: String?
    @State private var actionError: String?
    @State private var info: String?

    private var branch: String { cloud.state.config?.workspaceName ?? "" }

    var body: some View {
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Label("Kullanıcılar", systemImage: "person.badge.key").font(.headline)
                        Text("“\(branch)” şubesine giriş yapan hesaplar ve yetkileri (web paneli ve bu Mac). Yalnızca patron görür.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if loading { ProgressView().controlSize(.small) }
                    Button { Task { @MainActor in await reload() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(SoftButtonStyle())
                        .disabled(loading)
                        .help("Listeyi yenile")
                        .accessibilityLabel("Kullanıcı listesini yenile")
                    Button { sheet = .createAccount(employeeID: nil) } label: { Label("Hesap oluştur", systemImage: "person.crop.circle.badge.plus") }
                        .buttonStyle(PrimaryButtonStyle())
                        .help("Kullanıcı adıyla (e-posta gerekmez) ya da e-postayla hesap aç ve şubeye ekle")
                }
                .padding(14)
                if let message = actionError ?? error {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(Brand.negative)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        .padding(.horizontal, 14).padding(.bottom, 10)
                } else if let info {
                    Label(info, systemImage: "checkmark.circle.fill")
                        .font(.callout).foregroundStyle(Brand.ok)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14).padding(.bottom, 10)
                }
                Divider()
                if members.isEmpty {
                    Text(loading ? "Üyeler yükleniyor…" : "Henüz üye yok.")
                        .font(.callout).foregroundStyle(.secondary).padding(14)
                } else {
                    ForEach(CloudMembers.sorted(members)) { m in
                        memberRow(m)
                        Divider().padding(.leading, 14)
                    }
                }
                Text("Yetkiyi listeden değiştirin; şifresini unutan için “Şifre belirle”. Kişiye iletilecek mesaj hesap açılınca ya da şifre belirlenince gösterilir. Davet e-postaları web panelinden yönetilir.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(14)
            }
        }
        .confirmationDialog(confirm.map { confirmTitle($0) } ?? "",
                            isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            titleVisibility: .visible, presenting: confirm) { c in
            Button(confirmLabel(c), role: isDanger(c) ? .destructive : nil) { perform(c) }
            Button("Vazgeç", role: .cancel) { confirm = nil }
        } message: { c in
            Text(confirmText(c))
        }
    }

    // MARK: Satır

    @ViewBuilder private func memberRow(_ m: CloudMember) -> some View {
        let me = cloud.currentUserID
        let isSelf = m.userID != nil && m.userID == me
        let perms = CloudMembers.memberPermissions(m, in: members, myRole: cloud.role)
        let pw = CloudMembers.passwordPermission(m, myRole: cloud.role, myUserID: me)
        let linked = store.employee(linkedTo: m.email)
        // Bağlantı koduyla bağlanan bilgisayarın cihaz hesabı (web panelindeki "Bilgisayar Bağla"): ekibe bağlanmaz,
        // şifresini bilgisayar kendisi belirler
        let device = PairCode.isDeviceAccount(m.email)
        HStack(spacing: 10) {
            Image(systemName: m.pending ? "envelope" : (device ? "desktopcomputer" : (LoginName.isUsernameEmail(m.email) ? "person.crop.circle" : "at.circle")))
                .foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(m.displayName).fontWeight(.medium).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    if isSelf { Text("(siz)").font(.caption).foregroundStyle(.secondary) }
                    if m.pending { Pill(text: "Bekleyen davet", color: Brand.warn) }
                }
                Group {
                    if m.pending {
                        Text("Davetler web panelinden yönetilir; hesap açılınca şubeye eklenir.")
                    } else if device {
                        Text("Bağlantı koduyla bağlanan bilgisayar")
                    } else if let linked {
                        Text("Ekip: \(linked.name)" + (linked.role.isEmpty ? "" : " · \(linked.role)"))
                    } else {
                        Text(LoginName.isUsernameEmail(m.email) ? "Kullanıcı adı hesabı · ekip üyesine bağlı değil" : "E-posta hesabı · ekip üyesine bağlı değil")
                    }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if busyID == m.id { ProgressView().controlSize(.small) }
            if !m.pending && !device {
                linkMenu(m, linked: linked)
            }
            Picker("", selection: Binding(get: { m.role }, set: { requestRole(m, $0) })) {
                Text(CloudRole.title(CloudRole.staff)).tag(CloudRole.staff)
                Text(CloudRole.title(CloudRole.manager)).tag(CloudRole.manager)
                Text(CloudRole.title(CloudRole.owner)).tag(CloudRole.owner)
            }
            .labelsHidden().frame(width: 110)
            .disabled(m.pending || !perms.canChangeRole || busyID != nil)
            .help(m.pending ? "Davetin yetkisi web panelinden değiştirilir" : (perms.reason ?? "Yetkiyi değiştir"))
            Button("Şifre belirle") { actionError = nil; info = nil; sheet = .setPassword(m) }
                .buttonStyle(SoftButtonStyle())
                .disabled(!pw.can || device || busyID != nil)
                .help(device ? "Bilgisayar hesabının şifresini bilgisayar kendisi belirler. Yeniden bağlamak için web panelinde Yönetim → Kullanıcılar → Bilgisayar Bağla ile yeni kod üretin."
                      : (pw.reason ?? "Yeni geçici şifre belirle (eski şifre hemen geçmez olur)"))
            Button { confirm = .remove(m) } label: { Image(systemName: m.pending ? "xmark.circle" : "person.crop.circle.badge.minus") }
                .buttonStyle(.plain).foregroundStyle(Brand.negative.opacity(0.85)).frame(width: 28)
                .disabled(!perms.canRemove || isSelf || busyID != nil)
                .help(isSelf ? "Bu Mac'te oturumu açık hesabı buradan çıkaramazsınız"
                      : (perms.reason ?? (m.pending ? "Daveti iptal et" : "Şubeden çıkar")))
                .accessibilityLabel(m.pending ? "\(m.displayName) davetini iptal et" : "\(m.displayName) şubeden çıkar")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    /// Hesabı bir ekip üyesine bağlama (Ekip listesindeki "Giriş hesabı")
    private func linkMenu(_ m: CloudMember, linked: Employee?) -> some View {
        let candidates = store.employees.filter { ($0.account ?? "").isEmpty || $0.id == linked?.id }
        return Menu {
            if candidates.isEmpty {
                Text("Önce Ekip listesine eleman ekleyin")
            }
            ForEach(candidates) { e in
                Button(e.id == linked?.id ? "✓ \(e.name)" : e.name) {
                    store.linkAccount(employeeID: e.id, email: m.email)
                }
            }
            if let linked {
                Divider()
                Button("Bağlantıyı kaldır") { store.linkAccount(employeeID: linked.id, email: nil) }
            }
        } label: {
            Image(systemName: linked == nil ? "link.badge.plus" : "link")
        }
        .menuStyle(.borderlessButton).fixedSize()
        .disabled(!store.canEditCatalog)
        .help(linked.map { "Ekip üyesi: \($0.name) (değiştir ya da kaldır)" } ?? "Bir ekip üyesine bağla")
    }

    // MARK: İşlemler

    private func requestRole(_ m: CloudMember, _ next: String) {
        guard next != m.role else { return }
        if CloudMembers.roleChangeNeedsConfirm(m, to: next, myUserID: cloud.currentUserID) {
            confirm = .role(m, next)
        } else {
            changeRole(m, next)
        }
    }

    private func perform(_ c: UserConfirm) {
        confirm = nil
        switch c {
        case .role(let m, let next): changeRole(m, next)
        case .remove(let m): remove(m)
        }
    }

    private func changeRole(_ m: CloudMember, _ next: String) {
        run(m, success: "\(m.displayName) artık \(CloudRole.title(next)).") { try await cloud.setRole(m, to: next) }
    }

    private func remove(_ m: CloudMember) {
        if m.pending {
            run(m, success: "\(m.email) daveti iptal edildi.") { try await cloud.cancelInvite(m) }
        } else {
            let linked = store.employee(linkedTo: m.email)
            run(m, success: "\(m.displayName) şubeden çıkarıldı." + (linked.map { " Ekip listesindeki \($0.name) kaydı duruyor; işten ayrıldıysa pasif yapın." } ?? "")) {
                try await cloud.removeMember(m)
            }
        }
    }

    /// Sunucu işlemi: satırda ilerleme, sonra liste yenilenir; hata Türkçe metinle gösterilir
    private func run(_ m: CloudMember, success: String, _ work: @escaping @MainActor () async throws -> Void) {
        busyID = m.id
        actionError = nil
        info = nil
        Task { @MainActor in
            do {
                try await work()
                info = success
            } catch {
                actionError = CloudSyncController.memberErrorText(error)
            }
            busyID = nil
            await reload()
        }
    }

    // MARK: Onay metinleri (web paneliyle aynı)

    private func isSelf(_ m: CloudMember) -> Bool { m.userID != nil && m.userID == cloud.currentUserID }

    private func isDanger(_ c: UserConfirm) -> Bool {
        switch c {
        case .remove: return true
        case .role(let m, _): return isSelf(m)
        }
    }

    private func confirmTitle(_ c: UserConfirm) -> String {
        switch c {
        case .remove(let m):
            return m.pending ? "Davet iptal edilsin mi?" : "\(m.displayName) şubeden çıkarılsın mı?"
        case .role(let m, let next):
            if isSelf(m) { return "Kendi yetkinizi \(CloudRole.title(next).lowercased(with: Locale(identifier: "tr_TR"))) yapıyorsunuz" }
            return "\(m.displayName) patron yapılsın mı?"
        }
    }

    private func confirmText(_ c: UserConfirm) -> String {
        switch c {
        case .remove(let m):
            if m.pending { return "\(m.email) adresine yapılan davet silinir. Bu e-postayla hesap açılsa bile şubeye eklenmez." }
            return "\(m.displayName) “\(branch)” şubesine artık erişemez; Mac uygulamasındaki eşitlemesi de durur. Geçmişteki hareketleri silinmez."
        case .role(let m, let next):
            if isSelf(m) {
                return next == CloudRole.staff
                    ? "Patron yetkinizi bırakırsınız ve yalnızca günlük kayıtları değiştirebilirsiniz; Kullanıcılar bölümü kapanır. Geri almak için başka bir patron gerekir."
                    : "Patron yetkinizi bırakırsınız: kullanıcı hesabı açamaz, yetki değiştiremezsiniz. Geri almak için başka bir patron gerekir."
            }
            return "\(m.displayName) patron olursa kullanıcıları ve yetkileri yönetebilir, sizi bile şubeden çıkarabilir. Yalnızca işletme ortaklarına verin."
        }
    }

    private func confirmLabel(_ c: UserConfirm) -> String {
        switch c {
        case .remove(let m): return m.pending ? "Daveti İptal Et" : "Şubeden Çıkar"
        case .role(_, let next): return "\(CloudRole.title(next)) Yap"
        }
    }
}

// MARK: - Hesap oluştur

private struct CreateAccountSheet: View {
    @ObservedObject var store: AppStore
    @ObservedObject var cloud: CloudSyncController
    let members: [CloudMember]
    /// Ekip listesindeki "Hesap oluştur"dan gelindiyse bağlanacak üye
    let presetEmployeeID: String?
    var onDone: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var login = ""
    @State private var password = ""
    @State private var role = CloudRole.staff
    @State private var linkEmployeeID: String?
    @State private var touched = false
    @State private var busy = false
    @State private var error: String?
    /// Başarılı sonuç: başlık, açıklama ve kişiye iletilecek mesaj
    @State private var result: (title: String, note: String, message: String)?

    private var loginError: String? { CloudMembers.accountError(login, members: members) }
    private var passwordError: String? { PasswordRule.error(password) }
    private var branch: String { cloud.state.config?.workspaceName ?? "" }
    /// Bağlanabilecek üyeler: hesabı olmayanlar
    private var candidates: [Employee] { store.employees.filter { ($0.account ?? "").isEmpty || $0.id == presetEmployeeID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let result {
                resultView(result)
            } else {
                form
            }
        }
        .padding(22).frame(width: 580)
        .onAppear(perform: prefill)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Hesap oluştur").font(.title2.weight(.semibold))
            Text("E-posta gerekmez: kullanıcı adıyla (ör. ayse.yilmaz) açılan hesapla web paneline ve şubedeki Mac'e giriş yapılır. Hesap açılınca kişiye iletilecek mesaj gösterilir (WhatsApp/SMS ile gönderin).")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Kullanıcı adı veya e-posta")
                    TextField("ayse.yilmaz ya da ad@isletme.com", text: $login)
                        .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                }
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    loginHint
                }
                GridRow {
                    Text("Geçici şifre")
                    HStack(spacing: 8) {
                        // Düz metin: patron şifreyi kişiye iletecek
                        TextField("En az \(PasswordRule.minLength) karakter", text: $password)
                            .textFieldStyle(.roundedBorder).autocorrectionDisabled().font(.body.monospaced())
                        Button("Güçlü şifre üret") { password = PasswordRule.generate() }
                            .buttonStyle(SoftButtonStyle())
                    }
                }
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    passwordHint
                }
                GridRow {
                    Text("Yetki")
                    Picker("", selection: $role) {
                        Text(CloudRole.title(CloudRole.staff)).tag(CloudRole.staff)
                        Text(CloudRole.title(CloudRole.manager)).tag(CloudRole.manager)
                        Text(CloudRole.title(CloudRole.owner)).tag(CloudRole.owner)
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 300)
                }
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    Text(roleHelp).font(.caption).foregroundStyle(role == CloudRole.owner ? Brand.warn : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                GridRow {
                    Text("Ekip üyesi")
                    Picker("", selection: $linkEmployeeID) {
                        Text("Bağlama").tag(String?.none)
                        ForEach(candidates) { e in
                            Text(e.role.isEmpty ? e.name : "\(e.name) · \(e.role)").tag(String?.some(e.id))
                        }
                    }
                    .labelsHidden().frame(width: 300)
                    .disabled(!store.canEditCatalog)
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(Brand.negative)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            HStack {
                if busy {
                    ProgressView().controlSize(.small)
                    Text("Hesap açılıyor…").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Vazgeç") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Button("Hesap oluştur", action: submit)
                    .keyboardShortcut(.defaultAction).buttonStyle(PrimaryButtonStyle())
                    .disabled(busy || (touched && (loginError != nil || passwordError != nil)))
            }
        }
    }

    @ViewBuilder private var loginHint: some View {
        if touched || !login.isEmpty, let e = loginError, !(login.isEmpty && !touched) {
            Text(e).font(.caption).foregroundStyle(Brand.negative).fixedSize(horizontal: false, vertical: true)
        } else if let email = LoginName.email(from: login) {
            Text(LoginName.isUsername(login)
                 ? "Kullanıcı adı: “\(LoginName.display(email))” (web paneline ve Mac'e bu adla girilir; e-posta gerekmez)"
                 : "Giriş e-postası: \(email)")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Türkçe harfler ve boşluklar çevrilir: “Ayşe Yılmaz” → ayse.yilmaz")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var passwordHint: some View {
        if touched || !password.isEmpty, let e = passwordError {
            Text(e).font(.caption).foregroundStyle(touched ? Brand.negative : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if let advice = PasswordRule.advice(password) {
            Text(advice).font(.caption).foregroundStyle(Brand.warn)
        } else {
            Text("Kişi ilk girişten sonra şifresini web panelinde Ayarlar → Hesap → “Şifremi değiştir”den değiştirebilir.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var roleHelp: String {
        switch role {
        case CloudRole.owner: return "Patron tüm verileri, kullanıcı hesaplarını ve yetkileri yönetir; yalnızca işletme ortaklarına verin."
        case CloudRole.manager: return "Müdür tüm verileri değiştirir ve kapatılmış günün kilidini açar; kullanıcı hesaplarını patron yönetir."
        default: return "Personel sayım, satış ve not girer, günü kapatır; tanımlar (stok kalemi, reçete, ekip, sipariş) salt okunurdur."
        }
    }

    private func resultView(_ r: (title: String, note: String, message: String)) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(r.title, systemImage: "checkmark.circle.fill").font(.title2.weight(.semibold)).foregroundStyle(Brand.ok)
            Text(r.note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            AccountMessageBox(message: r.message)
            HStack {
                Spacer()
                Button("Tamam") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private func prefill() {
        guard let id = presetEmployeeID, let e = store.employees.first(where: { $0.id == id }) else { return }
        linkEmployeeID = id
        if login.isEmpty, let email = LoginName.email(from: e.name) { login = LoginName.display(email) }
        if !e.role.isEmpty, e.role.lowercased(with: Locale(identifier: "tr_TR")).contains("müdür") { role = CloudRole.manager }
    }

    private func submit() {
        touched = true
        error = nil
        guard loginError == nil, passwordError == nil, !busy, let email = LoginName.email(from: login) else { return }
        busy = true
        let pw = password, r = role, link = linkEmployeeID, typed = login
        Task { @MainActor in
            defer { busy = false }
            do {
                let outcome = try await cloud.createAccount(login: typed, password: pw, role: r)
                switch outcome {
                case .created:
                    if let link { store.linkAccount(employeeID: link, email: email) }
                    result = ("Hesap açıldı",
                              "\(LoginName.display(email)) şubeye \(CloudRole.title(r).lowercased(with: Locale(identifier: "tr_TR"))) olarak eklendi. Aşağıdaki mesajı kopyalayıp kişiye iletin; şifre bir daha gösterilmez.",
                              AccountMessage.created(branch: branch, email: email, role: r, password: pw))
                case .member:
                    if let link { store.linkAccount(employeeID: link, email: email) }
                    result = ("Şubeye eklendi",
                              "Bu hesap zaten vardı: şubeye eklendi, şifresi değişmedi (yazdığınız geçici şifre kullanılmadı). Kişi kendi şifresiyle girer.",
                              AccountMessage.existing(branch: branch, email: email, role: r))
                case .unconfirmed:
                    error = "\(LoginName.display(email)) için hesap açılamadı: bu e-postayla kendisi kayıt olmuş ama e-postasını doğrulamamış bir hesap var. Hesap başka bir patronun şubesinde de bulunduğu (ya da bir şubede patron olduğu) için şifresini siz belirleyemezsiniz; hiçbir şey değiştirilmedi. Kişi kayıt e-postasındaki doğrulama bağlantısını kullanmalı ya da diğer şubenin patronu “Şifre belirle” ile hesabı açmalı. Sonra burada tekrar “Hesap oluştur”a basın."
                }
                await onDone()
            } catch {
                self.error = CloudSyncController.memberErrorText(error)
            }
        }
    }
}

// MARK: - Şifre belirle

private struct SetPasswordSheet: View {
    @ObservedObject var cloud: CloudSyncController
    let member: CloudMember
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var touched = false
    @State private var busy = false
    @State private var error: String?
    @State private var message: String?

    private var passwordError: String? { PasswordRule.error(password) }

    var body: some View {
        let permission = CloudMembers.passwordPermission(member, myRole: cloud.role, myUserID: cloud.currentUserID)
        VStack(alignment: .leading, spacing: 14) {
            if let message {
                Label("Yeni şifre belirlendi", systemImage: "checkmark.circle.fill").font(.title2.weight(.semibold)).foregroundStyle(Brand.ok)
                Text("Eski şifresi artık geçmez; açık oturumları en geç 1 saat içinde kapanır. Mesajı kopyalayıp kişiye iletin.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                AccountMessageBox(message: message)
                HStack {
                    Spacer()
                    Button("Tamam") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(PrimaryButtonStyle())
                }
            } else {
                Text("\(member.displayName) için şifre belirle").font(.title2.weight(.semibold))
                Text("\(LoginName.display(member.email)) · \(CloudRole.title(member.role))").foregroundStyle(.secondary)
                Label("Eski şifresi hemen geçmez olur; web panelindeki ve Mac'teki açık oturumları en geç 1 saat içinde kapanır, sonra yeni şifreyle girer.",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(Brand.warn).fixedSize(horizontal: false, vertical: true)
                if !permission.can, let reason = permission.reason {
                    ReadOnlyNote(text: reason)
                }
                HStack(spacing: 8) {
                    TextField("Yeni geçici şifre", text: $password)
                        .textFieldStyle(.roundedBorder).autocorrectionDisabled().font(.body.monospaced())
                    Button("Güçlü şifre üret") { password = PasswordRule.generate() }
                        .buttonStyle(SoftButtonStyle())
                }
                if touched || !password.isEmpty, let e = passwordError {
                    Text(e).font(.caption).foregroundStyle(touched ? Brand.negative : Color.secondary)
                } else if let advice = PasswordRule.advice(password) {
                    Text(advice).font(.caption).foregroundStyle(Brand.warn)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(Brand.negative)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                HStack {
                    if busy { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Vazgeç") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                    Button("Şifreyi Belirle") { submit() }
                        .keyboardShortcut(.defaultAction).buttonStyle(PrimaryButtonStyle())
                        .disabled(busy || !permission.can || (touched && passwordError != nil))
                }
            }
        }
        .padding(22).frame(width: 520)
    }

    private func submit() {
        touched = true
        error = nil
        guard passwordError == nil, !busy else { return }
        busy = true
        let pw = password
        let branch = cloud.state.config?.workspaceName ?? ""
        Task { @MainActor in
            defer { busy = false }
            do {
                try await cloud.setMemberPassword(member, password: pw)
                message = AccountMessage.reset(branch: branch, email: member.email, password: pw)
            } catch {
                self.error = CloudSyncController.memberErrorText(error)
            }
        }
    }
}

// MARK: - Kişiye iletilecek mesaj

/// Kopyalanabilir mesaj kutusu
private struct AccountMessageBox: View {
    let message: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                Text(message)
                    .font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(height: 190)
            .background(Shapes.container.fill(Color.primary.opacity(0.05)))
            .overlay(Shapes.container.strokeBorder(Brand.line, lineWidth: 1))
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message, forType: .string)
                copied = true
            } label: { Label(copied ? "Kopyalandı" : "Mesajı Kopyala", systemImage: copied ? "checkmark" : "doc.on.doc") }
                .buttonStyle(SoftButtonStyle())
        }
    }
}

/// Hesap mesajları (web panelindeki accountMessage ile aynı içerik; Mac panel adresini bilmediği için adres satırı yok).
/// Kullanıcı adı hesabında yalnızca kullanıcı adı yazılır (giriş ekranları onu bekler).
private enum AccountMessage {
    private static let tr = Locale(identifier: "tr_TR")

    private static func loginLine(_ email: String) -> String {
        LoginName.isUsernameEmail(email) ? "Kullanıcı adı: \(LoginName.display(email))" : "E-posta: \(email)"
    }

    private static func noun(_ email: String) -> String {
        LoginName.isUsernameEmail(email) ? "kullanıcı adı" : "e-posta"
    }

    private static func macLine(_ email: String) -> String {
        "Mac'te: NextGen Envanter → Web'e Bağlan → \"Kullanıcı adı ve şifreyle bağlan\" → aynı \(noun(email)) ve şifreyle \"Bağlan\"a basın, listeden şubeyi seçin."
    }

    private static func webLine(_ email: String) -> String {
        "Web panelinde: aynı \(noun(email)) ve şifreyle \"Giriş yap\"a basın (telefon, tablet ya da bilgisayar)."
    }

    private static let changeLine = "İlk girişten sonra şifrenizi değiştirin: web panelinde Ayarlar → Hesap → \"Şifremi değiştir\"."
    private static let secretLine = "Bu bilgileri kimseyle paylaşmayın."

    static func created(branch: String, email: String, role: String, password: String) -> String {
        [
            "Merhaba, \"\(branch)\" şubesinin NextGen Envanter sisteminde size bir hesap açtım (yetki: \(CloudRole.title(role).lowercased(with: tr))).",
            "",
            loginLine(email),
            "Geçici şifre: \(password)",
            "",
            macLine(email),
            webLine(email),
            changeLine,
            secretLine,
        ].joined(separator: "\n")
    }

    static func reset(branch: String, email: String, password: String) -> String {
        [
            "Merhaba, NextGen Envanter hesabınız için yeni bir geçici şifre belirledim (\"\(branch)\" şubesi).",
            "",
            loginLine(email),
            "Yeni geçici şifre: \(password)",
            "",
            "Eski şifreniz artık geçmez. Web panelindeki ve Mac uygulamasındaki açık oturumlarınız en geç 1 saat içinde kapanır; sonra yeni şifreyle yeniden giriş yapın.",
            macLine(email),
            changeLine,
            secretLine,
        ].joined(separator: "\n")
    }

    static func existing(branch: String, email: String, role: String) -> String {
        [
            "Merhaba, \"\(branch)\" şubesinin NextGen Envanter sistemine \(CloudRole.title(role).lowercased(with: tr)) olarak eklendiniz.",
            "",
            "Mevcut hesabınızla (\(LoginName.display(email))) giriş yapın.",
            macLine(email),
            webLine(email),
            LoginName.isUsernameEmail(email)
                ? "Şifreniz değişmedi. Hatırlamıyorsanız bana haber verin; yeni bir geçici şifre belirleyebilirim."
                : "Şifreniz değişmedi. Hatırlamıyorsanız web panelinin giriş ekranındaki “Şifremi unuttum”u kullanın ya da bana haber verin; yeni bir geçici şifre belirleyebilirim.",
        ].joined(separator: "\n")
    }
}
