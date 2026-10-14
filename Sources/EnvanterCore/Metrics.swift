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
             "severity": sev(r.severity), "belowMinimum": r.belowMinimum,
             "openingSource": r.openingSource.rawValue, "openingBaseDate": s(r.openingBaseDate), "carriedNet": n(r.carriedNet),
             "carriedDays": r.carriedDays, "isBaseline": r.isBaseline, "openingJump": n(r.openingJump)]
        }
        let o = e.overview(date: date)
        let overview: [String: Any] = [
            "itemCount": o.itemCount, "countedItems": o.countedItems, "hasSales": o.hasSales, "salesLines": o.salesLines,
            "unknownLines": o.unknownLines, "problemItems": o.problemItems, "shortageItems": o.shortageItems,
            "belowMinimumItems": o.belowMinimumItems, "isLocked": o.isLocked, "isFullyCounted": o.isFullyCounted,
            "hasNotableProblems": o.hasNotableProblems, "hasSignificantProblems": o.hasSignificantProblems]
        let summary = e.summary(from: from, to: to).map { r -> [String: Any] in
            ["itemID": r.item.id, "daysCounted": r.daysCounted, "firstOpening": n(r.firstOpening), "lastClosing": n(r.lastClosing),
             "incoming": n(r.incoming), "transferIn": n(r.transferIn), "transferOut": n(r.transferOut),
             "sold": n(r.sold), "waste": n(r.waste), "actual": n(r.actual), "diff": n(r.diff),
             "shortageQty": n(r.shortageQty), "shortageDays": r.shortageDays, "openingAdjust": n(r.openingAdjust)]
        }
        let p = e.periodStats(from: from, to: to)
        let period: [String: Any] = ["days": p.days.count, "countedDays": p.countedDays, "salesDays": p.salesDays]
        let daily = p.days.map { d -> [String: Any] in
            ["date": d.date, "countedItems": d.countedItems, "problemItems": d.problemItems, "shortageItems": d.shortageItems,
             "belowMinimumItems": d.belowMinimumItems, "hasSales": d.hasSales, "isLocked": d.isLocked]
        }
        let st = e.data.settings
        let orders = e.orderSuggestions(asOf: date, lookbackDays: st.orderLookbackDays, coverDays: st.orderCoverDays).map { x -> [String: Any] in
            ["itemID": x.item.id, "stock": n(x.stock), "countedStock": n(x.countedStock), "stockDate": s(x.stockDate),
             "onOrder": n(x.onOrder), "dailyUsage": n(x.dailyUsage), "sampleDays": x.sampleDays, "daysOfCover": n(x.daysOfCover),
             "target": n(x.target), "suggested": n(x.suggested)]
        }
        let trend = e.trend(endingAt: date, days: 14).map { t -> [String: Any] in
            ["date": t.date, "countedItems": t.countedItems, "problemItems": t.problemItems, "shortageItems": t.shortageItems]
        }
        let estimates = e.stockEstimates(date: date).map { x -> [String: Any] in
            ["itemID": x.itemID, "stock": n(x.stock), "baseDate": x.baseDate, "counted": x.counted, "below": x.below]
        }
        let thresholds = e.thresholdSuggestions(asOf: date).map { x -> [String: Any] in
            ["itemID": x.itemID, "tolerance": n(x.tolerance), "countedDays": x.countedDays, "minStock": n(x.minStock),
             "dailyUsage": n(x.dailyUsage), "usageDays": x.usageDays]
        }
        let root: [String: Any] = [
            "date": date, "from": from, "to": to,
            "calc": calc, "overview": overview, "summary": summary, "period": period, "daily": daily,
            "orders": orders, "trend": trend, "estimates": estimates, "thresholds": thresholds]
        return (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }
}
