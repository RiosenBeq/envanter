import Foundation

/// İlk kullanım (yeni kurulum ya da boş veri): Genel Bakış'ta başlangıç seçenekleri gösterilir (web panelindeki
/// "Bu şubede henüz veri yok" kartının Mac karşılığı).
public enum Onboarding {
    /// Bu Mac'te henüz hiçbir günlük kayıt (sayım, satış, vardiya, not, kapatılmış gün), personel ve sipariş yok.
    /// Stok kalemleri ve reçeteler dikkate alınmaz: uygulamayla hazır gelirler ve başlamadan önce düzenlenebilirler.
    /// İlk günlük kayıt girilince (ya da web panelinden / yedekten veri gelince) false olur.
    public static func isEmpty(_ data: AppData) -> Bool {
        data.employees.isEmpty && data.purchaseOrders.isEmpty
            && data.days.values.allSatisfy { DocCodec.storedDay($0) == nil }
    }
}
