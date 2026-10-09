import Foundation

/// Değişiklik geçmişi özeti: bir belge yazılırken `envanter_put(p_summary)` için kısa Türkçe metin üretir.
/// Web istemcisindeki `src/lib/activity.ts` ile aynı biçim. Örnekler:
///   "09.10.2026 sayımı: 90 Gr kapanış 120 → 110, Peynir gelen 5"
///   "09.10.2026 satış raporu aktarıldı (121 satır, 82.450 ₺)"
///   "Vardiya 09.10.2026: Can Ö. 6 saat"
///   "09.10.2026 günü kapatıldı"
///   "Stok kalemleri: Patates birim maliyet 60 → 68 ₺"
/// Metin en fazla ~140 karakterdir; sığmayan ayrıntılar "+N değişiklik" olarak sayılır.
public enum ChangeSummary {
    public static let maxLength = 140

    struct Segment {
        /// Ayrıntılardan önce gelen başlık ("09.10.2026 sayımı: "); ayrıntı yoksa tek başına cümle
        var head: String
        var details: [String] = []
    }

    static let labels: [String: String] = [
        DocKey.items: "Stok kalemleri", DocKey.products: "Reçeteler", DocKey.employees: "Personel",
        DocKey.orders: "Siparişler", DocKey.settings: "Ayarlar",
    ]

    /// Bir belge değişikliğinin kısa Türkçe özeti. `before`/`after` belge gövdeleridir; `nil` = yok ya da silindi.
    /// `data` verilirse kalem ve personel adları ondan alınır (yoksa kimlik yazılır).
    public static func summarize(key: String, before: JSONValue?, after: JSONValue?, data: AppData? = nil) -> String {
        let b = before?.isNull == true ? nil : before
        let a = after?.isNull == true ? nil : after
        let date = DocKey.date(of: key)
        var segs: [Segment]
        if let date {
            segs = summarizeDay(date, b, a, data)
        } else if a == nil && b != nil {
            segs = [Segment(head: "\(labels[key] ?? key) silindi")]
        } else {
            switch key {
            case DocKey.items: segs = summarizeItems(b, a)
            case DocKey.products: segs = summarizeProducts(b, a, data)
            case DocKey.employees: segs = summarizeEmployees(b, a)
            case DocKey.orders: segs = summarizeOrders(b, a, data)
            case DocKey.settings: segs = summarizeSettings(b, a)
            default: segs = []
            }
        }
        if segs.isEmpty {
            let label = date.map { "\(DateKey.short($0)) günü" } ?? (labels[key] ?? key)
            return clip("\(label) güncellendi", maxLength)
        }
        return compose(segs)
    }

    // MARK: - Metin yardımcıları (JS ile aynı uzunluk: UTF-16 birimi)

    static func len(_ s: String) -> Int { s.utf16.count }

    static func clip(_ s: String, _ n: Int) -> String {
        let t = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard len(t) > n else { return t }
        var head = String(decoding: Array(t.utf16.prefix(max(0, n - 1))), as: UTF16.self)
        while let last = head.last, last.isWhitespace { head.removeLast() }
        return head + "…"
    }

    /// Bölümleri birleştirir; sığmayan ayrıntılar "+N değişiklik" olur.
    static func compose(_ segments: [Segment], max: Int = maxLength) -> String {
        var units: [(seg: Int, text: String)] = []
        for (i, s) in segments.enumerated() {
            if s.details.isEmpty { units.append((i, "")) } else { for d in s.details { units.append((i, d)) } }
        }
        var out = ""
        var lastSeg = -1
        for (i, u) in units.enumerated() {
            var piece = u.seg != lastSeg ? (out.isEmpty ? "" : "; ") + segments[u.seg].head + u.text : ", " + u.text
            let rest = units.count - i - 1
            let suffix = rest > 0 ? " +\(rest) değişiklik" : ""
            if out.isEmpty && len(piece + suffix) > max {
                piece = clip(piece, max - len(suffix))
            } else if !out.isEmpty && len(out + piece + suffix) > max {
                out += " +\(units.count - i) değişiklik"
                return out
            }
            out += piece
            lastSeg = u.seg
        }
        return out
    }

    /// "etiket a → b birim" / "etiket b birim" / "etiket silindi"; değişmediyse nil
    static func pair(_ a: Double?, _ b: Double?, _ fmt: (Double) -> String, _ label: String, _ unit: String = "") -> String? {
        if a == b { return nil }
        let u = unit.isEmpty ? "" : " \(unit)"
        if let a, let b { return "\(label) \(fmt(a)) → \(fmt(b))\(u)" }
        if let b { return "\(label) \(fmt(b))\(u)" }
        return "\(label) silindi"
    }

