import Foundation

/// Bir JSON değeri (bulut belgelerinin gövdesi). Eşitlik JSON değerlerinin derin eşitliğidir:
/// sayılar değer olarak karşılaştırılır (1 == 1.0), nesnelerde anahtar sırası önemsizdir.
public enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o } else { return nil } }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a } else { return nil } }
    public var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
    public var doubleValue: Double? { if case .number(let n) = self { return n } else { return nil } }
    public var boolValue: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    public var isNull: Bool { if case .null = self { return true } else { return false } }

    public subscript(key: String) -> JSONValue? { objectValue?[key] }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        // Bool önce denenir: bazı çözücüler true/false'u sayı olarak da okuyabilir
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Geçersiz JSON değeri")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            // Tam sayılar "120" olarak yazılır ("120.0" değil); 2^53'e kadar tam sayılar Double'da kayıpsızdır
            if n.isFinite, n == n.rounded(), abs(n) < 9_007_199_254_740_992 {
                try c.encode(Int64(n))
            } else {
                try c.encode(n)
            }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

/// Bulut belgeleri için JSON kodlama kuralları: `Persistence.encoder()/decoder()` ile aynı (ISO 8601 tarih,
/// `nil` alanlar yazılmaz). Okurken kesirli saniyeli ISO 8601 tarihler de kabul edilir (web/JS istemcileri).
public enum JSONCoding {
    /// Sıkıştırılmış, anahtarları sıralı (belirlenimci) çıktı
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            if let date = parseISODate(s) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Geçersiz ISO 8601 tarihi: \(s)")
        }
        return d
    }

    /// "2026-08-01T10:15:00Z", "2026-08-01T10:15:00.123Z", "2026-08-01T13:15:00+03:00"
    public static func parseISODate(_ s: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: s) { return d }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: s)
    }

    /// Kodlanabilir bir değeri JSON değerine çevirir
    public static func value<T: Encodable>(_ v: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: encoder().encode(v))
    }

    /// JSON değerini bir tipe çözer (tarihler ISO 8601)
    public static func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
        try decoder().decode(T.self, from: encoder().encode(value))
    }

    public static func data(_ value: JSONValue) throws -> Data { try encoder().encode(value) }

    public static func parse(_ data: Data) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: data) }
}

// MARK: - Üç yollu birleştirme (docs/SYNC.md §3)

public enum JSONMerge {
    /// Üç yollu birleştirme. `nil` = yok (silinmiş ya da hiç olmamış). Taban için JSON `null` da "yok" sayılır.
    /// 1. local == base → remote
    /// 2. remote == base → local
    /// 3. local == remote → local
    /// 4. üçü de nesne (base yoksa {}) → anahtar bazında özyinelemeli; sonucu `nil` olan anahtar yazılmaz
    /// 5. local ve remote kimlikli dizi ("id" ya da "code" metin alanlı, kimlikleri tekil nesneler) → kimliğe göre;
    ///    sıra: local, sonra yalnızca remote'ta yeni olanlar remote sırasıyla; sonucu `nil` olan eleman çıkarılır
    /// 6. diğer her durumda yerel kazanır → local
    public static func merge3(base: JSONValue?, local: JSONValue?, remote: JSONValue?) -> JSONValue? {
        let b: JSONValue? = (base?.isNull ?? true) ? nil : base
        if local == b { return remote }
        if remote == b { return local }
        if local == remote { return local }

        if case .object(let lo)? = local, case .object(let ro)? = remote {
            let bo: [String: JSONValue]?
            switch b {
            case nil: bo = [:]
            case .object(let o)?: bo = o
            default: bo = nil
            }
            if let bo {
                var out: [String: JSONValue] = [:]
                for k in Set(lo.keys).union(ro.keys) {
                    if let v = merge3(base: bo[k], local: lo[k], remote: ro[k]) { out[k] = v }
                }
                return .object(out)
            }
        }

        if case .array(let la)? = local, case .array(let ra)? = remote, let field = identityField(la, ra) {
            let ba: [JSONValue]
            if case .array(let a)? = b { ba = a } else { ba = [] }
            let bm = index(ba, by: field), lm = index(la, by: field), rm = index(ra, by: field)
            var order: [String] = la.compactMap { $0[field]?.stringValue }
            for el in ra { if let id = el[field]?.stringValue, lm[id] == nil { order.append(id) } }
            var out: [JSONValue] = []
            for id in order {
                if let v = merge3(base: bm[id], local: lm[id], remote: rm[id]) { out.append(v) }
            }
            return .array(out)
        }

        return local
    }

    /// Kimlik alanı: dizilerin tüm elemanları bu alanı (tekil) metin olarak taşıyan nesnelerse "id", değilse "code"
    static func identityField(_ arrays: [JSONValue]...) -> String? {
        for field in ["id", "code"] {
            var ok = true
            outer: for arr in arrays {
                var seen = Set<String>()
                for el in arr {
                    guard let id = el[field]?.stringValue, !seen.contains(id) else { ok = false; break outer }
                    seen.insert(id)
                }
            }
            if ok { return field }
        }
        return nil
    }

    private static func index(_ arr: [JSONValue], by field: String) -> [String: JSONValue] {
        var m: [String: JSONValue] = [:]
        for el in arr {
            if let id = el[field]?.stringValue, m[id] == nil { m[id] = el }
        }
        return m
    }
}

extension JSONValue {
    /// docs/SYNC.md §3 merge3 (bkz. `JSONMerge.merge3`)
    public static func merge3(base: JSONValue?, local: JSONValue?, remote: JSONValue?) -> JSONValue? {
        JSONMerge.merge3(base: base, local: local, remote: remote)
    }
}
