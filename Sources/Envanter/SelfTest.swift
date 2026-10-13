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
        store.pendingDayClose = nil                                            // Vazgeç
        check(!store.isLocked(d2), "vazgeçince gün açık kaldı")
        store.requestLockToggle(d2)
        if let pending = store.pendingDayClose { store.confirmDayClose(pending) }
        check(store.isLocked(d2) && store.pendingDayClose == nil, "onaydan sonra gün kapatıldı")
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
        check(store.data.days[d1]?.countedBy == "Yeni Personel" && store.employees.count == teamCount && store.settings.staff.isEmpty,
              "personel: yazılan Sayan adı yalnızca güne yazıldı (ekibe ve eski listeye eklenmedi)")
        // (e) Rol web panelinde müdüre yükseltildi (CloudSyncController şube listesinden günceller): kısıtlar kalkar
        store.enforcedRole = CloudRole.manager
        check(store.canEditCatalog && store.canChangeLockedDays, "müdür: tanımlar ve kapatılmış günler düzenlenebilir")
        check(store.lockAction(d2) == .unlock && store.lockMenuTitle(d2) == "Gün Kilidini Aç", "müdür kilidi açabilir")
        store.requestLockToggle(d2)
        check(!store.isLocked(d2), "müdür ⌘L ile kilidi açtı")
        store.requestLockToggle(d2)
        check(store.isLocked(d2) && store.pendingDayClose == nil, "müdür onaysız kapatır")
        store.enforcedRole = nil

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

        print("20) Genel Bakış: Bugün kartı (satış raporu → sayım → günü kapat)")
        let o1 = store.engine.overview(date: d1)
        let steps1 = DaySteps(o1)
        check(steps1.isDone(.sales) == o1.hasSales && steps1.isDone(.count) == o1.isFullyCounted && steps1.closed == o1.isLocked,
              "adımların durumu günün özetinden (satış raporu, sayım, kapatma)")
        let empty = DaySteps(store.engine.overview(date: DateKey.addDays(60, to: d2)))
        check(empty.next == .sales && store.lockAction(DateKey.addDays(60, to: d2)) == .nothingCounted,
              "boş gün: sıradaki adım satış raporu, gün kapatılamaz")
    }
}
