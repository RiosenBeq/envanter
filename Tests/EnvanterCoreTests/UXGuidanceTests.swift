import XCTest
@testable import EnvanterCore

/// Arayüz metinleri ve kuralları: yüzde biçimi, dönem karşılaştırması, grafik etiketleri, ilk kullanım,
/// web eşitlemesi hata açıklamaları ve gün kapatma onayı.
final class UXGuidanceTests: XCTestCase {
    // MARK: Biçim

    func testPercentFormatsUseTurkishSignPlacement() {
        XCTAssertEqual(Fmt.percent(0.133), "%13,3")
        XCTAssertEqual(Fmt.percent(0.3), "%30")
        XCTAssertEqual(Fmt.percent(0.0612, maxFraction: 0), "%6")
        XCTAssertEqual(Fmt.percent(.nan), "—")
        XCTAssertEqual(Fmt.signedPercent(0.1333), "+%13,3")
        XCTAssertEqual(Fmt.signedPercent(-0.05), "-%5")
        XCTAssertEqual(Fmt.signedPercent(0.0004), "%0")
        XCTAssertEqual(Fmt.signedPercent(-0.0004), "%0")
        XCTAssertEqual(Fmt.signedPercent(.infinity), "—")
        XCTAssertEqual(DateKey.dayMonth("2026-10-09"), "09.10")
        XCTAssertEqual(DateKey.dayMonth("bozuk"), "bozuk")
    }

    /// Yan menü grup başlıkları ve yardım bölüm başlıkları Türkçe büyük harfle yazılır ("DIĞER" değil "DİĞER")
    func testTurkishUppercase() {
        XCTAssertEqual(Fmt.upper("Diğer"), "DİĞER")
        XCTAssertEqual(Fmt.upper("Notlar ve ipuçları"), "NOTLAR VE İPUÇLARI")
        XCTAssertEqual(Fmt.upper("Terimler sözlüğü"), "TERİMLER SÖZLÜĞÜ")
        XCTAssertEqual(Fmt.upper("Raporlar"), "RAPORLAR")
        XCTAssertEqual(Fmt.upper("Başlarken"), "BAŞLARKEN")
    }

    // MARK: Dönem karşılaştırması

    func testPreviousRangeHasSameLength() {
        let r = PeriodComparison.previousRange(from: "2026-09-11", to: "2026-10-10")
        XCTAssertEqual(r.from, "2026-08-12")
        XCTAssertEqual(r.to, "2026-09-10")
        XCTAssertEqual(DateKey.distance(from: r.from, to: r.to), DateKey.distance(from: "2026-09-11", to: "2026-10-10"))
        let one = PeriodComparison.previousRange(from: "2026-10-10", to: "2026-10-10")
        XCTAssertEqual(one.from, "2026-10-09")
        XCTAssertEqual(one.to, "2026-10-09")
    }

    func testComparableNeedsHalfAsManyRecordedDays() {
        XCTAssertFalse(PeriodComparison.isComparable(previousDays: 5, days: 30))   // demo verisinin ilk ayı: +%556 gibi
        XCTAssertFalse(PeriodComparison.isComparable(previousDays: 14, days: 30))
        XCTAssertTrue(PeriodComparison.isComparable(previousDays: 15, days: 30))
        XCTAssertTrue(PeriodComparison.isComparable(previousDays: 30, days: 30))
        XCTAssertFalse(PeriodComparison.isComparable(previousDays: 0, days: 10))
        XCTAssertFalse(PeriodComparison.isComparable(previousDays: 3, days: 0))
        // Kural iki yönlüdür: ayın 10'unda "Bu ay" (10 kayıtlı gün) önceki 31 günle karşılaştırılmaz ("-%66" gibi)
        XCTAssertFalse(PeriodComparison.isComparable(previousDays: 31, days: 10))
        XCTAssertFalse(PeriodComparison.isComparable(previousDays: 31, days: 15))
        XCTAssertTrue(PeriodComparison.isComparable(previousDays: 31, days: 16))
        XCTAssertEqual(PeriodComparison.change(110, 100) ?? .nan, 0.1, accuracy: 1e-12)
        XCTAssertNil(PeriodComparison.change(10, 0))
    }

