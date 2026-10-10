import SwiftUI
import Charts
import EnvanterCore

enum AnalyticsTab: String, CaseIterable, Identifiable {
    case general = "Genel", item = "Kalem Analizi", abc = "ABC Analizi", menu = "Menü Mühendisliği"
    var id: String { rawValue }
    /// Ekran görüntüsü aracı için kısa ad
    static func named(_ s: String) -> AnalyticsTab? {
        switch s {
        case "general": return .general
        case "item": return .item
        case "abc": return .abc
        case "menu": return .menu
        default: return nil
        }
    }
}

/// İstatistikler: maliyet yüzdeleri, kayıp/zayi dağılımı, kalem eğilimleri, ABC ve menü mühendisliği.
struct AnalyticsView: View {
    @EnvironmentObject var store: AppStore
    @State private var preset: RangePreset = .last30
    @State private var from = DateKey.addDays(-29, to: DateKey.today())
    @State private var to = DateKey.today()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Picker("", selection: $store.analyticsTab) {
                    ForEach(AnalyticsTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 460)
                Spacer()
                RangePicker(preset: $preset, from: $from, to: $to)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            ScrollView {
                Group {
                    switch store.analyticsTab {
                    case .general: GeneralStatsView(from: from, to: to)
                    case .item: ItemAnalysisView(from: from, to: to)
                    case .abc: ABCView(from: from, to: to)
                    case .menu: MenuEngineeringView(from: from, to: to)
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle("İstatistikler")
        .onAppear {
            if let r = store.analyticsRange(containingSelectedDate: from, to) { from = r.from; to = r.to; preset = .custom }
        }
    }
}

/// Grafik kartı başlığı + içerik
private struct ChartCard<Content: View>: View {
    var title: String
    var subtitle: String = ""
    var info: Term? = nil
    @ViewBuilder var content: Content
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title).font(.headline)
                        if let info { InfoTip(term: info) }
                    }
                    if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private func percent(_ v: Double?) -> String {
    guard let v else { return "—" }
    return "%" + Fmt.number(v * 100, maxFraction: 1)
}

private func day(_ key: String) -> Date { DateKey.date(from: key) ?? Date() }

/// Hedefe göre renk (maliyet oranlarında düşük iyi)
private func tone(_ v: Double?, _ t: Double?) -> Color {
    guard let v, let t else { return Brand.accent }
    return v <= t ? Brand.ok : Brand.negative
}

/// Günlük maliyet dağılımı: hammadde + personel (yığılmış çubuk) ve satış tutarı (çizgi) — Tremor "CategoryBar" fikri
private struct CostMixChart: View {
    let days: [DailyStat]

    var body: some View {
        let parts: [(date: String, kind: String, value: Double)] = days.flatMap { d -> [(date: String, kind: String, value: Double)] in
            [(d.date, "Hammadde (fiili)", d.actualCost), (d.date, "Personel", d.laborCost)]
        }
        let hasRevenue = days.contains { $0.revenue > 0 }
        ChartCard(title: "Günlük maliyet dağılımı (prime cost)",
                  subtitle: hasRevenue ? "Yığılmış çubuk: hammadde + personel · Çizgi: satış tutarı" : "Yığılmış çubuk: hammadde + personel",
                  info: .primeCost) {
            Chart {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                    BarMark(x: .value("Gün", day(p.date), unit: .day), y: .value("Tutar", p.value))
                        .foregroundStyle(by: .value("Tür", p.kind))
                }
                if hasRevenue {
                    ForEach(days.filter { $0.revenue > 0 }) { d in
                        LineMark(x: .value("Gün", day(d.date), unit: .day), y: .value("Tutar", d.revenue))
                            .foregroundStyle(by: .value("Tür", "Satış tutarı"))
                            .interpolationMethod(.monotone)
                    }
                }
            }
            .chartForegroundStyleScale(domain: ["Hammadde (fiili)", "Personel", "Satış tutarı"],
                                       range: [Brand.accent, Brand.positive, Brand.ok])
            .chartLegend(position: .top, alignment: .leading)
            .frame(height: 230)
        }
    }
}

// MARK: - Genel

private struct GeneralStatsView: View {
    @EnvironmentObject var store: AppStore
    let from: String
    let to: String

