import Foundation

// İstatistikler: maliyet / food cost %, kalem serileri, ABC (Pareto) analizi, menü mühendisliği, stok değeri.
// Restoran stok yazılımlarındaki (teorik vs. fiili kullanım) yaklaşımı izler:
//   teorik maliyet = reçeteye göre olması gereken tüketim (satılan + zayi) × birim maliyet
//   fiili maliyet  = teorik maliyet − sayılan kalemlerdeki net farkın tutarı
//                    (sayılmayan kalemlerin reçeteye uygun tüketildiği varsayılır)

/// Bir günün parasal özeti
public struct DailyStat: Identifiable {
    public var id: String { date }
    public var date: String
    /// Satış tutarı (raporda tutar sütunu yoksa 0)
    public var revenue: Double
    public var hasRevenue: Bool
    public var theoreticalCost: Double
    public var actualCost: Double
    public var wasteCost: Double
    /// Fazla çıkışların tutarı (pozitif)
    public var lossValue: Double
    /// Net fark tutarı (negatif: kayıp)
    public var netValue: Double
    public var countedItems: Int
    public var problemItems: Int
    public var salesQty: Double
    /// Günün personel maliyeti (₺)
    public var laborCost: Double = 0
    /// Prime cost = fiili hammadde maliyeti + personel maliyeti
    public var primeCost: Double { actualCost + laborCost }
}

/// Dönem toplamları
public struct PeriodStats {
    public var from: String
    public var to: String
    public var days: [DailyStat]
    public var revenue: Double
    /// Tutar bilgisi olan gün sayısı
    public var revenueDays: Int
    public var theoreticalCost: Double
    public var actualCost: Double
    public var wasteCost: Double
    public var lossValue: Double
    public var netValue: Double
    /// Gelen (alım) miktarlarının tutarı
    public var incomingValue: Double
    public var countedDays: Int
    public var salesDays: Int
    /// Maliyeti tanımlı aktif kalem sayısı / toplam aktif kalem
    public var costedItems: Int
    public var totalItems: Int
    /// Verisi olan günlerin personel maliyeti
    public var laborCost: Double = 0
    public var hasLabor: Bool = false
    /// Oranlar yalnızca satış tutarı bilinen günler üzerinden hesaplanır (pay ve payda aynı günler)
    var revenueDayTheoretical = 0.0, revenueDayActual = 0.0, revenueDayWaste = 0.0, revenueDayLabor = 0.0

    public var primeCost: Double { actualCost + laborCost }
    public var theoreticalCostPct: Double? { revenue > 0 ? revenueDayTheoretical / revenue : nil }
    public var actualCostPct: Double? { revenue > 0 ? revenueDayActual / revenue : nil }
    public var wastePct: Double? { revenue > 0 ? revenueDayWaste / revenue : nil }
    public var laborPct: Double? { revenue > 0 && hasLabor ? revenueDayLabor / revenue : nil }
    public var primeCostPct: Double? { revenue > 0 && hasLabor ? (revenueDayActual + revenueDayLabor) / revenue : nil }
    public var hasCosts: Bool { costedItems > 0 }
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

/// ABC (Pareto) sınıfı: A = tüketim değerinin ilk %80'i, B = sonraki %15, C = kalan %5
public enum ABCClass: String {
    case a = "A", b = "B", c = "C"
}

public struct ABCRow: Identifiable {
    public var id: String { item.id }
    public var item: Item
    /// Dönemdeki tüketim (sayılan günlerde fiili, diğerlerinde reçeteye göre)
    public var quantity: Double
    public var value: Double
    public var share: Double
    public var cumulativeShare: Double
    public var klass: ABCClass
}

/// Menü mühendisliği sınıfları (Kasavana & Smith)
public enum MenuClass: String, CaseIterable {
    /// Popüler ve kârlı
    case star = "Yıldız"
    /// Popüler ama kârı düşük
    case plowhorse = "Beygir"
    /// Kârlı ama az satıyor
    case puzzle = "Bilmece"
    /// Ne popüler ne kârlı
    case dog = "Zayıf"

