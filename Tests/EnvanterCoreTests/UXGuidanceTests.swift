import XCTest
@testable import EnvanterCore

/// Arayüz metinleri ve kuralları: yüzde biçimi, ilk kullanım, web eşitlemesi hata açıklamaları ve gün kapatma onayı.
final class UXGuidanceTests: XCTestCase {
    // MARK: Biçim

    func testPercentFormatsUseTurkishSignPlacement() {
        XCTAssertEqual(Fmt.percent(0.133), "%13,3")
        XCTAssertEqual(Fmt.percent(0.3), "%30")
        XCTAssertEqual(Fmt.percent(0.0612, maxFraction: 0), "%6")
        XCTAssertEqual(Fmt.percent(.nan), "—")
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

    // MARK: İlk kullanım

    func testOnboardingShowsOnlyWithoutDailyRecords() {
        var data = AppData.seeded()
        XCTAssertTrue(Onboarding.isEmpty(data))
        // Boş gün kaydı (ör. yazılıp silinmiş not) veri sayılmaz
        data.days["2026-10-10"] = DayRecord(date: "2026-10-10")
        XCTAssertTrue(Onboarding.isEmpty(data))
        // Stok kalemi düzenlemek ilk kullanımı bitirmez
        data.items[0].minStock = 5
        XCTAssertTrue(Onboarding.isEmpty(data))
        // İlk sayım girilince kart kaybolur
        var counted = data
        counted.days["2026-10-10"] = DayRecord(date: "2026-10-10", entries: ["g90": DayEntry(closing: 12)])
        XCTAssertFalse(Onboarding.isEmpty(counted))
        // Kapatılmış (boş) gün, not, ekip üyesi ve sipariş de veridir
        var locked = data
        locked.days["2026-10-10"] = DayRecord(date: "2026-10-10", locked: true)
        XCTAssertFalse(Onboarding.isEmpty(locked))
        var noted = data
        noted.days["2026-10-10"] = DayRecord(date: "2026-10-10", note: "Açılış günü")
        XCTAssertFalse(Onboarding.isEmpty(noted))
        var staffed = data
        staffed.employees = [Employee(name: "Ayşe", role: "Kasiyer")]
        XCTAssertFalse(Onboarding.isEmpty(staffed))
        var ordered = data
        ordered.purchaseOrders = [PurchaseOrder(date: "2026-10-10", lines: [OrderLine(itemID: "g90", qty: 10)])]
        XCTAssertFalse(Onboarding.isEmpty(ordered))
        XCTAssertFalse(Onboarding.isEmpty(DemoData.make(endingAt: "2026-10-10", days: 3)))
        // Yalnızca eski sürümün vardiyalarını taşıyan gün artık veri sayılmaz (maliyet hesabı kaldırıldı)
        let shiftsOnly = try? Persistence.decode(Data(#"""
            {"items":[],"products":[],"days":{"2026-10-10":{"date":"2026-10-10","entries":{},"sales":[],"shifts":{"e1":{"hours":9}},"otherLabor":500}}}
            """#.utf8))
        XCTAssertEqual(shiftsOnly.map { Onboarding.isEmpty($0) }, true)
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
        XCTAssertTrue(full.hasPrefix("✓ Sayım tamam: 21 / 21 kalem sayıldı.\n✓ Satış raporu aktarıldı."))
        XCTAssertTrue(full.contains("kilidi yalnızca patron veya müdür açabilir"))
        XCTAssertFalse(DayLockAction.confirmDetail(counted: 0, total: 0, hasSales: true).contains("Sayım"))
    }
}
