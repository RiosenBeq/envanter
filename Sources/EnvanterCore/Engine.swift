import Foundation

/// Bir satış satırının bir stok kalemine etkisi.
public struct Contribution: Identifiable, Hashable {
    public var id: String { code + (isWaste ? "-z" : "-s") }
    public var code: String
    public var name: String
    public var qty: Double
    /// 1 adet satış için reçete miktarı (reçete birimi)
    public var perUnit: Double
    /// Envanter biriminde toplam etki (qty × perUnit × factor)
    public var amount: Double
    public var isWaste: Bool
}

public enum LineStatus: String {
    /// Reçetesi var, stoktan düşüyor
    case tracked
    /// Reçetesi bilinçli olarak boş (içecek, sos ...), stok etkisi yok
    case untracked
    /// Reçete tablosunda hiç yok: kullanıcının karar vermesi gerekiyor
    case unknown
}

public struct SalesAnalysis {
    /// stok kalemi id -> satış kaynaklı tüketim (envanter birimi)
    public var sold: [String: Double] = [:]
    /// stok kalemi id -> zayi kaynaklı tüketim (envanter birimi)
    public var waste: [String: Double] = [:]
    public var contributions: [String: [Contribution]] = [:]
    public var status: [String: LineStatus] = [:]
    public var unknownLines: [SaleLine] = []
    public var untrackedLines: [SaleLine] = []
    public var trackedLines: [SaleLine] = []

    public var unknownQty: Double { unknownLines.reduce(0) { $0 + $1.qty } }
}

/// Açılışın kaynağı (web `OpeningSource` ile aynı ham değerler)
public enum OpeningSource: String, Sendable {
    /// Elle girildi
    case manual
    /// Önceki sayımın kapanışı (arada hareket yok)
    case closing
    /// Tahmini: son sayım (ya da elle açılış) + aradaki sayılmayan günlerin hareketleri
    case carried
    /// Önceki sayım yok (ya da `Engine.carryMaxDays` günden eski): ilk sayım başlangıç kabul edilir
    /// (ham değer "none"; Swift'te `Optional.none` ile karışmasın diye `noBase`)
    case noBase = "none"
}

/// Devrin dayandığı gün: kapanışı girilmiş gün ya da kapanışsız, elle açılış girilmiş gün
public enum OpeningBaseKind: String, Sendable {
    case closing, manualOpening
}

/// Bir kalemin sayılmayan bir gündeki hareketleri (devreden açılışın dökümü)
public struct CarryDay: Equatable, Sendable {
    public var date: String
    public var incoming: Double
    public var transferIn: Double
    public var transferOut: Double
    public var sold: Double
    public var waste: Double
    /// Gelen + Gelen transfer − Giden transfer − Satılan − Zayi
    public var net: Double
}

/// Tahmini açılış: dayanak günün değeri + aradaki sayılmayan günlerin net hareketi (web `OpeningEstimate`)
public struct OpeningEstimate: Equatable, Sendable {
    public var value: Double
    public var baseDate: String
    public var baseKind: OpeningBaseKind
    public var baseValue: Double
    public var carriedNet: Double
    /// Net hareketi sıfırdan farklı yürünen gün sayısı
    public var carriedDays: Int
}

/// Bir kalemin bir gündeki tahmini stoğu (sayıldıysa kapanış; değilse son sayım + sonraki hareketler)
public struct StockEstimate: Equatable, Sendable {
    public var itemID: String
    /// Sınırlanmamış tahmin (eksi olabilir: girilmemiş Gelen işareti)
    public var stock: Double
    /// Sayıldıysa o gün; değilse dayanak gün (son sayım ya da elle açılış)
    public var baseDate: String
    public var baseKind: OpeningBaseKind
    public var baseValue: Double
    /// O gün sayıldı (stok = kapanış)
    public var counted: Bool
    public var minStock: Double?
    /// Kritik seviyenin altında
    public var below: Bool
}

/// Bir günde bir stok kaleminin hesaplanmış satırı (Excel'deki Envanter satırı).
public struct ItemCalc {
    public var itemID: String
    public var opening: Double
    /// true: açılış elle girilmedi (son sayımdan / devreden)
    public var openingIsAuto: Bool
    public var incoming: Double
    public var transferIn: Double
    public var transferOut: Double
    public var closing: Double?
    public var sold: Double
    /// Toplam zayi: ModPos ZAYİ ürünleri (ya da Excel'den gelen Zaiyat) + elle girilen zayi
    public var waste: Double
    /// Sayım yapılmadıysa (kapanış boşsa) ya da ilk sayımsa nil
    public var actual: Double?
    public var diff: Double?
    /// Farkın değerlendirmesi (sayım yoksa ya da ilk sayımsa nil)
    public var severity: DiffSeverity?
    /// Kapanış kritik stok seviyesinin altında
    public var belowMinimum: Bool
    /// Açılışın kaynağı
    public var openingSource: OpeningSource = .noBase
    /// Devrin dayanak günü (eskiyse de yazılır; dayanak yoksa nil)
    public var openingBaseDate: String? = nil
    public var openingBaseKind: OpeningBaseKind? = nil
    /// Devreden net hareket (kaynak closing / carried iken; diğerlerinde 0)
    public var carriedNet: Double = 0
    public var carriedDays: Int = 0
    /// İlk sayım: kapanış var, açılış elle girilmedi ve dayanak yok (ya da çok eski) → fark hesaplanmaz
    public var isBaseline: Bool = false
    /// Elle açılış − beklenen açılış (Excel'den aktarılan günlerde ve dayanak yoksa nil)
    public var openingJump: Double? = nil
    /// Açılış sıçraması tolerans dışı ("Sorunlu" nedeni)
    public var openingJumpIsProblem: Bool = false
    /// Elle girilen zayi (Zayi Ekle; `waste` içinde)
    public var manualWaste: Double = 0

