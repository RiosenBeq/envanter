import XCTest
@testable import EnvanterCore

/// Dönem envanter raporu (komut satırı `report`): fazla çıkış sırası birimler arası miktara göre değil, kritik seviye
/// dönem sonundaki son sayıma göre
final class InventoryReportTests: XCTestCase {
    /// Satış yok: her gün açılış − kapanış kadar fazla çıkış (fark = −fiili)
    private func sample() -> AppData {
        let items = [
            Item(id: "patates", name: "Patates", unit: "Kg", recipeUnit: "kg", factor: 1),
            Item(id: "ekmek", name: "Ekmek", unit: "Adet", recipeUnit: "adet", factor: 1),
            Item(id: "pecete", name: "Peçete", unit: "ADET", recipeUnit: "adet", factor: 1),
            Item(id: "sos", name: "Sos", unit: "Kg", recipeUnit: "kg", factor: 1),
            Item(id: "yag", name: "Yağ", unit: "Lt", recipeUnit: "lt", factor: 1, minStock: 20),
            Item(id: "eski", name: "Eski Kalem", unit: "Adet", recipeUnit: "adet", factor: 1, active: false, minStock: 100),
            Item(id: "sayilmayan", name: "Sayılmayan", unit: "Adet", recipeUnit: "adet", factor: 1, minStock: 100),
            Item(id: "toleransli", name: "Toleranslı", unit: "Adet", recipeUnit: "adet", factor: 1, minStock: 5, tolerance: 2),
        ]
        var days: [String: DayRecord] = [:]
        func set(_ date: String, _ entries: [String: DayEntry]) { days[date] = DayRecord(date: date, entries: entries) }
        set("2026-08-01", ["patates": DayEntry(opening: 10, closing: 9), "ekmek": DayEntry(opening: 500, closing: 400),
                           "pecete": DayEntry(opening: 1000, closing: 950), "sos": DayEntry(opening: 5, closing: 3),
                           "eski": DayEntry(opening: 10, closing: 10), "toleransli": DayEntry(opening: 10, closing: 8)])
        set("2026-08-02", ["patates": DayEntry(closing: 8), "ekmek": DayEntry(closing: 400), "pecete": DayEntry(closing: 950),
                           "sos": DayEntry(closing: 3), "toleransli": DayEntry(closing: 8)])
        set("2026-08-03", ["patates": DayEntry(closing: 7), "yag": DayEntry(opening: 15, closing: 15)])
        set("2026-08-04", ["patates": DayEntry(closing: 6.5)])
        // Dönemden sonra: Yağ'ın stoğu kritik seviyenin üstüne çıktı (31 Ağustos itibarıyla rapor bunu görmez)
        set("2026-08-06", ["yag": DayEntry(opening: 30, closing: 30)])
        let orders = [PurchaseOrder(id: "o1", date: "2026-08-02", lines: [OrderLine(itemID: "yag", qty: 10)]),
                      PurchaseOrder(id: "o2", date: "2026-08-01", lines: [OrderLine(itemID: "ekmek", qty: 100)], status: .received),
                      PurchaseOrder(id: "o3", date: "2026-08-03", lines: [OrderLine(itemID: "sos", qty: 1)])]
        var settings = AppSettings()
        settings.branchName = "Test Şubesi"
        return AppData(items: items, products: [], days: days, settings: settings, purchaseOrders: orders)
    }

    func testShortagesRankByDaysThenWithinUnit() {
        let r = InventoryReport(engine: Engine(data: sample()), from: "2026-08-01", to: "2026-08-05")
        // Patates 4 gün; 1 günlükler birim birim (adet: büyük harf farkı yok sayılır), aynı birimde çoktan aza
        XCTAssertEqual(r.shortages.map(\.item.id), ["patates", "ekmek", "pecete", "sos"])
        XCTAssertEqual(r.shortages.map(\.days), [4, 1, 1, 1])
        XCTAssertEqual(r.shortages[0].qty, 3.5, accuracy: 1e-9)
        XCTAssertEqual(r.shortages[1].qty, 100, accuracy: 1e-9)
        XCTAssertEqual(r.shortages[3].qty, 2, accuracy: 1e-9)
        // Tolerans içindeki 2 adet fazla çıkış listeye girmez
        XCTAssertFalse(r.shortages.contains { $0.item.id == "toleransli" })
    }

