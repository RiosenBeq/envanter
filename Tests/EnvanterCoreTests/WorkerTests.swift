import XCTest
@testable import EnvanterCore

/// Paylaşılan bilgisayarda şu an çalışan — web ile ortak vektörler (Fixtures/worker-vectors.json; web test/worker.test.ts).
final class WorkerTests: XCTestCase {
    func testWorkerVectors() throws {
        let root = try VectorSupport.load("worker-vectors")
        let k = root["constants"]
        XCTAssertEqual(k?["promptTitle"]?.stringValue, SessionWorker.promptTitle)
        XCTAssertEqual(k?["promptMessage"]?.stringValue, SessionWorker.promptMessage)
        XCTAssertEqual(k?["skipLabel"]?.stringValue, SessionWorker.skipLabel)
        XCTAssertEqual(k?["changeLabel"]?.stringValue, SessionWorker.changeLabel)
        XCTAssertEqual(k?["noEmployees"]?.stringValue, SessionWorker.noEmployeesText)

        for v in root["asks"]?.arrayValue ?? [] {
            let email = v["email"]?.stringValue
            XCTAssertEqual(SessionWorker.asks(email: email), v["asks"]?.boolValue, email ?? "nil")
        }
        let options = root["options"]
        let employees = try JSONCoding.decode([Employee].self, from: options?["employees"] ?? .array([]))
        XCTAssertEqual(SessionWorker.options(employees), (options?["expect"]?.arrayValue ?? []).compactMap { $0.stringValue })
        for v in root["summary"]?.arrayValue ?? [] {
            XCTAssertEqual(SessionWorker.summary(v["base"]?.stringValue ?? "", worker: v["worker"]?.stringValue), v["expect"]?.stringValue)
        }
        for v in root["countedBy"]?.arrayValue ?? [] {
            XCTAssertEqual(SessionWorker.countedBy(current: v["current"]?.stringValue, worker: v["worker"]?.stringValue,
                                                   hasClosing: v["hasClosing"]?.boolValue ?? false),
                           v["expect"]?.stringValue, "\(v)")
        }
        for v in root["defaultBy"]?.arrayValue ?? [] {
            XCTAssertEqual(SessionWorker.defaultBy(countedBy: v["countedBy"]?.stringValue, worker: v["worker"]?.stringValue,
                                                   linkedName: v["linkedName"]?.stringValue),
                           v["expect"]?.stringValue, "\(v)")
        }
    }
}
