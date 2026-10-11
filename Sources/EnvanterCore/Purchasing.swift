import Foundation

/// Satın alma siparişi akışı: öneriden sipariş oluştur → teslim al (Gelen'e işlenir).
public enum Purchasing {
    public enum Failure: Error, LocalizedError, Equatable {
        case notFound, notOpen, locked(String), nothingReceived
        public var errorDescription: String? {
            switch self {
            case .notFound: return "Sipariş bulunamadı."
            case .notOpen: return "Bu sipariş zaten teslim alınmış ya da iptal edilmiş."
            case .locked(let d): return "\(DateKey.short(d)) günü kapatılmış; teslimatı işlemek için önce günün kilidini açın."
            case .nothingReceived: return "Teslim alınan miktar girilmedi."
            }
        }
    }

    /// Önerilen miktarı olan kalemlerden sipariş oluşturur (önerisi olmayan kalem yoksa nil).
    public static func makeOrder(from suggestions: [OrderSuggestion], date: String, supplier: String = "") -> PurchaseOrder? {
        let lines = suggestions.filter { $0.suggested > 0 }.map { OrderLine(itemID: $0.item.id, qty: $0.suggested) }
        return lines.isEmpty ? nil : PurchaseOrder(date: date, supplier: supplier, lines: lines)
    }

    /// Siparişi `date` gününe teslim alır. `quantities` verilmeyen kalemlerde sipariş miktarı esas alınır;
    /// 0 girilen kalem teslim alınmamış sayılır.
    /// - Returns: teslim alınan (miktarı 0'dan büyük) kalem sayısı
    @discardableResult
    public static func receive(orderID: String, on date: String, quantities: [String: Double] = [:],
                               data: inout AppData) throws -> Int {
        guard let oi = data.purchaseOrders.firstIndex(where: { $0.id == orderID }) else { throw Failure.notFound }
        guard data.purchaseOrders[oi].status == .open else { throw Failure.notOpen }
        guard !(data.days[date]?.isLocked ?? false) else { throw Failure.locked(date) }
        var order = data.purchaseOrders[oi]
        var day = data.days[date] ?? DayRecord(date: date)
        var received = 0
        for li in order.lines.indices {
            let id = order.lines[li].itemID
            let q = max(quantities[id] ?? order.lines[li].qty, 0)
            order.lines[li].received = q
            if q > 0 {
                var e = day.entries[id] ?? DayEntry()
                e.incoming = Engine.clean((e.incoming ?? 0) + q)
                day.entries[id] = e
                received += 1
            }
        }
        guard received > 0 else { throw Failure.nothingReceived }
        order.status = .received
        order.receivedOn = date
        data.purchaseOrders[oi] = order
        data.days[date] = day
        return received
    }

    public static func cancel(orderID: String, data: inout AppData) {
        guard let i = data.purchaseOrders.firstIndex(where: { $0.id == orderID }), data.purchaseOrders[i].status == .open else { return }
        data.purchaseOrders[i].status = .cancelled
    }

    /// Tedarikçiye gönderilecek sipariş metni
    public static func text(_ order: PurchaseOrder, items: [String: Item], branch: String) -> String {
        var head = "Sipariş – \(DateKey.short(order.date))"
        if !order.supplier.isEmpty { head += " · \(order.supplier)" }
        let b = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        if !b.isEmpty { head = "\(b) · " + head }
        let lines = order.lines.compactMap { l -> String? in
            guard let item = items[l.itemID] else { return nil }
            return "• \(item.name): \(Fmt.number(l.qty, maxFraction: item.isKg ? 1 : 0)) \(item.unit.lowercased())"
        }
        return ([head] + lines).joined(separator: "\n")
    }
}