    func testShortageOrderIsAStrictOrdering() {
        func s(_ id: String, _ unit: String, _ qty: Double, _ days: Int) -> InventoryReport.Shortage {
            .init(item: Item(id: id, name: id.uppercased(), unit: unit, recipeUnit: "x", factor: 1), qty: qty, days: days)
        }
        // Birim karışık bir dizide her sıralama girdisinden aynı sonuç (geçişli, tutarlı karşılaştırma)
        let list = [s("c", "Kg", 5, 2), s("d", "Adet", 1, 2), s("e", "Kg", 9, 2), s("a", "Adet", 300, 1), s("b", "kg", 0.5, 3),
                    s("f", "Adet", 1, 2)]
        let expected = ["b", "d", "f", "e", "c", "a"]
        XCTAssertEqual(list.sorted(by: InventoryReport.shortageOrder).map(\.item.id), expected)
        XCTAssertEqual(list.reversed().sorted(by: InventoryReport.shortageOrder).map(\.item.id), expected)
        for x in list {
            XCTAssertFalse(InventoryReport.shortageOrder(x, x), "kendinden küçük olamaz")
            for y in list where InventoryReport.shortageOrder(x, y) {
                XCTAssertFalse(InventoryReport.shortageOrder(y, x), "\(x.item.id) / \(y.item.id)")
                for z in list where InventoryReport.shortageOrder(y, z) {
                    XCTAssertTrue(InventoryReport.shortageOrder(x, z), "geçişli: \(x.item.id) < \(y.item.id) < \(z.item.id)")
                }
            }
        }
    }

    func testBelowMinimumUsesLastCountOnOrBeforeTo() {
        let data = sample()
        let r = InventoryReport(engine: Engine(data: data), from: "2026-08-01", to: "2026-08-05")
        // Yağ: 3 Ağustos'taki 15 lt (kritik 20); pasif ve hiç sayılmamış kalem yok; tolerans kalemi 8 ≥ 5
        XCTAssertEqual(r.belowMinimum.map(\.item.id), ["yag"])
        XCTAssertEqual(r.belowMinimum.first?.closing, 15)
        XCTAssertEqual(r.belowMinimum.first?.date, "2026-08-03")
        // 6 Ağustos itibarıyla son sayım 30 lt: altında değil
        XCTAssertEqual(InventoryReport(engine: Engine(data: data), from: "2026-08-01", to: "2026-08-06").belowMinimum.map(\.item.id), [])
        // 2 Ağustos itibarıyla Yağ hiç sayılmamış: listede yok
        XCTAssertEqual(InventoryReport(engine: Engine(data: data), from: "2026-08-01", to: "2026-08-02").belowMinimum.map(\.item.id), [])
        // Tam o gün sayılan kapanış da sayılır (sınır dahil)
        let onDay = InventoryReport(engine: Engine(data: data), from: "2026-08-01", to: "2026-08-03")
        XCTAssertEqual(onDay.belowMinimum.map(\.date), ["2026-08-03"])
        // Kritik seviyeye eşit kapanış altında sayılmaz
        var equal = data
        equal.items[4].minStock = 15
        XCTAssertEqual(InventoryReport(engine: Engine(data: equal), from: "2026-08-01", to: "2026-08-05").belowMinimum.count, 0)
    }

    func testCountsAndProblemItems() {
        let r = InventoryReport(engine: Engine(data: sample()), from: "2026-08-01", to: "2026-08-05")
        XCTAssertEqual(r.period.days.count, 4)
        XCTAssertEqual(r.period.countedDays, 4)
        XCTAssertEqual(r.period.salesDays, 0)
        XCTAssertEqual(r.itemCount, 7, "aktif kalemler")
        XCTAssertEqual(r.problemItems.map(\.id), ["patates", "ekmek", "pecete", "sos"])
        XCTAssertEqual(r.openOrders, 2)
    }

    func testText() {
        let data = sample()
        let text = InventoryReport(engine: Engine(data: data), from: "2026-08-01", to: "2026-08-05").text(branch: "Test Şubesi", top: 3)
        XCTAssertEqual(text.components(separatedBy: "\n"), [
            "Test Şubesi · 01.08.2026 – 05.08.2026",
            "Gün                 : 4 (sayım 4, satış 0)",
            "Sorunlu kalem       : 4 / 7 (Patates, Ekmek, Peçete, Sos)",
            "Fazla çıkış         : 4 kalem (en sık olanlar)",
            "  • Patates: 3,5 kg (4 gün)",
            "  • Ekmek: 100 adet (1 gün)",
            "  • Peçete: 50 adet (1 gün)",
            "Kritik seviye altı  : 1 kalem (05.08.2026 itibarıyla son sayım)",
            "  • Yağ: 15 lt (kritik 20 lt · sayım 03.08.2026)",
            "Açık sipariş        : 2",
        ])
        XCTAssertFalse(text.contains("₺"))

        // Boş dönem ve şube adı yok
        let empty = InventoryReport(engine: Engine(data: AppData(items: [], products: [])), from: "2026-09-01", to: "2026-09-30")
        XCTAssertEqual(empty.text(branch: "  ").components(separatedBy: "\n"), [
            "Dönem özeti · 01.09.2026 – 30.09.2026",
            "Gün                 : 0 (sayım 0, satış 0)",
            "Sorunlu kalem       : 0 / 0",
            "Fazla çıkış         : yok",
            "Kritik seviye altı  : yok",
            "Açık sipariş        : 0",
        ])

        // Sayım tam o gün yapıldıysa tarih tekrarlanmaz
        let onDay = InventoryReport(engine: Engine(data: data), from: "2026-08-03", to: "2026-08-03").text(branch: "")
        XCTAssertTrue(onDay.contains("  • Yağ: 15 lt (kritik 20 lt)"), onDay)
    }
}
