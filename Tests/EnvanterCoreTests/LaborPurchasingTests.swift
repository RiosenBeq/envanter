import XCTest
@testable import EnvanterCore

/// Personel maliyeti, prime cost, fiyat geçmişi ve satın alma siparişi testleri.
final class LaborPurchasingTests: XCTestCase {
    func laborData() -> AppData {
        var data = AppData.seeded()
        data.employees = [
            Employee(id: "m", name: "Müdür", payType: .monthly, rate: 31_000, costFactor: 1.2),          // ağustos: 31 gün
            Employee(id: "d", name: "Kurye", payType: .daily, rate: 2_000),
            Employee(id: "h", name: "Servis", payType: .hourly, rate: 150, costFactor: 1.1),
            Employee(id: "x", name: "Ayrılan", payType: .monthly, rate: 30_000, endDate: "2026-08-01"),
            Employee(id: "y", name: "Yeni", payType: .daily, rate: 1_000, startDate: "2026-08-03"),
        ]
        return data
    }

    func testDailyLaborCost() {
        var data = laborData()
        data.days["2026-08-02"] = DayRecord(date: "2026-08-02", shifts: [
            "d": ShiftEntry(worked: true),
            "h": ShiftEntry(hours: 6, extra: 100),
            "y": ShiftEntry(worked: true),          // henüz işe başlamadı -> maliyet yok
        ], otherLabor: 500)
        let e = Engine(data: data)
        let l = e.labor(date: "2026-08-02")
        // Müdür: 31.000 × 1,2 ÷ 31 = 1.200 · Kurye 2.000 · Servis 6 × 150 × 1,1 + 100 × 1,1 = 1.100 · diğer 500
        XCTAssertEqual(l.total, 1_200 + 2_000 + 1_100 + 500, accuracy: 1e-9)
        XCTAssertEqual(l.other, 500)
        XCTAssertEqual(l.hours, 6)
        XCTAssertNil(l.lines.first { $0.employee.id == "x" }, "ayrılan personel maliyete girmez")
        XCTAssertNil(l.lines.first { $0.employee.id == "y" }, "işe başlamamış personel maliyete girmez")
        XCTAssertEqual(l.headcount, 2, "kurye + servis (aylıkta saat girilmedi)")

        // Kayıt yokken: yalnızca aylık maaş payı ve çıkış gününe kadar ayrılan personel
        let d1 = e.labor(date: "2026-08-01")
        XCTAssertEqual(d1.total, 1_200 + 30_000.0 / 31, accuracy: 1e-6)
        // Şubat: 28 güne bölünür
        XCTAssertEqual(e.labor(date: "2026-02-10").total, 31_000 * 1.2 / 28 + 30_000.0 / 28, accuracy: 1e-6)
    }

    func testLaborSummaryAndPrimeCost() {
        var data = laborData()
        data.employees.removeAll { $0.id == "x" || $0.id == "y" }
        let cost = ["g90": 10.0, "ekmekSusamli": 2.0]
        for (id, c) in cost { data.items[data.items.firstIndex { $0.id == id }!].unitCost = c }
        data.days["2026-08-01"] = DayRecord(date: "2026-08-01", sales: [SaleLine(code: "11100", name: "M", qty: 100, amount: 15_000)],
                                            shifts: ["d": ShiftEntry(worked: true), "h": ShiftEntry(hours: 10)])
        let e = Engine(data: data)
        let s = e.laborSummary(from: "2026-08-01", to: "2026-08-03")
        XCTAssertEqual(s.rows.first { $0.employee.id == "m" }!.cost, 3_600, accuracy: 1e-9)   // 3 gün × 1.200
        XCTAssertEqual(s.rows.first { $0.employee.id == "d" }!.days, 1)
        XCTAssertEqual(s.rows.first { $0.employee.id == "h" }!.hours, 10)
        XCTAssertEqual(s.total, 3_600 + 2_000 + 1_650, accuracy: 1e-9)

        let p = e.periodStats(from: "2026-08-01", to: "2026-08-01")
        // hammadde: 100 × (10 + 2) = 1.200 · personel: 1.200 + 2.000 + 1.650 = 4.850
        XCTAssertEqual(p.laborCost, 4_850, accuracy: 1e-9)
        XCTAssertEqual(p.actualCost, 1_200, accuracy: 1e-9)
        XCTAssertEqual(p.primeCost, 6_050, accuracy: 1e-9)
        XCTAssertEqual(p.laborPct!, 4_850.0 / 15_000, accuracy: 1e-12)
        XCTAssertEqual(p.primeCostPct!, 6_050.0 / 15_000, accuracy: 1e-12)
        XCTAssertNil(Engine(data: AppData.seeded()).periodStats(from: "2026-08-01", to: "2026-08-31").laborPct)
    }

