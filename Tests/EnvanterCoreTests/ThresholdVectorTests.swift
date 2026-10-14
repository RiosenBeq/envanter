import XCTest
@testable import EnvanterCore

/// Tolerans / kritik seviye önerileri ve kurulum listesi — web ile ortak vektörler (Fixtures/threshold-vectors.json;
/// web test/thresholds.test.ts).
final class ThresholdVectorTests: XCTestCase {
    func testThresholdVectors() throws {
        let root = try VectorSupport.load("threshold-vectors")
        XCTAssertEqual(root["minDays"]?.doubleValue, Double(Engine.thresholdMinDays))
        XCTAssertEqual(root["lookbackDays"]?.doubleValue, Double(Engine.thresholdLookbackDays))
        for c in root["cases"]?.arrayValue ?? [] {
            let name = c["name"]?.stringValue ?? "?"
            let engine = Engine(data: try VectorSupport.appData(c["data"]))
            for v in c["suggestions"]?.arrayValue ?? [] {
                let date = v["date"]?.stringValue ?? ""
                let got = engine.thresholdSuggestions(asOf: date, lookbackDays: Int(v["lookbackDays"]?.doubleValue ?? 28))
                let actual: [JSONValue] = got.map {
                    .object(["itemID": .string($0.itemID), "tolerance": VectorSupport.num($0.tolerance), "countedDays": .number(Double($0.countedDays)),
                             "minStock": VectorSupport.num($0.minStock), "dailyUsage": .number($0.dailyUsage), "usageDays": .number(Double($0.usageDays))])
                }
                VectorSupport.match(.array(actual), v["expect"] ?? .null, "\(name) \(date)")
            }
            for v in c["changes"]?.arrayValue ?? [] {
                let date = v["date"]?.stringValue ?? ""
                let changes = ThresholdChange.changes(items: engine.data.items,
                                                      suggestions: engine.thresholdSuggestions(asOf: date, lookbackDays: Int(v["lookbackDays"]?.doubleValue ?? 28)))
                let actual: [JSONValue] = changes.map {
                    .object(["itemID": .string($0.itemID), "field": .string($0.field.rawValue), "current": VectorSupport.num($0.current),
                             "suggested": .number($0.suggested), "preselected": .bool($0.preselected)])
                }
                VectorSupport.match(.array(actual), v["expect"] ?? .null, "\(name) değişiklikler \(date)")
                XCTAssertEqual(Double(ThresholdChange.itemCount(changes)), v["items"]?.doubleValue, name)
                // Uygulanınca önerilen değerler yazılır, tekrar hesaplanınca değişiklik kalmaz
                var items = engine.data.items
                ThresholdChange.apply(changes, to: &items)
                XCTAssertTrue(ThresholdChange.changes(items: items, suggestions: engine.thresholdSuggestions(asOf: date)).isEmpty, name)
            }
            for v in c["gaps"]?.arrayValue ?? [] {
                let date = v["date"]?.stringValue ?? ""
                let gaps = ThresholdGaps.make(items: engine.data.items,
                                              suggestions: engine.thresholdSuggestions(asOf: date, lookbackDays: Int(v["lookbackDays"]?.doubleValue ?? 28)))
                XCTAssertEqual(gaps.tolerance, (v["expect"]?["tolerance"]?.arrayValue ?? []).compactMap { $0.stringValue }, name)
                XCTAssertEqual(gaps.minStock, (v["expect"]?["minStock"]?.arrayValue ?? []).compactMap { $0.stringValue }, name)
                let names: ([String]) -> [String] = { ids in ids.map { id in engine.data.items.first { $0.id == id }?.name ?? id } }
                XCTAssertEqual(ThresholdGaps.text(.tolerance, names: names(gaps.tolerance)), v["text"]?["tolerance"]?.stringValue, name)
                XCTAssertEqual(ThresholdGaps.text(.minStock, names: names(gaps.minStock)), v["text"]?["minStock"]?.stringValue, name)
            }
            for v in c["setup"]?.arrayValue ?? [] {
                let date = v["date"]?.stringValue ?? ""
                let s = SetupChecklist.make(engine: engine, date: date, computerLinked: v["computerLinked"]?.boolValue ?? false)
                let actual: [String: JSONValue] = [
                    "activeItems": .number(Double(s.activeItems)), "withTolerance": .number(Double(s.withTolerance)),
                    "withMinStock": .number(Double(s.withMinStock)), "unknownProducts": .number(Double(s.unknownProducts)),
                    "computerLinked": .bool(s.computerLinked), "toleranceDone": .bool(s.toleranceDone), "minStockDone": .bool(s.minStockDone),
                    "recipesDone": .bool(s.recipesDone), "isDone": .bool(s.isDone),
                ]
                VectorSupport.check(actual, v["expect"], "\(name) kurulum \(date)")
            }
        }
    }

    func testThresholdGapTextShortensLongList() throws {
        let root = try VectorSupport.load("threshold-vectors")
        let names = (root["gapNames"]?["names"]?.arrayValue ?? []).compactMap { $0.stringValue }
        XCTAssertEqual(ThresholdGaps.text(.minStock, names: names), root["gapNames"]?["minStock"]?.stringValue)
        XCTAssertNil(ThresholdGaps.text(.tolerance, names: []))
    }

    func testRoundUpIgnoresFloatResidue() {
        XCTAssertEqual(Engine.roundUp(0.07, step: 0.01, atLeastOneStep: true), 0.07)
        XCTAssertEqual(Engine.roundUp(0.0701, step: 0.01, atLeastOneStep: true), 0.08)
        XCTAssertEqual(Engine.roundUp(0, step: 0.01, atLeastOneStep: true), 0.01)
        XCTAssertEqual(Engine.roundUp(0, step: 1, atLeastOneStep: false), 0)
        XCTAssertEqual(Engine.roundUp(5.4, step: 1, atLeastOneStep: false), 6)
        XCTAssertEqual(Engine.roundUp(0.5025, step: 0.1, atLeastOneStep: false), 0.6)
    }

    /// Demo verisi her günü saydığından yeni hesaplar eski sonuçları değiştirmez: açılışlar önceki sayımdan, ilk sayım
    /// ya da açılış sıçraması yok; tahmini stok sayılan kalemlerde kapanışa eşit.
    func testDemoDataKeepsOldResults() {
        let e = Engine(data: DemoData.make(endingAt: "2026-08-31", days: 35))
        let rows = e.calc(date: "2026-08-15").rows
        XCTAssertTrue(rows.allSatisfy { $0.openingSource == .closing && !$0.isBaseline && $0.openingJump == nil })
        XCTAssertTrue(e.summary(from: "2026-08-01", to: "2026-08-31").allSatisfy { $0.openingAdjust == 0 })
        for est in e.stockEstimates(date: "2026-08-15") {
            XCTAssertTrue(est.counted)
            XCTAssertEqual(est.stock, rows.first { $0.itemID == est.itemID }?.closing ?? -1, accuracy: 1e-9)
        }
        XCTAssertGreaterThan(e.thresholdSuggestions(asOf: "2026-08-31").count, 10)
    }
}