    public var advice: String {
        switch self {
        case .star: return "Korunmalı; görünür yerde tutun, kaliteyi sabit tutun."
        case .plowhorse: return "Porsiyon/maliyeti gözden geçirin ya da fiyatı kademeli artırın."
        case .puzzle: return "Tanıtımı artırın, menüde öne çıkarın, adını/sunumunu gözden geçirin."
        case .dog: return "Menüden çıkarmayı veya yeniden tasarlamayı düşünün."
        }
    }
}

public struct MenuItemStat: Identifiable {
    public var id: String { product.code }
    public var product: Product
    public var qty: Double
    public var revenue: Double
    /// Ortalama satış fiyatı (tutar / adet)
    public var unitPrice: Double
    /// Reçete maliyeti (tüm hammaddelerin maliyeti tanımlıysa)
    public var unitCost: Double?
    public var unitMargin: Double? { unitCost.map { unitPrice - $0 } }
    public var totalMargin: Double? { unitMargin.map { $0 * qty } }
    public var foodCostPct: Double? { unitCost.flatMap { unitPrice > 0 ? $0 / unitPrice : nil } }
    /// Toplam satış adedi içindeki pay
    public var popularity: Double
    public var klass: MenuClass?
}

public struct RecipeCost {
    /// Maliyeti bilinen hammaddelerin toplamı (₺ / 1 adet)
    public var cost: Double
    /// Tüm hammaddelerin maliyeti tanımlı mı
    public var isComplete: Bool
    /// Maliyeti eksik hammaddeler
    public var missing: [String]
}

extension Engine {
    // MARK: Reçete maliyeti

    public func recipeCost(_ product: Product) -> RecipeCost {
        var cost = 0.0
        var missing: [String] = []
        for (itemID, perUnit) in product.amounts.sorted(by: { $0.key < $1.key }) where perUnit != 0 {
            guard let item = itemsByID[itemID] else { continue }
            if let c = item.unitCost { cost += perUnit * item.factor * c } else { missing.append(item.name) }
        }
        return RecipeCost(cost: Self.clean(cost), isComplete: missing.isEmpty, missing: missing)
    }

    /// Ürünün en son satış raporundaki ortalama fiyatı
    public func lastUnitPrice(code: String) -> (price: Double, date: String)? {
        for d in datesWithData.reversed() {
            if let l = data.days[d]?.sales.first(where: { $0.code == code }), let a = l.amount, l.qty > 0 {
                return (Self.clean(a / l.qty), d)
            }
        }
        return nil
    }

    // MARK: Dönem istatistikleri

    public func dailyStat(date: String) -> DailyStat {
        let day = data.days[date]
        let (rows, _) = calc(date: date)
        var s = DailyStat(date: date, revenue: day?.salesRevenue ?? 0, hasRevenue: day?.salesRevenue != nil,
                          theoreticalCost: 0, actualCost: 0, wasteCost: 0, lossValue: 0, netValue: 0,
                          countedItems: 0, problemItems: 0, salesQty: day?.sales.reduce(0) { $0 + $1.qty } ?? 0)
        for r in rows {
            if r.isCounted { s.countedItems += 1 }
            if r.severity?.isProblem == true { s.problemItems += 1 }
            // Geçmiş günler o günkü fiyatla değerlenir (sonradan gelen zam kapanmış ayları değiştirmez)
            guard let cost = itemsByID[r.itemID]?.cost(on: date) else { continue }
            s.theoreticalCost += (r.sold + r.waste) * cost
            s.wasteCost += r.waste * cost
            if let v = r.diffValue {
                s.netValue += v
                if r.severity == .shortage { s.lossValue -= v }
            }
        }
        s.actualCost = s.theoreticalCost - s.netValue
        s.laborCost = labor(date: date).total
        s.theoreticalCost = Self.clean(s.theoreticalCost); s.actualCost = Self.clean(s.actualCost)
        s.wasteCost = Self.clean(s.wasteCost); s.lossValue = Self.clean(s.lossValue); s.netValue = Self.clean(s.netValue)
        return s
    }

