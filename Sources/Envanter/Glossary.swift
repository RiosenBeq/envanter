import SwiftUI

/// Uygulamadaki teknik terimlerin açıklamaları. Fareyle ⓘ simgesinin (ya da sütun başlığının) üzerine gelince görünür,
/// tıklayınca ayrıntılı açıklama açılır.
enum Term: String, CaseIterable, Identifiable {
    case opening, incoming, transfer, closing, sold, waste, actualUsage, diff
    case tolerance, minStock, factor, unitCost
    case theoreticalCost, actualCost, foodCostPct, laborCost, laborPct, primeCost, loss, netDiff, wasteCost, purchases, stockValue
    case abc, menuEngineering, popularity, unitMargin, consistency
    case orderSuggestion, daysOfCover, targetStock, costFactor, payType, priceAlert, purchaseOrder, lock

    var id: String { rawValue }

    var title: String {
        switch self {
        case .opening: return "Açılış"
        case .incoming: return "Gelen"
        case .transfer: return "Transfer"
        case .closing: return "Kapanış"
        case .sold: return "Satılan"
        case .waste: return "Zaiyat"
        case .actualUsage: return "Fiili tüketim"
        case .diff: return "Fark"
        case .tolerance: return "Tolerans"
        case .minStock: return "Kritik seviye"
        case .factor: return "Katsayı"
        case .unitCost: return "Birim maliyet"
        case .theoreticalCost: return "Teorik maliyet"
        case .actualCost: return "Fiili maliyet"
        case .foodCostPct: return "Hammadde maliyet oranı (food cost %)"
        case .laborCost: return "Personel maliyeti"
        case .laborPct: return "Personel oranı (labor %)"
        case .primeCost: return "Prime cost"
        case .loss: return "Kayıp"
        case .netDiff: return "Net fark"
        case .wasteCost: return "Zayi tutarı"
        case .purchases: return "Alım (gelen)"
        case .stockValue: return "Stok değeri"
        case .abc: return "ABC analizi"
        case .menuEngineering: return "Menü mühendisliği"
        case .popularity: return "Popülerlik (satış payı)"
        case .unitMargin: return "Birim kâr"
        case .consistency: return "Tutarlılık"
        case .orderSuggestion: return "Sipariş önerisi"
        case .daysOfCover: return "Kaç gün yeter"
        case .targetStock: return "Hedef stok"
        case .costFactor: return "İşveren maliyet çarpanı"
        case .payType: return "Ücret türü"
        case .priceAlert: return "Fiyat artışı uyarısı"
        case .purchaseOrder: return "Satın alma siparişi"
        case .lock: return "Günü kapatma"
        }
    }

