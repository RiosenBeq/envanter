import SwiftUI
import AppKit
import UniformTypeIdentifiers
import EnvanterCore

enum AppSection: String, CaseIterable, Identifiable {
    case overview, daily, sales, orders, labor, summary, analytics, recipes, items, backup, help
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return "Genel Bakış"
        case .daily: return "Günlük Envanter"
        case .sales: return "Satış Dökümü"
        case .summary: return "Özet ve Raporlar"
        case .analytics: return "İstatistikler"
        case .orders: return "Sipariş Önerisi"
        case .labor: return "Personel"
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
        case .labor: return "person.2"
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
        case .orders: return "4"
        case .labor: return "5"
        case .summary: return "6"
        case .analytics: return "7"
        case .recipes: return "8"
        case .items: return "9"
        case .backup: return ","
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
    /// Web eşitlemesinde bu Mac'in şubedeki rolü (CloudSyncController günceller; eşleşme yoksa nil). Personel ise
    /// tanım belgeleri ve kapatılmış günler bu Mac'te de salt okunurdur (docs/SYNC.md §2).
    @Published var enforcedRole: String?
    /// Onay bekleyen gün kapatma (personel: kapatılan günün kilidini yalnızca patron veya müdür açabilir)
    @Published var pendingDayClose: String?

    let persistence: Persistence
    /// Web paneliyle (Supabase) arka planda eşitleme
    let cloud: CloudSyncController
    /// Pencerenin geri alma yöneticisi (ContentView bağlar); Düzen > Geri Al / Yinele ile çalışır
    weak var undoManager: UndoManager?
    private var engineCache: Engine?
    private var saveTask: Task<Void, Never>?
    /// Veri dosyası ve eşitleme durumu aynı seri kuyrukta yazılır (DiskWriteQueue): kodlama ve yazma arka planda
    /// yapılır, eşitlemenin kayıt noktasında önce veri sonra durum sırası korunur.
    let diskQueue: DiskWriteQueue
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

    /// Stok kalemleri, reçeteler, ayarlar, personel ve siparişler değiştirilebilir mi (personel hesabıyla hayır)
    var canEditCatalog: Bool { CloudRole.canWriteCatalog(enforcedRole) }
    /// Kapatılmış günü değiştirme / kilidini açma yetkisi (personel hesabıyla yok)
    var canChangeLockedDays: Bool { CloudRole.canChangeLockedDay(enforcedRole) }
    /// Gün bu kullanıcı için salt okunur mu: kapatılmış ve kilidi açılamıyor
    func isReadOnlyDay(_ date: String) -> Bool { isLocked(date) && !canChangeLockedDays }

    init(persistence: Persistence = Persistence(directory: Persistence.defaultDirectory())) {
        self.persistence = persistence
        let queue = DiskWriteQueue(label: "envanter.save")
        diskQueue = queue
        // Otomatik test ve ekran görüntüsü modlarında web eşitlemesi kapalıdır
        let env = ProcessInfo.processInfo.environment
        let automated = !(env["ENVANTER_SELFTEST"] ?? "").isEmpty || !(env["ENVANTER_SNAPSHOT_DIR"] ?? "").isEmpty
        cloud = CloudSyncController(directory: persistence.directory, enabled: !automated, diskQueue: queue)
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
        if !FileManager.default.fileExists(atPath: persistence.dataFile.path) {
            scheduleSave(immediately: true)
        } else if !FileManager.default.fileExists(atPath: persistence.backupDirectory.appendingPathComponent("envanter-\(DateKey.today()).json").path),
                  let encoded = try? persistence.encode(data) {
            // Günün ilk açılışı: henüz değişiklik yapılmadan günün yedeğini al
            let p = persistence
            diskQueue.async { p.dailyBackup(encoded) }
            lastBackupAt = Date()
        }
        cloud.attach(self)
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
        let job = makeWriteJob()
        diskQueue.async { _ = job() }
    }

