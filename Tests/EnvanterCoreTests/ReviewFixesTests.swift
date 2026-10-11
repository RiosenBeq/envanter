import XCTest
@testable import EnvanterCore

/// İnceleme sonrası düzeltmeler: çift sipariş (açık siparişler ve sonradan gelen teslimatlar öneriden düşülür).
final class ReviewFixesTests: XCTestCase {
    private func item(_ id: String = "g90") -> Item {
        Item(id: id, name: id, unit: "Adet", recipeUnit: "adet", factor: 1)
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
}
