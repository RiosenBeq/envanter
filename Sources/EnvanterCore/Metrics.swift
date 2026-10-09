import Foundation

/// Hesap motorunun sonuçlarını JSON olarak verir: web panelindeki TypeScript motorunun eşlik testi için
/// (bkz. docs/SYNC.md §4). Alan adları web tarafındaki karşılıklarıyla aynıdır.
public enum Metrics {
    public static func json(engine e: Engine, date: String, from: String, to: String) -> Data {
        func n(_ v: Double?) -> Any { v.map { Engine.clean($0) as Any } ?? NSNull() }
        func s(_ v: String?) -> Any { v ?? NSNull() }
        func sev(_ v: DiffSeverity?) -> Any {
            guard let v else { return NSNull() }
            switch v {
            case .zero: return "zero"
            case .withinTolerance: return "withinTolerance"
            case .shortage: return "shortage"
            case .surplus: return "surplus"
            }
        }

        let calc = e.calc(date: date).rows.map { r -> [String: Any] in
            ["itemID": r.itemID, "opening": n(r.opening), "openingIsAuto": r.openingIsAuto, "incoming": n(r.incoming),
             "transferIn": n(r.transferIn), "transferOut": n(r.transferOut), "closing": n(r.closing),
             "sold": n(r.sold), "waste": n(r.waste), "actual": n(r.actual), "diff": n(r.diff),
             "diffValue": n(r.diffValue), "severity": sev(r.severity), "belowMinimum": r.belowMinimum]
        }
        let o = e.overview(date: date)
        let overview: [String: Any] = [
            "itemCount": o.itemCount, "countedItems": o.countedItems, "hasSales": o.hasSales, "salesLines": o.salesLines,
            "unknownLines": o.unknownLines, "problemItems": o.problemItems, "shortageItems": o.shortageItems,
            "belowMinimumItems": o.belowMinimumItems, "lossValue": n(o.lossValue), "netValue": n(o.netValue),
            "revenue": n(o.revenue), "hasSignificantLoss": o.hasSignificantLoss, "hasNotableLoss": o.hasNotableLoss]
        let summary = e.summary(from: from, to: to).map { r -> [String: Any] in
            ["itemID": r.item.id, "daysCounted": r.daysCounted, "firstOpening": n(r.firstOpening), "lastClosing": n(r.lastClosing),
             "incoming": n(r.incoming), "sold": n(r.sold), "waste": n(r.waste), "actual": n(r.actual), "diff": n(r.diff),
             "diffValue": n(r.diffValue), "shortageValue": n(r.shortageValue), "shortageQty": n(r.shortageQty),
             "shortageDays": r.shortageDays]
        }
        let p = e.periodStats(from: from, to: to)
        let period: [String: Any] = [
            "days": p.days.count, "revenue": n(p.revenue), "revenueDays": p.revenueDays,
            "theoreticalCost": n(p.theoreticalCost), "actualCost": n(p.actualCost), "wasteCost": n(p.wasteCost),
            "lossValue": n(p.lossValue), "netValue": n(p.netValue), "incomingValue": n(p.incomingValue),
            "laborCost": n(p.laborCost), "hasLabor": p.hasLabor, "primeCost": n(p.primeCost),
            "theoreticalCostPct": n(p.theoreticalCostPct), "actualCostPct": n(p.actualCostPct),
            "wastePct": n(p.wastePct), "laborPct": n(p.laborPct), "primeCostPct": n(p.primeCostPct),
            "countedDays": p.countedDays, "salesDays": p.salesDays]
        let daily = p.days.map { d -> [String: Any] in
            ["date": d.date, "revenue": n(d.revenue), "hasRevenue": d.hasRevenue, "theoreticalCost": n(d.theoreticalCost),
             "actualCost": n(d.actualCost), "wasteCost": n(d.wasteCost), "lossValue": n(d.lossValue),
             "netValue": n(d.netValue), "laborCost": n(d.laborCost), "countedItems": d.countedItems, "problemItems": d.problemItems]
        }
        let ld = e.labor(date: date)
        let labor: [String: Any] = [
            "total": n(ld.total), "other": n(ld.other), "hours": n(ld.hours), "headcount": ld.headcount,
            "lines": ld.lines.map { ["employeeID": $0.employee.id, "cost": n($0.cost), "hours": n($0.hours), "worked": $0.worked] }]
        let ls = e.laborSummary(from: from, to: to)
        let laborSummary: [String: Any] = [
            "total": n(ls.total), "other": n(ls.other), "hours": n(ls.hours),
            "rows": ls.rows.map { ["employeeID": $0.employee.id, "days": $0.days, "hours": n($0.hours), "cost": n($0.cost)] }]
        let st = e.data.settings
        let orders = e.orderSuggestions(asOf: date, lookbackDays: st.orderLookbackDays, coverDays: st.orderCoverDays).map { x -> [String: Any] in
            ["itemID": x.item.id, "stock": n(x.stock), "countedStock": n(x.countedStock), "stockDate": s(x.stockDate),
             "onOrder": n(x.onOrder), "dailyUsage": n(x.dailyUsage), "sampleDays": x.sampleDays, "daysOfCover": n(x.daysOfCover),
             "target": n(x.target), "suggested": n(x.suggested), "cost": n(x.cost)]
        }
        let alerts = e.priceAlerts(asOf: date, threshold: st.priceAlertPct).map { a -> [String: Any] in
            ["itemID": a.item.id, "from": n(a.from), "to": n(a.to), "ratio": n(a.ratio), "date": a.date]
        }
        let sv = e.stockValue(asOf: date)
        let trend = e.trend(endingAt: date, days: 14).map { t -> [String: Any] in
            ["date": t.date, "countedItems": t.countedItems, "problemItems": t.problemItems, "lossValue": n(t.lossValue)]
        }
        let root: [String: Any] = [
            "date": date, "from": from, "to": to,
            "calc": calc, "overview": overview, "summary": summary, "period": period, "daily": daily,
            "labor": labor, "laborSummary": laborSummary, "orders": orders, "priceAlerts": alerts,
            "stockValue": ["value": n(sv.value), "costedItems": sv.costedItems, "countedItems": sv.countedItems],
            "trend": trend]
        return (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }
}