    /// Para tutarı "₺" olmadan: 60 → "60", 8,25 → "8,25", 85000 → "85.000"
    static func amount(_ v: Double) -> String {
        let s = Fmt.money(v, fraction: v.isFinite && v == v.rounded() ? 0 : 2)
        return s.hasSuffix(" ₺") ? String(s.dropLast(2)) : s
    }

    static func percent(_ v: Double) -> String { "%" + Fmt.number(v * 100, maxFraction: 1) }

    static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    static func itemName(_ data: AppData?, _ id: String) -> String {
        nonEmpty(data?.items.first { $0.id == id }?.name) ?? id
    }

    static func employeeName(_ data: AppData?, _ id: String) -> String {
        nonEmpty(data?.employees.first { $0.id == id }?.name) ?? id
    }

    /// JavaScript `Array.prototype.sort()` sırası (UTF-16 birimleri)
    static func jsLess(_ a: String, _ b: String) -> Bool { a.utf16.lexicographicallyPrecedes(b.utf16) }

    /// Anahtarların birleşimi: önce `order` sırası, sonra kalanlar alfabetik
    static func orderedKeys(_ order: [String], _ recs: [String]?...) -> [String] {
        var all = Set<String>()
        for r in recs { if let r { all.formUnion(r) } }
        var out: [String] = []
        for k in order where all.contains(k) { out.append(k); all.remove(k) }
        return out + all.sorted(by: jsLess)
    }

    static func byKey<T>(_ list: [T], _ key: (T) -> String) -> [String: T] {
        var m: [String: T] = [:]
        for x in list where m[key(x)] == nil { m[key(x)] = x }
        return m
    }

    // MARK: - Gün

    static let entryFields: [(WritableKeyPath<DayEntry, Double?>, String)] = [
        (\.opening, "açılış"), (\.incoming, "gelen"), (\.transferIn, "gelen transfer"),
        (\.transferOut, "giden transfer"), (\.closing, "kapanış"),
    ]

    static func summarizeDay(_ date: String, _ before: JSONValue?, _ after: JSONValue?, _ data: AppData?) -> [Segment] {
        let D = DateKey.short(date)
        let b = before.flatMap { Lenient.day($0, date: date) }
        guard let a = after.flatMap({ Lenient.day($0, date: date) }) else { return [Segment(head: "\(D) günü silindi")] }
        var segs: [Segment] = []

        if a.isLocked && !(b?.isLocked ?? false) { segs.append(Segment(head: "\(D) günü kapatıldı")) }
        if !a.isLocked && (b?.isLocked ?? false) { segs.append(Segment(head: "\(D) günün kilidi açıldı")) }

        let bs = b?.sales ?? []
        if !a.sales.isEmpty && (bs != a.sales || b?.salesImportedAt != a.salesImportedAt) {
            let rev = a.salesRevenue.map { ", \(Fmt.money($0, fraction: 0))" } ?? ""
            segs.append(Segment(head: "\(D) satış raporu aktarıldı (\(a.sales.count) satır\(rev))"))
        } else if a.sales.isEmpty && !bs.isEmpty {
            segs.append(Segment(head: "\(D) satışları silindi"))
        }

        if b?.legacySold != a.legacySold || b?.legacyWaste != a.legacyWaste || b?.importedFrom != a.importedFrom {
            let from = nonEmpty(a.importedFrom).map { " (\(clip($0, 40)))" } ?? ""
            segs.append(Segment(head: "\(D) Excel verisi aktarıldı\(from)"))
        }

        var entryDetails: [String] = []
        for id in orderedKeys(data?.items.map { $0.id } ?? [], b.map { Array($0.entries.keys) }, Array(a.entries.keys)) {
            let be = b?.entries[id] ?? DayEntry(), ae = a.entries[id] ?? DayEntry()
            let frac = data?.items.first { $0.id == id }?.maxFraction ?? 3
            let phrases = entryFields.compactMap { kp, label in
                pair(be[keyPath: kp], ae[keyPath: kp], { Fmt.number($0, maxFraction: frac) }, label)
            }
            if !phrases.isEmpty { entryDetails.append("\(itemName(data, id)) \(phrases.joined(separator: ", "))") }
        }
        if !entryDetails.isEmpty { segs.append(Segment(head: "\(D) sayımı: ", details: entryDetails)) }

        var shiftDetails: [String] = []
        for id in orderedKeys(data?.employees.map { $0.id } ?? [], b?.shifts.map { Array($0.keys) }, a.shifts.map { Array($0.keys) }) {
            let bsft = b?.shifts?[id] ?? ShiftEntry(), asft = a.shifts?[id] ?? ShiftEntry()
            if bsft == asft { continue }
            let name = employeeName(data, id)
            if asft.isEmpty { shiftDetails.append("\(name) vardiyası silindi"); continue }
            var phrases: [String] = []
            if bsft.hours != asft.hours {
                if let h = asft.hours {
                    if let old = bsft.hours {
                        phrases.append("\(Fmt.number(old, maxFraction: 2)) → \(Fmt.number(h, maxFraction: 2)) saat")
                    } else {
                        phrases.append("\(Fmt.number(h, maxFraction: 2)) saat")
                    }
                } else {
                    phrases.append("saat silindi")
                }
            }
            if bsft.worked != asft.worked {
                phrases.append(asft.worked == true ? "çalıştı" : asft.worked == false ? "çalışmadı" : "çalıştı işareti kaldırıldı")
            }
            if let ex = pair(bsft.extra, asft.extra, amount, "ek ödeme", bsft.extra != nil && asft.extra == nil ? "" : "₺") {
                phrases.append(ex)
            }
            if !phrases.isEmpty { shiftDetails.append("\(name) \(phrases.joined(separator: ", "))") }
        }
        if let ol = pair(b?.otherLabor, a.otherLabor, amount, "diğer personel gideri", a.otherLabor == nil ? "" : "₺") {
            shiftDetails.append(ol)
        }
        if !shiftDetails.isEmpty { segs.append(Segment(head: "Vardiya \(D): ", details: shiftDetails)) }

        if (b?.countedBy ?? "") != (a.countedBy ?? "") {
            segs.append(Segment(head: nonEmpty(a.countedBy).map { "\(D) sayımı yapan: \(clip($0, 30))" } ?? "\(D) sayımı yapan silindi"))
        }
        if (b?.note ?? "") != (a.note ?? "") {
            segs.append(Segment(head: nonEmpty(a.note).map { "\(D) notu: \(clip($0, 50))" } ?? "\(D) notu silindi"))
        }
        return segs
    }

