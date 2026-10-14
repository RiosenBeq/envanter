import Foundation

/// Elle zayi kayıtlarının saf kuralları (AppStore ve web `src/lib/engine/waste.ts` aynı kuralı kullanır;
/// docs/SYNC.md §1 "Elle zayi").
public enum WasteLog {
    /// Notun en fazla uzunluğu (karakter)
    public static let noteMaxLength = 200

    /// Yeni kayıt: miktar sonlu ve > 0 olmalı (değilse nil). Not ve kim kırpılır; boşsa yazılmaz, not en fazla 200
    /// karakter. `at` saniye hassasiyetinde UTC ("2026-10-13T21:40:00Z").
    public static func make(id: String = UUID().uuidString, itemID: String, qty: Double, reason: WasteReason,
                            note: String? = nil, by: String? = nil, at: Date = Date()) -> WasteEntry? {
        guard qty.isFinite, qty > 0, !itemID.isEmpty else { return nil }
        let n = note.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(noteMaxLength)) } ?? ""
        let b = by?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return WasteEntry(id: id, itemID: itemID, qty: (qty * 1_000_000).rounded() / 1_000_000, reason: reason.rawValue,
                          note: n.isEmpty ? nil : n, by: b.isEmpty ? nil : b, at: timestamp(at))
    }

    /// "2026-10-13T21:40:00Z" (kesirli saniye yok; Mac'in ISO 8601 çözücüsüyle uyumlu)
    public static func timestamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    /// Kaydı günün sonuna ekler
    public static func adding(_ entry: WasteEntry, to day: DayRecord) -> DayRecord {
        var d = day
        d.wasteLog = (d.wasteLog ?? []) + [entry]
        return d
    }

    /// Kaydı siler. Son kayıt silinince `[]` kalır (anahtar silinmez: başka cihazın eklediği kayıtla birleşirken silme
    /// kaybolmasın). Kayıt yoksa gün aynen döner.
    public static func removing(id: String, from day: DayRecord) -> DayRecord {
        guard let log = day.wasteLog, log.contains(where: { $0.id == id }) else { return day }
        var d = day
        d.wasteLog = log.filter { $0.id != id }
        return d
    }

    /// Günün kayıtları (kalem verilirse yalnızca onun), girildiği sırayla
    public static func entries(_ day: DayRecord?, itemID: String? = nil) -> [WasteEntry] {
        (day?.wasteLog ?? []).filter { itemID == nil || $0.itemID == itemID }
    }

    /// Kaydın yerel saati ("22:30"); `at` yoksa ya da okunamazsa nil
    public static func time(_ entry: WasteEntry, timeZone: TimeZone = .current) -> String? {
        guard let at = entry.at, let date = JSONCoding.parseISODate(at) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "tr_TR")
        f.timeZone = timeZone
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}

/// Elle zayi metinleri: iki istemcide aynı (web `WASTE_TEXT` ve `waste*` fonksiyonları, src/lib/engine/waste.ts)
public enum WasteText {
    public static let addTitle = "Zayi Ekle"
    /// Sözlük: Zayi
    public static let glossary = "ModPos'ta ZAYİ kategorisinde girilen ürünlerin reçeteye göre düşen miktarı ile Zayi Ekle'yle elle girilen kayıtların toplamı (bozulan, yanan, düşen, iade edilen mal)."
    /// Yardım: ipucu
    public static let helpTip = "Bozulan, yanan, düşen ya da iade edilen malı nota yazmak yerine Günlük Sayım'da Zayi Ekle ile girin: kalemin Zayi'sine eklenir ve farkı açıklar. ModPos'ta ZAYİ ürünü olarak girilen zayiyi ikinci kez girmeyin."
    /// Gün notu alanının ipucu (zayi nota değil, Zayi Ekle ile girilir)
    public static let noteHint = "ör. Akşam yoğunluğu; zayi için Zayi Ekle'yi kullanın"
    /// Hesap dökümündeki bölüm başlıkları
    public static let section = "Zayi"
    public static let manualSection = "Elle girilen zayi"
    public static let posSection = "ModPos ZAYİ ürünleri"
    /// Kapatılmış günde Zayi Ekle kapalı
    public static let lockedNote = "Gün kapatılmış; zayi girilemez."
    public static let empty = "Bu gün elle zayi girilmedi."
    /// Kalemin dökümünde (liste o kaleme süzülü) boş liste
    public static let emptyItem = "Bu kalem için bu gün elle zayi girilmedi."
    /// Miktar boş ya da 0
    public static let qtyRequired = "Miktar 0'dan büyük olmalı."
    public static let itemRequired = "Kalem seçin."
    public static let reasonRequired = "Neden seçin."