    func testComparisonNoteExplainsWhichSideIsShort() {
        XCTAssertEqual(PeriodComparison.note(previousFrom: "2026-09-01", previousTo: "2026-09-30", previousDays: 30, days: 28),
                       "Değişim rozetleri önceki eşit uzunluktaki dönemle (01.09.2026 – 30.09.2026) karşılaştırır.")
        XCTAssertEqual(PeriodComparison.note(previousFrom: "2026-08-12", previousTo: "2026-09-10", previousDays: 5, days: 30),
                       "Önceki eşit dönemde (12.08.2026 – 10.09.2026) yeterli kayıt olmadığı için değişim gösterilmiyor.")
        XCTAssertEqual(PeriodComparison.note(previousFrom: "2026-08-31", previousTo: "2026-09-30", previousDays: 31, days: 10),
                       "Bu dönemde henüz 10 kayıtlı gün var, önceki eşit dönemde (31.08.2026 – 30.09.2026) 31 gün; dönemler karşılaştırılabilir olunca değişim gösterilir.")
        XCTAssertEqual(PeriodComparison.note(previousFrom: "2026-08-31", previousTo: "2026-09-30", previousDays: 0, days: 10),
                       "Önceki eşit dönemde (31.08.2026 – 30.09.2026) yeterli kayıt olmadığı için değişim gösterilmiyor.")
    }

    /// "Bu ay" ayın 10'unda: dönem ayın sonuna kadar uzanır ama yalnızca 10 kayıtlı gün vardır; önceki eşit dönem dolu
    /// olduğu için eski tek yönlü kural "-%66" gibi rozetler gösteriyordu
    func testThisMonthOnTheTenthIsNotComparable() {
        let today = "2026-10-10"
        let engine = Engine(data: DemoData.make(endingAt: today, days: 90))
        let from = "2026-10-01", to = "2026-10-31"
        let now = engine.periodStats(from: from, to: to)
        let prevRange = PeriodComparison.previousRange(from: from, to: to)
        let prev = engine.periodStats(from: prevRange.from, to: prevRange.to)
        XCTAssertEqual(now.days.count, 10)
        XCTAssertGreaterThanOrEqual(prev.days.count, 30)
        XCTAssertFalse(PeriodComparison.isComparable(previousDays: prev.days.count, days: now.days.count))
    }

    /// Demo verisi (35 gün): son 30 günün önceki dönemi yalnızca 5 gün içerir, değişim gösterilmemeli
    func testDemoDataFirstMonthIsNotComparable() {
        let end = "2026-10-10"
        let engine = Engine(data: DemoData.make(endingAt: end, days: 35))
        let from = DateKey.addDays(-29, to: end)
        let now = engine.periodStats(from: from, to: end)
        let prevRange = PeriodComparison.previousRange(from: from, to: end)
        let prev = engine.periodStats(from: prevRange.from, to: prevRange.to)
        XCTAssertEqual(now.days.count, 30)
        XCTAssertEqual(prev.days.count, 5)
        XCTAssertFalse(PeriodComparison.isComparable(previousDays: prev.days.count, days: now.days.count))
        // 60 günlük veride iki dönem de dolu: karşılaştırılır
        let longer = Engine(data: DemoData.make(endingAt: end, days: 60))
        let p2 = longer.periodStats(from: prevRange.from, to: prevRange.to)
        XCTAssertTrue(PeriodComparison.isComparable(previousDays: p2.days.count, days: now.days.count))
    }

    // MARK: Grafik etiketleri

    func testChartLabelsSkipOverlaps() {
        typealias C = ChartLabelLayout.Candidate
        let candidates = [
            C(id: "a", text: "AVANTAJLI DOYURAN KUTU", x: 1.80, y: 492),
            C(id: "b", text: "MEGA KANKA MENÜ", x: 1.69, y: 477),          // a ile üst üste biner
            C(id: "c", text: "MEXICANO BURGER MENÜ", x: 2.30, y: 150),     // uzakta
            C(id: "d", text: "AİLE KOVASI MENÜ", x: 0.55, y: 770),
            C(id: "a", text: "AVANTAJLI DOYURAN KUTU", x: 1.80, y: 492),   // yinelenen
        ]
        let shown = ChartLabelLayout.visible(candidates, xDomain: 0...2.5, yDomain: 0...1000, width: 1000, height: 280)
        XCTAssertEqual(shown, ["a", "c", "d"])
        // Geniş grafikte ikisi de sığar
        let wide = ChartLabelLayout.visible(Array(candidates.prefix(2)), xDomain: 0...2.5, yDomain: 0...1000, width: 4000, height: 2000)
        XCTAssertEqual(wide, ["a", "b"])
        // Sonsuz değerler atlanır
        XCTAssertTrue(ChartLabelLayout.visible([C(id: "x", text: "X", x: .nan, y: 1)], xDomain: 0...1, yDomain: 0...1,
                                               width: 100, height: 100).isEmpty)
    }

