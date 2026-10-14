import XCTest
@testable import EnvanterCore

/// Sayım girişi: toplayarak giriş ve kalem arama — web ile ortak vektörler (Fixtures/count-vectors.json; web
/// test/countEntry.test.ts).
final class CountEntryTests: XCTestCase {
    func testCountVectors() throws {
        let root = try VectorSupport.load("count-vectors")
        let k = root["constants"]
        XCTAssertEqual(k?["maxTerms"]?.doubleValue, Double(Fmt.countExpressionMaxTerms))
        XCTAssertEqual(k?["hint"]?.stringValue, CountEntryText.expressionHint)
        XCTAssertEqual(k?["placeholder"]?.stringValue, ItemSearch.placeholder)
        XCTAssertEqual(k?["clearLabel"]?.stringValue, ItemSearch.clearLabel)

        let cases = root["expression"]?.arrayValue ?? []
        XCTAssertGreaterThanOrEqual(cases.count, 30)
        for c in cases {
            guard let a = c.arrayValue, a.count == 3, let text = a[0].stringValue, let isKg = a[1].boolValue else {
                XCTFail("bozuk vektör \(c)"); continue
            }
            let got = Fmt.parseCountExpression(text, isKg: isKg)
            if let want = a[2].doubleValue {
                guard let got else { XCTFail("\"\(text)\" (kg: \(isKg)): nil, beklenen \(want)"); continue }
                XCTAssertEqual(got, want, accuracy: 1e-9, "\"\(text)\" (kg: \(isKg))")
            } else {
                XCTAssertNil(got, "\"\(text)\" (kg: \(isKg)) geçersiz olmalı")
            }
        }
        for c in root["expressionText"]?.arrayValue ?? [] {
            let text = c["text"]?.stringValue ?? "", isKg = c["isKg"]?.boolValue ?? false
            let value = try XCTUnwrap(Fmt.parseCountExpression(text, isKg: isKg), text)
            XCTAssertEqual(value, c["value"]?.doubleValue ?? -1, accuracy: 1e-9, text)
            XCTAssertEqual(Fmt.countExpressionText(text, value: value, maxFraction: Int(c["maxFraction"]?.doubleValue ?? 3)),
                           c["display"]?.stringValue, text)
        }
        for c in root["search"]?.arrayValue ?? [] {
            guard let a = c.arrayValue, a.count == 4 else { XCTFail("bozuk vektör \(c)"); continue }
            let q = a[0].stringValue ?? "", name = a[1].stringValue ?? "", id = a[2].stringValue ?? ""
            XCTAssertEqual(ItemSearch.matches(name: name, id: id, query: q), a[3].boolValue, "\"\(q)\" ~ \(name) / \(id)")
        }
        for c in root["noMatch"]?.arrayValue ?? [] {
            XCTAssertEqual(ItemSearch.noMatchText(c["query"]?.stringValue ?? ""), c["text"]?.stringValue)
        }
    }

    /// Düz sayı eskisi gibi okunur (yalnızca "1.200" adet kalemde artık 1200)
    func testPlainNumbersMatchParse() {
        for s in ["7,5", "12", "0,014", "1.234,5", "1,234.5"] {
            XCTAssertEqual(Fmt.parseCountExpression(s, isKg: true), Fmt.parse(s), s)
            XCTAssertEqual(Fmt.parseCountExpression(s, isKg: false), Fmt.parseQuantity(s), s)
        }
        XCTAssertEqual(Fmt.parse("1.200"), 1.2)
        XCTAssertEqual(Fmt.parseCountExpression("1.200", isKg: false), 1200)
    }
}
