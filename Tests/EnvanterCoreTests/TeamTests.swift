import XCTest
@testable import EnvanterCore

/// Ekip: üye kaydının hoşgörülü okunması, eski sayan adlarının (settings.staff) ekibe taşınması ve Sayan seçimi.
final class TeamTests: XCTestCase {
    private func data(staff: [String], employees: [Employee] = []) -> AppData {
        var d = AppData(items: [], products: [])
        d.settings.staff = staff
        d.employees = employees
        return d
    }

    // MARK: - Üye kaydı

    func testEmployeeDecodesOldPayFieldsTolerantly() throws {
        // Eski sürümün personel kaydı: ücret alanları yok sayılır, eksik alanlar varsayılanı alır
        let old = #"""
        [{"id":"e1","name":"Murat A.","role":"Şube Müdürü","payType":"monthly","rate":85000,"costFactor":1.2,"active":false,
          "startDate":"2026-01-01","endDate":"2026-08-31","defaultHours":9,
          "payHistory":[{"from":null,"payType":"monthly","rate":80000,"costFactor":1.2}]},
         {"id":"e2"}]
        """#
        let list = try JSONDecoder().decode([Employee].self, from: Data(old.utf8))
        XCTAssertEqual(list[0], Employee(id: "e1", name: "Murat A.", role: "Şube Müdürü", active: false,
                                         startDate: "2026-01-01", endDate: "2026-08-31"))
        XCTAssertEqual(list[1], Employee(id: "e2", name: "", role: "", active: true))
        XCTAssertThrowsError(try JSONDecoder().decode(Employee.self, from: Data(#"{"name":"kimliksiz"}"#.utf8)))

        // Yeni alanlar yazılıp okunur; boş isteğe bağlı alanlar yazılmaz
        let e = Employee(id: "a", name: "Ayşe", role: "Kasiyer", phone: "0500 000 00 00", note: "not", account: "ayse@envanter.local")
        let json = String(decoding: try JSONCoding.encoder().encode(e), as: UTF8.self)
        XCTAssertEqual(json, #"{"account":"ayse@envanter.local","active":true,"id":"a","name":"Ayşe","note":"not","phone":"0500 000 00 00","role":"Kasiyer"}"#)
        XCTAssertEqual(try JSONCoding.decoder().decode(Employee.self, from: Data(json.utf8)), e)
        XCTAssertTrue(Employee(name: "Yeni", startDate: "2026-08-10").isEmployed(on: "2026-08-10"))
        XCTAssertFalse(Employee(name: "Yeni", startDate: "2026-08-10").isEmployed(on: "2026-08-09"))
    }

    // MARK: - Eski sayan adlarının taşınması

    /// Ortak vektörler (account-vectors.json "teamID"): her ad kendi kimliğiyle taşınır, slug'ı boş ad atlanır
    func testMigrationUsesSharedVectors() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/account-vectors", withExtension: "json"))
        let rows = try XCTUnwrap(try JSONCoding.parse(Data(contentsOf: url))["teamID"]?.arrayValue)
        var d = data(staff: try rows.map { try XCTUnwrap($0["name"]?.stringValue) })
        XCTAssertTrue(Team.migrateLegacyStaff(&d))
        let expected = rows.compactMap { r -> Employee? in
            guard let id = r["id"]?.stringValue, let name = r["name"]?.stringValue else { return nil }
            return Employee(id: id, name: name.trimmingCharacters(in: .whitespaces))
        }
        XCTAssertEqual(d.employees, expected)
        XCTAssertEqual(d.employees.count, 7, "\"---\" taşınmaz")
        XCTAssertEqual(d.employees.first { $0.id == "staff-ismail" }?.name, "İSMAİL", "ad kırpılır, yazımı korunur")
        XCTAssertTrue(d.settings.staff.isEmpty)
    }

    func testMigrationSkipsExistingMembersAndIsIdempotent() {
        let existing = [Employee(id: "e1", name: "Ayşe Yılmaz", role: "Kasiyer"),
                        Employee(id: "e2", name: "Mehmet", active: false),
                        Employee(id: "staff-veli", name: "Veli Can")]   // önceki taşıma; adı sonradan değişti
        var d = data(staff: ["  ayse yilmaz ", "MEHMET", "Veli", "Ali", "ALİ", "Alı", "", "Zeynep"], employees: existing)
        XCTAssertTrue(Team.migrateLegacyStaff(&d))
        // Ayşe ve (pasif) Mehmet zaten üye; Veli'nin kimliği alınmış; ALİ / Alı, Ali ile aynı slug
        XCTAssertEqual(d.employees, existing + [Employee(id: "staff-ali", name: "Ali"), Employee(id: "staff-zeynep", name: "Zeynep")])
        XCTAssertEqual(d.employees.last?.role, "")
        XCTAssertTrue(d.employees.last?.active == true)
        XCTAssertTrue(d.settings.staff.isEmpty)

        // İkinci kez: değişiklik yok
        let once = d
        XCTAssertFalse(Team.migrateLegacyStaff(&d))
        XCTAssertEqual(d.employees, once.employees)
        XCTAssertNil(Team.migratingLegacyStaff(d))

        // Yalnızca zaten üye olan adlar: liste yine boşaltılır (değişiklik var)
        var only = data(staff: ["Ayşe Yılmaz"], employees: existing)
        XCTAssertEqual(Team.migratingLegacyStaff(only)?.employees, existing)
        XCTAssertTrue(Team.migrateLegacyStaff(&only))
        XCTAssertTrue(only.settings.staff.isEmpty)
    }

    /// Mac ve web aynı listeyi ayrı ayrı taşısa da belgeler kimliğe göre çakışmasız birleşir
    func testConcurrentMigrationsMergeByID() throws {
        let base = data(staff: ["Ali", "Veli"], employees: [Employee(id: "e1", name: "Murat")])
        var mac = base, web = base
        Team.migrateLegacyStaff(&mac)
        Team.migrateLegacyStaff(&web)
        web.employees[0].role = "Müdür"                         // web'de ayrıca bir düzenleme
        let merged = JSONMerge.merge3(base: try JSONCoding.value(base.employees), local: try JSONCoding.value(mac.employees),
                                      remote: try JSONCoding.value(web.employees))
        XCTAssertEqual(merged, try JSONCoding.value(web.employees))
        XCTAssertEqual(JSONMerge.merge3(base: try JSONCoding.value(base.settings), local: try JSONCoding.value(mac.settings),
                                        remote: try JSONCoding.value(web.settings)), try JSONCoding.value(web.settings))
    }

    // MARK: - Sayan seçimi

    func testCounterNamesOrder() {
        let d = data(staff: ["Zeynep", "ayse yilmaz", "Mehmet", "Okan", "zeynep", "  ", "Can"],
                     employees: [Employee(id: "1", name: "Can"), Employee(id: "2", name: "Ayşe Yılmaz"),
                                 Employee(id: "3", name: "Mehmet", active: false), Employee(id: "4", name: "Ayse Yilmaz"),
                                 Employee(id: "5", name: " ")])
        // Aktif üyeler liste sırasıyla (aynı ada çıkan bir kez), sonra hiçbir üyeyle (pasif dahil) eşleşmeyen eski adlar
        XCTAssertEqual(Team.counterNames(d), ["Can", "Ayşe Yılmaz", "Zeynep", "Okan"])
        XCTAssertEqual(Team.counterNames(data(staff: [])), [])
    }

    func testRememberingCounterAddsTeamMemberNotSettings() {
        let d = data(staff: [], employees: [Employee(id: "staff-ali", name: "Ali Can")])
        // Yeni ad ekibe eklenir; kimlik alınmışsa numaralanır
        let added = Team.rememberingCounter("  Ali ", in: d, role: CloudRole.manager)
        XCTAssertEqual(added, d.employees + [Employee(id: "staff-ali-2", name: "Ali")])
        XCTAssertEqual(Team.rememberingCounter("Ayşe", in: d, role: nil)?.last, Employee(id: "staff-ayse", name: "Ayşe"))
        // Zaten üye, boş ad ya da personel hesabı: değişiklik yok
        XCTAssertNil(Team.rememberingCounter("ALİ CAN", in: d, role: CloudRole.owner))
        XCTAssertNil(Team.rememberingCounter("   ", in: d, role: CloudRole.owner))
        XCTAssertNil(Team.rememberingCounter("Ayşe", in: d, role: CloudRole.staff))
    }
}
