import SwiftUI
import AppKit
import UniformTypeIdentifiers
import EnvanterCore

enum AppSection: String, CaseIterable, Identifiable {
    case overview, daily, sales, summary, analytics, orders, recipes, items, backup, help
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return "Genel Bakış"
        case .daily: return "Günlük Envanter"
        case .sales: return "Satış Dökümü"
        case .summary: return "Özet ve Raporlar"
        case .analytics: return "İstatistikler"
        case .orders: return "Sipariş Önerisi"
        case .recipes: return "Reçeteler"
        case .items: return "Stok Kalemleri"
        case .backup: return "Ayarlar ve Veri"
        case .help: return "Nasıl Kullanılır?"
        }
    }
    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .daily: return "checklist"
        case .sales: return "cart"
        case .summary: return "tablecells"
        case .analytics: return "chart.xyaxis.line"
        case .orders: return "shippingbox.and.arrow.backward"
        case .recipes: return "fork.knife"
        case .items: return "shippingbox"
        case .backup: return "gearshape"
        case .help: return "questionmark.circle"
        }
    }
    /// ⌘1… kısayolu
    var shortcut: KeyEquivalent? {
        switch self {
        case .overview: return "1"
        case .daily: return "2"
        case .sales: return "3"
        case .summary: return "4"
        case .analytics: return "5"
        case .orders: return "6"
        case .recipes: return "7"
        case .items: return "8"
        case .backup: return "9"
        case .help: return nil
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

enum SaveState: Equatable {
    case saved, saving, failed(String)
}

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var data: AppData {
        didSet { engineCache = nil; scheduleSave() }
    }
    @Published var selectedDate: String = DateKey.today()
    @Published var section: AppSection? = .overview
    @Published var importPreview: ImportPreview?
    @Published var workbookPreview: WorkbookPreview?
    @Published var alert: AppAlert?
    /// Reçeteler ekranında seçili ürün kodu
    @Published var recipeSelection: String?
    /// Satış dökümünden "Reçete tanımla" ile açılan taslak
    @Published var newProductDraft: SaleLine?
    /// İstatistikler > Kalem analizi ekranında seçili stok kalemi
    @Published var analyticsItem: String?
    @Published var analyticsTab: AnalyticsTab = .general
    @Published private(set) var saveState: SaveState = .saved
    @Published private(set) var lastSavedAt: Date?

    let persistence: Persistence
    /// Pencerenin geri alma yöneticisi (ContentView bağlar); Düzen > Geri Al / Yinele ile çalışır
    weak var undoManager: UndoManager?
    private var engineCache: Engine?
    private var saveTask: Task<Void, Never>?
    private let saveQueue = DispatchQueue(label: "envanter.save", qos: .utility)
    private var saveGeneration = 0
    private var lastBackupAt: Date?
    private var saveErrorReported = false

    var engine: Engine {
        if let e = engineCache { return e }
        let e = Engine(data: data)
        engineCache = e
        return e
    }

    var settings: AppSettings { data.settings }

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
        case .unreadable(let moved):
            data = AppData.seeded()
            startupAlert = AppAlert(
                title: "Veri dosyası okunamadı",
                message: "Veri dosyası bozuk ve kullanılabilir yedek bulunamadı. Dosya \"\(moved)\" adıyla veri klasöründe saklandı; uygulama varsayılan reçetelerle açıldı. Elinizde yedek dosyası varsa Ayarlar ve Veri ekranından geri yükleyin.")
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
        saveState = .saving
        saveTask = Task { [weak self] in
            if !immediately { try? await Task.sleep(nanoseconds: 400_000_000) }
            guard !Task.isCancelled else { return }
            self?.writeNow()
        }
    }

    /// Kodlama ve yazma arka planda yapılır; günlük yedek en fazla 10 dakikada bir güncellenir.
    private func writeNow() {
        let snapshot = data
        let p = persistence
        let backup = lastBackupAt.map { Date().timeIntervalSince($0) > 600 } ?? true
        if backup { lastBackupAt = Date() }
        saveGeneration += 1
        let generation = saveGeneration
        saveQueue.async { [weak self] in
            var failure: String?
            do {
                let encoded = try p.encode(snapshot)
                try p.write(encoded)
                if backup { p.dailyBackup(encoded) }
            } catch {
                failure = error.localizedDescription
                NSLog("Kayıt hatası: \(error)")
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finishSave(failure: failure, generation: generation) }
            }
        }
    }

    private func finishSave(failure: String?, generation: Int) {
        if let failure {
            saveState = .failed(failure)
            if !saveErrorReported {
                saveErrorReported = true
                alert = AppAlert(title: "Kaydedilemedi",
                                 message: "Değişiklikler diske yazılamadı: \(failure)\nDisk dolu olabilir ya da veri klasörüne yazma izni yoktur. Sorun giderilince bir sonraki değişiklikte tekrar denenir.")
            }
        } else if generation == saveGeneration {
            saveState = .saved
            lastSavedAt = Date()
            saveErrorReported = false
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

    // MARK: - Değişiklik + geri alma

    /// Veriyi değiştirir ve işlemi pencerenin geri alma geçmişine ekler.
    func mutateData(_ actionName: String? = nil, _ f: (inout AppData) -> Void) {
        var d = data
        f(&d)
        setData(d, actionName: actionName)
    }

    private func setData(_ new: AppData, actionName: String?) {
        let old = data
        data = new
        guard let um = undoManager else { return }
        um.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated { store.setData(old, actionName: actionName) }
        }
        if let actionName { um.setActionName(actionName) }
    }

    // MARK: - Gün gezinme

    var dateBinding: Binding<Date> {
        Binding(get: { DateKey.date(from: self.selectedDate) ?? Date() },
                set: { self.selectedDate = DateKey.string(from: $0) })
    }
    func shiftDay(_ n: Int) { selectedDate = DateKey.addDays(n, to: selectedDate) }
    func goToday() { selectedDate = DateKey.today() }

    // MARK: - Günlük giriş

    func isLocked(_ date: String) -> Bool { data.days[date]?.isLocked ?? false }

    func entryBinding(item: String, date: String, _ kp: WritableKeyPath<DayEntry, Double?>) -> Binding<Double?> {
        Binding(get: { self.data.days[date]?.entries[item]?[keyPath: kp] },
                set: { v in self.updateEntry(item, date: date) { $0[keyPath: kp] = v } })
    }

    func updateEntry(_ itemID: String, date: String, _ mutate: (inout DayEntry) -> Void) {
        guard !isLocked(date) else { NSSound.beep(); return }
        mutateData("Sayım Girişi") { d in
            var day = d.days[date] ?? DayRecord(date: date)
            var e = day.entries[itemID] ?? DayEntry()
            mutate(&e)
            if e.isEmpty { day.entries[itemID] = nil } else { day.entries[itemID] = e }
            if day.isEmpty { d.days[date] = nil } else { d.days[date] = day }
        }
    }

    func updateDay(_ date: String, actionName: String, _ mutate: (inout DayRecord) -> Void) {
        mutateData(actionName) { d in
            var day = d.days[date] ?? DayRecord(date: date)
            mutate(&day)
            if day.isEmpty && !day.isLocked { d.days[date] = nil } else { d.days[date] = day }
        }
    }

    func setLocked(_ date: String, _ locked: Bool) {
        updateDay(date, actionName: locked ? "Günü Kapat" : "Gün Kilidini Aç") { $0.locked = locked ? true : nil }
    }

    func setDayNote(_ date: String, _ text: String) {
        let v = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard v != (data.days[date]?.note ?? "") else { return }
        updateDay(date, actionName: "Gün Notu") { $0.note = v.isEmpty ? nil : v }
    }

    func setCountedBy(_ date: String, _ name: String) {
        let v = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard v != (data.days[date]?.countedBy ?? "") else { return }
        updateDay(date, actionName: "Sayımı Yapan") { $0.countedBy = v.isEmpty ? nil : v }
        rememberStaff(v)
    }

    private func rememberStaff(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, !settings.staff.contains(n) else { return }
        mutateData { $0.settings.staff.append(n) }
    }

    /// Sayımı yapılmamış kalemlere önceki günün kapanışını aynen yazar (hareket olmayan kalemler için hızlı doldurma).
    func fillUncountedWithOpening(date: String) -> Int {
        guard !isLocked(date) else { return 0 }
        let rows = engine.calc(date: date).rows.filter { !$0.isCounted && $0.incoming == 0 && $0.transferIn == 0 && $0.transferOut == 0 && $0.sold == 0 && $0.waste == 0 && $0.opening > 0 }
        guard !rows.isEmpty else { return 0 }
        mutateData("Hareketsiz Kalemleri Doldur") { d in
            var day = d.days[date] ?? DayRecord(date: date)
            for r in rows { day.entries[r.itemID, default: DayEntry()].closing = r.opening }
            d.days[date] = day
        }
        return rows.count
    }

    // MARK: - Ayarlar

    func updateSettings(_ actionName: String = "Ayarlar", _ mutate: (inout AppSettings) -> Void) {
        mutateData(actionName) { mutate(&$0.settings) }
    }

    func settingsBinding<T>(_ kp: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(get: { self.data.settings[keyPath: kp] }, set: { v in self.updateSettings { $0[keyPath: kp] = v } })
    }

    // MARK: - Satış içe aktarma

    /// Satış raporu veya (sürüklenen) eski Excel envanter dosyası
    func beginImport(url: URL) {
        let ext = url.pathExtension.lowercased()
        if ext == "xlsm" { importWorkbook(url: url); return }
        do {
            presentImport(try SalesParser.parse(fileURL: url))
        } catch SalesParseError.noLines where ext == "xlsx" {
            // Satış raporu değilse eski envanter dosyası olabilir
            if let imp = try? WorkbookImporter.parse(url: url, items: data.items) {
                workbookPreview = WorkbookPreview(imp: imp)
            } else {
                alert = AppAlert(title: "Satış raporu okunamadı", message: SalesParseError.noLines.localizedDescription)
            }
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
        importWorkbook(url: url)
    }

    private func importWorkbook(url: URL) {
        do {
            workbookPreview = WorkbookPreview(imp: try WorkbookImporter.parse(url: url, items: data.items))
        } catch {
            alert = AppAlert(title: "Excel dosyası aktarılamadı", message: error.localizedDescription)
        }
    }

    func conflicts(for imp: WorkbookImport) -> [String] { WorkbookImporter.conflicts(imp, in: data) }

    func confirmWorkbookImport(_ imp: WorkbookImport, overwrite: Bool) {
        if let current = try? persistence.encode(data) { persistence.snapshot(current, label: "aktarim-oncesi") }
        var report = WorkbookImportReport()
        mutateData("Excel'den Aktarım") { report = WorkbookImporter.apply(imp, to: &$0, overwrite: overwrite) }
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
        guard !isLocked(date) else {
            alert = AppAlert(title: "Gün kapatılmış", message: "\(DateKey.short(date)) günü kilitli. Satış aktarmak için önce günün kilidini açın.")
            return
        }
        mutateData("Satış Raporu Aktarımı") { d in
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
        guard !isLocked(date) else { NSSound.beep(); return }
        mutateData("Satışları Sil") { d in
            guard var day = d.days[date] else { return }
            day.sales = []; day.salesSource = nil; day.salesPeriod = nil; day.salesImportedAt = nil
            if day.isEmpty { d.days[date] = nil } else { d.days[date] = day }
        }
    }

    // MARK: - Reçeteler

    func product(_ code: String) -> Product? { engine.productsByCode[code] }

    func updateProduct(_ code: String, actionName: String = "Reçete Düzenleme", _ mutate: (inout Product) -> Void) {
        mutateData(actionName) { d in
            guard let i = d.products.firstIndex(where: { $0.code == code }) else { return }
            mutate(&d.products[i])
        }
    }

    @discardableResult
    func addProduct(_ p: Product) -> Bool {
        guard engine.productsByCode[p.code] == nil else { return false }
        mutateData("Ürün Ekle") { $0.products.append(p) }
        return true
    }

    func deleteProduct(_ code: String) {
        mutateData("Ürün Sil") { $0.products.removeAll { $0.code == code } }
        if recipeSelection == code { recipeSelection = nil }
    }

    func startNewProduct(from line: SaleLine) {
        newProductDraft = line
        section = .recipes
    }

    // MARK: - Stok kalemleri

    func updateItem(_ id: String, actionName: String = "Stok Kalemi Düzenleme", _ mutate: (inout Item) -> Void) {
        mutateData(actionName) { d in
            guard let i = d.items.firstIndex(where: { $0.id == id }) else { return }
            mutate(&d.items[i])
        }
    }

    func addItem(name: String, unit: String) {
        var base = name.lowercased(with: Locale(identifier: "tr_TR")).filter { $0.isLetter || $0.isNumber }
        if base.isEmpty { base = "kalem" }
        var id = base, n = 2
        while data.items.contains(where: { $0.id == id }) { id = "\(base)\(n)"; n += 1 }
        let isKg = unit == "Kg"
        mutateData("Stok Kalemi Ekle") { $0.items.append(Item(id: id, name: name, unit: unit, recipeUnit: isKg ? "kg" : "adet", factor: 1)) }
    }

    func deleteItem(_ id: String) {
        mutateData("Stok Kalemi Sil") { d in
            d.items.removeAll { $0.id == id }
            for i in d.products.indices { d.products[i].amounts[id] = nil }
            for (k, var day) in d.days {
                day.entries[id] = nil
                day.legacySold?[id] = nil
                day.legacyWaste?[id] = nil
                if day.isEmpty { d.days[k] = nil } else { d.days[k] = day }
            }
        }
    }

    func moveItems(from: IndexSet, to: Int) {
        mutateData("Sıralama") { $0.items.move(fromOffsets: from, toOffset: to) }
    }

    /// Silinmiş varsayılan reçete/kalemleri geri ekler; mevcut düzenlemelere dokunmaz.
    @discardableResult
    func restoreMissingDefaults() -> (items: Int, products: Int) {
        let seed = AppData.seeded()
        var addedItems = 0, addedProducts = 0
        mutateData("Varsayılanları Geri Ekle") { d in
            let ids = Set(d.items.map { $0.id }), codes = Set(d.products.map { $0.code })
            for i in seed.items where !ids.contains(i.id) { d.items.append(i); addedItems += 1 }
            for p in seed.products where !codes.contains(p.code) { d.products.append(p); addedProducts += 1 }
        }
        return (addedItems, addedProducts)
    }

    // MARK: - İstatistikler

    /// İstatistikler açılırken: seçili gün verilen aralığın dışındaysa seçili günle biten 30 günlük aralık önerir.
    func analyticsRange(containingSelectedDate from: String, _ to: String) -> (from: String, to: String)? {
        guard selectedDate < from || selectedDate > to else { return nil }
        return (DateKey.addDays(-29, to: selectedDate), selectedDate)
    }

    func openItemAnalysis(_ itemID: String) {
        analyticsItem = itemID
        analyticsTab = .item
        section = .analytics
    }

    // MARK: - Sipariş önerisi

    func orderSuggestions(date: String) -> [OrderSuggestion] {
        engine.orderSuggestions(asOf: date, lookbackDays: settings.orderLookbackDays, coverDays: settings.orderCoverDays)
    }

    func copyOrderText(date: String) {
        let text = Exporter.orderText(orderSuggestions(date: date), date: date, branch: settings.branchName)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func exportOrdersExcel(date: String) {
        let bytes = Exporter.orders(orderSuggestions(date: date), date: date)
        Files.save(bytes, suggestedName: fileName("Sipariş \(DateKey.short(date))"), type: Files.xlsx) { [weak self] url in
            self?.reveal(url)
        }
    }

    // MARK: - Dışa / içe aktarma

    /// "NextGen Envanter – Kadıköy – 01.08.2026.xlsx"
    private func fileName(_ base: String, ext: String = "xlsx") -> String {
        let branch = settings.branchName.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return ([Brand.appName] + (branch.isEmpty ? [] : [branch]) + [base]).joined(separator: " – ") + ".\(ext)"
    }

    func exportDayExcel() {
        let bytes = Exporter.day(engine: engine, date: selectedDate)
        Files.save(bytes, suggestedName: fileName(DateKey.short(selectedDate)), type: Files.xlsx) { [weak self] url in
            self?.reveal(url)
        }
    }

    func exportCountSheet() {
        let bytes = Exporter.countSheet(engine: engine, date: selectedDate, branch: settings.branchName)
        Files.save(bytes, suggestedName: fileName("Sayım Formu \(DateKey.short(selectedDate))"), type: Files.xlsx) { [weak self] url in
            self?.reveal(url)
        }
    }

    func exportHistoryExcel(from: String, to: String) {
        let bytes = Exporter.history(engine: engine, from: from, to: to)
        Files.save(bytes, suggestedName: fileName("\(DateKey.short(from)) - \(DateKey.short(to))"), type: Files.xlsx) { [weak self] url in
            self?.reveal(url)
        }
    }

    private func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    func exportBackup() {
        guard let bytes = try? persistence.encode(data) else { return }
        Files.save(bytes, suggestedName: fileName("Yedek \(DateKey.short(DateKey.today()))", ext: "json"), type: .json) { [weak self] url in
            self?.reveal(url)
        }
    }

    func restoreBackup() {
        guard let url = Files.openFile(types: [.json], message: "Geri yüklenecek yedek dosyasını seçin") else { return }
        do {
            let restored = try Persistence.decode(Data(contentsOf: url))
            // Mevcut hali güvenlik için ayrıca yedekle
            if let current = try? persistence.encode(data) { persistence.snapshot(current, label: "geri-yukleme-oncesi") }
            mutateData("Yedekten Geri Yükleme") { $0 = restored }
            alert = AppAlert(title: "Yedek geri yüklendi",
                             message: "\(Engine(data: restored).datesWithData.count) günlük kayıt ve \(restored.products.count) ürün reçetesi yüklendi. Önceki hal \"Yedekler\" klasörüne kaydedildi; Düzen > Geri Al ile de dönebilirsiniz.")
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
