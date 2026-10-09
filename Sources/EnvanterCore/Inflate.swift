import Foundation

/// Bağımlılıksız ham DEFLATE (RFC 1951) çözücü.
/// macOS'ta Apple'ın Compression çerçevesi kullanılır; bu uygulama yalnızca o çerçevenin olmadığı
/// platformlarda (ör. Linux'ta çalışan testler / CI) devreye girer. Mark Adler'in puff.c'sini izler.
enum Inflate {
    enum Failure: Error { case corrupt, truncated }

    static func decompress(_ input: Data, expectedSize: Int) throws -> Data {
        var state = State(input: [UInt8](input))
        state.out.reserveCapacity(expectedSize)
        var last = false
        repeat {
            last = try state.bits(1) == 1
            switch try state.bits(2) {
            case 0: try state.stored()
            case 1: try state.codes(lengths: Fixed.lengths, distances: Fixed.distances)
            case 2:
                let (l, d) = try state.dynamicTables()
                try state.codes(lengths: l, distances: d)
            default: throw Failure.corrupt
            }
        } while !last
        return Data(state.out)
    }

    struct Huffman {
        /// count[n]: n bit uzunluğundaki kod sayısı
        var count = [Int](repeating: 0, count: 16)
        /// Kanonik sırada semboller
        var symbol: [Int]

        init(lengths: [Int]) throws {
            symbol = [Int](repeating: 0, count: lengths.count)
            for l in lengths { count[l] += 1 }
            if count[0] == lengths.count { return }  // boş tablo (yalnızca uzunluk kodu kullanan bloklar)
            var left = 1
            for len in 1..<16 {
                left <<= 1
                left -= count[len]
                if left < 0 { throw Failure.corrupt }  // fazla dolu
            }
            var offs = [Int](repeating: 0, count: 16)
            for len in 1..<15 { offs[len + 1] = offs[len] + count[len] }
            for (sym, len) in lengths.enumerated() where len != 0 {
                symbol[offs[len]] = sym
                offs[len] += 1
            }
        }
    }

    enum Fixed {
        static let lengths: Huffman = {
            var l = [Int](repeating: 8, count: 288)
            for i in 144..<256 { l[i] = 9 }
            for i in 256..<280 { l[i] = 7 }
            return try! Huffman(lengths: l)
        }()
        static let distances: Huffman = try! Huffman(lengths: [Int](repeating: 5, count: 30))
    }

    static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
                             35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
                              3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    static let distBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
                           257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    static let distExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
                            7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    static let codeOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    struct State {
        let input: [UInt8]
        var pos = 0
        var bitBuf = 0
        var bitCount = 0
        var out: [UInt8] = []

        init(input: [UInt8]) { self.input = input }

        mutating func bits(_ need: Int) throws -> Int {
            var val = bitBuf
            while bitCount < need {
                guard pos < input.count else { throw Failure.truncated }
                val |= Int(input[pos]) << bitCount
                pos += 1
                bitCount += 8
            }
            bitBuf = val >> need
            bitCount -= need
            return val & ((1 << need) - 1)
        }

        mutating func stored() throws {
            bitBuf = 0; bitCount = 0  // bayt sınırına hizala
            guard pos + 4 <= input.count else { throw Failure.truncated }
            let len = Int(input[pos]) | Int(input[pos + 1]) << 8
            let nlen = Int(input[pos + 2]) | Int(input[pos + 3]) << 8
            guard len == (~nlen & 0xffff) else { throw Failure.corrupt }
            pos += 4
            guard pos + len <= input.count else { throw Failure.truncated }
            out.append(contentsOf: input[pos..<(pos + len)])
            pos += len
        }

        mutating func decode(_ h: Huffman) throws -> Int {
            var code = 0, first = 0, index = 0
            for len in 1..<16 {
                code |= try bits(1)
                let count = h.count[len]
                if code - count < first { return h.symbol[index + (code - first)] }
                index += count
                first += count
                first <<= 1
                code <<= 1
            }
            throw Failure.corrupt
        }

        mutating func codes(lengths: Huffman, distances: Huffman) throws {
            while true {
                var sym = try decode(lengths)
                if sym < 256 {
                    out.append(UInt8(sym))
                } else if sym == 256 {
                    return
                } else {
                    sym -= 257
                    guard sym < 29 else { throw Failure.corrupt }
                    let len = Inflate.lengthBase[sym] + (try bits(Inflate.lengthExtra[sym]))
                    let dsym = try decode(distances)
                    guard dsym < 30 else { throw Failure.corrupt }
                    let dist = Inflate.distBase[dsym] + (try bits(Inflate.distExtra[dsym]))
                    guard dist <= out.count else { throw Failure.corrupt }
                    let start = out.count - dist
                    // Örtüşen kopyalar (dist < len) bayt bayt yapılmalı
                    for i in 0..<len { out.append(out[start + i]) }
                }
            }
        }

        mutating func dynamicTables() throws -> (Huffman, Huffman) {
            let nlen = try bits(5) + 257
            let ndist = try bits(5) + 1
            let ncode = try bits(4) + 4
            guard nlen <= 286, ndist <= 30 else { throw Failure.corrupt }
            var codeLengths = [Int](repeating: 0, count: 19)
            for i in 0..<ncode { codeLengths[Inflate.codeOrder[i]] = try bits(3) }
            let lencode = try Huffman(lengths: codeLengths)

            var lengths = [Int](repeating: 0, count: nlen + ndist)
            var index = 0
            while index < nlen + ndist {
                let sym = try decode(lencode)
                if sym < 16 {
                    lengths[index] = sym; index += 1
                    continue
                }
                var len = 0, repeatCount = 0
                switch sym {
                case 16:
                    guard index > 0 else { throw Failure.corrupt }
                    len = lengths[index - 1]
                    repeatCount = 3 + (try bits(2))
                case 17: repeatCount = 3 + (try bits(3))
                default: repeatCount = 11 + (try bits(7))
                }
                guard index + repeatCount <= nlen + ndist else { throw Failure.corrupt }
                for _ in 0..<repeatCount { lengths[index] = len; index += 1 }
            }
            guard lengths[256] != 0 else { throw Failure.corrupt }  // blok sonu kodu olmalı
            return (try Huffman(lengths: Array(lengths[0..<nlen])),
                    try Huffman(lengths: Array(lengths[nlen...])))
        }
    }
}
