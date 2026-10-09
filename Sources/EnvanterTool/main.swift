import Foundation
import EnvanterCore

// NextGen Envanter komut satırı aracı (uygulama kapalıyken kullanın):
//   EnvanterTool status                                   Veri özetini gösterir
//   EnvanterTool import-excel <dosya.xlsm> [--overwrite] [--dry-run]
//   EnvanterTool export-excel <çıktı.xlsx> [--from GG.AA.YYYY|yyyy-MM-dd] [--to …]
//   EnvanterTool orders [--date …] [--days 14] [--cover 3]    Sipariş önerisini yazdırır
//   EnvanterTool demo --data-dir KLASÖR [--date …] [--days 35] Eğitim/tanıtım için örnek veri kurar
//   EnvanterTool report [--from …] [--to …]                    Dönem özeti: satış, maliyet %, personel %, prime cost
// Tüm komutlar --data-dir KLASÖR ile başka bir veri klasörüne yönlendirilebilir.

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8)); exit(1)
}

let usage = """
    Kullanım:
      EnvanterTool status
      EnvanterTool import-excel <dosya.xlsm> [--overwrite] [--dry-run]
      EnvanterTool export-excel <çıktı.xlsx> [--from TARİH] [--to TARİH]
      EnvanterTool orders [--date TARİH] [--days 14] [--cover 3]
      EnvanterTool demo --data-dir KLASÖR [--date TARİH] [--days 35]
      EnvanterTool report [--from TARİH] [--to TARİH]
    Ortak seçenek: --data-dir KLASÖR
    """

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail(usage) }
args.removeFirst()

/// "--ad değer" seçeneğini okur ve argümanlardan çıkarır
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name) else { return nil }
    guard i + 1 < args.count else { fail("\(name) için değer gerekli.") }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

func flag(_ name: String) -> Bool {
    let has = args.contains(name)
    args.removeAll { $0 == name }
    return has
}

/// "01.08.2026" veya "2026-08-01"
func dateArg(_ raw: String?) -> String? {
    guard let raw else { return nil }
    if DateKey.isValid(raw) { return raw }
    if let k = SalesParser.extractDates(raw).first { return k }
    fail("Tarih anlaşılamadı: \(raw)")
}

let explicitDataDir = option("--data-dir")
let dataDir = explicitDataDir.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Persistence.defaultDirectory()

// Demo verisi gerçek veri klasörüne asla yazılmaz
if command == "demo" {
    guard explicitDataDir != nil else { fail("demo komutu için --data-dir KLASÖR zorunludur (gerçek verinin üzerine yazmamak için).") }
    let p = Persistence(directory: dataDir)
    guard case .fresh = p.load() else { fail("\(dataDir.path) içinde zaten veri var; boş bir klasör seçin.") }
    let end = dateArg(option("--date")) ?? DateKey.today()
    let days = max(7, min(option("--days").flatMap { Int($0) } ?? 35, 400))
    let demo = DemoData.make(endingAt: end, days: days)
    do { try p.save(demo) } catch { fail("Hata: \(error.localizedDescription)") }
    print("Demo verisi kuruldu: \(dataDir.path) (\(days) gün, son gün \(DateKey.short(end)))")
    print("Uygulamayı bu veriyle açmak için:")
    print("  ENVANTER_DATA_DIR=\"\(dataDir.path)\" \"/Applications/NextGen Envanter.app/Contents/MacOS/Envanter\"")
    exit(0)
}
let persistence = Persistence(directory: dataDir)
var data: AppData
switch persistence.load() {
case .fresh: data = AppData.seeded()
case .loaded(let d): data = d
case .recovered(let d, let from): data = d; print("Uyarı: veri dosyası yedekten (\(from)) onarıldı.")
case .unreadable(let moved):
    fail("Veri dosyası okunamadı ve kullanılabilir yedek yok (bozuk dosya: \(moved)). Hiçbir şey yazılmadı.")
}

