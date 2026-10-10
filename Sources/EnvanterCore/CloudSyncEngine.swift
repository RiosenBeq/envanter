import Foundation

/// Bir eşitleme turunun sonucu
public struct SyncOutcome: Sendable {
    /// Eşitlemeden sonraki yerel veri (sunucudan gelenler uygulanmış)
    public var data: AppData
    /// Yerelde sunucu sürümüyle değişen anahtarlar (uygulanan, birleştirilen ya da yetkisiz olduğu için geri alınan)
    public var appliedRemote: Set<String> = []
    /// Sunucuya yazılan anahtarlar
    public var pushed: [String] = []
    /// Çakışma yaşanan (merge3 ile birleştirilen) anahtarlar
    public var conflicts: Set<String> = []
    /// Yetki yüzünden reddedilen anahtarlar → sunucunun mesajı (yerel değişiklik bırakıldı, sunucu sürümü geçerli).
    /// Personelin tanım belgeleri ve kapatılmış günleri (docs/SYNC.md §2 "Kapatılmış gün") burada döner; yeniden denenmez.
    public var rejected: [String: String] = [:]
    /// Sunucudaki gövdesi çözülemeyen (bozuk) belgeler: yerel değer korundu
    public var undecodable: Set<String> = []
    /// Gönderim sırasında oluşan hata (çekilenler yine de uygulanmıştır; kalan anahtarlar "dirty" kalır)
    public var error: CloudSyncError?

    public init(data: AppData) { self.data = data }

    /// Yerel veri değişti mi
    public var changedLocalData: Bool { !appliedRemote.isEmpty }
}

/// İlk bağlantıda ne yapılacağı (docs/SYNC.md §3 "İlk bağlantı")
public enum InitialSyncMode: String, Sendable, Equatable {
    /// Bu Mac'tekini yükle
    case upload
    /// Buluttakini indir (önce yerel yedek alınır)
    case download
    /// Başka şubeden boş şubeye geçiş: yalnızca tanımlar (stok kalemleri, reçeteler, ayarlar) kopyalanır; günler,
    /// personel ve siparişler eski şubede kalır
    case copyCatalog
    /// İkisi de dolu: kullanıcıya sor
    case ask
}

/// Şube seçildiğinde: kaldığı yerden devam mı, ilk bağlantı mı
public enum WorkspaceChoice: Equatable, Sendable {
    /// Bu Mac zaten bu şubeyle eşleşmiş (çıkış yapıp yeniden girmek dahil): bekleyen ve tabandan ayrışan
    /// değişiklikler 3 yollu birleştirmeyle gönderilir
    case resume
    /// İlk bağlantı. `switching`: bu Mac başka bir şubeyle eşleşmişti; yereldeki veri o şubenindir.
    case initial(switching: Bool)
}

/// Eşitleme algoritması (docs/SYNC.md §3): önce çek (pull), sonra gönder (push).
public enum CloudSyncEngine {
    /// Bulut boşsa her şey yüklenir; yerel veri yalnızca varsayılan haldeyse buluttan indirilir; ikisi de doluysa sorulur.
    /// Başka şubeden geçişte (`switchingFromOtherWorkspace`) yereldeki veri eski şubenindir: dolu şubeye geçince o
    /// şubenin verisi indirilir (yerel yedek alınır); boş şubeye geçince ne kopyalanacağı sorulur (kendiliğinden yüklenmez).
    public static func initialMode(localIsSeedOnly: Bool, remoteEmpty: Bool, switchingFromOtherWorkspace: Bool = false) -> InitialSyncMode {
        if switchingFromOtherWorkspace && !localIsSeedOnly { return remoteEmpty ? .ask : .download }
        if remoteEmpty { return .upload }
        if localIsSeedOnly { return .download }
        return .ask
    }

    /// Şube seçimi kaldığı yerden devam mı, ilk bağlantı mı (başka şubeden geçiş dahil)
    public static func workspaceChoice(state: SyncState, workspaceID: String) -> WorkspaceChoice {
        guard let current = state.config?.workspaceID, state.initialized else { return .initial(switching: false) }
        return current == workspaceID ? .resume : .initial(switching: true)
    }

    /// Sunucudaki (silinmemiş) belge yok mu
    public static func isRemoteEmpty(_ rows: [RemoteDoc]) -> Bool {
        !latest(rows).values.contains { !$0.deleted && DocKey.isValid($0.key) }
    }

