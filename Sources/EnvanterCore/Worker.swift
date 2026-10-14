import Foundation

// Paylaşılan mağaza bilgisayarında kim çalışıyor (web `src/lib/worker.ts`). Bağlantı koduyla bağlanan bilgisayar bir
// cihaz hesabıyla (pc-…) yazar; değişiklik geçmişinde kişi görünmez. Uygulama açılınca bir kez "Şu an kim çalışıyor?"
// sorulur (aktif ekip üyeleri; atlanabilir). Cevap yalnızca bu bilgisayarda, uygulama açık kaldıkça tutulur (eşitlenmez):
// değişiklik geçmişi özetine " · Murat A." eklenir, Sayan (ilk kapanış girilirken boşsa) ve Zayi Ekle "Kim"
// varsayılanı olur. Ortak test vektörleri: Fixtures/worker-vectors.json (web test/fixtures/, aynı içerik).

public enum SessionWorker {
    public static let promptTitle = "Şu an kim çalışıyor?"
    public static let promptMessage = "Bu bilgisayar ortak kullanılıyor. Adınızı seçin: değişiklik geçmişine yazılır, sayımı yapan ve zayi kaydında varsayılan olur. Yalnızca bu bilgisayarda, uygulama açık kaldıkça hatırlanır."
    public static let skipLabel = "Atla"
    public static let changeLabel = "Değiştir"
    /// Ekipte aktif üye yokken
    public static let noEmployeesText = "Ekipte aktif üye yok. Patron ya da müdür Ekip ekranından ekleyebilir."

    /// Soru sorulur mu: bağlantı koduyla bağlanan bilgisayarın cihaz hesabı (pc-…)
    public static func asks(email: String?) -> Bool {
        guard let email else { return false }
        return PairCode.isDeviceAccount(email)
    }

    /// Seçenekler: aktif ekip üyelerinin adları (liste sırasıyla; boş ve aynı ada çıkanlar atlanır)
    public static func options(_ employees: [Employee]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for e in employees where e.active {
            let n = e.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !n.isEmpty && seen.insert(Team.nameKey(n)).inserted { out.append(n) }
        }
        return out
    }

    /// Seçilen ad (boşluklar atılır; boşsa nil)
    public static func normalized(_ name: String?) -> String? {
        let n = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? nil : n
    }

    /// Değişiklik geçmişi özeti: "09.10.2026 sayımı: 90 Gr kapanış 120 → 110 · Murat A." (özet boşsa ya da çalışan
    /// seçilmediyse aynen)
    public static func summary(_ base: String, worker: String?) -> String {
        guard let w = normalized(worker), !base.isEmpty else { return base }
        return base + " · " + w
    }

    /// Kapanış girilince gün kaydının Sayan'ı: boşsa çalışan yazılır (nil: değişmez)
    public static func countedBy(current: String?, worker: String?, hasClosing: Bool) -> String? {
        guard hasClosing, (current ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return normalized(worker)
    }

    /// Zayi Ekle "Kim" varsayılanı: günün sayanı, yoksa çalışan, yoksa bu hesaba bağlı ekip üyesi (cihaz hesabı kişi
    /// değildir: bağlı üye aranmaz), yoksa boş
    public static func defaultBy(countedBy: String?, worker: String?, linkedName: String?) -> String {
        if let c = normalized(countedBy) { return c }
        if let w = normalized(worker) { return w }
        return normalized(linkedName) ?? ""
    }
}