    /// Dönemin personel maliyetinin hesaplandığı takvim aralığı: `from`'dan dönemdeki son kayıtlı güne kadar
    /// (henüz girilmemiş gelecek günlerin maaşı sayılmaz). Kayıtlı gün yoksa nil.
    public func laborRange(from: String, to: String) -> (from: String, to: String, days: Int)? {
        guard let last = datesWithData.last(where: { $0 >= from && $0 <= to }),
              let n = DateKey.distance(from: from, to: last), n >= 0 else { return nil }
        return (from, last, min(n, 3660))
    }

    /// from...to (dahil) arasındaki verisi olan günlerin istatistikleri
    public func periodStats(from: String, to: String) -> PeriodStats {
        let dates = datesWithData.filter { $0 >= from && $0 <= to }
        let days = dates.map { dailyStat(date: $0) }
        var incomingValue = 0.0
        for d in dates {
            for (id, e) in data.days[d]?.entries ?? [:] {
                if let inc = e.incoming, let c = itemsByID[id]?.cost(on: d), itemsByID[id]?.active == true { incomingValue += inc * c }
            }
        }
        let active = activeItems
        var p = PeriodStats(
            from: from, to: to, days: days,
            revenue: Self.clean(days.reduce(0) { $0 + $1.revenue }),
            revenueDays: days.filter { $0.hasRevenue }.count,
            theoreticalCost: Self.clean(days.reduce(0) { $0 + $1.theoreticalCost }),
            actualCost: Self.clean(days.reduce(0) { $0 + $1.actualCost }),
            wasteCost: Self.clean(days.reduce(0) { $0 + $1.wasteCost }),
            lossValue: Self.clean(days.reduce(0) { $0 + $1.lossValue }),
            netValue: Self.clean(days.reduce(0) { $0 + $1.netValue }),
            incomingValue: Self.clean(incomingValue),
            countedDays: days.filter { $0.countedItems > 0 }.count,
            salesDays: dates.filter { data.days[$0]?.hasSalesData ?? false }.count,
            costedItems: active.filter { $0.unitCost != nil }.count,
            totalItems: active.count)
        // Kaydı hiç olmayan günler (kapalı gün, bayram) satışsız geçmiştir ama aylık maaş yine işler:
        // bu günlerin personel maliyeti de dönem maliyetine ve personel oranına girer (Personel ekranıyla aynı toplam).
        var closedDayLabor = 0.0
        if let range = laborRange(from: from, to: to) {
            let recorded = Set(dates)
            for i in 0...range.days {
                let d = DateKey.addDays(i, to: range.from)
                if !recorded.contains(d) { closedDayLabor += labor(date: d).total }
            }
        }
        p.laborCost = Self.clean(days.reduce(0) { $0 + $1.laborCost } + closedDayLabor)
        // Personel kaydı yoksa oran %0 değil "kayıt yok" gösterilir
        p.hasLabor = p.laborCost > 0
        for d in days where d.hasRevenue && d.revenue > 0 {
            p.revenueDayTheoretical += d.theoreticalCost; p.revenueDayActual += d.actualCost
            p.revenueDayWaste += d.wasteCost; p.revenueDayLabor += d.laborCost
        }
        p.revenueDayLabor += closedDayLabor
        return p
    }

    // MARK: Kalem serisi

    public func itemSeries(itemID: String, from: String, to: String) -> [ItemDayPoint] {
        datesWithData.filter { $0 >= from && $0 <= to }.compactMap { d in
            guard let r = calc(date: d).rows.first(where: { $0.itemID == itemID }), r.hasActivity else { return nil }
            return ItemDayPoint(date: d, expected: Self.clean(r.sold + r.waste), actual: r.actual, diff: r.diff,
                                closing: r.closing, incoming: r.incoming, waste: r.waste)
        }
    }