    var body: some View {
        let engine = store.engine
        let stats = engine.periodStats(from: from, to: to)
        let summary = engine.summary(from: from, to: to)
        let stock = engine.stockValue(asOf: min(to, DateKey.today()))
        // Önceki eşit uzunluktaki dönem (değişim rozetleri için). Önceki dönemde en az bu dönemin yarısı kadar kayıtlı gün
        // yoksa (ör. verinin ilk ayı) oran yanıltır ("+%556"): rozet gösterilmez (web paneliyle aynı kural)
        let prevRange = PeriodComparison.previousRange(from: from, to: to)
        let prev = engine.periodStats(from: prevRange.from, to: prevRange.to)
        let hasPrev = PeriodComparison.isComparable(previousDays: prev.days.count, days: stats.days.count)
        let s = store.settings
        VStack(alignment: .leading, spacing: 16) {
            if !stats.hasCosts {
                notice("Maliyet tanımlı değil", "İstatistiklerin ₺ karşılığı için Stok Kalemleri ekranında her kalemin birim maliyetini girin. Satış raporunda \"Tutar\" sütunu varsa maliyet yüzdeleri de hesaplanır.")
            }
            StatRow {
                StatCard(title: "Satış tutarı", value: stats.revenueDays > 0 ? Fmt.money(stats.revenue) : "—",
                         detail: stats.revenueDays > 0 ? "\(stats.revenueDays) günlük raporda tutar var" : "Raporlarda tutar sütunu yok",
                         icon: "banknote", color: Brand.ok,
                         delta: hasPrev ? PeriodComparison.change(stats.revenue, prev.revenue) : nil,
                         spark: stats.days.count > 1 ? stats.days.map { $0.revenue } : nil)
                StatCard(title: "Teorik maliyet", value: stats.hasCosts ? Fmt.money(stats.theoreticalCost) : "—",
                         detail: "Reçeteye göre · satışın " + percent(stats.theoreticalCostPct), icon: "function", color: Brand.positive,
                         info: .theoreticalCost)
                StatCard(title: "Fiili maliyet", value: stats.hasCosts ? Fmt.money(stats.actualCost) : "—",
                         detail: "Sayıma göre · satışın " + percent(stats.actualCostPct) + (s.targetFoodCostPct.map { " · hedef " + percent($0) } ?? ""),
                         icon: "scalemass", color: tone(stats.actualCostPct, s.targetFoodCostPct), info: .actualCost,
                         delta: hasPrev ? PeriodComparison.change(stats.actualCost, prev.actualCost) : nil, higherIsBetter: false,
                         targetValue: stats.actualCostPct, target: s.targetFoodCostPct)
                StatCard(title: "Kayıp (fazla çıkış)", value: stats.hasCosts ? Fmt.money(stats.lossValue) : "—",
                         detail: "Net fark: \(Fmt.money(stats.netValue))", icon: "arrow.down.right.circle",
                         color: stats.lossValue > 0 ? Brand.negative : Brand.ok, info: .loss,
                         delta: hasPrev ? PeriodComparison.change(stats.lossValue, prev.lossValue) : nil, higherIsBetter: false,
                         spark: stats.days.count > 1 ? stats.days.map { $0.lossValue } : nil)
            }
            StatRow {
                StatCard(title: "Personel maliyeti", value: stats.hasLabor ? Fmt.money(stats.laborCost) : "—",
                         detail: stats.hasLabor ? "Satışın " + percent(stats.laborPct) + (s.targetLaborPct.map { " · hedef " + percent($0) } ?? "") : (store.employees.isEmpty ? "Personel ekranından çalışanları ekleyin" : "Bu dönemde personel kaydı yok"),
                         icon: "person.2", color: tone(stats.laborPct, s.targetLaborPct), info: .laborPct,
                         targetValue: stats.laborPct, target: s.targetLaborPct)
                StatCard(title: "Prime cost", value: stats.hasLabor ? Fmt.money(stats.primeCost) : "—",
                         detail: "Hammadde + personel · satışın " + percent(stats.primeCostPct),
                         icon: "chart.pie", color: tone(stats.primeCostPct, s.targetPrimeCostPct), info: .primeCost,
                         targetValue: stats.primeCostPct, target: s.targetPrimeCostPct)
                StatCard(title: "Zayi", value: stats.hasCosts ? Fmt.money(stats.wasteCost) : "—",
                         detail: "Satışa oranı " + percent(stats.wastePct), icon: "trash", color: Brand.warn, info: .wasteCost,
                         delta: hasPrev ? PeriodComparison.change(stats.wasteCost, prev.wasteCost) : nil, higherIsBetter: false)
                StatCard(title: "Stok değeri", value: stock.costedItems > 0 ? Fmt.money(stock.value) : "—",
                         detail: "Alım: \(Fmt.money(stats.incomingValue)) · \(stats.countedDays) sayılmış gün", icon: "archivebox",
                         color: Brand.accent, info: .stockValue)
            }
            if !stats.days.isEmpty {
                Text(comparisonNote(hasPrev, from: prevRange.from, to: prevRange.to))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if stats.days.isEmpty {
                EmptyStateView(icon: "chart.xyaxis.line", title: "Bu dönemde veri yok", message: "Tarih aralığını değiştirin.")
                    .frame(height: 240)
            } else {
                CostTrendChart(days: stats.days)
                if stats.hasLabor && stats.hasCosts { CostMixChart(days: stats.days) }
                HStack(alignment: .top, spacing: 16) {
                    TopLossChart(rows: summary)
                    WasteChart(from: from, to: to)
                }
                CountQualityChart(days: stats.days)
            }
        }
    }

    /// Değişim rozetlerinin neyle karşılaştırdığı (ya da neden gösterilmediği)
    private func comparisonNote(_ hasPrev: Bool, from: String, to: String) -> String {
        let range = "\(DateKey.short(from)) – \(DateKey.short(to))"
        return hasPrev
            ? "Değişim rozetleri önceki eşit uzunluktaki dönemle (\(range)) karşılaştırır."
            : "Önceki eşit dönemde (\(range)) yeterli kayıt olmadığı için değişim gösterilmiyor."
    }

    private func notice(_ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill").foregroundStyle(Brand.positive)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Stok Kalemleri") { store.section = .items }.buttonStyle(SoftButtonStyle())
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Brand.positive.opacity(0.08)))
    }
}