    func testChartLabelShortTextAndNiceDomain() {
        XCTAssertEqual(ChartLabelLayout.shortText("AVANTAJLI DOYURAN KUTU"), "AVANTAJLI DOYURAN…")
        XCTAssertEqual(ChartLabelLayout.shortText("KANKA MENÜ"), "KANKA MENÜ")
        XCTAssertEqual(ChartLabelLayout.niceDomain(min: 0, max: 846), 0...1000)
        XCTAssertEqual(ChartLabelLayout.niceDomain(min: 0, max: 1000), 0...1000)
        XCTAssertEqual(ChartLabelLayout.niceDomain(min: -120, max: 480), -200...600)
        XCTAssertEqual(ChartLabelLayout.niceDomain(min: 0, max: 0), 0...1)
        let d = ChartLabelLayout.niceDomain(min: 10, max: 37)
        XCTAssertEqual(d.lowerBound, 0)
        XCTAssertGreaterThanOrEqual(d.upperBound, 37)
    }

    // MARK: İlk kullanım

    func testOnboardingShowsOnlyWithoutDailyRecords() {
        var data = AppData.seeded()
        XCTAssertTrue(Onboarding.isEmpty(data))
        // Boş gün kaydı (ör. yazılıp silinmiş not) veri sayılmaz
        data.days["2026-10-10"] = DayRecord(date: "2026-10-10")
        XCTAssertTrue(Onboarding.isEmpty(data))
        // Stok kalemi düzenlemek ilk kullanımı bitirmez
        data.items[0].unitCost = 38
        XCTAssertTrue(Onboarding.isEmpty(data))
        // İlk sayım girilince kart kaybolur
        var counted = data
        counted.days["2026-10-10"] = DayRecord(date: "2026-10-10", entries: ["g90": DayEntry(closing: 12)])
        XCTAssertFalse(Onboarding.isEmpty(counted))
        // Kapatılmış (boş) gün, not, personel ve sipariş de veridir
        var locked = data
        locked.days["2026-10-10"] = DayRecord(date: "2026-10-10", locked: true)
        XCTAssertFalse(Onboarding.isEmpty(locked))
        var noted = data
        noted.days["2026-10-10"] = DayRecord(date: "2026-10-10", note: "Açılış günü")
        XCTAssertFalse(Onboarding.isEmpty(noted))
        var staffed = data
        staffed.employees = [Employee(name: "Ayşe", payType: .monthly, rate: 30_000)]
        XCTAssertFalse(Onboarding.isEmpty(staffed))
        var ordered = data
        ordered.purchaseOrders = [PurchaseOrder(date: "2026-10-10", lines: [OrderLine(itemID: "g90", qty: 10)])]
        XCTAssertFalse(Onboarding.isEmpty(ordered))
        XCTAssertFalse(Onboarding.isEmpty(DemoData.make(endingAt: "2026-10-10", days: 3)))
    }

    // MARK: Web eşitlemesi metinleri

    func testSetupMissingIssueTellsOwnerToRunDatabaseSetup() {
        let offline = CloudSyncError.notProvisioned.issue(connected: false)
        XCTAssertEqual(offline.title, "Kurulum eksik")
        XCTAssertTrue(offline.message.contains("envanter tabloları kurulu değil"))
        XCTAssertEqual(offline.severity, .actionNeeded)
        let hint = offline.hint ?? ""
        XCTAssertTrue(hint.contains("SQL Editor"))
        XCTAssertTrue(hint.contains("Patron"))
        XCTAssertTrue(hint.contains("\"Bağlan\""))
        let online = CloudSyncError.notProvisioned.issue(connected: true).hint ?? ""
        XCTAssertTrue(online.contains("SQL Editor"))
        XCTAssertTrue(online.contains("bu Mac'te saklanır"))
        XCTAssertTrue(CloudSyncError.notProvisioned.issue(connected: false).text.hasPrefix(offline.message))
    }

    func testNetworkAndPasswordIssuesAreActionable() {
        let offline = CloudSyncError.network("timeout").issue(connected: true)
        XCTAssertEqual(offline.title, "Bağlantı yok")
        XCTAssertEqual(offline.severity, .temporary)
        XCTAssertTrue(offline.hint?.contains("değişiklikler bu Mac'te saklanır, bağlantı gelince kendiliğinden gönderilir") == true)
        XCTAssertTrue(CloudSyncError.network("").issue(connected: false).hint?.contains("\"Bağlan\"") == true)

        let password = CloudSyncError.invalidCredentials.issue(connected: false)
        XCTAssertEqual(password.message, "E-posta ya da şifre yanlış.")
        XCTAssertTrue(password.hint?.contains("Yönetim → Kullanıcılar") == true)
        XCTAssertTrue(password.hint?.contains("\"Şifre belirle\"") == true)

        let member = CloudSyncError.noWorkspace.issue(connected: false)
        XCTAssertTrue(member.hint?.contains("\"Hesap oluştur\"") == true)
        XCTAssertTrue(CloudSyncGuide.accountHelp.contains("Yönetim → Kullanıcılar ekranında \"Hesap oluştur\""))
        XCTAssertTrue(CloudSyncError.sessionExpired.issue(connected: false).hint?.contains("korunuyor") == true)
    }

