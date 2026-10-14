import XCTest
@testable import EnvanterCore

/// Ortak stok kalemi vektörleri (Fixtures/catalog-vectors.json; web: test/catalogVectors.test.ts aynı dosyayı okur):
/// silme (kapatılmış günlere dokunulmaz), kullanılmış kimlikler, yeni kimlik, ad denetimi, geçmiş, onay metinleri ve
/// "Yeni kalem olarak aç".
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

    func testHistoryAndTexts() throws {
        let v = try vectors()
        let input = try data(v)
        for c in v["history"]?.arrayValue ?? [] {
            let h = CatalogOps.history(c["itemID"]?.stringValue ?? "", in: input)
            let e = c["expected"]
            let got: [String: JSONValue] = [
                "days": .number(Double(h.days)), "lockedDays": .number(Double(h.lockedDays)), "products": .number(Double(h.products)),
                "recipes": .number(Double(h.recipes)), "orders": .number(Double(h.orders)), "salesDays": .number(Double(h.salesDays)),
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
}