/// Günlük teorik / fiili maliyet (tutar varsa yüzde olarak)
private struct CostTrendChart: View {
    let days: [DailyStat]

    var body: some View {
        let usePct = days.contains { $0.revenue > 0 }
        let points: [(date: String, series: String, value: Double)] = days.flatMap { d -> [(date: String, series: String, value: Double)] in
            if usePct {
                guard d.revenue > 0 else { return [] }
                return [(d.date, "Teorik %", d.theoreticalCost / d.revenue * 100), (d.date, "Fiili %", d.actualCost / d.revenue * 100)]
            }
            return [(d.date, "Teorik maliyet", d.theoreticalCost), (d.date, "Fiili maliyet", d.actualCost)]
        }
        ChartCard(title: usePct ? "Günlük maliyet yüzdesi (food cost %)" : "Günlük teorik ve fiili maliyet (₺)",
                  subtitle: "Fiili çizgi teoriğin üstündeyse reçeteye göre fazla tüketim (fire, porsiyon, kayıp) vardır", info: .foodCostPct) {
            Chart {
                ForEach(Array(points.enumerated()), id: \.offset) { _, p in
                    LineMark(x: .value("Gün", day(p.date), unit: .day), y: .value("Değer", p.value))
                        .foregroundStyle(by: .value("Seri", p.series))
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("Gün", day(p.date), unit: .day), y: .value("Değer", p.value))
                        .foregroundStyle(by: .value("Seri", p.series))
                        .symbolSize(18)
                }
            }
            .chartForegroundStyleScale(domain: usePct ? ["Teorik %", "Fiili %"] : ["Teorik maliyet", "Fiili maliyet"],
                                       range: [Brand.positive, Brand.negative])
            .chartYScale(domain: .automatic(includesZero: false))
            .chartLegend(position: .top, alignment: .leading)
            .frame(height: 220)
        }
    }
}

/// En çok kayıp veren kalemler (₺; maliyet yoksa miktar)
private struct TopLossChart: View {
    let rows: [Engine.SummaryRow]

    var body: some View {
        let hasCosts = rows.contains { $0.diffValue != nil }
        // Kayıp tanımı İstatistikler kartı ve Özet ile aynı: tolerans dışı fazla çıkış günleri, az çıkışlarla mahsup edilmez
        let losses: [(name: String, value: Double)] = Array(rows
            .filter { $0.daysCounted > 0 && $0.shortageDays > 0 }
            .map { r -> (name: String, value: Double) in (r.item.name, hasCosts ? r.shortageValue : r.shortageQty) }
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
            .prefix(8))
        ChartCard(title: "En çok kayıp veren kalemler", subtitle: hasCosts ? "Fazla stok çıkışının tutarı (₺)" : "Fazla çıkış miktarı (birim)", info: .loss) {
            if losses.isEmpty {
                Text("Bu dönemde tolerans dışı fazla çıkış yok.").font(.callout).foregroundStyle(.secondary).frame(height: 180)
            } else {
                Chart(losses, id: \.name) { l in
                    BarMark(x: .value("Kayıp", l.value), y: .value("Kalem", l.name))
                        .foregroundStyle(Brand.negative.gradient)
                        .annotation(position: .trailing) {
                            Text(hasCosts ? Fmt.money(l.value) : Fmt.number(l.value, maxFraction: 2))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                }
                .chartXAxis(.hidden)
                .frame(height: max(140, CGFloat(losses.count) * 30))
            }
        }
    }
}

/// Zayi dağılımı (kalem bazında)
private struct WasteChart: View {
    @EnvironmentObject var store: AppStore
    let from: String
    let to: String

