import XCTest
@testable import EnvanterCore

/// Ortak test vektörleri için yardımcılar: motor sonuçlarını JSON değerine çevirir ve beklenen alanlarla karşılaştırır
/// (sayılar ±1e-6, null = nil). Web paneli aynı dosyaları vitest ile geçer.
enum VectorSupport {
    static func load(_ name: String) throws -> JSONValue {
        guard let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json") else {
            throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(name).json fikstürü yok"])
        }
        return try JSONCoding.parse(Data(contentsOf: url))
    }

    static func appData(_ v: JSONValue?) throws -> AppData {
        try Persistence.decode(JSONCoding.encoder().encode(v ?? .null))
    }

    static func num(_ v: Double?) -> JSONValue { v.map { .number($0) } ?? .null }
    static func str(_ v: String?) -> JSONValue { v.map { .string($0) } ?? .null }

    static func severity(_ s: DiffSeverity?) -> JSONValue {
        guard let s else { return .null }
        switch s {
        case .zero: return .string("zero")
        case .withinTolerance: return .string("withinTolerance")
        case .shortage: return .string("shortage")
        case .surplus: return .string("surplus")
        }
    }

    static func calc(_ r: ItemCalc) -> [String: JSONValue] {
        ["opening": .number(r.opening), "openingIsAuto": .bool(r.openingIsAuto), "incoming": .number(r.incoming),
         "transferIn": .number(r.transferIn), "transferOut": .number(r.transferOut), "closing": num(r.closing),
         "sold": .number(r.sold), "waste": .number(r.waste), "actual": num(r.actual), "diff": num(r.diff),
         "severity": severity(r.severity), "belowMinimum": .bool(r.belowMinimum), "openingSource": .string(r.openingSource.rawValue),
         "openingBaseDate": str(r.openingBaseDate), "openingBaseKind": str(r.openingBaseKind?.rawValue),
         "carriedNet": .number(r.carriedNet), "carriedDays": .number(Double(r.carriedDays)), "isBaseline": .bool(r.isBaseline),
         "openingJump": num(r.openingJump), "openingJumpIsProblem": .bool(r.openingJumpIsProblem),
         "hasStaleBase": .bool(r.hasStaleBase), "isCounted": .bool(r.isCounted), "manualWaste": .number(r.manualWaste)]
    }

    static func carryDay(_ d: CarryDay) -> [String: JSONValue] {
        ["date": .string(d.date), "incoming": .number(d.incoming), "transferIn": .number(d.transferIn),
         "transferOut": .number(d.transferOut), "sold": .number(d.sold), "waste": .number(d.waste), "net": .number(d.net)]
    }

    static func summary(_ r: Engine.SummaryRow) -> [String: JSONValue] {
        ["daysCounted": .number(Double(r.daysCounted)), "firstOpening": num(r.firstOpening), "lastClosing": num(r.lastClosing),
         "incoming": .number(r.incoming), "transferIn": .number(r.transferIn), "transferOut": .number(r.transferOut),
         "sold": .number(r.sold), "waste": .number(r.waste), "actual": .number(r.actual), "diff": .number(r.diff),
         "shortageQty": .number(r.shortageQty), "shortageDays": .number(Double(r.shortageDays)),
         "openingAdjust": .number(r.openingAdjust),
         "daily": .array(r.daily.map { .object(["date": .string($0.date), "diff": .number($0.diff)]) })]
    }

    static func order(_ o: OrderSuggestion) -> [String: JSONValue] {
        ["stock": num(o.stock), "stockDate": str(o.stockDate), "countedStock": num(o.countedStock), "onOrder": .number(o.onOrder),
         "dailyUsage": .number(o.dailyUsage), "sampleDays": .number(Double(o.sampleDays)), "daysOfCover": num(o.daysOfCover),
         "target": .number(o.target), "suggested": .number(o.suggested),
         "estimate": o.estimate.map { JSONValue.object(estimate($0)) } ?? JSONValue.null]
    }

    static func estimate(_ e: StockEstimate) -> [String: JSONValue] {
        ["itemID": .string(e.itemID), "stock": .number(e.stock), "baseDate": .string(e.baseDate), "baseKind": .string(e.baseKind.rawValue),
         "baseValue": .number(e.baseValue), "counted": .bool(e.counted), "minStock": num(e.minStock), "below": .bool(e.below)]
    }

    static func check(_ actual: [String: JSONValue], _ expected: JSONValue?, _ at: String, file: StaticString = #filePath, line: UInt = #line) {
        guard case .object(let exp)? = expected else { return XCTFail("\(at): beklenen nesne yok", file: file, line: line) }
        for (k, v) in exp {
            guard let a = actual[k] else { XCTFail("\(at).\(k): alan yok", file: file, line: line); continue }
            match(a, v, "\(at).\(k)", file: file, line: line)
        }
    }

    static func match(_ a: JSONValue, _ e: JSONValue, _ at: String, file: StaticString = #filePath, line: UInt = #line) {
        switch (a, e) {
        case (.number(let x), .number(let y)):
            XCTAssertEqual(x, y, accuracy: 1e-6, at, file: file, line: line)
        case (.array(let xs), .array(let ys)):
            guard xs.count == ys.count else { return XCTFail("\(at): uzunluk \(xs.count) ≠ \(ys.count)", file: file, line: line) }
            for (i, (x, y)) in zip(xs, ys).enumerated() { match(x, y, "\(at)[\(i)]", file: file, line: line) }
        case (.object(let xo), .object(let yo)):
            for (k, v) in yo { match(xo[k] ?? .null, v, "\(at).\(k)", file: file, line: line) }
        default:
            XCTAssertEqual(a, e, at, file: file, line: line)
        }
    }
}

