import SwiftUI
import AppKit
import EnvanterCore

/// Web paneliyle eşitlemenin ekrandaki durumu
enum CloudStatus: Equatable {
    /// Bağlı değil / kapalı
    case off
    /// Bağlı; son başarılı eşitleme zamanı (henüz yoksa nil)
    case idle(Date?)
    case syncing
    case error(String)
}

/// İlk bağlantıda iki tarafta da veri varsa (ya da başka şubeden boş şubeye geçilirken) kullanıcıya sorulan karar
struct InitialDecision: Identifiable {
    let id = UUID()
    let workspace: CloudWorkspace
    let rows: [RemoteDoc]
    /// Bu Mac'te ve bulutta kayıtlı gün sayısı
    let localDays: Int
    let remoteDays: Int
    /// Başka şubeden geçiş: bu Mac'in eşleştiği önceki şubenin adı (veri o şubenindir)
    var switchingFrom: String? = nil
    /// Geçişten vazgeçilirse geri dönülecek eşitleme durumu (önceki şube)
    var previous: SyncState? = nil
}

/// Mac uygulamasının web paneliyle (Supabase) arka planda eşitlenmesi (docs/SYNC.md).
/// Değişiklikten 8 sn sonra, 60 sn'de bir ve uygulama öne gelince eşitler. Otomatik test (ENVANTER_SELFTEST)
/// ve ekran görüntüsü (ENVANTER_SNAPSHOT_DIR) modlarında kapalıdır.
@MainActor
final class CloudSyncController: ObservableObject {
    @Published private(set) var status: CloudStatus = .off
    @Published private(set) var state: SyncState {
        didSet { publishRole() }
    }
    /// Birden fazla şube varsa seçim listesi
    @Published private(set) var workspaces: [CloudWorkspace] = []
    /// İlk bağlantı kararı bekleniyor
    @Published var decision: InitialDecision?
    /// Bağlanma / şube seçimi sürüyor
    @Published private(set) var busy = false
    /// Kartta gösterilen bilgi ya da hata metni
    @Published var notice: String?
    /// Gönderim ilerlemesi (çok sayıda belge yüklenirken)
    @Published private(set) var progress: (done: Int, total: Int)?
    /// Kapatılmış gün uyarısı bu oturumda gösterildi mi (bir kez)
    private var lockedDayNoticeShown = false

    /// Otomatik test / ekran görüntüsü modunda false
    let enabled: Bool
    private let syncStore: SyncStore
    private weak var app: AppStore?
    private var api: SupabaseAPI?
    /// Oturum / şube değişince artar; eski eşitleme turlarının sonucu uygulanmaz
    private var generation = 0
    private var isSyncing = false
    private var rerunRequested = false
    /// Açılışta "kaydedilmeden kalmış" değişiklikler bulunana kadar eşitleme bekler
    private var startupCheckDone = false
    /// Eşitleme sürerken kullanıcının değiştirdiği anahtarlar
    private var changedDuringSync = Set<String>()
    private var debounceTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var stateSaveTask: Task<Void, Never>?
    private var permissionNoticeShown = false
    private var observers: [NSObjectProtocol] = []
    private let saveQueue = DispatchQueue(label: "envanter.sync.state", qos: .utility)

    init(directory: URL, enabled: Bool) {
        self.enabled = enabled
        syncStore = SyncStore(directory: directory)
        state = enabled ? syncStore.load() : SyncState()
    }

    // MARK: - Durum

    /// Şube seçilmiş, oturum açık, ilk karar verilmiş
    var isConnected: Bool { enabled && state.isActive }

    /// Kenar çubuğunda eşitleme satırı gösterilsin mi (oturum süresi dolduysa da hata gösterilir; çıkış yapıldıysa değil)
    var showsStatus: Bool { enabled && state.config?.workspaceID != nil && state.initialized && !state.signedOut }

    /// Oturumun süresi dolmuş, yeniden giriş gerekiyor (şube eşleşmesi korunuyor)
    var needsSignIn: Bool { enabled && state.config?.workspaceID != nil && state.initialized && !state.isSignedIn && !state.signedOut }

