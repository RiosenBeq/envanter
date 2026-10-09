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

    /// Kapanış girilmiş mi (günün bu kalemi için sayım tamam mı)
    public var isCounted: Bool { closing != nil }
    /// Bu kalemle ilgili herhangi bir veri/hareket var mı
    public var hasActivity: Bool {
        opening != 0 || incoming != 0 || transferIn != 0 || transferOut != 0 || closing != nil || sold != 0 || waste != 0
    }
}

public struct Engine {
    public let data: AppData
    public let itemsByID: [String: Item]
    public let productsByCode: [String: Product]
    private let sortedDates: [String]

    public init(data: AppData) {
        self.data = data
        self.itemsByID = Dictionary(uniqueKeysWithValues: data.items.map { ($0.id, $0) })
        var byCode: [String: Product] = [:]
        for p in data.products { byCode[p.code] = p }
        self.productsByCode = byCode
        self.sortedDates = data.days.keys.sorted()
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
            for (itemID, perUnit) in product.amounts where perUnit != 0 {
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
        var i = sortedDates.count - 1
        while i >= 0 {
            let d = sortedDates[i]
            if d < date, let c = data.days[d]?.entries[itemID]?.closing { return c }
            i -= 1
        }
        return nil
    }

    // MARK: - Günlük hesap

    public func calc(date: String) -> (rows: [ItemCalc], analysis: SalesAnalysis) {
        let day = data.days[date]
        let analysis = analyze(sales: day?.sales ?? [])
        var rows: [ItemCalc] = []
        for item in data.items where item.active {
            rows.append(calcRow(item: item, date: date, day: day, analysis: analysis))
        }
        return (rows, analysis)
    }

    func calcRow(item: Item, date: String, day: DayRecord?, analysis: SalesAnalysis) -> ItemCalc {
        let entry = day?.entries[item.id] ?? DayEntry()
        let autoOpening = previousClosing(itemID: item.id, before: date)
        let opening = entry.opening ?? autoOpening ?? 0
        let incoming = entry.incoming ?? 0
        let tin = entry.transferIn ?? 0
        let tout = entry.transferOut ?? 0
        let useLegacy = day?.usesLegacySales ?? false
        let sold = useLegacy ? (day?.legacySold?[item.id] ?? 0) : (analysis.sold[item.id] ?? 0)
        let waste = useLegacy ? (day?.legacyWaste?[item.id] ?? 0) : (analysis.waste[item.id] ?? 0)
        var actual: Double?
        var diff: Double?
        if let closing = entry.closing {
            // Fiili Tüketim = Açılış + Gelen + Gelen Transfer - (Giden Transfer + Kapanış)
            let a = opening + incoming + tin - (tout + closing)
            actual = Self.clean(a)
            // Fark = (Satılan + Zayi) - Fiili Tüketim   (negatif: beklenenden fazla stok çıkışı)
            diff = Self.clean(sold + waste - a)
        }
        return ItemCalc(itemID: item.id, opening: opening, openingIsAuto: entry.opening == nil,
                        incoming: incoming, transferIn: tin, transferOut: tout, closing: entry.closing,
                        sold: Self.clean(sold), waste: Self.clean(waste), actual: actual, diff: diff)
    }

    /// Kayan nokta artıklarını temizler (10.864000000000001 -> 10.864).
    static func clean(_ v: Double) -> Double {
        let r = (v * 1_000_000).rounded() / 1_000_000
        return r == 0 ? 0 : r
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
        public var daily: [(date: String, diff: Double)]
    }

    /// from...to (dahil) arasındaki günlerin toplamı. Yalnızca kapanışı sayılmış günler hesaba katılır;
    /// böylece Fark = Satılan + Zayi - Fiili özdeşliği dönem toplamında da korunur.
    public func summary(from: String, to: String) -> [SummaryRow] {
        let dates = sortedDates.filter { $0 >= from && $0 <= to }
        var rows: [SummaryRow] = []
        var perDay: [(String, [ItemCalc])] = []
        for d in dates { perDay.append((d, calc(date: d).rows)) }
        for item in data.items where item.active {
            var r = SummaryRow(item: item, daysCounted: 0, firstOpening: nil, lastClosing: nil,
                               incoming: 0, transferIn: 0, transferOut: 0, sold: 0, waste: 0,
                               actual: 0, diff: 0, daily: [])
            for (d, calcs) in perDay {
                guard let c = calcs.first(where: { $0.itemID == item.id }), c.isCounted,
                      let actual = c.actual, let diff = c.diff else { continue }
                r.daysCounted += 1
                if r.firstOpening == nil { r.firstOpening = c.opening }
                r.lastClosing = c.closing
                r.incoming += c.incoming; r.transferIn += c.transferIn; r.transferOut += c.transferOut
                r.sold += c.sold; r.waste += c.waste; r.actual += actual; r.diff += diff
                r.daily.append((d, diff))
            }
            r.incoming = Self.clean(r.incoming); r.transferIn = Self.clean(r.transferIn)
            r.transferOut = Self.clean(r.transferOut); r.sold = Self.clean(r.sold)
            r.waste = Self.clean(r.waste); r.actual = Self.clean(r.actual); r.diff = Self.clean(r.diff)
            rows.append(r)
        }
        return rows
    }

    public var datesWithData: [String] { sortedDates.filter { !(data.days[$0]?.isEmpty ?? true) } }
}
