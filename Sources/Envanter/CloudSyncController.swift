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
/// Web panelindeki değişiklik canlı bağlantıyla (Supabase Realtime, `RealtimeClient`) anında çekilir; yerel değişiklik
/// `CloudDefaults.debounceSeconds` (2 sn) sonra gönderilir. 60 sn'lik düzenli tur ve uygulamanın öne gelişi güvenlik
/// ağıdır (canlı bağlantı kopukken de çalışır). Otomatik test (ENVANTER_SELFTEST) ve ekran görüntüsü
/// (ENVANTER_SNAPSHOT_DIR) modlarında kapalıdır; canlı bağlantı da kurulmaz.
@MainActor
final class CloudSyncController: ObservableObject {
    @Published private(set) var status: CloudStatus = .off {
        // Başarılı eşitlemede ya da kapanınca son hata unutulur; yeniden denenirken (syncing) gösterilmeye devam eder
        didSet {
            switch status {
            case .idle, .off: if lastError != nil { lastError = nil }
            case .syncing, .error: break
            }
        }
    }
    /// Son eşitleme / bağlanma hatası: ne olduğu ve ne yapılacağı `issue` ile gösterilir
    @Published private(set) var lastError: CloudSyncError?
    @Published private(set) var state: SyncState {
        // Tek yaşam döngüsü kancası: rol, canlı bağlantının açılıp kapanması (bağlanma, şube seçimi / değişimi, ilk
        // bağlantı kararı, çıkış, oturum süresinin dolması) ve yenilenen erişim anahtarı buradan izlenir
        didSet {
            publishRole()
            updateRealtime(tokenChanged: oldValue.accessToken != state.accessToken)
        }
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
    /// Canlı bağlantının (Supabase Realtime) durumu: `.connected` iken web panelindeki değişiklikler anında gelir;
    /// değilse 60 sn'lik düzenli eşitleme sürer. Bağlı değilken ya da bu modda kapalıyken `.disconnected`.
    @Published private(set) var realtimeStatus: RealtimeStatus = .disconnected
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
    /// Veri dosyasıyla ortak seri yazma kuyruğu (AppStore.diskQueue): durum kaydı, kuyrukta bekleyen veri yazmasının
    /// önüne geçemez (docs/SYNC.md §3 "Kayıt sırası")
    private let diskQueue: DiskWriteQueue
    /// Şube listesinden (rol, şube adı) son denetim zamanı; rol web panelinde değişebilir
    private var lastRoleCheck: Date?
    /// Bir sonraki eşitleme turunda rol de denetlensin (uygulama öne geldi)
    private var roleCheckRequested = false
    /// Kayıtlı sunucu eski varsayılan projeydi; açılışta yeni varsayılana geçildi (`SyncState.movingOffRetiredDefault`)
    private var movedOffRetiredDefault = false
    /// Canlı bağlantı istemcisi (ilk bağlanmada oluşturulur; otomatik test / ekran görüntüsü modunda hiç oluşturulmaz).
    /// deinit'ten de durdurulabilsin diye Sendable bir kutuda tutulur.
    private let realtimeBox = RealtimeBox()
    /// Çalışan canlı bağlantının anahtarı (sunucu | anahtar | şube); nil: kapalı. Değişince bağlantı yeniden kurulur.
    private var realtimeKey: String?
    /// Canlı bağlantıdan değişiklik bildirimi geldi ve eşitleme sürüyordu: tur bitince yeni tur 2 sn yerine 0,3 sn sonra
    private var remotePending = false
    /// Son "Bağlan" denemesindeki giriş adı (e-posta; kullanıcı adı ad@envanter.local): giriş hatasının metni kullanıcı adı
    /// hesabına göre seçilir
    private var lastLogin: String?
    /// Bu oturum süresi dolmasında cihaz hesabıyla sessiz giriş denendi mi: her süre dolmasında bir kez (geçici hatada
    /// beklemeyle yeniden denenir: `DeviceSignIn.retryDelay`)
    private var silentSignInAttempted = false
    /// Sessiz girişin art arda geçici hatayla başarısız olma sayısı (bekleme süresi buna göre uzar)
    private var silentSignInFailures = 0
    /// Bu zamandan önce sessiz giriş denenmez: geçici hatadan sonra bekleme; başarılı girişten sonra, yeni oturumla bir
    /// eşitleme başarılı olana kadar (`DeviceSignIn.cooldownAfterSuccess`)
    private var silentSignInNotBefore: Date?
    /// Sessiz giriş geçici bir hatayla başarısız oldu ve kendiliğinden yeniden denenecek (hata metni buna göre seçilir)
    private var silentRetryScheduled = false
    /// Bağlıyken yarım kalan şifre değiştirme (kayıtta hâlâ kod var) bu zamandan önce yeniden denenmez
    private var rotationRetryNotBefore: Date?

    init(directory: URL, enabled: Bool, diskQueue: DiskWriteQueue) {
        self.enabled = enabled
        self.diskQueue = diskQueue
        syncStore = SyncStore(directory: directory)
        let loaded = enabled ? syncStore.load() : SyncState()
        if let moved = loaded.movingOffRetiredDefault() {
            state = moved
            movedOffRetiredDefault = true
        } else {
            state = loaded
        }
    }

    deinit {
        realtimeBox.client?.stop()
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

    /// Bu Mac bir şubeyle eşleşmiş mi (şube seçilmiş ve ilk bağlantı kararı verilmiş; oturum kapalı olsa da). Eşleşmemiş
    /// Mac'te eski sayan listesi yerelde ekibe taşınır (AppStore); eşleşmişte bunu eşitleme turu yapar.
    var isLinked: Bool { enabled && state.config?.workspaceID != nil && state.initialized }

    /// Oturumdaki kullanıcının kimliği (erişim anahtarındaki `sub`; oturum yoksa nil). Kullanıcılar panelinde kendi
    /// satırını tanımak için (kendi şifresi, kendi yetkisi, kendini çıkarma).
    var currentUserID: String? { state.accessToken.flatMap { JWTClaims.subject($0) } }

    /// Kullanıcı hesaplarını bu Mac'ten yönetebilir mi: web paneline bağlı ve bu şubede patron
    var canManageMembers: Bool { isConnected && role == CloudRole.owner }

    /// Canlı bağlantı açık mı: web panelindeki değişiklikler anında gelir
    var isLive: Bool { isConnected && realtimeStatus == .connected }

    /// Bu Mac bağlantı koduyla (cihaz hesabıyla) bağlandı mı
    var isDeviceAccount: Bool { PairCode.isDeviceAccount(state.config?.email ?? "") }

    /// Bağlantı koduyla bağlanmış ve çıkış yapılmış (ya da oturumu düşmüş) Mac: kod yeniden sorulmadan "Yeniden Bağlan"
    var canReconnectDevice: Bool { enabled && state.reconnectableDevice != nil }

    /// Güncel sorun (yoksa nil): kısa ad, açıklama ve ne yapılacağı. Bağlıyken oluşan hatada değişikliklerin bu Mac'te
    /// beklediği ve kendiliğinden gönderileceği; bağlanırken oluşan hatada yeniden "Bağlan"a basılacağı söylenir.
    var issue: CloudIssue? {
        guard let e = lastError else { return nil }
        switch status {
        case .error, .syncing:
            // Sessiz girişi kendiliğinden yeniden denenecek cihaz hesabında da değişiklikler bu Mac'te bekler
            let linked = state.isActive || (state.silentSignIn != nil && silentRetryScheduled)
            return Self.issue(for: e, connected: linked, login: lastLogin ?? state.userEmail ?? state.config?.email,
                              deviceKept: state.reconnectableDevice != nil)
        case .idle, .off: return nil
        }
    }

    /// Hatanın ekrandaki hali. Giriş hatalarında metin web panelinin giriş ekranıyla aynı yolu söyler: kullanıcı adı
    /// hesabında şifreyi patron "Şifre belirle" ile yeniler (e-postayla sıfırlama yok), e-posta hesabında web panelinin
    /// giriş ekranındaki "Şifremi unuttum" kullanılır.
    /// - Parameters:
    ///   - connected: bu Mac bir şubeyle eşitlenirken mi oldu
    ///   - login: denenen giriş adı (e-posta; kullanıcı adı hesaplarında ad@envanter.local)
    ///   - deviceKept: bağlantı koduyla bağlanan bu Mac'in cihaz kaydı duruyor ("Yeniden Bağlan" yeni kod istemez)
    nonisolated static func issue(for e: CloudSyncError, connected: Bool, login: String?, deviceKept: Bool = false) -> CloudIssue {
        var issue = e.issue(connected: connected)
        let username = login.map { LoginName.isUsernameEmail($0) } ?? false
        // Bağlantı koduyla bağlanan bilgisayarın cihaz hesabı (pc-…@envanter.local): şifre yerine kod konuşulur
        let device = login.map { PairCode.isDeviceAccount($0) } ?? false
        switch e {
        case .invalidCredentials:
            if device {
                // Kişi şifre yazmadı: durum etiketi de kodu söyler
                issue.title = CloudSyncGuide.invalidPairCodeTitle
                issue.message = CloudSyncGuide.invalidPairCode
                issue.hint = CloudSyncGuide.pairCodeHelp + " Bu bilgisayarın bağlantısı web panelinden kaldırıldıysa da yeni bir kod gerekir."
            } else if username {
                issue.message = "Kullanıcı adı veya şifre hatalı."
                issue.hint = "Büyük/küçük harfe dikkat edin. Şifrenizi unuttuysanız patronunuz web panelinde Yönetim → Kullanıcılar ekranında (ya da kendi Mac'inde Ekip → Kullanıcılar bölümünde) “Şifre belirle” ile size yeni bir geçici şifre verir; kullanıcı adı hesaplarında e-postayla şifre sıfırlama yoktur."
            } else {
                issue.message = "E-posta veya şifre hatalı."
                issue.hint = "Büyük/küçük harfe dikkat edin. Şifrenizi unuttuysanız web panelinin giriş ekranındaki “Şifremi unuttum”u kullanın ya da patronunuzdan Yönetim → Kullanıcılar → “Şifre belirle” ile yeni bir şifre isteyin."
            }
        case .emailNotConfirmed:
            issue.message = "E-posta adresiniz henüz doğrulanmadı."
            issue.hint = "Kayıt olurken gelen e-postadaki doğrulama bağlantısına tıklayın (gereksiz/spam klasörüne de bakın). E-posta gelmediyse patronunuz Yönetim → Kullanıcılar → “Hesap oluştur” ile aynı e-postayı ve size vereceği geçici şifreyi girerek hesabınızı açabilir; sonra o şifreyle bağlanırsınız."
        case .network where !connected:
            issue.message = "Sunucuya ulaşılamıyor."
            issue.hint = "İnternet bağlantınızı kontrol edip yeniden \"Bağlan\"a basın. Bu sırada uygulamayı kullanmaya devam edebilirsiniz; veriler bu Mac'e kaydedilir."
        case .sessionExpired where device:
            if deviceKept {
                // Kayıtlı şifre reddedilmedi (ör. sunucu yeni oturumu hemen reddetti): yeni kod gerekmez
                issue.hint = "Bu bilgisayarın kayıtlı bağlantısı duruyor; yeni kod gerekmez. Birkaç dakika içinde kendiliğinden yeniden girilmeye çalışılır; hemen denemek için yan menüdeki Web'e Yeniden Bağlan'a (ya da Ayarlar → Web paneli ile eşitleme kartındaki “Yeniden Bağlan”a) basın. Bekleyen değişiklikler bu Mac'te korunuyor."
            } else {
                issue.hint = "Bu bilgisayarın web paneli bağlantısı geçersiz oldu (patron bağlantıyı kaldırmış olabilir). Patronunuzdan yeni bir bağlantı kodu isteyip Web'e Bağlan'dan girin; bekleyen değişiklikler bu Mac'te korunuyor."
            }
        default:
            break
        }
        return issue
    }

    // MARK: - Başlatma

    func attach(_ app: AppStore) {
        self.app = app
        publishRole()
        guard enabled else { status = .off; startupCheckDone = true; return }
        if state.isActive {
            status = .idle(state.lastSyncAt)
        } else if needsSignIn {
            // Bağlantı koduyla bağlanan bilgisayar kayıtlı şifresiyle sessizce yeniden girer; değilse "Giriş gerekli"
            if !startSilentSignIn() { showSignInNeeded() }
        } else {
            status = .off
        }
        if movedOffRetiredDefault {
            // Eski projenin oturum anahtarları ve şube eşleşmesi dosyadan da silinsin
            saveState()
            notice = "Eşitleme sunucusu değişti (yeni Supabase projesi). Bu Mac'teki veriler yerinde duruyor; web paneli kullanıcı adınız (ya da e-postanız) ve şifrenizle yeniden bağlanıp şubeyi seçin."
        }

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appBecameActive() }
        })
        observers.append(nc.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stopRealtime()
                self?.saveStateNow()
            }
        })
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(CloudDefaults.intervalSeconds * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
        // Kayıtlı oturumla açılış: canlı bağlantı hemen kurulur (state didSet başlatıcıda çalışmaz)
        updateRealtime(tokenChanged: false)

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
        guard isConnected else {
            if needsSignIn { startSilentSignIn() }
            return
        }
        // Rol web panelinde değişmiş olabilir (ör. personel müdüre yükseltildi): öne gelişte şube listesi de okunur
        roleCheckRequested = true
        let now = Date()
        if let last = state.lastSyncAt, now.timeIntervalSince(last) < 15,
           let checked = lastRoleCheck, now.timeIntervalSince(checked) < 15 { return }
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

    // MARK: - Canlı bağlantı

    /// Canlı bağlantıyı duruma göre açar / kapatır: yalnızca bu mod açıkken ve Mac şubeyle eşitlenirken (şube seçilmiş,
    /// oturum açık, ilk karar verilmiş) çalışır. Sunucu / şube değişince yeniden kurulur; erişim anahtarı yenilenince kanala
    /// hemen bildirilir. `state` her değiştiğinde çağrılır; anahtar aynıysa iş yapmaz.
    private func updateRealtime(tokenChanged: Bool) {
        // Bağlantı koduyla bağlanan bilgisayarın cihaz adı ("pc-7kq2m9"): web panelindeki bağlı bilgisayarlar listesi
        // çevrimiçi olanı tanır. Kişi hesabında nil (çevrimiçi bilgisinde gönderilmez).
        let device = state.config.flatMap { PairCode.deviceName(forEmail: $0.email) }
        let want: String? = {
            guard enabled, state.isActive, let c = state.config, let ws = c.workspaceID else { return nil }
            return "\(c.url)|\(c.publishableKey)|\(ws)|\(c.workspaceName ?? "")|\(device ?? "")"
        }()
        guard want != realtimeKey else {
            if tokenChanged, want != nil, let token = state.accessToken, !token.isEmpty {
                realtimeBox.client?.updateToken(token)
            }
            return
        }
        stopRealtime()
        guard let want, let config = state.config, let ws = config.workspaceID else { return }
        realtimeKey = want
        let presence = RealtimePresence.mac(branch: config.workspaceName ?? "", app: Self.appVersion, since: Date(), device: device)
        // Anahtar her katılmada ve kalp atışında sorulur: dolmak üzereyse yenilenir (yenilenen oturum sessionChanged ile
        // hemen diske yazılır)
        realtimeClient().start(config: config, workspaceID: ws, deviceKey: Self.deviceKey(), presence: presence,
                               accessToken: { [weak self] in
                                   guard let api = await self?.realtimeAPI() else { return nil }
                                   return try? await api.validAccessToken()
                               })
    }

    /// Canlı bağlantıyı kapatır (çıkış, şube değişimi, ilk bağlantı kararı, oturum süresinin dolması, uygulamanın kapanması)
    private func stopRealtime() {
        guard realtimeKey != nil else { return }
        realtimeKey = nil
        realtimeBox.client?.stop()
        if realtimeStatus != .disconnected { realtimeStatus = .disconnected }
    }

    /// Canlı bağlantının anahtar kaynağı için geçerli istemci (oturum yoksa nil)
    private func realtimeAPI() -> SupabaseAPI? {
        guard realtimeKey != nil else { return nil }
        return currentAPI()
    }

    /// İstemci ilk gerektiğinde oluşturulur; geri çağrılar ana kuyrukta gelir
    private func realtimeClient() -> RealtimeClient {
        if let c = realtimeBox.client { return c }
        let c = RealtimeClient(transport: URLSessionRealtimeTransport())
        c.onChange = { [weak self] in
            MainActor.assumeIsolated { self?.remoteChanged() }
        }
        c.onStatus = { [weak self] status in
            MainActor.assumeIsolated { self?.realtimeStatusChanged(status) }
        }
        realtimeBox.client = c
        return c
    }

    /// Web panelinde (ya da başka bir cihazda) belge değişti: 0,3 sn içinde çek. Eşitleme sürüyorsa tur bitince
    /// 0,3 sn sonra yeni tur yapılır. Kendi gönderimimizin yankısı da gelir; tek bir hafif çekme turu olur.
    private func remoteChanged() {
        guard realtimeKey != nil, isConnected else { return }
        if isSyncing || !startupCheckDone {
            remotePending = true
            rerunRequested = true
            return
        }
        scheduleSync(after: RealtimeClient.coalesceSeconds)
    }

    private func realtimeStatusChanged(_ status: RealtimeStatus) {
        // Kapatıldıktan sonra kuyruktan gelen eski bildirim yok sayılır
        guard realtimeKey != nil else { return }
        let was = realtimeStatus
        if was != status { realtimeStatus = status }
        // Kanala (yeniden) katılındı: kopukken kaçan değişiklikler bir kez çekilir
        if status == .connected && was != .connected { syncNow() }
    }

    /// Bu kurulumun kalıcı cihaz anahtarı (canlı bağlantıdaki çevrimiçi bilgisinin anahtarı; kişisel bilgi içermez)
    private static func deviceKey() -> String {
        let defaults = UserDefaults.standard
        if let key = defaults.string(forKey: "envanterDeviceID"), !key.isEmpty { return key }
        let key = "mac-" + UUID().uuidString.lowercased()
        defaults.set(key, forKey: "envanterDeviceID")
        return key
    }

    /// Çevrimiçi bilgisindeki uygulama sürümü (geliştirme derlemesinde "dev")
    private static var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
    }

    // MARK: - Bağlanma

    /// Kullanıcı adı (ya da e-posta) ve şifreyle giriş yapar; şubeleri getirir. Hiç şube yoksa (ilk kurulum) şube adıyla
    /// yenisini açar. Kullanıcı adı ("@" yok) ad@envanter.local e-postasına çevrilir (`LoginName`) ve öyle saklanır.
    func connect(email rawEmail: String, password: String, url rawURL: String, key rawKey: String) async {
        guard enabled, !busy else { return }
        var url = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        var key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.isEmpty { url = CloudDefaults.url }
        if key.isEmpty { key = CloudDefaults.publishableKey }
        guard !rawEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !password.isEmpty else {
            notice = "Kullanıcı adınızı (ya da e-postanızı) ve şifrenizi girin."
            return
        }
        guard let email = LoginName.email(from: rawEmail) else {
            notice = "Geçerli bir kullanıcı adı ya da e-posta yazın: kullanıcı adında en az bir harf ya da rakam olmalı (harf, rakam, nokta, alt çizgi ve tire kullanılabilir)."
            return
        }
        await signIn(email: email, passwords: [password], url: url, key: key)
    }

    /// Bağlantı koduyla bağlanır (patronun web panelinde "Bilgisayar Bağla" ile ürettiği kod; kodu içeren mesaj ya da
    /// envanter:// bağlantısı da olur). Sunucu verilmezse bu Mac'te kayıtlı sunucu, o da yoksa varsayılan kullanılır.
    /// Girişten hemen sonra cihaz hesabına yeni şifre verilir: kod bir daha kullanılamaz (`rotateDevicePassword`). Kod bu
    /// Mac'in kayıtlı cihaz hesabınınsa (kullanılmış kod yeniden yazıldı ya da bağlantı yeniden açıldı) önce kayıtlı
    /// şifreler denenir: bilgisayar yeni kod istemeden girer, kayıt silinmez.
    func connect(code rawCode: String, url rawURL: String? = nil, key rawKey: String? = nil) async {
        guard enabled, !busy else { return }
        guard let code = PairCode.parse(rawCode) else {
            notice = "Bağlantı kodunu yazın: XXXX-XXXX-XXXX-XXXX biçiminde 16 karakter. " + CloudSyncGuide.pairCodeHelp
            return
        }
        var url = rawURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var key = rawKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if url.isEmpty { url = state.config?.url ?? CloudDefaults.url }
        // Kayıtlı sunucuyla aynı adres (sondaki "/" ya da büyük/küçük harf farkı): kayıtlı hali kullanılır, şube
        // eşleşmesi korunur (`SyncState.forSignIn` adresleri birebir karşılaştırır)
        let saved = state.config
        if let saved, CloudDefaults.sameServer(url, saved.url) { url = saved.url }
        if key.isEmpty { key = url == saved?.url ? (saved?.publishableKey ?? CloudDefaults.publishableKey) : CloudDefaults.publishableKey }
        await signIn(email: PairCode.email(code), passwords: state.devicePasswords(forCode: code, url: url), url: url, key: key)
    }

    /// "Yeniden Bağlan": bağlantı koduyla bağlanmış bu Mac, çıkıştan sonra kayıtlı şifresiyle (kod sorulmadan) yeniden girer
    func reconnectDevice() async {
        guard enabled, !busy, let login = state.reconnectableDevice, let c = state.config else { return }
        await signIn(email: login.email, passwords: login.passwords, url: c.url, key: c.publishableKey)
    }

    /// Ortak giriş: şifreler sırayla denenir (`DeviceSignIn`; kişi hesabında tek şifre). Cihaz hesabında geçen şifre
    /// saklanır, şifre hâlâ bağlantı koduysa hesaba yeni şifre verilir; kişi hesabıyla girişte eski cihaz kaydı silinir.
    /// Sonra şubeler getirilir (şube seçimi, ilk bağlantı kararı ve şube değişimi her girişte aynı).
    private func signIn(email: String, passwords: [String], url: String, key: String) async {
        lastLogin = email
        busy = true
        notice = nil
        silentSignInAttempted = false
        silentSignInFailures = 0
        silentSignInNotBefore = nil
        silentRetryScheduled = false
        // Yeni deneme: önceki denemenin hatası "Bağlanıyor…" sırasında gösterilmesin
        if case .error = status { status = .off }
        defer { busy = false }
        let device = PairCode.isDeviceAccount(email)
        do {
            let api = try SupabaseAPI(url: url, publishableKey: key)
            let result = await DeviceSignIn.attempt(DeviceLogin(email: email, passwords: passwords)) { e, p in
                try await api.signIn(email: e, password: p)
            }
            guard let session = result.session else {
                // Cihaz hesabının kayıtlı şifrelerinin hepsi denendi ve reddedildi (bağlantı kaldırıldı): kayıt silinir,
                // yeni kod gerekir. Yalnızca başka bir şifre ya da kullanılmış bir kod reddedildiyse kayıt korunur.
                if device, result.login == nil, state.shouldForgetDeviceLogin(email: email, tried: passwords, url: url) {
                    state.deviceLogin = nil
                    saveState()
                }
                throw result.error ?? CloudSyncError.invalidCredentials
            }
            generation += 1
            install(api)
            // Aynı sunucuda şube eşleşmesi (taban, bekleyen değişiklikler) korunur, hesap farklı olsa da: aynı şube
            // seçilirse kaldığı yerden 3 yollu birleştirmeyle devam edilir. Şube onaylanana kadar eşitleme bekler.
            var s = SyncState.forSignIn(existing: state, url: url, publishableKey: key, email: email)
            s.store(session)
            s.userEmail = session.email ?? email
            s.deviceLogin = device ? result.login : nil
            state = s
            saveState()
            if device, result.needsNewPassword, let code = result.password {
                await rotateDevicePassword(api: api, email: email, code: code)
            }
            try await loadWorkspaces(api: api, autoSelect: true)
        } catch {
            report(error)
        }
    }

    /// Bağlantı koduyla girişten sonra: cihaz hesabına rastgele yeni şifre verilir, kod bir daha geçmez. İstekten önce
    /// [yeni, kod] diske yazılır (istek sunucuda uygulanıp uygulama kapanırsa da yeni şifre bilinsin); yazılamazsa istek
    /// gönderilmez (kod geçerli kalır). Sonra kabul edildiyse [yeni], kesin olarak reddedildiyse [kod], sonuç
    /// bilinmiyorsa (ağ hatası) ikisi de saklanır. Kabul edilmediyse bağlıyken yeniden denenir
    /// (`retryDeviceRotationIfDue`). Şifreler gösterilmez ve günlüğe yazılmaz.
    private func rotateDevicePassword(api: SupabaseAPI, email: String, code: String) async {
        let fresh = DevicePassword.generate()
        state.deviceLogin = DeviceLogin.rotating(email: email, newPassword: fresh, code: code)
        let outcome: PasswordChangeOutcome
        if await saveStateAndWait() {
            do {
                try await api.updatePassword(fresh)
                outcome = .applied
            } catch {
                outcome = PasswordChangeOutcome(error: error)
            }
        } else {
            // [yeni, kod] diske yazılamadı: şifre değişirse uygulama yeniden açılınca yeni şifre bilinmezdi
            outcome = .rejected
        }
        rotationRetryNotBefore = outcome == .applied ? nil : Date().addingTimeInterval(DeviceLogin.rotationRetrySeconds)
        // Bu sırada "Şubeden Ayır" ile kayıt silindiyse dokunulmaz
        guard let login = state.deviceLogin, login.email == email else { return }
        state.deviceLogin = login.after(outcome)
        saveState()
    }

    /// Bağlıyken yarım kalan şifre değiştirmeyi yeniden dener: kayıtta hâlâ kod biçiminde bir şifre varsa (istek
    /// reddedildi, sonucu bilinmiyor ya da durum diske yazılamadı) kod geçerli kalmasın. Düzenli turda, en fazla
    /// `DeviceLogin.rotationRetrySeconds`'ta bir.
    private func retryDeviceRotationIfDue() {
        guard enabled, isConnected, !busy, let login = state.deviceLogin, login.rotationRetry != .notNeeded,
              TextFold.asciiLowercased(login.email) == TextFold.asciiLowercased(state.config?.email ?? "") else { return }
        if let wait = rotationRetryNotBefore, Date() < wait { return }
        guard let api = currentAPI(), let c = state.config else { return }
        rotationRetryNotBefore = Date().addingTimeInterval(DeviceLogin.rotationRetrySeconds)
        busy = true
        let gen = generation
        Task { [weak self] in await self?.performRotationRetry(login, api: api, config: c, generation: gen) }
    }

    private func performRotationRetry(_ login: DeviceLogin, api: SupabaseAPI, config c: CloudConfig, generation gen: Int) async {
        defer { busy = false }
        let code: String
        switch login.rotationRetry {
        case .notNeeded:
            return
        case .rotate(let current):
            code = current
        case .verify:
            // Önceki isteğin sonucu bilinmiyor: hangi şifrenin geçtiği ayrı bir girişle bulunur (bu oturuma dokunulmaz;
            // deneme oturumu kapatılmaz: çıkış isteği hesabın bütün oturumlarını kapatırdı)
            guard let probe = try? SupabaseAPI(url: c.url, publishableKey: c.publishableKey) else { return }
            let result = await DeviceSignIn.attempt(login) { e, p in try await probe.signIn(email: e, password: p) }
            // Bu sırada çıkış yapıldıysa, başka hesapla girildiyse ya da kayıt değiştiyse sonuç uygulanmaz. Hepsi
            // reddedildiyse ya da geçici hatada kayda dokunulmaz (bağlantı kaldırıldıysa oturum düşünce anlaşılır).
            guard gen == generation, state.deviceLogin == login, result.session != nil, let kept = result.login else { return }
            state.deviceLogin = kept
            saveState()
            guard result.needsNewPassword, let current = result.password else {
                // Önceki istek uygulanmış: şifre artık kod değil
                rotationRetryNotBefore = nil
                return
            }
            code = current
        }
        guard gen == generation, isConnected else { return }
        await rotateDevicePassword(api: api, email: login.email, code: code)
    }

    // MARK: - Sessiz giriş (bağlantı koduyla bağlanan bilgisayar)

    /// Düzenli tur: bağlıyken eşitleme (ve yarım kalan şifre değiştirme); oturumu düşmüş cihaz hesabında sessiz giriş
    /// (geçici hatadan sonra beklemeyle) yeniden denenir
    private func tick() {
        if needsSignIn {
            startSilentSignIn()
        } else {
            syncNow()
            retryDeviceRotationIfDue()
        }
    }

    /// Oturumun süresi doldu ve bu Mac bağlantı koduyla bağlandı: kayıtlı şifrelerle sırayla, sessizce yeniden girilir
    /// (her süre dolmasında bir kez; geçici hatada beklemeyle yeniden). Başarısızsa hata ya da "Giriş gerekli" gösterilir.
    /// - Returns: deneme başladı mı
    @discardableResult
    private func startSilentSignIn() -> Bool {
        guard enabled, !busy, !silentSignInAttempted, let login = state.silentSignIn, let c = state.config else { return false }
        if let wait = silentSignInNotBefore, Date() < wait { return false }
        silentSignInAttempted = true
        busy = true
        status = .syncing
        let gen = generation
        Task { [weak self] in await self?.performSilentSignIn(login, config: c, generation: gen) }
        return true
    }

    private func performSilentSignIn(_ login: DeviceLogin, config c: CloudConfig, generation gen: Int) async {
        defer { busy = false }
        guard let api = try? SupabaseAPI(url: c.url, publishableKey: c.publishableKey) else {
            showSignInNeeded()
            return
        }
        let result = await DeviceSignIn.attempt(login) { e, p in try await api.signIn(email: e, password: p) }
        // Bu sırada çıkış yapıldıysa, başka hesapla girildiyse ya da şube değiştiyse sonuç uygulanmaz
        guard gen == generation, state.silentSignIn?.email == login.email else { return }
        lastLogin = login.email
        guard let session = result.session else {
            guard result.login != nil, let e = result.error else {
                // Şifrelerin hepsi reddedildi (bağlantı web panelinden kaldırıldı): kayıt silinir, yeni bağlantı kodu gerekir
                state.deviceLogin = nil
                saveState()
                silentSignInFailures = 0
                silentSignInNotBefore = nil
                silentRetryScheduled = false
                showSignInNeeded()
                return
            }
            // Kayıt geçerli; asıl hata gösterilir (bağlantı yok, sunucu hatası, çok fazla deneme). Geçici hatada
            // beklemeyle kendiliğinden yeniden denenir (bağlantı yok: bir sonraki düzenli turda ya da uygulama öne
            // gelince); başka bir hatada "Yeniden Bağlan" beklenir.
            silentSignInFailures += 1
            if let delay = DeviceSignIn.retryDelay(after: e, failures: silentSignInFailures) {
                silentSignInAttempted = false
                silentSignInNotBefore = Date().addingTimeInterval(delay)
                silentRetryScheduled = true
            } else {
                silentRetryScheduled = false
            }
            lastError = e
            status = .error(e.localizedDescription)
            return
        }
        generation += 1
        install(api)
        var s = state
        s.store(session)
        s.userEmail = session.email ?? login.email
        s.deviceLogin = result.login
        state = s
        saveState()
        silentSignInAttempted = false
        silentSignInFailures = 0
        silentRetryScheduled = false
        // Yeni oturumla bir eşitleme başarılı olana kadar yeni sessiz giriş beklenir: sunucu yeni oturumu hemen
        // reddederse (ör. yanlış yapılandırılmış sunucu) giriş döngüye girmesin
        silentSignInNotBefore = Date().addingTimeInterval(DeviceSignIn.cooldownAfterSuccess)
        status = .idle(s.lastSyncAt)
        if result.needsNewPassword, let code = result.password {
            await rotateDevicePassword(api: api, email: login.email, code: code)
        }
        syncNow()
    }

    /// "Giriş gerekli": şube eşleşmesi ve bekleyen değişiklikler korunur, kartta ne yapılacağı yazar
    private func showSignInNeeded() {
        lastError = .sessionExpired
        status = .error(CloudSyncError.sessionExpired.localizedDescription)
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
        lastRoleCheck = Date()
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
            checkpoint(app, dataChanged: dataChanged)
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
        // Bağlantı koduyla bağlanan Mac: kod kullanıldı ama kayıtlı şifresiyle "Yeniden Bağlan" (reconnectableDevice)
        notice = state.reconnectableDevice != nil
            ? "Eşitleme başlatılmadı. Şube seçmek için “Yeniden Bağlan”a basın; yeni kod gerekmez."
            : "Eşitleme başlatılmadı. Şube seçmek için yeniden bağlanın."
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
        checkpoint(app, dataChanged: dataChanged)
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
        // Bu tur buluttaki son hali çeker: önceki canlı bildirim karşılanmış olur
        remotePending = false
        status = .syncing
        // Rol önce güncellenir: terfide eskimiş tanımlar geri yüklenir, düşürülmede gönderim yeni rolle yapılır
        await refreshRoleIfDue(api: api, generation: gen)
        guard gen == generation, state.isActive else { return }
        changedDuringSync = []
        let started = app.data
        var st = state
        do {
            // Paylaşılan bilgisayarda çalışan değişiklik geçmişi özetine eklenir (" · Murat A."; SessionWorker). Yalnızca
            // seçildiği cihaz hesabıyla bağlıyken (`activeWorker`): kişisel hesapla bağlanınca eklenmez
            let out = try await CloudSyncEngine.syncOnce(local: started, state: &st, api: api, worker: app.activeWorker) { done, total in
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
            checkpoint(app, dataChanged: dataChanged)
            if !out.rejected.isEmpty { reportRejected(out.rejected) }
            if let e = out.error {
                report(e)
            } else {
                status = .idle(st.lastSyncAt)
                if out.rejected.isEmpty { notice = nil }
                // Oturum sunucuda geçerli: oturum yeniden düşerse sessiz giriş beklemeden denenir
                silentSignInNotBefore = nil
                silentSignInFailures = 0
            }
            if !changed.isEmpty || !changedDuringSync.isEmpty { rerunRequested = true }
        } catch {
            guard gen == generation else { return }
            storeSession(await api.currentSession)
            report(error)
        }
    }

    /// Rol ve şube adı web panelinde değişebilir (patron "Hesap oluştur"la açtığı personeli müdüre yükseltir ya da müdürü
    /// personele alır; oturum kapanmaz). Şube listesi açılıştan sonraki ilk turda, en fazla 5 dakikada bir
    /// (`CloudDefaults.roleCheckSeconds`) ve uygulama öne gelince okunur; yoksa personel kısıtları (yerel rol denetimi,
    /// gizli "Kilidi Aç") çıkış yapıp yeniden girene kadar sürerdi. Okunamazsa (ağ hatası) sessizce geçilir; eşitleme
    /// turu hatayı zaten gösterir.
    private func refreshRoleIfDue(api: SupabaseAPI, generation gen: Int) async {
        let now = Date()
        let due = roleCheckRequested || (lastRoleCheck.map { now.timeIntervalSince($0) >= CloudDefaults.roleCheckSeconds } ?? true)
        guard due else { return }
        roleCheckRequested = false
        lastRoleCheck = now
        guard let list = try? await api.myWorkspaces() else { return }
        applyRoleRefresh(list, generation: gen)
    }

    /// Şube listesindeki rol / ad bu Mac'tekinden farklıysa uygular (CloudSyncEngine.refreshRole). Eşitleme turu
    /// verinin kopyasını aldıktan sonra çağrılmamalı: turun sonundaki yeniden birleştirme, geri yüklenen tanımları
    /// yerel değişiklik sanardı (performSync turun başında, reportRejected tur bitince çağırır).
    private func applyRoleRefresh(_ list: [CloudWorkspace], generation gen: Int) {
        guard gen == generation, state.isActive, let app else { return }
        var s = state
        guard let data = CloudSyncEngine.refreshRole(workspaces: list, local: app.data, state: &s) else { return }
        let dataChanged = !DocCodec.changedKeys(app.data, data).isEmpty
        if dataChanged { app.applyRemote(data) }
        state = s
        checkpoint(app, dataChanged: dataChanged)
    }

    private func finishSyncCycle() {
        isSyncing = false
        progress = nil
        if rerunRequested {
            rerunRequested = false
            // Tur sürerken web panelinden değişiklik geldiyse hemen (0,3 sn), yoksa 2 sn sonra yeni tur
            scheduleSync(after: remotePending ? RealtimeClient.coalesceSeconds : 2)
        }
    }

    // MARK: - Kullanıcılar (patron)

    /// Şubenin üyeleri ve bekleyen davetleri (envanter_members_list). Davetleri yalnızca patron görür.
    /// Hatalar Türkçe metinlidir (`CloudMemberError.message`, `CloudSyncError`); metin için `memberErrorText`.
    func membersList() async throws -> [CloudMember] {
        let (api, ws) = try memberContext(ownerOnly: false)
        return try await memberCall { try await api.membersList(workspace: ws) }
    }

    /// E-posta gerektirmeden hesap açar ve şubeye ekler. `login`: kullanıcı adı ya da e-posta (kullanıcı adı
    /// ad@envanter.local olur). `role`: `CloudRole.owner` / `.manager` / `.staff`. Şifre `PasswordRule` kuralına uymalı.
    func createAccount(login: String, password: String, role: String) async throws -> CreateAccountResult {
        let (api, ws) = try memberContext(ownerOnly: true)
        guard let email = LoginName.email(from: login) else {
            throw CloudMemberError(kind: .invalid, message: CloudMembers.accountError(login, members: []) ?? "Kullanıcı adı ya da e-posta yazın.")
        }
        return try await memberCall { try await api.createAccount(workspace: ws, email: email, password: password, role: role) }
    }

    /// Üyenin yetkisini değiştirir (son patron düşürülemez). Kendi yetkisi değişirse rol hemen yeniden okunur.
    func setRole(_ member: CloudMember, to role: String) async throws {
        let (api, ws) = try memberContext(ownerOnly: true)
        guard let user = member.userID else { throw CloudMemberError(kind: .invalid, message: CloudMembers.passwordPendingReason) }
        try await memberCall { try await api.setRole(workspace: ws, user: user, role: role) }
        if user == currentUserID { refreshRoleSoon() }
    }

    /// Üyenin şifresini belirler: eski şifre hemen geçmez, açık oturumları en geç 1 saat içinde kapanır
    func setMemberPassword(_ member: CloudMember, password: String) async throws {
        let (api, ws) = try memberContext(ownerOnly: true)
        guard let user = member.userID else { throw CloudMemberError(kind: .invalid, message: CloudMembers.passwordPendingReason) }
        try await memberCall { try await api.setMemberPassword(workspace: ws, user: user, password: password) }
    }

    /// Üyeyi şubeden çıkarır (son patron çıkarılamaz). Bu Mac'te oturumu açık kullanıcı kendini çıkaramaz (eşitleme dururdu).
    func removeMember(_ member: CloudMember) async throws {
        let (api, ws) = try memberContext(ownerOnly: true)
        guard let user = member.userID else { throw CloudMemberError(kind: .invalid, message: CloudMembers.passwordPendingReason) }
        guard user != currentUserID else {
            throw CloudMemberError(kind: .invalid, message: "Bu Mac'te oturumu açık hesabı buradan çıkaramazsınız; gerekirse web panelinden yapın.")
        }
        try await memberCall { try await api.removeMember(workspace: ws, user: user) }
    }

    /// Bekleyen daveti iptal eder (bu e-postayla hesap açılsa bile şubeye eklenmez)
    func cancelInvite(_ member: CloudMember) async throws {
        let (api, ws) = try memberContext(ownerOnly: true)
        try await memberCall { try await api.cancelInvite(workspace: ws, email: member.email) }
    }

    /// Kullanıcı işlemi hatasının ekrandaki metni (ne oldu ve ne yapılmalı)
    nonisolated static func memberErrorText(_ error: Error) -> String {
        if let m = error as? CloudMemberError { return m.message }
        if let e = error as? CloudSyncError {
            switch e {
            case .forbidden:
                return CloudMembers.ownerOnlyReason + " Yetkiniz web panelinde değiştiyse bir sonraki eşitlemede bu Mac'te de güncellenir."
            case .sessionExpired:
                return "Oturumun süresi doldu. Ayarlar → Web paneli ile eşitleme kartından (ya da yan menüdeki Web'e Bağlan ile) yeniden giriş yapın."
            case .network:
                return "Sunucuya ulaşılamadı. İnternet bağlantınızı kontrol edip tekrar deneyin."
            default:
                return e.localizedDescription
            }
        }
        return error.localizedDescription
    }

    /// İşlemin yapılabileceği istemci ve şube; yoksa Türkçe hata
    private func memberContext(ownerOnly: Bool) throws -> (SupabaseAPI, String) {
        guard isConnected, let ws = state.config?.workspaceID, let api = currentAPI() else { throw CloudSyncError.notConfigured }
        if ownerOnly && role != CloudRole.owner {
            throw CloudMemberError(kind: .forbidden, message: CloudMembers.ownerOnlyReason)
        }
        return (api, ws)
    }

    /// Sunucu çağrısı: oturum süresi dolduysa eşitleme kartı "Giriş gerekli" gösterir; ağ hataları Türkçeye çevrilir
    private func memberCall<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch let e as CloudMemberError {
            throw e
        } catch let e as CloudSyncError {
            if e == .sessionExpired { report(e) }
            // Yetki reddi: rol web panelinde değişmiş olabilir
            if case .forbidden = e { refreshRoleSoon() }
            throw e
        } catch {
            throw CloudSyncError.network(error.localizedDescription)
        }
    }

    /// Rolü (şube listesi) bir sonraki turda yeniden oku ve hemen eşitle
    private func refreshRoleSoon() {
        roleCheckRequested = true
        syncNow()
    }

    /// Ekip ekranına geç (Ayarlar'daki "Kullanıcılar…" düğmesi; Kullanıcılar bölümü orada)
    func showUsers() {
        app?.section = .team
    }

    // MARK: - Çıkış

    /// Oturumu kapatır. Şube eşleşmesi (taban, bekleyen değişiklikler) korunur: yeniden girişte aynı şube seçilince
    /// kaldığı yerden 3 yollu birleştirmeyle devam edilir, arada web panelinde yapılan değişiklikler ezilmez.
    /// `detach`: bu Mac şubeden de ayrılır (eşleşme ve gönderilmemiş değişiklik kaydı silinir; yeniden bağlanınca
    /// ilk bağlantı kararı sorulur). Bu Mac'teki veri her iki durumda da silinmez.
    func signOut(detach: Bool = false) {
        generation += 1
        debounceTask?.cancel()
        stopRealtime()
        if let api { Task { await api.logout() } }
        api = nil
        remotePending = false
        silentSignInAttempted = false
        silentSignInFailures = 0
        silentSignInNotBefore = nil
        silentRetryScheduled = false
        // Şube değişimi kararı bekleniyorsa önceki şubenin eşleşmesi korunur
        var s = decision?.previous ?? state
        s.signOut()
        if detach {
            s.resetWorkspaceData()
            s.config?.workspaceID = nil
            s.config?.workspaceName = nil
            s.config?.role = nil
            // Bağlantı koduyla bağlanan Mac'in cihaz hesabı da unutulur: yeniden bağlanmak için yeni kod gerekir
            s.deviceLogin = nil
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
        guard let c = state.config, let session = state.session,
              let created = try? SupabaseAPI(url: c.url, publishableKey: c.publishableKey, session: session) else { return nil }
        install(created)
        return created
    }

    /// Bu oturumun istemcisi olur. Yenilenen oturum (yeni yenileme anahtarı; eskisi geçersizleşir) hemen esitleme.json'a
    /// yazılır: yoksa uygulama tur bitmeden kapanırsa diskteki eski anahtarla yeniden giriş gerekirdi.
    private func install(_ api: SupabaseAPI) {
        self.api = api
        let id = ObjectIdentifier(api)
        let observer: @Sendable (AuthSession?) -> Void = { [weak self] session in
            Task { @MainActor [weak self] in self?.sessionChanged(session, api: id) }
        }
        Task { await api.setSessionObserver(observer) }
    }

    /// Oturum değişti (giriş, yenileme ya da yenileme reddi). Eski bir istemcinin bildirimi yok sayılır.
    private func sessionChanged(_ session: AuthSession?, api id: ObjectIdentifier) {
        guard enabled, let current = api, ObjectIdentifier(current) == id else { return }
        guard let session else {
            // Yenileme anahtarı reddedildi: eşitleme turu "Giriş gerekli" hatasını gösterir ve oturumu kapatır
            syncNow()
            return
        }
        guard state.config != nil,
              session.accessToken != state.accessToken || session.refreshToken != (state.refreshToken ?? "") else { return }
        state.store(session)
        saveState()
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
            stopRealtime()
            api = nil
            var s = state
            s.store(nil)
            state = s
            saveState()
            // Bağlantı koduyla bağlanan bilgisayar önce kayıtlı şifresiyle sessizce yeniden girer
            if startSilentSignIn() {
                notice = nil
                return
            }
        }
        // Hata kartın üstündeki kutuda (issue) bir kez gösterilir; önceki bilgi notu (ör. "yükleniyor…") silinir
        lastError = e
        status = .error(e.localizedDescription)
        notice = nil
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
                    message: "Personel hesabıyla yalnızca günlük veriler (sayım, satış, not) web paneline gönderilir. \(labels) bölümündeki değişiklik gönderilmedi ve web panelindeki hal geri yüklendi. Bu değişikliği patron ya da müdür web panelinden yapabilir.")
            }
        }
        notice = parts.joined(separator: " ")
        // Rol değişmiş olabilir (ör. müdürken personele alındı): şube listesinden güncelle. Bu sırada yeni bir eşitleme
        // turu başlamışsa güncelleme bir sonraki turun başına bırakılır.
        if let api = currentAPI() {
            let gen = generation
            lastRoleCheck = Date()
            Task { [weak self] in
                guard let list = try? await api.myWorkspaces(), let self else { return }
                if self.isSyncing {
                    self.roleCheckRequested = true
                } else {
                    self.applyRoleRefresh(list, generation: gen)
                }
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

    /// Durum dosyasını arka planda yazar (veri dosyasıyla aynı kuyrukta, sırayla)
    private func saveState() {
        guard enabled else { return }
        stateSaveTask?.cancel()
        diskQueue.async(stateWriter())
    }

    private func saveStateNow() {
        guard enabled else { return }
        let write = stateWriter()
        diskQueue.sync { write() }
    }

    /// Durum dosyasını yazar ve yazılmasını bekler (kuyrukta sırayla; ana iş parçacığı bekletilmez)
    /// - Returns: dosya yazılabildi mi (bu modda kapalıysa false)
    private func saveStateAndWait() async -> Bool {
        guard enabled else { return false }
        stateSaveTask?.cancel()
        let write = stateSaver(), queue = diskQueue
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            queue.async {
                cont.resume(returning: write())
            }
        }
    }

    /// Kayıt noktası: yerel veri değiştiyse önce veri dosyası, sonra durum; ikisi de arka planda, sırayla
    /// (AppStore.syncCheckpoint). Kodlama ana iş parçacığında yapılmaz.
    private func checkpoint(_ app: AppStore, dataChanged: Bool) {
        guard enabled else { return }
        stateSaveTask?.cancel()
        app.syncCheckpoint(dataChanged: dataChanged, writeState: stateWriter())
    }

    /// Şu anki durumun yazma işi (kopya şimdi alınır, kuyrukta yazılır)
    private func stateWriter() -> @Sendable () -> Void {
        let save = stateSaver()
        return { _ = save() }
    }

    /// Şu anki durumun yazma işi; yazılabildi mi döner (hata günlüğe yazılır)
    private func stateSaver() -> @Sendable () -> Bool {
        let s = state, store = syncStore
        return {
            do {
                try store.save(s)
                return true
            } catch {
                NSLog("Eşitleme durumu kaydedilemedi: \(error)")
                return false
            }
        }
    }
}

/// Canlı bağlantı istemcisinin kutusu: denetleyicinin deinit'inden de (ana aktör dışı) durdurulabilsin diye
/// Sendable bir sabitte tutulur. Yalnızca ana iş parçacığında değiştirilir.
private final class RealtimeBox: @unchecked Sendable {
    var client: RealtimeClient?
}
