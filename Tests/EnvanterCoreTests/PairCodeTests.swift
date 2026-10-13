import Foundation
import XCTest
@testable import EnvanterCore

/// Bağlantı kodu, envanter:// bağlantısı ve kod alanı (web ile aynı vektörler)
final class PairCodeTests: XCTestCase {
    private func vectors() throws -> JSONValue {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/pair-vectors", withExtension: "json"))
        return try JSONCoding.parse(Data(contentsOf: url))
    }

    // MARK: - Ortak vektörler (envantersite: test/fixtures/pair-vectors.json)

    func testPairVectors() throws {
        let v = try vectors()
        XCTAssertEqual(v["alphabet"]?.stringValue, PairCode.alphabet)
        XCTAssertEqual(v["length"]?.doubleValue, Double(PairCode.length))
        let parse = try XCTUnwrap(v["parse"]?.arrayValue)
        let derive = try XCTUnwrap(v["derive"]?.arrayValue)
        let link = try XCTUnwrap(v["link"]?.arrayValue)
        let device = try XCTUnwrap(v["isDeviceAccount"]?.arrayValue)
        XCTAssertEqual(parse.count, 30)
        XCTAssertEqual(derive.count, 3)
        XCTAssertEqual(link.count, 2)
        XCTAssertEqual(device.count, 12)
        for row in parse {
            let input = try XCTUnwrap(row["input"]?.stringValue)
            XCTAssertEqual(PairCode.parse(input), row["code"]?.stringValue, "parse(\(input.debugDescription))")
        }
        for row in derive {
            let code = try XCTUnwrap(row["code"]?.stringValue)
            XCTAssertEqual(PairCode.display(code), row["display"]?.stringValue)
            XCTAssertEqual(PairCode.username(code), row["username"]?.stringValue)
            XCTAssertEqual(PairCode.email(code), row["email"]?.stringValue)
            XCTAssertEqual(PairCode.password(code), row["password"]?.stringValue)
            // Ekrandaki hal ve e-posta geri okunur
            XCTAssertEqual(PairCode.parse(PairCode.display(code)), code)
            XCTAssertTrue(PairCode.isDeviceAccount(PairCode.email(code)))
            XCTAssertEqual(PairCode.deviceName(forEmail: PairCode.email(code)), PairCode.username(code))
        }
        for row in link {
            let code = try XCTUnwrap(row["code"]?.stringValue)
            let server = try XCTUnwrap(row["url"]?.stringValue)
            let key = try XCTUnwrap(row["key"]?.stringValue)
            let text = try XCTUnwrap(row["link"]?.stringValue)
            XCTAssertEqual(PairLink.make(code: code, url: server, key: key), text)
            let parsed = try XCTUnwrap(PairLink.parse(try XCTUnwrap(URL(string: text))), text)
            XCTAssertEqual(parsed.code, code)
            XCTAssertEqual(parsed.url, server)
            XCTAssertEqual(parsed.key, key)
            // Bağlantı metni kod alanına yapıştırılsa da kod okunur
            XCTAssertEqual(PairCode.parse(text), code)
        }
        for row in device {
            let email = try XCTUnwrap(row["email"]?.stringValue)
            let expected = try XCTUnwrap(row["result"]?.boolValue)
            XCTAssertEqual(PairCode.isDeviceAccount(email), expected, "isDeviceAccount(\(email.debugDescription))")
        }
    }

    // MARK: - Üretme

    func testRandomCodesUseAlphabetAndParseBack() {
        var seen = Set<String>()
        for _ in 0..<300 {
            let code = PairCode.random()
            XCTAssertEqual(code.unicodeScalars.count, 16)
            XCTAssertTrue(code.unicodeScalars.allSatisfy { PairCode.alphabet.unicodeScalars.contains($0) }, code)
            XCTAssertTrue(PairCode.isCode(code))
            XCTAssertEqual(PairCode.parse(code), code)
            XCTAssertEqual(PairCode.parse(PairCode.display(code)), code)
            XCTAssertEqual(PairCode.parse(PairCode.display(code).lowercased()), code)
            XCTAssertTrue(PairCode.isDeviceAccount(PairCode.email(code)))
            seen.insert(code)
        }
        XCTAssertEqual(seen.count, 300)
    }