    /// Çıkış yapıldı ama şube eşleşmesi korunuyor: yeniden girişte kaldığı yerden devam edilir
    var isSignedOutWithLink: Bool { enabled && state.signedOut && state.config?.workspaceID != nil && state.initialized }

    var role: String? { state.config?.role }
    var pendingChanges: Int { state.dirty.count }

    // MARK: - Başlatma

    func attach(_ app: AppStore) {
        self.app = app
        publishRole()
        guard enabled else { status = .off; startupCheckDone = true; return }
        status = state.isActive ? .idle(state.lastSyncAt) : (needsSignIn ? .error(CloudSyncError.sessionExpired.localizedDescription) : .off)

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appBecameActive() }
        })
        observers.append(nc.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveStateNow() }
        })
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(CloudDefaults.intervalSeconds * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.syncNow()
            }
        }

        // Uygulama kapanmadan önce durum dosyası yazılamamış değişiklikleri bul (tabandan ayrışan belgeler)
        guard state.config?.workspaceID != nil, state.initialized else { startupCheckDone = true; return }
        let data = app.data, st = state
        Task { [weak self] in
            let keys = await Task.detached(priority: .utility) { CloudSyncEngine.divergentKeys(local: data, state: st) }.value
            guard let self else { return }
            if !keys.isEmpty {
                self.state.dirty.formUnion(keys)
                self.saveState()
            }
            self.startupCheckDone = true
            self.scheduleSync(after: 1.5)
        }
    }

    /// Yerel değişikliklerde uygulanacak rolü AppStore'a bildirir (personel: tanımlar ve kapatılmış günler salt okunur)
    private func publishRole() {
        let role = enabled ? state.enforcedRole : nil
        if let app, app.enforcedRole != role { app.enforcedRole = role }
    }

    private func appBecameActive() {
        guard isConnected else { return }
        if let last = state.lastSyncAt, Date().timeIntervalSince(last) < 15 { return }
        syncNow()
    }

    // MARK: - Yerel değişiklikler

    /// AppStore her kullanıcı değişikliğinde çağırır (buluttan gelenler hariç)
    func noteLocalChange(_ keys: Set<String>) {
        guard enabled, !keys.isEmpty, state.config?.workspaceID != nil, state.initialized else { return }
        state.dirty.formUnion(keys)
        if isSyncing { changedDuringSync.formUnion(keys) }
        scheduleStateSave()
        if state.isActive { scheduleSync(after: CloudDefaults.debounceSeconds) }
    }

    // MARK: - Bağlanma

    /// E-posta ve şifreyle giriş yapar; şubeleri getirir. Hiç şube yoksa (ilk kurulum) şube adıyla yenisini açar.
    func connect(email rawEmail: String, password: String, url rawURL: String, key rawKey: String) async {
        guard enabled, !busy else { return }
        let email = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        var url = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        var key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.isEmpty { url = CloudDefaults.url }
        if key.isEmpty { key = CloudDefaults.publishableKey }
        guard !email.isEmpty, !password.isEmpty else {
            notice = "E-posta adresinizi ve şifrenizi girin."
            return
        }
        busy = true
        notice = nil
        defer { busy = false }
        do {
            let api = try SupabaseAPI(url: url, publishableKey: key)
            let session = try await api.signIn(email: email, password: password)
            generation += 1
            self.api = api
            // Aynı sunucuda şube eşleşmesi (taban, bekleyen değişiklikler) korunur, hesap farklı olsa da: aynı şube
            // seçilirse kaldığı yerden 3 yollu birleştirmeyle devam edilir. Şube onaylanana kadar eşitleme bekler.
            var s = SyncState.forSignIn(existing: state, url: url, publishableKey: key, email: email)
            s.store(session)
            s.userEmail = session.email ?? email
            state = s
            saveState()
            try await loadWorkspaces(api: api, autoSelect: true)
        } catch {
            report(error)
        }
    }

    /// Şube listesini yeniler (şube değiştirmek için)
    func showWorkspacePicker() async {
        guard let api = currentAPI() else { return }
        busy = true
        defer { busy = false }
        do { try await loadWorkspaces(api: api, autoSelect: false) } catch { report(error) }
    }

    private func loadWorkspaces(api: SupabaseAPI, autoSelect: Bool) async throws {
        var list = try await api.myWorkspaces()
        if list.isEmpty {
            // İlk kurulum: hiç şube yoksa bu hesap patron olur ve şube adıyla yeni şube açılır
            let branch = app?.settings.branchName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            do {
                _ = try await api.createWorkspace(name: branch.isEmpty ? "Şubem" : branch)
            } catch CloudSyncError.forbidden {
                throw CloudSyncError.noWorkspace
            }
            list = try await api.myWorkspaces()
            guard !list.isEmpty else { throw CloudSyncError.noWorkspace }
        }
        storeSession(await api.currentSession)
        guard autoSelect else { workspaces = list; return }
        if let current = state.config?.workspaceID, state.initialized {
            if let w = list.first(where: { $0.id == current }) {
                await choose(w)        // aynı şubeye yeniden giriş
            } else {
                // Bu Mac başka bir şubeyle eşleşmiş (ör. o şubeye üye olmayan başka bir hesap): şube değişimi
                // kendiliğinden yapılmaz, kullanıcı seçer
                workspaces = list
                notice = "Bu Mac \"\(state.config?.workspaceName ?? "önceki şube")\" şubesiyle eşleşmişti; bu hesap o şubeye üye değil. Eşitlenecek şubeyi seçin."
            }
        } else if list.count == 1 {
            await choose(list[0])
        } else {
            workspaces = list          // kullanıcı seçecek
        }
    }

    /// Şube seçim listesini kapatır (şube değiştirmekten vazgeçildi)
    func dismissWorkspacePicker() {
        workspaces = []
        if isSignedOutWithLink { notice = nil }
    }

    /// Şube seçimi. Daha önce eşleşmiş şubeyse kaldığı yerden devam eder (çıkış yapıp yeniden girmek dahil); değilse
    /// ilk bağlantı kararı verilir. Başka şubeden geçişte bu Mac'in verisi o şubenindir: dolu şubeye geçince o şubenin
    /// verisi indirilir (yerel yedek alınır), boş şubeye geçince ne kopyalanacağı sorulur (kendiliğinden yüklenmez).
    func choose(_ w: CloudWorkspace) async {
        guard let api = currentAPI(), let app else { return }
        workspaces = []
        var s = state
        switch CloudSyncEngine.workspaceChoice(state: s, workspaceID: w.id) {
        case .resume:
            // Personelken eskimiş kalan tanımlar önce web'deki haline döner (rol yükseldiyse yerel değişiklik
            // sanılmasın); oturum kapalıyken yapılan değişiklikler gönderilmek üzere işaretlenir.
            let data = CloudSyncEngine.resume(workspace: w, local: app.data, state: &s)
            let dataChanged = !DocCodec.changedKeys(app.data, data).isEmpty
            if dataChanged { app.applyRemote(data) }
            state = s
            SyncCheckpoint.persist(dataChanged: dataChanged, writeData: { app.writeDataNow() }, writeState: { saveState() })
            status = .idle(s.lastSyncAt)
            syncNow()
            return
        case .initial(let switching):
            // Gönderilmemiş değişiklikler önceki şubeye gönderilmeden geçilmez (oturum açıkken beklenebilir)
            if switching && state.isActive && !state.dirty.isEmpty {
                notice = "Bekleyen \(state.dirty.count) değişiklik gönderildikten sonra şube değiştirilebilir."
                syncNow()
                return
            }
            busy = true
            defer { busy = false }
            generation += 1
            let previous: SyncState? = switching ? s : nil
            let previousName = switching ? s.config?.workspaceName : nil
            s.resetWorkspaceData()
            s.config?.workspaceID = w.id
            s.config?.workspaceName = w.name
            s.config?.role = w.role
            state = s
            saveState()
            do {
                let rows = try await api.pull(workspace: w.id, since: 0)
                storeSession(await api.currentSession)
                let mode = CloudSyncEngine.initialMode(localIsSeedOnly: DocCodec.isSeedOnly(app.data),
                                                       remoteEmpty: CloudSyncEngine.isRemoteEmpty(rows),
                                                       switchingFromOtherWorkspace: switching)
                if mode == .ask {
                    let remoteDays = Set(rows.filter { !$0.deleted && DocKey.isDay($0.key) }.map { $0.key }).count
                    let localDays = app.data.days.values.filter { DocCodec.storedDay($0) != nil }.count
                    decision = InitialDecision(workspace: w, rows: rows, localDays: localDays, remoteDays: remoteDays,
                                               switchingFrom: switching ? (previousName ?? "önceki şube") : nil,
                                               previous: previous)
                    status = .off
                    return
                }
                resolve(mode, rows: rows)
            } catch {
                report(error)
            }
        }
    }

    /// İlk bağlantı kararı (kullanıcı seçti)
    func resolveDecision(_ mode: InitialSyncMode) {
        guard let d = decision, mode != .ask else { return }
        decision = nil
        resolve(mode, rows: d.rows)
    }

    /// İlk bağlantıdan vazgeç: şube eşleşmesi kaldırılır (oturum açık kalır). Başka şubeden geçişten vazgeçilirse
    /// önceki şubeyle eşitleme kaldığı yerden sürer.
    func cancelDecision() {
        let previous = decision?.previous
        decision = nil
        generation += 1
        if var p = previous {
            p.store(state.session)
            p.userEmail = state.userEmail ?? p.userEmail
            state = p
            saveState()
            let name = p.config?.workspaceName ?? ""
            if state.isActive {
                status = .idle(p.lastSyncAt)
                notice = "Şube değiştirilmedi; \"\(name)\" şubesiyle eşitleme sürüyor."
                syncNow()
            } else {
                // Önceki şubeye bu hesapla erişilemiyor (ör. farklı hesap): eşleşme korunur, eşitleme bekler
                status = .off
                notice = "Şube değiştirilmedi. Bu Mac \"\(name)\" şubesiyle eşleşmiş durumda; o şubeye üye bir hesapla giriş yapın ya da yeniden bağlanıp başka şube seçin."
            }
            return
        }
        var s = state
        s.resetWorkspaceData()
        s.config?.workspaceID = nil
        s.config?.workspaceName = nil
        s.config?.role = nil
        state = s
        saveState()
        status = .off
        notice = "Eşitleme başlatılmadı. Şube seçmek için yeniden bağlanın."
    }

    private func resolve(_ mode: InitialSyncMode, rows: [RemoteDoc]) {
        guard let app, mode != .ask else { return }
        let p = app.persistence
        // Riskli adımlardan önce yedek: indirmede ve şube değişiminde bu Mac'teki veri, yüklemede buluttaki veri
        if mode == .download || mode == .copyCatalog, let enc = try? p.encode(app.data) {
            p.snapshot(enc, label: mode == .download ? "bulut-indirme-oncesi" : "sube-degisimi-oncesi")
        }
        if mode == .upload, !CloudSyncEngine.isRemoteEmpty(rows), let enc = try? p.encode(CloudSyncEngine.assembleRemote(rows)) {
            p.snapshot(enc, label: "bulut-yukleme-oncesi")
        }
        var s = state
        s.signedOut = false
        let newData = CloudSyncEngine.prepareInitial(mode: mode, local: app.data, rows: rows, state: &s)
        let dataChanged = !DocCodec.changedKeys(app.data, newData).isEmpty
        if dataChanged {
            app.applyRemote(newData)
            // Eski geri alma adımları indirilen verinin üzerine eski hali yazmasın
            app.clearUndoHistory()
        }
        state = s
        // Önce veri, sonra durum: yeni taban eski veriyle diskte kalmasın
        SyncCheckpoint.persist(dataChanged: dataChanged, writeData: { app.writeDataNow() }, writeState: { saveState() })
        startupCheckDone = true
        status = .idle(nil)
        switch mode {
        case .download:
            notice = "Buluttaki veri indirildi. Bu Mac'in önceki hali Yedekler klasörüne kaydedildi."
        case .copyCatalog:
            notice = "Stok kalemleri, reçeteler ve ayarlar \"\(s.config?.workspaceName ?? "")\" şubesine yükleniyor. Bu Mac'in önceki hali Yedekler klasörüne kaydedildi."
        default:
            notice = "Bu Mac'teki veri web paneline yükleniyor…"
        }
        syncNow()
    }

    // MARK: - Eşitleme

    /// Hemen eşitle (sürüyorsa bitince bir tur daha)
    func syncNow() {
        guard enabled, state.isActive else { return }
        guard startupCheckDone else { rerunRequested = true; return }
        if isSyncing { rerunRequested = true; return }
        debounceTask?.cancel()
        isSyncing = true
        let gen = generation
        Task { [weak self] in await self?.performSync(generation: gen) }
    }

    private func scheduleSync(after seconds: Double) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.syncNow()
        }
    }

    private func performSync(generation gen: Int) async {
        defer { finishSyncCycle() }
        guard let app, let api = currentAPI() else { return }
        changedDuringSync = []
        status = .syncing
        let started = app.data
        var st = state
        do {
            let out = try await CloudSyncEngine.syncOnce(local: started, state: &st, api: api) { done, total in
                Task { @MainActor [weak self] in
                    if total > 1 && done < total {
                        self?.progress = (done: done, total: total)
                    } else {
                        self?.progress = nil
                    }
                }
            }
            guard gen == generation else { return }
            // Eşitleme sürerken yapılan değişiklikler korunur ve yeniden gönderilmek üzere işaretlenir
            let current = app.data
            let (final, changed) = DocCodec.rebase(started: started, current: current, synced: out.data)
            st.dirty.formUnion(changed)
            st.dirty.formUnion(changedDuringSync)
            let dataChanged = !DocCodec.changedKeys(current, final).isEmpty
            if dataChanged { app.applyRemote(final) }
            state = st
            // Önce veri dosyası, sonra durum: tabanı ilerlemiş durum eski veriyle diskte kalırsa (çökme / zorla kapatma)
            // yeniden açılışta eski belgeler güncel tabanla gönderilip web panelindeki değişikliği ezerdi
            SyncCheckpoint.persist(dataChanged: dataChanged, writeData: { app.writeDataNow() }, writeState: { saveState() })
            if !out.rejected.isEmpty { reportRejected(out.rejected) }
            if let e = out.error {
                report(e)
            } else {
                status = .idle(st.lastSyncAt)
                if out.rejected.isEmpty { notice = nil }
            }
            if !changed.isEmpty || !changedDuringSync.isEmpty { rerunRequested = true }
        } catch {
            guard gen == generation else { return }
            storeSession(await api.currentSession)
            report(error)
        }
    }

    private func finishSyncCycle() {
        isSyncing = false
        progress = nil
        if rerunRequested {
            rerunRequested = false
            scheduleSync(after: 2)
        }
    }

    // MARK: - Çıkış

    /// Oturumu kapatır. Şube eşleşmesi (taban, bekleyen değişiklikler) korunur: yeniden girişte aynı şube seçilince
    /// kaldığı yerden 3 yollu birleştirmeyle devam edilir, arada web panelinde yapılan değişiklikler ezilmez.
    /// `detach`: bu Mac şubeden de ayrılır (eşleşme ve gönderilmemiş değişiklik kaydı silinir; yeniden bağlanınca
    /// ilk bağlantı kararı sorulur). Bu Mac'teki veri her iki durumda da silinmez.
    func signOut(detach: Bool = false) {
        generation += 1
        debounceTask?.cancel()
        if let api { Task { await api.logout() } }
        api = nil
        // Şube değişimi kararı bekleniyorsa önceki şubenin eşleşmesi korunur
        var s = decision?.previous ?? state
        s.signOut()
        if detach {
            s.resetWorkspaceData()
            s.config?.workspaceID = nil
            s.config?.workspaceName = nil
            s.config?.role = nil
        }
        state = s
        saveState()
        workspaces = []
        decision = nil
        status = .off
        if s.config?.workspaceID != nil && s.initialized {
            notice = "Çıkış yapıldı. Bu Mac'teki veriler ve \"\(s.config?.workspaceName ?? "")\" şubesiyle eşleşme korunuyor; yeniden giriş yaptığınızda kaldığınız yerden devam edilir."
        } else {
            notice = "Çıkış yapıldı. Bu Mac'teki veriler yerinde duruyor."
        }
    }

    // MARK: - Yardımcılar

    private func currentAPI() -> SupabaseAPI? {
        if let api { return api }
        guard let c = state.config, let session = state.session else { return nil }
        api = try? SupabaseAPI(url: c.url, publishableKey: c.publishableKey, session: session)
        return api
    }

    private func storeSession(_ s: AuthSession?) {
        guard let s else { return }
        state.store(s)
        saveState()
    }

    private func report(_ error: Error) {
        let e = (error as? CloudSyncError) ?? .network(error.localizedDescription)
        if e == .sessionExpired {
            // Yenileme anahtarı geçersiz: yeniden giriş gerekir (şube eşleşmesi ve bekleyen değişiklikler korunur)
            api = nil
            var s = state
            s.store(nil)
            state = s
            saveState()
        }
        let message = e.localizedDescription
        status = .error(message)
        notice = message
    }

    /// Sunucunun reddettiği (ve sunucudaki haline döndürülen) anahtarlar: kapatılmış günler ve tanım belgeleri için
    /// ayrı metin; uyarı penceresi her tür için oturumda bir kez gösterilir. Reddedilen anahtar yeniden denenmez.
    private func reportRejected(_ rejected: [String: String]) {
        let days = DocKey.sorted(rejected.keys.filter { DocKey.isDay($0) })
        let catalog = DocKey.sorted(rejected.keys.filter { !DocKey.isDay($0) })
        var parts: [String] = []
        if !days.isEmpty {
            let dates = days.map { Self.label(for: $0) }.joined(separator: ", ")
            parts.append("\(CloudPermission.lockedDayMessage) \(dates) gününün web panelindeki hali geri yüklendi.")
            if !lockedDayNoticeShown {
                lockedDayNoticeShown = true
                app?.alert = AppAlert(
                    title: "Gün kapatılmış",
                    message: "\(dates) günü web panelinde kapatılmış. \(CloudPermission.lockedDayMessage) Bu Mac'teki değişiklik gönderilmedi ve günün web panelindeki hali geri yüklendi. Düzeltme gerekiyorsa patron ya da müdür günün kilidini açabilir.")
            }
        }
        if !catalog.isEmpty {
            let labels = catalog.map { Self.label(for: $0) }.joined(separator: ", ")
            parts.append("Bu değişiklik için müdür yetkisi gerekir (\(labels)). Web panelindeki hal geri yüklendi.")
            if !permissionNoticeShown {
                permissionNoticeShown = true
                app?.alert = AppAlert(
                    title: "Bu değişiklik için müdür yetkisi gerekir",
                    message: "Personel hesabıyla yalnızca günlük veriler (sayım, satış, vardiya, not) web paneline gönderilir. \(labels) bölümündeki değişiklik gönderilmedi ve web panelindeki hal geri yüklendi. Bu değişikliği patron ya da müdür web panelinden yapabilir.")
            }
        }
        notice = parts.joined(separator: " ")
        // Rol değişmiş olabilir (ör. müdürken personele alındı): şube listesinden güncelle
        if let api = currentAPI() {
            let wsID = state.config?.workspaceID
            Task { [weak self] in
                guard let list = try? await api.myWorkspaces(), let w = list.first(where: { $0.id == wsID }) else { return }
                guard let self, self.state.config?.workspaceID == w.id else { return }
                self.state.config?.role = w.role
                self.state.config?.workspaceName = w.name
                self.saveState()
            }
        }
    }

    nonisolated static func label(for key: String) -> String { DocKey.title(key) }

    private func scheduleStateSave() {
        stateSaveTask?.cancel()
        stateSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.saveState()
        }
    }

    /// Durum dosyasını arka planda yazar (sırayla)
    private func saveState() {
        guard enabled else { return }
        stateSaveTask?.cancel()
        let s = state, store = syncStore
        saveQueue.async {
            do { try store.save(s) } catch { NSLog("Eşitleme durumu kaydedilemedi: \(error)") }
        }
    }

    private func saveStateNow() {
        guard enabled else { return }
        let s = state, store = syncStore
        saveQueue.sync {
            do { try store.save(s) } catch { NSLog("Eşitleme durumu kaydedilemedi: \(error)") }
        }
    }
}
