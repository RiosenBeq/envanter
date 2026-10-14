import XCTest
@testable import EnvanterCore

/// Ortak sürüm ve gün dönümü vektörleri (Fixtures/version-vectors.json; web: test/versionVectors.test.ts aynı dosyayı
/// okur): veri biçimi düzeyi, canlı durumdaki `fmt`, kanalda daha yeni sürüm ve gün dönümü kararı.
final class VersionVectorTests: XCTestCase {
    private func vectors() throws -> JSONValue {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/version-vectors", withExtension: "json"))
        return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    }

    func testLevelAndPresenceFormat() throws {
        let v = try vectors()
        XCTAssertEqual(Double(DataFormat.level), v["level"]?.doubleValue)
        for c in v["presenceFormat"]?.arrayValue ?? [] {
            let meta = try XCTUnwrap(c["meta"]?.objectValue)
            XCTAssertEqual(Double(DataFormat.level(ofPresence: meta)), c["expected"]?.doubleValue, c["name"]?.stringValue ?? "?")
        }
        // Mac'in kendi bildirdiği düzey okunduğunda aynı çıkar
        let own = RealtimePresence.mac(branch: "Tuzla", app: "2.1", since: Date())
        XCTAssertEqual(DataFormat.level(ofPresence: own), DataFormat.level)
    }

    func testNewerPeer() throws {
        let v = try vectors()
        for c in v["newerPeer"]?.arrayValue ?? [] {
            var presence: [String: [JSONValue]] = [:]
            for (k, metas) in c["presence"]?.objectValue ?? [:] { presence[k] = metas.arrayValue ?? [] }
            let got = DataFormat.newerPeerLevel(in: presence, ownKey: c["ownKey"]?.stringValue ?? "")
            XCTAssertEqual(got.map(Double.init), c["expected"]?.doubleValue, c["name"]?.stringValue ?? "?")
        }
        for c in v["newerPeerMessage"]?.arrayValue ?? [] {
            XCTAssertEqual(DataFormat.newerPeerMessage(Int(c["level"]?.doubleValue ?? 0)), c["expected"]?.stringValue)
        }
    }

    func testRollover() throws {
        let v = try vectors()
        for c in v["rollover"]?.arrayValue ?? [] {
            let d = DayRollover.decide(selected: c["selected"]?.stringValue ?? "", previousToday: c["previousToday"]?.stringValue ?? "",
                                       today: c["today"]?.stringValue ?? "", editing: c["editing"]?.boolValue ?? false)
            let expected: DayRollover.Decision
            switch c["expected"]?["kind"]?.stringValue {
            case "move": expected = .move(to: c["expected"]?["date"]?.stringValue ?? "")
            case "wait": expected = .wait
            default: expected = .none
            }
            XCTAssertEqual(d, expected, c["name"]?.stringValue ?? "?")
        }
        for c in v["rolloverTitle"]?.arrayValue ?? [] {
            XCTAssertEqual(DayRollover.title(c["date"]?.stringValue ?? ""), c["expected"]?.stringValue)
        }
        XCTAssertEqual(DayRollover.backLabel, v["rolloverBack"]?.stringValue)
    }
}
