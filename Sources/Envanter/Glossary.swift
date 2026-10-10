import SwiftUI

/// Uygulamadaki teknik terimlerin açıklamaları. Fareyle ⓘ simgesinin (ya da sütun başlığının) üzerine gelince görünür,
/// tıklayınca ayrıntılı açıklama açılır.
enum Term: String, CaseIterable, Identifiable {
    case opening, incoming, transfer, closing, sold, waste, actualUsage, diff
    case tolerance, minStock, factor, unitCost
    case theoreticalCost, actualCost, foodCostPct, laborCost, laborPct, primeCost, loss, netDiff, wasteCost, purchases, stockValue
    case abc, menuEngineering, popularity, unitMargin, consistency
    case orderSuggestion, daysOfCover, targetStock, onOrder, costFactor, payType, priceAlert, purchaseOrder, lock, recipeCost

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
        case .onOrder: return "Siparişte"
        case .costFactor: return "İşveren maliyet çarpanı"
        case .payType: return "Ücret türü"
        case .priceAlert: return "Fiyat artışı uyarısı"
        case .purchaseOrder: return "Satın alma siparişi"
        case .lock: return "Günü kapatma"
        case .recipeCost: return "Reçete maliyeti"
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
            return "Fark = (Satılan + Zayi) − Fiili tüketim. Negatif (kırmızı): satışlara göre fazla stok çıkmış — kaydedilmemiş zayi, büyük porsiyon, kayıt dışı kullanım ya da kayıp. Pozitif (mavi): az çıkmış — genelde sayım veya reçete hatası."
        case .tolerance:
            return "Günlük farkın normal sayılan sınırı (±). Kalemin kendi biriminde (adet veya kg) girilir, yüzde değildir. Ölçüm ve porsiyon hassasiyeti yüzünden küçük farklar kaçınılmazdır; bu sınır içindeki farklar yeşil gösterilir, Kayıp'a ve uyarılara girmez."
        case .minStock:
            return "Bu seviyenin altına düşen kalemler uyarı verir; sipariş önerisinde emniyet stoğu olarak hedefe eklenir."
        case .factor:
            return "Reçete biriminin envanter birimine çevrimi. Örn. peynir reçetede dilimle, envanterde kg ile tutuluyorsa 1 dilim = 0,014 kg."
        case .unitCost:
            return "1 envanter biriminin (adet veya kg) KDV hariç alış maliyeti; koli/paket fiyatı değil. Farkların ₺ karşılığı, reçete maliyeti ve tüm maliyet istatistikleri buna göre hesaplanır. Fiyat değişince geçmiş günler eski fiyatla kalır."
        case .theoreticalCost:
            return "Satılan ve zayi edilen ürünlerin reçeteye göre olması gereken hammadde maliyeti. \"Her şey reçeteye uygun yapılsaydı\" ne harcanırdı sorusunun cevabı."
        case .actualCost:
            return "Sayımlara göre gerçekten harcanan hammadde maliyeti: teorik maliyet − net fark tutarı. Fazla çıkışlar (kırmızı) eklenir, az çıkışlar (mavi) düşülür; tolerans içindeki farklar da dahildir. Bu yüzden fiili ile teorik arasındaki fark, Kayıp kartındaki tutarla aynı olmayabilir. Sayılmayan kalemlerin reçeteye uygun tüketildiği varsayılır."
        case .foodCostPct:
            return "Fiili hammadde maliyetinin satış tutarına oranı (yalnızca satış tutarı bilinen günler). Örn. %30: her 100 ₺'lik satışın 30 ₺'si hammaddeye gidiyor. Sektördeki %25–35 hedefleri KDV hariç satışa göredir; ModPos tutarı KDV dahilse oran olduğundan düşük görünür, hedefi buna göre girin (Ayarlar). İçecek gibi reçetesiz ürünlerin maliyeti dahil değildir."
        case .laborCost:
            return "Kayıtlı personelin maaş/yevmiye/saatlik ücretleri (işveren çarpanıyla) + ek ödemeler + diğer personel giderleri. Aylık maaşlar ayın her takvim gününe (kapalı günler dahil) eşit dağıtılır. Zamlar tarihlidir: her gün o gün geçerli ücretle hesaplanır."
        case .laborPct:
            return "Personel maliyetinin satış tutarına oranı. Satış tutarı bilinen günler ile kaydı hiç olmayan (kapalı) günlerin maaşı hesaba katılır; sayımı olup satış tutarı girilmemiş günler oranı bozmasın diye dışarıda kalır."
        case .primeCost:
            return "Hammadde (fiili) + personel maliyeti. Restoranın kontrol edebildiği en büyük iki gider kalemidir; satışa oranı genelde %60–65'in altında tutulmaya çalışılır."
        case .loss:
            return "Tolerans dışı fazla stok çıkışlarının (yalnızca kırmızı farklar) gün gün toplanan maliyeti. Net farktan farklı olarak az çıkan (mavi) farklarla mahsup edilmez."
        case .netDiff:
            return "Tüm farkların ₺ toplamı (fazla ve eksik çıkışlar birbirini götürür)."
        case .wasteCost:
            return "ZAYİ olarak girilen ürünlerin hammadde maliyeti; teorik maliyete dahildir. Kayıptan farklı olarak nedeni bilinen, kayıt altına alınmış tüketimdir."
        case .purchases:
            return "Dönemde gelen malların, geldikleri gün geçerli birim maliyetle tutarı."
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
            return "Önerilen = ortalama günlük tüketim × istenen gün sayısı + kritik seviye − mevcut stok − siparişte bekleyen. Mevcut stok, son sayıma o günden sonraki gelen/transfer ve satışlar eklenerek tahmin edilir. Adetler yukarı tam sayıya, kg 0,1'e yuvarlanır."
        case .daysOfCover:
            return "Mevcut stok, ortalama tüketimle kaç gün yeter. Seçilen gün sayısından azsa kırmızı gösterilir."
        case .targetStock:
            return "Ortalama günlük tüketim × gün sayısı + kritik seviye."
        case .onOrder:
            return "Açık (henüz teslim alınmamış) siparişlerde bekleyen miktar. Aynı malın iki kez sipariş edilmemesi için öneriden düşülür."
        case .costFactor:
            return "Ücrete eklenen işveren yükleri için çarpan. 1 = ek yok; örn. 1,2 = ücretin %20 fazlası işverene maliyettir. Kendi bordronuza göre girin."
        case .payType:
            return "Aylık maaş ayın günlerine dağıtılır; günlük yevmiye \"çalıştı\" işaretli ya da saat girilmiş günlere, saatlik ücret girilen saate göre yazılır. Ücret değişikliği bir tarihten itibaren (zam) ya da tüm dönem için (düzeltme) yapılır."
        case .priceAlert:
            return "Bir kalemin birim maliyeti son 30 gün içinde (arada birden fazla değişiklik olsa da toplamda) Ayarlar'daki eşik kadar veya daha fazla arttıysa uyarı verilir; o kalemi kullanan reçetelerin maliyeti de otomatik artar."
        case .purchaseOrder:
            return "Önerilerden oluşturulan sipariş. Mal gelince \"Teslim al\" ile gelen miktarlar seçili günün Gelen sütununa işlenir; fatura birim fiyatı (₺ / adet veya kg) girilirse fiyat geçmişine yazılır ve birim maliyet güncellenir."
        case .lock:
            return "Sayım bitince günü kapatın: sayım, satış, vardiya ve teslimat girişleri kilitlenir ve yanlışlıkla değiştirilemez. Gerekirse kilit açılabilir; web paneline personel hesabıyla bağlı Mac'te kapatılmış günün kilidini yalnızca patron veya müdür açar."
        case .recipeCost:
            return "1 adet ürünün reçetesindeki hammaddelerin birim maliyetle toplamı (₺ / porsiyon). Hammaddelerden birinin maliyeti eksikse hesaplanmaz."
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