    var body: some View {
        let hasCosts = store.engine.activeItems.contains { $0.unitCost != nil }
        // Zayi, sayılmayan günlerde de satış raporundan bilinir; tüm günler toplanır
        var totals: [String: Double] = [:]
        for d in store.engine.datesWithData where d >= from && d <= to {
            for c in store.engine.calc(date: d).rows where c.waste > 0 {
                let cost = store.engine.itemsByID[c.itemID]?.cost(on: d)
                totals[c.itemID, default: 0] += hasCosts ? c.waste * (cost ?? 0) : c.waste
            }
        }
        let all: [(name: String, value: Double)] = totals.compactMap { entry -> (name: String, value: Double)? in
            guard entry.value > 0, let item = store.engine.itemsByID[entry.key] else { return nil }
            return (item.name, entry.value)
        }
        let list = Array(all.sorted { $0.value > $1.value }.prefix(8))
        return ChartCard(title: "Zayi dağılımı", subtitle: hasCosts ? "ZAYİ ürünlerinden düşen tutar (₺)" : "ZAYİ ürünlerinden düşen miktar", info: .wasteCost) {
            if list.isEmpty {
                Text("Bu dönemde zayi kaydı yok.").font(.callout).foregroundStyle(.secondary).frame(height: 180)
            } else {
                Chart(list, id: \.name) { w in
                    SectorMark(angle: .value("Zayi", w.value), innerRadius: .ratio(0.55), angularInset: 1.5)
                        .foregroundStyle(by: .value("Kalem", w.name))
                        .cornerRadius(3)
                }
                .chartLegend(position: .trailing, alignment: .center)
                .frame(height: 200)
            }
        }
    }
}

/// Sayım düzeni: her gün sayılan ve sorunlu kalem sayısı
private struct CountQualityChart: View {
    let days: [DailyStat]

    var body: some View {
        ChartCard(title: "Sayım düzeni ve sorunlu kalemler", subtitle: "Çubuk: sayılan kalem sayısı · Kırmızı çizgi: tolerans dışı fark çıkan kalem sayısı", info: .tolerance) {
            Chart {
                ForEach(days) { d in
                    BarMark(x: .value("Gün", day(d.date), unit: .day), y: .value("Kalem", d.countedItems))
                        .foregroundStyle(Color.secondary.opacity(0.35))
                }
                ForEach(days) { d in
                    LineMark(x: .value("Gün", day(d.date), unit: .day), y: .value("Kalem", d.problemItems))
                        .foregroundStyle(Brand.negative)
                    PointMark(x: .value("Gün", day(d.date), unit: .day), y: .value("Kalem", d.problemItems))
                        .foregroundStyle(Brand.negative).symbolSize(20)
                }
            }
            .frame(height: 160)
        }
    }
}

// MARK: - Kalem analizi

private struct ItemAnalysisView: View {
    @EnvironmentObject var store: AppStore
    let from: String
    let to: String

    var body: some View {
        let items = store.engine.activeItems
        let selectedID = store.analyticsItem ?? items.first?.id ?? ""
        let item = store.engine.itemsByID[selectedID]
        let series = store.engine.itemSeries(itemID: selectedID, from: from, to: to)
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Picker("Kalem", selection: Binding(get: { selectedID }, set: { store.analyticsItem = $0 })) {
                    ForEach(items) { Text($0.name).tag($0.id) }
                }
                .frame(width: 280)
                Spacer()
            }
            if let item {
                if series.isEmpty {
                    EmptyStateView(icon: "chart.xyaxis.line", title: "\(item.name) için bu dönemde hareket yok", message: "Tarih aralığını değiştirin.")
                        .frame(height: 260)
                } else {
                    itemCards(item, series)
                    ConsumptionChart(item: item, series: series)
                    HStack(alignment: .top, spacing: 16) {
                        DiffChart(item: item, series: series)
                        StockLevelChart(item: item, series: series)
                    }
                }
                if (item.costHistory?.filter { $0.date != nil }.count ?? 0) >= 2 {
                    PriceHistoryChart(item: item)
                }
            }
        }
    }

    private func itemCards(_ item: Item, _ s: [ItemDayPoint]) -> some View {
        let counted = s.filter { $0.actual != nil }
        let avgActual = counted.isEmpty ? nil : counted.reduce(0) { $0 + ($1.actual ?? 0) } / Double(counted.count)
        let avgExpected = s.isEmpty ? 0 : s.reduce(0) { $0 + $1.expected } / Double(s.count)
        let totalDiff = counted.reduce(0) { $0 + ($1.diff ?? 0) }
        let accuracy = counted.isEmpty ? nil : Double(counted.filter { item.severity(of: $0.diff ?? 0).isProblem == false }.count) / Double(counted.count)
        let u = item.unit.lowercased()
        return StatRow {
            StatCard(title: "Ort. beklenen tüketim", value: "\(Fmt.number(avgExpected, maxFraction: item.maxFraction)) \(u)",
                     detail: "Reçeteye göre, günlük", icon: "function", color: Brand.positive, info: .sold)
            StatCard(title: "Ort. fiili tüketim", value: avgActual.map { "\(Fmt.number($0, maxFraction: item.maxFraction)) \(u)" } ?? "—",
                     detail: "\(counted.count) sayılmış gün", icon: "scalemass", color: Brand.accent, info: .actualUsage)
            StatCard(title: "Toplam fark", value: "\(Fmt.number(totalDiff, maxFraction: item.maxFraction)) \(u)",
                     detail: item.unitCost.map { "Tutar: \(Fmt.money(totalDiff * $0))" } ?? "Birim maliyet tanımlı değil",
                     icon: "plusminus", color: Brand.color(for: item.severity(of: totalDiff)), info: .diff)
            StatCard(title: "Tutarlılık", value: percent(accuracy),
                     detail: "Farkın tolerans içinde kaldığı günler", icon: "target",
                     color: (accuracy ?? 0) >= 0.8 ? Brand.ok : Brand.warn, progress: accuracy, info: .consistency)
        }
    }
}

