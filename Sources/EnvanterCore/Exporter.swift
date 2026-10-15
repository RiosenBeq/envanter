import Foundation

/// Excel'e aktarım. Dönem kitabının "Alımlar" ve "Özet" sayfaları eski Alımlar sayfasıyla aynı sütun düzenini ve başlıkları
/// kullanır; böylece eski pivot tablolar çalışmaya devam eder. Gün kitabının "Envanter" sayfası aynı sütun sırasıyla sayım
/// ekranının adlarını kullanır (Devreden, Giren, … Olması Gereken, Fark; web `DAY_HEADER`).
public enum Exporter {
    public static let inventoryHeader = [
        "Tarih", "Ürün", "Açılış", "Gelen", "Gelen Transfer (+)", "Giden Transfer (-)",
        "Kapanış", "Satılan", "Zaiyat", "Fiili Tüketim", "Fark",
    ]
    public static let inventoryWidths: [Double] = [12, 28, 11, 11, 14, 14, 11, 11, 11, 13, 11]

    /// Gün kitabının Envanter sayfası (sade sözcükler)
    public static let dayHeader = [
        "Tarih", "Ürün", "Devreden", "Giren", "Şubeden Gelen", "Çıkan",
        "Kalan", "Satılan", "Zayi", "Olması Gereken", "Fark",
    ]
    public static let dayWidths: [Double] = [12, 28, 11, 11, 13, 11, 11, 11, 11, 14, 11]

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

    /// Gün kitabının satırları: aynı sütun sırası, 10. sütun Olması Gereken (Devreden + Giren + Şubeden gelen − Çıkan −
    /// Satılan − Zayi; Devreden bilinmiyorsa boş); Fark = Kalan − Olması Gereken
    public static func dayInventoryRows(engine: Engine, date: String) -> [[XlsxCell]] {
        let serial = DateKey.excelSerial(date)
        return engine.calc(date: date).rows.compactMap { c -> [XlsxCell]? in
            guard let item = engine.itemsByID[c.itemID] else { return nil }
            return [
                serial.map { XlsxCell.date(serial: $0) } ?? .text(date),
                .text(label(item)),
                .number(c.opening), .number(c.incoming), .number(c.transferIn), .number(c.transferOut),
                .optNumber(c.closing), .number(c.sold), .number(c.waste),
                .optNumber(c.expectedClosing), .diff(c.diff),
            ]
        }
    }