    func testEveryErrorHasTitleAndMessage() {
        let all: [CloudSyncError] = [
            .invalidCredentials, .emailNotConfirmed, .sessionExpired, .forbidden(""), .network("x"), .rateLimited,
            .notProvisioned, .invalidRequest("x"), .server(status: 500, message: ""), .invalidResponse(""), .notConfigured,
            .noWorkspace, .invalidConfiguration("x"),
        ]
        for e in all {
            for connected in [false, true] {
                let i = e.issue(connected: connected)
                XCTAssertFalse(i.title.isEmpty, "\(e)")
                XCTAssertFalse(i.message.isEmpty, "\(e)")
                XCTAssertEqual(i.message, e.localizedDescription, "\(e)")
            }
        }
    }

    func testPendingAndLastSyncTexts() throws {
        XCTAssertEqual(CloudSyncGuide.pendingText(0, issue: nil), "Yok, tüm değişiklikler gönderildi")
        XCTAssertEqual(CloudSyncGuide.pendingText(3, issue: nil), "3 değişiklik gönderilmeyi bekliyor")
        // Bağlantı sorunu geçicidir; giriş / kurulum / yetki sorunu biri bir şey yapınca çözülür
        XCTAssertEqual(CloudSyncGuide.pendingText(2, issue: CloudSyncError.network("").issue(connected: true)),
                       "2 değişiklik bu Mac'te saklanıyor; bağlantı gelince gönderilir")
        XCTAssertEqual(CloudSyncGuide.pendingText(2, issue: CloudSyncError.sessionExpired.issue(connected: true)),
                       "2 değişiklik bu Mac'te saklanıyor; sorun giderilince gönderilir")
        XCTAssertEqual(CloudSyncGuide.pendingText(2, issue: CloudSyncError.notProvisioned.issue(connected: true)),
                       "2 değişiklik bu Mac'te saklanıyor; sorun giderilince gönderilir")

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Istanbul"))
        func at(_ d: Int, _ h: Int, _ m: Int) -> Date {
            cal.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h, minute: m))!
        }
        let now = at(10, 15, 0)
        XCTAssertEqual(CloudSyncGuide.lastSyncText(at(10, 14, 5), now: now, calendar: cal), "Bugün 14:05")
        XCTAssertEqual(CloudSyncGuide.lastSyncText(at(9, 18, 20), now: now, calendar: cal), "Dün 18:20")
        XCTAssertEqual(CloudSyncGuide.lastSyncText(at(7, 9, 0), now: now, calendar: cal), "7 Ekim 09:00")
        XCTAssertEqual(CloudSyncGuide.lastSyncText(nil, now: now, calendar: cal), "Henüz yok")
    }

    func testRoleSummaries() {
        XCTAssertTrue(CloudRole.summary(CloudRole.staff).contains("salt okunur"))
        XCTAssertTrue(CloudRole.summary(CloudRole.staff).contains("günü kapatabilirsiniz"))
        XCTAssertTrue(CloudRole.summary(CloudRole.manager).contains("kilidini açabilirsiniz"))
        XCTAssertTrue(CloudRole.summary(CloudRole.owner).contains("Yönetim → Kullanıcılar"))
        XCTAssertFalse(CloudRole.summary(nil).isEmpty)
    }

    // MARK: Gün kapatma onayı

    func testDayCloseConfirmationShowsWhatIsMissing() {
        let partial = DayLockAction.confirmDetail(counted: 14, total: 21, hasSales: false)
        XCTAssertTrue(partial.contains("Sayım eksik: 14 / 21 kalem sayıldı, 7 kalem sayılmadı."))
        XCTAssertTrue(partial.contains("Satış raporu aktarılmadı"))
        XCTAssertTrue(partial.hasSuffix(DayLockAction.confirmMessage))
        let full = DayLockAction.confirmDetail(counted: 21, total: 21, hasSales: true)
        XCTAssertTrue(full.hasPrefix("Sayım tamam: 21 / 21 kalem sayıldı.\nSatış raporu aktarıldı."))
        XCTAssertTrue(full.contains("kilidi yalnızca patron veya müdür açabilir"))
        XCTAssertFalse(DayLockAction.confirmDetail(counted: 0, total: 0, hasSales: true).contains("Sayım"))
    }
}