    /// Kapanış girilmiş mi (günün bu kalemi için sayım tamam mı)
    public var isCounted: Bool { closing != nil }
    /// Dayanak var ama `Engine.carryMaxDays` günden eski
    public var hasStaleBase: Bool { openingSource == .noBase && openingBaseDate != nil }
    /// Bu kalemle ilgili herhangi bir veri/hareket var mı
    public var hasActivity: Bool {
        opening != 0 || incoming != 0 || transferIn != 0 || transferOut != 0 || closing != nil || sold != 0 || waste != 0
    }
}

/// Bir günün genel durumu (pano ve gün listesi için)
public struct DayOverview: Identifiable {
    public var id: String { date }
    public var date: String
    public var itemCount: Int
    public var countedItems: Int
    public var hasSales: Bool
    public var salesLines: Int
    public var unknownLines: Int
    /// Tolerans dışı fark olan kalem sayısı
    public var problemItems: Int
    /// Beklenenden fazla stok çıkan kalem sayısı
    public var shortageItems: Int
    /// Kritik seviyenin altındaki kalem sayısı
    public var belowMinimumItems: Int
    public var isLocked: Bool

    public var isFullyCounted: Bool { itemCount > 0 && countedItems == itemCount }
    /// Dikkat: sayılan kalemlerin en az %10'unda tolerans dışı fark (web ile aynı tam sayı hesabı)
    public var hasNotableProblems: Bool { problemItems > 0 && problemItems * 10 >= countedItems }
    /// Belirgin sorun: sayılan kalemlerin en az %20'sinde tolerans dışı fark
    public var hasSignificantProblems: Bool { problemItems > 0 && problemItems * 5 >= countedItems }
    public var hasAnyCount: Bool { countedItems > 0 }

    /// Takip şeridindeki renk sınıfı (web `trackerState` ile aynı kural, sırası önemli):
    /// sayım ve satış yok → boş; sayım yok → yalnızca satış; %20 fark → kötü; %10 fark ya da eksik sayım → dikkat; değilse iyi.
    public var trackerState: TrackerState {
        if !hasAnyCount && !hasSales { return .empty }
        if !hasAnyCount { return .salesOnly }
        if hasSignificantProblems { return .bad }
        if hasNotableProblems || !isFullyCounted { return .warn }
        return .ok
    }
}

/// Takip şeridi (son 30 gün) kutusunun durumu. Ham değerler web'deki `TrackerState` anahtarlarıyla aynıdır.
public enum TrackerState: String, CaseIterable {
    /// Sayım da satış raporu da yok
    case empty = "none"
    /// Satış raporu var, sayım yok
    case salesOnly
    /// Sayılanların en az %20'sinde tolerans dışı fark
    case bad
    /// Sayılanların en az %10'unda fark ya da eksik sayım
    case warn
    /// Sayım tam, fark az
    case ok

    /// Renk açıklamasındaki metin (Mac ve web aynı)
    public var label: String {
        switch self {
        case .ok: return "Sayım tam, fark az"
        case .warn: return "Eksik sayım ya da sayılanların %10'unda fark"
        case .bad: return "Sayılanların %20'sinde fark"
        case .salesOnly: return "Yalnızca satış"
        case .empty: return "Veri yok"
        }
    }

    /// Renk açıklamasındaki sıra (iyiden veri yoka)
    public static let legendOrder: [TrackerState] = [.ok, .warn, .bad, .salesOnly, .empty]
}

/// Bir stok kaleminin bir günlük noktası (grafikler için)
public struct ItemDayPoint: Identifiable {
    public var id: String { date }
    public var date: String
    /// Reçeteye göre beklenen tüketim (satılan + zayi)
    public var expected: Double
    /// Sayıma göre fiili tüketim (sayım yoksa nil)
    public var actual: Double?
    public var diff: Double?
    public var closing: Double?
    public var incoming: Double
    public var waste: Double
}