func describe(_ data: AppData) {
    let days = Engine(data: data).datesWithData
    print("Veri klasörü: \(dataDir.path)")
    if !data.settings.branchName.isEmpty { print("Şube: \(data.settings.branchName)") }
    print("Kayıtlı gün: \(days.count)\(days.isEmpty ? "" : " (\(days.first!) … \(days.last!))") · ürün reçetesi: \(data.products.count) · stok kalemi: \(data.items.count)")
}

switch command {
case "status":
    describe(data)

case "import-excel":
    let overwrite = flag("--overwrite")
    let dryRun = flag("--dry-run")
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
        persistence.snapshot(try persistence.encode(data), label: "aktarim-oncesi")
        let report = WorkbookImporter.apply(imp, to: &data, overwrite: overwrite)
        try persistence.save(data)
        persistence.dailyBackup(try persistence.encode(data))
        print("Aktarıldı: \(report.added) yeni gün, \(report.replaced) değiştirilen, \(report.skippedExisting) atlanan.")
        describe(data)
    } catch {
        fail("Hata: \(error.localizedDescription)")
    }

case "export-excel":
    let engine = Engine(data: data)
    let from = dateArg(option("--from")) ?? engine.datesWithData.first ?? DateKey.today()
    let to = dateArg(option("--to")) ?? engine.datesWithData.last ?? DateKey.today()
    guard let path = args.first else { fail("Çıktı dosyası gerekli (ör. rapor.xlsx).") }
    do {
        try Exporter.history(engine: engine, from: from, to: to).write(to: URL(fileURLWithPath: path), options: .atomic)
        print("Yazıldı: \(path) (\(DateKey.short(from)) – \(DateKey.short(to)))")
    } catch {
        fail("Hata: \(error.localizedDescription)")
    }

case "orders":
    let date = dateArg(option("--date")) ?? DateKey.today()
    let days = option("--days").flatMap { Int($0) } ?? data.settings.orderLookbackDays
    let cover = option("--cover").flatMap { Fmt.parse($0) } ?? data.settings.orderCoverDays
    let list = Engine(data: data).orderSuggestions(asOf: date, lookbackDays: days, coverDays: cover)
    print(Exporter.orderText(list, date: date, branch: data.settings.branchName))

case "report":
    let engine = Engine(data: data)
    let to = dateArg(option("--to")) ?? engine.datesWithData.last ?? DateKey.today()
    let from = dateArg(option("--from")) ?? DateKey.startOfMonth(to)
    let p = engine.periodStats(from: from, to: to)
    func pct(_ v: Double?) -> String { v.map { "%" + Fmt.number($0 * 100, maxFraction: 1) } ?? "—" }
    let s = data.settings
    print("\(s.branchName.isEmpty ? "Dönem özeti" : s.branchName) · \(DateKey.short(from)) – \(DateKey.short(to))")
    print("Gün: \(p.days.count) (sayım \(p.countedDays), satış \(p.salesDays), tutarlı \(p.revenueDays))")
    print("Satış tutarı        : \(Fmt.money(p.revenue))")
    print("Teorik hammadde     : \(Fmt.money(p.theoreticalCost))  \(pct(p.theoreticalCostPct))")
    print("Fiili hammadde      : \(Fmt.money(p.actualCost))  \(pct(p.actualCostPct))  hedef \(pct(s.targetFoodCostPct))")
    print("Personel            : \(Fmt.money(p.laborCost))  \(pct(p.laborPct))  hedef \(pct(s.targetLaborPct))")
    print("Prime cost          : \(Fmt.money(p.primeCost))  \(pct(p.primeCostPct))  hedef \(pct(s.targetPrimeCostPct))")
    print("Kayıp (fazla çıkış) : \(Fmt.money(p.lossValue))   Zayi: \(Fmt.money(p.wasteCost))")
    let alerts = engine.priceAlerts(asOf: to, threshold: s.priceAlertPct)
    for a in alerts { print("Fiyat artışı        : \(a.item.name) \(Fmt.money(a.from, fraction: 2)) → \(Fmt.money(a.to, fraction: 2)) (\(pct(a.ratio)))") }
    let open = data.purchaseOrders.filter { $0.status == .open }
    if !open.isEmpty { print("Açık sipariş        : \(open.count)") }

default:
    fail("Bilinmeyen komut: \(command)\n\(usage)")
}
