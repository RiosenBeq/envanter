import XCTest
@testable import EnvanterCore

/// Ortak sipariş vektörleri (Fixtures/purchasing-vectors.json; web: test/purchasingVectors.test.ts aynı dosyayı okur):
/// taslak, düzenleme, yeniden açma, teslim alma (Gelen'e ekleyerek / eklemeden), elle girilmiş Gelen ipucu, bekleme
/// süresi ve sipariş metni.
final class PurchasingVectorTests: XCTestCase {
    private func vectors() throws -> JSONValue {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/purchasing-vectors", withExtension: "json"))
        return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    }

    private func data(_ v: JSONValue, _ c: JSONValue) throws -> AppData {
        try JSONCoding.decode(AppData.self, from: .object([
            "items": v["items"] ?? .array([]), "products": .array([]),
            "purchaseOrders": c["orders"] ?? .array([]), "days": c["days"] ?? .object([:]),
        ]))
    }

    private func lines(_ v: JSONValue?) throws -> [OrderLine] { try JSONCoding.decode([OrderLine].self, from: v ?? .array([])) }
    private func order(_ v: JSONValue?) throws -> PurchaseOrder { try JSONCoding.decode(PurchaseOrder.self, from: try XCTUnwrap(v)) }
    private func name(_ c: JSONValue) -> String { c["name"]?.stringValue ?? "?" }

    private func expectError(_ c: JSONValue, _ f: () throws -> Void) {
        let code = c["expected"]?["error"]?.stringValue
        XCTAssertThrowsError(try f(), name(c)) { XCTAssertEqual(($0 as? Purchasing.Failure)?.code, code, name(c)) }
    }

    func testDraft() throws {
        let v = try vectors()
        for c in v["draft"]?.arrayValue ?? [] {
            let make = { try Purchasing.orderFromDraft(date: c["date"]?.stringValue ?? "", supplier: c["supplier"]?.stringValue ?? "",
                                                       note: c["note"]?.stringValue, lines: try self.lines(c["lines"]),
                                                       id: c["id"]?.stringValue ?? "") }
            if c["expected"]?["error"] != nil { expectError(c) { _ = try make() }; continue }
            XCTAssertEqual(try make(), try order(c["expected"]?["order"]), name(c))
        }
    }

    func testUpdateAndReopen() throws {
        let v = try vectors()
        for c in v["update"]?.arrayValue ?? [] {
            var d = try data(v, c)
            let id = c["orderID"]?.stringValue ?? ""
            let run = { try Purchasing.updateOrder(orderID: id, supplier: c["supplier"]?.stringValue ?? "", note: c["note"]?.stringValue,
                                                   lines: try self.lines(c["lines"]), data: &d) }
            if c["expected"]?["error"] != nil {
                let before = d.purchaseOrders
                expectError(c, run)
                XCTAssertEqual(d.purchaseOrders, before, "hata: \(name(c))")
                continue
            }
            try run()
            XCTAssertEqual(d.purchaseOrders.first { $0.id == id }, try order(c["expected"]?["order"]), name(c))
        }
        for c in v["reopen"]?.arrayValue ?? [] {
            var d = try data(v, c)
            let id = c["orderID"]?.stringValue ?? ""
            Purchasing.reopen(orderID: id, data: &d)
            XCTAssertEqual(d.purchaseOrders.first { $0.id == id }?.status.rawValue, c["expectedStatus"]?.stringValue, name(c))
        }
    }

    func testReceive() throws {
        let v = try vectors()
        for c in v["receive"]?.arrayValue ?? [] {
            var d = try data(v, c)
            let id = c["orderID"]?.stringValue ?? "", date = c["date"]?.stringValue ?? ""
            var q: [String: Double] = [:]
            for (k, x) in c["quantities"]?.objectValue ?? [:] { q[k] = x.doubleValue }
            let add = c["addToIncoming"]?.boolValue ?? true
            if c["expected"]?["error"] != nil {
                let before = (d.purchaseOrders, d.days)
                expectError(c) { _ = try Purchasing.receive(orderID: id, on: date, quantities: q, addToIncoming: add, data: &d) }
                XCTAssertEqual(d.purchaseOrders, before.0, name(c))
                XCTAssertEqual(d.days, before.1, name(c))
                continue
            }
            let n = try Purchasing.receive(orderID: id, on: date, quantities: q, addToIncoming: add, data: &d)
            XCTAssertEqual(Double(n), c["expected"]?["lines"]?.doubleValue, name(c))
            XCTAssertEqual(d.purchaseOrders.first { $0.id == id }, try order(c["expected"]?["order"]), name(c))
            for (day, items) in c["expected"]?["incoming"]?.objectValue ?? [:] {
                for (item, value) in items.objectValue ?? [:] {
                    XCTAssertEqual(d.days[day]?.entries[item]?.incoming, value.doubleValue, "\(name(c)): \(day) \(item)")
                }
            }
            for day in c["expected"]?["absentDays"]?.arrayValue ?? [] {
                XCTAssertNil(d.days[day.stringValue ?? ""], "\(name(c)): gün oluşturulmamalı")
            }
        }
    }

