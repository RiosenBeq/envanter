import XCTest
@testable import EnvanterCore

/// Ortak geri alma vektörleri (Fixtures/undo-vectors.json; web: test/store/undo.test.ts aynı dosyayı okur): Mac'in
/// `DocCodec.undoing`'i ile web panelinin `undoing`'i (src/lib/store/undo.ts) işlemden sonraki değişiklikleri aynı biçimde korur.
final class UndoVectorTests: XCTestCase {
    private func vectors() throws -> [JSONValue] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/undo-vectors", withExtension: "json"))
        let v = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        return v["cases"]?.arrayValue ?? []
    }

    /// Belge gövdelerinden veri (eksik belge boş / varsayılan)
    private func data(_ docs: JSONValue?) -> AppData {
        guard case .object(let o)? = docs else { return AppData(items: [], products: []) }
        return DocCodec.assemble(o, base: AppData(items: [], products: []))
    }

    func testUndoVectors() throws {
        let cases = try vectors()
        XCTAssertGreaterThanOrEqual(cases.count, 10)
        for c in cases {
            let name = c["name"]?.stringValue ?? "?"
            let keys = Set((c["keys"]?.arrayValue ?? []).compactMap { $0.stringValue })
            let current = data(c["current"])
            let out = DocCodec.undoing(keys: keys, old: data(c["old"]), new: data(c["new"]), current: current)
            let want = data(c["expected"])
            guard case .object(let expected)? = c["expected"] else { XCTFail(name); continue }
            for k in expected.keys {
                XCTAssertEqual(DocCodec.body(for: k, in: out), DocCodec.body(for: k, in: want), "\(name): \(k)")
            }
            // İşlemin anahtarları dışındaki belgelere dokunulmaz
            for k in DocKey.catalog where !keys.contains(k) {
                XCTAssertEqual(DocCodec.body(for: k, in: out), DocCodec.body(for: k, in: current), "\(name): \(k)")
            }
        }
    }
}
