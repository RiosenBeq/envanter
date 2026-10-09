import Foundation

/// Excel'e aktarım. "Alımlar" sayfasıyla aynı sütun düzenini kullanır; böylece eski pivot tablolar çalışmaya devam eder.
public enum Exporter {
    public static let inventoryHeader = [
        "Tarih", "Ürün", "Açılış", "Gelen", "Gelen Transfer (+)", "Giden Transfer (-)",
        "Kapanış", "Satılan", "Zaiyat", "Fiili Tüketim", "Fark",
    ]
    public static let inventoryWidths: [Double] = [12, 28, 11, 11, 14, 14, 11, 11, 11, 13, 11]

    public static func label(_ item: Item) -> String { "\(item.name) / \(item.unit)" }

    public static func inventoryRows(engine: Engine, dates: [String]) -> [[XlsxCell]] {
        var rows: [[XlsxCell]] = []
        for date in dates {
            let serial = DateKey.excelSerial(date)
            let (calcs, _) = engine.calc(date: date)
            for c in calcs {
                guard let item = engine.itemsByID[c.itemID] else { continue }
                rows.append([
                    serial.map { XlsxCell.date(serial: $0) } ?? .text(date),
                    .text(label(item)),
                    .number(c.opening), .number(c.incoming), .number(c.transferIn), .number(c.transferOut),
                    .optNumber(c.closing), .number(c.sold), .number(c.waste),
                    .optNumber(c.actual), .diff(c.diff),
                ])
            }
        }
        return rows
    }

    /// Seçili günün envanteri + satış dökümü (iki sayfa)
    public static func day(engine: Engine, date: String) -> Data {
        let inv = XlsxSheetData(name: "Envanter", header: inventoryHeader,
                                rows: inventoryRows(engine: engine, dates: [date]), widths: inventoryWidths)
        return XlsxWriter.build(sheets: [inv, salesSheet(engine: engine, date: date)])
    }

    /// Verisi olan tüm günler (Alımlar formatı) + özet
    public static func history(engine: Engine, from: String, to: String) -> Data {
        let dates = engine.datesWithData.filter { $0 >= from && $0 <= to }
        let alim = XlsxSheetData(name: "Alımlar", header: inventoryHeader,
                                 rows: inventoryRows(engine: engine, dates: dates), widths: inventoryWidths)
        return XlsxWriter.build(sheets: [alim, summarySheet(engine: engine, from: from, to: to)])
    }

    public static func salesSheet(engine: Engine, date: String) -> XlsxSheetData {
        let sales = engine.data.days[date]?.sales ?? []
        let analysis = engine.analyze(sales: sales)
        let rows: [[XlsxCell]] = sales.map { l in
            let status: String
            switch analysis.status[l.code] ?? .unknown {
            case .tracked: status = "Reçeteli"
            case .untracked: status = "Stok etkisi yok"
            case .unknown: status = "Reçete tanımsız"
            }
            return [.text(l.code), .text(l.name), .number(l.qty), .text(status)]
        }
        return XlsxSheetData(name: "Satışlar", header: ["Kodu", "Ürün", "Adedi", "Durum"], rows: rows, widths: [10, 40, 10, 18])
    }

    public static func summarySheet(engine: Engine, from: String, to: String) -> XlsxSheetData {
        let rows: [[XlsxCell]] = engine.summary(from: from, to: to).map { r in
            [.text(label(r.item)), .number(Double(r.daysCounted)), .optNumber(r.firstOpening),
             .number(r.incoming), .number(r.transferIn), .number(r.transferOut),
             .optNumber(r.lastClosing), .number(r.sold), .number(r.waste), .number(r.actual), .diff(r.diff)]
        }
        return XlsxSheetData(
            name: "Özet",
            header: ["Ürün (\(DateKey.short(from)) – \(DateKey.short(to)))", "Sayılan Gün", "İlk Açılış", "Toplam Gelen",
                     "Gelen Transfer (+)", "Giden Transfer (-)", "Son Kapanış", "Toplam Satılan", "Toplam Zaiyat",
                     "Toplam Fiili Tüketim", "Toplam Fark"],
            rows: rows, widths: [32, 12, 11, 13, 14, 14, 11, 13, 13, 16, 13])
    }
}
