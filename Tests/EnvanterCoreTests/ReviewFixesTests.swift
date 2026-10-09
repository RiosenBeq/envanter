import XCTest
@testable import EnvanterCore

/// İnceleme sonrası düzeltmeler: çift sipariş, geriye dönük fiyat/ücret, kapalı gün maaşı, fiyat uyarısı penceresi.
final class ReviewFixesTests: XCTestCase {
    private func item(_ id: String = "g90", cost: Double? = 40) -> Item {
        Item(id: id, name: id, unit: "Adet", recipeUnit: "adet", factor: 1, unitCost: cost)
    }

    // MARK: Sipariş önerisi

    func testOpenOrdersAndLaterDeliveriesReduceSuggestion() {
        var data = AppData(items: [item()], products: [])
        data.days["2026-08-01"] = DayRecord(date: "2026-08-01", entries: ["g90": DayEntry(opening: 100, closing: 40)])
        var e = Engine(data: data)
        let first = e.orderSuggestions(asOf: "2026-08-01", lookbackDays: 7, coverDays: 3).first!
        XCTAssertEqual(first.suggested, 140)            // 60 × 3 − 40
        XCTAssertEqual(first.onOrder, 0)

        // Açık sipariş öneriden düşülür
        data.purchaseOrders.append(Purchasing.makeOrder(from: [first], date: "2026-08-01")!)
        e = Engine(data: data)
        let withOrder = e.orderSuggestions(asOf: "2026-08-01", lookbackDays: 7, coverDays: 3).first!
        XCTAssertEqual(withOrder.onOrder, 140)
        XCTAssertEqual(withOrder.suggested, 0)

        // Ertesi sabah teslim alındı: sayım yapılmadan önce de stok tahmini teslimatı içerir
        try! Purchasing.receive(orderID: data.purchaseOrders[0].id, on: "2026-08-02", data: &data)
        e = Engine(data: data)
        let nextMorning = e.orderSuggestions(asOf: "2026-08-02", lookbackDays: 7, coverDays: 3).first!
        XCTAssertEqual(nextMorning.countedStock, 40)
        XCTAssertEqual(nextMorning.stock, 180)          // 40 + 140 gelen
        XCTAssertEqual(nextMorning.onOrder, 0)
        XCTAssertEqual(nextMorning.suggested, 0)
    }

    func testOrderPlacedAfterViewedDateIsIgnored() {
        var data = AppData(items: [item()], products: [])
        data.days["2026-08-01"] = DayRecord(date: "2026-08-01", entries: ["g90": DayEntry(opening: 100, closing: 40)])
        data.purchaseOrders.append(PurchaseOrder(date: "2026-08-05", lines: [OrderLine(itemID: "g90", qty: 50)]))
        XCTAssertEqual(Engine(data: data).onOrder(asOf: "2026-08-01")["g90"], nil)
        XCTAssertEqual(Engine(data: data).onOrder(asOf: "2026-08-05")["g90"], 50)
    }

    // MARK: Fiyat geçmişi

    func testBackdatedInvoiceDoesNotOverrideNewerPrice() {
        var i = item(cost: 40)
        i.setCost(44, on: "2026-08-10")
        i.setCost(42, on: "2026-08-06")                 // sonradan girilen eski tarihli fatura
        XCTAssertEqual(i.unitCost, 44)
        XCTAssertEqual(i.costHistory?.map { $0.date }, [nil, "2026-08-06", "2026-08-10"])
        XCTAssertEqual(i.cost(on: "2026-08-01"), 40)
        XCTAssertEqual(i.cost(on: "2026-08-07"), 42)
        XCTAssertEqual(i.cost(on: "2026-09-01"), 44)
        XCTAssertEqual(i.lastPriceChange?.to, 44)
        // Aynı fiyatı tekrar girmek kayıt eklemez
        i.setCost(44, on: "2026-08-20")
        XCTAssertEqual(i.costHistory?.count, 3)
    }

    func testPastDaysValuedAtTheirOwnPrice() {
        var data = AppData(items: [item(cost: 40)], products: [])
        data.days["2026-08-01"] = DayRecord(date: "2026-08-01", entries: ["g90": DayEntry(opening: 10, closing: 9)])
        data.items[0].setCost(50, on: "2026-09-01")
        let e = Engine(data: data)
        // Satış yok, 1 adet fazla çıkış: 01.08'de fiyat 40
        XCTAssertEqual(e.calc(date: "2026-08-01").rows[0].diffValue, -40)
        XCTAssertEqual(e.summary(from: "2026-08-01", to: "2026-08-31")[0].diffValue, -40)
    }