    /// Şu anki verinin yazma işi (kuyrukta çalışır): kodlar, yazar, zamanı geldiyse günlük yedeği günceller ve sonucu
    /// ana iş parçacığına bildirir. Kopya burada (ana iş parçacığında) alınır; kodlama ve yazma kuyrukta yapılır.
    /// - Returns: iş; çalışınca veri dosyası yazıldı mı
    private func makeWriteJob() -> @Sendable () -> Bool {
        let snapshot = data
        let p = persistence
        let backup = lastBackupAt.map { Date().timeIntervalSince($0) > 600 } ?? true
        if backup { lastBackupAt = Date() }
        saveGeneration += 1
        let generation = saveGeneration
        return { [weak self] in
            var failure: String?
            do {
                let encoded = try p.encode(snapshot)
                try p.write(encoded)
                if backup { p.dailyBackup(encoded) }
            } catch {
                failure = error.localizedDescription
                NSLog("Kayıt hatası: \(error)")
            }
            let result = failure, owner = self
            DispatchQueue.main.async {
                MainActor.assumeIsolated { owner?.finishSave(failure: result, generation: generation) }
            }
            return result == nil
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

    /// Web eşitlemesinin kayıt noktası (SyncCheckpoint, docs/SYNC.md §3 "Kayıt sırası"): yerel veri değiştiyse önce veri
    /// dosyası, sonra eşitleme durumu (`writeState`) yazılır; veri yazılamazsa durum yazılmaz. İkisi de arka planda,
    /// durumun diğer kayıtlarıyla aynı seri kuyrukta yazılır: ana iş parçacığı kodlamayı ve yazmayı beklemez, sonradan
    /// kuyruğa giren durum kaydı da bu verinin önüne geçemez. Bekleyen (gecikmeli) kayıt bu yazmaya katılır.
    func syncCheckpoint(dataChanged: Bool, writeState: @escaping @Sendable () -> Void) {
        var job: (@Sendable () -> Bool)?
        if dataChanged {
            saveTask?.cancel()
            job = makeWriteJob()
        }
        diskQueue.checkpoint(writeData: job, writeState: writeState)
    }

    /// Bekleyen değişiklikleri hemen (eşzamanlı) diske yazar.
    func flush() {
        saveTask?.cancel()
        guard let encoded = try? persistence.encode(data) else { return }
        diskQueue.sync { [persistence] in
            try? persistence.write(encoded)
            persistence.dailyBackup(encoded)
        }
    }

    // MARK: - Değişiklik + geri alma

    /// Veriyi değiştirir ve işlemi pencerenin geri alma geçmişine ekler.
    /// - Returns: uygulandı mı (personel hesabıyla yetkisiz işlem bütünüyle reddedilir)
    @discardableResult
    func mutateData(_ actionName: String? = nil, _ f: (inout AppData) -> Void) -> Bool {
        var d = data
        f(&d)
        return setData(d, actionName: actionName)
    }

    @discardableResult
    private func setData(_ new: AppData, actionName: String?) -> Bool {
        let old = data
        // Değişen belgeler (items, products, settings, employees, orders, day:YYYY-MM-DD)
        let keys = DocCodec.changedKeys(old, new)
        // Personel hesabıyla: tanım belgelerine ya da kapatılmış güne dokunan işlem bütünüyle reddedilir. Sunucu da
        // reddeder; yarısı gönderilip yarısı geri alınan işlem (ör. teslim alma: Gelen gider, sipariş açık kalır;
        // kalem silme: günlerden sayımlar silinir, kalem geri gelir) veriyi bozardı.
        if let refusal = CloudPermission.refusal(role: enforcedRole, old: old, keys: keys) {
            NSSound.beep()
            alert = AppAlert(title: refusal.title, message: refusal.message)
            return false
        }
        data = new
        cloud.noteLocalChange(keys)
        guard let um = undoManager else { return true }
        // Geri alma yalnızca bu işlemin değiştirdiği belgelere ve onlarda yalnızca bu işlemin değiştirdiği alanlara
        // dokunur: arada web panelinden gelen değişiklikler (ör. aynı günde müdürün düzelttiği başka kalem, not ya da
        // patronun değiştirdiği maliyet) geri alınmaz.
        um.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated {
                store.setData(DocCodec.undoing(keys: keys, old: old, new: new, current: store.data), actionName: actionName)
            }
        }
        if let actionName { um.setActionName(actionName) }
        return true
    }

    /// Web panelinden (buluttan) gelen veriyi uygular: geri alma geçmişine eklenmez ve yeniden gönderilmek üzere
    /// işaretlenmez. Kayıt ve hesap önbelleği normal değişiklikteki gibi yenilenir.
    func applyRemote(_ new: AppData) {
        data = new
    }

    /// Geri alma geçmişini temizler (buluttaki veri indirildikten sonra eski adımlar onun üzerine yazmasın)
    func clearUndoHistory() {
        undoManager?.removeAllActions()
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

    @discardableResult
    func updateDay(_ date: String, actionName: String, _ mutate: (inout DayRecord) -> Void) -> Bool {
        mutateData(actionName) { d in
            var day = d.days[date] ?? DayRecord(date: date)
            mutate(&day)
            if day.isEmpty && !day.isLocked { d.days[date] = nil } else { d.days[date] = day }
        }
    }

    func setLocked(_ date: String, _ locked: Bool) {
        updateDay(date, actionName: locked ? "Günü Kapat" : "Gün Kilidini Aç") { $0.locked = locked ? true : nil }
    }

    /// "Günü Kapat / Kilidi Aç" isteğinin sonucu (Gün menüsü ⌘L ve Günlük Envanter düğmesi aynı kuralı kullanır)
    func lockAction(_ date: String) -> DayLockAction {
        DayLockAction.resolve(locked: isLocked(date), counted: engine.hasCount(date: date), role: enforcedRole)
    }

    /// Gün menüsündeki öğenin adı (personel hesabıyla kapatma onay ister: "…")
    func lockMenuTitle(_ date: String) -> String {
        if isLocked(date) { return "Gün Kilidini Aç" }
        return lockAction(date) == .confirmClose ? "Günü Kapat…" : "Günü Kapat"
    }

    /// Gün menüsü (⌘L) ve Günlük Envanter düğmesi: sayım yapılmamış (boş ya da ileri tarihli) gün kapatılmaz; personel
    /// hesabıyla gün onaydan sonra kapatılır (kilidini yalnızca patron veya müdür açabilir), kilit açılamaz.
    func requestLockToggle(_ date: String) {
        switch lockAction(date) {
        case .close: setLocked(date, true)
        case .unlock: setLocked(date, false)
        case .confirmClose: pendingDayClose = date
        case .nothingCounted, .unlockNotAllowed: NSSound.beep()
        }
    }

    /// Personelin onayladığı gün kapatma
    func confirmDayClose(_ date: String) {
        pendingDayClose = nil
        let action = lockAction(date)
        guard action == .confirmClose || action == .close else { return }
        setLocked(date, true)
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

    /// Personel hesabıyla ayarlar yazılamadığından ad listeye eklenmez (her yeni ad reddedilen bir yazma olurdu)
    private func rememberStaff(_ name: String) {
        guard let updated = settings.rememberingStaff(name, role: enforcedRole) else { return }
        mutateData { $0.settings = updated }
    }

    /// Sayımı yapılmamış kalemlere önceki günün kapanışını aynen yazar (hareket olmayan kalemler için hızlı doldurma).
    func fillUncountedWithOpening(date: String) -> Int {
        guard !isLocked(date) else { return 0 }
        let rows = engine.calc(date: date).rows.filter { !$0.isCounted && $0.incoming == 0 && $0.transferIn == 0 && $0.transferOut == 0 && $0.sold == 0 && $0.waste == 0 && $0.opening > 0 }
        guard !rows.isEmpty else { return 0 }
        let applied = mutateData("Hareketsiz Kalemleri Doldur") { d in
            var day = d.days[date] ?? DayRecord(date: date)
            for r in rows { day.entries[r.itemID, default: DayEntry()].closing = r.opening }
            d.days[date] = day
        }
        return applied ? rows.count : 0
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
        let applied = mutateData("Excel'den Aktarım") { report = WorkbookImporter.apply(imp, to: &$0, overwrite: overwrite) }
        workbookPreview = nil
        guard applied else { return }
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
            // Personel kilidi kendisi açamaz: başka gün seçmesi söylenir
            let hint = canChangeLockedDays ? "Satış aktarmak için önce günün kilidini açın." : CloudPermission.lockedDayPickAnotherNote
            alert = AppAlert(title: "Gün kapatılmış", message: "\(DateKey.short(date)) günü kilitli. \(hint)")
            return
        }
        let applied = mutateData("Satış Raporu Aktarımı") { d in
            var day = d.days[date] ?? DayRecord(date: date)
            day.sales = report.lines
            day.salesSource = report.sourceName
            day.salesPeriod = report.periodText
            day.salesImportedAt = Date()
            d.days[date] = day
        }
        guard applied else { return }
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
        return mutateData("Ürün Ekle") { $0.products.append(p) }
    }

    func deleteProduct(_ code: String) {
        guard mutateData("Ürün Sil", { $0.products.removeAll { $0.code == code } }) else { return }
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
        let applied = mutateData("Varsayılanları Geri Ekle") { d in
            let ids = Set(d.items.map { $0.id }), codes = Set(d.products.map { $0.code })
            for i in seed.items where !ids.contains(i.id) { d.items.append(i); addedItems += 1 }
            for p in seed.products where !codes.contains(p.code) { d.products.append(p); addedProducts += 1 }
        }
        return applied ? (addedItems, addedProducts) : (0, 0)
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

    // MARK: - Personel

    var employees: [Employee] { data.employees }

    func addEmployee(_ e: Employee) {
        mutateData("Personel Ekle") { $0.employees.append(e) }
    }

    func updateEmployee(_ id: String, actionName: String = "Personel Düzenleme", _ mutate: (inout Employee) -> Void) {
        mutateData(actionName) { d in
            guard let i = d.employees.firstIndex(where: { $0.id == id }) else { return }
            mutate(&d.employees[i])
        }
    }

    /// İşten ayrılış: geçmiş maliyetler korunur, seçili günden sonra maliyet yazılmaz
    func markEmployeeLeft(_ id: String, on date: String) {
        updateEmployee(id, actionName: "Personel Ayrıldı") { $0.endDate = date; $0.active = false }
    }

    /// Ücret değişikliği: `from` verilirse o günden itibaren (zam), nil ise tüm dönem için düzeltme
    func changePay(_ id: String, payType: PayType, rate: Double, costFactor: Double, from: String?) {
        updateEmployee(id, actionName: from == nil ? "Ücret Düzeltme" : "Ücret Değişikliği") {
            $0.setTerms(payType: payType, rate: rate, costFactor: costFactor, from: from)
        }
    }

    /// Giriş/ayrılış tarihlerini düzenler (ayrılış kaldırılırsa personel yeniden aktif olur)
    func setEmployeeDates(_ id: String, start: String?, end: String?) {
        updateEmployee(id, actionName: "Personel Tarihleri") {
            $0.startDate = start
            $0.endDate = end
            if end == nil { $0.active = true }
        }
    }

    /// Verilen tarihten itibaren kapatılmış gün sayısı (geriye dönük değişikliklerde uyarı için)
    func lockedDays(from date: String) -> Int {
        data.days.filter { $0.key >= date && $0.value.isLocked }.count
    }

    /// Personeli ve tüm vardiya kayıtlarını siler (yanlış girilen kayıt için)
    func deleteEmployee(_ id: String) {
        mutateData("Personel Sil") { d in
            d.employees.removeAll { $0.id == id }
            for (k, var day) in d.days where day.shifts?[id] != nil {
                day.shifts?[id] = nil
                if day.isEmpty { d.days[k] = nil } else { d.days[k] = day }
            }
        }
    }

    func updateShift(_ employeeID: String, date: String, _ mutate: (inout ShiftEntry) -> Void) {
        guard !isLocked(date) else { NSSound.beep(); return }
        updateDay(date, actionName: "Vardiya") { day in
            var shifts = day.shifts ?? [:]
            var e = shifts[employeeID] ?? ShiftEntry()
            mutate(&e)
            shifts[employeeID] = e.isEmpty ? nil : e
            day.shifts = shifts.isEmpty ? nil : shifts
        }
    }

    func shiftBinding(_ employeeID: String, date: String, _ kp: WritableKeyPath<ShiftEntry, Double?>) -> Binding<Double?> {
        Binding(get: { self.data.days[date]?.shifts?[employeeID]?[keyPath: kp] },
                set: { v in self.updateShift(employeeID, date: date) { $0[keyPath: kp] = v } })
    }

    /// Yevmiyeli için "çalıştı": saat girilmişse de çalışmış sayılır; işaret kaldırılınca saat de silinir
    /// (yoksa işaret kapalı görünürken yevmiye yazılmaya devam ederdi).
    func workedBinding(_ employeeID: String, date: String) -> Binding<Bool> {
        Binding(get: {
                    let s = self.data.days[date]?.shifts?[employeeID]
                    return s?.worked == true || (s?.hours ?? 0) > 0
                },
                set: { v in
                    self.updateShift(employeeID, date: date) {
                        if v { $0.worked = true } else { $0.worked = nil; $0.hours = nil }
                    }
                })
    }

    func otherLaborBinding(_ date: String) -> Binding<Double?> {
        Binding(get: { self.data.days[date]?.otherLabor },
                set: { v in
                    guard !self.isLocked(date) else { NSSound.beep(); return }
                    self.updateDay(date, actionName: "Diğer Personel Gideri") { $0.otherLabor = (v ?? 0) > 0 ? v : nil }
                })
    }

    /// Boş vardiyaları varsayılanla doldurur: saatlikler varsayılan saat, yevmiyeliler "çalıştı"
    func fillDefaultShifts(date: String) -> Int {
        guard !isLocked(date) else { return 0 }
        let existing = data.days[date]?.shifts ?? [:]
        var fills: [String: ShiftEntry] = [:]
        for e in data.employees where e.active && e.isEmployed(on: date) && (existing[e.id]?.isEmpty ?? true) {
            switch e.terms(on: date).payType {
            case .daily: fills[e.id] = ShiftEntry(worked: true)
            case .hourly, .monthly: if let h = e.defaultHours, h > 0 { fills[e.id] = ShiftEntry(hours: h) }
            }
        }
        // Doldurulacak bir şey yoksa geri alma geçmişine boş adım eklenmez
        guard !fills.isEmpty else { return 0 }
        let applied = updateDay(date, actionName: "Vardiyaları Doldur") { day in
            var shifts = day.shifts ?? [:]
            for (id, s) in fills { shifts[id] = s }
            day.shifts = shifts
        }
        return applied ? fills.count : 0
    }

    // MARK: - Fiyat geçmişi

    /// Birim maliyeti değiştirir ve değişikliği fiyat geçmişine yazar
    func setItemCost(_ id: String, _ cost: Double?) {
        let today = DateKey.today()
        updateItem(id, actionName: "Birim Maliyet") { $0.setCost(cost, on: today) }
    }

    // MARK: - Satın alma siparişleri

    var openOrders: [PurchaseOrder] { data.purchaseOrders.filter { $0.status == .open } }

    /// Önerilerden sipariş oluşturur
    @discardableResult
    func createOrder(date: String, supplier: String) -> Bool {
        guard let order = Purchasing.makeOrder(from: orderSuggestions(date: date), date: date, supplier: supplier) else {
            alert = AppAlert(title: "Sipariş oluşturulamadı", message: "Bu gün için önerilen sipariş yok.")
            return false
        }
        return mutateData("Sipariş Oluştur") { $0.purchaseOrders.append(order) }
    }

    func receiveOrder(_ id: String, on date: String, quantities: [String: Double], prices: [String: Double]) -> Bool {
        var copy = data
        do {
            let r = try Purchasing.receive(orderID: id, on: date, quantities: quantities, prices: prices, data: &copy)
            guard mutateData("Teslim Al", { $0 = copy }) else { return false }
            alert = AppAlert(title: "Teslim alındı",
                             message: "\(r.lines) kalem \(DateKey.short(date)) gününün Gelen sütununa işlendi" + (r.priceUpdates > 0 ? "; \(r.priceUpdates) kalemin birim maliyeti fatura fiyatıyla güncellendi." : "."))
            return true
        } catch {
            alert = AppAlert(title: "Teslim alınamadı", message: error.localizedDescription)
            return false
        }
    }

    func cancelOrder(_ id: String) {
        mutateData("Siparişi İptal Et") { Purchasing.cancel(orderID: id, data: &$0) }
    }

    func deleteOrder(_ id: String) {
        mutateData("Siparişi Sil") { $0.purchaseOrders.removeAll { $0.id == id } }
    }

    func copyOrder(_ id: String) {
        guard let o = data.purchaseOrders.first(where: { $0.id == id }) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Purchasing.text(o, items: engine.itemsByID, branch: settings.branchName), forType: .string)
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
            guard mutateData("Yedekten Geri Yükleme", { $0 = restored }) else { return }
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
