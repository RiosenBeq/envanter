import Foundation
#if canImport(Compression)
import Compression
#endif

public enum ZipError: Error, LocalizedError {
    case notAZip, corrupt(String), unsupported(String), missing(String)
    public var errorDescription: String? {
        switch self {
        case .notAZip: return "Dosya geçerli bir .xlsx (zip) dosyası değil."
        case .corrupt(let s): return "Dosya bozuk: \(s)"
        case .unsupported(let s): return "Desteklenmeyen dosya biçimi: \(s)"
        case .missing(let s): return "Dosyada beklenen bölüm yok: \(s)"
        }
    }
}

/// Sadece okuma amaçlı, bağımlılıksız minimal ZIP okuyucu (stored + deflate).
public struct ZipReader {
    struct Entry { var name: String; var method: UInt16; var compSize: Int; var size: Int; var localOffset: Int }
    private let data: Data
    private var entries: [String: Entry] = [:]

    public var names: [String] { Array(entries.keys) }

    /// Tek bir bölümün açılmış hali için üst sınır (bozuk / kötü niyetli dosyaya karşı)
    static let maxEntrySize = 512 * 1024 * 1024

    public init(data: Data) throws {
        self.data = data
        guard data.count >= 22 else { throw ZipError.notAZip }
        // End of central directory kaydını sondan ara
        var eocd = -1
        var i = data.count - 22
        let lowerBound = max(0, data.count - 22 - 65_535)
        while i >= lowerBound {
            if Self.u32(data, i) == 0x0605_4b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notAZip }
        let count = Int(Self.u16(data, eocd + 10))
        var pos = Int(Self.u32(data, eocd + 16))
        guard pos < data.count else { throw ZipError.corrupt("merkez dizin") }
        for _ in 0..<count {
            guard pos + 46 <= data.count, Self.u32(data, pos) == 0x0201_4b50 else { throw ZipError.corrupt("merkez dizin kaydı") }
            let method = Self.u16(data, pos + 10)
            let comp = Int(Self.u32(data, pos + 20))
            let size = Int(Self.u32(data, pos + 24))
            let nameLen = Int(Self.u16(data, pos + 28))
            let extraLen = Int(Self.u16(data, pos + 30))
            let commentLen = Int(Self.u16(data, pos + 32))
            let offset = Int(Self.u32(data, pos + 42))
            guard pos + 46 + nameLen <= data.count else { throw ZipError.corrupt("dosya adı") }
            let nameData = data.subdata(in: (pos + 46)..<(pos + 46 + nameLen))
            let name = String(data: nameData, encoding: .utf8) ?? String(decoding: nameData, as: UTF8.self)
            entries[name] = Entry(name: name, method: method, compSize: comp, size: size, localOffset: offset)
            pos += 46 + nameLen + extraLen + commentLen
        }
    }

    public func contains(_ name: String) -> Bool { entries[name] != nil }

    public func read(_ name: String) throws -> Data {
        guard let e = entries[name] else { throw ZipError.missing(name) }
        let lo = e.localOffset
        guard lo + 30 <= data.count, Self.u32(data, lo) == 0x0403_4b50 else { throw ZipError.corrupt(name) }
        let nameLen = Int(Self.u16(data, lo + 26))
        let extraLen = Int(Self.u16(data, lo + 28))
        let start = lo + 30 + nameLen + extraLen
        guard start + e.compSize <= data.count else { throw ZipError.corrupt(name) }
        let raw = data.subdata(in: start..<(start + e.compSize))
        switch e.method {
        case 0:
            return raw
        case 8:
            if e.size == 0 { return Data() }
            guard e.size <= Self.maxEntrySize else { throw ZipError.unsupported("\(name) çok büyük") }
            return try Self.inflate(raw, size: e.size, name: name)
        default:
            throw ZipError.unsupported("sıkıştırma yöntemi \(e.method)")
        }
    }

    private static func inflate(_ raw: Data, size: Int, name: String) throws -> Data {
        #if canImport(Compression)
        var out = Data(count: size)
        let written: Int = out.withUnsafeMutableBytes { dst in
            raw.withUnsafeBytes { src in
                guard let d = dst.bindMemory(to: UInt8.self).baseAddress,
                      let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(d, size, s, raw.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw ZipError.corrupt("\(name) açılamadı") }
        return out
        #else
        guard let out = try? Inflate.decompress(raw, expectedSize: size), out.count == size else {
            throw ZipError.corrupt("\(name) açılamadı")
        }
        return out
        #endif
    }

    static func u16(_ d: Data, _ o: Int) -> UInt16 {
        UInt16(d[d.startIndex + o]) | UInt16(d[d.startIndex + o + 1]) << 8
    }
    static func u32(_ d: Data, _ o: Int) -> UInt32 {
        UInt32(d[d.startIndex + o]) | UInt32(d[d.startIndex + o + 1]) << 8
            | UInt32(d[d.startIndex + o + 2]) << 16 | UInt32(d[d.startIndex + o + 3]) << 24
    }
}

/// Sıkıştırmasız (stored) ZIP yazıcı: .xlsx dışa aktarımı için yeterli.
public struct ZipWriter {
    private var files: [(name: String, data: Data)] = []
    public init() {}

    public mutating func add(_ name: String, _ data: Data) { files.append((name, data)) }
    public mutating func add(_ name: String, text: String) { files.append((name, Data(text.utf8))) }

    public func finish() -> Data {
        var out = Data()
        var central = Data()
        // 2026-01-01 00:00 (DOS biçimi)
        let dosTime: UInt16 = 0
        let dosDate: UInt16 = UInt16((2026 - 1980) << 9 | 1 << 5 | 1)
        for f in files {
            let nameData = Data(f.name.utf8)
            let crc = Self.crc32(f.data)
            let offset = UInt32(out.count)
            out.append(le32(0x0403_4b50)); out.append(le16(20)); out.append(le16(0x0800)); out.append(le16(0))
            out.append(le16(dosTime)); out.append(le16(dosDate))
            out.append(le32(crc)); out.append(le32(UInt32(f.data.count))); out.append(le32(UInt32(f.data.count)))
            out.append(le16(UInt16(nameData.count))); out.append(le16(0))
            out.append(nameData); out.append(f.data)

            central.append(le32(0x0201_4b50)); central.append(le16(20)); central.append(le16(20))
            central.append(le16(0x0800)); central.append(le16(0))
            central.append(le16(dosTime)); central.append(le16(dosDate))
            central.append(le32(crc)); central.append(le32(UInt32(f.data.count))); central.append(le32(UInt32(f.data.count)))
            central.append(le16(UInt16(nameData.count))); central.append(le16(0)); central.append(le16(0))
            central.append(le16(0)); central.append(le16(0)); central.append(le32(0)); central.append(le32(offset))
            central.append(nameData)
        }
        let cdOffset = UInt32(out.count)
        out.append(central)
        out.append(le32(0x0605_4b50)); out.append(le16(0)); out.append(le16(0))
        out.append(le16(UInt16(files.count))); out.append(le16(UInt16(files.count)))
        out.append(le32(UInt32(central.count))); out.append(le32(cdOffset)); out.append(le16(0))
        return out
    }

    private func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xff), UInt8(v >> 8)]) }
    private func le32(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8(v >> 24)])
    }

    static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = crcTable[Int((c ^ UInt32(b)) & 0xff)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}
