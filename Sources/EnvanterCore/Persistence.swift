import Foundation

/// Veriyi ~/Library/Application Support/Envanter/ altında JSON olarak saklar.
/// Yazma atomiktir; her gün otomatik yedek alınır, bozulursa son yedekten dönülür.
public final class Persistence: @unchecked Sendable {
    public let directory: URL
    public var dataFile: URL { directory.appendingPathComponent("envanter-verisi.json") }
    public var backupDirectory: URL { directory.appendingPathComponent("Yedekler", isDirectory: true) }

    public enum LoadResult {
        case fresh
        case loaded(AppData)
        case recovered(AppData, from: String)
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
        if let d = try? Data(contentsOf: dataFile), let data = try? Self.decoder().decode(AppData.self, from: d) {
            return .loaded(data)
        }
        // Bozuk dosyayı sakla, son yedeğe dön
        let stamp = Int(Date().timeIntervalSince1970)
        try? fm.moveItem(at: dataFile, to: directory.appendingPathComponent("bozuk-\(stamp).json"))
        let backups = ((try? fm.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for b in backups {
            if let d = try? Data(contentsOf: b), let data = try? Self.decoder().decode(AppData.self, from: d) {
                return .recovered(data, from: b.lastPathComponent)
            }
        }
        return .fresh
    }

    public func encode(_ data: AppData) throws -> Data { try Self.encoder().encode(data) }

    public func write(_ encoded: Data) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoded.write(to: dataFile, options: .atomic)
    }

    public func save(_ data: AppData) throws { try write(try encode(data)) }

    /// Günde bir kez yedek al; son 30 yedeği tut.
    public func dailyBackup(_ encoded: Data, today: String = DateKey.today()) {
        let fm = FileManager.default
        try? fm.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let file = backupDirectory.appendingPathComponent("envanter-\(today).json")
        // Aynı gün içinde yedek zaten varsa güncelle (gün sonundaki hali kalsın)
        try? encoded.write(to: file, options: .atomic)
        let all = ((try? fm.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("envanter-") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in all.dropFirst(30) { try? fm.removeItem(at: old) }
    }

    public static func decode(_ data: Data) throws -> AppData { try decoder().decode(AppData.self, from: data) }
}
