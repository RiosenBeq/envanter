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

    /// Çalışan yalnızca seçildiği cihaz hesabıyla bağlıyken geçerlidir (çıkış, kişisel hesap, başka cihaz hesabı: yok)
    func testActiveWorkerFollowsDeviceAccount() {
        let pc = SessionWorker.account(email: " PC-7KQ2M9@envanter.local ")
        XCTAssertEqual(pc, "pc-7kq2m9")
        XCTAssertNil(SessionWorker.account(email: "ayse.yilmaz@envanter.local"))
        XCTAssertNil(SessionWorker.account(email: nil))
        XCTAssertEqual(SessionWorker.active(" Murat A. ", chosenOn: pc, account: "pc-7kq2m9"), "Murat A.")
        // Çıkış yapıldı ya da yerel çalışılıyor; kişisel hesapla bağlı
        XCTAssertNil(SessionWorker.active("Murat A.", chosenOn: pc, account: nil))
        XCTAssertNil(SessionWorker.active("Murat A.", chosenOn: pc, account: SessionWorker.account(email: "patron@ornek.com")))
        // Başka bir cihaz hesabı; henüz sorulmadı
        XCTAssertNil(SessionWorker.active("Murat A.", chosenOn: pc, account: SessionWorker.account(email: "pc-abcdef@envanter.local")))
        XCTAssertNil(SessionWorker.active("Murat A.", chosenOn: nil, account: pc))
        // Atlandı
        XCTAssertNil(SessionWorker.active(nil, chosenOn: pc, account: pc))
        XCTAssertNil(SessionWorker.active("  ", chosenOn: pc, account: pc))
    }
}