    var text: String {
        switch self {
        case .opening:
            return "Günün başındaki stok. Boş bırakılırsa bir önceki sayılmış günün kapanışı otomatik gelir (Excel'deki \"Yeni Envanter Aç\" makrosunun işi)."
        case .incoming:
            return "Gün içinde tedarikçiden gelen mal. Sipariş Önerisi ekranında bir siparişi \"Teslim al\" dediğinizde otomatik eklenir."
        case .transfer:
            return "Başka şubeye giden (−) veya başka şubeden gelen (+) mal. Fiili tüketime satış gibi sayılmaz."
        case .closing:
            return "Gün sonu sayımı. Kapanış girilmeden o kalemin fiili tüketimi ve farkı hesaplanmaz."
        case .sold:
            return "ModPos satış raporundaki ürünlerin reçetelerine göre bu kalemden düşmesi gereken miktar. Örn. 10 Dublex Burger = 20 adet 90 gr."
        case .waste:
            return "ModPos'ta ZAYİ kategorisinde girilen ürünlerin reçeteye göre düşen miktarı (yanan, düşen, iade edilen ürün)."
        case .actualUsage:
            return "Sayıma göre gerçekten çıkan miktar: Açılış + Gelen + Gelen transfer − Giden transfer − Kapanış."
        case .diff:
            return "Fark = (Satılan + Zaiyat) − Fiili tüketim. Negatif (kırmızı): satışlara göre fazla stok çıkmış — fire, büyük porsiyon, kayıt dışı kullanım ya da kayıp. Pozitif (mavi): az çıkmış — genelde sayım veya reçete hatası."
        case .tolerance:
            return "Normal sayılan fark (±). Ölçüm ve porsiyon hassasiyeti yüzünden küçük farklar kaçınılmazdır; bu sınır içindeki farklar yeşil gösterilir ve uyarı üretmez."
        case .minStock:
            return "Bu seviyenin altına düşen kalemler uyarı verir; sipariş önerisinde emniyet stoğu olarak hedefe eklenir."
        case .factor:
            return "Reçete biriminin envanter birimine çevrimi. Örn. peynir reçetede dilimle, envanterde kg ile tutuluyorsa 1 dilim = 0,014 kg."
        case .unitCost:
            return "1 envanter biriminin (adet veya kg) alış maliyeti. Farkların ₺ karşılığı, reçete maliyeti ve tüm maliyet istatistikleri buna göre hesaplanır."
        case .theoreticalCost:
            return "Satılan ve zayi edilen ürünlerin reçeteye göre olması gereken hammadde maliyeti. \"Her şey reçeteye uygun yapılsaydı\" ne harcanırdı sorusunun cevabı."
        case .actualCost:
            return "Sayımlara göre gerçekten harcanan hammadde maliyeti (teorik maliyet + fazla çıkışların tutarı). Teorikten yüksekse aradaki fark kayıptır. Sayılmayan kalemlerin reçeteye uygun tüketildiği varsayılır."
        case .foodCostPct:
            return "Hammadde maliyetinin satış tutarına oranı. Örn. %30: her 100 ₺'lik satışın 30 ₺'si hammaddeye gidiyor. Hızlı servis restoranlarında genelde %25–35 aralığı hedeflenir; hedefi Ayarlar'dan girin."
        case .laborCost:
            return "Kayıtlı personelin maaş/yevmiye/saatlik ücretleri (işveren çarpanıyla) + ek ödemeler + diğer personel giderleri. Aylık maaşlar ayın günlerine eşit dağıtılır."
        case .laborPct:
            return "Personel maliyetinin satış tutarına oranı. Yalnızca satış tutarı bilinen günler hesaba katılır."
        case .primeCost:
            return "Hammadde (fiili) + personel maliyeti. Restoranın kontrol edebildiği en büyük iki gider kalemidir; satışa oranı genelde %60–65'in altında tutulmaya çalışılır."
        case .loss:
            return "Tolerans dışı fazla stok çıkışlarının maliyeti (yalnızca kırmızı farklar). Net farktan farklı olarak fazla gelen (mavi) farklarla mahsup edilmez."
        case .netDiff:
            return "Tüm farkların ₺ toplamı (fazla ve eksik çıkışlar birbirini götürür)."
        case .wasteCost:
            return "ZAYİ olarak girilen ürünlerin hammadde maliyeti. Kayıptan farklı olarak kayıt altına alınmış firedir."
        case .purchases:
            return "Dönemde gelen malların güncel birim maliyetle tutarı."
        case .stockValue:
            return "Son sayılan stokların birim maliyetle toplam değeri (depoda bağlı duran para)."
        case .abc:
            return "Stok kalemlerini tüketim değerine göre sıralar. A: değerin ilk %80'ini oluşturan az sayıda kalem — her gün dikkatle sayın. B: sonraki %15. C: kalan %5 — haftalık sayım çoğu zaman yeterlidir."
        case .menuEngineering:
            return "Ürünleri popülerlik ve birim kâra göre dört gruba ayırır. Yıldız: çok satan ve kârlı. Beygir: çok satan ama kârı düşük. Bilmece: kârlı ama az satan. Zayıf: ikisi de düşük."
        case .popularity:
            return "Ürünün toplam satış adedi içindeki payı. Eşik, ürün sayısına göre beklenen payın %70'idir (Kasavana–Smith yöntemi)."
        case .unitMargin:
            return "Ortalama satış fiyatı − reçete maliyeti. Eşik, satış adediyle ağırlıklandırılmış ortalama birim kârdır."
        case .consistency:
            return "Sayılmış günlerin yüzde kaçında farkın tolerans içinde kaldığı. Yüksekse reçete ve sayım güvenilirdir."
        case .orderSuggestion:
            return "Önerilen = ortalama günlük tüketim × istenen gün sayısı + kritik seviye − son sayılan stok. Adetler yukarı tam sayıya, kg 0,1'e yuvarlanır."
        case .daysOfCover:
            return "Son sayılan stok, ortalama tüketimle kaç gün yeter. Seçilen gün sayısından azsa kırmızı gösterilir."
        case .targetStock:
            return "Ortalama günlük tüketim × gün sayısı + kritik seviye."
        case .costFactor:
            return "Ücrete eklenen işveren yükleri için çarpan. 1 = ek yok; örn. 1,2 = ücretin %20 fazlası işverene maliyettir. Kendi bordronuza göre girin."
        case .payType:
            return "Aylık maaş ayın günlerine dağıtılır; günlük yevmiye yalnızca \"çalıştı\" işaretli günlere, saatlik ücret girilen saate göre yazılır."
        case .priceAlert:
            return "Bir kalemin birim maliyeti son 30 günde Ayarlar'daki eşikten fazla arttıysa uyarı verilir; o kalemi kullanan reçetelerin maliyeti de otomatik artar."
        case .purchaseOrder:
            return "Önerilerden oluşturulan sipariş. Mal gelince \"Teslim al\" ile gelen miktarlar seçili günün Gelen sütununa işlenir; fatura fiyatı girilirse birim maliyet güncellenir."
        case .lock:
            return "Sayım bitince günü kapatın: girişler kilitlenir ve yanlışlıkla değiştirilemez. Gerekirse kilit açılabilir."
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
