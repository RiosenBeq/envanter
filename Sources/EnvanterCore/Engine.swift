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

/// Bir günde bir stok kaleminin hesaplanmış satırı (Excel'deki Envanter satırı).
public struct ItemCalc {
    public var itemID: String
    public var opening: Double
    /// true: açılış elle girilmedi, önceki günün kapanışından geldi
    public var openingIsAuto: Bool
    public var incoming: Double
    public var transferIn: Double
    public var transferOut: Double
    public var closing: Double?
    public var sold: Double
    public var waste: Double
    /// Sayım yapılmadıysa (kapanış boşsa) nil
    public var actual: Double?
    public var diff: Double?
    /// Farkın değerlendirmesi (sayım yoksa nil)
    public var severity: DiffSeverity?
    /// Farkın parasal karşılığı (₺; birim maliyet tanımlı değilse nil)
    public var diffValue: Double?
    /// Kapanış kritik stok seviyesinin altında
    public var belowMinimum: Bool

    /// Kapanış girilmiş mi (günün bu kalemi için sayım tamam mı)
    public var isCounted: Bool { closing != nil }
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
    /// Fazla çıkışların (kayıp) parasal toplamı, pozitif sayı (₺)
    public var lossValue: Double
    /// Tüm farkların net parasal toplamı (₺)
    public var netValue: Double
    public var isLocked: Bool

    public var isFullyCounted: Bool { itemCount > 0 && countedItems == itemCount }
    public var hasAnyCount: Bool { countedItems > 0 }
}

/// Sipariş önerisi satırı
public struct OrderSuggestion: Identifiable {
    public var id: String { item.id }
    public var item: Item
    /// Son sayılan stok (kapanış)
    public var stock: Double?
    public var stockDate: String?
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
    /// Önerilen siparişin maliyeti (₺)
    public var cost: Double?
}

public struct Engine {
    public let data: AppData
    public let itemsByID: [String: Item]
    public let productsByCode: [String: Product]
    private let sortedDates: [String]
    /// Verisi olan günler (eskiden yeniye)
    public let datesWithData: [String]

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

    // MARK: - Açılış devri (Excel'deki "YeniEnvanterAç" makrosu)

    /// Verilen günden önceki, kapanışı girilmiş en son güne ait kapanış.
    public func previousClosing(itemID: String, before date: String) -> Double? {
        lastClosing(itemID: itemID, before: date)?.value
    }

