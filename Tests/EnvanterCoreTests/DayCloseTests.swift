import XCTest
@testable import EnvanterCore

/// Gün kapatma kontrol listesi, kapatılmamış günler ve personelin eski güne giriş uyarısı — web ile ortak vektörler
/// (Fixtures/dayclose-vectors.json; web test/dayClose.test.ts).
final class DayCloseTests: XCTestCase {
    private func lines(_ c: DayCloseCheck) -> JSONValue {
        .array(c.lines.map { .object(["kind": .string($0.kind), "tone": .string($0.tone.rawValue), "text": .string($0.text)]) })
    }

    func testDayCloseVectors() throws {
        let root = try VectorSupport.load("dayclose-vectors")
        let k = root["constants"]
        XCTAssertEqual(k?["closeLabel"]?.stringValue, DayCloseCheck.closeLabel)
        XCTAssertEqual(k?["closeAnywayLabel"]?.stringValue, DayCloseCheck.closeAnywayLabel)
        XCTAssertEqual(k?["showUncountedLabel"]?.stringValue, DayCloseCheck.showUncountedLabel)
        XCTAssertEqual(k?["staffRule"]?.stringValue, DayCloseCheck.staffRule)
        XCTAssertEqual(k?["managerRule"]?.stringValue, DayCloseCheck.managerRule)
        XCTAssertEqual(k?["unknownStaffNote"]?.stringValue, DayCloseCheck.unknownStaffNote)
        XCTAssertEqual(k?["unclosedLookbackDays"]?.doubleValue, Double(UnclosedDays.lookbackDays))
        XCTAssertEqual(k?["unclosedSubtitle"]?.stringValue, UnclosedDays.subtitle)
        XCTAssertEqual(k?["unclosedEmpty"]?.stringValue, UnclosedDays.emptyText)
        XCTAssertEqual(k?["closeSelectedLabel"]?.stringValue, UnclosedDays.closeSelectedLabel)
        XCTAssertEqual(k?["unclosedDismissLabel"]?.stringValue, UnclosedDays.dismissLabel)
        XCTAssertEqual(k?["unclosedBadgeHelp"]?.stringValue, UnclosedDays.badgeHelp)
        XCTAssertEqual(k?["oldDayDays"]?.doubleValue, Double(OldDayWarning.days))
        XCTAssertEqual(k?["oldDayTitle"]?.stringValue, OldDayWarning.title)
        XCTAssertEqual(DayLockAction.confirmMessage, DayCloseCheck.staffRule)

        for t in root["texts"]?.arrayValue ?? [] {
            let date = t["date"]?.stringValue ?? ""
            XCTAssertEqual(DayCloseCheck.title(date: date), t["title"]?.stringValue)
            XCTAssertEqual(DayLockAction.confirmTitle(date: date), t["title"]?.stringValue)
            XCTAssertEqual(DayCloseCheck.closedText(date: date), t["closed"]?.stringValue)
            XCTAssertEqual(OldDayWarning.message(date: date), t["oldDayMessage"]?.stringValue)
        }
        for t in root["counts"]?.arrayValue ?? [] {
            let n = Int(t["count"]?.doubleValue ?? 0)
            XCTAssertEqual(UnclosedDays.title(n), t["title"]?.stringValue)
            XCTAssertEqual(UnclosedDays.closedText(n), t["closed"]?.stringValue)
            XCTAssertEqual(UnclosedDays.badge(n), t["badge"]?.stringValue)
        }

        let evaluate = root["evaluate"]?.arrayValue ?? []
        XCTAssertGreaterThanOrEqual(evaluate.count, 6)
        for v in evaluate {
            let name = v["name"]?.stringValue ?? "?"
            let i = v["input"]
            let c = DayCloseCheck.evaluate(counted: Int(i?["counted"]?.doubleValue ?? 0), total: Int(i?["total"]?.doubleValue ?? 0),
                                           hasSales: i?["hasSales"]?.boolValue ?? false,
                                           unknownLines: Int(i?["unknownLines"]?.doubleValue ?? 0),
                                           problemItems: Int(i?["problemItems"]?.doubleValue ?? 0),
                                           canChangeLockedDay: i?["canChangeLockedDay"]?.boolValue ?? false)
            let actual: [String: JSONValue] = [
                "needsConfirm": .bool(c.needsConfirm), "allOK": .bool(c.allOK), "confirmLabel": .string(c.confirmLabel),
                "hasUncounted": .bool(c.hasUncounted), "missingSales": .bool(c.missingSales), "lines": lines(c),
                "ruleText": .string(c.ruleText), "message": .string(c.message),
            ]
            var expected = v.objectValue ?? [:]
            expected["name"] = nil
            expected["input"] = nil
            VectorSupport.check(actual, .object(expected), name)
        }

        let unclosed = root["unclosed"]
        let engine = Engine(data: try VectorSupport.appData(unclosed?["data"]))
        for v in unclosed?["cases"]?.arrayValue ?? [] {
            let name = v["name"]?.stringValue ?? "?"
            let list = UnclosedDays.list(engine: engine, asOf: v["asOf"]?.stringValue ?? "",
                                         lookbackDays: Int(v["lookbackDays"]?.doubleValue ?? 60),
                                         canChangeLockedDay: v["canChangeLockedDay"]?.boolValue ?? false)
            let actual: JSONValue = .array(list.map {
                .object(["date": .string($0.date), "needsConfirm": .bool($0.check.needsConfirm), "allOK": .bool($0.check.allOK),
                         "lines": lines($0.check)])
            })
            VectorSupport.match(actual, v["expect"] ?? .null, name)
            XCTAssertEqual(UnclosedDays.preselected(list), (v["preselected"]?.arrayValue ?? []).compactMap { $0.stringValue }, name)
        }

        for v in root["oldDay"]?.arrayValue ?? [] {
            let role = v["role"]?.stringValue, date = v["date"]?.stringValue ?? "", today = v["today"]?.stringValue ?? ""
            XCTAssertEqual(OldDayWarning.applies(role: role, date: date, today: today), v["applies"]?.boolValue,
                           "\(role ?? "nil") \(date) / \(today)")
        }
    }

    /// Eski imza korunur: personelin onay metni kontrol listesinin işaretli satırları ve kuraldır
    func testConfirmDetailKeepsSignature() {
        let partial = DayLockAction.confirmDetail(counted: 14, total: 21, hasSales: false)
        XCTAssertTrue(partial.contains("⚠ Sayım eksik: 14 / 21 kalem sayıldı, 7 kalem sayılmadı."))
        XCTAssertTrue(partial.hasSuffix(DayLockAction.confirmMessage))
        XCTAssertFalse(DayLockAction.confirmDetail(counted: 0, total: 0, hasSales: true).contains("Sayım"))
    }

    /// Demo verisinde son günler kapatılmamıştır (liste boş değil) ve her biri sayılmıştır
    func testDemoDataUnclosedDays() {
        let e = Engine(data: DemoData.make(endingAt: "2026-08-31", days: 35))
        let list = UnclosedDays.list(engine: e, asOf: "2026-08-31", canChangeLockedDay: true)
        for d in list {
            let o = e.overview(date: d.date)
            XCTAssertTrue(o.hasAnyCount && !o.isLocked, d.date)
        }
        XCTAssertEqual(list.map { $0.date }, list.map { $0.date }.sorted(by: >))
    }
}