    // MARK: - Stok kalemleri

    static func summarizeItems(_ before: JSONValue?, _ after: JSONValue?) -> [Segment] {
        let bl = before.flatMap { Lenient.items($0) } ?? [], al = after.flatMap { Lenient.items($0) } ?? []
        let bm = byKey(bl) { $0.id }, am = byKey(al) { $0.id }
        var details: [String] = []
        for it in al {
            guard let old = bm[it.id] else { details.append("\(nonEmpty(it.name) ?? it.id) eklendi"); continue }
            if old == it { continue }
            var p: [String] = []
            let label = old.name != it.name ? "\(nonEmpty(old.name) ?? it.id) → \(nonEmpty(it.name) ?? it.id)" : (nonEmpty(it.name) ?? it.id)
            if let uc = pair(old.unitCost, it.unitCost, amount, "birim maliyet", it.unitCost == nil ? "" : "₺") {
                p.append(uc.replacingOccurrences(of: "birim maliyet silindi", with: "birim maliyet kaldırıldı"))
            } else if old.costHistory != it.costHistory {
                p.append("fiyat geçmişi güncellendi")
            }
            let frac = it.maxFraction
            if let x = pair(old.minStock, it.minStock, { Fmt.number($0, maxFraction: frac) }, "kritik stok") { p.append(x) }
            if let x = pair(old.tolerance, it.tolerance, { Fmt.number($0, maxFraction: frac) }, "tolerans") { p.append(x) }
            if old.factor != it.factor {
                p.append("çarpan \(Fmt.number(old.factor, maxFraction: 6)) → \(Fmt.number(it.factor, maxFraction: 6))")
            }
            if old.unit != it.unit { p.append("birim \(old.unit) → \(it.unit)") }
            if old.recipeUnit != it.recipeUnit { p.append("reçete birimi \(old.recipeUnit) → \(it.recipeUnit)") }
            if old.active != it.active { p.append(it.active ? "aktif edildi" : "pasife alındı") }
            if p.isEmpty && old.name == it.name { p.append("güncellendi") }
            details.append(p.isEmpty ? label : "\(label) \(p.joined(separator: ", "))")
        }
        for it in bl where am[it.id] == nil { details.append("\(nonEmpty(it.name) ?? it.id) silindi") }
        if details.isEmpty && bl != al { details.append("sıralama değişti") }
        return details.isEmpty ? [] : [Segment(head: "Stok kalemleri: ", details: details)]
    }

    // MARK: - Reçeteler