    /// Günlük Sayım'daki bağlantı: "Zayi kayıtları (2)"
    public static func listLink(_ count: Int) -> String { "Zayi kayıtları (\(count))" }

    /// "3 kg", "5 adet" (kalem yoksa yalnızca sayı)
    public static func amount(_ qty: Double, item: Item?) -> String {
        let n = Fmt.number(qty, maxFraction: item?.maxFraction ?? 3)
        guard let item else { return n }
        return "\(n) \(item.unit.lowercased())"
    }

    /// "Patates 3 kg" (kalem bilinmiyorsa kimliği)
    public static func itemAmount(_ entry: WasteEntry, item: Item?) -> String {
        "\(itemName(entry, item: item)) \(amount(entry.qty, item: item))"
    }

    static func itemName(_ entry: WasteEntry, item: Item?) -> String {
        guard let item, !item.name.isEmpty else { return entry.itemID }
        return item.name
    }

    /// Kaydetme bildirimi: "Zayi kaydedildi: Patates 3 kg · Bozuldu / SKT geçti"
    public static func saved(_ entry: WasteEntry, item: Item?) -> String {
        "Zayi kaydedildi: \(itemAmount(entry, item: item)) · \(WasteReason.title(entry.reason))"
    }

    /// Silme bildirimi: "Zayi silindi: Patates 3 kg"
    public static func removed(_ entry: WasteEntry, item: Item?) -> String {
        "Zayi silindi: \(itemAmount(entry, item: item))"
    }

    /// Kaydın ayrıntısı (saat hariç): "Bozuldu / SKT geçti · Dondurucu arızası · Murat A."
    public static func detail(_ entry: WasteEntry) -> String {
        var parts = [WasteReason.title(entry.reason)]
        if let n = entry.note, !n.isEmpty { parts.append(n) }
        if let b = entry.by, !b.isEmpty { parts.append(b) }
        return parts.joined(separator: " · ")
    }

    /// Aynı zayinin iki kez girilmesine karşı: günün ModPos (ya da Excel'den gelen) zayisi ve önceden elle girilenler.
    /// `base` = toplam zayi − elle girilen; ikisi de 0 ise nil.
    /// "Bu gün ModPos'ta 0,6 kg zayi var; aynı zayiyi iki kez girmeyin." / "Bu gün elle 2 kg zayi girildi (1 kayıt)."
    public static func duplicateHint(base: Double, legacy: Bool, manual: Double, manualCount: Int, item: Item) -> String? {
        var parts: [String] = []
        if base > 0 {
            let source = legacy ? "Excel'den aktarılan" : "ModPos'ta"
            parts.append("Bu gün \(source) \(amount(base, item: item)) zayi var; aynı zayiyi iki kez girmeyin.")
        }
        if manualCount > 0 {
            parts.append("Bu gün elle \(amount(manual, item: item)) zayi girildi (\(manualCount) kayıt).")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Zayi hücresinin ipucu: "Zayi 1,5 kg (ModPos 0,4 + elle 1,1) — dökümü görmek için tıklayın". Excel'den aktarılan
    /// günde (`usesLegacySales`) kaynak "Excel" yazılır.
    public static func cellHelp(_ calc: ItemCalc, legacy: Bool, item: Item) -> String {
        let source = legacy ? "Excel" : "ModPos"
        let base = Engine.clean(calc.waste - calc.manualWaste)
        let f: (Double) -> String = { Fmt.number($0, maxFraction: item.maxFraction) }
        let parts: String
        if !(calc.manualWaste > 0) {
            parts = source
        } else if base > 0 {
            parts = "\(source) \(f(base)) + elle \(f(calc.manualWaste))"
        } else {
            parts = "elle girildi"
        }
        return "Zayi \(amount(calc.waste, item: item)) (\(parts)) — dökümü görmek için tıklayın"
    }

    /// Excel'den aktarılan günün dökümünde Zaiyat'ın açıklaması: "Excel'den aktarılan Zaiyat: 0,5 kg" (taban = toplam −
    /// elle; gün Excel'den değilse ya da taban 0 ise nil)
    public static func legacyLine(_ calc: ItemCalc, legacy: Bool, item: Item) -> String? {
        let base = Engine.clean(calc.waste - calc.manualWaste)
        guard legacy, base != 0 else { return nil }
        return "Excel'den aktarılan Zaiyat: \(amount(base, item: item))"
    }

    /// Hesap satırından: `duplicateHint` (taban = toplam − elle)
    public static func duplicateHint(_ calc: ItemCalc, day: DayRecord?, item: Item) -> String? {
        duplicateHint(base: Engine.clean(calc.waste - calc.manualWaste), legacy: day?.usesLegacySales ?? false,
                      manual: calc.manualWaste, manualCount: WasteLog.entries(day, itemID: item.id).count, item: item)
    }
}