private struct ConsumptionChart: View {
    let item: Item
    let series: [ItemDayPoint]

    var body: some View {
        ChartCard(title: "\(item.name) · beklenen ve fiili tüketim (\(item.unit.lowercased()))",
                  subtitle: "Beklenen: satış raporu × reçete (zayi dahil). Fiili: sayımdan hesaplanan tüketim.") {
            Chart {
                ForEach(series) { p in
                    BarMark(x: .value("Gün", day(p.date), unit: .day), y: .value("Miktar", p.expected))
                        .foregroundStyle(by: .value("Seri", "Beklenen"))
                        .opacity(0.55)
                    if let a = p.actual {
                        LineMark(x: .value("Gün", day(p.date), unit: .day), y: .value("Miktar", a))
                            .foregroundStyle(by: .value("Seri", "Fiili"))
                            .interpolationMethod(.monotone)
                        PointMark(x: .value("Gün", day(p.date), unit: .day), y: .value("Miktar", a))
                            .foregroundStyle(by: .value("Seri", "Fiili"))
                    }
                }
            }
            .chartForegroundStyleScale(domain: ["Beklenen", "Fiili"], range: [Brand.positive, Brand.accent])
            .chartLegend(position: .top, alignment: .leading)
            .frame(height: 230)
        }
    }
}

private struct DiffChart: View {
    let item: Item
    let series: [ItemDayPoint]

