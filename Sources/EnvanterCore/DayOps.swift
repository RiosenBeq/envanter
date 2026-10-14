import Foundation

/// "Hareketsizleri Doldur" yapılamama nedeni (web `FillRefusal`)
public enum FillRefusal: String, Sendable {
    /// Gün kapatılmış
    case locked
    /// Günün satış verisi yok: hangi kalemin hareketsiz olduğu bilinemez
    case noSales
}

/// Gün işlemlerinin saf (Linux'ta test edilebilen) kuralları; AppStore ve web aynı kuralı kullanır.
public enum DayOps {
    /// Sayılmamış ve hiç hareketi olmayan (gelen, transfer, satış, zayi) kalemlere kapanış = açılış yazar.
    /// Yalnızca açılışı önceki sayımdan (`closing`) ya da elle (`manual`) gelen satırlar doldurulur: tahmini (devreden)
    /// açılış sayım yerine geçmez. Gün kapatılmışsa ya da satış verisi yoksa yapılmaz. Dönen gün yalnızca count > 0
    /// iken değişmiştir.
    public static func fillUncountedWithOpening(engine: Engine, date: String) -> (day: DayRecord?, count: Int, refusal: FillRefusal?) {
        let current = engine.data.days[date]
        if current?.isLocked == true { return (current, 0, .locked) }
        guard current?.hasSalesData == true else { return (current, 0, .noSales) }
        let rows = engine.calc(date: date).rows.filter { isIdle($0) }
        guard !rows.isEmpty else { return (current, 0, nil) }
        var day = current ?? DayRecord(date: date)
        for r in rows { day.entries[r.itemID, default: DayEntry()].closing = r.opening }
        return (day, rows.count, nil)
    }

    /// Doldurulabilir satır: sayılmamış, hareketsiz, açılışı > 0 ve sayımdan ya da elle gelmiş. Sayımdan gelen açılışta
    /// aradaki sayılmayan günlerde hiç hareket olmamalı (`carriedMoveDays == 0`): birbirini götüren hareketler (net 0;
    /// ör. Gelen 3, Satılan 3) de sayılmadığından açılış bir tahmindir, sayım yerine geçmez.
    public static func isIdle(_ r: ItemCalc) -> Bool {
        !r.isCounted && r.incoming == 0 && r.transferIn == 0 && r.transferOut == 0 && r.sold == 0 && r.waste == 0
            && r.opening > 0 && (r.openingSource == .manual || (r.openingSource == .closing && r.carriedMoveDays == 0))
    }
}