    /// Verilen günden önceki, kapanışı girilmiş en son gün ve kapanış değeri.
    public func lastClosing(itemID: String, before date: String) -> (date: String, value: Double)? {
        // İkili arama: date'ten küçük son anahtarın konumu
        var lo = 0, hi = sortedDates.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sortedDates[mid] < date { lo = mid + 1 } else { hi = mid }
        }
        var i = lo - 1
        while i >= 0 {
            let d = sortedDates[i]
            if let c = data.days[d]?.entries[itemID]?.closing { return (d, c) }
            i -= 1
        }
        return nil
    }

    // MARK: - Günlük hesap

    public func calc(date: String) -> (rows: [ItemCalc], analysis: SalesAnalysis) {
        let day = data.days[date]
        let analysis = analyze(sales: day?.sales ?? [])
        let rows = activeItems.map { calcRow(item: $0, date: date, day: day, analysis: analysis) }
        return (rows, analysis)
    }

    func calcRow(item: Item, date: String, day: DayRecord?, analysis: SalesAnalysis) -> ItemCalc {
        let entry = day?.entries[item.id] ?? DayEntry()
        let opening = entry.opening ?? previousClosing(itemID: item.id, before: date) ?? 0
        let incoming = entry.incoming ?? 0
        let tin = entry.transferIn ?? 0
        let tout = entry.transferOut ?? 0
        let useLegacy = day?.usesLegacySales ?? false
        let sold = useLegacy ? (day?.legacySold?[item.id] ?? 0) : (analysis.sold[item.id] ?? 0)
        let waste = useLegacy ? (day?.legacyWaste?[item.id] ?? 0) : (analysis.waste[item.id] ?? 0)
        var actual: Double?
        var diff: Double?
        var severity: DiffSeverity?
        var diffValue: Double?
        if let closing = entry.closing {
            // Fiili Tüketim = Açılış + Gelen + Gelen Transfer - (Giden Transfer + Kapanış)
            let a = opening + incoming + tin - (tout + closing)
            actual = Self.clean(a)
            // Fark = (Satılan + Zayi) - Fiili Tüketim   (negatif: beklenenden fazla stok çıkışı)
            let d = Self.clean(sold + waste - a)
            diff = d
            severity = item.severity(of: d)
            if let cost = item.unitCost { diffValue = Self.clean(d * cost) }
        }
        return ItemCalc(itemID: item.id, opening: opening, openingIsAuto: entry.opening == nil,
                        incoming: incoming, transferIn: tin, transferOut: tout, closing: entry.closing,
                        sold: Self.clean(sold), waste: Self.clean(waste), actual: actual, diff: diff,
                        severity: severity, diffValue: diffValue, belowMinimum: item.isBelowMinimum(entry.closing))
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
                            problemItems: 0, shortageItems: 0, belowMinimumItems: 0, lossValue: 0, netValue: 0,
                            isLocked: day?.isLocked ?? false)
        for r in rows {
            if r.isCounted { o.countedItems += 1 }
            if r.belowMinimum { o.belowMinimumItems += 1 }
            if r.severity?.isProblem == true { o.problemItems += 1 }
            if r.severity == .shortage {
                o.shortageItems += 1
                if let v = r.diffValue { o.lossValue -= v }
            }
            if let v = r.diffValue { o.netValue += v }
        }
        o.lossValue = Self.clean(o.lossValue); o.netValue = Self.clean(o.netValue)
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
        /// Toplam farkın parasal karşılığı (₺; maliyet tanımlı değilse nil)
        public var diffValue: Double?
        /// Tolerans dışı fazla çıkış olan gün sayısı
        public var shortageDays: Int
        public var daily: [(date: String, diff: Double)]

        public var severity: DiffSeverity { item.severity(of: diff) }
    }

    /// from...to (dahil) arasındaki günlerin toplamı. Yalnızca kapanışı sayılmış günler hesaba katılır;
    /// böylece Fark = Satılan + Zayi - Fiili özdeşliği dönem toplamında da korunur.
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
                               actual: 0, diff: 0, diffValue: nil, shortageDays: 0, daily: [])
            for (d, calcs) in perDay {
                guard let c = calcs[item.id], c.isCounted, let actual = c.actual, let diff = c.diff else { continue }
                r.daysCounted += 1
                if r.firstOpening == nil { r.firstOpening = c.opening }
                r.lastClosing = c.closing
                r.incoming += c.incoming; r.transferIn += c.transferIn; r.transferOut += c.transferOut
                r.sold += c.sold; r.waste += c.waste; r.actual += actual; r.diff += diff
                if c.severity == .shortage { r.shortageDays += 1 }
                r.daily.append((d, diff))
            }
            r.incoming = Self.clean(r.incoming); r.transferIn = Self.clean(r.transferIn)
            r.transferOut = Self.clean(r.transferOut); r.sold = Self.clean(r.sold)
            r.waste = Self.clean(r.waste); r.actual = Self.clean(r.actual); r.diff = Self.clean(r.diff)
            if let cost = item.unitCost, r.daysCounted > 0 { r.diffValue = Self.clean(r.diff * cost) }
            return r
        }
    }

    // MARK: - Sipariş önerisi

    /// `date` itibarıyla her aktif kalem için sipariş önerisi.
    /// Günlük tüketim, son `lookbackDays` gün içinde sayımı yapılmış günlerin fiili tüketim ortalamasıdır;
    /// sayım yoksa satış raporundan (satılan + zayi) hesaplanır.
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
        return activeItems.map { item in
            let samples = counted[item.id].flatMap { $0.isEmpty ? nil : $0 } ?? fromSales[item.id] ?? []
            let usage = samples.isEmpty ? 0 : samples.reduce(0, +) / Double(samples.count)
            let last = lastClosing(itemID: item.id, before: tomorrow)
            let stock = last?.value
            let target = usage * max(coverDays, 0) + max(item.minStock ?? 0, 0)
            var suggested = max(0, target - (stock ?? 0))
            // Adet kalemler tam sayıya, kg kalemler 0,1'e yukarı yuvarlanır
            suggested = item.isKg ? (suggested * 10 - 1e-9).rounded(.up) / 10 : (suggested - 1e-9).rounded(.up)
            suggested = max(suggested, 0)
            return OrderSuggestion(
                item: item, stock: stock, stockDate: last?.date, dailyUsage: Self.clean(usage), sampleDays: samples.count,
                daysOfCover: (stock != nil && usage > 0) ? Self.clean(stock! / usage) : nil,
                target: Self.clean(target), suggested: Self.clean(suggested),
                cost: item.unitCost.map { Self.clean($0 * suggested) })
        }
    }
}