    func testIncomingHint() throws {
        let v = try vectors()
        for c in v["hint"]?.arrayValue ?? [] {
            let d = try data(v, c)
            let o = try XCTUnwrap(d.purchaseOrders.first { $0.id == c["orderID"]?.stringValue }, name(c))
            let hint = Purchasing.incomingHint(order: o, data: d, asOf: c["asOf"]?.stringValue ?? "")
            guard let e = c["expected"], !e.isNull else { XCTAssertNil(hint, name(c)); continue }
            XCTAssertEqual(hint?.date, e["date"]?.stringValue, name(c))
            let expected = (e["lines"]?.arrayValue ?? []).map {
                Purchasing.HintLine(itemID: $0["itemID"]?.stringValue ?? "", incoming: $0["incoming"]?.doubleValue ?? -1)
            }
            XCTAssertEqual(hint?.lines, expected, name(c))
        }
    }

    func testAgeStaleAndText() throws {
        let v = try vectors()
        for c in v["age"]?.arrayValue ?? [] {
            let o = PurchaseOrder(id: "a", date: c["date"]?.stringValue ?? "", lines: [],
                                  status: OrderStatus(rawValue: c["status"]?.stringValue ?? "") ?? .open)
            let asOf = c["asOf"]?.stringValue ?? ""
            let label = "\(o.date) → \(asOf) (\(o.status.rawValue))"
            XCTAssertEqual(Purchasing.age(o, asOf: asOf).map(Double.init), c["expected"]?["age"]?.doubleValue, label)
            XCTAssertEqual(Purchasing.isStale(o, asOf: asOf), c["expected"]?["stale"]?.boolValue, label)
            XCTAssertEqual(Purchasing.waitingText(o, asOf: asOf), c["expected"]?["text"]?.stringValue, label)
        }
        for c in v["stale"]?.arrayValue ?? [] {
            let d = try data(v, c)
            let stale = Purchasing.staleOrders(d.purchaseOrders, asOf: c["asOf"]?.stringValue ?? "")
            XCTAssertEqual(stale.map { $0.id }, (c["expected"]?["ids"]?.arrayValue ?? []).compactMap { $0.stringValue }, name(c))
            XCTAssertEqual(Purchasing.staleNotice(stale), c["expected"]?["notice"]?.stringValue, name(c))
        }
        let items = Dictionary(uniqueKeysWithValues: try data(v, .object([:])).items.map { ($0.id, $0) })
        for c in v["text"]?.arrayValue ?? [] {
            XCTAssertEqual(Purchasing.text(try order(c["order"]), items: items, branch: c["branch"]?.stringValue ?? ""),
                           c["expected"]?.stringValue, name(c))
        }
    }

    /// Eski belgeler `receivedWithoutIncoming` olmadan okunur; alan yalnızca true yazılır ve geri okunur
    func testReceivedWithoutIncomingRoundTrip() throws {
        let old = try JSONCoding.decode(PurchaseOrder.self, from: Lenient.order(.object([
            "id": .string("p"), "date": .string("2026-10-12"), "lines": .array([]), "status": .string("received"),
        ])) ?? .null)
        XCTAssertNil(old.receivedWithoutIncoming)
        var o = old
        o.receivedWithoutIncoming = true
        let back = try JSONCoding.decode(PurchaseOrder.self, from: Lenient.order(try JSONCoding.value(o)) ?? .null)
        XCTAssertEqual(back.receivedWithoutIncoming, true)
        XCTAssertFalse(String(decoding: try JSONCoding.encoder().encode(old), as: UTF8.self).contains("receivedWithoutIncoming"))
        // Bozuk değer okunmaz
        let bad = try JSONCoding.decode(PurchaseOrder.self, from: Lenient.order(.object([
            "id": .string("p"), "receivedWithoutIncoming": .string("evet"),
        ])) ?? .null)
        XCTAssertNil(bad.receivedWithoutIncoming)
    }

    /// Değişiklik özeti: düzenleme (miktar, kalem, tedarikçi, not) ve "Teslim alındı say"
    func testOrderChangeSummaries() throws {
        var data = AppData.seeded()
        let o = PurchaseOrder(id: "s", date: "2026-10-12", supplier: "Et", lines: [OrderLine(itemID: "g90", qty: 100), OrderLine(itemID: "peynir", qty: 2)])
        data.purchaseOrders = [o]
        let before = try JSONCoding.value(data.purchaseOrders)
        var edited = data
        try Purchasing.updateOrder(orderID: "s", supplier: "Et", note: "Sabah",
                                   lines: [OrderLine(itemID: "g90", qty: 120), OrderLine(itemID: "patates", qty: 5)], data: &edited)
        XCTAssertEqual(ChangeSummary.summarize(key: DocKey.orders, before: before, after: try JSONCoding.value(edited.purchaseOrders), data: edited),
                       "Sipariş güncellendi (Et): 90 Gr 100 → 120, Patates 5 eklendi, Peynir çıkarıldı, not güncellendi")
        var supplier = data
        try Purchasing.updateOrder(orderID: "s", supplier: "", note: nil, lines: o.lines, data: &supplier)
        XCTAssertEqual(ChangeSummary.summarize(key: DocKey.orders, before: before, after: try JSONCoding.value(supplier.purchaseOrders), data: supplier),
                       "Sipariş güncellendi (12.10.2026 siparişi): tedarikçi silindi")
        var received = data
        try Purchasing.receive(orderID: "s", on: "2026-10-13", quantities: ["peynir": 0], addToIncoming: false, data: &received)
        XCTAssertEqual(ChangeSummary.summarize(key: DocKey.orders, before: before, after: try JSONCoding.value(received.purchaseOrders), data: received),
                       "Sipariş teslim alındı (Et, 1/2 kalem, Gelen'e eklenmeden)")
        XCTAssertNil(received.days["2026-10-13"], "Gelen'e eklenmedi")
    }
}