    var body: some View {
        ChartCard(title: "Günlük fark", subtitle: "Negatif: beklenenden fazla çıkış", info: .diff) {
            Chart {
                ForEach(series.filter { $0.diff != nil }) { p in
                    BarMark(x: .value("Gün", day(p.date), unit: .day), y: .value("Fark", p.diff ?? 0))
                        .foregroundStyle(Brand.color(for: item.severity(of: p.diff ?? 0)))
                }
                RuleMark(y: .value("Sıfır", 0)).foregroundStyle(.secondary)
                if let t = item.tolerance, t > 0 {
                    RuleMark(y: .value("Tolerans", -t)).foregroundStyle(Brand.warn.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    RuleMark(y: .value("Tolerans", t)).foregroundStyle(Brand.warn.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
            .frame(height: 190)
        }
    }
}

private struct StockLevelChart: View {
    let item: Item
    let series: [ItemDayPoint]

    var body: some View {
        ChartCard(title: "Stok seviyesi (kapanış)", subtitle: item.minStock.map { "Kesikli çizgi: kritik seviye \(Fmt.number($0, maxFraction: item.maxFraction))" } ?? "Kritik seviye tanımlı değil", info: .minStock) {
            Chart {
                ForEach(series.filter { $0.closing != nil }) { p in
                    AreaMark(x: .value("Gün", day(p.date), unit: .day), y: .value("Stok", p.closing ?? 0))
                        .foregroundStyle(Brand.accent.opacity(0.15).gradient)
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Gün", day(p.date), unit: .day), y: .value("Stok", p.closing ?? 0))
                        .foregroundStyle(Brand.accent)
                        .interpolationMethod(.monotone)
                }
                if let m = item.minStock, m > 0 {
                    RuleMark(y: .value("Kritik", m)).foregroundStyle(Brand.warn)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                }
            }
            .frame(height: 190)
        }
    }
}

/// Birim maliyetin zaman içindeki değişimi (tedarikçi fiyat takibi)
private struct PriceHistoryChart: View {
    let item: Item

    var body: some View {
        let points = (item.costHistory ?? []).compactMap { p -> (date: Date, cost: Double)? in
            guard let d = p.date, let date = DateKey.date(from: d) else { return nil }
            return (date, p.cost)
        }
        let change = item.lastPriceChange
        ChartCard(title: "Birim maliyet geçmişi (₺ / \(item.unit.lowercased()))",
                  subtitle: change.map { changeText(from: $0.from, to: $0.to, ratio: $0.ratio, date: $0.date) } ?? "",
                  info: .priceAlert) {
            Chart {
                ForEach(Array(points.enumerated()), id: \.offset) { _, p in
                    LineMark(x: .value("Tarih", p.date, unit: .day), y: .value("Birim maliyet", p.cost))
                        .foregroundStyle(Brand.accent)
                        .interpolationMethod(.stepEnd)
                    PointMark(x: .value("Tarih", p.date, unit: .day), y: .value("Birim maliyet", p.cost))
                        .foregroundStyle(Brand.accent)
                        .annotation(position: .top) {
                            Text(Fmt.money(p.cost)).font(.caption2).foregroundStyle(.secondary)
                        }
                }
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(height: 170)
        }
    }

    /// "Son değişim (09.10.2026): 60,00 ₺ → 68,00 ₺ (+%13,3)" (web paneliyle aynı biçim)
    private func changeText(from: Double, to: Double, ratio: Double, date: String?) -> String {
        let when = date.map { " (\(DateKey.short($0)))" } ?? ""
        return "Son değişim\(when): \(Fmt.money(from, fraction: 2)) → \(Fmt.money(to, fraction: 2)) (\(Fmt.signedPercent(ratio)))"
    }
}

// MARK: - ABC

private struct ABCView: View {
    @EnvironmentObject var store: AppStore
    let from: String
    let to: String

    var body: some View {
        let rows = store.engine.abcAnalysis(from: from, to: to)
        VStack(alignment: .leading, spacing: 16) {
            Text("ABC analizi, stok kalemlerini dönemdeki tüketim değerine göre sıralar: A sınıfı (değerin ilk %80'i) en sık ve dikkatli sayılması gerekenlerdir; C sınıfı haftalık sayım için yeterli olabilir.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if rows.isEmpty {
                EmptyStateView(icon: "chart.bar.doc.horizontal", title: "Hesaplanacak veri yok",
                               message: "ABC analizi için kalemlerin birim maliyeti ve dönemde tüketim (sayım veya satış) olmalı.")
                    .frame(height: 260)
            } else {
                StatRow {
                    ForEach([ABCClass.a, .b, .c], id: \.self) { k in
                        let list = rows.filter { $0.klass == k }
                        StatCard(title: "\(k.rawValue) sınıfı", value: "\(list.count) kalem",
                                 detail: "Tüketim değerinin " + percent(list.reduce(0) { $0 + $1.share }) + "'i · " + Fmt.money(list.reduce(0) { $0 + $1.value }),
                                 icon: "\(k.rawValue.lowercased()).circle.fill", color: color(k), info: .abc)
                    }
                }
                ChartCard(title: "Pareto grafiği", subtitle: "Çubuk: kalemin payı · Çizgi: birikimli pay (%)", info: .abc) {
                    Chart {
                        ForEach(rows) { r in
                            BarMark(x: .value("Kalem", r.item.name), y: .value("Pay", r.share * 100))
                                .foregroundStyle(color(r.klass))
                            LineMark(x: .value("Kalem", r.item.name), y: .value("Birikimli", r.cumulativeShare * 100))
                                .foregroundStyle(Color.primary.opacity(0.7))
                            PointMark(x: .value("Kalem", r.item.name), y: .value("Birikimli", r.cumulativeShare * 100))
                                .foregroundStyle(Color.primary.opacity(0.7)).symbolSize(16)
                        }
                        RuleMark(y: .value("%80", 80)).foregroundStyle(Brand.warn.opacity(0.6))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                    .chartYScale(domain: 0...100)
                    .frame(height: 240)
                }
                Card(padding: 0) {
                    VStack(spacing: 0) {
                        HStack {
                            Text("Sınıf").frame(width: 26)
                            Text("Kalem")
                            Spacer()
                            Text("Tüketim").frame(width: 120, alignment: .trailing)
                            Text("Tutar").frame(width: 110, alignment: .trailing)
                            Text("Pay").frame(width: 70, alignment: .trailing).help("Kalemin dönem tüketim değerindeki payı")
                            Text("Birikimli").frame(width: 70, alignment: .trailing).explains(.abc)
                        }
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Color.primary.opacity(0.05))
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                            HStack {
                                Text(r.klass.rawValue).font(.headline).foregroundStyle(.white)
                                    .frame(width: 26, height: 26).background(Circle().fill(color(r.klass)))
                                Text(r.item.name).fontWeight(.medium)
                                Spacer()
                                Text("\(Fmt.number(r.quantity, maxFraction: r.item.maxFraction)) \(r.item.unit.lowercased())")
                                    .monospacedDigit().foregroundStyle(.secondary).frame(width: 120, alignment: .trailing)
                                Text(Fmt.money(r.value)).monospacedDigit().frame(width: 110, alignment: .trailing)
                                Text(percent(r.share)).monospacedDigit().foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
                                Text(percent(r.cumulativeShare)).monospacedDigit().foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(i % 2 == 0 ? Color.clear : Color.primary.opacity(0.03))
                        }
                    }
                }
            }
        }
    }

    private func color(_ k: ABCClass) -> Color {
        switch k {
        case .a: return Brand.negative
        case .b: return Brand.warn
        case .c: return Brand.ok
        }
    }
}

// MARK: - Menü mühendisliği

private struct MenuEngineeringView: View {
    @EnvironmentObject var store: AppStore
    let from: String
    let to: String

    var body: some View {
        let stats = store.engine.menuEngineering(from: from, to: to)
        let classified = stats.filter { $0.klass != nil }
        // Ürün maliyet oranı, Ayarlar'daki hammadde hedefini aşınca kırmızı
        let costLimit = store.settings.targetFoodCostPct ?? 0.35
        VStack(alignment: .leading, spacing: 16) {
            Text("Menü mühendisliği, reçeteli ürünleri popülerlik (satış payı) ve birim kâra (fiyat − reçete maliyeti) göre dört gruba ayırır. Satış raporunda \"Tutar\" sütunu ve ürünün tüm hammaddelerinde birim maliyet olmalıdır.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if classified.isEmpty {
                EmptyStateView(icon: "star.leadinghalf.filled", title: "Hesaplanacak veri yok",
                               message: stats.isEmpty ? "Bu dönemde tutar bilgisi olan satış raporu yok." : "Ürünlerin hammaddelerine birim maliyet girin (Stok Kalemleri).")
                    .frame(height: 260)
            } else {
                StatRow {
                    ForEach(MenuClass.allCases, id: \.self) { k in
                        let list = classified.filter { $0.klass == k }
                        StatCard(title: k.rawValue, value: "\(list.count) ürün",
                                 detail: k.advice, icon: icon(k), color: color(k), info: .menuEngineering)
                    }
                }
                MenuMatrixChart(stats: classified, productCount: stats.count, color: color)
                Card(padding: 0) {
                    VStack(spacing: 0) {
                        HStack {
                            Text("Ürün").frame(maxWidth: .infinity, alignment: .leading)
                            Text("Adet").frame(width: 70, alignment: .trailing)
                            Text("Ort. fiyat").frame(width: 90, alignment: .trailing).help("Satış raporundaki tutar ÷ adet")
                            Text("Reçete maliyeti").frame(width: 110, alignment: .trailing).explains(.recipeCost)
                            Text("Maliyet %").frame(width: 80, alignment: .trailing).explains(.foodCostPct)
                            Text("Birim kâr").frame(width: 90, alignment: .trailing).explains(.unitMargin)
                            Text("Toplam kâr").frame(width: 110, alignment: .trailing).help("Birim kâr × satış adedi")
                            Text("Sınıf").frame(width: 80, alignment: .center).explains(.menuEngineering)
                        }
                        .font(.caption.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Color.primary.opacity(0.05))
                        ForEach(Array(stats.enumerated()), id: \.element.id) { i, s in
                            HStack {
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(s.product.name).lineLimit(1)
                                    Text(s.product.code).font(.caption2).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Text(Fmt.number(s.qty, maxFraction: 0)).frame(width: 70, alignment: .trailing)
                                Text(Fmt.money(s.unitPrice)).frame(width: 90, alignment: .trailing)
                                Text(s.unitCost.map { Fmt.money($0) } ?? "eksik").foregroundStyle(s.unitCost == nil ? Brand.warn : .primary)
                                    .frame(width: 110, alignment: .trailing)
                                Text(percent(s.foodCostPct)).foregroundStyle((s.foodCostPct ?? 0) > costLimit ? Brand.negative : .primary)
                                    .frame(width: 80, alignment: .trailing)
                                Text(s.unitMargin.map { Fmt.money($0) } ?? "—").frame(width: 90, alignment: .trailing)
                                Text(s.totalMargin.map { Fmt.money($0) } ?? "—").frame(width: 110, alignment: .trailing)
                                Group {
                                    if let k = s.klass { Pill(text: k.rawValue, color: color(k)) } else { Text("—").foregroundStyle(.tertiary) }
                                }
                                .frame(width: 80)
                            }
                            .monospacedDigit().font(.callout)
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .background(i % 2 == 0 ? Color.clear : Color.primary.opacity(0.03))
                        }
                    }
                }
            }
        }
    }

    private func color(_ k: MenuClass) -> Color {
        switch k {
        case .star: return Brand.ok
        case .plowhorse: return Brand.positive
        case .puzzle: return Brand.warn
        case .dog: return Brand.negative
        }
    }

    private func icon(_ k: MenuClass) -> String {
        switch k {
        case .star: return "star.fill"
        case .plowhorse: return "figure.walk"
        case .puzzle: return "puzzlepiece.fill"
        case .dog: return "arrow.down.circle"
        }
    }
}

private struct MenuMatrixChart: View {
    let stats: [MenuItemStat]
    /// Sınıflandırmadaki ürün sayısı (maliyeti eksik olanlar dahil; motorla aynı eşik)
    let productCount: Int
    let color: (MenuClass) -> Color

    var body: some View {
        ChartCard(title: "Popülerlik × kârlılık matrisi",
                  subtitle: "Yatay: satış payı (%) · Dikey: birim kâr (₺) · Kesikli çizgiler sınıf eşikleri · Her ürün aşağıdaki tabloda", info: .menuEngineering) {
            // Etiketlerin üst üste binmemesi için grafiğin genişliği gerekir
            GeometryReader { geo in
                matrix(width: Double(geo.size.width))
            }
            .frame(height: 340)
        }
    }

    private func matrix(width: Double) -> some View {
        let threshold = 70.0 / Double(max(productCount, 1))
        let totalQty = stats.reduce(0) { $0 + $1.qty }
        let avgMargin = totalQty > 0 ? stats.reduce(0) { $0 + ($1.totalMargin ?? 0) } / totalQty : 0
        let maxX = (stats.map { $0.popularity * 100 }.max() ?? 1) * 1.08
        let margins = stats.map { $0.unitMargin ?? 0 }
        // Dikey eksen yuvarlak sınırlarla verilir (etiket yerleşimi grafikle aynı ölçeği kullansın); en üstteki
        // noktaların etiketi sığsın diye üstte pay bırakılır
        let yDomain = ChartLabelLayout.niceDomain(min: margins.min() ?? 0, max: (margins.max() ?? 1) * 1.12)
        let labelled = labels(maxX: maxX, yDomain: yDomain, width: width)
        return Chart {
            ForEach(stats) { s in
                PointMark(x: .value("Popülerlik", s.popularity * 100), y: .value("Birim kâr", s.unitMargin ?? 0))
                    .foregroundStyle(color(s.klass ?? .dog))
                    .symbolSize(labelled.contains(s.product.code) ? 70 : 34)
                    .annotation(position: .top, spacing: 2) {
                        if labelled.contains(s.product.code) {
                            Text(ChartLabelLayout.shortText(s.product.name))
                                .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
            }
            RuleMark(x: .value("Eşik", threshold)).foregroundStyle(.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            RuleMark(y: .value("Ort. kâr", avgMargin)).foregroundStyle(.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        .chartXScale(domain: 0...maxX)
        .chartYScale(domain: yDomain)
        .chartXAxisLabel("Satış payı (%)")
        .chartYAxisLabel("Birim kâr (₺)")
    }

    /// Etiketlenecek ürünler: ciroya göre ilk 8 ürün, en kârlı ve en popüler ürün (bu sırayla); daha önce yerleşmiş bir
    /// etiketle üst üste binenler atlanır (web paneliyle aynı yaklaşım)
    private func labels(maxX: Double, yDomain: ClosedRange<Double>, width: Double) -> Set<String> {
        var order = Array(stats.sorted { $0.revenue > $1.revenue }.prefix(8))
        if let m = stats.max(by: { ($0.unitMargin ?? 0) < ($1.unitMargin ?? 0) }) { order.append(m) }
        if let p = stats.max(by: { $0.popularity < $1.popularity }) { order.append(p) }
        let candidates = order.map { s in
            ChartLabelLayout.Candidate(id: s.product.code, text: s.product.name, x: s.popularity * 100, y: s.unitMargin ?? 0)
        }
        // Çizim alanı yaklaşık: sağdaki eksen değerleri ve eksen başlıkları düşülür
        return ChartLabelLayout.visible(candidates, xDomain: 0...maxX, yDomain: yDomain,
                                        width: max(width - 70, 120), height: 280)
    }
}
