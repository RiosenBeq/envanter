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

/// İlk bağlantıda iki tarafta da veri varsa kullanıcıya sorulan karar
struct InitialDecision: Identifiable {
    let id = UUID()
    let workspace: CloudWorkspace
    let rows: [RemoteDoc]
    /// Bu Mac'te ve bulutta kayıtlı gün sayısı
    let localDays: Int
    let remoteDays: Int
}

/// Mac uygulamasının web paneliyle (Supabase) arka planda eşitlenmesi (docs/SYNC.md).
/// Değişiklikten 8 sn sonra, 60 sn'de bir ve uygulama öne gelince eşitler. Otomatik test (ENVANTER_SELFTEST)
/// ve ekran görüntüsü (ENVANTER_SNAPSHOT_DIR) modlarında kapalıdır.
@MainActor
final class CloudSyncController: ObservableObject {
    @Published private(set) var status: CloudStatus = .off
    @Published private(set) var state: SyncState
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

    /// Kenar çubuğunda eşitleme satırı gösterilsin mi (oturum süresi dolduysa da hata gösterilir)
    var showsStatus: Bool { enabled && state.config?.workspaceID != nil && state.initialized }

    /// Oturumun süresi dolmuş, yeniden giriş gerekiyor (şube eşleşmesi korunuyor)
    var needsSignIn: Bool { enabled && state.config?.workspaceID != nil && state.initialized && !state.isSignedIn }

    var role: String? { state.config?.role }
    var pendingChanges: Int { state.dirty.count }

    // MARK: - Başlatma

    func attach(_ app: AppStore) {
        self.app = app
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
            var s = state
            let sameAccount = s.config.map { $0.email.lowercased() == email.lowercased() && $0.url == url } ?? false
            if !sameAccount {
                s = SyncState(config: CloudConfig(url: url, publishableKey: key, email: email))
            } else {
                s.config?.publishableKey = key
            }
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
        if let current = state.config?.workspaceID, state.initialized, let w = list.first(where: { $0.id == current }) {
            await choose(w)            // aynı şubeye yeniden giriş
        } else if list.count == 1 {
            await choose(list[0])
        } else {
            workspaces = list          // kullanıcı seçecek
        }
    }

    /// Şube seçimi. Daha önce eşleşmiş şubeyse kaldığı yerden devam eder; değilse ilk bağlantı kararı verilir.
    func choose(_ w: CloudWorkspace) async {
        guard let api = currentAPI(), let app else { return }
        workspaces = []
        var s = state
        if s.config?.workspaceID == w.id && s.initialized {
            s.config?.workspaceName = w.name
            s.config?.role = w.role
            // Oturum kapalıyken yapılan değişiklikler
            s.dirty.formUnion(CloudSyncEngine.divergentKeys(local: app.data, state: s))
            state = s
            saveState()
            status = .idle(s.lastSyncAt)
            syncNow()
            return
        }
        busy = true
        defer { busy = false }
        generation += 1
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
                                                   remoteEmpty: CloudSyncEngine.isRemoteEmpty(rows))
            if mode == .ask {
                let remoteDays = Set(rows.filter { !$0.deleted && DocKey.isDay($0.key) }.map { $0.key }).count
                let localDays = app.data.days.values.filter { DocCodec.storedDay($0) != nil }.count
                decision = InitialDecision(workspace: w, rows: rows, localDays: localDays, remoteDays: remoteDays)
                status = .off
                return
            }
            resolve(mode, rows: rows)
        } catch {
            report(error)
        }
    }

    /// İlk bağlantı kararı (kullanıcı seçti)
    func resolveDecision(_ mode: InitialSyncMode) {
        guard let d = decision, mode != .ask else { return }
        decision = nil
        resolve(mode, rows: d.rows)
    }

    /// İlk bağlantıdan vazgeç: şube eşleşmesi kaldırılır (oturum açık kalır)
    func cancelDecision() {
        decision = nil
        generation += 1
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
        // Riskli adımlardan önce yedek: indirmede bu Mac'teki veri, yüklemede buluttaki veri
        if mode == .download, let enc = try? p.encode(app.data) {
            p.snapshot(enc, label: "bulut-indirme-oncesi")
        }
        if mode == .upload, !CloudSyncEngine.isRemoteEmpty(rows), let enc = try? p.encode(CloudSyncEngine.assembleRemote(rows)) {
            p.snapshot(enc, label: "bulut-yukleme-oncesi")
        }
        var s = state
        let newData = CloudSyncEngine.prepareInitial(mode: mode, local: app.data, rows: rows, state: &s)
        state = s
        saveState()
        if !DocCodec.changedKeys(app.data, newData).isEmpty {
            app.applyRemote(newData)
            // Eski geri alma adımları indirilen verinin üzerine eski hali yazmasın
            app.clearUndoHistory()
        }
        startupCheckDone = true
        status = .idle(nil)
        notice = mode == .download
            ? "Buluttaki veri indirildi. Bu Mac'in önceki hali Yedekler klasörüne kaydedildi."
            : "Bu Mac'teki veri web paneline yükleniyor…"
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
            state = st
            if !DocCodec.changedKeys(current, final).isEmpty { app.applyRemote(final) }
            saveState()
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

    /// Oturumu kapatır ve şube eşleşmesini kaldırır. Bu Mac'teki veri silinmez.
    func signOut() {
        generation += 1
        debounceTask?.cancel()
        if let api { Task { await api.logout() } }
        api = nil
        var s = state
        s.store(nil)
        s.userEmail = nil
        s.resetWorkspaceData()
        s.config?.workspaceID = nil
        s.config?.workspaceName = nil
        s.config?.role = nil
        state = s
        saveState()
        workspaces = []
        decision = nil
        status = .off
        notice = "Çıkış yapıldı. Bu Mac'teki veriler yerinde duruyor."
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

    private func reportRejected(_ rejected: [String: String]) {
        let labels = rejected.keys.sorted().map { Self.label(for: $0) }.joined(separator: ", ")
        notice = "Bu değişiklik için müdür yetkisi gerekir (\(labels)). Web panelindeki hal geri yüklendi."
        if !permissionNoticeShown {
            permissionNoticeShown = true
            app?.alert = AppAlert(
                title: "Bu değişiklik için müdür yetkisi gerekir",
                message: "Personel hesabıyla yalnızca günlük veriler (sayım, satış, vardiya, not) web paneline gönderilir. \(labels) bölümündeki değişiklik gönderilmedi ve web panelindeki hal geri yüklendi. Bu değişikliği patron ya da müdür web panelinden yapabilir.")
        }
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

    nonisolated static func label(for key: String) -> String {
        switch key {
        case DocKey.items: return "Stok kalemleri"
        case DocKey.products: return "Reçeteler"
        case DocKey.settings: return "Ayarlar"
        case DocKey.employees: return "Personel"
        case DocKey.orders: return "Siparişler"
        default: return DocKey.date(of: key).map { DateKey.short($0) } ?? key
        }
    }

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
