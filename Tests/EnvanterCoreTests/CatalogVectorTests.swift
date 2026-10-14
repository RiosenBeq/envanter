import XCTest
@testable import EnvanterCore

/// Ortak stok kalemi vektörleri (Fixtures/catalog-vectors.json; web: test/catalogVectors.test.ts aynı dosyayı okur):
/// silme (kapatılmış günlere dokunulmaz), kullanılmış kimlikler, yeni kimlik, ad denetimi, geçmiş, onay metinleri ve
/// "Yeni kalem olarak aç" (metinleri ve açık sipariş engeli) ve eksik tanımları ekleme.
final class CatalogVectorTests: XCTestCase {
    private func vectors() throws -> JSONValue {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/catalog-vectors", withExtension: "json"))
        return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    }

    private func data(_ v: JSONValue, extraItems: JSONValue? = nil) throws -> AppData {
        let items = (v["items"]?.arrayValue ?? []) + (extraItems?.arrayValue ?? [])
        return try JSONCoding.decode(AppData.self, from: .object([
            "items": .array(items), "products": v["products"] ?? .array([]),
            "days": v["days"] ?? .object([:]), "purchaseOrders": v["orders"] ?? .array([]),
        ]))
    }

    private func amounts(_ d: AppData) throws -> JSONValue {
        var out: [String: JSONValue] = [:]
        for p in d.products { out[p.code] = try JSONCoding.value(p.amounts) }
        return .object(out)
    }

    /// Günün karşılaştırılan alanları: entries, legacySold, legacyWaste (varsa)
    private func dayView(_ day: DayRecord?) throws -> JSONValue {
        guard let day else { return .null }
        var out: [String: JSONValue] = ["entries": try JSONCoding.value(day.entries)]
        if let s = day.legacySold { out["legacySold"] = try JSONCoding.value(s) }
        if let w = day.legacyWaste { out["legacyWaste"] = try JSONCoding.value(w) }
        return .object(out)
    }

    private func name(_ c: JSONValue) -> String { c["name"]?.stringValue ?? c["itemID"]?.stringValue ?? "?" }

    func testDeleteItemKeepsLockedDays() throws {
        let v = try vectors()
        let input = try data(v)
        for c in v["delete"]?.arrayValue ?? [] {
            let r = CatalogOps.deleteItem(c["itemID"]?.stringValue ?? "", in: input)
            let e = try XCTUnwrap(c["expected"])
            XCTAssertEqual(r.data.items.map { JSONValue.string($0.id) }, e["items"]?.arrayValue, name(c))
            XCTAssertEqual(try amounts(r.data), e["products"], name(c))
            for (date, expected) in e["days"]?.objectValue ?? [:] {
                XCTAssertEqual(try dayView(r.data.days[date]), expected, "\(name(c)): \(date)")
            }
            XCTAssertEqual(Double(r.products), e["counts"]?["products"]?.doubleValue, name(c))
            XCTAssertEqual(Double(r.days), e["counts"]?["days"]?.doubleValue, name(c))
            XCTAssertEqual(Double(r.keptLockedDays), e["counts"]?["keptLockedDays"]?.doubleValue, name(c))
            // Kapatılmış günler birebir aynı kalır
            for (date, day) in input.days where day.isLocked { XCTAssertEqual(r.data.days[date], day, "\(name(c)): \(date)") }
        }
    }

    func testReservedAndNewIDs() throws {
        let v = try vectors()
        let input = try data(v)
        func after(_ c: JSONValue) -> AppData {
            guard let id = c["deleteFirst"]?.stringValue else { return input }
            return CatalogOps.deleteItem(id, in: input).data
        }
        for c in v["reserved"]?.arrayValue ?? [] {
            XCTAssertEqual(CatalogOps.reservedItemIDs(after(c)).sorted().map { JSONValue.string($0) }, c["expected"]?.arrayValue, name(c))
        }
        for c in v["newID"]?.arrayValue ?? [] {
            XCTAssertEqual(CatalogOps.newItemID(name: c["itemName"]?.stringValue ?? "", data: after(c)), c["expected"]?.stringValue, name(c))
        }
        for c in v["named"]?.arrayValue ?? [] {
            XCTAssertEqual(CatalogOps.hasItemNamed(c["name"]?.stringValue ?? "", in: input.items, except: c["exceptID"]?.stringValue),
                           c["expected"]?.boolValue, "\(name(c)) / \(c["exceptID"]?.stringValue ?? "-")")
        }
        XCTAssertEqual(CatalogOps.duplicateTitle, v["duplicate"]?["title"]?.stringValue)
        for c in v["duplicate"]?["cases"]?.arrayValue ?? [] {
            XCTAssertEqual(CatalogOps.duplicateMessage(c["name"]?.stringValue ?? ""), c["expected"]?.stringValue)
        }
    }

