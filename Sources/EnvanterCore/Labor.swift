import Foundation

// Personel maliyeti ve prime cost.
//   Aylık maaş   : maaş × işveren çarpanı ÷ ayın gün sayısı (işte kayıtlı olduğu her güne)
//   Günlük yevmiye: yevmiye × çarpan (çalıştı işaretli ya da saat girilmiş günlerde)
//   Saatlik ücret: saat × ücret × çarpan
//   Ek ödeme (mesai, prim): tutar × çarpan; ayrıca güne "diğer personel gideri" eklenebilir.
//   Prime cost = hammadde maliyeti (fiili) + personel maliyeti — restoranlarda en önemli maliyet göstergesi.

public struct LaborLine: Identifiable {
    public var id: String { employee.id }
    public var employee: Employee
    public var hours: Double
    public var cost: Double
    /// O gün çalıştı mı (aylık maaşlılarda saat girilmese de maaş payı yazılır)
    public var worked: Bool
}

public struct LaborDay {
    public var date: String
    public var lines: [LaborLine]
    /// Kayıtlı personel dışındaki gider
    public var other: Double
    public var total: Double
    public var hours: Double
    public var headcount: Int
}

/// Dönem personel özeti (kişi bazında)
public struct LaborSummaryRow: Identifiable {
    public var id: String { employee.id }
    public var employee: Employee
    public var days: Int
    public var hours: Double
    public var cost: Double
}

extension Engine {
    /// Bir personelin bir günlük maliyeti
    public func laborCost(of e: Employee, on date: String, shift: ShiftEntry?) -> (cost: Double, hours: Double, worked: Bool) {
        guard e.isEmployed(on: date) else { return (0, 0, false) }
        let factor = max(e.costFactor, 0)
        let hours = max(shift?.hours ?? 0, 0)
        let extra = max(shift?.extra ?? 0, 0) * factor
        switch e.payType {
        case .monthly:
            guard let v = DateKey.ymd(date) else { return (0, 0, false) }
            let daily = max(e.rate, 0) * factor / Double(DateKey.daysInMonth(v.y, v.m))
            return (Self.clean(daily + extra), hours, true)
        case .daily:
            let worked = shift?.worked == true || hours > 0
            return (Self.clean((worked ? max(e.rate, 0) * factor : 0) + extra), hours, worked)
        case .hourly:
            return (Self.clean(hours * max(e.rate, 0) * factor + extra), hours, hours > 0)
        }
    }

    public func labor(date: String) -> LaborDay {
        let day = data.days[date]
        var lines: [LaborLine] = []
        for e in data.employees {
            let shift = day?.shifts?[e.id]
            let r = laborCost(of: e, on: date, shift: shift)
            if r.cost > 0 || r.worked { lines.append(LaborLine(employee: e, hours: r.hours, cost: r.cost, worked: r.worked)) }
        }
        let other = max(day?.otherLabor ?? 0, 0)
        let total = lines.reduce(0) { $0 + $1.cost } + other
        return LaborDay(date: date, lines: lines, other: Self.clean(other), total: Self.clean(total),
                        hours: Self.clean(lines.reduce(0) { $0 + $1.hours }),
                        headcount: lines.filter { $0.worked && ($0.employee.payType != .monthly || $0.hours > 0) }.count)
    }

    /// Dönemdeki her gün (verisi olsun olmasın) için personel maliyeti; aylık maaşlar takvim günlerine dağılır.
    public func laborSummary(from: String, to: String) -> (rows: [LaborSummaryRow], other: Double, total: Double, hours: Double) {
        guard let n = DateKey.distance(from: from, to: to), n >= 0 else { return ([], 0, 0, 0) }
        var rows: [String: LaborSummaryRow] = [:]
        var other = 0.0
        for i in 0...min(n, 3660) {
            let d = DateKey.addDays(i, to: from)
            let ld = labor(date: d)
            other += ld.other
            for l in ld.lines {
                var r = rows[l.employee.id] ?? LaborSummaryRow(employee: l.employee, days: 0, hours: 0, cost: 0)
                if l.worked && (l.employee.payType != .monthly || l.hours > 0) { r.days += 1 }
                r.hours += l.hours; r.cost += l.cost
                rows[l.employee.id] = r
            }
        }
        let list = data.employees.compactMap { rows[$0.id] }.map { r -> LaborSummaryRow in
            var x = r; x.cost = Self.clean(x.cost); x.hours = Self.clean(x.hours); return x
        }
        let total = list.reduce(0) { $0 + $1.cost } + other
        return (list, Self.clean(other), Self.clean(total), Self.clean(list.reduce(0) { $0 + $1.hours }))
    }

    // MARK: - Fiyat uyarıları

    /// Son `days` gün içinde birim maliyeti `threshold` oranından fazla artan kalemler
    public func priceAlerts(asOf date: String, days: Int = 30, threshold: Double) -> [(item: Item, from: Double, to: Double, ratio: Double, date: String)] {
        let since = DateKey.addDays(-days, to: date)
        return activeItems.compactMap { item in
            guard let c = item.lastPriceChange, let d = c.date, d >= since, d <= date, c.ratio >= threshold else { return nil }
            return (item, c.from, c.to, c.ratio, d)
        }.sorted { $0.ratio > $1.ratio }
    }

    /// Bir kalemi kullanan reçeteli ürün sayısı (fiyat değişiminin etkisi için)
    public func productsUsing(itemID: String) -> Int {
        data.products.filter { ($0.amounts[itemID] ?? 0) != 0 }.count
    }
}