    func testPercentagesUseOnlyRevenueDays() {
        var data = AppData.seeded()
        data.items[data.items.firstIndex { $0.id == "g90" }!].unitCost = 10
        data.days["2026-08-01"] = DayRecord(date: "2026-08-01", sales: [SaleLine(code: "11100", name: "M", qty: 10, amount: 1_000)])
        // Tutar bilgisi olmayan gün oranı bozmamalı
        data.days["2026-08-02"] = DayRecord(date: "2026-08-02", sales: [SaleLine(code: "11100", name: "M", qty: 50)])
        let p = Engine(data: data).periodStats(from: "2026-08-01", to: "2026-08-31")
        XCTAssertEqual(p.theoreticalCost, 600, accuracy: 1e-9)
        XCTAssertEqual(p.theoreticalCostPct!, 0.1, accuracy: 1e-12)
    }

    func testPriceHistoryAndAlerts() {
        var item = Item(id: "a", name: "A", unit: "Kg", recipeUnit: "kg", factor: 1, unitCost: 100)
        item.setCost(110, on: "2026-08-01")
        XCTAssertEqual(item.costHistory?.map { $0.cost }, [100, 110])
        XCTAssertNil(item.costHistory?.first?.date)
        item.setCost(112, on: "2026-08-01")   // aynı gün: tek kayıt
        XCTAssertEqual(item.costHistory?.count, 2)
        XCTAssertEqual(item.lastPriceChange!.ratio, 0.12, accuracy: 1e-12)
        item.setCost(112, on: "2026-08-05")   // değişmedi: kayıt yok
        XCTAssertEqual(item.costHistory?.count, 2)

        var data = AppData.seeded()
        let i = data.items.firstIndex { $0.id == "patates" }!
        data.items[i].unitCost = 60
        data.items[i].setCost(66, on: "2026-08-10")
        let e = Engine(data: data)
        XCTAssertEqual(e.priceAlerts(asOf: "2026-08-20", threshold: 0.05).map { $0.item.id }, ["patates"])
        XCTAssertTrue(e.priceAlerts(asOf: "2026-08-20", threshold: 0.2).isEmpty)
        XCTAssertTrue(e.priceAlerts(asOf: "2026-10-20", days: 30, threshold: 0.05).isEmpty, "eski değişim")
        XCTAssertGreaterThan(e.productsUsing(itemID: "patates"), 10)
    }

    func testPurchaseOrderReceiving() throws {
        var data = AppData.seeded()
        data.days["2026-08-01"] = DayRecord(date: "2026-08-01", entries: ["g90": DayEntry(opening: 100, closing: 40)])
        let suggestions = Engine(data: data).orderSuggestions(asOf: "2026-08-01", lookbackDays: 7, coverDays: 3)
        var order = try XCTUnwrap(Purchasing.makeOrder(from: suggestions, date: "2026-08-01", supplier: "Et"))
        XCTAssertEqual(order.lines.map { $0.itemID }, ["g90"])
        XCTAssertEqual(order.lines[0].qty, 140)      // 60 × 3 − 40
        order.lines.append(OrderLine(itemID: "ekmekSusamli", qty: 50))
        data.purchaseOrders = [order]
        XCTAssertTrue(Purchasing.text(order, items: Engine(data: data).itemsByID, branch: "Tuzla").contains("• 90 Gr: 140 adet"))

        // Kilitli güne teslim alınamaz
        data.days["2026-08-02"] = DayRecord(date: "2026-08-02", entries: ["g90": DayEntry(incoming: 10)], locked: true)
        XCTAssertThrowsError(try Purchasing.receive(orderID: order.id, on: "2026-08-02", data: &data)) {
            XCTAssertEqual($0 as? Purchasing.Failure, .locked("2026-08-02"))
        }
        data.days["2026-08-02"]!.locked = nil

        // 90 Gr eksik geldi (130), ekmek gelmedi (0), 90 Gr faturası 40 ₺
        let r = try Purchasing.receive(orderID: order.id, on: "2026-08-02", quantities: ["g90": 130, "ekmekSusamli": 0],
                                       prices: ["g90": 40], data: &data)
        XCTAssertEqual(r.lines, 1)
        XCTAssertEqual(r.priceUpdates, 1)
        XCTAssertEqual(data.days["2026-08-02"]!.entries["g90"]!.incoming, 140, "var olan Gelen'e eklenir")
        XCTAssertNil(data.days["2026-08-02"]!.entries["ekmekSusamli"])
        XCTAssertEqual(data.items.first { $0.id == "g90" }!.unitCost, 40)
        XCTAssertEqual(data.purchaseOrders[0].status, .received)
        XCTAssertEqual(data.purchaseOrders[0].lines[0].received, 130)
        XCTAssertThrowsError(try Purchasing.receive(orderID: order.id, on: "2026-08-02", data: &data))
        XCTAssertEqual(Purchasing.estimatedCost(data.purchaseOrders[0], items: Engine(data: data).itemsByID), 130 * 40, accuracy: 1e-9)

        // Hiçbir şey gelmediyse hata
        data.purchaseOrders.append(PurchaseOrder(id: "b", date: "2026-08-02", lines: [OrderLine(itemID: "g90", qty: 5)]))
        XCTAssertThrowsError(try Purchasing.receive(orderID: "b", on: "2026-08-03", quantities: ["g90": 0], data: &data))
        Purchasing.cancel(orderID: "b", data: &data)
        XCTAssertEqual(data.purchaseOrders[1].status, .cancelled)
    }

