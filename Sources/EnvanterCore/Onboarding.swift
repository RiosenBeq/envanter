import Foundation

/// İlk kullanım (yeni kurulum ya da boş veri): Genel Bakış'ta başlangıç seçenekleri gösterilir (web panelindeki
/// "Bu şubede henüz veri yok" kartının Mac karşılığı).
public enum Onboarding {
    /// Bu Mac'te henüz hiçbir günlük kayıt (sayım, satış, not, kapatılmış gün), ekip üyesi ve sipariş yok.
    /// Stok kalemleri ve reçeteler dikkate alınmaz: uygulamayla hazır gelirler ve başlamadan önce düzenlenebilirler.
    /// İlk günlük kayıt girilince (ya da web panelinden / yedekten veri gelince) false olur.
    public static func isEmpty(_ data: AppData) -> Bool {
        data.employees.isEmpty && data.purchaseOrders.isEmpty
            && data.days.values.allSatisfy { DocCodec.storedDay($0) == nil }
    }
}

/// Genel Bakış'taki "Bugün" kartı: günün üç adımı (web panelindeki kartla aynı sıra) — ① satış raporunu aktar,
/// ② sayımı tamamla, ③ günü kapat. Durumlar seçili günün özetinden (`DayOverview`) gelir.
public struct DaySteps: Equatable, Sendable {
    public enum Step: Int, CaseIterable, Sendable {
        case sales = 1, count, close
    }

    public var hasSales: Bool
    /// Kapanışı girilmiş ve toplam aktif kalem sayısı
    public var counted: Int
    public var total: Int
    public var closed: Bool

    public init(hasSales: Bool, counted: Int, total: Int, closed: Bool) {
        self.hasSales = hasSales; self.counted = counted; self.total = total; self.closed = closed
    }

    public init(_ o: DayOverview) {
        self.init(hasSales: o.hasSales, counted: o.countedItems, total: o.itemCount, closed: o.isLocked)
    }

    public func isDone(_ step: Step) -> Bool {
        switch step {
        case .sales: return hasSales
        case .count: return total > 0 && counted >= total
        case .close: return closed
        }
    }

    /// Sıradaki adım: yapılmamış ilk adım; gün kapatıldıysa (ya da her şey yapıldıysa) nil
    public var next: Step? { closed ? nil : Step.allCases.first { !isDone($0) } }

    /// Sayım adımının kısa durumu: "14/21"
    public var countText: String { "\(counted)/\(total)" }
}