    /// Rastgele bayt b < 248 ise alfabe[b % 31]; 248 ve üstü atılır (web ile aynı eşit dağılım)
    func testRandomRejectionSampling() {
        var g = SequenceGenerator(values: [248, 255] + Array(repeating: [0, 30, 31, 247, 252], count: 4).flatMap { $0 })
        XCTAssertEqual(PairCode.random(using: &g), "2Z2Z2Z2Z2Z2Z2Z2Z")
        // 64 bitlik değerin yalnızca son baytı kullanılır
        var h = SequenceGenerator(values: Array(repeating: 0x1234_5678_9ABC_DE01, count: 16))
        XCTAssertEqual(PairCode.random(using: &h), String(repeating: "3", count: 16))
    }

    // MARK: - Bağlantı

    func testPairLinkParsing() throws {
        func parse(_ s: String) -> (code: String, url: String?, key: String?)? { URL(string: s).flatMap { PairLink.parse($0) } }
        let full = try XCTUnwrap(parse("envanter://baglan?kod=7kq2-m9xp-4tra-hw3d&sunucu=https%3A%2F%2Fx.supabase.co&anahtar=sb_publishable_k"))
        XCTAssertEqual(full.code, "7KQ2M9XP4TRAHW3D")
        XCTAssertEqual(full.url, "https://x.supabase.co")
        XCTAssertEqual(full.key, "sb_publishable_k")
        // Sunucu ve anahtar isteğe bağlı; boş değer yok sayılır; ad büyük/küçük harf fark etmez
        let bare = try XCTUnwrap(parse("ENVANTER://Baglan?KOD=7KQ2M9XP4TRAHW3D&sunucu="))
        XCTAssertEqual(bare.code, "7KQ2M9XP4TRAHW3D")
        XCTAssertNil(bare.url)
        XCTAssertNil(bare.key)
        XCTAssertNil(parse("envanter://baglan?kod=7KQ2-M9XP-4TRA-HW1D"))
        XCTAssertNil(parse("envanter://baglan?sunucu=https%3A%2F%2Fx.supabase.co"))
        XCTAssertNil(parse("envanter://ayarlar?kod=7KQ2-M9XP-4TRA-HW3D"))
        XCTAssertNil(parse("https://baglan?kod=7KQ2-M9XP-4TRA-HW3D"))
        XCTAssertEqual(PairLink.encodeComponent("a b+ş/!~*'()"), "a%20b%2B%C5%9F%2F!~*'()")
    }

    /// Bağlantı kendiliğinden yalnızca bilinen sunucuya bağlanır (yabancı bağlantı veriyi başka sunucuya yükletemesin)
    func testPairLinkKnownServer() {
        XCTAssertTrue(PairLink.isKnownServer(nil, saved: nil))
        XCTAssertTrue(PairLink.isKnownServer("  ", saved: nil))
        XCTAssertTrue(PairLink.isKnownServer(CloudDefaults.url, saved: nil))
        XCTAssertTrue(PairLink.isKnownServer(" " + CloudDefaults.url.uppercased() + "//", saved: nil))
        XCTAssertTrue(PairLink.isKnownServer("https://kendi.supabase.co/", saved: "https://kendi.supabase.co"))
        XCTAssertFalse(PairLink.isKnownServer("https://evil.example", saved: nil))
        XCTAssertFalse(PairLink.isKnownServer("https://evil.example", saved: "https://kendi.supabase.co"))
        XCTAssertFalse(PairLink.isKnownServer("http://" + CloudDefaults.url.dropFirst("https://".count), saved: nil))
        // Bağlantıdan okunan sunucuyla
        let link = PairLink.make(code: "7KQ2M9XP4TRAHW3D", url: "https://evil.example", key: "x")
        let parsed = URL(string: link).flatMap { PairLink.parse($0) }
        XCTAssertEqual(parsed?.url, "https://evil.example")
        XCTAssertFalse(PairLink.isKnownServer(parsed?.url, saved: CloudDefaults.url))

        XCTAssertTrue(CloudDefaults.sameServer("https://P.supabase.co/", " https://p.supabase.co"))
        XCTAssertFalse(CloudDefaults.sameServer("https://p.supabase.co", "https://q.supabase.co"))
        XCTAssertEqual(CloudDefaults.normalizedURL(" HTTPS://P.supabase.co// "), "https://p.supabase.co")
    }

