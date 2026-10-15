import Foundation

// Sayım girişi kolaylıkları: kalem arama ve toplayarak giriş metinleri (web `src/lib/countEntry.ts`). Toplama kuralı
// `Fmt.parseCountExpression`; ortak test vektörleri Fixtures/count-vectors.json (web test/fixtures/, aynı içerik).

/// Kalem arama: ad ya da kimlik, Türkçe harf ve büyük/küçük harf farkı gözetmeden ("pey" → Peynir, "sogan" → Soğan)
public enum ItemSearch {
    /// Karşılaştırma biçimi: baştaki/sondaki boşluk atılır, Türkçe harfler ve aksanlar ASCII'ye indirilir, küçültülür
    public static func fold(_ s: String) -> String {
        TextFold.ascii(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Boş arama her kalemle eşleşir
    public static func matches(name: String, id: String, query: String) -> Bool {
        let q = fold(query)
        guard !q.isEmpty else { return true }
        return fold(name).contains(q) || fold(id).contains(q)
    }

    public static func matches(_ item: Item, query: String) -> Bool {
        matches(name: item.name, id: item.id, query: query)
    }

    /// Arama kutusunun yer tutucusu
    public static let placeholder = "Kalem ara"
    /// Eşleşme yokken: "“pey” ile eşleşen kalem yok"
    public static func noMatchText(_ query: String) -> String {
        "“\(query.trimmingCharacters(in: .whitespacesAndNewlines))” ile eşleşen kalem yok"
    }
    public static let clearLabel = "Aramayı temizle"
}

/// Sayım tablosunun altındaki açıklamalar
public enum CountEntryText {
    /// Toplayarak giriş ipucu (iki istemcide aynı)
    public static let expressionHint = "İpucu: toplayarak girebilirsiniz — 12+8 ya da 3x24+7"
}

/// Günlük Sayım ekranının sütunları ve hesap metinleri (web CountGrid / CountView ile aynı ifadeler). İç alan adları
/// değişmez: Devreden = opening, Giren = incoming, Çıkan = transferOut, Şubeden gelen = transferIn, Kalan = closing.
public enum CountText {
    public static let item = "Ürün"
    public static let opening = "Devreden"
    public static let incoming = "Giren"
    public static let transferOut = "Çıkan"
    public static let transferIn = "Şubeden gelen"
    public static let sold = "Satılan"
    public static let waste = "Zayi"
    public static let closing = "Kalan"
    public static let expected = "Olması gereken"
    public static let diff = "Fark"
    /// Masaüstü tablonun sütunları (sırasıyla; sonda döküm ⓘ)
    public static let columns = [item, opening, incoming, transferOut, sold, waste, closing, diff]

    /// Sayfa alt başlığı
    public static let subtitle = "Gün sonunda kalanı sayın; giren, çıkan ve zayiyi girin. Fark satış raporuna göre hesaplanır."
    /// Elle girilmiş Devreden'in yanındaki işaret
    public static let manualMark = "elle"
    /// Dökümdeki Devreden düzeltme alanı
    public static let editOpening = "Devreden'i düzelt"
    public static let editOpeningHelp = "Yalnızca devreden yanlışsa (ör. sayılmayan bir teslimat) yazın; boş bırakılırsa son sayımdan hesaplanır."
    public static let transferInHelp = "Başka şubeden gelen mal (Giren'den ayrı tutulur)."
    /// Fark kapsülü: tolerans içinde
    public static let ok = "Tamam"
    /// Alt satırdaki açıklamalar
    public static let diffLegend = "Fark = Kalan − Olması gereken · Olması gereken = Devreden + Giren − Çıkan − Satılan − Zayi"
    public static let colorLegend = "Kırmızı: eksik · Mavi: fazla · Yeşil: tamam (tolerans içinde)"
    public static let openingLegend = "Devreden son sayımdan gelir; arada sayılmayan günler varsa onların hareketleri eklenir (≈ tahmini)"
    /// Kalan girilmeden Fark hücresinin ipucu
    public static let notCountedHelp = "Kalan girilince hesaplanır"

    /// Sütun ipuçlarının ilk cümlesi (sözlük; web `COUNT_MEANING`)
    public enum Meaning {
        public static let opening = "Önceki sayımdan devreden miktar (sayılmayan günlerin hareketleri eklenir)"
        public static let incoming = "Teslim alınan / gelen mal"
        public static let transferOut = "Başka şubeye ya da depoya giden (satış ve zayi hariç)"
        public static let transferIn = "Başka şubeden gelen mal; yalnızca dökümde gösterilir"
        public static let sold = "Satış raporundan reçeteyle hesaplanır"
        public static let waste = "ModPos zayi + elle girilen zayi"
        public static let closing = "Gün sonunda sayılan miktar"
        public static let expected = "Devreden + Giren + Şubeden gelen − Çıkan − Satılan − Zayi"
        public static let diff = "Kalan − Olması gereken; eksi = eksik, artı = fazla"
    }

    static func num(_ v: Double, _ item: Item) -> String { Fmt.number(v, maxFraction: item.maxFraction) }
    static func unit(_ item: Item) -> String { item.unit.lowercased() }

    /// Devreden hücresi: önceki sayım yoksa "—", tahminiyse "≈ 150", değilse "120"
    public static func openingValue(_ c: ItemCalc, item: Item) -> String {
        switch c.openingSource {
        case .noBase: return "—"
        case .carried: return "≈ " + num(c.opening, item)
        case .closing, .manual: return num(c.opening, item)
        }
    }

    /// Giren hücresinin altındaki not: "+5 şubeden" (Şubeden gelen 0 ise nil)
    public static func transferInNote(_ c: ItemCalc, item: Item) -> String? {
        c.transferIn == 0 ? nil : "+" + num(c.transferIn, item) + " şubeden"
    }

    /// Kalan alanının soluk değeri: "≈ 14,406" (eksi tahmin "≈ 0"; Olması gereken hesaplanamıyorsa boş)
    public static func closingPlaceholder(_ c: ItemCalc, item: Item) -> String {
        c.expectedClosing.map { "≈ " + num(max($0, 0), item) } ?? ""
    }

    /// Elle girilen Devreden beklenenden farklı: "Devreden beklenenden 5 kg fazla girildi (beklenen ≈ 20)"
    public static func openingJumpWords(_ c: ItemCalc, item: Item) -> String? {
        guard let j = c.openingJump, j != 0 else { return nil }
        return "\(opening) beklenenden \(num(abs(j), item)) \(unit(item)) \(j > 0 ? "fazla" : "eksik") girildi (beklenen ≈ \(num(Engine.clean(c.opening - j), item)))"
    }

    /// Farkın sözle karşılığı: "Tamam", "0,126 kg eksik", "3 adet fazla"
    public static func diffWords(_ d: Double, severity: DiffSeverity, item: Item) -> String {
        let amount = num(abs(d), item) + " " + unit(item)
        switch severity {
        case .zero, .withinTolerance: return ok
        case .shortage: return amount + " eksik"
        case .surplus: return amount + " fazla"
        }
    }

    /// Fark kapsülü: ilk sayım "İlk sayım", sayılmadıysa "—", değilse `diffWords`
    public static func diffPill(_ c: ItemCalc, item: Item) -> String {
        if c.isBaseline { return OpeningText.baselinePill }
        guard let d = c.diff, let s = c.severity else { return "—" }
        return diffWords(d, severity: s, item: item)
    }

    /// Fark hücresinin ipucu (elle Devreden beklenenden farklıysa eklenir)
    public static func diffHelp(_ c: ItemCalc, item: Item) -> String {
        let text: String
        if let d = c.diff, let s = c.severity {
            let amount = num(abs(d), item) + " " + unit(item)
            switch s {
            case .zero: text = "\(ok): kalan, olması gerekenle aynı"
            case .withinTolerance: text = "\(ok): fark \(amount), tolerans (±\(num(item.tolerance ?? 0, item))) içinde"
            case .shortage: text = "Kalan, olması gerekenden \(amount) eksik — kaydedilmemiş zayi, büyük porsiyon ya da kayıp olabilir"
            case .surplus: text = "Kalan, olması gerekenden \(amount) fazla — sayımı, girilmeyen Giren'i ya da reçeteyi kontrol edin"
            }
        } else {
            text = notCountedHelp
        }
        guard let jump = openingJumpWords(c, item: item) else { return text }
        return text + " · " + jump
    }

    /// Dökümdeki düz formül: "Devreden 16,8 + Giren 0 − Çıkan 0 − Satılan 2,394 − Zayi 0 = Olması gereken 14,406 ·
    /// Sayılan 14,28 → 0,126 kg eksik" (Şubeden gelen yalnızca 0 değilse yazılır)
    public static func formula(_ c: ItemCalc, item: Item) -> String {
        guard let target = c.expectedClosing else {
            let head = "Önceki sayım yok: bu sayım başlangıç kabul edilir, fark hesaplanmaz"
            return c.closing.map { "\(head) · Sayılan \(num($0, item))" } ?? head
        }
        var parts = ["\(opening) \(openingValue(c, item: item))", "+ \(incoming) \(num(c.incoming, item))"]
        if c.transferIn != 0 { parts.append("+ \(transferIn) \(num(c.transferIn, item))") }
        parts += ["\u{2212} \(transferOut) \(num(c.transferOut, item))", "\u{2212} \(sold) \(num(c.sold, item))",
                  "\u{2212} \(waste) \(num(c.waste, item))", "= \(expected) \(num(target, item))"]
        let base = parts.joined(separator: " ")
        guard let closing = c.closing, let d = c.diff, let s = c.severity else { return base + " · \(self.closing) henüz sayılmadı" }
        var result = diffWords(d, severity: s, item: item)
        if s == .withinTolerance { result += " (fark \(num(abs(d), item)) \(unit(item)), tolerans ±\(num(item.tolerance ?? 0, item)))" }
        return base + " · Sayılan \(num(closing, item)) → \(result)"
    }
}
