import XCTest
@testable import EnvanterCore

/// Satın alma siparişi (yalnızca miktarlar), kayıt dosyası uyumluluğu ve Excel'e aktarımdaki ekip sayfası testleri.
final class PurchasingTests: XCTestCase {
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

        // 90 Gr eksik geldi (130), ekmek gelmedi (0): yalnızca miktarlar işlenir, kalemlere dokunulmaz
        let items = data.items
        let received = try Purchasing.receive(orderID: order.id, on: "2026-08-02", quantities: ["g90": 130, "ekmekSusamli": 0],
                                              data: &data)
        XCTAssertEqual(received, 1)
        XCTAssertEqual(data.days["2026-08-02"]!.entries["g90"]!.incoming, 140, "var olan Gelen'e eklenir")
        XCTAssertNil(data.days["2026-08-02"]!.entries["ekmekSusamli"])
        XCTAssertEqual(data.items, items)
        XCTAssertEqual(data.purchaseOrders[0].status, .received)
        XCTAssertEqual(data.purchaseOrders[0].receivedOn, "2026-08-02")
        XCTAssertEqual(data.purchaseOrders[0].lines.map { $0.received }, [130, 0])
        XCTAssertThrowsError(try Purchasing.receive(orderID: order.id, on: "2026-08-02", data: &data)) {
            XCTAssertEqual($0 as? Purchasing.Failure, .notOpen)
        }
        XCTAssertThrowsError(try Purchasing.receive(orderID: "yok", on: "2026-08-02", data: &data)) {
            XCTAssertEqual($0 as? Purchasing.Failure, .notFound)
        }

        // Miktar verilmeyen kalemde sipariş miktarı esas alınır
        data.purchaseOrders.append(PurchaseOrder(id: "c", date: "2026-08-02", lines: [OrderLine(itemID: "peynir", qty: 2.5)]))
        XCTAssertEqual(try Purchasing.receive(orderID: "c", on: "2026-08-03", data: &data), 1)
        XCTAssertEqual(data.days["2026-08-03"]!.entries["peynir"]!.incoming, 2.5)