    static func summarizeProducts(_ before: JSONValue?, _ after: JSONValue?, _ data: AppData?) -> [Segment] {
        let bl = before.flatMap { Lenient.products($0) } ?? [], al = after.flatMap { Lenient.products($0) } ?? []
        let bm = byKey(bl) { $0.code }, am = byKey(al) { $0.code }
        var details: [String] = []
        let itemOrder = data?.items.map { $0.id } ?? []
        for pr in al {
            let name = nonEmpty(pr.name) ?? pr.code
            guard let old = bm[pr.code] else { details.append("\(name) eklendi"); continue }
            if old == pr { continue }
            var p: [String] = []
            if old.name != pr.name { p.append("ad \(old.name) → \(pr.name)") }
            if old.category != pr.category { p.append("kategori \(pr.category)") }
            for id in orderedKeys(itemOrder, Array(old.amounts.keys), Array(pr.amounts.keys)) {
                let x = old.amounts[id], y = pr.amounts[id]
                if x == y { continue }
                let iname = itemName(data, id)
                if y == nil || y == 0 {
                    p.append("\(iname) çıkarıldı")
                } else if x == nil || x == 0 {
                    p.append("\(iname) \(Fmt.number(y!, maxFraction: 4))")
                } else {
                    p.append("\(iname) \(Fmt.number(x!, maxFraction: 4)) → \(Fmt.number(y!, maxFraction: 4))")
                }
            }
            if (old.note ?? "") != (pr.note ?? "") { p.append("not güncellendi") }
            details.append("\(name): \(p.isEmpty ? "güncellendi" : p.joined(separator: ", "))")
        }
        for pr in bl where am[pr.code] == nil { details.append("\(nonEmpty(pr.name) ?? pr.code) silindi") }
        if details.isEmpty && bl != al { details.append("sıralama değişti") }
        return details.isEmpty ? [] : [Segment(head: "Reçeteler: ", details: details)]
    }

    // MARK: - Personel

    static func summarizeEmployees(_ before: JSONValue?, _ after: JSONValue?) -> [Segment] {
        let bl = before.flatMap { Lenient.employees($0) } ?? [], al = after.flatMap { Lenient.employees($0) } ?? []
        let bm = byKey(bl) { $0.id }, am = byKey(al) { $0.id }
        var details: [String] = []
        for e in al {
            let name = nonEmpty(e.name) ?? e.id
            guard let old = bm[e.id] else { details.append("\(name) eklendi"); continue }
            if old == e { continue }
            let label = old.name != e.name ? "\(nonEmpty(old.name) ?? e.id) → \(name)" : name
            details.append("\(label) \(employeePhrases(old, e).joined(separator: ", "))".trimmingCharacters(in: .whitespaces))
        }
        for e in bl where am[e.id] == nil { details.append("\(nonEmpty(e.name) ?? e.id) silindi") }
        if details.isEmpty && bl != al { details.append("sıralama değişti") }
        return details.isEmpty ? [] : [Segment(head: "Personel: ", details: details)]
    }

    static func employeePhrases(_ old: Employee, _ e: Employee) -> [String] {
        var p: [String] = []
        let historyChanged = old.payHistory != e.payHistory
        let since = (nonEmpty(e.payHistory?.last?.from)).flatMap { historyChanged ? " (\(DateKey.short($0)) itibarıyla)" : nil } ?? ""
        if old.payType != e.payType { p.append("\(old.payType.title) → \(e.payType.title)") }
        if old.rate != e.rate { p.append("ücret \(amount(old.rate)) → \(amount(e.rate)) ₺") }
        if old.costFactor != e.costFactor {
            p.append("maliyet çarpanı \(Fmt.number(old.costFactor, maxFraction: 3)) → \(Fmt.number(e.costFactor, maxFraction: 3))")
        }
        if !p.isEmpty {
            p[p.count - 1] += since
        } else if historyChanged {
            p.append("ücret geçmişi güncellendi")
        }
        if old.role != e.role { p.append(nonEmpty(e.role).map { "görev \($0)" } ?? "görev silindi") }
        if old.startDate != e.startDate { p.append(nonEmpty(e.startDate).map { "giriş \(DateKey.short($0))" } ?? "giriş tarihi kaldırıldı") }
        if old.endDate != e.endDate { p.append(nonEmpty(e.endDate).map { "ayrıldı (\(DateKey.short($0)))" } ?? "çıkış tarihi kaldırıldı") }
        if old.active != e.active && !(nonEmpty(e.endDate) != nil && old.endDate != e.endDate) {
            p.append(e.active ? "aktif edildi" : "pasife alındı")
        }
        if let dh = pair(old.defaultHours, e.defaultHours, { Fmt.number($0, maxFraction: 2) }, "varsayılan vardiya",
                         e.defaultHours == nil ? "" : "saat") {
            p.append(dh)
        }
        if p.isEmpty { p.append("güncellendi") }
        return p
    }

