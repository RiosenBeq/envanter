import Foundation

/// Veri biçimi düzeyi: aynı belgeleri farklı anlamla okuyan sürümleri ayırt eder (ör. elle zayi, devreden açılış). Her
/// sürüm canlı durum (presence) bilgisinde `fmt` olarak bildirir; web paneli düzeyi düşük bir Mac ya da Windows bilgisayarı
/// görünce uyarır, Mac de kanalda kendinden yeni bir düzey görürse güncellemesini ister. Web: `DATA_FORMAT_LEVEL`
/// (`src/lib/version.ts`); ortak vektörler `Fixtures/version-vectors.json` (docs/SYNC.md §2 "Varlık").
public enum DataFormat {
    /// Bu sürümün düzeyi (1: `fmt` bildirmeyen eski sürümler; 2: Ekim 2026 sürümü, Mac 2.1)
    public static let level = 2

    /// Canlı durum bilgisindeki düzey: `fmt` sayı ya da sayı metni (aşağı yuvarlanır); yoksa, 1'den küçükse ya da
    /// okunamıyorsa 1 (düzeyi bilmeyen eski sürüm)
    public static func level(ofPresence meta: [String: JSONValue]) -> Int {
        let raw: Double?
        switch meta["fmt"] {
        case .number(let n)?: raw = n
        case .string(let s)?: raw = Double(s.trimmingCharacters(in: .whitespaces))
        default: raw = nil
        }
        guard let v = raw, v.isFinite, v >= 1, v < 1_000_000 else { return 1 }
        return Int(v.rounded(.down))
    }

    /// Kanaldaki diğer istemcilerin (web, Windows, başka Mac) bildirdiği en yüksek düzey bu sürümünkünden büyükse o düzey;
    /// değilse nil. `ownKey`: bu Mac'in kanal anahtarı (kendi kaydı sayılmaz).
    public static func newerPeerLevel(in presence: [String: [JSONValue]], ownKey: String) -> Int? {
        var best = level
        for (key, metas) in presence where key != ownKey {
            for m in metas {
                guard let o = m.objectValue, o["fmt"] != nil else { continue }
                best = max(best, Self.level(ofPresence: o))
            }
        }
        return best > level ? best : nil
    }

    /// Mac uyarısı: şubede bu Mac'ten yeni bir sürüm çalışıyor
    public static func newerPeerMessage(_ peerLevel: Int) -> String {
        "Bu Mac'teki uygulama eski: şubede daha yeni bir sürüm çalışıyor (veri biçimi \(peerLevel), bu Mac \(level)). "
            + "Sayım ve fark hesapları bu Mac'te farklı çıkabilir; uygulamayı güncelleyin."
    }
}