    /// Dışa aktarılan dosyanın adı: "NextGen Envanter – Kadıköy – 01.08.2026.xlsx". Şube adı kırpılır; içindeki / : \
    /// yerine - yazılır; boşsa atlanır. Web'deki `exportFileName` ile aynı (Fixtures/export-vectors.json).
    public static func fileName(branch: String, base: String, ext: String = "xlsx") -> String {
        let b = branch.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: "\\", with: "-")
        return (["NextGen Envanter"] + (b.isEmpty ? [] : [b]) + [base]).joined(separator: " – ") + ".\(ext)"
    }

    /// Seçili günün envanteri + satış dökümü (iki sayfa)
    public static func daySheets(engine: Engine, date: String) -> [XlsxSheetData] {
        let inv = XlsxSheetData(name: "Envanter", header: dayHeader,
                                rows: dayInventoryRows(engine: engine, date: date), widths: dayWidths)
        return [inv, salesSheet(engine: engine, date: date)]
    }

    public static func day(engine: Engine, date: String) -> Data {
        XlsxWriter.build(sheets: daySheets(engine: engine, date: date))
    }

    /// Verisi olan tüm günler (Alımlar formatı) + özet + günlük durum + (varsa) gün notları, elle zayi kayıtları ve ekip
    public static func history(engine: Engine, from: String, to: String) -> Data {
        let dates = engine.datesWithData.filter { $0 >= from && $0 <= to }
        let alim = XlsxSheetData(name: "Alımlar", header: inventoryHeader,
                                 rows: inventoryRows(engine: engine, dates: dates), widths: inventoryWidths)
        var sheets = [alim, summarySheet(engine: engine, from: from, to: to), dailySheet(engine: engine, from: from, to: to)]
        let notes: [[XlsxCell]] = dates.compactMap { d in
            guard let day = engine.data.days[d], !(day.note ?? "").isEmpty || !(day.countedBy ?? "").isEmpty || day.isLocked else { return nil }
            return [DateKey.excelSerial(d).map { XlsxCell.date(serial: $0) } ?? .text(d), .text(day.countedBy ?? ""),
                    .text(day.isLocked ? "Kapatıldı" : ""), .text(day.note ?? "")]
        }
        if !notes.isEmpty {
            sheets.append(XlsxSheetData(name: "Notlar", header: ["Tarih", "Sayımı Yapan", "Durum", "Not"], rows: notes, widths: [12, 20, 12, 60]))
        }
        if let waste = wasteSheet(engine: engine, dates: dates) { sheets.append(waste) }
        if !engine.data.employees.isEmpty { sheets.append(teamSheet(engine.data.employees)) }
        return XlsxWriter.build(sheets: sheets)
    }

    public static let wasteHeader = ["Tarih", "Kalem", "Miktar", "Birim", "Neden", "Not", "Kim"]

    /// Elle girilen zayi kayıtları (gün ve giriş sırasıyla); aralıkta kayıt yoksa nil
    public static func wasteSheet(engine: Engine, dates: [String]) -> XlsxSheetData? {
        var rows: [[XlsxCell]] = []
        for d in dates {
            for e in engine.data.days[d]?.wasteLog ?? [] {
                let item = engine.itemsByID[e.itemID]
                rows.append([DateKey.excelSerial(d).map { XlsxCell.date(serial: $0) } ?? .text(d),
                             .text(item?.name ?? e.itemID), .number(e.qty), .text(item?.unit ?? ""),
                             .text(WasteReason.title(e.reason)), .text(e.note ?? ""), .text(e.by ?? "")])
            }
        }
        guard !rows.isEmpty else { return nil }
        return XlsxSheetData(name: "Zayi Kayıtları", header: wasteHeader, rows: rows, widths: [12, 24, 10, 8, 22, 40, 18])
    }

    /// Günlük sayım durumu: sayılan / sorunlu / fazla çıkış / kritik altı kalem sayıları
    public static func dailySheet(engine: Engine, from: String, to: String) -> XlsxSheetData {
        let rows: [[XlsxCell]] = engine.periodStats(from: from, to: to).days.map { d in
            [DateKey.excelSerial(d.date).map { XlsxCell.date(serial: $0) } ?? .text(d.date),
             .number(Double(d.countedItems)), .number(Double(d.itemCount)), .number(Double(d.problemItems)),
             .number(Double(d.shortageItems)), .number(Double(d.belowMinimumItems)),
             .text(d.hasSales ? "Var" : "Yok"), .text(d.isLocked ? "Kapatıldı" : "")]
        }
        return XlsxSheetData(name: "Günlük Durum",
                             header: ["Tarih", "Sayılan Kalem", "Toplam Kalem", "Sorunlu Kalem", "Fazla Çıkış",
                                      "Kritik Altı", "Satış Raporu", "Durum"],
                             rows: rows, widths: [12, 13, 13, 13, 12, 11, 12, 12])
    }

    /// Ekip listesi (pasif üyeler dahil)
    public static func teamSheet(_ team: [Employee]) -> XlsxSheetData {
        let rows: [[XlsxCell]] = team.map { e in
            [.text(e.name), .text(e.role), .text(e.phone ?? ""), .text(e.active ? "Aktif" : "Pasif"),
             .text(e.startDate.map(DateKey.short) ?? ""), .text(e.endDate.map(DateKey.short) ?? ""),
             .text(e.account.map(LoginName.display) ?? ""), .text(e.note ?? "")]
        }
        return XlsxSheetData(name: "Ekip",
                             header: ["Ad", "Görev", "Telefon", "Durum", "İşe Giriş", "İşten Çıkış", "Giriş Hesabı", "Not"],
                             rows: rows, widths: [24, 16, 16, 9, 12, 12, 22, 40])
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
             .number(r.shortageQty), .number(Double(r.shortageDays))]
        }
        return XlsxSheetData(
            name: "Özet",
            header: ["Ürün (\(DateKey.short(from)) – \(DateKey.short(to)))", "Sayılan Gün", "İlk Açılış", "Toplam Gelen",
                     "Gelen Transfer (+)", "Giden Transfer (-)", "Son Kapanış", "Toplam Satılan", "Toplam Zaiyat",
                     "Toplam Fiili Tüketim", "Toplam Fark", "Fazla Çıkış Miktarı", "Fazla Çıkış Olan Gün"],
            rows: rows, widths: [32, 12, 11, 13, 14, 14, 11, 13, 13, 16, 13, 16, 12])
    }

    // MARK: - Sayım şablonu

    /// Sayım şablonu ("Sayım Formu"): depoda doldurulup "Excel'den Yükle" ile geri yüklenir (`CountImport`). 1. satır
    /// başlık, 2. satır sütunlar (Kalem, Kod, Birim, Devreden, Giren, Çıkan, Zayi, Kalan (sayım), Not), kalemler 3. satırdan.
    public static func countSheet(engine: Engine, date: String, branch: String = "") -> Data {
        XlsxWriter.build(sheets: [countSheetData(engine: engine, date: date, branch: branch)])
    }

    public static func countSheetData(engine: Engine, date: String, branch: String = "") -> XlsxSheetData {
        CountImport.template(engine: engine, date: date, branch: branch)
    }

    // MARK: - Sipariş önerisi

    public static func orderSheet(_ suggestions: [OrderSuggestion], date: String) -> XlsxSheetData {
        let rows: [[XlsxCell]] = suggestions.map { s in
            [.text(label(s.item)), .optNumber(s.stock), .optNumber(s.countedStock), .text(s.stockDate.map(DateKey.short) ?? ""),
             .number(s.onOrder), .number(s.dailyUsage), .optNumber(s.daysOfCover), .optNumber(s.item.minStock),
             .number(s.target), .text(s.suggested > 0 ? "Sipariş ver" : "Yeterli"), .number(s.suggested)]
        }
        return XlsxSheetData(
            name: "Sipariş",
            header: ["Ürün (\(DateKey.short(date)))", "Mevcut Stok (tahmini)", "Son Sayım", "Sayım Tarihi", "Siparişte",
                     "Günlük Tüketim", "Kaç Gün Yeter", "Kritik Seviye", "Hedef Stok", "Durum", "Önerilen Sipariş"],
            rows: rows, widths: [28, 14, 11, 12, 10, 13, 12, 12, 11, 11, 14])
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
