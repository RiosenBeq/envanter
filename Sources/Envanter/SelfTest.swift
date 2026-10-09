import SwiftUI
import AppKit
import EnvanterCore

/// Yakalanmamış Objective-C istisnasının nedenini ve yığınını yazar (C işlev göstericisi olarak verilir)
private func selfTestExceptionHandler(_ e: NSException) {
    print("SELFTEST İSTİSNA: \(e.name.rawValue): \(e.reason ?? "")")
    print(e.callStackSymbols.prefix(30).joined(separator: "\n"))
}

/// Uçtan uca sistem testi: ENVANTER_SELFTEST=1 ile açılınca uygulamanın gerçek AppStore'u üzerinden
/// tipik bir iş gününü baştan sona oynatır, her adımı doğrular ve sonucu çıkış koduyla bildirir (0 = başarılı).
/// Geçici bir veri klasörü kullanır; gerçek veriye dokunmaz. CI'da macOS üzerinde çalıştırılır.
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

        print("1) Açılış ve varsayılanlar")
        check(store.data.items.count >= 20, "varsayılan stok kalemleri yüklendi")
        check(store.data.products.count >= 300, "varsayılan reçeteler yüklendi")
        check(store.section == .overview, "uygulama Genel Bakış ile açılıyor")

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
        check(near(calc?.diff, -30), "satış yokken fark −30")

        print("3) Satış raporu aktarımı (metin + tutar)")
        let report = SalesParser.parse(text: "Kodu\tÜrün Tipi\tAdedi\tTutar\n11101\tDUBLEX BURGER\t14\t5460\n17001\tZAYİ 100 GR KÖFTE\t1\n13001\tKOLA\t10\t500\n99999\tYENİ ÜRÜN\t3\t900\n",
                                       sourceName: "selftest")
        check(report.lines.count == 4, "4 satış satırı okundu")
        store.confirmImport(report: report, date: d1)
        calc = store.engine.calc(date: d1).rows.first { $0.itemID == "g90" }
        check(near(calc?.sold, 28), "Dublex 14 adet → 90 gr satılan 28")
        check(near(calc?.waste, 1), "ZAYİ köfte → zaiyat 1")
        check(near(calc?.diff, -1), "fark = 28 + 1 − 30 = −1")
        check(store.engine.overview(date: d1).unknownLines == 1, "reçetesi tanımsız 1 ürün işaretlendi")
        check(near(store.data.days[d1]?.salesRevenue, 6860), "satış tutarı 6.860 ₺")

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

        print("5) Maliyet, tolerans ve fiyat geçmişi")
        step("maliyet") { store.updateItem("g90") { $0.unitCost = 38 } }
        step("maliyet artışı") { store.setItemCost("g90", 42) }
        let g90 = store.engine.itemsByID["g90"]
        check(g90?.unitCost == 42, "birim maliyet güncellendi")
        check(near(g90?.lastPriceChange?.ratio, 4.0 / 38), "fiyat geçmişi: %10,5 artış")
        check(!store.engine.priceAlerts(asOf: DateKey.today(), threshold: 0.05).isEmpty, "fiyat artışı uyarısı üretildi")
        step("tolerans") { store.updateItem("g90") { $0.tolerance = 2 } }
        check(store.engine.calc(date: d1).rows.first { $0.itemID == "g90" }?.severity == .withinTolerance, "−1 fark tolerans (±2) içinde")
        check(near(store.engine.calc(date: d1).rows.first { $0.itemID == "g90" }?.diffValue, -42), "farkın tutarı −42 ₺")

        print("6) Açılış devri ve hareketsiz kalemler")
        let d2row = store.engine.calc(date: d2).rows.first { $0.itemID == "g90" }
        check(d2row?.opening == 120 && d2row?.openingIsAuto == true, "ertesi günün açılışı önceki kapanıştan (120)")
        step("peynir") { store.entryBinding(item: "peynir", date: d1, \.closing).wrappedValue = 5 }
        let filled = store.fillUncountedWithOpening(date: d2)
        check(filled >= 2, "hareketsiz kalemler dolduruldu (\(filled))")
        check(store.data.days[d2]?.entries["peynir"]?.closing == 5, "peynir kapanışı = açılış (5)")

        print("7) Gün kilidi")
        step("kilit") { store.setLocked(d1, true) }
        store.entryBinding(item: "g90", date: d1, \.closing).wrappedValue = 1
        check(store.data.days[d1]?.entries["g90"]?.closing == 120, "kilitli günde sayım değişmiyor")
        store.clearSales(date: d1)
        check(store.data.days[d1]?.sales.count == 4, "kilitli günde satışlar silinemiyor")
        step("kilit aç") { store.setLocked(d1, false) }
        check(!store.isLocked(d1), "kilit açıldı")

        print("8) Personel maliyeti ve prime cost")
        let m = Employee(id: "m", name: "Müdür", payType: .monthly, rate: 31_000, costFactor: 1.2)
        let h = Employee(id: "h", name: "Servis", payType: .hourly, rate: 150, defaultHours: 6)
        let k = Employee(id: "k", name: "Kurye", payType: .daily, rate: 2_000)
        step("personel") { store.addEmployee(m); store.addEmployee(h); store.addEmployee(k) }
        let filledShifts = store.fillDefaultShifts(date: d1)
        check(filledShifts == 2, "varsayılan vardiyalar dolduruldu (saatlik + yevmiyeli)")
        step("mesai") { store.shiftBinding("h", date: d1, \.extra).wrappedValue = 100 }
        step("diğer gider") { store.otherLaborBinding(d1).wrappedValue = 500 }
        let labor = store.engine.labor(date: d1)
        // 31.000 × 1,2 ÷ 31 = 1.200 · 6 × 150 + 100 = 1.000 · 2.000 · diğer 500
        check(near(labor.total, 4_700), "günün personel maliyeti 4.700 ₺")
        let p = store.engine.periodStats(from: d1, to: d1)
        check(near(p.laborPct, 4_700.0 / 6_860), "personel oranı = 4.700 / 6.860")
        check(p.primeCostPct != nil, "prime cost oranı hesaplandı")
        step("ayrıldı") { store.markEmployeeLeft("k", on: d1) }
        check(store.engine.labor(date: d2).lines.first { $0.employee.id == "k" } == nil, "ayrılan personel ertesi gün maliyete girmiyor")

        print("9) Sipariş oluşturma ve teslim alma")
        store.selectedDate = d2
        step("sayım d2") { store.entryBinding(item: "g90", date: d2, \.closing).wrappedValue = 20 }
        let created = store.createOrder(date: d2, supplier: "Et Tedarikçisi")
        check(created && store.openOrders.count == 1, "önerilerden açık sipariş oluşturuldu")
        if let order = store.openOrders.first {
            let line = order.lines.first { $0.itemID == "g90" }
            check(line != nil, "siparişte 90 gr var")
            let before = store.data.days[d2]?.entries["g90"]?.incoming ?? 0
            let ok = store.receiveOrder(order.id, on: d2, quantities: ["g90": 100], prices: ["g90": 44])
            check(ok, "sipariş teslim alındı")
            check(near(store.data.days[d2]?.entries["g90"]?.incoming, before + 100), "teslimat Gelen'e işlendi (+100)")
            check(store.engine.itemsByID["g90"]?.unitCost == 44, "fatura fiyatı birim maliyete yazıldı")
            check(store.openOrders.isEmpty, "sipariş kapandı")
        }

        print("10) Ayarlar ve hedefler")
        step("hedef") { store.updateSettings { $0.targetLaborPct = 0.25; $0.branchName = "Test Şube" } }
        check(store.settings.targetLaborPct == 0.25 && store.settings.branchName == "Test Şube", "hedef ve şube adı kaydedildi")

        print("11) Excel dışa aktarımı")
        if let x = try? XlsxReader.read(data: Exporter.history(engine: store.engine, from: d1, to: d2)) {
            check(x.map { $0.name } == ["Alımlar", "Özet", "Günlük Maliyet", "Personel"], "geçmiş Excel'i 4 sayfa")
        } else { check(false, "geçmiş Excel'i okunabilir") }
        check((try? XlsxReader.read(data: Exporter.countSheet(engine: store.engine, date: d2)))?.first?.name == "Sayım Formu", "sayım formu")
        check((try? XlsxReader.read(data: Exporter.day(engine: store.engine, date: d1)))?.count == 2, "gün Excel'i 2 sayfa")

        print("12) Diske kayıt ve yeniden yükleme")
        store.flush()
        switch Persistence(directory: dir).load() {
        case .loaded(let back):
            check(back.days[d1]?.entries["g90"]?.closing == 120, "sayım diske yazıldı")
            check(back.employees.count == 3, "personel diske yazıldı")
            check(back.purchaseOrders.first?.status == .received, "sipariş durumu diske yazıldı")
            check(back.items.first { $0.id == "g90" }?.costHistory?.count ?? 0 >= 2, "fiyat geçmişi diske yazıldı")
            check(back.settings.branchName == "Test Şube", "ayarlar diske yazıldı")
        default:
            check(false, "veri dosyası yeniden yüklenebilir")
        }
        check(!persistence.backups().isEmpty, "günlük yedek alındı")

        print("13) Varsayılanları geri ekleme ve silme")
        step("ürün sil") { store.deleteProduct("11101") }
        check(store.product("11101") == nil, "ürün silindi")
        let restored = store.restoreMissingDefaults()
        check(restored.products == 1 && store.product("11101") != nil, "silinen varsayılan ürün geri eklendi")
    }
}
