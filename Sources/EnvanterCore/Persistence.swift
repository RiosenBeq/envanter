import Foundation

/// Veriyi ~/Library/Application Support/Envanter/ altında JSON olarak saklar.
/// Yazma atomiktir; her gün otomatik yedek alınır, bozulursa son yedekten dönülür.
public final class Persistence: @unchecked Sendable {
    public let directory: URL
    public var dataFile: URL { directory.appendingPathComponent("envanter-verisi.json") }
    public var backupDirectory: URL { directory.appendingPathComponent("Yedekler", isDirectory: true) }
    /// Saklanan günlük yedek sayısı
    public static let keptBackups = 30

    public enum LoadResult {
        /// Veri dosyası yok (ilk açılış)
        case fresh
        case loaded(AppData)
        /// Ana dosya okunamadı; yedekten dönüldü
        case recovered(AppData, from: String)
        /// Ana dosya okunamadı ve kullanılabilir yedek yok; bozuk dosya kenara alındı
        case unreadable(movedTo: String)
    }

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public static func defaultDirectory() -> URL {
        if let env = ProcessInfo.processInfo.environment["ENVANTER_DATA_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // Klasör adı geriye dönük uyumluluk için "Envanter" olarak kalır
        return base.appendingPathComponent("Envanter", isDirectory: true)
    }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public func load() -> LoadResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dataFile.path) else { return .fresh }
        if let d = try? Data(contentsOf: dataFile), let data = try? Self.decode(d) {
            return .loaded(data)
        }
        // Bozuk dosyayı sakla, en yeni yedeğe dön
        let stamp = Int(Date().timeIntervalSince1970)
        var moved = directory.appendingPathComponent("bozuk-\(stamp).json")
        var n = 2
        while fm.fileExists(atPath: moved.path) { moved = directory.appendingPathComponent("bozuk-\(stamp)-\(n).json"); n += 1 }
        try? fm.moveItem(at: dataFile, to: moved)
        for b in backups() {
            if let d = try? Data(contentsOf: b), let data = try? Self.decode(d) {
                return .recovered(data, from: b.lastPathComponent)
            }
        }
        return .unreadable(movedTo: moved.lastPathComponent)
    }

    /// Yedek klasöründeki tüm JSON dosyaları, en yeniden eskiye (değiştirilme tarihine göre).
    public func backups() -> [URL] {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "json" }
        func modified(_ u: URL) -> Date {
            (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        return files.map { ($0, modified($0)) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.lastPathComponent > $1.0.lastPathComponent }
            .map { $0.0 }
    }

    public func encode(_ data: AppData) throws -> Data { try Self.encoder().encode(data) }

    public func write(_ encoded: Data) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoded.write(to: dataFile, options: .atomic)
    }

    public func save(_ data: AppData) throws { try write(try encode(data)) }

    /// Günün yedeğini yazar (aynı gün içinde güncellenir); son 30 günlük yedeği tutar.
    public func dailyBackup(_ encoded: Data, today: String = DateKey.today()) {
        let fm = FileManager.default
        try? fm.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let file = backupDirectory.appendingPathComponent("envanter-\(today).json")
        try? encoded.write(to: file, options: .atomic)
        let all = ((try? fm.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("envanter-") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in all.dropFirst(Self.keptBackups) { try? fm.removeItem(at: old) }
    }

    /// Riskli bir işlemden (geri yükleme, toplu içe aktarma) önce anlık kopya alır.
    @discardableResult
    public func snapshot(_ encoded: Data, label: String) -> URL? {
        let fm = FileManager.default
        try? fm.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        var url = backupDirectory.appendingPathComponent("\(label)-\(stamp).json")
        var n = 2
        while fm.fileExists(atPath: url.path) { url = backupDirectory.appendingPathComponent("\(label)-\(stamp)-\(n).json"); n += 1 }
        do { try encoded.write(to: url, options: .atomic); return url } catch { return nil }
    }

    public static func decode(_ data: Data) throws -> AppData { try decoder().decode(AppData.self, from: data) }
}
