import Foundation

/// Satın alma siparişi akışı: öneriden (ya da elle) sipariş oluştur → düzenle → teslim al (Gelen'e işlenir) ya da Gelen
/// elle girildiyse "Teslim alındı say". Web: src/lib/engine/purchasing.ts (aynı adlar, ortak vektörler:
/// Tests/EnvanterCoreTests/Fixtures/purchasing-vectors.json).
public enum Purchasing {
    /// Bu kadar günden eski açık sipariş uyarı alır (öneriden düşülmeye devam ettiği için)
    public static let staleDays = 3
    /// Tedarikçi notunun azami uzunluğu (giriş alanı sınırı)
    public static let noteLimit = 300

    public enum Failure: Error, LocalizedError, Equatable {
        case notFound, notOpen, locked(String), nothingReceived, emptyOrder, alreadyReceiving
        public var errorDescription: String? {
            switch self {
            case .notFound: return "Sipariş bulunamadı."
            case .notOpen: return "Bu sipariş zaten teslim alınmış ya da iptal edilmiş."
            case .locked(let d): return "\(DateKey.short(d)) günü kapatılmış; teslimatı işlemek için önce günün kilidini açın."
            case .nothingReceived: return "Teslim alınan miktar girilmedi."
            case .emptyOrder: return "Siparişte kalem yok."
            case .alreadyReceiving: return "Teslimatı başlamış siparişin kalemleri değiştirilemez."
            }
        }

        /// Vektörlerdeki ad (web: PurchasingError.code)
        public var code: String {
            switch self {
            case .notFound: return "notFound"
            case .notOpen: return "notOpen"
            case .locked: return "locked"
            case .nothingReceived: return "nothingReceived"
            case .emptyOrder: return "emptyOrder"
            case .alreadyReceiving: return "alreadyReceiving"
            }
        }
    }

    /// Önerilen miktarı olan kalemlerden sipariş oluşturur (önerisi olmayan kalem yoksa nil).
    public static func makeOrder(from suggestions: [OrderSuggestion], date: String, supplier: String = "") -> PurchaseOrder? {
        let lines = suggestions.filter { $0.suggested > 0 }.map { OrderLine(itemID: $0.item.id, qty: $0.suggested) }
        return lines.isEmpty ? nil : PurchaseOrder(date: date, supplier: supplier, lines: lines)
    }

    // MARK: - Taslak ve düzenleme

    /// Sipariş formunun satırları: miktarı 0, negatif ya da geçersiz olan atılır; aynı kalem tek satırda toplanır;
    /// kullanıcının sırası korunur.
    public static func draftLines(_ lines: [OrderLine]) -> [OrderLine] {
        var order: [String] = []
        var qty: [String: Double] = [:]
        for l in lines where l.qty.isFinite && l.qty > 0 {
            if qty[l.itemID] == nil { order.append(l.itemID) }
            qty[l.itemID] = Engine.clean((qty[l.itemID] ?? 0) + l.qty)
        }
        return order.map { OrderLine(itemID: $0, qty: qty[$0] ?? 0) }
    }

