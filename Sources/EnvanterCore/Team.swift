import Foundation

/// Ekip yardımcıları (web istemcisi aynı kuralları uygular; docs/SYNC.md §1 "Ekip").
/// Eski sürümlerin sayım yapan kişi listesi (`settings.staff`) ekip üyelerine taşınır; Sayan seçimi ekipten beslenir.
public enum Team {
    /// Ad karşılaştırma anahtarı: slug (`TeamID.slug`; Türkçe harf ve büyük-küçük farkı yok sayılır). Slug'ı boş adlarda
    /// (ör. yalnızca noktalama) kırpılmış adın kendisi.
    static func nameKey(_ name: String) -> String {
        let slug = TeamID.slug(name)
        return slug.isEmpty ? name.trimmingCharacters(in: .whitespacesAndNewlines) : slug
    }

    /// Eski sayan adlarını ekibe taşır: `settings.staff` sırasıyla her ad için, adı aynı slug'a çıkan bir üye ya da
    /// "staff-<slug>" kimlikli bir üye (önceki bir taşıma; adı sonradan değişmiş olabilir) yoksa
    /// `Employee(id: "staff-<slug>", name, role: "", active: true)` eklenir; slug'ı boş adlar taşınmaz. Sonra
    /// `settings.staff` boşaltılır. Kimlikler belirlenimcidir: Mac ve web aynı anda taşısa da belgeler kimliğe göre birleşir.
    /// Yalnızca tanım belgelerini yazabilen istemci çağırır (bağlı değilken ya da bulut eşitlemesinde çekmeden sonra,
    /// rol tanımları yazabiliyorsa: `CloudSyncEngine.syncOnce`). Okumada kendiliğinden çalışmaz.
    /// - Returns: veri değişti mi (`settings.staff` boşsa false)
    @discardableResult
    public static func migrateLegacyStaff(_ data: inout AppData) -> Bool {
        guard !data.settings.staff.isEmpty else { return false }
        var taken = Set(data.employees.map { $0.id })
        var keys = Set(data.employees.map { TeamID.slug($0.name) }.filter { !$0.isEmpty })
        for raw in data.settings.staff {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let slug = TeamID.slug(name)
            let id = TeamID.prefix + slug
            guard !slug.isEmpty, !keys.contains(slug), !taken.contains(id) else { continue }
            data.employees.append(Employee(id: id, name: name))
            taken.insert(id)
            keys.insert(slug)
        }
        data.settings.staff = []
        return true
    }

    /// Şubeyle eşleşmemiş (yalnızca bu Mac'te çalışan: `state.config?.workspaceID == nil || !state.initialized`) veride
    /// geçiş: değişiklik varsa yeni veri, yoksa nil. Uygulama açılışta ve yedekten geri yüklenen veride çağırır; şubeyle
    /// eşleşmiş Mac'te çağrılmaz (orada `CloudSyncEngine.syncOnce` çekmeden sonra yapar). Kendi kendini sınama ve ekran
    /// görüntüsü kipinde çağrılmaz.
    public static func migratingLegacyStaff(_ data: AppData) -> AppData? {
        var d = data
        return migrateLegacyStaff(&d) ? d : nil
    }

    /// Sayan seçimindeki adlar: önce aktif ekip üyeleri (liste sırasıyla), sonra henüz taşınmamış eski sayan adlarından
    /// hiçbir üyeyle (pasifler dahil) eşleşmeyenler. Aynı ada çıkanlar (slug) bir kez yazılır.
    public static func counterNames(_ data: AppData) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for e in data.employees where e.active {
            let n = e.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !n.isEmpty && seen.insert(nameKey(n)).inserted { out.append(n) }
        }
        seen.formUnion(data.employees.map { nameKey($0.name) })
        for raw in data.settings.staff {
            let n = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !n.isEmpty && seen.insert(nameKey(n)).inserted { out.append(n) }
        }
        return out
    }

    /// Sayan alanına yazılan yeni adı ekibe ekler (bir sonraki sayımda seçilebilsin): adı aynı slug'a çıkan üye yoksa
    /// `Employee(id: "staff-<slug>", name, role: "")` eklenir (kimlik alınmışsa "-2", "-3" …). Personel hesabıyla ekip
    /// belgesi yazılamadığından eklenmez (web: saveDayNote ile aynı); yoksa her yeni ad reddedilen bir yazma olurdu.
    /// `settings.staff`'a hiçbir zaman yazılmaz.
    /// - Returns: güncellenmiş ekip; değişiklik yoksa nil
    public static func rememberingCounter(_ name: String, in data: AppData, role: String?) -> [Employee]? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CloudRole.canWriteCatalog(role), !data.employees.contains(where: { nameKey($0.name) == nameKey(n) }),
              let id = TeamID.id(for: n, taken: Set(data.employees.map { $0.id })) else { return nil }
        return data.employees + [Employee(id: id, name: n)]
    }
}
