import SwiftUI
import EnvanterCore

/// Uygulamadaki teknik terimlerin açıklamaları. Fareyle ⓘ simgesinin (ya da sütun başlığının) üzerine gelince görünür,
/// tıklayınca ayrıntılı açıklama açılır.
enum Term: String, CaseIterable, Identifiable {
    // Sayım ekranının sütun sırasıyla (sözlükte de bu sırayla listelenir)
    case opening, incoming, transferOut, transferIn, sold, waste, closing, expected, diff, actualUsage, expectedUsage
    case tolerance, minStock, factor, shortage, consistency
    case orderSuggestion, daysOfCover, targetStock, onOrder, purchaseOrder, lock

    var id: String { rawValue }

    var title: String {
        switch self {
        case .opening: return CountText.opening
        case .incoming: return CountText.incoming
        case .transferOut: return CountText.transferOut
        case .transferIn: return CountText.transferIn
        case .sold: return CountText.sold
        case .waste: return CountText.waste
        case .closing: return CountText.closing
        case .expected: return CountText.expected
        case .diff: return CountText.diff
        case .actualUsage: return "Gerçek kullanım"
        case .expectedUsage: return "Satış + zayi"
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
        // Sayım sütunlarının ipuçları (web glossary.ts ile aynı metinler; ilk cümle CountText.Meaning)
        case .opening:
            return "\(CountText.Meaning.opening). Son sayımın kalanına arada sayılmayan günlerin gireni, çıkanı, satışı ve zayisi eklenir (≈ tahmini). Önceki sayım yoksa ya da 31 günden eskiyse o günün sayımı başlangıç kabul edilir ve fark hesaplanmaz. Yanlışsa hesap dökümünde “\(CountText.editOpening)” ile elle yazılır (eski adıyla Açılış)."
        case .incoming:
            return "\(CountText.Meaning.incoming). Sipariş ekranında bir siparişi \"Teslim al\" dediğinizde otomatik eklenir (eski adıyla Gelen)."
        case .transferOut:
            return "\(CountText.Meaning.transferOut). Başka şubeden gelen mal hesap dökümünde “Şubeden gelen” olarak girilir ve Olması gereken'e eklenir."
        case .transferIn:
            return "\(CountText.Meaning.transferIn). Hesap dökümünde girilir; Giren'in altında \"+N şubeden\" diye görünür, eski kayıtlar da hesaba katılır."
        case .sold:
            return "\(CountText.Meaning.sold): ModPos satış raporundaki ürünlerin reçetelerine göre bu kalemden düşmesi gereken miktar. Örn. 10 Dublex Burger = 20 adet 90 gr."
        case .waste:
            return "\(CountText.Meaning.waste). \(WasteText.glossary) Sayım Excel'inin Zayi sütunu da elle girilen bir kayıttır."
        case .closing:
            return "\(CountText.Meaning.closing). Kalan girilmeden o kalemin farkı hesaplanmaz (eski adıyla Kapanış)."
        case .expected:
            return "Satışlara göre gün sonunda kalması gereken miktar: \(CountText.Meaning.expected). Sayılan Kalan bununla karşılaştırılır."
        case .diff:
            return "\(CountText.Meaning.diff). Eksik (kırmızı): satışlara göre fazla stok çıkmış — kaydedilmemiş zayi, büyük porsiyon, kayıt dışı kullanım ya da kayıp. Fazla (mavi): genelde sayım, girilmeyen Giren ya da reçete hatası. Tolerans içindeki fark “Tamam” (yeşil) görünür."
        case .actualUsage:
            return "Sayıma göre gerçekten kullanılan miktar: Devreden + Giren + Şubeden gelen − Çıkan − Kalan. Raporlarda satış + zayi ile karşılaştırılır; aradaki fark Fark'tır."
        case .expectedUsage:
            return "Satış raporundan reçeteyle hesaplanan Satılan ile Zayi'nin toplamı. Gerçek kullanım bundan fazlaysa eksik vardır."
        case .tolerance:
            return "Günlük farkın normal sayılan sınırı (±). Kalemin kendi biriminde (adet veya kg) girilir, yüzde değildir. Ölçüm ve porsiyon hassasiyeti yüzünden küçük farklar kaçınılmazdır; bu sınır içindeki farklar yeşil “Tamam” gösterilir, fazla çıkışa ve uyarılara girmez. Stok Kalemleri'ndeki \"Eşik önerileri\" son 28 günün farklarına göre bir değer önerir."
        case .minStock:
            return "Bu seviyenin altına düşen kalemler uyarı verir; sayım girilmemiş günde son sayım ve sonraki hareketlerle tahmin edilen stoğa (≈) göre uyarılır. Sipariş önerisinde emniyet stoğu olarak hedefe eklenir."
        case .factor:
            return "Reçete biriminin envanter birimine çevrimi. Örn. peynir reçetede dilimle, envanterde kg ile tutuluyorsa 1 dilim = 0,014 kg."
        case .shortage:
            return "Satışlara (reçeteye) göre beklenenden fazla stok çıkması: tolerans dışı eksi fark (Günlük Sayım'da kırmızı “eksik”). Kaydedilmemiş zayi, büyük porsiyon, kayıt dışı kullanım ya da kayıp olabilir. Dönem özetinde fazla çıkış olan gün sayısı ve toplam miktarı (kalemin biriminde) gösterilir; az çıkışlarla mahsup edilmez."
        case .consistency:
            return "Sayılmış günlerin yüzde kaçında farkın tolerans içinde kaldığı. Yüksekse reçete ve sayım güvenilirdir."
        case .orderSuggestion:
            return "Önerilen = ortalama günlük tüketim × istenen gün sayısı + kritik seviye − mevcut stok − siparişte bekleyen. Mevcut stok, son sayıma o günden sonraki giren, çıkan ve satışlar eklenerek tahmin edilir (son sayım 31 günden eskiyse bilinmiyor sayılır). Adetler yukarı tam sayıya, kg 0,1'e yuvarlanır."
        case .daysOfCover:
            return "Mevcut stok, ortalama tüketimle kaç gün yeter. Seçilen gün sayısından azsa kırmızı gösterilir."
        case .targetStock:
            return "Ortalama günlük tüketim × gün sayısı + kritik seviye."
        case .onOrder:
            return "Açık (henüz teslim alınmamış) siparişlerde bekleyen miktar. Aynı malın iki kez sipariş edilmemesi için öneriden düşülür."
        case .purchaseOrder:
            return "Önerilen miktarlarla başlayan formdan oluşturulan sipariş (miktarlar, kalemler ve tedarikçiye not değiştirilebilir; açıkken düzenlenebilir). Mal gelince \"Teslim al\" ile gelen miktarlar seçilen günün Giren sütununa işlenir; teslimat Giren olarak elle girildiyse \"Teslim alındı say\" siparişi Giren'e eklemeden kapatır. 3 günden eski açık siparişler için uyarı çıkar."
        case .lock:
            return "Sayım bitince günü kapatın: sayım, satış ve teslimat girişleri kilitlenir ve yanlışlıkla değiştirilemez. Hiç sayım girilmemiş gün kapatılamaz. Kapatmadan önce kontrol listesi (sayılmayan kalem, satış raporu, tanımsız reçete) gösterilir; eksik varsa onay istenir. Gerekirse kilit açılabilir; web paneline personel hesabıyla bağlı Mac'te kapatılmış günün kilidini yalnızca patron veya müdür açar, bu yüzden personel her zaman onaylar."
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