    /// Buluttaki (silinmemiş) belgelerden kurulan veri: "Bu Mac'tekini yükle" öncesinde buluttaki hal yedeklenir.
    public static func assembleRemote(_ rows: [RemoteDoc]) -> AppData {
        var docs: [String: JSONValue] = [:]
        for (k, r) in latest(rows) where !r.deleted && DocKey.isValid(k) { docs[k] = r.body ?? .null }
        return DocCodec.assemble(docs, base: AppData(items: [], products: []))
    }

    /// Her anahtarın en yeni satırı
    static func latest(_ rows: [RemoteDoc]) -> [String: RemoteDoc] {
        var m: [String: RemoteDoc] = [:]
        for r in rows where (m[r.key]?.rev ?? Int64.min) < r.rev { m[r.key] = r }
        return m
    }

    /// İlk bağlantı: tam okumanın (`rows`, since = 0) ardından yerel veriyi ve durumu hazırlar.
    /// - upload: bulutta olup yerelde olmayan günler yerele alınır; yerel her belge "dirty" olur (yerel kazanır).
    ///   Personel tanım belgelerini yazamadığından onlarda buluttaki hal geçerlidir (bulutta yoksa yereldeki kalır).
    /// - copyCatalog: upload gibi, ama önce yereldeki günler, personel ve siparişler boşaltılır (başka şubenindir);
    ///   şube adı ayarı yeni şubenin adı olur.
    /// - download: yerel veri buluttakiyle değiştirilir (bulutta olmayan günler silinir); bulutta hiç olmayan
    ///   tanım belgeleri yerelden korunur ve (yetki varsa) yüklenmek üzere "dirty" işaretlenir.
    /// `.ask` geçersizdir (önce kullanıcıya sorulmalı).
    public static func prepareInitial(mode: InitialSyncMode, local: AppData, rows: [RemoteDoc], state: inout SyncState) -> AppData {
        precondition(mode != .ask, "İlk bağlantı kararı verilmeden hazırlanamaz")
        let canWriteCatalog = state.config?.canWriteCatalog ?? true
        state.base = [:]
        state.dirty = []
        state.lastRev = rows.map { $0.rev }.max() ?? 0
        let remote = latest(rows).filter { DocKey.isValid($0.key) }
        for (k, r) in remote { state.base[k] = BaseDoc(rev: r.rev, body: r.body, deleted: r.deleted) }

        var data = local
        switch mode {
        case .upload, .copyCatalog:
            if mode == .copyCatalog {
                data.days = [:]
                data.employees = []
                data.purchaseOrders = []
                if let name = state.config?.workspaceName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                    data.settings.branchName = name
                }
            }
            // Personel: tanım belgelerinde buluttaki hal geçerli (yüklenemezler; eski hal kalırsa web'le ayrışırdı)
            if !canWriteCatalog { data = restoreReadOnlyDocs(local: data, state: state).data }
            // Yalnızca bulutta olan günler yerele gelir; diğer her şeyde yerel kazanır
            for (k, r) in remote where DocKey.isDay(k) && !r.deleted && DocCodec.body(for: k, in: data) == nil {
                DocCodec.apply(key: k, body: r.body, to: &data)
            }
            for k in DocCodec.split(data).keys where needsPush(key: k, data: data, base: state.base[k]) {
                if canWriteCatalog || DocKey.isDay(k) { state.dirty.insert(k) }
            }
        case .download:
            data.days = [:]
            for (k, r) in remote where !r.deleted {
                if !DocCodec.apply(key: k, body: r.body, to: &data), let date = DocKey.date(of: k) {
                    // Bozuk gün belgesi: yereldeki korunur
                    data.days[date] = local.days[date]
                }
            }
            if canWriteCatalog {
                for k in DocKey.catalog where remote[k] == nil || remote[k]?.deleted == true { state.dirty.insert(k) }
            }
        case .ask:
            break
        }
        state.initialized = true
        return data
    }

    /// Aynı şubeye yeniden bağlanma (çıkış yapıp yeniden giriş — başka hesapla da —, oturum yenileme, rol değişimi):
    /// personelken yazılamayan tanım belgeleri önce sunucudaki haline döner (rol müdüre yükseldiyse eskimiş tanımlar
    /// "yerel değişiklik" sanılıp sunucudakinin üzerine yazılmasın), sonra şube adı ve rol güncellenir, eşitleme
    /// yeniden başlar ve tabandan ayrışan belgeler (oturum kapalıyken yapılanlar) gönderilmek üzere "dirty" işaretlenir.
    /// Gönderim 3 yollu birleştirmeyle yapılır: arada web panelinde yapılan değişiklikler korunur.
    public static func resume(workspace: CloudWorkspace, local: AppData, state: inout SyncState) -> AppData {
        let healed = restoreReadOnlyDocs(local: local, state: state)
        state.config?.workspaceName = workspace.name
        state.config?.role = workspace.role
        state.signedOut = false
        state.dirty.formUnion(divergentKeys(local: healed.data, state: state))
        return healed.data
    }

    /// Rolün yazamadığı (personel: tanım belgeleri) ve sunucudaki halinden (taban) ayrışmış belgeleri sunucudaki
    /// haliyle değiştirir ("sunucu kazanır"). "dirty" anahtarlara (gönderimde reddedilip geri yüklenir), tabanı olmayan,
    /// silinmiş ya da çözülemeyen belgelere dokunulmaz. Personelken eskimiş kalan tanımlar böylece hem web'le aynı olur
    /// hem de rol müdüre yükselince "yerel değişiklik" sanılıp sunucudakinin üzerine yazılmaz.
    public static func restoreReadOnlyDocs(local: AppData, state: SyncState) -> (data: AppData, restored: Set<String>) {
        let role = state.config?.role
        var data = local
        var restored = Set<String>()
        for k in DocKey.catalog where !CloudRole.canWrite(role, key: k) && !state.dirty.contains(k) {
            guard let b = state.base[k], !b.deleted, let serverN = DocCodec.normalize(key: k, body: b.body) else { continue }
            if DocCodec.body(for: k, in: data) != serverN, DocCodec.apply(key: k, body: serverN, to: &data) {
                restored.insert(k)
            }
        }
        return (data, restored)
    }

    /// Sunucudaki hali kapatılmış (kilitli) gün mü: sunucunun D1 denetimiyle aynı (`body -> 'locked' = true`, silinmemiş;
    /// boolean olmayan değer kilit sayılmaz)
    public static func isLockedDay(_ base: BaseDoc?) -> Bool {
        guard let base, !base.deleted else { return false }
        return base.body?["locked"]?.boolValue == true
    }

    /// Yerel değer sunucudakinden (taban) farklı mı: gönderilmesi gerekiyor mu
    public static func needsPush(key: String, data: AppData, base: BaseDoc?) -> Bool {
        let local = DocCodec.body(for: key, in: data)
        guard let base, !base.deleted else { return local != nil }
        return local != DocCodec.normalize(key: key, body: base.body)
    }

    /// Yerel verinin tabandan ayrıştığı anahtarlar (uygulama kapanmadan önce "dirty" kaydedilemediyse bulunur).
    /// `canWriteCatalog` false ise (personel) tabanı olmayan tanım belgeleri sayılmaz.
    public static func divergentKeys(local: AppData, state: SyncState) -> Set<String> {
        let canWriteCatalog = state.config?.canWriteCatalog ?? true
        var keys = Set<String>()
        let localKeys = Set(DocCodec.split(local).keys)
        let baseKeys = Set(state.base.filter { !$0.value.deleted }.keys)
        for k in localKeys.union(baseKeys) where DocKey.isValid(k) {
            if !DocKey.isDay(k) && !canWriteCatalog { continue }
            if needsPush(key: k, data: local, base: state.base[k]) { keys.insert(k) }
        }
        return keys
    }

    /// Bir eşitleme turu: önce çek, sonra gönder.
    /// Çekme hatası fırlatılır (durum değişmez). Gönderme hatası `SyncOutcome.error` ile döner: o ana kadar çekilen
    /// ve yazılan her şey `state`e ve `data`ya işlenmiştir; kalan anahtarlar "dirty" kalır.
    public static func syncOnce(local: AppData, state: inout SyncState, api: SupabaseAPIProtocol,
                                client: String = CloudDefaults.client,
                                progress: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil) async throws -> SyncOutcome {
        guard let ws = state.config?.workspaceID else { throw CloudSyncError.notConfigured }
        var out = SyncOutcome(data: local)

        // 1. Çek
        let rows = try await api.pull(workspace: ws, since: state.lastRev)
        for row in rows.sorted(by: { $0.rev < $1.rev }) {
            defer { state.lastRev = max(state.lastRev, row.rev) }
            guard DocKey.isValid(row.key) else { continue }
            // Kendi yazdığımızın yankısı (ya da zaten bilinen sürüm)
            if let b = state.base[row.key], b.rev >= row.rev { continue }
            let key = row.key
            let remoteRaw: JSONValue? = row.deleted ? nil : row.body
            if state.dirty.contains(key) {
                let remoteN = DocCodec.normalize(key: key, body: remoteRaw)
                if remoteRaw != nil && remoteN == nil && !isEmptyDay(key, remoteRaw) {
                    // Sunucudaki gövde çözülemedi: "silinmiş" sayılmaz, yerel değer korunur
                    out.undecodable.insert(key)
                } else {
                    let base = state.base[key]
                    let baseN = (base?.deleted ?? true) ? nil : DocCodec.normalize(key: key, body: base?.body)
                    let localBody = DocCodec.body(for: key, in: out.data)
                    let merged = JSONMerge.merge3(base: baseN, local: localBody, remote: remoteN)
                    if merged != localBody { applyLocal(key, merged, &out) }
                    out.conflicts.insert(key)
                }
            } else {
                if DocCodec.apply(key: key, body: remoteRaw, to: &out.data) {
                    out.appliedRemote.insert(key)
                    out.undecodable.remove(key)
                } else {
                    out.undecodable.insert(key)
                }
            }
            state.base[key] = BaseDoc(rev: row.rev, body: remoteRaw, deleted: row.deleted)
        }

        // Personel: tanım belgelerinde sunucudaki hal geçerli (ör. ilk bağlantıda "Bu Mac'tekini Yükle" seçilmişse)
        if !(state.config?.canWriteCatalog ?? true) {
            let healed = restoreReadOnlyDocs(local: out.data, state: state)
            if !healed.restored.isEmpty {
                out.data = healed.data
                out.appliedRemote.formUnion(healed.restored)
            }
        }

        // 2. Gönder
        let keys = DocKey.sorted(state.dirty)
        var done = 0
        progress?(0, keys.count)
        do {
            for key in keys {
                try await push(key: key, workspace: ws, state: &state, out: &out, api: api, client: client)
                done += 1
                progress?(done, keys.count)
            }
        } catch let e as CloudSyncError {
            out.error = e
        } catch {
            out.error = .network(error.localizedDescription)
        }

        if let s = await api.currentSession { state.store(s) }
        if out.error == nil { state.lastSyncAt = Date() }
        return out
    }

    /// Tek anahtarı gönderir; çakışmada merge3 ile birleştirip en fazla `maxConflictRetries` kez yeniden dener.
    static func push(key: String, workspace: String, state: inout SyncState, out: inout SyncOutcome,
                     api: SupabaseAPIProtocol, client: String) async throws {
        guard DocKey.isValid(key) else { state.dirty.remove(key); return }
        var attempts = 0
        while true {
            let base = state.base[key]
            let local = DocCodec.body(for: key, in: out.data)
            let baseN = (base?.deleted ?? true) ? nil : DocCodec.normalize(key: key, body: base?.body)
            // Değişiklik geri alınmış ya da zaten sunucudaki gibi: göndermeye gerek yok
            if local == baseN && (local != nil || base == nil || base?.deleted == true || DocKey.isDay(key) == false) {
                state.dirty.remove(key)
                return
            }
            if local == nil && !DocKey.isDay(key) { state.dirty.remove(key); return }  // tanım belgeleri silinmez
            let deleted = local == nil
            let body: JSONValue = local.map { bodyPreservingUnknownFields(local: $0, baseRaw: base?.body, baseNormalized: baseN) } ?? .object([:])
            let summary = ChangeSummary.summarize(key: key, before: baseN, after: local, data: out.data)
            let r: PutResult
            do {
                r = try await api.put(workspace: workspace, key: key, body: body, baseRev: base?.rev ?? 0,
                                      deleted: deleted, client: client, summary: summary)
            } catch CloudSyncError.forbidden(let message) where !DocKey.isDay(key) || isLockedDay(base) {
                // Yetkisiz tanım değişikliği (personel kalem/reçete/ayar değiştirdi) ya da kapatılmış gün (personel
                // sunucuda kilitli olan günü değiştirdi, kilidini açtı ya da sildi; docs/SYNC.md §2): bırakılır, sunucudaki
                // sürüm geçerli olur ve yeniden denenmez; sonraki anahtarların gönderimi sürer. Sunucu kilit denetimini
                // rev karşılaştırmasından sonra yaptığından 42501 geldiğinde taban sunucudaki kilitli haldir (eski tabanla
                // yazan önce çakışmayı alıp tabanını günceller). Kilitsiz günde yetki hatası (ör. şubeden çıkarılma) yerel
                // veriyi geri almaz: hata yukarı iletilir ve anahtar "dirty" kalır.
                out.rejected[key] = message
                state.dirty.remove(key)
                if let base {
                    let serverN = base.deleted ? nil : DocCodec.normalize(key: key, body: base.body)
                    if base.deleted || serverN != nil { applyLocal(key, serverN, &out) }
                }
                return
            }
            if r.ok {
                state.base[key] = BaseDoc(rev: r.rev, body: deleted ? nil : (r.body ?? body), deleted: deleted)
                state.dirty.remove(key)
                out.pushed.append(key)
                return
            }
            // Çakışma: sunucudaki güncel hal döndü
            attempts += 1
            out.conflicts.insert(key)
            if r.rev == 0 {
                // Belge sunucuda yok: tabanı kaldırıp yerel hali yeniden ekle
                state.base[key] = nil
            } else {
                let serverRaw: JSONValue? = r.deleted ? nil : r.body
                state.base[key] = BaseDoc(rev: r.rev, body: serverRaw, deleted: r.deleted)
                let serverN = DocCodec.normalize(key: key, body: serverRaw)
                if serverRaw != nil && serverN == nil && !isEmptyDay(key, serverRaw) {
                    // Sunucudaki gövde çözülemedi: yerel hal yeni tabanla yeniden gönderilir
                    out.undecodable.insert(key)
                } else {
                    let merged = JSONMerge.merge3(base: baseN, local: local, remote: serverN)
                    if merged != local { applyLocal(key, merged, &out) }
                }
            }
            if attempts > CloudDefaults.maxConflictRetries {
                // Bir sonraki turda çekilip yeniden birleştirilecek (anahtar "dirty" kalır); diğer anahtarların
                // gönderimi sürer (ör. bugünün sayımı, sık değişen bir belge yüzünden bekletilmez)
                out.error = .server(status: 409, message: "\(key) belgesi art arda değişti; bir sonraki eşitlemede yeniden denenecek")
                return
            }
        }
    }

    /// Gönderilecek gövde: yerel (Mac'in bildiği alanlar) + sunucudaki bilinmeyen alanlar.
    /// merge3(taban = sunucu gövdesinin Mac karşılığı, yerel, uzak = sunucunun ham gövdesi): Mac'in değiştirdiği
    /// alanlar yerelden, Mac'in bilmediği (ileriki sürüm / web) alanları sunucudan gelir.
    public static func bodyPreservingUnknownFields(local: JSONValue, baseRaw: JSONValue?, baseNormalized: JSONValue?) -> JSONValue {
        guard let baseRaw, !baseRaw.isNull, let baseNormalized, baseRaw != baseNormalized else { return local }
        return JSONMerge.merge3(base: baseNormalized, local: local, remote: baseRaw) ?? local
    }

    /// Gövde çözülebilen ama boş (saklanmayan) bir gün mü (normalize nil döndürse de "bozuk" sayılmaz)
    static func isEmptyDay(_ key: String, _ body: JSONValue?) -> Bool {
        guard let date = DocKey.date(of: key), let body else { return false }
        return Lenient.day(body, date: date).map { DocCodec.storedDay($0) == nil } ?? false
    }

    /// Bir belgenin yerel değerini değiştirir (`nil` = sil); çözülemeyen değer yerel veriyi bozmaz.
    static func applyLocal(_ key: String, _ value: JSONValue?, _ out: inout SyncOutcome) {
        if DocCodec.apply(key: key, body: value, to: &out.data) {
            out.appliedRemote.insert(key)
        } else {
            out.undecodable.insert(key)
        }
    }
}