        // Hiçbir şey gelmediyse hata
        data.purchaseOrders.append(PurchaseOrder(id: "b", date: "2026-08-02", lines: [OrderLine(itemID: "g90", qty: 5)]))
        XCTAssertThrowsError(try Purchasing.receive(orderID: "b", on: "2026-08-03", quantities: ["g90": 0], data: &data)) {
            XCTAssertEqual($0 as? Purchasing.Failure, .nothingReceived)
        }
        Purchasing.cancel(orderID: "b", data: &data)
        XCTAssertEqual(data.purchaseOrders.first { $0.id == "b" }?.status, .cancelled)
    }

    func testNewFieldsRoundTripAndOldFilesDecode() throws {
        var data = AppData.seeded()
        data.employees = [Employee(id: "a", name: "Ayşe", role: "Kasiyer", phone: "0500", startDate: "2026-08-01",
                                   note: "hafta sonu", account: "ayse@envanter.local"),
                          Employee(id: "b", name: "Can", active: false, endDate: "2026-08-20")]
        data.purchaseOrders = [PurchaseOrder(id: "p", date: "2026-08-01", lines: [OrderLine(itemID: "g90", qty: 5, received: 4)])]
        data.days["2026-08-01"] = DayRecord(date: "2026-08-01", sales: [SaleLine(code: "11100", name: "M", qty: 3)], countedBy: "Ayşe")
        let back = try Persistence.decode(try Persistence.encoder().encode(data))
        XCTAssertEqual(back.employees, data.employees)
        XCTAssertEqual(back.purchaseOrders, data.purchaseOrders)
        XCTAssertEqual(back.days, data.days)

        let old = #"{"items":[],"products":[],"settings":{"branchName":"X"}}"#
        let d = try Persistence.decode(Data(old.utf8))
        XCTAssertTrue(d.employees.isEmpty)
        XCTAssertTrue(d.purchaseOrders.isEmpty)
        XCTAssertEqual(d.settings.branchName, "X")
    }

    /// Eski sürümün kayıt dosyası (maliyet, fiyat geçmişi, ücret, vardiya, hedef alanlarıyla) açılır; alanlar yok sayılır
    /// ve yeniden kaydedilen dosyada yer almaz
    func testOldCostFieldsAreIgnoredAndNotWritten() throws {
        let json = #"""
        {"schemaVersion":1,
         "items":[{"id":"g90","name":"90 Gr","unit":"Adet","recipeUnit":"adet","factor":1,"active":true,"unitCost":38,
                   "minStock":50,"costHistory":[{"date":null,"cost":35},{"date":"2026-08-01","cost":38}]}],
         "products":[],
         "employees":[{"id":"e1","name":"Murat","role":"Müdür","payType":"monthly","rate":85000,"costFactor":1.2,"active":true,
                       "defaultHours":9,"payHistory":[{"from":null,"payType":"monthly","rate":80000,"costFactor":1.2}]},
                      {"id":"e2","name":"Can","payType":"hourly","rate":150}],
         "purchaseOrders":[{"id":"p","date":"2026-08-01","supplier":"","status":"received","lines":[{"itemID":"g90","qty":5,"received":5,"unitPrice":38}]}],
         "settings":{"branchName":"X","orderLookbackDays":7,"orderCoverDays":2,"staff":["Ali"],
                     "targetFoodCostPct":0.3,"targetLaborPct":0.25,"targetPrimeCostPct":0.6,"priceAlertPct":0.05},
         "days":{"2026-08-01":{"date":"2026-08-01","entries":{"g90":{"closing":3}},"sales":[{"code":"11100","name":"M","qty":2,"amount":300}],
                               "shifts":{"e1":{"hours":9},"e2":{"worked":true,"extra":100}},"otherLabor":500},
                 "2026-08-02":{"date":"2026-08-02","entries":{},"sales":[],"shifts":{"e1":{"hours":9}},"otherLabor":200}}}
        """#
        let d = try Persistence.decode(Data(json.utf8))
        XCTAssertEqual(d.items[0].minStock, 50)
        XCTAssertEqual(d.employees, [Employee(id: "e1", name: "Murat", role: "Müdür"), Employee(id: "e2", name: "Can")])
        XCTAssertEqual(d.purchaseOrders[0].lines, [OrderLine(itemID: "g90", qty: 5, received: 5)])
        XCTAssertEqual(d.settings, AppSettings(branchName: "X", orderLookbackDays: 7, orderCoverDays: 2, staff: ["Ali"]))
        XCTAssertEqual(d.days["2026-08-01"]?.sales, [SaleLine(code: "11100", name: "M", qty: 2)])
        // Yalnızca vardiyası olan eski gün artık boş sayılır (verisi olan günlere girmez)
        XCTAssertTrue(d.days["2026-08-02"]!.isEmpty)
        XCTAssertEqual(Engine(data: d).datesWithData, ["2026-08-01"])

        let written = String(decoding: try Persistence.encoder().encode(d), as: UTF8.self)
        for key in ["unitCost", "costHistory", "unitPrice", "amount", "payType", "rate", "costFactor", "payHistory",
                    "defaultHours", "shifts", "otherLabor", "targetFoodCostPct", "targetLaborPct", "targetPrimeCostPct",
                    "priceAlertPct"] {
            XCTAssertFalse(written.contains("\"\(key)\""), key)
        }
    }

    func testExportIncludesTeam() throws {
        var data = AppData.seeded()
        data.employees = [Employee(id: "a", name: "Ayşe", role: "Kasiyer", phone: "0500 000 00 00", account: "ayse.yilmaz@envanter.local"),
                          Employee(id: "b", name: "Can", role: "Usta", active: false, endDate: "2026-08-20", note: "ayrıldı")]
        data.days["2026-08-01"] = DayRecord(date: "2026-08-01", entries: ["g90": DayEntry(opening: 5, closing: 3)])
        let sheets = try XlsxReader.read(data: Exporter.history(engine: Engine(data: data), from: "2026-08-01", to: "2026-08-02"))
        XCTAssertEqual(sheets.map { $0.name }, ["Alımlar", "Özet", "Günlük Durum", "Ekip"])
        let team = sheets[3]
        XCTAssertEqual((1...8).map { team.value(row: 1, col: $0) },
                       ["Ad", "Görev", "Telefon", "Durum", "İşe Giriş", "İşten Çıkış", "Giriş Hesabı", "Not"],
                       "tarih sütunları giriş hesabıyla karışmaz")
        XCTAssertEqual(team.value(row: 2, col: 1), "Ayşe")
        XCTAssertEqual(team.value(row: 2, col: 2), "Kasiyer")
        XCTAssertEqual(team.value(row: 2, col: 4), "Aktif")
        XCTAssertEqual(team.value(row: 2, col: 7), "ayse.yilmaz", "kullanıcı adı hesabı adıyla gösterilir")
        XCTAssertEqual(team.value(row: 3, col: 4), "Pasif")
        XCTAssertEqual(team.value(row: 3, col: 6), "20.08.2026")
        for s in sheets {
            for r in 1...max(1, s.maxRow) {
                XCTAssertFalse((s.rows[r] ?? [:]).values.contains { $0.contains("₺") || $0.contains("Maliyet") }, s.name)
            }
        }
    }
}
