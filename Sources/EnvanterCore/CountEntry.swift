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