    // MARK: ABC analizi

    public func abcAnalysis(from: String, to: String) -> [ABCRow] {
        let dates = datesWithData.filter { $0 >= from && $0 <= to }
        var qty: [String: Double] = [:]
        for d in dates {
            for r in calc(date: d).rows {
                qty[r.itemID, default: 0] += r.actual.map { max($0, 0) } ?? (r.sold + r.waste)
            }
        }
        let valued = activeItems.compactMap { item -> (Item, Double, Double)? in
            guard let c = item.unitCost, let q = qty[item.id], q > 0 else { return nil }
            return (item, q, q * c)
        }.sorted { $0.2 > $1.2 }
        let total = valued.reduce(0) { $0 + $1.2 }
        guard total > 0 else { return [] }
        var cumulative = 0.0
        return valued.map { item, q, v in
            let before = cumulative
            cumulative += v / total
            let klass: ABCClass = before < 0.8 ? .a : (before < 0.95 ? .b : .c)
            return ABCRow(item: item, quantity: Self.clean(q), value: Self.clean(v), share: v / total,
                          cumulativeShare: min(cumulative, 1), klass: klass)
        }
    }

    // MARK: Menü mühendisliği

    /// Reçeteli (stok düşen) ve tutarı bilinen ürünler için popülerlik × kârlılık sınıflandırması.
    public func menuEngineering(from: String, to: String) -> [MenuItemStat] {
        var qty: [String: Double] = [:]
        var revenue: [String: Double] = [:]
        var order: [String] = []
        for d in datesWithData where d >= from && d <= to {
            for l in data.days[d]?.sales ?? [] {
                guard let p = productsByCode[l.code], p.isTracked, !p.isWaste, let a = l.amount, l.qty > 0 else { continue }
                if qty[l.code] == nil { order.append(l.code) }
                qty[l.code, default: 0] += l.qty
                revenue[l.code, default: 0] += a
            }
        }
        let totalQty = qty.values.reduce(0, +)
        guard totalQty > 0 else { return [] }
        var stats: [MenuItemStat] = order.compactMap { code in
            guard let p = productsByCode[code], let q = qty[code], let r = revenue[code] else { return nil }
            let rc = recipeCost(p)
            return MenuItemStat(product: p, qty: Self.clean(q), revenue: Self.clean(r), unitPrice: Self.clean(r / q),
                                unitCost: rc.isComplete ? rc.cost : nil, popularity: q / totalQty, klass: nil)
        }
        // Eşikler: popülerlik için beklenen payın %70'i, kârlılık için ağırlıklı ortalama birim kâr
        let threshold = 0.7 / Double(stats.count)
        let costed = stats.filter { $0.unitCost != nil }
        let costedQty = costed.reduce(0) { $0 + $1.qty }
        let avgMargin = costedQty > 0 ? costed.reduce(0) { $0 + ($1.totalMargin ?? 0) } / costedQty : 0
        for i in stats.indices {
            guard let m = stats[i].unitMargin else { continue }
            let popular = stats[i].popularity >= threshold
            let profitable = m >= avgMargin
            stats[i].klass = popular ? (profitable ? .star : .plowhorse) : (profitable ? .puzzle : .dog)
        }
        return stats.sorted { $0.revenue > $1.revenue }
    }

    // MARK: Stok değeri

    /// `date` itibarıyla son sayılan stokların maliyet değeri
    public func stockValue(asOf date: String) -> (value: Double, costedItems: Int, countedItems: Int) {
        let tomorrow = DateKey.addDays(1, to: date)
        var value = 0.0, costed = 0, counted = 0
        for item in activeItems {
            guard let c = lastClosing(itemID: item.id, before: tomorrow) else { continue }
            counted += 1
            if let cost = item.cost(on: date) { value += c.value * cost; costed += 1 }
        }
        return (Self.clean(value), costed, counted)
    }
}