    // MARK: - Siparişler

    static func orderLabel(_ o: PurchaseOrder) -> String {
        nonEmpty(o.supplier.trimmingCharacters(in: .whitespacesAndNewlines)) ?? "\(DateKey.short(o.date)) siparişi"
    }

    static func summarizeOrders(_ before: JSONValue?, _ after: JSONValue?, _ data: AppData?) -> [Segment] {
        let bl = before.flatMap { Lenient.orders($0) } ?? [], al = after.flatMap { Lenient.orders($0) } ?? []
        let bm = byKey(bl) { $0.id }, am = byKey(al) { $0.id }
        var segs: [Segment] = []
        for o in al {
            guard let old = bm[o.id] else {
                segs.append(Segment(head: "Sipariş oluşturuldu (\(orderLabel(o)), \(o.lines.count) kalem)"))
                continue
            }
            if old == o { continue }
            if old.status != o.status && o.status == .received {
                let n = o.lines.filter { ($0.received ?? 0) > 0 }.count
                let extra = n > 0 && n != o.lines.count ? ", \(n)/\(o.lines.count) kalem" : ""
                segs.append(Segment(head: "Sipariş teslim alındı (\(orderLabel(o))\(extra))"))
            } else if old.status != o.status && o.status == .cancelled {
                segs.append(Segment(head: "Sipariş iptal edildi (\(orderLabel(o)))"))
            } else if old.status != o.status && o.status == .open {
                segs.append(Segment(head: "Sipariş yeniden açıldı (\(orderLabel(o)))"))
            } else {
                var lines: [String] = []
                let oldLines = byKey(old.lines) { $0.itemID }
                for l in o.lines {
                    if let x = oldLines[l.itemID] {
                        if x.qty != l.qty {
                            lines.append("\(itemName(data, l.itemID)) \(Fmt.number(x.qty, maxFraction: 3)) → \(Fmt.number(l.qty, maxFraction: 3))")
                        }
                    } else {
                        lines.append("\(itemName(data, l.itemID)) \(Fmt.number(l.qty, maxFraction: 3)) eklendi")
                    }
                }
                let newLines = byKey(o.lines) { $0.itemID }
                for l in old.lines where newLines[l.itemID] == nil { lines.append("\(itemName(data, l.itemID)) çıkarıldı") }
                segs.append(Segment(head: "Sipariş güncellendi (\(orderLabel(o)))\(lines.isEmpty ? "" : ": ")", details: lines))
            }
        }
        for o in bl where am[o.id] == nil { segs.append(Segment(head: "Sipariş silindi (\(orderLabel(o)))")) }
        return segs
    }

    // MARK: - Ayarlar

    static func summarizeSettings(_ before: JSONValue?, _ after: JSONValue?) -> [Segment] {
        let b = before.flatMap { Lenient.settings($0) } ?? AppSettings()
        let a = after.flatMap { Lenient.settings($0) } ?? AppSettings()
        var d: [String] = []
        if b.branchName != a.branchName {
            d.append(nonEmpty(a.branchName).map { "şube adı \"\(clip($0, 40))\"" } ?? "şube adı silindi")
        }
        func pct(_ old: Double?, _ now: Double?, _ label: String) {
            if old == now { return }
            d.append(now.map { "\(label) \(percent($0))" } ?? "\(label) kaldırıldı")
        }
        pct(b.targetFoodCostPct, a.targetFoodCostPct, "hammadde hedefi")
        pct(b.targetLaborPct, a.targetLaborPct, "personel hedefi")
        pct(b.targetPrimeCostPct, a.targetPrimeCostPct, "prime cost hedefi")
        pct(b.priceAlertPct, a.priceAlertPct, "fiyat uyarı eşiği")
        if b.orderLookbackDays != a.orderLookbackDays { d.append("ortalama tüketim \(a.orderLookbackDays) gün") }
        if b.orderCoverDays != a.orderCoverDays { d.append("sipariş kapsamı \(Fmt.number(a.orderCoverDays, maxFraction: 1)) gün") }
        for s in a.staff where !b.staff.contains(s) { d.append("sayım ekibine \(s) eklendi") }
        for s in b.staff where !a.staff.contains(s) { d.append("sayım ekibinden \(s) çıkarıldı") }
        if d.isEmpty && before != after { d.append("güncellendi") }
        return d.isEmpty ? [] : [Segment(head: "Ayarlar: ", details: d)]
    }
}
