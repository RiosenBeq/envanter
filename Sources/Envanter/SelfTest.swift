import SwiftUI
import AppKit
import EnvanterCore

/// Kayıt noktası denetimi: durum yazılırken diskteki veri dosyasının durumu (arka plan kuyruğunda yazılır)
private final class CheckpointProbe: @unchecked Sendable {
    var dataWasCurrent = false
    var stateWritten = false
}

/// Yakalanmamış Objective-C istisnasının nedenini ve yığınını yazar (C işlev göstericisi olarak verilir)
private func selfTestExceptionHandler(_ e: NSException) {
    print("SELFTEST İSTİSNA: \(e.name.rawValue): \(e.reason ?? "")")
    print(e.callStackSymbols.prefix(30).joined(separator: "\n"))
}

/// Uçtan uca sistem testi: ENVANTER_SELFTEST=1 ile açılınca uygulamanın gerçek AppStore'u üzerinden
/// tipik bir iş gününü baştan sona oynatır, her adımı doğrular ve sonucu çıkış koduyla bildirir (0 = başarılı).
/// Geçici bir veri klasörü kullanır; gerçek veriye dokunmaz. Ağ kullanmaz (web eşitlemesi bu modda kapalıdır).
/// CI'da macOS üzerinde çalıştırılır.
@MainActor
enum SelfTest {
    private static var failures: [String] = []
    private static var passed = 0
    private static var started = false

    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["ENVANTER_SELFTEST"] == "1", !started else { return }
        started = true
        // Çıktı boruya yönlendirildiğinde de satır satır görünsün (takılırsa nerede kaldığı anlaşılsın)
        setvbuf(stdout, nil, _IONBF, 0)
        print("SELFTEST başlıyor")
        // AppKit yakalanmamış Objective-C istisnalarını sessizce yutar; testte nedenini görüp hemen düşelim
        NSSetUncaughtExceptionHandler(selfTestExceptionHandler)
        Task { @MainActor in
            await run()
            print("SELFTEST: \(passed) kontrol geçti, \(failures.count) başarısız")
            for f in failures { print("SELFTEST BAŞARISIZ: \(f)") }
            fflush(stdout)
            exit(failures.isEmpty ? 0 : 1)
        }
    }

    private static func check(_ ok: Bool, _ what: String, line: UInt = #line) {
        if ok { passed += 1; print("  ✓ \(what)") } else { failures.append("\(what) (satır \(line))"); print("  ✗ \(what)") }
    }

    private static func near(_ a: Double?, _ b: Double, _ eps: Double = 1e-6) -> Bool {
        guard let a else { return false }
        return abs(a - b) < eps
    }

    /// Olay döngüsünün bir tur dönmesini bekler (geri alma grupları gerçek kullanımdaki gibi tur sonunda kapanır)
    private static func settle() async {
        try? await Task.sleep(nanoseconds: 80_000_000)
    }

    static func run() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("envanter-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let persistence = Persistence(directory: dir)
        let store = AppStore(persistence: persistence)
        /// Adımın adı yalnızca okunabilirlik için
        func step(_ name: String, _ f: () -> Void) { f() }
        /// Bir günün kapanışlarını tek işlemde yazar (takip şeridi denemesi)
        func setClosings(_ date: String, _ values: [String: Double]) {
            store.mutateData("Sayım Girişi") { d in
                var day = d.days[date] ?? DayRecord(date: date)
                for (id, v) in values { day.entries[id, default: DayEntry()].closing = v }
                d.days[date] = day
            }
        }

        print("1) Açılış, varsayılanlar ve ekranlar")
        check(store.data.items.count >= 20, "varsayılan stok kalemleri yüklendi")
        check(store.data.products.count >= 300, "varsayılan reçeteler yüklendi")
        check(store.section == .overview, "uygulama Genel Bakış ile açılıyor")
        check(store.isFirstRun, "ilk açılışta Genel Bakış başlangıç seçeneklerini gösteriyor (henüz günlük kayıt yok)")
        check(AppSection.daily.title == "Günlük Sayım", "günlük ekranın adı web paneliyle aynı (Günlük Sayım)")
        check(AppSection.team.title == "Ekip" && AppSection.reports.title == "Raporlar" && AppSection.orders.title == "Sipariş",
              "Ekip, Raporlar ve Sipariş ekranları")
        check(AppSection.allCases.compactMap { $0.shortcut.map { String($0.character) } } == ["1", "2", "3", "4", "5", "6", "7", "8", ","],
              "⌘1…⌘8 kısayolları yan menü sırasıyla, Ayarlar ⌘,")
        check(AppSection.mainSections + AppSection.definitionSections == AppSection.allCases.filter { $0.shortcut?.character.isNumber == true },
              "yan menü: günlük işler, sonra Tanımlar (⌘1…⌘8 sırasıyla)")
        check(AppSection.definitionSections == [.items, .recipes, .team] && AppSection.bottomSections == [.backup, .help],
              "Tanımlar: Stok Kalemleri, Reçeteler, Ekip; altta Ayarlar ve Yardım")
        check(AppSection.backup.title == "Ayarlar" && AppSection.help.title == "Yardım", "ekran adları: Ayarlar, Yardım")
        check(Set(AppSection.mainSections + AppSection.definitionSections + AppSection.bottomSections) == Set(AppSection.allCases),
              "her ekran yan menüde")
        check(ReportsTab.named("summary") == .summary && ReportsTab.named("item") == .item, "Raporlar sekmelerinin kısa adları")
        store.openItemAnalysis(itemID: "patates")
        check(store.section == .reports && store.reportsTab == .item && store.reportItem == "patates",
              "\"Ayrıntılı analiz\" Raporlar > Kalem Analizi'ni seçili kalemle açıyor")
        store.section = .overview
        store.reportsTab = .summary
        store.reportItem = nil

        let d1 = "2026-08-01", d2 = "2026-08-02"
        store.selectedDate = d1

        print("2) Sayım girişi ve fark hesabı")
        step("sayım") {
            store.entryBinding(item: "g90", date: d1, \.opening).wrappedValue = 100
            store.entryBinding(item: "g90", date: d1, \.incoming).wrappedValue = 50
            store.entryBinding(item: "g90", date: d1, \.closing).wrappedValue = 120
        }
        var calc = store.engine.calc(date: d1).rows.first { $0.itemID == "g90" }
        check(near(calc?.actual, 30), "fiili tüketim = 100 + 50 − 120 = 30")
        check(!store.isFirstRun, "ilk sayım girilince başlangıç kartı kayboluyor")
        check(near(calc?.diff, -30), "satış yokken fark −30")

        print("3) Satış raporu aktarımı (Tutar sütunu yok sayılır)")
        let report = SalesParser.parse(text: "Kodu\tÜrün Tipi\tAdedi\tTutar\n11101\tDUBLEX BURGER\t14\t5460\n17001\tZAYİ 100 GR KÖFTE\t1\n13001\tKOLA\t10\t500\n99999\tYENİ ÜRÜN\t3\t900\n",
                                       sourceName: "selftest")
        check(report.lines.count == 4, "4 satış satırı okundu")
        check(report.lines.first { $0.code == "11101" }?.qty == 14, "Tutar sütunu ad ya da adet sanılmadı (Dublex 14 adet)")
        store.confirmImport(report: report, date: d1)
        calc = store.engine.calc(date: d1).rows.first { $0.itemID == "g90" }
        check(near(calc?.sold, 28), "Dublex 14 adet → 90 gr satılan 28")
        check(near(calc?.waste, 1), "ZAYİ köfte → zayi 1")
        check(near(calc?.diff, -1), "fark = 28 + 1 − 30 = −1")
        check(store.engine.overview(date: d1).unknownLines == 1, "reçetesi tanımsız 1 ürün işaretlendi")
        let again = SalesImportCheck.warnings(report: report, targetDate: DateKey.addDays(1, to: d1), data: store.data)
        check(again.first?.kind == .duplicate && SalesImportCheck.needsConfirmation(again),
              "aynı rapor ertesi güne aktarılırken uyarı ve \"Yine de bu güne aktar\" onayı")
        let priced = SalesParser.parse(text: "Kodu;Ürün Tipi;Birim Fiyat;Adedi\n11101;DUBLEX;185;12 adet\n11103;CHEESE;210;?\n",
                                       sourceName: "selftest")
        check(priced.lines.first?.qty == 12 && priced.skipped.map { $0.row } == [3],
              "başlıklı rapor: birim fiyat adet sanılmadı, okunamayan satır bildirildi")
        let json = (try? persistence.encode(store.data)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        check(!json.isEmpty && !json.contains("\"amount\"") && !json.contains("\"salesRevenue\""), "satış tutarı saklanmıyor (yalnızca adet)")

        print("4) Geri al / yinele")
        // Pencerenin geri alma yöneticisi gibi: gruplar olay döngüsü turunun sonunda kendiliğinden kapanır
        let undo = UndoManager()
        store.undoManager = undo
        await settle()
        store.entryBinding(item: "g90", date: d1, \.closing).wrappedValue = 110
        await settle()
        check(store.data.days[d1]?.entries["g90"]?.closing == 110, "kapanış 110 yapıldı")
        check(undo.canUndo && undo.undoActionName == "Sayım Girişi", "Düzen menüsünde \"Sayım Girişi Geri Al\"")
        undo.undo()
        await settle()
        check(store.data.days[d1]?.entries["g90"]?.closing == 120, "geri al: kapanış 120'ye döndü")
        check(undo.canRedo, "yinele kullanılabilir")
        undo.redo()
        await settle()
        check(store.data.days[d1]?.entries["g90"]?.closing == 110, "yinele: kapanış yeniden 110")
        undo.undo()
        await settle()
        check(store.data.days[d1]?.entries["g90"]?.closing == 120, "tekrar geri al: 120")
        store.undoManager = nil

        print("5) Tolerans")
        step("tolerans") { store.updateItem("g90") { $0.tolerance = 2 } }
        check(store.engine.calc(date: d1).rows.first { $0.itemID == "g90" }?.severity == .withinTolerance, "−1 fark tolerans (±2) içinde")
        check(store.engine.overview(date: d1).problemItems == store.engine.calc(date: d1).rows.filter { $0.severity?.isProblem == true }.count,
              "sorunlu kalem sayısı tolerans dışı farklardan")

        print("6) Açılış devri ve hareketsiz kalemler")
        let d2row = store.engine.calc(date: d2).rows.first { $0.itemID == "g90" }
        check(d2row?.opening == 120 && d2row?.openingIsAuto == true && d2row?.openingSource == .closing,
              "ertesi günün açılışı önceki sayımdan (120)")
        step("peynir") { store.entryBinding(item: "peynir", date: d1, \.closing).wrappedValue = 5 }
        let peynirFirst = store.engine.calc(date: d1).rows.first { $0.itemID == "peynir" }
        check(peynirFirst?.isBaseline == true && peynirFirst?.diff == nil, "ilk sayım başlangıç kabul edilir (fark hesaplanmaz)")
        let refused = store.fillUncountedWithOpening(date: d2)
        check(refused.count == 0 && refused.refusal == .noSales && store.data.days[d2]?.entries["peynir"] == nil,
              "satış raporu olmadan Hareketsizleri Doldur çalışmıyor")
        // Stok etkisi olmayan satış (içecek): günün satış verisi var, hiçbir kalem hareket etmez
        store.confirmImport(report: SalesParser.parse(text: "Kodu\tÜrün Tipi\tAdedi\n13001\tKOLA\t5\n", sourceName: "selftest-içecek"), date: d2)
        let filled = store.fillUncountedWithOpening(date: d2)
        check(filled.count >= 2 && filled.refusal == nil, "hareketsiz kalemler dolduruldu (\(filled.count))")
        check(store.data.days[d2]?.entries["peynir"]?.closing == 5, "peynir kapanışı = açılış (5)")

        print("6b) Sayılmayan gün devri ve tahmini stok")
        let d3 = "2026-08-03", d4 = "2026-08-04"
        store.entryBinding(item: "g90", date: d3, \.incoming).wrappedValue = 30
        let d4row = store.engine.calc(date: d4).rows.first { $0.itemID == "g90" }
        check(near(d4row?.opening, 150) && d4row?.openingSource == .carried && d4row?.carriedDays == 1 && d4row?.openingBaseDate == d2,
              "sayılmayan günün Gelen'i sonraki açılışa devreder (120 + 30 ≈ 150)")
        if let d4row, let g90 = store.engine.itemsByID["g90"] {
            check(OpeningText.placeholder(d4row, item: g90) == "≈ 150", "tahmini açılış \"≈ 150\" yazılır")
            check(OpeningText.help(d4row, item: g90, date: d4, breakdown: store.engine.carryBreakdown(itemID: "g90", date: d4))
                    == "Son sayım 02.08.2026: 120 + sayılmayan 1 günün hareketleri (Gelen +30) ≈ 150",
                  "açılış ipucu dayanağı ve devreden hareketi gösteriyor")
            // Sipariş'teki mevcut stok aynı tahmin ve aynı dayanak (Stok Kalemleri ile ortak metin)
            let o3 = store.orderSuggestions(date: d3).first { $0.item.id == "g90" }
            check(o3.map { OrderStockText.value($0) } == "≈ 150" && o3.flatMap { OrderStockText.note($0, date: d3) } == "sayım 02.08 + hareket",
                  "Sipariş: mevcut stok tahmini (≈ 150 · sayım 02.08 + hareket)")
        } else { check(false, "04.08 satırı hesaplandı") }
        // Sayım girilmemiş gün: Genel Bakış'taki "Kritik seviye altı" kartı tahmini stoğa göre
        store.updateItem("g90", actionName: "Kritik Seviye") { $0.minStock = 200 }
        let card = BelowMinimumCard.make(store.engine.overview(date: d3), estimates: store.engine.stockEstimates(date: d3))
        check(card.detail == "tahmini · sayım girilmedi" && (Int(card.value) ?? 0) >= 1 && card.warn,
              "Genel Bakış: sayım yokken kritik seviye kartı tahmini stoğu gösteriyor (\(card.value))")
        store.updateItem("g90", actionName: "Kritik Seviye") { $0.minStock = nil }

        print("6c) Elle zayi (Zayi Ekle)")
        let wasteBefore = store.engine.calc(date: d1).rows.first { $0.itemID == "g90" }
        let wasteUndo = UndoManager()
        store.undoManager = wasteUndo
        await settle()
        if let entry = WasteLog.make(id: "selftest-zayi", itemID: "g90", qty: 2, reason: .burnt, note: "Yanan köfte", by: "Ayşe") {
            check(store.addWaste(date: d1, entry: entry), "zayi kaydı eklendi")
        } else { check(false, "zayi kaydı oluşturuldu") }
        await settle()
        let wasteRow = store.engine.calc(date: d1).rows.first { $0.itemID == "g90" }
        check(near(wasteRow?.manualWaste, 2) && near(wasteRow?.waste, (wasteBefore?.waste ?? 0) + 2),
              "elle zayi Zayi sütununa eklendi (ModPos + elle)")
        check(near(wasteRow?.diff, (wasteBefore?.diff ?? 0) + 2), "fark elle zayi kadar değişti")
        check(wasteUndo.undoActionName == "Zayi Ekle", "Düzen menüsünde \"Zayi Ekle Geri Al\"")
        check(store.removeWaste(date: d1, id: "selftest-zayi") && store.data.days[d1]?.wasteLog == [],
              "son kayıt silinince liste boş kalır ([]; anahtar silinmez)")
        await settle()
        wasteUndo.undo()
        await settle()
        check(store.data.days[d1]?.wasteLog?.map { $0.id } == ["selftest-zayi"], "geri al: silinen zayi kaydı geri geldi")
        if let row = store.engine.calc(date: d1).rows.first(where: { $0.itemID == "g90" }), let g90 = store.engine.itemsByID["g90"] {
            check(WasteText.duplicateHint(row, day: store.data.days[d1], item: g90)?.contains("elle 2 adet zayi girildi") == true,
                  "Zayi Ekle aynı zayinin iki kez girilmesine karşı uyarıyor")
            let help = WasteText.cellHelp(row, legacy: store.data.days[d1]?.usesLegacySales ?? false, item: g90)
            check(help.contains("elle 2") || help.contains("elle girildi"), "Zayi hücresi ipucu elle girilen zayiyi gösteriyor: \(help)")
        }
        if let withWaste = store.data.days[d1] {
            var plain = withWaste
            plain.wasteLog = nil
            let summary = ChangeSummary.summarize(key: DocKey.day(d1), before: try? JSONCoding.value(plain),
                                                  after: try? JSONCoding.value(withWaste), data: store.data)
            check(summary == "01.08.2026 zayi eklendi: 90 Gr 2 adet (Yandı / hatalı üretim)", "değişiklik geçmişi: \(summary)")
        }
        // Satışı olan gün: yalnızca elle zayisi olan kalem hareketsiz sayılmaz (Hareketsizleri Doldur)
        let d5 = "2026-08-05"
        store.confirmImport(report: SalesParser.parse(text: "Kodu\tÜrün Tipi\tAdedi\n13001\tKOLA\t2\n", sourceName: "selftest-zayi"), date: d5)
        let peynirIdle = { store.engine.calc(date: d5).rows.first { $0.itemID == "peynir" }.map(DayOps.isIdle) ?? false }
        check(peynirIdle(), "satışı olan günde hareketsiz peynir doldurulabilir")
        if let peynirZayi = WasteLog.make(itemID: "peynir", qty: 0.5, reason: .spoiled) { store.addWaste(date: d5, entry: peynirZayi) }
        check(!peynirIdle(), "elle zayi hareket sayılır")
        _ = store.fillUncountedWithOpening(date: d5)
        check(store.data.days[d5]?.entries["peynir"]?.closing == nil, "elle zayisi olan kaleme kapanış = açılış yazılmadı")
        store.undoManager = nil
        wasteUndo.removeAllActions()
        store.removeWaste(date: d1, id: "selftest-zayi")
        store.selectedDate = d1

        print("7) Gün kilidi")
        step("kilit") { store.setLocked(d1, true) }
        store.entryBinding(item: "g90", date: d1, \.closing).wrappedValue = 1
        check(store.data.days[d1]?.entries["g90"]?.closing == 120, "kilitli günde sayım değişmiyor")
        store.clearSales(date: d1)
        check(store.data.days[d1]?.sales.count == 4, "kilitli günde satışlar silinemiyor")
        step("kilit aç") { store.setLocked(d1, false) }
        check(!store.isLocked(d1), "kilit açıldı")

        print("8) Ekip: ekleme, düzenleme, pasif yapma, silme (geri alınabilir)")
        let teamUndo = UndoManager()
        // Her işlem kendi geri alma adımında (pencerede her tıklama ayrı olay turudur). Olay turuna bağlı gruplama
        // burada art arda iki işlemi tek adımda birleştirirdi; gruplar elle açılıp kapanır.
        teamUndo.groupsByEvent = false
        @discardableResult func act<T>(_ f: () -> T) -> T {
            teamUndo.beginUndoGrouping()
            defer { teamUndo.endUndoGrouping() }
            return f()
        }
        store.undoManager = teamUndo
        await settle()
        let added = act { store.addEmployee(Employee(id: "m", name: "Ayşe Yılmaz", role: "Müdür", phone: "0555 000 00 00")) }
        await settle()
        check(added && store.employees.map { $0.id } == ["m"], "ekip üyesi eklendi")
        check(teamUndo.undoActionName == "Eleman Ekle", "Düzen menüsünde \"Eleman Ekle Geri Al\"")
        teamUndo.undo()
        await settle()
        check(store.employees.isEmpty, "geri al: eklenen üye kaldırıldı")
        teamUndo.redo()
        await settle()
        check(store.employees.first?.phone == "0555 000 00 00" && store.employees.first?.role == "Müdür", "yinele: üye görevi ve telefonuyla geri geldi")
        act { store.addEmployee(Employee(id: "u", name: "Mehmet", role: "Usta")) }
        await settle()
        act { store.updateEmployee("u") { $0.role = "Kasiyer" } }
        await settle()
        check(store.employees.first { $0.id == "u" }?.role == "Kasiyer" && teamUndo.undoActionName == "Eleman Düzenleme",
              "görev değiştirildi (Eleman Düzenleme)")
        teamUndo.undo()
        await settle()
        check(store.employees.first { $0.id == "u" }?.role == "Usta", "geri al: görev yeniden Usta")
        let lastAction = teamUndo.undoActionName
        let unchanged = store.updateEmployee("u") { $0.role = "Usta" }
        await settle()
        check(unchanged && teamUndo.undoActionName == lastAction, "değişiklik yoksa geri alma geçmişine boş adım eklenmiyor")
        check(store.counterNames == ["Ayşe Yılmaz", "Mehmet"], "Sayan listesi aktif üyelerden (liste sırasıyla)")
        act { store.setEmployeeActive("u", false) }
        await settle()
        check(store.employees.first { $0.id == "u" }?.active == false && teamUndo.undoActionName == "Eleman Pasif", "üye pasif yapıldı (Eleman Pasif)")
        check(store.counterNames == ["Ayşe Yılmaz"], "pasif üye Sayan listesinde görünmüyor")
        teamUndo.undo()
        await settle()
        check(store.employees.first { $0.id == "u" }?.active == true && store.counterNames.contains("Mehmet"), "geri al: üye yeniden aktif")
        act { store.deleteEmployee("u") }
        await settle()
        check(!store.employees.contains { $0.id == "u" } && teamUndo.undoActionName == "Eleman Sil", "üye silindi (Eleman Sil)")
        teamUndo.undo()
        await settle()
        check(store.employees.map { $0.id } == ["m", "u"], "geri al: silinen üye yerine geri geldi")

        print("9) Sayan alanı ve eski sayım yapanlar listesi (yalnızca bu Mac'te taşınır)")
        // Eski sürümden kalan hızlı seçim listesi (web eşitlemesi kapalı, şubeyle eşleşmemiş Mac)
        act { store.updateSettings { $0.staff = ["Ahmet", "ayşe yılmaz", "  İSMAİL  "] } }
        await settle()
        check(store.counterNames == ["Ayşe Yılmaz", "Mehmet", "Ahmet", "İSMAİL"],
              "Sayan: önce aktif üyeler, sonra ekipte olmayan eski adlar (aynı ad bir kez)")
        let staffBefore = store.settings.staff
        act { store.setCountedBy(d1, "Zeynep Kaya") }
        await settle()
        check(store.data.days[d1]?.countedBy == "Zeynep Kaya", "sayımı yapan güne yazıldı")
        check(store.employees.contains { $0.id == "staff-zeynep-kaya" && $0.name == "Zeynep Kaya" && $0.active },
              "ekipte olmayan yeni ad ekibe eklendi (staff-zeynep-kaya)")
        check(store.settings.staff == staffBefore, "yazılan ad eski hızlı seçim listesine yazılmadı")
        check(teamUndo.undoActionName == "Sayımı Yapan", "ad ve yeni üye tek adımda geri alınır (Sayımı Yapan)")
        teamUndo.undo()
        await settle()
        check(store.data.days[d1]?.countedBy == nil && !store.employees.contains { $0.id == "staff-zeynep-kaya" },
              "geri al: ad günden ve ekipten kalktı")
        let teamBefore = store.employees.count
        act { store.setCountedBy(d1, "  mehmet ") }
        await settle()
        check(store.data.days[d1]?.countedBy == "mehmet" && store.employees.count == teamBefore,
              "ekipteki ad (büyük/küçük harf farkıyla) yeniden eklenmedi")
        let actionBefore = teamUndo.undoActionName
        let migrated = store.applyLegacyStaffMigration()
        let ids = store.employees.map { $0.id }
        check(migrated && store.settings.staff.isEmpty, "eski liste ekibe taşındı ve boşaltıldı")
        check(ids.contains("staff-ahmet") && ids.contains("staff-ismail"), "belirlenimci kimlikler: staff-ahmet, staff-ismail")
        check(!ids.contains("staff-ayse-yilmaz") && store.employees.filter { TeamID.slug($0.name) == "ayse-yilmaz" }.count == 1,
              "ekipte aynı adlı üye varken yeniden eklenmedi")
        check(store.employees.first { $0.id == "staff-ismail" }?.name == "İSMAİL", "taşınan ad kırpıldı")
        check(store.counterNames == ["Ayşe Yılmaz", "Mehmet", "Ahmet", "İSMAİL"], "Sayan listesi taşımadan sonra da aynı")
        check(teamUndo.undoActionName == actionBefore, "taşıma geri alma geçmişine eklenmedi (⌘Z eski listeyi geri getirmez)")
        check(!store.applyLegacyStaffMigration(), "ikinci taşımada değişiklik yok")
        act { store.linkAccount(employeeID: "m", email: "Ayşe.Yilmaz") }
        check(store.employees.first { $0.id == "m" }?.account == "ayse.yilmaz@envanter.local", "giriş hesabı kullanıcı adıyla bağlandı (ayse.yilmaz)")
        check(store.employee(linkedTo: "AYSE.YILMAZ@envanter.local")?.id == "m", "hesaba bağlı üye bulunuyor (Kullanıcılar listesindeki ad)")
        act { store.linkAccount(employeeID: "staff-ahmet", email: "ayse.yilmaz@envanter.local") }
        check(store.employees.first { $0.id == "m" }?.account == nil && store.employees.first { $0.id == "staff-ahmet" }?.account == "ayse.yilmaz@envanter.local",
              "bir hesap tek üyeye bağlanır")
        act { store.linkAccount(employeeID: "staff-ahmet", email: nil) }
        act { store.linkAccount(employeeID: "m", email: "ayse.yilmaz") }
        check(store.employees.first { $0.id == "staff-ahmet" }?.account == nil && store.employees.first { $0.id == "m" }?.account == "ayse.yilmaz@envanter.local",
              "bağlantı kaldırıldı ve yeniden bağlandı")
        store.undoManager = nil

        print("10) Sipariş oluşturma ve teslim alma (yalnızca miktar)")
        store.selectedDate = d2
        step("sayım d2") { store.entryBinding(item: "g90", date: d2, \.closing).wrappedValue = 20 }
        let created = store.createOrder(date: d2, supplier: "Et Tedarikçisi")
        check(created && store.openOrders.count == 1, "önerilerden açık sipariş oluşturuldu")
        if let order = store.openOrders.first {
            let line = order.lines.first { $0.itemID == "g90" }
            check(line != nil, "siparişte 90 gr var")
            let after = store.orderSuggestions(date: d2).first { $0.item.id == "g90" }
            check(near(after?.onOrder, line?.qty ?? -1) && after?.suggested == 0, "açık siparişteki miktar öneriden düşüldü (çift sipariş yok)")
            let before = store.data.days[d2]?.entries["g90"]?.incoming ?? 0
            let expectedLines = order.lines.filter { ($0.itemID == "g90" ? 100 : $0.qty) > 0 }.count
            store.alert = nil
            let ok = store.receiveOrder(order.id, on: d2, quantities: ["g90": 100])
            check(ok, "sipariş teslim alındı")
            check(store.alert?.message.hasPrefix("\(expectedLines) kalem") == true, "bildirim işlenen kalem sayısını gösteriyor (\(expectedLines) kalem)")
            store.alert = nil
            check(near(store.data.days[d2]?.entries["g90"]?.incoming, before + 100), "teslimat Gelen'e işlendi (+100)")
            check(store.data.purchaseOrders.first { $0.id == order.id }?.lines.first { $0.itemID == "g90" }?.received == 100,
                  "teslim alınan miktar siparişe yazıldı")
            check(store.openOrders.isEmpty, "sipariş kapandı")
        }

        print("10b) Sipariş formu, düzenleme ve \"Teslim alındı say\"")
        let manual = store.createOrder(date: d2, supplier: "Sebzeci", note: "Sabah getirin",
                                       lines: [OrderLine(itemID: "patates", qty: 5), OrderLine(itemID: "g90", qty: 0)])
        check(manual && store.openOrders.first?.lines == [OrderLine(itemID: "patates", qty: 5)] && store.openOrders.first?.note == "Sabah getirin",
              "formdan sipariş: miktarı 0 olan kalem atıldı, not yazıldı")
        if let o = store.openOrders.first {
            check(store.updateOrder(o.id, supplier: "Sebzeci", note: "", lines: [OrderLine(itemID: "patates", qty: 8)]), "açık sipariş düzenlendi")
            check(store.openOrders.first?.lines.first?.qty == 8 && store.openOrders.first?.note == nil, "miktar 8 oldu, not silindi")
            let before = store.data.days[d2]?.entries["patates"]?.incoming
            store.alert = nil
            check(store.receiveOrder(o.id, on: d2, quantities: ["patates": 8], addToIncoming: false), "\"Teslim alındı say\" uygulandı")
            store.alert = nil
            check(store.data.days[d2]?.entries["patates"]?.incoming == before, "Gelen'e eklenmedi (elle girilmişti)")
            check(store.data.purchaseOrders.first { $0.id == o.id }?.receivedWithoutIncoming == true && store.openOrders.isEmpty,
                  "sipariş kapandı ve \"Gelen'e eklenmeden\" olarak işaretlendi")
        }

        print("11) Ayarlar")
        step("şube adı") { store.updateSettings { $0.branchName = "Test Şube" } }
        check(store.settings.branchName == "Test Şube", "şube adı kaydedildi")

        print("12) Excel dışa aktarımı (yalnızca miktarlar)")
        if let x = try? XlsxReader.read(data: Exporter.history(engine: store.engine, from: d1, to: d2)) {
            let names = x.map { $0.name }
            check(names.first == "Alımlar" && names.contains("Özet") && names.contains("Günlük Durum") && names.contains("Ekip"),
                  "geçmiş Excel'i: Alımlar, Özet, Günlük Durum, Ekip (\(names.joined(separator: ", ")))")
            check(!names.contains("Günlük Maliyet") && !names.contains("Personel"), "geçmiş Excel'inde maliyet / personel maliyeti sayfası yok")
            let cells = x.flatMap { $0.rows.values.flatMap { $0.values } }
            check(!cells.contains { $0.contains("₺") || $0.contains("Maliyet") }, "geçmiş Excel'inde tutar ya da maliyet yok")
        } else { check(false, "geçmiş Excel'i okunabilir") }
        check((try? XlsxReader.read(data: Exporter.countSheet(engine: store.engine, date: d2)))?.first?.name == "Sayım Formu", "sayım formu")
        check((try? XlsxReader.read(data: Exporter.day(engine: store.engine, date: d1)))?.count == 2, "gün Excel'i 2 sayfa")
        // Web paneliyle aynı dosya adı kuralı (Fixtures/export-vectors.json)
        check(Exporter.fileName(branch: " A/B:C ", base: "Sayım Formu 01.08.2026") == "NextGen Envanter – A-B-C – Sayım Formu 01.08.2026.xlsx",
              "dışa aktarım dosya adı (web ile aynı)")
        if let o = try? XlsxReader.read(data: Exporter.orders(store.orderSuggestions(date: d2), date: d2)) {
            let cells = o.flatMap { $0.rows.values.flatMap { $0.values } }
            check(o.first?.name == "Sipariş" && !cells.contains { $0.contains("₺") || $0.contains("Tutar") }, "sipariş Excel'inde tutar sütunu yok")
        } else { check(false, "sipariş Excel'i okunabilir") }

        print("13) Diske kayıt ve yeniden yükleme")
        store.flush()
        switch Persistence(directory: dir).load() {
        case .loaded(let back):
            check(back.days[d1]?.entries["g90"]?.closing == 120, "sayım diske yazıldı")
            check(back.employees.count == 4 && back.employees.first { $0.id == "m" }?.phone == "0555 000 00 00"
                  && back.employees.first { $0.id == "m" }?.account == "ayse.yilmaz@envanter.local", "ekip (telefon, giriş hesabı) diske yazıldı")
            check(back.settings.staff.isEmpty && back.employees.contains { $0.id == "staff-ismail" }, "taşınan eski liste diskte boş, üyeler ekipte")
            check(back.purchaseOrders.first?.status == .received, "sipariş durumu diske yazıldı")
            check(back.settings.branchName == "Test Şube", "ayarlar diske yazıldı")
        default:
            check(false, "veri dosyası yeniden yüklenebilir")
        }
        let raw = (try? Data(contentsOf: persistence.dataFile)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        check(!raw.isEmpty && ["unitCost", "costHistory", "unitPrice", "payType", "salesRevenue", "shifts", "targetFoodCostPct"].allSatisfy { !raw.contains("\"\($0)\"") },
              "veri dosyasında maliyet, fiyat ya da ücret alanı yok")
        check(!persistence.backups().isEmpty, "günlük yedek alındı")

        print("14) Varsayılanları geri ekleme ve silme")
        step("ürün sil") { store.deleteProduct("11101") }
        check(store.product("11101") == nil, "ürün silindi")
        let restored = store.restoreMissingDefaults()
        check(restored.products == 1 && store.product("11101") != nil, "silinen varsayılan ürün geri eklendi")

        print("14b) Stok kalemi: aynı ad, silme, silinen kimlik, birim (CatalogOps; web ile aynı)")
        store.alert = nil
        check(!store.addItem(name: " 90 GR ", unit: "Adet") && store.alert?.title == CatalogOps.duplicateTitle, "aynı adlı kalem eklenmedi (uyarı)")
        store.alert = nil
        check(store.addItem(name: "Turşu", unit: "Adet") && store.data.items.last?.id == "turşu", "yeni kalem eklendi (turşu)")
        check(!store.renameItem("turşu", to: "peynir") && store.alert?.title == CatalogOps.duplicateTitle
              && store.data.items.last?.name == "Turşu", "başka kalemin adı verilemiyor")
        store.alert = nil
        let lockedDay = "2026-07-10", openDay = "2026-07-11"
        setClosings(lockedDay, ["turşu": 4])
        setClosings(openDay, ["turşu": 3])
        store.setLocked(lockedDay, true)
        let lockedBefore = store.data.days[lockedDay]
        check(CatalogOps.history("turşu", in: store.data).suggestsDeactivate, "sayım geçmişi olan kalemde silmek yerine \"Pasif Yap\" öneriliyor")
        let removed = store.deleteItem("turşu")
        check(removed?.days == 1 && removed?.keptLockedDays == 1 && store.data.days[openDay] == nil && store.data.days[lockedDay] == lockedBefore,
              "silme: açık gündeki kayıt silindi, kapatılmış gün olduğu gibi kaldı")
        check(store.addItem(name: "Turşu", unit: "Kg") && store.data.items.last?.id == "turşu2",
              "yeniden eklenen kalem silinenin kimliğini almadı (turşu2: kapatılmış gündeki kayıtları devralmaz)")
        setClosings(openDay, ["turşu2": 2])
        check(CatalogOps.unitChangeNeedsConfirmation(CatalogOps.history("turşu2", in: store.data)), "sayım geçmişi olan kalemde birim değişikliği onay istiyor")
        check(store.splitItemForUnit("turşu2", unit: "Adet") && store.data.items.first { $0.id == "turşu2" }?.active == false
              && store.data.items.first { $0.id == "turşu2" }?.name == "Turşu (kg)"
              && store.data.items.contains { $0.name == "Turşu" && $0.unit == "Adet" && $0.active },
              "Yeni Kalem Olarak Aç: eski kalem \"Turşu (kg)\" adıyla pasif, yeni birimli kalem açık")
        store.alert = nil
        check(store.deactivateItem("turşu2") == false, "pasif kalem yeniden pasif yapılmıyor")
        // Eksik varsayılanları geri ekleme aynı adlı kalemi ikinci kez eklemez (silinip "Peynir" adıyla yeniden eklenmiş)
        var reAdded = CatalogOps.deleteItem("peynir", in: store.data).data
        reAdded.items.append(CatalogOps.newItem(name: "Peynir", unit: "Kg", data: reAdded))
        let seed = AppData.seeded()
        let merged = CatalogOps.mergeDefinitions(items: seed.items, products: seed.products, into: reAdded).data
        check(merged.items.filter { CatalogOps.hasItemNamed("Peynir", in: [$0]) }.count == 1,
              "Eksik varsayılanları geri ekle: silinip yeniden eklenen \"Peynir\" ikinci kez gelmedi")
        store.setLocked(lockedDay, false)

        print("15) Takip şeridi renkleri (sayılanların kaçında fark var; web paneliyle aynı kural)")
        check(TrackerState.legendOrder.prefix(3).map { $0.label }
              == ["Sayım tam, fark az", "Eksik sayım ya da sayılanların %10'unda fark", "Sayılanların %20'sinde fark"],
              "renk açıklaması web paneliyle aynı")
        let tA = "2026-08-20", tB = "2026-08-21", tC = "2026-08-22", tD = "2026-08-25"
        setClosings(tA, ["g90": 2])
        store.entryBinding(item: "g90", date: tA, \.opening).wrappedValue = 10
        var oA = store.engine.overview(date: tA)
        check(oA.countedItems == 1 && oA.problemItems == 1 && oA.shortageItems == 1 && oA.hasSignificantProblems && oA.trackerState == .bad,
              "tek sayılan kalemde fazla çıkış → kırmızı")
        setClosings(tA, ["g90": 9])
        oA = store.engine.overview(date: tA)
        check(oA.problemItems == 0 && !oA.hasNotableProblems && !oA.isFullyCounted && oA.trackerState == .warn, "fark tolerans içinde ama eksik sayım → turuncu")
        store.confirmImport(report: report, date: tB)
        check(store.engine.overview(date: tB).trackerState == .salesOnly, "yalnızca satış raporu olan gün gri")
        check(store.engine.overview(date: tC).trackerState == .empty, "verisi olmayan gün boş")
        // Önceki gün tüm kalemler sayılsın: ilk sayım (önceki kapanış yok) fark üretmez, eşik denemesi her kalemde çalışsın
        let beforeD = DateKey.addDays(-1, to: tD)
        setClosings(beforeD, Dictionary(store.engine.calc(date: beforeD).rows.map { ($0.itemID, max($0.opening, 0)) },
                                        uniquingKeysWith: { a, _ in a }))
        let rowsD = store.engine.calc(date: tD).rows
        let even = Dictionary(rowsD.map { ($0.itemID, $0.opening) }, uniquingKeysWith: { a, _ in a })
        setClosings(tD, even)
        var oD = store.engine.overview(date: tD)
        let n = oD.countedItems
        check(oD.isFullyCounted && oD.problemItems == 0 && oD.trackerState == .ok, "tam sayım, fark yok → yeşil (\(n) kalem)")
        /// İlk `k` kalemde tolerans dışı fark (az çıkış) olan tam sayım
        func withProblems(_ k: Int) -> DayOverview {
            var values = even
            for r in rowsD.prefix(k) { values[r.itemID] = r.opening + (store.engine.itemsByID[r.itemID]?.tolerance ?? 0) + 5 }
            setClosings(tD, values)
            return store.engine.overview(date: tD)
        }
        let notable = (n + 9) / 10, significant = (n + 4) / 5
        check(n >= 11 && notable < significant, "eşik denemesi için yeterli kalem (\(n))")
        oD = withProblems(notable - 1)
        check(oD.problemItems == notable - 1 && !oD.hasNotableProblems && oD.trackerState == .ok,
              "\(notable - 1) / \(n) kalemde fark (%10'un altı) → yeşil")
        oD = withProblems(notable)
        check(oD.problemItems == notable && oD.hasNotableProblems && !oD.hasSignificantProblems && oD.trackerState == .warn,
              "\(notable) / \(n) kalemde fark (%10) → turuncu")
        oD = withProblems(significant)
        check(oD.problemItems == significant && oD.hasSignificantProblems && oD.trackerState == .bad,
              "\(significant) / \(n) kalemde fark (%20) → kırmızı")

        print("16) Personel hesabı: gün kapatma onayı, kapatılmış gün, ekip ve rol değişimi")
        // Web eşitlemesi bu modda kapalı; rolü CloudSyncController'ın yaptığı gibi doğrudan veriyoruz
        store.enforcedRole = CloudRole.staff
        check(!store.canEditCatalog && !store.canChangeLockedDays, "personel: tanımlar ve kapatılmış günler salt okunur")
        // (a) Sayımı olmayan (ileri tarihli) gün ⌘L ile kapatılmaz
        let future = DateKey.addDays(30, to: d2)
        store.selectedDate = future
        check(store.lockAction(future) == .nothingCounted && !store.lockAction(future).isAvailable, "sayımı olmayan günde Günü Kapat kapalı")
        store.requestLockToggle(future)
        check(!store.isLocked(future) && store.pendingDayClose == nil && store.data.days[future] == nil, "boş gün kapatılmadı")
        // (b) Sayılmış gün: önce onay istenir
        store.selectedDate = d2
        check(!store.isLocked(d2) && store.lockAction(d2) == .confirmClose, "personel: kapatmadan önce onay istenir")
        check(store.lockMenuTitle(d2) == "Günü Kapat…", "Gün menüsünde \"Günü Kapat…\"")
        store.requestLockToggle(d2)
        check(store.pendingDayClose == d2 && !store.isLocked(d2), "onay verilmeden gün kapatılmadı")
        let confirmText = store.dayCloseConfirmMessage(d2)
        check(confirmText.contains("kalem sayıldı") && confirmText.hasSuffix(DayLockAction.confirmMessage),
              "onay penceresi günün sayım durumunu ve kuralı gösteriyor")
        check(confirmText.contains("⚠ Sayım eksik") || confirmText.contains("✓ Sayım tamam"), "onay penceresi kontrol listesini işaretli gösteriyor")
        store.pendingDayClose = nil                                            // Vazgeç
        check(!store.isLocked(d2), "vazgeçince gün açık kaldı")
        store.requestLockToggle(d2)
        if let pending = store.pendingDayClose { store.confirmDayClose(pending) }
        check(store.isLocked(d2) && store.pendingDayClose == nil, "onaydan sonra gün kapatıldı")
        // 02.08 bugünden 7 günden eski: personel bu oturumda bir kez uyarılır (OldDayWarning)
        check(store.alert?.title == OldDayWarning.title, "personel: 7 günden eski güne yazınca uyarı")
        store.alert = nil
        check(store.lockAction(d2) == .unlockNotAllowed && store.isReadOnlyDay(d2), "personel kapatılmış günün kilidini açamaz")
        store.requestLockToggle(d2)
        check(store.isLocked(d2), "⌘L personel hesabıyla kilidi açmadı")
        // (c) Kapatılmış güne satış aktarma: personele kilidi açması söylenmez
        store.alert = nil
        store.confirmImport(report: report, date: d2)
        let importMessage = store.alert?.message ?? ""
        check(importMessage.contains("patron veya müdür") && !importMessage.contains("kilidini açın"),
              "kapatılmış gün uyarısı personele başka gün seçmesini söylüyor")
        store.alert = nil
        // (d) Ekip personel hesabıyla salt okunur; yazılan Sayan adı yalnızca güne yazılır
        let teamCount = store.employees.count
        let staffAdded = store.addEmployee(Employee(id: "x", name: "Personelin eklediği"))
        check(!staffAdded && store.employees.count == teamCount && store.alert != nil, "personel: ekip değiştirilemiyor (uyarı gösterildi)")
        store.alert = nil
        check(!store.setEmployeeActive("m", false) && store.employees.first { $0.id == "m" }?.active == true, "personel: üye pasif yapılamıyor")
        store.alert = nil
        store.setCountedBy(d1, "Yeni Personel")
        check(store.alert == nil, "eski gün uyarısı oturumda bir kez gösterilir")
        check(store.data.days[d1]?.countedBy == "Yeni Personel" && store.employees.count == teamCount && store.settings.staff.isEmpty,
              "personel: yazılan Sayan adı yalnızca güne yazıldı (ekibe ve eski listeye eklenmedi)")
        // (e) Rol web panelinde müdüre yükseltildi (CloudSyncController şube listesinden günceller): kısıtlar kalkar
        store.enforcedRole = CloudRole.manager
        check(store.canEditCatalog && store.canChangeLockedDays, "müdür: tanımlar ve kapatılmış günler düzenlenebilir")
        check(store.lockAction(d2) == .unlock && store.lockMenuTitle(d2) == "Gün Kilidini Aç", "müdür kilidi açabilir")
        store.requestLockToggle(d2)
        check(!store.isLocked(d2), "müdür ⌘L ile kilidi açtı")
        // Eksik gün (sayılmayan kalem, tanımsız reçete): müdür de kontrol listesini onaylar (DayCloseCheck)
        let mgrCheck = store.dayCloseCheck(d2)
        check(mgrCheck.needsConfirm && mgrCheck.confirmLabel == "Yine de Kapat" && mgrCheck.ruleText == DayCloseCheck.managerRule,
              "müdür: eksik günde kontrol listesi onay istiyor (Yine de Kapat)")
        check(store.lockMenuTitle(d2) == "Günü Kapat…", "müdür: eksik günde Gün menüsünde \"Günü Kapat…\"")
        store.requestLockToggle(d2)
        check(store.pendingDayClose == d2 && !store.isLocked(d2), "müdür: eksik gün kapatılmadan önce onay bekliyor")
        store.clearDailySearch = false
        store.showUncounted(d2)
        check(store.pendingDayClose == nil && store.dailyFilter == .uncounted && store.section == .daily && !store.isLocked(d2),
              "\"Sayılmayanları Göster\": Günlük Sayım Sayılmayan filtresiyle açıldı, gün açık")
        check(store.clearDailySearch, "\"Sayılmayanları Göster\": kalem araması temizleniyor (web ile aynı)")
        store.clearDailySearch = false
        store.dailyFilter = .all
        store.requestLockToggle(d2)
        if let pending = store.pendingDayClose { store.confirmDayClose(pending) }
        check(store.isLocked(d2) && store.pendingDayClose == nil, "müdür onayla kapatır")
        // Eksiksiz gün (tam sayım, satış raporu, tanımsız reçete yok): müdür onaysız kapatır
        store.confirmImport(report: SalesParser.parse(text: "Kodu\tÜrün Tipi\tAdedi\n13001\tKOLA\t2\n", sourceName: "selftest-kapat"), date: tD)
        let fullCheck = store.dayCloseCheck(tD)
        check(!fullCheck.needsConfirm && fullCheck.allOK && store.lockMenuTitle(tD) == "Günü Kapat",
              "müdür: eksiksiz günde onay yok (tolerans dışı fark yalnızca bilgi)")
        store.requestLockToggle(tD)
        check(store.isLocked(tD) && store.pendingDayClose == nil, "müdür eksiksiz günü onaysız kapatır")
        // Kapatılmamış günler (son 60 gün) ve toplu kapatma: kapatılmış ve sayımsız gün atlanır, tek geri alma adımı
        store.selectedDate = tD
        let unclosed = store.unclosedDays()
        check(unclosed.contains { $0.date == tA } && !unclosed.contains { $0.date == tD } && !unclosed.contains { $0.date == tC },
              "kapatılmamış günler: sayılmış açık günler (\(unclosed.count)), kapatılmış ve sayımsız gün yok")
        check(store.closeDays([tA, tD, tC]) == 1 && store.isLocked(tA) && !store.isLocked(tC), "toplu kapatma: yalnızca sayılmış açık gün kapatıldı")
        store.enforcedRole = CloudRole.staff
        check(store.closeDays([tB]) == 0, "personel toplu kapatamaz")
        store.enforcedRole = nil
        store.alert = nil

        print("16b) Sayım girişi: kalem arama, toplayarak giriş, paylaşılan bilgisayarda çalışan")
        let allD1 = store.dailyRows(date: d1, filter: .all, query: "")
        let patRows = store.dailyRows(date: d1, filter: .all, query: " PAT ")
        check(!patRows.isEmpty && patRows.count < allD1.count
              && patRows.allSatisfy { ItemSearch.fold(store.engine.itemsByID[$0.itemID]?.name ?? "").contains("pat") || $0.itemID.contains("pat") },
              "arama satırları daraltıyor (\"pat\": \(patRows.count) / \(allD1.count))")
        check(store.dailyRows(date: d1, filter: .all, query: "zzz-yok").isEmpty, "eşleşmeyen arama boş liste")
        check(store.dailyRows(date: d1, filter: .uncounted, query: "").allSatisfy { !$0.isCounted }, "filtre ve arama birlikte")
        // Kalem Ara (⌘F): Stok Kalemleri açıksa oradaki aramaya odaklanır, değilse Günlük Sayım'a geçer
        let sectionBefore = store.section
        store.section = .items
        store.requestItemSearch()
        check(store.section == .items && store.focusItemsSearch && !store.focusDailySearch, "⌘F Stok Kalemleri'nde kendi aramasına odaklanıyor")
        store.focusItemsSearch = false
        store.section = .overview
        store.requestItemSearch()
        check(store.section == .daily && store.focusDailySearch && !store.focusItemsSearch, "⌘F başka ekranda Günlük Sayım aramasına geçiyor")
        store.focusDailySearch = false
        store.section = sectionBefore
        check(Fmt.parseCountExpression("12+8+5", isKg: false) == 25 && Fmt.parseCountExpression("1.200", isKg: false) == 1200
              && Fmt.parseCountExpression("5-7", isKg: false) == nil, "toplayarak giriş: 12+8+5 = 25, adet 1.200 = 1200, 5-7 geçersiz")
        check(!store.asksWorker && store.activeWorker == nil, "bağlantı koduyla bağlı değilken çalışan sorulmuyor")
        store.askWorkerIfNeeded()
        check(!store.showWorkerPrompt, "kişisel hesapla / yerelde \"Şu an kim çalışıyor?\" açılmıyor")
        // Cihaz hesabıyla bağlı (otomatik testte web eşitlemesi kapalı: hesap doğrudan verilir); araya giren pencere yok
        store.connectRequest = nil
        store.importPreview = nil
        store.workbookPreview = nil
        store.testDeviceAccount = "pc-7kq2m9"
        store.askWorkerIfNeeded()
        check(store.showWorkerPrompt && !store.workerPromptIsChange, "cihaz hesabıyla bağlanınca çalışan soruluyor")
        store.markWorkerAsked()
        store.setWorker("  Murat A. ")
        check(store.activeWorker == "Murat A." && !store.showWorkerPrompt, "çalışan seçildi")
        store.askWorkerIfNeeded()
        check(!store.showWorkerPrompt, "aynı hesapta oturumda bir kez soruluyor")
        let wDay = "2026-08-26"
        store.entryBinding(item: "g90", date: wDay, \.closing).wrappedValue = 5
        check(store.data.days[wDay]?.countedBy == "Murat A.", "ilk kapanış girilince Sayan çalışan oldu")
        store.setCountedBy(wDay, "Selin K.")
        store.entryBinding(item: "peynir", date: wDay, \.closing).wrappedValue = 2
        check(store.data.days[wDay]?.countedBy == "Selin K.", "Sayan doluyken değişmedi")
        check(store.defaultWasteBy(date: "2026-08-27") == "Murat A.", "Zayi Ekle \"Kim\" varsayılanı çalışan")
        check(SessionWorker.summary("01.08.2026 sayımı: 90 Gr kapanış 120", worker: store.activeWorker) == "01.08.2026 sayımı: 90 Gr kapanış 120 · Murat A.",
              "değişiklik geçmişi özetine çalışan eklenir")
        // "Değiştir" → Esc / Vazgeç: seçili çalışan kalır (web closeWorkerPrompt)
        store.requestWorkerChange()
        check(store.showWorkerPrompt && store.workerPromptIsChange, "Değiştir: pencere yeniden açıldı")
        store.closeWorkerPrompt()
        check(!store.showWorkerPrompt && store.activeWorker == "Murat A.", "Değiştir → Vazgeç: çalışan değişmedi")
        // Çıkış yapılıp kişisel hesapla (ya da yerel) çalışılınca seçilen çalışan kullanılmaz
        store.testDeviceAccount = nil
        let pDay = "2026-08-28"
        check(store.data.days[pDay] == nil, "denemedeki gün boş")
        store.entryBinding(item: "g90", date: pDay, \.closing).wrappedValue = 7
        check(store.activeWorker == nil && store.data.days[pDay]?.entries["g90"]?.closing == 7 && store.data.days[pDay]?.countedBy == nil
              && store.defaultWasteBy(date: "2026-08-27") != "Murat A.",
              "çıkıştan sonra çalışan Sayan'a, Zayi \"Kim\"e ve özete yazılmıyor")
        // Başka bir cihaz hesabı: önceki seçim kullanılmaz, yeniden sorulur
        store.testDeviceAccount = "pc-abcdef"
        check(store.activeWorker == nil, "başka cihaz hesabında önceki çalışan kullanılmıyor")
        store.askWorkerIfNeeded()
        check(store.showWorkerPrompt && !store.workerPromptIsChange, "başka cihaz hesabında çalışan yeniden soruluyor")
        store.markWorkerAsked()
        store.closeWorkerPrompt()
        check(!store.showWorkerPrompt && store.activeWorker == nil, "ilk soruda Esc: Atla (çalışan seçilmedi)")
        // İlk hesaba dönünce de önceki seçim kullanılmaz (bu Mac yalnızca son sorulan hesabın seçimini tutar), yeniden sorulur
        store.testDeviceAccount = "pc-7kq2m9"
        store.askWorkerIfNeeded()
        check(store.activeWorker == nil && store.showWorkerPrompt, "ilk cihaz hesabına dönünce çalışan yeniden soruluyor")
        store.markWorkerAsked()
        store.setWorker(nil)
        check(!store.showWorkerPrompt && store.activeWorker == nil, "Atla: çalışan seçilmedi")
        store.testDeviceAccount = nil

        print("17) Eşitleme kayıt noktası arayüzü bekletmez (önce veri, sonra durum)")
        let year = DemoData.make(endingAt: d2, days: 365)
        store.applyRemote(year)
        let probe = CheckpointProbe()
        let dataFile = persistence.dataFile
        let expectedDays = year.days.count
        let started = Date()
        store.syncCheckpoint(dataChanged: true) {
            probe.dataWasCurrent = (try? Persistence.decode(Data(contentsOf: dataFile)))?.days.count == expectedDays
            probe.stateWritten = true
        }
        let mainMs = Date().timeIntervalSince(started) * 1000
        check(mainMs < 40, "kayıt noktasının ana iş parçacığındaki kısmı kısa (\(Int(mainMs)) ms; kodlama arka planda)")
        store.diskQueue.sync {}
        check(probe.stateWritten && probe.dataWasCurrent, "durum yazılırken veri dosyası güncel (365 gün)")

        print("18) Otomatik test modunda web eşitlemesi kapalı")
        check(!store.cloud.enabled && !store.cloud.isLinked && !store.cloud.isConnected, "web eşitlemesi kapalı (ağ kullanılmıyor)")
        check(store.cloud.realtimeStatus == .disconnected && !store.cloud.isLive, "canlı bağlantı kurulmadı")
        check(!store.cloud.canManageMembers, "Kullanıcılar bölümü bağlı değilken kapalı")

        print("19) Web'e bağlanma: bağlantı kodu ve envanter:// bağlantısı")
        store.alert = nil
        store.connectRequest = nil
        store.openConnect()
        check(store.connectRequest?.code == "" && store.connectRequest?.autoConnect == false, "Web'e Bağlan: bağlanma penceresi boş açılıyor")
        store.connectRequest = nil
        if let link = URL(string: "envanter://baglan?kod=7KQ2-M9XP-4TRA-HW3D&sunucu=https%3A%2F%2Fornek.supabase.co&anahtar=sb_publishable_x") {
            store.openConnectLink(link)
        }
        let request = store.connectRequest
        check(request?.code == "7KQ2M9XP4TRAHW3D" && request?.url == "https://ornek.supabase.co" && request?.key == "sb_publishable_x",
              "bağlantı: pencere kod ve sunucu ayarıyla dolu açılıyor")
        check(request?.autoConnect == false, "başka sunucuyu gösteren bağlantıda kendiliğinden bağlanılmıyor (Bağlan beklenir)")
        store.connectRequest = nil
        if let link = URL(string: "envanter://baglan?kod=7KQ2-M9XP-4TRA-HW3D") { store.openConnectLink(link) }
        check(store.connectRequest?.autoConnect == true && store.connectRequest?.url == nil,
              "şubeyle eşleşmemiş Mac'te sunucusuz bağlantıyla hemen bağlanılıyor")
        store.connectRequest = nil
        if let link = URL(string: PairLink.make(code: "7KQ2M9XP4TRAHW3D", url: CloudDefaults.url + "/", key: CloudDefaults.publishableKey)) {
            store.openConnectLink(link)
        }
        check(store.connectRequest?.autoConnect == true, "varsayılan sunucuyu gösteren bağlantıyla hemen bağlanılıyor")
        store.connectRequest = nil
        if let bad = URL(string: "envanter://baglan?kod=7KQ2-M9XP-4TRA-HW1D") { store.openConnectLink(bad) }
        check(store.connectRequest == nil && store.alert?.title == "Bağlantı açılamadı", "geçersiz kodlu bağlantıda uyarı")
        store.alert = nil
        check(PairCode.formatInput("Bağlantı kodu: 7kq2-m9xp-4tra-hw3d") == "7KQ2-M9XP-4TRA-HW3D" && PairCode.formatInput("7kq2m") == "7KQ2-M",
              "kod alanı: yapıştırılan mesajdan kod, yazarken 4'erli gruplar")
        check(PairCode.email("7KQ2M9XP4TRAHW3D") == "pc-7kq2m9@envanter.local" && PairCode.isDeviceAccount("pc-7kq2m9@envanter.local"),
              "cihaz hesabı: pc-7kq2m9@envanter.local")
        check(!store.cloud.canReconnectDevice && !store.cloud.isDeviceAccount, "bağlantı koduyla bağlanılmadı: Yeniden Bağlan yok")
        let issue = CloudSyncController.issue(for: .invalidCredentials, connected: false, login: "pc-7kq2m9@envanter.local")
        check(issue.message == CloudSyncGuide.invalidPairCode, "yanlış / kullanılmış kod: \"\(CloudSyncGuide.invalidPairCode)\"")
        check(issue.title == CloudSyncGuide.invalidPairCodeTitle, "yanlış / kullanılmış kodda durum etiketi \"\(CloudSyncGuide.invalidPairCodeTitle)\" (şifre değil)")
        check(CloudSyncController.issue(for: .invalidCredentials, connected: false, login: "ayse.yilmaz@envanter.local").title == "Şifre yanlış",
              "kişi hesabında durum etiketi: Şifre yanlış")
        let removed = CloudSyncController.issue(for: .sessionExpired, connected: false, login: "pc-7kq2m9@envanter.local")
        let kept = CloudSyncController.issue(for: .sessionExpired, connected: false, login: "pc-7kq2m9@envanter.local", deviceKept: true)
        check((removed.hint ?? "").contains("yeni bir bağlantı kodu") && !(kept.hint ?? "").contains("yeni bir bağlantı kodu")
              && (kept.hint ?? "").contains("Yeniden Bağlan"),
              "oturum düştü: kayıt silindiyse yeni kod, kayıt duruyorsa Yeniden Bağlan")
        let offline = CloudSyncController.issue(for: .network("timeout"), connected: true, login: "pc-7kq2m9@envanter.local", deviceKept: true)
        check(offline.title == CloudSyncError.network("timeout").issue(connected: true).title && offline.hint == CloudSyncGuide.offlineKeepsChanges,
              "sessiz giriş bağlantı yokken: asıl hata (bağlantı yok), değişiklikler bu Mac'te")

        print("19b) Eşik önerileri ve kurulum listesi (365 günlük demo verisi)")
        let suggestions = store.engine.thresholdSuggestions(asOf: d2)
        check(suggestions.count >= 10, "eşik önerileri hesaplandı (\(suggestions.count) kalem)")
        let setup = store.setupChecklist(date: d2)
        check(setup.activeItems == store.engine.activeItems.count && !setup.computerLinked && !setup.isDone,
              "kurulum listesi: web paneline bağlı değil, liste tamamlanmadı")
        if let first = suggestions.first(where: { $0.tolerance != nil }) {
            store.updateItem(first.itemID, actionName: "Tolerans") { $0.tolerance = nil }
            let changes = ThresholdChange.changes(items: store.data.items, suggestions: store.engine.thresholdSuggestions(asOf: d2))
            let pick = changes.filter { $0.itemID == first.itemID && $0.field == .tolerance }
            check(pick.count == 1 && pick.first?.preselected == true, "boş tolerans önerisi önceden seçili")
            check(store.applyThresholds(pick) && store.data.items.first { $0.id == first.itemID }?.tolerance == first.tolerance,
                  "Önerilenleri uygula: tolerans önerilen değer oldu")
        } else { check(false, "tolerans önerisi var") }

        print("20) Genel Bakış: Bugün kartı (satış raporu → sayım → günü kapat)")
        let o1 = store.engine.overview(date: d1)
        let steps1 = DaySteps(o1)
        check(steps1.isDone(.sales) == o1.hasSales && steps1.isDone(.count) == o1.isFullyCounted && steps1.closed == o1.isLocked,
              "adımların durumu günün özetinden (satış raporu, sayım, kapatma)")
        let empty = DaySteps(store.engine.overview(date: DateKey.addDays(60, to: d2)))
        check(empty.next == .sales && store.lockAction(DateKey.addDays(60, to: d2)) == .nothingCounted,
              "boş gün: sıradaki adım satış raporu, gün kapatılamaz")

        print("21) Sürüm uyumu ve gün dönümü")
        check(DataFormat.level == 2 && DataFormat.level(ofPresence: RealtimePresence.mac(branch: "Tuzla", app: "2.1", since: Date())) == 2,
              "canlı durum bilgisi veri biçimi düzeyini bildiriyor (fmt 2)")
        check(Brand.version == "2.1" || Brand.version == "geliştirme", "uygulama sürümü 2.1 (\(Brand.version))")
        check(DataFormat.newerPeerLevel(in: ["web-1": [.object(["client": .string("web"), "fmt": .number(3)])]], ownKey: "mac-1") == 3,
              "kanalda daha yeni sürüm görülünce uyarı düzeyi")
        let day0 = "2026-10-14", day1 = "2026-10-15"
        store.setKnownToday(day0)
        store.selectedDate = day0
        store.checkDayRollover(today: day1, editing: true)
        check(store.selectedDate == day0 && store.dayRollover == nil, "gün dönümü: biri yazarken beklenir")
        store.checkDayRollover(today: day1, editing: false)
        check(store.selectedDate == day1 && store.dayRollover == DayRolloverNotice(from: day0, to: day1),
              "gün dönümü: bugün seçiliyken yeni güne geçildi, şerit gösterildi (\(DayRollover.title(day1)))")
        store.returnFromRollover()
        check(store.selectedDate == day0 && store.dayRollover == nil, "\"\(DayRollover.backLabel)\" önceki güne döndü")
        store.checkDayRollover(today: "2026-10-16", editing: false)
        check(store.selectedDate == day0 && store.dayRollover == nil, "başka gün görüntülenirken gün değişmez")
        store.setKnownToday(DateKey.today())
    }
}