    func testNewFieldsRoundTripAndOldFilesDecode() throws {
        var data = laborData()
        data.days["2026-08-01"] = DayRecord(date: "2026-08-01", shifts: ["h": ShiftEntry(hours: 4)], otherLabor: 250)
        data.purchaseOrders = [PurchaseOrder(id: "p", date: "2026-08-01", lines: [OrderLine(itemID: "g90", qty: 5)])]
        data.settings.targetLaborPct = 0.25
        data.items[0].setCost(12, on: "2026-08-01")
        let back = try Persistence.decode(try Persistence.encoder().encode(data))
        XCTAssertEqual(back.employees.count, 5)
        XCTAssertEqual(back.employees[2].payType, .hourly)
        XCTAssertEqual(back.days["2026-08-01"]!.shifts?["h"]?.hours, 4)
        XCTAssertEqual(back.days["2026-08-01"]!.otherLabor, 250)
        XCTAssertEqual(back.purchaseOrders.first?.lines.first?.qty, 5)
        XCTAssertEqual(back.settings.targetLaborPct, 0.25)
        XCTAssertEqual(back.settings.priceAlertPct, 0.05)
        XCTAssertEqual(back.items[0].costHistory?.last?.cost, 12)
        XCTAssertFalse(DayRecord(date: "2026-08-01", shifts: ["h": ShiftEntry(hours: 4)]).isEmpty)
        XCTAssertTrue(DayRecord(date: "2026-08-01", shifts: ["h": ShiftEntry()]).isEmpty)

        let old = #"{"items":[],"products":[],"settings":{"branchName":"X"}}"#
        let d = try Persistence.decode(Data(old.utf8))
        XCTAssertTrue(d.employees.isEmpty)
        XCTAssertTrue(d.purchaseOrders.isEmpty)
        XCTAssertEqual(d.settings.branchName, "X")
        XCTAssertNil(d.settings.targetFoodCostPct)
    }

    func testExportIncludesLabor() throws {
        var data = laborData()
        data.days["2026-08-01"] = DayRecord(date: "2026-08-01", entries: ["g90": DayEntry(opening: 5, closing: 3)],
                                            shifts: ["h": ShiftEntry(hours: 4)])
        let sheets = try XlsxReader.read(data: Exporter.history(engine: Engine(data: data), from: "2026-08-01", to: "2026-08-02"))
        XCTAssertEqual(sheets.map { $0.name }, ["Alımlar", "Özet", "Günlük Maliyet", "Personel"])
        XCTAssertEqual(sheets[2].value(row: 1, col: 8), "Personel (₺)")
        let personel = sheets[3]
        XCTAssertEqual(personel.value(row: 2, col: 1), "Müdür")
        XCTAssertEqual(personel.value(row: personel.maxRow, col: 1), "TOPLAM")
    }

    func testDemoHasRealisticLaborAndPrime() {
        let e = Engine(data: DemoData.make(endingAt: "2026-08-31", days: 35))
        let p = e.periodStats(from: "2026-08-01", to: "2026-08-31")
        let labor = try? XCTUnwrap(p.laborPct)
        let prime = try? XCTUnwrap(p.primeCostPct)
        XCTAssertTrue((0.12...0.40).contains(labor ?? 0), "personel %: \(labor ?? -1)")
        XCTAssertTrue((0.35...0.80).contains(prime ?? 0), "prime cost %: \(prime ?? -1)")
        XCTAssertFalse(e.priceAlerts(asOf: "2026-08-31", threshold: 0.05).isEmpty)
        XCTAssertEqual(e.data.purchaseOrders.filter { $0.status == .open }.count, 1)
        XCTAssertEqual(e.data.settings.branchName, "Burger Yiyelim · Tuzla Marina")
    }
}
