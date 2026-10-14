import SwiftUI
import EnvanterCore

/// Uygulamadaki teknik terimlerin açıklamaları. Fareyle ⓘ simgesinin (ya da sütun başlığının) üzerine gelince görünür,
/// tıklayınca ayrıntılı açıklama açılır.
enum Term: String, CaseIterable, Identifiable {
    case opening, incoming, transfer, closing, sold, waste, actualUsage, diff
    case tolerance, minStock, factor, shortage, consistency
    case orderSuggestion, daysOfCover, targetStock, onOrder, purchaseOrder, lock

    var id: String { rawValue }

    var title: String {
        switch self {
        case .opening: return "Açılış"
        case .incoming: return "Gelen"
        case .transfer: return "Transfer"
        case .closing: return "Kapanış"
        case .sold: return "Satılan"
        case .waste: return "Zayi"
        case .actualUsage: return "Fiili tüketim"
        case .diff: return "Fark"
        case .tolerance: return "Tolerans"
        case .minStock: return "Kritik seviye"
        case .factor: return "Katsayı"
        case .shortage: return "Fazla çıkış"
        case .consistency: return "Tutarlılık"
        case .orderSuggestion: return "Sipariş önerisi"
        case .daysOfCover: return "Kaç gün yeter"
        case .targetStock: return "Hedef stok"
        case .onOrder: return "Siparişte"
        case .purchaseOrder: return "Satın alma siparişi"
        case .lock: return "Günü kapatma"
        }
    }

    var text: String {
        switch self {
        case .opening:
            // Web glossary.ts ile aynı metin (OpeningText.glossary)
            return OpeningText.glossary
        case .incoming:
            return "Gün içinde tedarikçiden gelen mal. Sipariş ekranında bir siparişi \"Teslim al\" dediğinizde otomatik eklenir."
        case .transfer:
            return "Başka şubeye giden (−) veya başka şubeden gelen (+) mal. Fiili tüketime satış gibi sayılmaz."
        case .closing:
            return "Gün sonu sayımı. Kapanış girilmeden o kalemin fiili tüketimi ve farkı hesaplanmaz."
        case .sold:
            return "ModPos satış raporundaki ürünlerin reçetelerine göre bu kalemden düşmesi gereken miktar. Örn. 10 Dublex Burger = 20 adet 90 gr."
        case .waste:
            // Web glossary.ts ile aynı metin (WasteText.glossary)
            return WasteText.glossary
        case .actualUsage:
            return "Sayıma göre gerçekten çıkan miktar: Açılış + Gelen + Gelen transfer − Giden transfer − Kapanış."
        case .diff:
            return "Fark = (Satılan + Zayi) − Fiili tüketim. Negatif (kırmızı): satışlara göre fazla stok çıkmış — kaydedilmemiş zayi, büyük porsiyon, kayıt dışı kullanım ya da kayıp. Pozitif (mavi): az çıkmış — genelde sayım veya reçete hatası."
        case .tolerance:
            return "Günlük farkın normal sayılan sınırı (±). Kalemin kendi biriminde (adet veya kg) girilir, yüzde değildir. Ölçüm ve porsiyon hassasiyeti yüzünden küçük farklar kaçınılmazdır; bu sınır içindeki farklar yeşil gösterilir, fazla çıkışa ve uyarılara girmez. Stok Kalemleri'ndeki \"Eşik önerileri\" son 28 günün farklarına göre bir değer önerir."
        case .minStock:
            return "Bu seviyenin altına düşen kalemler uyarı verir; sayım girilmemiş günde son sayım ve sonraki hareketlerle tahmin edilen stoğa (≈) göre uyarılır. Sipariş önerisinde emniyet stoğu olarak hedefe eklenir."
        case .factor:
            return "Reçete biriminin envanter birimine çevrimi. Örn. peynir reçetede dilimle, envanterde kg ile tutuluyorsa 1 dilim = 0,014 kg."
        case .shortage:
            return "Satışlara (reçeteye) göre beklenenden fazla stok çıkması: tolerans dışı negatif fark (kırmızı). Kaydedilmemiş zayi, büyük porsiyon, kayıt dışı kullanım ya da kayıp olabilir. Dönem özetinde fazla çıkış olan gün sayısı ve toplam miktarı (kalemin biriminde) gösterilir; az çıkışlarla mahsup edilmez."
        case .consistency:
            return "Sayılmış günlerin yüzde kaçında farkın tolerans içinde kaldığı. Yüksekse reçete ve sayım güvenilirdir."
        case .orderSuggestion:
            return "Önerilen = ortalama günlük tüketim × istenen gün sayısı + kritik seviye − mevcut stok − siparişte bekleyen. Mevcut stok, son sayıma o günden sonraki gelen/transfer ve satışlar eklenerek tahmin edilir (son sayım 31 günden eskiyse bilinmiyor sayılır). Adetler yukarı tam sayıya, kg 0,1'e yuvarlanır."
        case .daysOfCover:
            return "Mevcut stok, ortalama tüketimle kaç gün yeter. Seçilen gün sayısından azsa kırmızı gösterilir."
        case .targetStock:
            return "Ortalama günlük tüketim × gün sayısı + kritik seviye."
        case .onOrder:
            return "Açık (henüz teslim alınmamış) siparişlerde bekleyen miktar. Aynı malın iki kez sipariş edilmemesi için öneriden düşülür."
        case .purchaseOrder:
            return "Önerilerden oluşturulan sipariş. Mal gelince \"Teslim al\" ile gelen miktarlar seçili günün Gelen sütununa işlenir."
        case .lock:
            return "Sayım bitince günü kapatın: sayım, satış ve teslimat girişleri kilitlenir ve yanlışlıkla değiştirilemez. Hiç sayım girilmemiş gün kapatılamaz. Gerekirse kilit açılabilir; web paneline personel hesabıyla bağlı Mac'te kapatılmış günün kilidini yalnızca patron veya müdür açar, bu yüzden kapatmadan önce günün sayım ve satış durumu gösterilip onay istenir."
        }
    }
}

/// Terim açıklaması: fareyle üzerine gelince ipucu, tıklayınca ayrıntılı açıklama.
struct InfoTip: View {
    let term: Term
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .help(term.text)
        .accessibilityLabel("\(term.title) açıklaması")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text(term.title).font(.headline)
                Text(term.text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(width: 320)
        }
    }
}

extension View {
    /// Fareyle üzerine gelince terimin açıklamasını gösterir (sütun başlıkları vb. için)
    func explains(_ term: Term) -> some View { help("\(term.title): \(term.text)") }
}