/// Sayılmayan gün devri, ilk sayım, devir sınırı, açılış sıçraması, dönem özeti, sipariş stoğu, tahmini stok ve
/// "Hareketsizleri Doldur" — web ile ortak vektörler (Fixtures/carry-vectors.json; web test/carry.test.ts).
final class CarryVectorTests: XCTestCase {
    func testCarryVectors() throws {
        let root = try VectorSupport.load("carry-vectors")
        XCTAssertEqual(root["carryMaxDays"]?.doubleValue, Double(Engine.carryMaxDays))
        let cases = root["cases"]?.arrayValue ?? []
        XCTAssertGreaterThanOrEqual(cases.count, 6)
        for c in cases {
            let name = c["name"]?.stringValue ?? "?"
            let engine = Engine(data: try VectorSupport.appData(c["data"]))
            func item(_ id: String) throws -> Item { try XCTUnwrap(engine.itemsByID[id], "\(name): kalem yok \(id)") }

            for v in c["calc"]?.arrayValue ?? [] {
                let date = v["date"]?.stringValue ?? "", id = v["itemID"]?.stringValue ?? ""
                let at = "\(name) \(date) \(id)"
                guard let row = engine.calc(date: date).rows.first(where: { $0.itemID == id }) else { XCTFail("\(at): satır yok"); continue }
                VectorSupport.check(VectorSupport.calc(row), v["expect"], at)
                if let text = v["text"] {
                    let it = try item(id)
                    let texts: [String: JSONValue] = [
                        "placeholder": .string(OpeningText.placeholder(row, item: it)),
                        "help": .string(OpeningText.help(row, item: it, date: date, breakdown: engine.carryBreakdown(itemID: id, date: date))),
                        "breakdownLabel": .string(OpeningText.breakdownLabel(row)),
                        "baselineHelp": .string(OpeningText.baselineHelp(row, date: date)),
                        "jumpText": VectorSupport.str(OpeningText.jumpText(row, item: it)),
                    ]
                    VectorSupport.check(texts, text, at + " metin")
                }
            }

            for v in c["breakdown"]?.arrayValue ?? [] {
                let date = v["date"]?.stringValue ?? "", id = v["itemID"]?.stringValue ?? ""
                let days = engine.carryBreakdown(itemID: id, date: date)
                VectorSupport.match(.array(days.map { .object(VectorSupport.carryDay($0)) }), v["expect"] ?? .null, "\(name) döküm \(date)")
                let it = try item(id)
                XCTAssertEqual(days.map { OpeningText.carryLine($0, item: it) }, (v["lines"]?.arrayValue ?? []).compactMap { $0.stringValue }, name)
            }

            for v in c["summary"]?.arrayValue ?? [] {
                let from = v["from"]?.stringValue ?? "", to = v["to"]?.stringValue ?? "", id = v["itemID"]?.stringValue ?? ""
                guard let r = engine.summary(from: from, to: to).first(where: { $0.item.id == id }) else { XCTFail("\(name): özet yok"); continue }
                VectorSupport.check(VectorSupport.summary(r), v["expect"], "\(name) özet \(from)–\(to)")
                XCTAssertEqual(r.diff, r.sold + r.waste - r.actual, accuracy: 1e-6, "\(name): özdeşlik")
            }

            for v in c["orders"]?.arrayValue ?? [] {
                let date = v["date"]?.stringValue ?? "", id = v["itemID"]?.stringValue ?? ""
                let list = engine.orderSuggestions(asOf: date, lookbackDays: Int(v["lookbackDays"]?.doubleValue ?? 14),
                                                   coverDays: v["coverDays"]?.doubleValue ?? 3)
                guard let o = list.first(where: { $0.item.id == id }) else { XCTFail("\(name): öneri yok"); continue }
                VectorSupport.check(VectorSupport.order(o), v["expect"], "\(name) sipariş \(date)")
                // Stoğun dayanağı Stok Kalemleri'ndeki tahminle aynı
                XCTAssertEqual(o.estimate, engine.stockEstimate(itemID: id, date: date), "\(name) sipariş tahmini \(date)")
                if let text = v["text"] {
                    VectorSupport.check(["value": .string(OrderStockText.value(o)), "note": VectorSupport.str(OrderStockText.note(o, date: date)),
                                         "help": .string(OrderStockText.help(o, date: date))], text, "\(name) sipariş metni \(date)")
                }
            }

            for v in c["estimates"]?.arrayValue ?? [] {
                let date = v["date"]?.stringValue ?? "", id = v["itemID"]?.stringValue ?? ""
                let e = engine.stockEstimate(itemID: id, date: date)
                if v["expect"]?.isNull ?? true {
                    XCTAssertNil(e, "\(name) tahmin \(date) \(id)")
                    continue
                }
                guard let e else { XCTFail("\(name) tahmin \(date) \(id): yok"); continue }
                VectorSupport.check(VectorSupport.estimate(e), v["expect"], "\(name) tahmin \(date)")
                if let text = v["text"] {
                    let it = try item(id)
                    VectorSupport.check(["value": .string(StockEstimateText.value(e, item: it)), "help": .string(StockEstimateText.help(e, item: it)),
                                         "attention": .string(StockEstimateText.attention(e, item: it))], text, "\(name) tahmin metni")
                }
                XCTAssertEqual(engine.stockEstimates(date: date).first { $0.itemID == id }, e, name)
            }

            for v in c["belowMinimumCard"]?.arrayValue ?? [] {
                let date = v["date"]?.stringValue ?? ""
                let card = BelowMinimumCard.make(engine.overview(date: date), estimates: engine.stockEstimates(date: date))
                VectorSupport.check(["value": .string(card.value), "detail": .string(card.detail), "warn": .bool(card.warn)], v["expect"], "\(name) kart \(date)")
            }

            for v in c["fill"]?.arrayValue ?? [] {
                let date = v["date"]?.stringValue ?? ""
                let r = DayOps.fillUncountedWithOpening(engine: engine, date: date)
                XCTAssertEqual(VectorSupport.str(r.refusal?.rawValue), v["expect"]?["refusal"] ?? .null, "\(name) doldur \(date)")
                let before = engine.data.days[date]
                var written: [String: JSONValue] = [:]
                for (id, e) in r.day?.entries ?? [:] where e.closing != nil && before?.entries[id]?.closing == nil {
                    written[id] = .number(e.closing ?? 0)
                }
                XCTAssertEqual(JSONValue.object(written), v["expect"]?["closings"] ?? .null, "\(name) doldur \(date)")
                XCTAssertEqual(r.count, written.count, name)
            }
        }
    }
}