    /// Elle zayi kayıtları (`wasteLog`): silmede kalemin açık günlerdeki kayıtları çıkar (`[]` kalır), kapatılmış günlere
    /// dokunulmaz; kayıtta geçen kimlik geçmiş sayılır ve yeniden kullanılmaz
    func testWasteLogEntries() throws {
        let v = try vectors()
        let w = try XCTUnwrap(v["wasteLog"])
        var input = try data(v)
        for (date, raw) in w["days"]?.objectValue ?? [:] { input.days[date] = try JSONCoding.decode(DayRecord.self, from: raw) }
        func view(_ day: DayRecord?) throws -> JSONValue {
            guard let day else { return .null }
            var out: [String: JSONValue] = ["entries": try JSONCoding.value(day.entries)]
            if let log = day.wasteLog { out["wasteLog"] = .array(log.map { .string($0.id) }) }
            return .object(out)
        }
        for c in w["delete"]?.arrayValue ?? [] {
            let r = CatalogOps.deleteItem(c["itemID"]?.stringValue ?? "", in: input)
            for (date, expected) in c["expected"]?["days"]?.objectValue ?? [:] {
                XCTAssertEqual(try view(r.data.days[date]), expected, "\(name(c)): \(date)")
            }
            XCTAssertEqual(Double(r.days), c["expected"]?["counts"]?["days"]?.doubleValue, name(c))
            XCTAssertEqual(Double(r.keptLockedDays), c["expected"]?["counts"]?["keptLockedDays"]?.doubleValue, name(c))
            for (date, day) in input.days where day.isLocked { XCTAssertEqual(r.data.days[date], day, "\(name(c)): \(date)") }
        }
        for c in w["history"]?.arrayValue ?? [] {
            let h = CatalogOps.history(c["itemID"]?.stringValue ?? "", in: input)
            XCTAssertEqual(Double(h.days), c["expected"]?["days"]?.doubleValue, name(c))
            XCTAssertEqual(Double(h.lockedDays), c["expected"]?["lockedDays"]?.doubleValue, name(c))
        }
        for c in w["newID"]?.arrayValue ?? [] {
            XCTAssertEqual(CatalogOps.newItemID(name: c["itemName"]?.stringValue ?? "", data: input), c["expected"]?.stringValue, name(c))
        }
    }

    func testHistoryAndTexts() throws {
        let v = try vectors()
        let input = try data(v)
        for c in v["history"]?.arrayValue ?? [] {
            let h = CatalogOps.history(c["itemID"]?.stringValue ?? "", in: input)
            let e = c["expected"]
            let got: [String: JSONValue] = [
                "days": .number(Double(h.days)), "lockedDays": .number(Double(h.lockedDays)), "products": .number(Double(h.products)),
                "recipes": .number(Double(h.recipes)), "orders": .number(Double(h.orders)), "openOrders": .number(Double(h.openOrders)),
                "salesDays": .number(Double(h.salesDays)),
                "lockedSalesDays": .number(Double(h.lockedSalesDays)), "suggestsDeactivate": .bool(h.suggestsDeactivate),
            ]
            XCTAssertEqual(JSONValue.object(got), e, name(c))
        }
        for c in v["deleteText"]?.arrayValue ?? [] {
            let text = CatalogOps.deleteDescription(openDays: Int(c["openDays"]?.doubleValue ?? -1), products: Int(c["products"]?.doubleValue ?? -1),
                                                    lockedDays: Int(c["lockedDays"]?.doubleValue ?? -1))
            XCTAssertEqual(text, c["expected"]?.stringValue)
        }
        for c in v["historyDeleteText"]?.arrayValue ?? [] {
            XCTAssertEqual(CatalogOps.deleteDescription(CatalogOps.history(c["itemID"]?.stringValue ?? "", in: input)), c["expected"]?.stringValue, name(c))
        }
        for c in v["unit"]?.arrayValue ?? [] {
            let id = c["itemID"]?.stringValue ?? ""
            let item = try XCTUnwrap(input.items.first { $0.id == id }, name(c))
            let h = CatalogOps.history(id, in: input)
            XCTAssertEqual(CatalogOps.unitChangeNeedsConfirmation(h), c["needsConfirmation"]?.boolValue, name(c))
            XCTAssertEqual(CatalogOps.unitChangeMessage(item: item, newUnit: c["newUnit"]?.stringValue ?? "", days: h.days), c["expected"]?.stringValue, name(c))
        }
        for c in v["factor"]?.arrayValue ?? [] {
            let h = CatalogOps.history(c["itemID"]?.stringValue ?? "", in: input)
            XCTAssertEqual(CatalogOps.factorChangeNeedsConfirmation(h), c["needsConfirmation"]?.boolValue, name(c))
            XCTAssertEqual(CatalogOps.factorChangeMessage(h), c["expected"]?.stringValue, name(c))
        }
    }