    /// Boş not yazılmaz
    static func cleanNote(_ note: String?) -> String? {
        let t = (note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Formdan yeni sipariş (miktarlar elle; öneri yalnızca başlangıç değeri). Kalem yoksa `emptyOrder`.
    public static func orderFromDraft(date: String, supplier: String, note: String?, lines: [OrderLine],
                                      id: String = UUID().uuidString) throws -> PurchaseOrder {
        let draft = draftLines(lines)
        guard !draft.isEmpty else { throw Failure.emptyOrder }
        return PurchaseOrder(id: id, date: date, supplier: supplier.trimmingCharacters(in: .whitespacesAndNewlines),
                             lines: draft, note: cleanNote(note))
    }

    /// Açık siparişi düzenler: tedarikçi, not, miktarlar, kalem ekle/çıkar. Teslim alınmış ya da iptal edilmiş sipariş
    /// değişmez (`notOpen`); teslim alınan miktarı olan satır varsa kalemler değişmez (`alreadyReceiving`). Kalan
    /// satırların diğer alanları korunur.
    public static func updateOrder(orderID: String, supplier: String, note: String?, lines: [OrderLine],
                                   data: inout AppData) throws {
        guard let oi = data.purchaseOrders.firstIndex(where: { $0.id == orderID }) else { throw Failure.notFound }
        var order = data.purchaseOrders[oi]
        guard order.status == .open else { throw Failure.notOpen }
        let draft = draftLines(lines)
        guard !draft.isEmpty else { throw Failure.emptyOrder }
        let old = order.lines
        let linesChanged = draft.count != old.count || zip(draft, old).contains { $0.itemID != $1.itemID || $0.qty != $1.qty }
        if linesChanged && old.contains(where: { ($0.received ?? 0) > 0 }) { throw Failure.alreadyReceiving }
        order.supplier = supplier.trimmingCharacters(in: .whitespacesAndNewlines)
        order.note = cleanNote(note)
        if linesChanged {
            order.lines = draft.map { d in
                guard var kept = old.first(where: { $0.itemID == d.itemID }) else { return d }
                kept.qty = d.qty
                return kept
            }
        }
        data.purchaseOrders[oi] = order
    }

    // MARK: - Teslim alma

    /// Siparişi `date` gününe teslim alır. `quantities` verilmeyen kalemlerde sipariş miktarı esas alınır;
    /// 0 girilen kalem teslim alınmamış sayılır.
    /// `addToIncoming == false` ("Teslim alındı say"): Gelen o güne elle girilmişti; miktarlar yalnızca siparişe yazılır,
    /// gün kaydına dokunulmaz (kapatılmış gün de seçilebilir) ve sipariş `receivedWithoutIncoming` ile işaretlenir.
    /// - Returns: teslim alınan (miktarı 0'dan büyük) kalem sayısı
    @discardableResult
    public static func receive(orderID: String, on date: String, quantities: [String: Double] = [:],
                               addToIncoming: Bool = true, data: inout AppData) throws -> Int {
        guard let oi = data.purchaseOrders.firstIndex(where: { $0.id == orderID }) else { throw Failure.notFound }
        guard data.purchaseOrders[oi].status == .open else { throw Failure.notOpen }
        if addToIncoming { guard !(data.days[date]?.isLocked ?? false) else { throw Failure.locked(date) } }
        var order = data.purchaseOrders[oi]
        var day = data.days[date] ?? DayRecord(date: date)
        var received = 0
        for li in order.lines.indices {
            let id = order.lines[li].itemID
            let q = max(quantities[id] ?? order.lines[li].qty, 0)
            order.lines[li].received = q
            if q > 0 {
                if addToIncoming {
                    var e = day.entries[id] ?? DayEntry()
                    e.incoming = Engine.clean((e.incoming ?? 0) + q)
                    day.entries[id] = e
                }
                received += 1
            }
        }
        guard received > 0 else { throw Failure.nothingReceived }
        order.status = .received
        order.receivedOn = date
        if !addToIncoming { order.receivedWithoutIncoming = true }
        data.purchaseOrders[oi] = order
        if addToIncoming { data.days[date] = day }
        return received
    }

    public static func cancel(orderID: String, data: inout AppData) {
        guard let i = data.purchaseOrders.firstIndex(where: { $0.id == orderID }), data.purchaseOrders[i].status == .open else { return }
        data.purchaseOrders[i].status = .cancelled
    }

    /// İptal edilmiş siparişi yeniden açar (başka durumda bir şey yapmaz)
    public static func reopen(orderID: String, data: inout AppData) {
        guard let i = data.purchaseOrders.firstIndex(where: { $0.id == orderID }), data.purchaseOrders[i].status == .cancelled else { return }
        data.purchaseOrders[i].status = .open
    }

    // MARK: - Elle girilmiş Gelen ("Bu teslimat bu siparişten mi?")

    public struct HintLine: Equatable, Sendable {
        public var itemID: String
        /// O gün elle girilmiş (başka siparişin teslimatına ait olmayan) Gelen
        public var incoming: Double
    }

    public struct IncomingHint: Equatable, Sendable {
        /// Gelen'in girildiği gün
        public var date: String
        /// Siparişteki kalemlerden o gün Gelen'i olanlar (sipariş sırasıyla)
        public var lines: [HintLine]
    }

    /// Açık siparişin kalemlerine sipariş gününden sonra (`asOf`'a kadar) elle Gelen girilmiş mi: önce sipariş gününden
    /// sonraki ilk gün, yoksa sipariş günü. O gün teslim alınmış diğer siparişlerin miktarları Gelen'den düşülür
    /// (onların teslimatı elle girilmiş sayılmaz).
    public static func incomingHint(order: PurchaseOrder, data: AppData, asOf: String) -> IncomingHint? {
        guard order.status == .open, DateKey.isValid(order.date) else { return nil }
        var ids: [String] = []
        for l in order.lines where !ids.contains(l.itemID) { ids.append(l.itemID) }
        func matches(_ d: String) -> [HintLine] {
            guard let day = data.days[d] else { return [] }
            return ids.compactMap { id in
                guard let inc = day.entries[id]?.incoming, inc > 0 else { return nil }
                var claimed = 0.0
                for o in data.purchaseOrders where o.id != order.id && o.status == .received && o.receivedOn == d {
                    for l in o.lines where l.itemID == id { claimed += l.received ?? 0 }
                }
                let manual = Engine.clean(inc - claimed)
                return manual > 0 ? HintLine(itemID: id, incoming: manual) : nil
            }
        }
        for d in data.days.keys.filter({ $0 > order.date && $0 <= asOf }).sorted() {
            let m = matches(d)
            if !m.isEmpty { return IncomingHint(date: d, lines: m) }
        }
        if order.date <= asOf {
            let m = matches(order.date)
            if !m.isEmpty { return IncomingHint(date: order.date, lines: m) }
        }
        return nil
    }

    // MARK: - Bekleyen sipariş

    /// Siparişin verildiği günden `asOf`'a geçen gün (sipariş günü geçersizse nil; ileri tarihliyse negatif)
    public static func age(_ order: PurchaseOrder, asOf: String) -> Int? {
        DateKey.distance(from: order.date, to: asOf)
    }

    /// Açık ve `staleDays` günden eski
    public static func isStale(_ order: PurchaseOrder, asOf: String) -> Bool {
        order.status == .open && (age(order, asOf: asOf) ?? 0) > staleDays
    }

    /// Açık siparişin bekleme süresi: "1 gündür bekliyor", "5 gündür bekliyor". Aynı gün, ileri tarihli ya da açık
    /// olmayan siparişte nil.
    public static func waitingText(_ order: PurchaseOrder, asOf: String) -> String? {
        guard order.status == .open, let a = age(order, asOf: asOf), a > 0 else { return nil }
        return "\(a) gündür bekliyor"
    }

    /// Eski açık siparişler (en eskisi önce; aynı günde liste sırası)
    public static func staleOrders(_ orders: [PurchaseOrder], asOf: String) -> [PurchaseOrder] {
        orders.enumerated().filter { isStale($0.element, asOf: asOf) }
            .sorted { $0.element.date != $1.element.date ? $0.element.date < $1.element.date : $0.offset < $1.offset }
            .map { $0.element }
    }

    /// Genel Bakış ve Sipariş ekranındaki uyarı (eski sipariş yoksa nil)
    public static func staleNotice(_ stale: [PurchaseOrder]) -> String? {
        guard !stale.isEmpty else { return nil }
        return "\(stale.count) sipariş \(staleDays) günden uzun süredir bekliyor. Mal geldiyse teslim alın, gelmeyecekse "
            + "iptal edin: açık sipariş öneriden düşülmeye devam eder."
    }

    // MARK: - Metin

    /// Tedarikçiye gönderilecek sipariş metni (silinmiş kalemler yazılmaz, sayısı belirtilir; not en sonda)
    public static func text(_ order: PurchaseOrder, items: [String: Item], branch: String) -> String {
        var head = "Sipariş – \(DateKey.short(order.date))"
        if !order.supplier.isEmpty { head += " · \(order.supplier)" }
        let b = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        if !b.isEmpty { head = "\(b) · " + head }
        var missing = 0
        let lines = order.lines.compactMap { l -> String? in
            guard let item = items[l.itemID] else { missing += 1; return nil }
            return "• \(item.name): \(Fmt.number(l.qty, maxFraction: item.isKg ? 1 : 0)) \(item.unit.lowercased())"
        }
        var out = ([head] + lines).joined(separator: "\n")
        if missing > 0 { out += "\n(\(missing) kalem listede yok)" }
        if let n = cleanNote(order.note) { out += "\nNot: \(n)" }
        return out
    }
}
