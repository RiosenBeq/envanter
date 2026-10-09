import Foundation

/// Eğitim, tanıtım ve ekran görüntüleri için gerçekçi örnek veri üretir.
/// Gerçek veriye asla yazılmaz: `EnvanterTool demo --data-dir KLASÖR` ile ayrı bir klasöre kurulur.
public enum DemoData {
    /// Tekrarlanabilir rastgele sayı üreteci (SplitMix64)
    struct RNG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        /// [0, 1)
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
        mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * unit() }
        /// Yaklaşık normal dağılım (12 tekdüze toplamı)
        mutating func normal(_ sd: Double) -> Double { ((0..<12).reduce(0) { s, _ in s + unit() } - 6) * sd }
    }

    /// 2026 fiyatlarıyla yaklaşık birim maliyetler (₺ / envanter birimi)
    static let costs: [String: Double] = [
        "g90": 38, "g120": 50, "g130": 62, "g220": 95, "tavuk160": 42, "lezita90": 24, "smash70": 30,
        "peynir": 420, "patates": 68, "ekmekSusamli": 9, "ekmekSusamsiz": 8.5, "donukEkmek": 7, "g60": 26,
        "fume": 950, "soganHalkasi": 280, "citirPeynir": 540, "fillet": 340, "tender": 360, "kanat": 240,
        "hotShots": 310, "jrTavuk": 290,
    ]
    /// Kalıcı fire eğilimi olan kalemler (fiili tüketim reçeteden bu oranda fazla)
    static let shrink: [String: Double] = ["peynir": 0.05, "patates": 0.035, "fume": 0.03, "kanat": 0.02]

    public static func make(endingAt end: String, days: Int = 35, seed: UInt64 = 2026) -> AppData {
        var rng = RNG(state: seed)
        var data = AppData.seeded()
        data.settings = AppSettings(branchName: "Demo Şube · Kadıköy", orderLookbackDays: 14, orderCoverDays: 3,
                                    staff: ["Ahmet Y.", "Ayşe K.", "Mehmet D."])
        for i in data.items.indices {
            let id = data.items[i].id
            data.items[i].unitCost = costs[id]
            data.items[i].tolerance = data.items[i].isKg ? (id == "patates" ? 0.8 : 0.08) : (id.hasPrefix("ekmek") ? 3 : 2)
        }

        // --- Ürün karışımı ve fiyatlar ---
        let engine0 = Engine(data: data)
        let tracked = data.products.filter { $0.isTracked && !$0.isWaste }
        let untracked = data.products.filter { !$0.isTracked && !$0.isWaste }
        let waste = data.products.filter { $0.isWaste }
        var weights: [String: Double] = [:]
        var prices: [String: Double] = [:]
        for p in tracked {
            // Az sayıda çok satan, çok sayıda az satan ürün (orta ölçekli bir burger restoranı)
            let w = pow(rng.unit(), 3) * 10
            if w > 0.3 { weights[p.code] = w }
            let cost = engine0.recipeCost(p).cost
            prices[p.code] = max(60, ((cost * rng.range(2.7, 3.6)) / 5).rounded(.up) * 5)
        }
        let drinks = Array(untracked.prefix(12))
        for p in drinks { weights[p.code] = rng.range(1.5, 8); prices[p.code] = (rng.range(35, 75) / 5).rounded() * 5 }
        let wasteMix = Array(waste.prefix(6))

        let start = DateKey.addDays(-(days - 1), to: end)
        let allDates = (0..<days).map { DateKey.addDays($0, to: start) }

        // --- Satışlar ---
        var salesByDate: [String: [SaleLine]] = [:]
        for (i, d) in allDates.enumerated() {
            let weekday = ((DateKey.ymd(d).map { DateKey.days($0) } ?? 0) + 4) % 7   // 0 = Pazar
            let dayFactor = (weekday == 5 || weekday == 6 || weekday == 0) ? 1.35 : 1.0
            var lines: [SaleLine] = []
            for p in tracked + drinks {
                guard let w = weights[p.code] else { continue }
                let q = (w * dayFactor * rng.range(0.75, 1.25)).rounded()
                if q > 0 { lines.append(SaleLine(code: p.code, name: p.name, qty: q, amount: q * (prices[p.code] ?? 0))) }
            }
            for p in wasteMix where rng.unit() < 0.45 {
                lines.append(SaleLine(code: p.code, name: p.name, qty: (rng.range(1, 4)).rounded(.down)))
            }
            // Son iki günde reçetesi tanımlı olmayan yeni ürünler
            if i >= days - 2 {
                lines.append(SaleLine(code: "19991", name: "KAÇMAZ MENÜ", qty: 6, amount: 6 * 345))
                lines.append(SaleLine(code: "19112", name: "KAMPANYA BOX", qty: 4, amount: 4 * 420))
            }
            salesByDate[d] = lines
        }

        // --- Stok simülasyonu ---
        let engine = Engine(data: data)
        let expected: [String: [String: Double]] = salesByDate.mapValues { lines in
            let a = engine.analyze(sales: lines)
            return a.sold.merging(a.waste, uniquingKeysWith: +)
        }
        let active = data.items.filter { $0.active }
        var avgUsage: [String: Double] = [:]
        for item in active {
            avgUsage[item.id] = allDates.reduce(0) { $0 + (expected[$1]?[item.id] ?? 0) } / Double(max(days, 1))
        }
        func round(_ v: Double, _ item: Item, step: Double? = nil) -> Double {
            let s = step ?? (item.isKg ? 0.01 : 1)
            return max(0, (v / s).rounded() * s)
        }
        for i in data.items.indices where data.items[i].active {
            let u = avgUsage[data.items[i].id] ?? 0
            if u > 0 { data.items[i].minStock = round(u * 1.5, data.items[i], step: data.items[i].isKg ? 0.5 : 5) }
            // Tolerans günlük tüketimin ~%1,5'i (sayım ve porsiyon hassasiyeti)
            data.items[i].tolerance = data.items[i].isKg ? max(0.05, (u * 0.015 * 100).rounded() / 100)
                                                        : max(2, (u * 0.015).rounded())
        }

        var stock: [String: Double] = [:]
        for item in active {
            stock[item.id] = round((avgUsage[item.id] ?? 0) * 5 + 4, item, step: item.isKg ? 0.5 : 5)
        }
        for (i, d) in allDates.enumerated() {
            var day = DayRecord(date: d, sales: salesByDate[d] ?? [], salesSource: "ModPos Satış Raporu (demo)",
                                salesPeriod: DateKey.short(d), salesImportedAt: nil)
            let isLast = i == days - 1
            for (j, item) in active.enumerated() {
                let id = item.id
                let opening = stock[id] ?? 0
                let use = expected[d]?[id] ?? 0
                var e = DayEntry()
                if i == 0 { e.opening = opening }
                // Teslimat: stok 2 günlük ihtiyaç + kritik seviyenin altındaysa ~4 günlük mal gelir
                var incoming = 0.0
                let u = avgUsage[id] ?? 0
                if u > 0 && opening < u * 2 + (data.items.first { $0.id == id }?.minStock ?? 0) {
                    incoming = round(u * 4, item, step: item.isKg ? 0.5 : 10)
                    e.incoming = incoming
                }
                var tin = 0.0, tout = 0.0
                if i == 9 && id == "ekmekSusamli" { tout = 20; e.transferOut = tout }
                if i == 17 && id == "patates" { tin = 5; e.transferIn = tin }
                var factor = 1 + rng.normal(0.012) + (shrink[id] ?? 0)
                if rng.unit() < 0.05 { factor += 0.09 }   // ara sıra belirgin kayıp
                if i == days - 6 && id == "patates" { factor += 0.12 }  // dondurucu arızası
                let actual = max(0, use * factor)
                let closing = round(opening + incoming + tin - tout - actual, item)
                stock[id] = closing
                // Son gün sayım yarım kalmış olsun
                if !isLast || j % 3 != 0 { e.closing = closing }
                if !e.isEmpty { day.entries[id] = e }
            }
            day.countedBy = data.settings.staff[i % data.settings.staff.count]
            if i < days - 2 { day.locked = true }
            if i == days - 6 { day.note = "Dondurucu arızası: yaklaşık 2 kg patates çöpe gitti." }
            if i == days - 12 { day.note = "Akşam vardiyasında yoğunluk; peynir porsiyonları kontrol edilecek." }
            data.days[d] = day
        }
        return data
    }
}
