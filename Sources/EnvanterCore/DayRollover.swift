import Foundation

/// Gün dönümü: uygulama (ya da Windows'taki panel) açıkken takvim günü değişince "bugün" seçiliyse yeni güne geçilir;
/// başka bir gün görüntüleniyorsa hiçbir şey değişmez. Açık bir pencere varken ya da sayım sürerken (odakta yazı alanı,
/// son 15 dk içinde klavye / fare kullanılmış) geçiş bekler (`shouldWait`).
/// Web: `rolloverDecision` (`src/lib/rollover.ts`); ortak vektörler `Fixtures/version-vectors.json` (docs/SYNC.md §3
/// "Gün dönümü").
public enum DayRollover {
    public enum Decision: Equatable {
        /// Gün değişmedi ya da seçili gün "bugün" değildi: yalnızca bilinen "bugün" güncellenir
        case none
        /// Seçili gün yeni güne geçer
        case move(to: String)
        /// Seçili gün "bugün"dü ama bekleme var (açık pencere ya da süren sayım): bilinen "bugün" değişmeden kalır, sonra
        /// yeniden denenir
        case wait
    }

    /// - Parameters:
    ///   - selected: seçili gün
    ///   - previousToday: son bakıldığında "bugün" olan gün
    ///   - today: şimdiki takvim günü
    ///   - editing: geçiş beklesin (`shouldWait`)
    public static func decide(selected: String, previousToday: String, today: String, editing: Bool) -> Decision {
        guard today != previousToday, selected == previousToday else { return .none }
        return editing ? .wait : .move(to: today)
    }

    /// Bildirim: "Yeni gün başladı: 15.10.2026"
    public static func title(_ newDay: String) -> String { "Yeni gün başladı: \(DateKey.short(newDay))" }

    /// Önceki güne dönme düğmesi
    public static let backLabel = "Dünkü güne dön"

    /// Odakta yazı alanı varken son klavye / fare kullanımından bu kadar süre geçmediyse sayım sürüyor sayılır (sn): gece
    /// yarısını geçen sayım kendi gününde biter; gece boyu dokunulmadan kalan mağaza bilgisayarı yine de yeni güne geçer.
    public static let editingIdleSeconds: Double = 15 * 60

    /// Gün dönümü beklesin mi: açık bir pencere (sayfa, uyarı; içindeki işlem seçili güne bağlıdır, kapanınca geçilir) ya da
    /// odakta bir yazı alanı ve son giriş `editingIdleSeconds`'tan yeni. Beklenmeden geçilirken odaktaki hücre önce bırakılır:
    /// yazılmış ama kaydedilmemiş değer önceki güne kaydedilir.
    public static func shouldWait(dialogOpen: Bool, fieldFocused: Bool, idleSeconds: Double) -> Bool {
        dialogOpen || (fieldFocused && idleSeconds < editingIdleSeconds)
    }
}