    // MARK: - Kod alanı

    func testFormatInputWhileTyping() {
        XCTAssertEqual(PairCode.formatInput(""), "")
        XCTAssertEqual(PairCode.formatInput("7kq2"), "7KQ2")
        XCTAssertEqual(PairCode.formatInput("7kq2m"), "7KQ2-M")
        XCTAssertEqual(PairCode.formatInput("7KQ2-"), "7KQ2")              // tire silinince grup geri birleşir
        XCTAssertEqual(PairCode.formatInput("7KQ2-M9XP 4tr"), "7KQ2-M9XP-4TR")
        XCTAssertEqual(PairCode.formatInput("7KQ2-M9XP-4TRA-HW3DX"), "7KQ2-M9XP-4TRA-HW3D")   // en fazla 16 karakter
        XCTAssertEqual(PairCode.formatInput("7KQ2-M9XP-4TRA-HWOD"), "7KQ2-M9XP-4TRA-HWOD")   // alfabede olmayan harf kalır
        // Yapıştırılan mesaj ya da bağlantı: içindeki kod
        XCTAssertEqual(PairCode.formatInput("Bağlantı kodu: 7kq2-m9xp-4tra-hw3d\nMac'te Web'e Bağlan"), "7KQ2-M9XP-4TRA-HW3D")
        XCTAssertEqual(PairCode.formatInput("envanter://baglan?kod=AB2C-D3EF-4GH5-JK6M&sunucu=x"), "AB2C-D3EF-4GH5-JK6M")
        // Kod bulunamayan mesaj olduğu gibi kalır
        XCTAssertEqual(PairCode.formatInput("Merhaba, kod yok."), "Merhaba, kod yok.")
    }

    func testInputProblem() {
        XCTAssertNil(PairCode.inputProblem(""))
        XCTAssertNil(PairCode.inputProblem("7KQ2-M9"))                       // yazılıyor
        XCTAssertNil(PairCode.inputProblem("7KQ2-M9XP-4TRA-HW3D"))
        XCTAssertEqual(PairCode.inputProblem("7KQ2-M9XP-4TRA-HW0D"),
                       "Kodda 0 ve 1 rakamları, I, L ve O harfleri yoktur; kodu yeniden kontrol edin.")
        XCTAssertEqual(PairCode.inputProblem("Merhaba, kod yok."),
                       "Bu metinde bağlantı kodu bulunamadı. Kod XXXX-XXXX-XXXX-XXXX biçiminde 16 karakterdir.")
    }

    func testDeviceAccountHelpers() {
        XCTAssertEqual(PairCode.deviceName(forEmail: " PC-7KQ2M9@Envanter.Local "), "pc-7kq2m9")
        XCTAssertNil(PairCode.deviceName(forEmail: "ayse.yilmaz@envanter.local"))
        XCTAssertNil(PairCode.deviceName(forEmail: "mac-7kq2m9@envanter.local"))
        XCTAssertNil(PairCode.deviceName(forEmail: "pc-7kq2m9@envanter.local.com"))
        XCTAssertFalse(PairCode.isCode("7KQ2-M9XP-4TRA-HW3D"))
        XCTAssertFalse(PairCode.isCode("7kq2m9xp4trahw3d"))
        XCTAssertFalse(PairCode.isCode(DevicePassword.generate()))
        XCTAssertEqual(PairCode.percentDecoded("a%2Db%zz%4"), "a-b%zz%4")
        XCTAssertEqual(PairCode.percentDecoded("%C5%9F"), "ş")
    }
}

/// Verilen değerleri sırayla döndüren üreteç (rastgele kod / şifre denemeleri için)
struct SequenceGenerator: RandomNumberGenerator {
    var values: [UInt64]
    var index = 0

    init(values: [UInt64]) { self.values = values }

    mutating func next() -> UInt64 {
        defer { index += 1 }
        return values[index % values.count]
    }
}