/// Dönemin günlük durumu (Genel Bakış, rapor ve Excel'deki "Günlük Durum" sayfası için)
public struct PeriodStats {
    public var from: String
    public var to: String
    /// Verisi olan günlerin özeti (eskiden yeniye)
    public var days: [DayOverview]
    /// En az bir kalemi sayılmış gün sayısı
    public var countedDays: Int
    /// Satış raporu (ya da Excel'den gelen satış) olan gün sayısı
    public var salesDays: Int
}

/// Sipariş önerisi satırı
public struct OrderSuggestion: Identifiable {
    public var id: String { item.id }
    public var item: Item
    /// Tahmini mevcut stok: son sayılan kapanış + sonraki (henüz sayılmamış) günlerin hareketleri
    public var stock: Double?
    /// Son sayımın günü
    public var stockDate: String?
    /// Son sayımdaki kapanış (hareketler eklenmeden)
    public var countedStock: Double?
    /// Açık siparişlerde bekleyen miktar (henüz teslim alınmamış)
    public var onOrder: Double
    /// Ortalama günlük tüketim (envanter birimi)
    public var dailyUsage: Double
    /// Ortalamanın hesaplandığı gün sayısı
    public var sampleDays: Int
    /// Mevcut stok kaç gün yeter
    public var daysOfCover: Double?
    /// Hedef stok = günlük tüketim × gün + emniyet stoğu
    public var target: Double
    /// Önerilen sipariş miktarı (yukarı yuvarlanmış)
    public var suggested: Double
    /// Stoğun dayanağı (`stockEstimate(date)` ile aynı: sınırlanmamış tahmin, dayanak günü ve türü); yoksa ya da
    /// `carryMaxDays` günden eskiyse nil
    public var estimate: StockEstimate? = nil
}

/// Dayanak noktası: kapanışı girilmiş ya da kapanışsız elle açılış girilmiş gün
struct OpeningBasePoint {
    var date: String
    var kind: OpeningBaseKind
    var value: Double
}

/// Motorun hesap önbelleği: veri değişmediği sürece günlük analiz, hareket ve satır hesapları yeniden yapılmaz.
/// Motor arka plan görevlerinde de kullanıldığından erişim kilitlidir (hesaplar kilidin dışında yapılır).
final class EngineCache: @unchecked Sendable {
    private let lock = NSLock()
    var analyses: [String: SalesAnalysis] = [:]
    var manualWastes: [String: [String: Double]] = [:]
    var movements: [String: [String: CarryDay]] = [:]
    var calcs: [String: [ItemCalc]] = [:]
    var bases: [String: [OpeningBasePoint]] = [:]
    var estimates: [String: [StockEstimate]] = [:]

    func get<V>(_ kp: ReferenceWritableKeyPath<EngineCache, [String: V]>, _ key: String) -> V? {
        lock.lock(); defer { lock.unlock() }
        return self[keyPath: kp][key]
    }

    func set<V>(_ kp: ReferenceWritableKeyPath<EngineCache, [String: V]>, _ key: String, _ value: V) {
        lock.lock(); defer { lock.unlock() }
        self[keyPath: kp][key] = value
    }
}

public struct Engine {
    /// Devrin en uzun aralığı (gün): dayanak bundan eskiyse sonraki sayım başlangıç kabul edilir (web `CARRY_MAX_DAYS`)
    public static let carryMaxDays = 31

    public let data: AppData
    public let itemsByID: [String: Item]
    public let productsByCode: [String: Product]
    private let sortedDates: [String]
    /// Verisi olan günler (eskiden yeniye)
    public let datesWithData: [String]
    private let cache = EngineCache()

