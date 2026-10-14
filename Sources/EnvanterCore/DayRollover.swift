import Foundation

/// Gün dönümü: uygulama (ya da Windows'taki panel) açıkken takvim günü değişince "bugün" seçiliyse yeni güne geçilir;
/// başka bir gün görüntüleniyorsa hiçbir şey değişmez. Biri o an bir hücreye yazıyorsa geçiş yazma bitene kadar bekler.
/// Web: `rolloverDecision` (`src/lib/rollover.ts`); ortak vektörler `Fixtures/version-vectors.json` (docs/SYNC.md §3
/// "Gün dönümü").
public enum DayRollover {
    public enum Decision: Equatable {
        /// Gün değişmedi ya da seçili gün "bugün" değildi: yalnızca bilinen "bugün" güncellenir
        case none
        /// Seçili gün yeni güne geçer
        case move(to: String)
        /// Seçili gün "bugün"dü ama biri yazıyor: bilinen "bugün" değişmeden kalır, sonra yeniden denenir
        case wait
    }

    /// - Parameters:
    ///   - selected: seçili gün
    ///   - previousToday: son bakıldığında "bugün" olan gün
    ///   - today: şimdiki takvim günü
    ///   - editing: bir sayı / yazı alanına o an yazılıyor
    public static func decide(selected: String, previousToday: String, today: String, editing: Bool) -> Decision {
        guard today != previousToday, selected == previousToday else { return .none }
        return editing ? .wait : .move(to: today)
    }

    /// Bildirim: "Yeni gün başladı: 15.10.2026"
    public static func title(_ newDay: String) -> String { "Yeni gün başladı: \(DateKey.short(newDay))" }

    /// Önceki güne dönme düğmesi
    public static let backLabel = "Dünkü güne dön"
}