    func testSplitForUnit() throws {
        let v = try vectors()
        for c in v["split"]?.arrayValue ?? [] {
            let input = try data(v, extraItems: c["extraItems"])
            let id = c["itemID"]?.stringValue ?? "", unit = c["unit"]?.stringValue ?? ""
            let r = CatalogOps.splitForUnit(id, unit: unit, in: input)
            guard let e = c["expected"], !e.isNull else { XCTAssertNil(r, name(c)); continue }
            let s = try XCTUnwrap(r, name(c))
            XCTAssertEqual(s.newID, e["newID"]?.stringValue, name(c))
            XCTAssertEqual(s.oldName, e["oldName"]?.stringValue, name(c))
            XCTAssertEqual(try JSONCoding.value(s.data.items), e["items"], name(c))
            XCTAssertEqual(try amounts(s.data), e["products"], name(c))
            // Günlere dokunulmaz (sayım geçmişi eski kalemde kalır)
            XCTAssertEqual(s.data.days, input.days, name(c))
            let item = try XCTUnwrap(input.items.first { $0.id == id })
            let moved = CatalogOps.history(id, in: input).recipes
            XCTAssertEqual(CatalogOps.splitMessage(name: item.name, unit: unit, oldName: s.oldName, recipeUnit: item.recipeUnit, movedRecipes: moved),
                           e["message"]?.stringValue, name(c))
        }
    }

    func testSplitTextsAndOpenOrders() throws {
        let v = try vectors()
        for c in v["splitTexts"]?.arrayValue ?? [] {
            let input = try data(v, extraItems: c["extraItems"])
            let id = c["itemID"]?.stringValue ?? "", unit = c["unit"]?.stringValue ?? ""
            let item = try XCTUnwrap(input.items.first { $0.id == id }, name(c))
            let h = CatalogOps.history(id, in: input)
            let oldName = CatalogOps.splitOldName(item, in: input.items)
            XCTAssertEqual(oldName, c["oldName"]?.stringValue, name(c))
            XCTAssertEqual(CatalogOps.splitBlocked(h), c["blocked"]?.boolValue, name(c))
            XCTAssertEqual(CatalogOps.splitExplanation(item: item, newUnit: unit, oldName: oldName, movedRecipes: h.recipes),
                           c["explanation"]?.stringValue, name(c))
            if let m = c["blockedMessage"]?.stringValue {
                XCTAssertEqual(CatalogOps.splitBlockedMessage(item: item, openOrders: h.openOrders), m, name(c))
            }
            // splitForUnit aynı adı kullanır; açık siparişte bölünmez
            let r = CatalogOps.splitForUnit(id, unit: unit, in: input)
            if c["blocked"]?.boolValue == true { XCTAssertNil(r, name(c)) } else { XCTAssertEqual(r?.oldName, c["oldName"]?.stringValue, name(c)) }
        }
    }

    func testMergeDefinitions() throws {
        let v = try vectors()
        for c in v["merge"]?.arrayValue ?? [] {
            var input = try data(v, extraItems: c["extraItems"])
            if let id = c["deleteFirst"]?.stringValue { input = CatalogOps.deleteItem(id, in: input).data }
            let remove = Set((c["removeProducts"]?.arrayValue ?? []).compactMap { $0.stringValue })
            input.products.removeAll { remove.contains($0.code) }
            let items = try JSONCoding.decode([Item].self, from: c["source"]?["items"] ?? .array([]))
            let products = try JSONCoding.decode([Product].self, from: c["source"]?["products"] ?? .array([]))
            let r = CatalogOps.mergeDefinitions(items: items, products: products, into: input)
            let e = try XCTUnwrap(c["expected"])
            XCTAssertEqual(try JSONCoding.value(r.data.items), e["items"], name(c))
            XCTAssertEqual(try amounts(r.data), e["products"], name(c))
            XCTAssertEqual(Double(r.addedItems), e["addedItems"]?.doubleValue, name(c))
            XCTAssertEqual(Double(r.addedProducts), e["addedProducts"]?.doubleValue, name(c))
            // Günlere ve siparişlere dokunulmaz
            XCTAssertEqual(r.data.days, input.days, name(c))
            XCTAssertEqual(r.data.purchaseOrders, input.purchaseOrders, name(c))
        }
    }
}