    public init(data: AppData) {
        self.data = data
        // Aynı kimlik iki kez varsa ilki geçerlidir (bozuk / elle düzenlenmiş yedeklerde çökmemek için)
        self.itemsByID = Dictionary(data.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var byCode: [String: Product] = [:]
        for p in data.products where byCode[p.code] == nil { byCode[p.code] = p }
        self.productsByCode = byCode
        self.sortedDates = data.days.keys.sorted()
        self.datesWithData = sortedDates.filter { !(data.days[$0]?.isEmpty ?? true) }
    }

    /// Ekranda gösterilen (aktif) kalemler, kullanıcının sıralamasıyla
    public var activeItems: [Item] {
        var seen = Set<String>()
        return data.items.filter { $0.active && seen.insert($0.id).inserted }
    }

    // MARK: - Satış -> hammadde tüketimi (Excel'deki KOD sayfası)

    public func analyze(sales: [SaleLine]) -> SalesAnalysis {
        var result = SalesAnalysis()
        for line in sales {
            guard let product = productsByCode[line.code] else {
                result.status[line.code] = .unknown
                result.unknownLines.append(line)
                continue
            }
            if !product.isTracked {
                result.status[line.code] = .untracked
                result.untrackedLines.append(line)
                continue
            }
            result.status[line.code] = .tracked
            result.trackedLines.append(line)
            for (itemID, perUnit) in product.amounts.sorted(by: { $0.key < $1.key }) where perUnit != 0 {
                guard let item = itemsByID[itemID] else { continue }
                let amount = line.qty * perUnit * item.factor
                if product.isWaste { result.waste[itemID, default: 0] += amount }
                else { result.sold[itemID, default: 0] += amount }
                result.contributions[itemID, default: []].append(
                    Contribution(code: line.code, name: product.name, qty: line.qty, perUnit: perUnit,
                                 amount: amount, isWaste: product.isWaste))
            }
        }
        return result
    }

    /// Günün satış analizi (önbellekli)
    public func analysis(date: String) -> SalesAnalysis {
        if let a = cache.get(\.analyses, date) { return a }
        let a = analyze(sales: data.days[date]?.sales ?? [])
        cache.set(\.analyses, date, a)
        return a
    }

    /// Günün elle girilen zayisi: kalem id → toplam miktar (önbellekli). Bilinmeyen kaleme ait ya da miktarı > 0 olmayan
    /// kayıtlar atlanır.
    public func manualWaste(date: String) -> [String: Double] {
        if let m = cache.get(\.manualWastes, date) { return m }
        var out: [String: Double] = [:]
        for e in data.days[date]?.wasteLog ?? [] where itemsByID[e.itemID] != nil && e.qty.isFinite && e.qty > 0 {
            out[e.itemID, default: 0] += e.qty
        }
        out = out.mapValues { Self.clean($0) }
        cache.set(\.manualWastes, date, out)
        return out
    }

    // MARK: - Açılış devri (Excel'deki "YeniEnvanterAç" makrosu + sayılmayan günlerin hareketleri)

    /// `key`'den küçük olmayan ilk günün konumu (ikili arama)
    private func lowerBound(_ key: String) -> Int {
        var lo = 0, hi = sortedDates.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sortedDates[mid] < key { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Verilen günden önceki, kapanışı girilmiş en son güne ait kapanış.
    public func previousClosing(itemID: String, before date: String) -> Double? {
        lastClosing(itemID: itemID, before: date)?.value
    }

    /// Verilen günden önceki, kapanışı girilmiş en son gün ve kapanış değeri.
    public func lastClosing(itemID: String, before date: String) -> (date: String, value: Double)? {
        var i = lowerBound(date) - 1
        while i >= 0 {
            let d = sortedDates[i]
            if let c = data.days[d]?.entries[itemID]?.closing { return (d, c) }
            i -= 1
        }
        return nil
    }

    /// Günün kalem bazında hareketleri (önbellekli). Satılan ve Zayi `calcRow` ile aynı kaynaktan (satış dökümü ya da
    /// Excel'den gelen değerler; Zayi'ye elle girilen zayi eklenir).
    func movements(on date: String) -> [String: CarryDay] {
        if let m = cache.get(\.movements, date) { return m }
        var out: [String: CarryDay] = [:]
        if let day = data.days[date] {
            let useLegacy = day.usesLegacySales
            let a = useLegacy ? SalesAnalysis() : analysis(date: date)
            let manual = manualWaste(date: date)
            var ids = Set(day.entries.keys).union(manual.keys)
            if useLegacy {
                ids.formUnion((day.legacySold ?? [:]).keys)
                ids.formUnion((day.legacyWaste ?? [:]).keys)
            } else {
                ids.formUnion(a.sold.keys)
                ids.formUnion(a.waste.keys)
            }
            for id in ids {
                let e = day.entries[id]
                let inc = e?.incoming ?? 0, tin = e?.transferIn ?? 0, tout = e?.transferOut ?? 0
                let sold = Self.clean(useLegacy ? (day.legacySold?[id] ?? 0) : (a.sold[id] ?? 0))
                let waste = Self.clean((useLegacy ? (day.legacyWaste?[id] ?? 0) : (a.waste[id] ?? 0)) + (manual[id] ?? 0))
                out[id] = CarryDay(date: date, incoming: inc, transferIn: tin, transferOut: tout, sold: sold, waste: waste,
                                   net: Self.clean(inc + tin - tout - sold - waste))
            }
        }
        cache.set(\.movements, date, out)
        return out
    }

    /// Kalemin dayanak günleri (kapanışı ya da kapanışsız elle açılışı olan günler), eskiden yeniye (önbellekli)
    private func basePoints(_ itemID: String) -> [OpeningBasePoint] {
        if let b = cache.get(\.bases, itemID) { return b }
        var out: [OpeningBasePoint] = []
        for d in sortedDates {
            guard let e = data.days[d]?.entries[itemID] else { continue }
            if let c = e.closing { out.append(OpeningBasePoint(date: d, kind: .closing, value: c)) }
            else if let o = e.opening { out.append(OpeningBasePoint(date: d, kind: .manualOpening, value: o)) }
        }
        cache.set(\.bases, itemID, out)
        return out
    }

    /// `date`'ten önceki en yakın dayanak: kapanışı girilmiş gün ya da kapanışsız elle açılış girilmiş gün
    public func openingBase(itemID: String, before date: String) -> (date: String, kind: OpeningBaseKind, value: Double)? {
        let points = basePoints(itemID)
        var lo = 0, hi = points.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if points[mid].date < date { lo = mid + 1 } else { hi = mid }
        }
        guard lo > 0 else { return nil }
        let p = points[lo - 1]
        return (p.date, p.kind, p.value)
    }

    /// Devirde yürünen günler: dayanaktan sonra `date`'ten önce kaydı olan günler (elle açılışta dayanak günü de)
    private func walkDates(after base: String, before date: String, includeBase: Bool) -> ArraySlice<String> {
        var start = lowerBound(base)
        let end = lowerBound(date)
        if !includeBase, start < sortedDates.count, sortedDates[start] == base { start += 1 }
        return start < end ? sortedDates[start..<end] : []
    }

    /// Dayanak (eskiyse de) ve geçerli tahmin (dayanak yoksa ya da `carryMaxDays` günden eskiyse tahmin nil)
    func openingLookup(itemID: String, date: String) -> (baseDate: String?, baseKind: OpeningBaseKind?, estimate: OpeningEstimate?) {
        guard let base = openingBase(itemID: itemID, before: date) else { return (nil, nil, nil) }
        guard let gap = DateKey.distance(from: base.date, to: date), gap <= Self.carryMaxDays else {
            return (base.date, base.kind, nil)
        }
        var net = 0.0, days = 0
        for d in walkDates(after: base.date, before: date, includeBase: base.kind == .manualOpening) {
            guard let m = movements(on: d)[itemID] else { continue }
            net += m.net
            if m.net != 0 { days += 1 }
        }
        let est = OpeningEstimate(value: Self.clean(base.value + net), baseDate: base.date, baseKind: base.kind,
                                  baseValue: base.value, carriedNet: Self.clean(net), carriedDays: days)
        return (base.date, base.kind, est)
    }

    /// Tahmini açılış: son sayımın kapanışı (ya da kapanışsız elle açılış) + aradaki sayılmayan günlerin gelen,
    /// transfer, satış ve zayisi. Dayanak yoksa ya da `carryMaxDays` günden eskiyse nil. Sınırlanmaz (eksi olabilir).
    public func estimatedOpening(itemID: String, date: String) -> OpeningEstimate? {
        openingLookup(itemID: itemID, date: date).estimate
    }

    /// Devreden açılışın dökümü: yürünen günlerden net hareketi olanlar (eskiden yeniye)
    public func carryBreakdown(itemID: String, date: String) -> [CarryDay] {
        guard let est = estimatedOpening(itemID: itemID, date: date) else { return [] }
        return walkDates(after: est.baseDate, before: date, includeBase: est.baseKind == .manualOpening).compactMap { d in
            guard let m = movements(on: d)[itemID], m.net != 0 else { return nil }
            return m
        }
    }

    // MARK: - Günlük hesap

    /// Günde en az bir (aktif) kalemin kapanışı girilmiş mi: `calc(date:).rows.contains { $0.isCounted }` ile aynı,
    /// satış analizi yapılmadan (Gün menüsü her çizimde sorar)
    public func hasCount(date: String) -> Bool {
        guard let entries = data.days[date]?.entries, !entries.isEmpty else { return false }
        return activeItems.contains { entries[$0.id]?.closing != nil }
    }

    /// Günün hesabı (önbellekli)
    public func calc(date: String) -> (rows: [ItemCalc], analysis: SalesAnalysis) {
        let a = analysis(date: date)
        if let rows = cache.get(\.calcs, date) { return (rows, a) }
        let day = data.days[date]
        let rows = activeItems.map { calcRow(item: $0, date: date, day: day, analysis: a) }
        cache.set(\.calcs, date, rows)
        return (rows, a)
    }

    func calcRow(item: Item, date: String, day: DayRecord?, analysis: SalesAnalysis) -> ItemCalc {
        let entry = day?.entries[item.id] ?? DayEntry()
        let lookup = openingLookup(itemID: item.id, date: date)
        let est = lookup.estimate
        let opening = entry.opening ?? est?.value ?? 0
        let source: OpeningSource
        if entry.opening != nil { source = .manual }
        else if let est { source = (est.carriedDays > 0 || est.baseKind == .manualOpening) ? .carried : .closing }
        else { source = .noBase }
        let incoming = entry.incoming ?? 0
        let tin = entry.transferIn ?? 0
        let tout = entry.transferOut ?? 0
        let useLegacy = day?.usesLegacySales ?? false
        let sold = useLegacy ? (day?.legacySold?[item.id] ?? 0) : (analysis.sold[item.id] ?? 0)
        // Zayi = ModPos ZAYİ ürünleri (ya da Excel'den gelen Zaiyat) + elle girilen zayi
        let manual = manualWaste(date: date)[item.id] ?? 0
        let waste = (useLegacy ? (day?.legacyWaste?[item.id] ?? 0) : (analysis.waste[item.id] ?? 0)) + manual
        // İlk sayım: önceki kapanış yok (ya da çok eski) ve açılış elle girilmedi → fark hesaplanmaz
        let isBaseline = entry.closing != nil && entry.opening == nil && est == nil
        var actual: Double?
        var diff: Double?
        var severity: DiffSeverity?
        if let closing = entry.closing, !isBaseline {
            // Fiili Tüketim = Açılış + Gelen + Gelen Transfer - (Giden Transfer + Kapanış)
            let a = opening + incoming + tin - (tout + closing)
            actual = Self.clean(a)
            // Fark = (Satılan + Zayi) - Fiili Tüketim   (negatif: beklenenden fazla stok çıkışı)
            let d = Self.clean(sold + waste - a)
            diff = d
            severity = item.severity(of: d)
        }
        // Elle açılış beklenenden farklıysa: arada ortaya çıkan / kaybolan stok (Excel'den aktarılan günler hariç)
        var jump: Double?
        if let o = entry.opening, let est, day?.importedFrom == nil { jump = Self.clean(o - est.value) }
        var row = ItemCalc(itemID: item.id, opening: opening, openingIsAuto: entry.opening == nil,
                           incoming: incoming, transferIn: tin, transferOut: tout, closing: entry.closing,
                           sold: Self.clean(sold), waste: Self.clean(waste), actual: actual, diff: diff,
                           severity: severity, belowMinimum: item.isBelowMinimum(entry.closing))
        row.openingSource = source
        row.openingBaseDate = lookup.baseDate
        row.openingBaseKind = lookup.baseKind
        if source == .closing || source == .carried, let est {
            row.carriedNet = est.carriedNet
            row.carriedDays = est.carriedDays
        }
        row.isBaseline = isBaseline
        row.openingJump = jump
        row.openingJumpIsProblem = jump.map { item.severity(of: $0).isProblem } ?? false
        row.manualWaste = manual
        return row
    }

    /// Kayan nokta artıklarını temizler (10.864000000000001 -> 10.864).
    static func clean(_ v: Double) -> Double {
        let r = (v * 1_000_000).rounded() / 1_000_000
        return r == 0 ? 0 : r
    }

    // MARK: - Gün özeti (pano)

    public func overview(date: String) -> DayOverview {
        let (rows, analysis) = calc(date: date)
        return overview(date: date, rows: rows, analysis: analysis)
    }

    public func overview(date: String, rows: [ItemCalc], analysis: SalesAnalysis) -> DayOverview {
        let day = data.days[date]
        var o = DayOverview(date: date, itemCount: rows.count, countedItems: 0, hasSales: day?.hasSalesData ?? false,
                            salesLines: day?.sales.count ?? 0, unknownLines: analysis.unknownLines.count,
                            problemItems: 0, shortageItems: 0, belowMinimumItems: 0, isLocked: day?.isLocked ?? false)
        for r in rows {
            if r.isCounted { o.countedItems += 1 }
            if r.belowMinimum { o.belowMinimumItems += 1 }
            if r.severity?.isProblem == true { o.problemItems += 1 }
            if r.severity == .shortage { o.shortageItems += 1 }
        }
        return o
    }

    /// `end` dahil geriye doğru `days` günün özeti (eskiden yeniye)
    public func trend(endingAt end: String, days: Int) -> [DayOverview] {
        (0..<max(days, 0)).reversed().map { overview(date: DateKey.addDays(-$0, to: end)) }
    }

    // MARK: - Dönem özeti (Excel'deki "Özet" sayfası)

    public struct SummaryRow: Identifiable {
        public var id: String { item.id }
        public var item: Item
        public var daysCounted: Int
        public var firstOpening: Double?
        public var lastClosing: Double?
        public var incoming: Double
        public var transferIn: Double
        public var transferOut: Double
        public var sold: Double
        public var waste: Double
        public var actual: Double
        public var diff: Double
        /// Tolerans dışı fazla çıkış olan günlerin miktarı (pozitif, envanter birimi; az çıkışlarla mahsup edilmez)
        public var shortageQty: Double = 0
        /// Tolerans dışı fazla çıkış olan gün sayısı
        public var shortageDays: Int
        public var daily: [(date: String, diff: Double)]
        /// Dönemdeki elle açılış sıçramalarının toplamı (+ ortaya çıkan, − kaybolan stok)
        public var openingAdjust: Double = 0

        public var severity: DiffSeverity { item.severity(of: diff) }
    }

    /// from...to (dahil) arasındaki günlerin toplamı. Sayılmış günler (ilk sayım hariç) ve hareketi sonraki sayıma
    /// devredilen sayılmayan günler hesaba katılır; devredilen günün fiili tüketimi Satılan + Zayi sayılır. Böylece
    /// Fark = Satılan + Zayi - Fiili özdeşliği dönem toplamında da korunur. Sayılmayan gün, sonraki sayımın geçerli
    /// dayanağından sonraysa devredilir: hareketleri birbirini götürse de (net 0), sonraki sayımın açılışı elle
    /// girilse de (sıçrama `openingAdjust`'ta).
    public func summary(from: String, to: String) -> [SummaryRow] {
        let dates = sortedDates.filter { $0 >= from && $0 <= to }
        var perDay: [(String, [String: ItemCalc])] = []
        for d in dates {
            let rows = calc(date: d).rows
            perDay.append((d, Dictionary(rows.map { ($0.itemID, $0) }, uniquingKeysWith: { a, _ in a })))
        }
        return activeItems.map { item in
            var r = SummaryRow(item: item, daysCounted: 0, firstOpening: nil, lastClosing: nil,
                               incoming: 0, transferIn: 0, transferOut: 0, sold: 0, waste: 0,
                               actual: 0, diff: 0, shortageDays: 0, daily: [])
            // Sondan başa: hareketi dönem içindeki sonraki sayıma devredilen sayılmayan günler
            var carried = Set<String>()
            var carryBase: String?
            for (d, calcs) in perDay.reversed() {
                guard let c = calcs[item.id] else { continue }
                if c.isCounted {
                    carryBase = c.isBaseline ? nil : summaryCarryBase(c, date: d)
                } else if let b = carryBase, d >= b {
                    carried.insert(d)
                }
            }
            for (d, calcs) in perDay {
                guard let c = calcs[item.id] else { continue }
                r.openingAdjust += c.openingJump ?? 0
                if c.isCounted, let actual = c.actual, let diff = c.diff {
                    r.daysCounted += 1
                    if r.firstOpening == nil { r.firstOpening = c.opening }
                    r.lastClosing = c.closing
                    r.incoming += c.incoming; r.transferIn += c.transferIn; r.transferOut += c.transferOut
                    r.sold += c.sold; r.waste += c.waste; r.actual += actual; r.diff += diff
                    if c.severity == .shortage {
                        r.shortageDays += 1
                        r.shortageQty -= diff
                    }
                    r.daily.append((d, diff))
                } else if carried.contains(d) {
                    if r.firstOpening == nil { r.firstOpening = c.opening }
                    r.incoming += c.incoming; r.transferIn += c.transferIn; r.transferOut += c.transferOut
                    r.sold += c.sold; r.waste += c.waste; r.actual += c.sold + c.waste
                }
            }
            r.incoming = Self.clean(r.incoming); r.transferIn = Self.clean(r.transferIn)
            r.transferOut = Self.clean(r.transferOut); r.sold = Self.clean(r.sold)
            r.waste = Self.clean(r.waste); r.actual = Self.clean(r.actual); r.diff = Self.clean(r.diff)
            r.shortageQty = Self.clean(r.shortageQty); r.openingAdjust = Self.clean(r.openingAdjust)
            return r
        }
    }

    /// Sayılmış satırın geçerli dayanağının günü (`carryMaxDays` içinde): aradaki sayılmayan günler bu sayıma devreder
    private func summaryCarryBase(_ c: ItemCalc, date: String) -> String? {
        switch c.openingSource {
        case .closing, .carried: return c.openingBaseDate
        case .manual: return estimatedOpening(itemID: c.itemID, date: date)?.baseDate
        case .noBase: return nil
        }
    }

    // MARK: - Dönem

    /// from...to (dahil) arasındaki verisi olan günlerin özeti
    public func periodStats(from: String, to: String) -> PeriodStats {
        let days = datesWithData.filter { $0 >= from && $0 <= to }.map { overview(date: $0) }
        return PeriodStats(from: from, to: to, days: days, countedDays: days.filter { $0.hasAnyCount }.count,
                           salesDays: days.filter { $0.hasSales }.count)
    }

    // MARK: - Kalem analizi

    /// Bir kalemin verisi olan günlerdeki beklenen ve fiili tüketimi (hareket olmayan günler atlanır)
    public func itemSeries(itemID: String, from: String, to: String) -> [ItemDayPoint] {
        datesWithData.filter { $0 >= from && $0 <= to }.compactMap { d in
            guard let r = calc(date: d).rows.first(where: { $0.itemID == itemID }), r.hasActivity else { return nil }
            return ItemDayPoint(date: d, expected: Self.clean(r.sold + r.waste), actual: r.actual, diff: r.diff,
                                closing: r.closing, incoming: r.incoming, waste: r.waste)
        }
    }

    // MARK: - Tahmini stok

    /// Kalemin o günkü tahmini stoğu: sayıldıysa kapanış; değilse son sayım (ya da elle açılış) + sonraki hareketler
    /// (`estimatedOpening(addDays(1, date))`, sınırlanmaz). Dayanak yoksa ya da çok eskiyse nil.
    public func stockEstimate(itemID: String, date: String) -> StockEstimate? {
        guard let item = itemsByID[itemID] else { return nil }
        let stock: Double, baseDate: String, kind: OpeningBaseKind, baseValue: Double, counted: Bool
        if let c = data.days[date]?.entries[itemID]?.closing {
            stock = c; baseDate = date; kind = .closing; baseValue = c; counted = true
        } else if let est = estimatedOpening(itemID: itemID, date: DateKey.addDays(1, to: date)) {
            stock = est.value; baseDate = est.baseDate; kind = est.baseKind; baseValue = est.baseValue; counted = false
        } else {
            return nil
        }
        let m = item.minStock ?? 0
        return StockEstimate(itemID: itemID, stock: Self.clean(stock), baseDate: baseDate, baseKind: kind, baseValue: baseValue,
                             counted: counted, minStock: item.minStock, below: m > 0 && stock < m)
    }

    /// Aktif kalemlerin tahmini stokları (dayanağı olanlar; önbellekli)
    public func stockEstimates(date: String) -> [StockEstimate] {
        if let e = cache.get(\.estimates, date) { return e }
        let out = activeItems.compactMap { stockEstimate(itemID: $0.id, date: date) }
        cache.set(\.estimates, date, out)
        return out
    }

    // MARK: - Sipariş önerisi

    /// `date` itibarıyla açık siparişlerde bekleyen (teslim alınmamış) miktarlar
    public func onOrder(asOf date: String) -> [String: Double] {
        var out: [String: Double] = [:]
        for o in data.purchaseOrders where o.status == .open && o.date <= date {
            for l in o.lines { out[l.itemID, default: 0] += max(l.qty - (l.received ?? 0), 0) }
        }
        return out
    }

    /// `date` itibarıyla her aktif kalem için sipariş önerisi.
    /// Günlük tüketim, son `lookbackDays` gün içinde sayımı yapılmış günlerin fiili tüketim ortalamasıdır;
    /// sayım yoksa satış raporundan (satılan + zayi) hesaplanır.
    /// Mevcut stok = `stockEstimate(date)`: o gün sayıldıysa kapanış, değilse son sayım (ya da elle açılış) + sonraki
    /// gelen/transfer − satış ve zayi, sıfırın altına inmez; dayanak yoksa ya da `carryMaxDays` günden eskiyse
    /// bilinmiyor. Açık siparişlerde bekleyen miktar öneriden düşülür.
    public func orderSuggestions(asOf date: String, lookbackDays: Int, coverDays: Double) -> [OrderSuggestion] {
        let lookback = max(1, lookbackDays)
        let window = (0..<lookback).map { DateKey.addDays(-$0, to: date) }.filter { data.days[$0] != nil }
        var counted: [String: [Double]] = [:]
        var fromSales: [String: [Double]] = [:]
        for d in window {
            let hasSales = data.days[d]?.hasSalesData ?? false
            for c in calc(date: d).rows {
                if let a = c.actual { counted[c.itemID, default: []].append(max(a, 0)) }
                else if hasSales { fromSales[c.itemID, default: []].append(c.sold + c.waste) }
            }
        }
        let tomorrow = DateKey.addDays(1, to: date)
        let pending = onOrder(asOf: date)
        let estimates = Dictionary(stockEstimates(date: date).map { ($0.itemID, $0) }, uniquingKeysWith: { a, _ in a })
        return activeItems.map { item in
            let samples = counted[item.id].flatMap { $0.isEmpty ? nil : $0 } ?? fromSales[item.id] ?? []
            let usage = samples.isEmpty ? 0 : samples.reduce(0, +) / Double(samples.count)
            let last = lastClosing(itemID: item.id, before: tomorrow)
            let est = estimates[item.id]
            // Bugünkü sayım olduğu gibi; tahmin (sayımdan ya da elle açılıştan sonraki hareketler) sıfırın altına inmez
            let stock: Double? = est.map { $0.counted ? $0.stock : max($0.stock, 0) }
            let onOrder = pending[item.id] ?? 0
            let target = usage * max(coverDays, 0) + max(item.minStock ?? 0, 0)
            var suggested = max(0, target - (stock ?? 0) - onOrder)
            // Adet kalemler tam sayıya, kg kalemler 0,1'e yukarı yuvarlanır
            suggested = item.isKg ? (suggested * 10 - 1e-9).rounded(.up) / 10 : (suggested - 1e-9).rounded(.up)
            suggested = max(suggested, 0)
            return OrderSuggestion(
                item: item, stock: stock.map(Self.clean), stockDate: last?.date, countedStock: last?.value, onOrder: Self.clean(onOrder),
                dailyUsage: Self.clean(usage), sampleDays: samples.count,
                daysOfCover: (stock != nil && usage > 0) ? Self.clean(stock! / usage) : nil,
                target: Self.clean(target), suggested: Self.clean(suggested), estimate: est)
        }
    }
}
