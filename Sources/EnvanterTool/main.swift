import Foundation
import EnvanterCore

// Komut satırı aracı: uygulama kapalıyken Excel envanter dosyasını veri klasörüne aktarır.
//   EnvanterTool import-excel <dosya.xlsm> [--overwrite] [--data-dir KLASÖR] [--dry-run]
//   EnvanterTool status [--data-dir KLASÖR]

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8)); exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail("Kullanım: EnvanterTool import-excel <dosya> [--overwrite] [--dry-run] [--data-dir KLASÖR] | status") }
args.removeFirst()

var dataDir = Persistence.defaultDirectory()
if let i = args.firstIndex(of: "--data-dir"), i + 1 < args.count {
    dataDir = URL(fileURLWithPath: args[i + 1], isDirectory: true); args.removeSubrange(i...(i + 1))
}
let overwrite = args.contains("--overwrite"); args.removeAll { $0 == "--overwrite" }
let dryRun = args.contains("--dry-run"); args.removeAll { $0 == "--dry-run" }

let persistence = Persistence(directory: dataDir)
var data: AppData
switch persistence.load() {
case .fresh: data = AppData.seeded()
case .loaded(let d): data = d
case .recovered(let d, let from): data = d; print("Uyarı: veri dosyası yedekten (\(from)) onarıldı.")
}

func describe(_ data: AppData) {
    let days = data.days.filter { !$0.value.isEmpty }.keys.sorted()
    print("Veri klasörü: \(dataDir.path)")
    print("Kayıtlı gün: \(days.count)\(days.isEmpty ? "" : " (\(days.first!) … \(days.last!))") · ürün reçetesi: \(data.products.count) · stok kalemi: \(data.items.count)")
}

switch command {
case "status":
    describe(data)
case "import-excel":
    guard let path = args.first else { fail("Dosya yolu gerekli.") }
    do {
        let imp = try WorkbookImporter.parse(url: URL(fileURLWithPath: path), items: data.items)
        print("Kaynak: \(imp.sourceName)")
        print("Geçmiş günler: \(imp.historyDates.count)" + (imp.historyDates.isEmpty ? "" : " (\(imp.historyDates.first!) … \(imp.historyDates.last!))"))
        if let d = imp.currentDate { print("Güncel gün: \(d) — \(imp.currentCountedItems) kalem sayımı, \(imp.currentSalesLines) satış satırı") }
        if imp.duplicatesResolved > 0 { print("Yinelenen kayıt (kapanışlı olan alındı): \(imp.duplicatesResolved)") }
        if !imp.skippedItemNames.isEmpty { print("Eşleşmeyen ürün adları (atlandı): \(imp.skippedItemNames.joined(separator: ", "))") }
        for n in imp.notes { print("Not: \(n)") }
        let conflicts = WorkbookImporter.conflicts(imp, in: data)
        if !conflicts.isEmpty { print("Zaten verisi olan gün: \(conflicts.count)\(overwrite ? " (üzerine yazılacak)" : " (dokunulmayacak)")") }
        if dryRun { print("Deneme çalışması: hiçbir şey yazılmadı."); exit(0) }
        let report = WorkbookImporter.apply(imp, to: &data, overwrite: overwrite)
        try persistence.save(data)
        persistence.dailyBackup(try persistence.encode(data))
        print("Aktarıldı: \(report.added) yeni gün, \(report.replaced) değiştirilen, \(report.skippedExisting) atlanan.")
        describe(data)
    } catch {
        fail("Hata: \(error.localizedDescription)")
    }
default:
    fail("Bilinmeyen komut: \(command)")
}