    func testPriceAlertSeesCumulativeIncreaseInWindow() {
        var data = AppData(items: [item("patates", cost: 60)], products: [])
        data.items[0].setCost(66, on: "2026-08-01")      // %10
        data.items[0].setCost(67, on: "2026-08-03")      // +%1,5; toplam %11,7
        let alerts = Engine(data: data).priceAlerts(asOf: "2026-08-05", threshold: 0.05)
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].from, 60)
        XCTAssertEqual(alerts[0].to, 67)
        XCTAssertEqual(alerts[0].date, "2026-08-03")
        // Pencere dışına çıkınca uyarı kalkar
        XCTAssertTrue(Engine(data: data).priceAlerts(asOf: "2026-10-01", threshold: 0.05).isEmpty)
    }

    // MARK: Personel

    func testRaiseDoesNotChangePastDays() {
        var m = Employee(id: "m", name: "Müdür", payType: .monthly, rate: 31_000)
        m.setTerms(payType: .monthly, rate: 62_000, costFactor: 1, from: "2026-08-16")
        var data = AppData(items: [], products: [])
        data.employees = [m]
        let e = Engine(data: data)
        XCTAssertEqual(e.labor(date: "2026-08-15").total, 1_000)
        XCTAssertEqual(e.labor(date: "2026-08-16").total, 2_000)
        XCTAssertEqual(m.rate, 62_000)                  // listede güncel ücret görünür
        XCTAssertEqual(m.payHistory?.count, 2)

        // Düzeltme (tüm dönem) geçmişi siler
        var c = m
        c.setTerms(payType: .monthly, rate: 30_000, costFactor: 1, from: nil)
        XCTAssertNil(c.payHistory)
        data.employees = [c]
        XCTAssertEqual(Engine(data: data).labor(date: "2026-08-15").total, Engine.clean(30_000.0 / 31))
    }

    func testClosedDaysSalaryCountsInPeriodLabor() {
        var data = AppData(items: [], products: [])
        data.employees = [Employee(id: "m", name: "Müdür", payType: .monthly, rate: 30_000)]   // Eylül: 1.000 ₺/gün
        for d in 1...10 where d != 5 {                   // 05.09 kapalı (kayıt yok)
            let key = String(format: "2026-09-%02d", d)
            data.days[key] = DayRecord(date: key, sales: [SaleLine(code: "1", name: "x", qty: 1, amount: 4_000)])
        }
        let p = Engine(data: data).periodStats(from: "2026-09-01", to: "2026-09-10")
        XCTAssertEqual(p.laborCost, 10_000)
        XCTAssertEqual(p.laborCost, Engine(data: data).laborSummary(from: "2026-09-01", to: "2026-09-10").total)
        XCTAssertEqual(p.laborPct!, 10_000.0 / 36_000, accuracy: 1e-9)
    }

    func testNoLaborRecordedShowsNoPercentage() {
        var data = AppData(items: [], products: [])
        data.employees = [Employee(id: "y", name: "Yeni", payType: .monthly, rate: 30_000, startDate: "2026-10-01")]
        data.days["2026-09-01"] = DayRecord(date: "2026-09-01", sales: [SaleLine(code: "1", name: "x", qty: 1, amount: 4_000)])
        let p = Engine(data: data).periodStats(from: "2026-09-01", to: "2026-09-30")
        XCTAssertFalse(p.hasLabor)
        XCTAssertNil(p.laborPct)
        XCTAssertNil(p.primeCostPct)
    }

    // MARK: Gün şeridi

    func testSignificantLossIsRelativeToRevenue() {
        var o = DayOverview(date: "2026-08-01", itemCount: 1, countedItems: 1, hasSales: true, salesLines: 1, unknownLines: 0,
                            problemItems: 3, shortageItems: 3, belowMinimumItems: 0, lossValue: 600, netValue: -600, isLocked: false)
        o.revenue = 80_000
        XCTAssertFalse(o.hasSignificantLoss)            // %0,75
        XCTAssertTrue(o.hasNotableLoss)
        o.revenue = 200_000
        XCTAssertFalse(o.hasNotableLoss)                // %0,3
        o.revenue = 80_000
        o.revenue = 40_000
        XCTAssertTrue(o.hasSignificantLoss)             // %1,5
        o.revenue = nil
        XCTAssertTrue(o.hasSignificantLoss)             // tutar bilinmiyorsa 500 ₺ eşiği
    }
}
