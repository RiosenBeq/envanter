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

    /// Verisi olan tüm günler (Alımlar formatı) + özet + günlük maliyet + (varsa) gün notları
    public static func history(engine: Engine, from: String, to: String) -> Data {
        let dates = engine.datesWithData.filter { $0 >= from && $0 <= to }
        let alim = XlsxSheetData(name: "Alımlar", header: inventoryHeader,
                                 rows: inventoryRows(engine: engine, dates: dates), widths: inventoryWidths)
        var sheets = [alim, summarySheet(engine: engine, from: from, to: to), dailyStatsSheet(engine: engine, from: from, to: to)]
        let notes: [[XlsxCell]] = dates.compactMap { d in
            guard let day = engine.data.days[d], !(day.note ?? "").isEmpty || !(day.countedBy ?? "").isEmpty || day.isLocked else { return nil }
            return [DateKey.excelSerial(d).map { XlsxCell.date(serial: $0) } ?? .text(d), .text(day.countedBy ?? ""),
                    .text(day.isLocked ? "Kapatıldı" : ""), .text(day.note ?? "")]
        }
        if !notes.isEmpty {
            sheets.append(XlsxSheetData(name: "Notlar", header: ["Tarih", "Sayımı Yapan", "Durum", "Not"], rows: notes, widths: [12, 20, 12, 60]))
        }
        return XlsxWriter.build(sheets: sheets)
    }

    /// Günlük ciro, teorik/fiili maliyet ve kayıp
    public static func dailyStatsSheet(engine: Engine, from: String, to: String) -> XlsxSheetData {
        let stats = engine.periodStats(from: from, to: to)
        let rows: [[XlsxCell]] = stats.days.map { s in
            [DateKey.excelSerial(s.date).map { XlsxCell.date(serial: $0) } ?? .text(s.date),
             s.hasRevenue ? .number(s.revenue) : XlsxCell(.blank), .number(s.theoreticalCost), .number(s.actualCost),
             .number(s.wasteCost), .number(s.lossValue), .diff(s.netValue),
             s.revenue > 0 ? .number((s.actualCost / s.revenue * 1000).rounded() / 10) : XlsxCell(.blank),
             .number(Double(s.countedItems)), .number(Double(s.problemItems))]
        }
        return XlsxSheetData(name: "Günlük Maliyet",
                             header: ["Tarih", "Satış Tutarı (₺)", "Teorik Maliyet (₺)", "Fiili Maliyet (₺)", "Zayi (₺)",
                                      "Kayıp (₺)", "Net Fark (₺)", "Fiili Maliyet %", "Sayılan Kalem", "Sorunlu Kalem"],
                             rows: rows, widths: [12, 15, 16, 15, 11, 11, 13, 14, 13, 13])
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
             .optNumber(r.lastClosing), .number(r.sold), .number(r.waste), .number(r.actual), .diff(r.diff),
             .diff(r.diffValue), .number(Double(r.shortageDays))]
        }
        return XlsxSheetData(
            name: "Özet",
            header: ["Ürün (\(DateKey.short(from)) – \(DateKey.short(to)))", "Sayılan Gün", "İlk Açılış", "Toplam Gelen",
                     "Gelen Transfer (+)", "Giden Transfer (-)", "Son Kapanış", "Toplam Satılan", "Toplam Zaiyat",
                     "Toplam Fiili Tüketim", "Toplam Fark", "Fark Tutarı (₺)", "Fazla Çıkış Olan Gün"],
            rows: rows, widths: [32, 12, 11, 13, 14, 14, 11, 13, 13, 16, 13, 14, 12])
    }

    // MARK: - Sayım formu

    /// Depoda elle doldurmak için yazdırılabilir sayım formu: açılış (devreden) dolu, kapanış boş.
    public static func countSheet(engine: Engine, date: String, branch: String = "") -> Data {
        let calcs = engine.calc(date: date).rows
        let rows: [[XlsxCell]] = calcs.compactMap { c in
            guard let item = engine.itemsByID[c.itemID] else { return nil }
            let e = engine.data.days[date]?.entries[item.id]
            return [.text(item.name), .text(item.unit), .number(c.opening),
                    .optNumber(e?.incoming), .optNumber(e?.transferIn), .optNumber(e?.transferOut),
                    .optNumber(e?.closing), XlsxCell(.blank)]
        }
        let title = (branch.isEmpty ? "" : branch + " · ") + "Sayım \(DateKey.short(date))"
        let sheet = XlsxSheetData(name: "Sayım Formu",
                                  header: [title, "Birim", "Açılış", "Gelen", "Gelen Transfer (+)", "Giden Transfer (-)", "Kapanış (sayım)", "Not"],
                                  rows: rows, widths: [30, 8, 11, 11, 14, 14, 16, 30])
        return XlsxWriter.build(sheets: [sheet])
    }

    // MARK: - Sipariş önerisi

    public static func orderSheet(_ suggestions: [OrderSuggestion], date: String) -> XlsxSheetData {
        let rows: [[XlsxCell]] = suggestions.map { s in
            [.text(label(s.item)), .optNumber(s.stock), .text(s.stockDate.map(DateKey.short) ?? ""),
             .number(s.dailyUsage), .optNumber(s.daysOfCover), .optNumber(s.item.minStock),
             .number(s.target), .text(s.suggested > 0 ? "Sipariş ver" : "Yeterli"), .number(s.suggested), .optNumber(s.cost)]
        }
        return XlsxSheetData(
            name: "Sipariş",
            header: ["Ürün (\(DateKey.short(date)))", "Son Stok", "Sayım Tarihi", "Günlük Tüketim", "Kaç Gün Yeter",
                     "Kritik Seviye", "Hedef Stok", "Durum", "Önerilen Sipariş", "Tutar (₺)"],
            rows: rows, widths: [28, 11, 12, 13, 12, 12, 11, 11, 14, 12])
    }

    public static func orders(_ suggestions: [OrderSuggestion], date: String) -> Data {
        XlsxWriter.build(sheets: [orderSheet(suggestions, date: date)])
    }

    /// Tedarikçiye (WhatsApp / e-posta) gönderilebilecek düz metin sipariş listesi.
    public static func orderText(_ suggestions: [OrderSuggestion], date: String, branch: String) -> String {
        let lines = suggestions.filter { $0.suggested > 0 }.map { s in
            "• \(s.item.name): \(Fmt.number(s.suggested, maxFraction: s.item.isKg ? 1 : 0)) \(s.item.unit.lowercased())"
        }
        var head = "Sipariş listesi – \(DateKey.short(date))"
        let b = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        if !b.isEmpty { head = "\(b) · " + head }
        return lines.isEmpty ? head + "\nSipariş gerekmiyor." : ([head] + lines).joined(separator: "\n")
    }
}
