import SwiftUI
import AppKit
import UniformTypeIdentifiers
import EnvanterCore

enum AppSection: String, CaseIterable, Identifiable {
    case daily, sales, summary, recipes, items, backup, help
    var id: String { rawValue }
    var title: String {
        switch self {
        case .daily: return "Günlük Envanter"
        case .sales: return "Satış Dökümü"
        case .summary: return "Özet ve Raporlar"
        case .recipes: return "Reçeteler"
        case .items: return "Stok Kalemleri"
        case .backup: return "Yedek ve Veri"
        case .help: return "Nasıl Kullanılır?"
        }
    }
    var icon: String {
        switch self {
        case .daily: return "checklist"
        case .sales: return "cart"
        case .summary: return "chart.bar.xaxis"
        case .recipes: return "fork.knife"
        case .items: return "shippingbox"
        case .backup: return "externaldrive"
        case .help: return "questionmark.circle"
        }
    }
}

struct AppAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

struct ImportPreview: Identifiable {
    let id = UUID()
    var report: SalesReport
}

struct WorkbookPreview: Identifiable {
    let id = UUID()
    var imp: WorkbookImport
}

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var data: AppData {
        didSet { engineCache = nil; scheduleSave() }
    }
    @Published var selectedDate: String = DateKey.today()
    @Published var section: AppSection? = .daily
    @Published var importPreview: ImportPreview?
    @Published var workbookPreview: WorkbookPreview?
    @Published var alert: AppAlert?
    /// Reçeteler ekranında seçili ürün kodu
    @Published var recipeSelection: String?
    /// Satış dökümünden "Reçete tanımla" ile açılan taslak
    @Published var newProductDraft: SaleLine?

    let persistence: Persistence
    private var engineCache: Engine?
    private var saveTask: Task<Void, Never>?
    private let saveQueue = DispatchQueue(label: "envanter.save", qos: .utility)

    var engine: Engine {
        if let e = engineCache { return e }
        let e = Engine(data: data)
        engineCache = e
        return e
    }

    init(persistence: Persistence = Persistence(directory: Persistence.defaultDirectory())) {
        self.persistence = persistence
        var startupAlert: AppAlert?
        switch persistence.load() {
        case .fresh:
            data = AppData.seeded()
        case .loaded(let d):
            data = d
        case .recovered(let d, let from):
            data = d
            startupAlert = AppAlert(
                title: "Veri dosyası onarıldı",
                message: "Ana veri dosyası okunamadı; \"\(from)\" yedeğinden geri yüklendi. Bozuk dosya veri klasöründe saklandı.")
        }
        alert = startupAlert
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
        // İlk açılışta dosyayı hemen oluştur
        if !FileManager.default.fileExists(atPath: persistence.dataFile.path) { scheduleSave(immediately: true) }
    }

    // MARK: - Kayıt

    private func scheduleSave(immediately: Bool = false) {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            if !immediately { try? await Task.sleep(nanoseconds: 400_000_000) }
            guard !Task.isCancelled else { return }
            self?.writeNow()
        }
    }

    private func writeNow() {
        do {
            let encoded = try persistence.encode(data)
            let p = persistence
            saveQueue.async {
                do { try p.write(encoded); p.dailyBackup(encoded) } catch { NSLog("Kayıt hatası: \(error)") }
            }
        } catch {
            alert = AppAlert(title: "Kaydedilemedi", message: error.localizedDescription)
        }
    }

    /// Bekleyen değişiklikleri hemen (eşzamanlı) diske yazar.
    func flush() {
        saveTask?.cancel()
        guard let encoded = try? persistence.encode(data) else { return }
        saveQueue.sync { [persistence] in
            try? persistence.write(encoded)
            persistence.dailyBackup(encoded)
        }
    }

    func mutateData(_ f: (inout AppData) -> Void) {
        var d = data
        f(&d)
        data = d
    }

    // MARK: - Gün gezinme

    var dateBinding: Binding<Date> {
        Binding(get: { DateKey.date(from: self.selectedDate) ?? Date() },
                set: { self.selectedDate = DateKey.string(from: $0) })
    }
    func shiftDay(_ n: Int) { selectedDate = DateKey.addDays(n, to: selectedDate) }
    func goToday() { selectedDate = DateKey.today() }

    // MARK: - Günlük giriş

    func entryBinding(item: String, date: String, _ kp: WritableKeyPath<DayEntry, Double?>) -> Binding<Double?> {
        Binding(get: { self.data.days[date]?.entries[item]?[keyPath: kp] },
                set: { v in self.updateEntry(item, date: date) { $0[keyPath: kp] = v } })
    }

    func updateEntry(_ itemID: String, date: String, _ mutate: (inout DayEntry) -> Void) {
        mutateData { d in
            var day = d.days[date] ?? DayRecord(date: date)
            var e = day.entries[itemID] ?? DayEntry()
            mutate(&e)
            if e.isEmpty { day.entries[itemID] = nil } else { day.entries[itemID] = e }
            if day.isEmpty { d.days[date] = nil } else { d.days[date] = day }
        }
    }

    // MARK: - Satış içe aktarma

    func beginImport(url: URL) {
        do {
            presentImport(try SalesParser.parse(fileURL: url))
        } catch {
            alert = AppAlert(title: "Satış raporu okunamadı", message: error.localizedDescription)
        }
    }

    func beginPasteImport() {
        guard let s = NSPasteboard.general.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            alert = AppAlert(title: "Pano boş", message: "ModPos satış raporundan Kodu, Ürün Tipi ve Adedi sütunlarını kopyalayıp tekrar deneyin.")
            return
        }
        let r = SalesParser.parse(text: s, sourceName: "Panodan yapıştırıldı")
        guard !r.lines.isEmpty else {
            alert = AppAlert(title: "Satış verisi bulunamadı",
                             message: "Panodaki metinde ürün kodu ve adet içeren satır yok. ModPos raporundan Kodu, Ürün Tipi ve Adedi sütunlarını kopyalayın.")
            return
        }
        presentImport(r)
    }

    func pickAndImportFile() {
        guard let url = Files.openFile(types: Files.salesTypes, message: "ModPos satış raporunu seçin (.xlsx, .csv, .txt)") else { return }
        beginImport(url: url)
    }

    private func presentImport(_ r: SalesReport) { importPreview = ImportPreview(report: r) }

    // MARK: - Excel envanter dosyasından içe aktarma

    func pickAndImportWorkbook() {
        let types = ["xlsm", "xlsx"].compactMap { UTType(filenameExtension: $0) }
        guard let url = Files.openFile(types: types, message: "Eski Excel envanter dosyasını seçin (ör. 01.08.xlsm)") else { return }
        do {
            workbookPreview = WorkbookPreview(imp: try WorkbookImporter.parse(url: url, items: data.items))
        } catch {
            alert = AppAlert(title: "Excel dosyası aktarılamadı", message: error.localizedDescription)
        }
    }

    func conflicts(for imp: WorkbookImport) -> [String] { WorkbookImporter.conflicts(imp, in: data) }

    func confirmWorkbookImport(_ imp: WorkbookImport, overwrite: Bool) {
        var report = WorkbookImportReport()
        mutateData { report = WorkbookImporter.apply(imp, to: &$0, overwrite: overwrite) }
        workbookPreview = nil
        if let d = imp.currentDate ?? imp.historyDates.last { selectedDate = d }
        section = .daily
        alert = AppAlert(title: "Excel verileri aktarıldı",
                         message: "\(report.added) gün eklendi" + (report.replaced > 0 ? ", \(report.replaced) gün değiştirildi" : "")
                            + (report.skippedExisting > 0 ? ", verisi olan \(report.skippedExisting) güne dokunulmadı" : "") + ".")
    }

    /// Verisi olan günler (yeniden eskiye)
    var recordedDates: [String] { engine.datesWithData.reversed() }

    func confirmImport(report: SalesReport, date: String) {
        mutateData { d in
            var day = d.days[date] ?? DayRecord(date: date)
            day.sales = report.lines
            day.salesSource = report.sourceName
            day.salesPeriod = report.periodText
            day.salesImportedAt = Date()
            d.days[date] = day
        }
        selectedDate = date
        importPreview = nil
    }

    func clearSales(date: String) {
        mutateData { d in
            guard var day = d.days[date] else { return }
            day.sales = []; day.salesSource = nil; day.salesPeriod = nil; day.salesImportedAt = nil
            if day.isEmpty { d.days[date] = nil } else { d.days[date] = day }
        }
    }

    // MARK: - Reçeteler

    func product(_ code: String) -> Product? { engine.productsByCode[code] }

    func updateProduct(_ code: String, _ mutate: (inout Product) -> Void) {
        mutateData { d in
            guard let i = d.products.firstIndex(where: { $0.code == code }) else { return }
            mutate(&d.products[i])
        }
    }

    @discardableResult
    func addProduct(_ p: Product) -> Bool {
        guard engine.productsByCode[p.code] == nil else { return false }
        mutateData { $0.products.append(p) }
        return true
    }

    func deleteProduct(_ code: String) {
        mutateData { $0.products.removeAll { $0.code == code } }
        if recipeSelection == code { recipeSelection = nil }
    }

    func startNewProduct(from line: SaleLine) {
        newProductDraft = line
        section = .recipes
    }

    // MARK: - Stok kalemleri

    func updateItem(_ id: String, _ mutate: (inout Item) -> Void) {
        mutateData { d in
            guard let i = d.items.firstIndex(where: { $0.id == id }) else { return }
            mutate(&d.items[i])
        }
    }

    func addItem(name: String, unit: String) {
        var base = name.lowercased().filter { $0.isLetter || $0.isNumber }
        if base.isEmpty { base = "kalem" }
        var id = base, n = 2
        while data.items.contains(where: { $0.id == id }) { id = "\(base)\(n)"; n += 1 }
        let isKg = unit == "Kg"
        mutateData { $0.items.append(Item(id: id, name: name, unit: unit, recipeUnit: isKg ? "kg" : "adet", factor: 1)) }
    }

    func deleteItem(_ id: String) {
        mutateData { d in
            d.items.removeAll { $0.id == id }
            for i in d.products.indices { d.products[i].amounts[id] = nil }
            for (k, var day) in d.days {
                day.entries[id] = nil
                if day.isEmpty { d.days[k] = nil } else { d.days[k] = day }
            }
        }
    }

    func moveItems(from: IndexSet, to: Int) {
        mutateData { $0.items.move(fromOffsets: from, toOffset: to) }
    }

    /// Silinmiş varsayılan reçete/kalemleri geri ekler; mevcut düzenlemelere dokunmaz.
    @discardableResult
    func restoreMissingDefaults() -> (items: Int, products: Int) {
        let seed = AppData.seeded()
        var addedItems = 0, addedProducts = 0
        mutateData { d in
            let ids = Set(d.items.map { $0.id }), codes = Set(d.products.map { $0.code })
            for i in seed.items where !ids.contains(i.id) { d.items.append(i); addedItems += 1 }
            for p in seed.products where !codes.contains(p.code) { d.products.append(p); addedProducts += 1 }
        }
        return (addedItems, addedProducts)
    }

    // MARK: - Dışa / içe aktarma

    func exportDayExcel() {
        let bytes = Exporter.day(engine: engine, date: selectedDate)
        Files.save(bytes, suggestedName: "Envanter \(DateKey.short(selectedDate)).xlsx", type: Files.xlsx) { [weak self] url in
            self?.revealOrReport(url)
        }
    }

    func exportHistoryExcel(from: String, to: String) {
        let bytes = Exporter.history(engine: engine, from: from, to: to)
        Files.save(bytes, suggestedName: "Envanter \(DateKey.short(from)) - \(DateKey.short(to)).xlsx", type: Files.xlsx) { [weak self] url in
            self?.revealOrReport(url)
        }
    }

    private func revealOrReport(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    func exportBackup() {
        guard let bytes = try? persistence.encode(data) else { return }
        Files.save(bytes, suggestedName: "Envanter Yedek \(DateKey.today()).json", type: .json) { [weak self] url in
            self?.revealOrReport(url)
        }
    }

    func restoreBackup() {
        guard let url = Files.openFile(types: [.json], message: "Geri yüklenecek yedek dosyasını seçin") else { return }
        do {
            let restored = try Persistence.decode(Data(contentsOf: url))
            // Mevcut hali güvenlik için ayrıca yedekle
            if let current = try? persistence.encode(data) {
                try? current.write(to: persistence.backupDirectory.appendingPathComponent("geri-yukleme-oncesi-\(Int(Date().timeIntervalSince1970)).json"))
            }
            data = restored
            alert = AppAlert(title: "Yedek geri yüklendi", message: "\(restored.days.count) günlük kayıt ve \(restored.products.count) ürün reçetesi yüklendi.")
        } catch {
            alert = AppAlert(title: "Yedek okunamadı", message: "Dosya geçerli bir Envanter yedeği değil.")
        }
    }
}

// MARK: - Dosya diyalogları

enum Files {
    static let xlsx = UTType(filenameExtension: "xlsx") ?? .data
    static let salesTypes: [UTType] = {
        var t: [UTType] = [.commaSeparatedText, .tabSeparatedText, .plainText]
        if let x = UTType(filenameExtension: "xlsx") { t.append(x) }
        if let m = UTType(filenameExtension: "xlsm") { t.append(m) }
        return t
    }()

    @MainActor
    static func openFile(types: [UTType], message: String) -> URL? {
        let p = NSOpenPanel()
        p.message = message
        p.allowedContentTypes = types
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = false
        return p.runModal() == .OK ? p.url : nil
    }

    @MainActor
    static func save(_ data: Data, suggestedName: String, type: UTType, completion: (URL) -> Void) {
        let p = NSSavePanel()
        p.nameFieldStringValue = suggestedName
        p.allowedContentTypes = [type]
        p.canCreateDirectories = true
        guard p.runModal() == .OK, let url = p.url else { return }
        do { try data.write(to: url, options: .atomic); completion(url) }
        catch {
            let a = NSAlert(); a.messageText = "Dosya kaydedilemedi"; a.informativeText = error.localizedDescription; a.runModal()
        }
    }
}
