import SwiftUI
import Charts
import EnvanterCore

/// Pano: seçili günün durumu, ayın maliyet oranları (hedeflerle), son 30 günün durum şeridi ve dikkat gerektirenler.
struct OverviewView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        let date = store.selectedDate
        let engine = store.engine
        let result = engine.calc(date: date)
        let rows = result.rows
        let analysis = result.analysis
        let o = engine.overview(date: date, rows: rows, analysis: analysis)
        let trend30 = engine.trend(endingAt: date, days: 30)
        let hasCosts = engine.activeItems.contains { $0.unitCost != nil }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center) {
                    DateNavigator()
                    Spacer()
                }
                dayCards(o, hasCosts: hasCosts, trend: Array(trend30.suffix(14)))
                MonthCards(date: date)
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 16) {
                        trackerCard(trend30)
                        trendCard(Array(trend30.suffix(14)), hasCosts: hasCosts)
                    }
                    .frame(maxWidth: .infinity)
                    actions(o).frame(width: 290)
                }
                attention(rows: rows, analysis: analysis, overview: o)
            }
            .padding(22)
        }
        .navigationTitle("Genel Bakış")
    }

    // MARK: Günün kartları

    private func dayCards(_ o: DayOverview, hasCosts: Bool, trend: [DayOverview]) -> some View {
        StatRow(spacing: 14) {
            StatCard(title: "Sayım", value: "\(o.countedItems) / \(o.itemCount)",
                     detail: o.isFullyCounted ? "Tüm kalemler sayıldı" : (o.hasAnyCount ? "\(o.itemCount - o.countedItems) kalem bekliyor" : "Bugün henüz sayım girilmedi"),
                     icon: "checklist", color: o.isFullyCounted ? Brand.ok : Brand.accent,
                     progress: o.itemCount > 0 ? Double(o.countedItems) / Double(o.itemCount) : 0, info: .closing)
            StatCard(title: "Satış raporu", value: o.hasSales ? (o.salesLines > 0 ? "\(o.salesLines) satır" : "Excel'den") : "Yok",
                     detail: o.unknownLines > 0 ? "\(o.unknownLines) ürünün reçetesi tanımsız" : (o.hasSales ? "Tüm ürünler eşleşti" : "ModPos raporunu aktarın"),
                     icon: "cart", color: o.hasSales ? (o.unknownLines > 0 ? Brand.warn : Brand.ok) : Brand.negative, info: .sold)
            StatCard(title: "Sorunlu kalem", value: o.hasAnyCount ? "\(o.problemItems)" : "—",
                     detail: o.hasAnyCount ? (o.problemItems == 0 ? "Farklar tolerans içinde" : "\(o.shortageItems) kalemde fazla çıkış") : "Sayım girilince hesaplanır",
                     icon: "exclamationmark.triangle", color: o.problemItems == 0 ? Brand.ok : Brand.negative, info: .diff)
            StatCard(title: "Günün kaybı", value: hasCosts ? (o.hasAnyCount ? Fmt.money(o.lossValue) : "—") : "—",
                     detail: hasCosts ? "Net fark: \(Fmt.money(o.netValue)) · çizgi son 14 gün" : "Stok Kalemleri'nde birim maliyet girin",
                     icon: "turkishlirasign.circle", color: o.lossValue > 0 ? Brand.negative : Brand.ok, info: .loss,
                     spark: hasCosts ? trend.map { $0.lossValue } : nil)
        }
    }

    // MARK: Durum şeridi

    private func trackerCard(_ days: [DayOverview]) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Son 30 gün").font(.headline)
                    Text("Her kutu bir gün: üzerine gelince özet, tıklayınca o güne gider").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    let counted = days.filter { $0.hasAnyCount }.count
                    Text("\(counted) günde sayım").font(.callout).foregroundStyle(.secondary)
                }
                TrackerStrip(days: days, selected: store.selectedDate) { store.selectedDate = $0 }
                HStack {
                    Text(DateKey.short(days.first?.date ?? "")).font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                    TrackerLegend()
                    Spacer()
                    Text(DateKey.short(days.last?.date ?? "")).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: Eğilim

    private func trendCard(_ trend: [DayOverview], hasCosts: Bool) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(hasCosts ? "Son 14 gün · günlük kayıp (₺)" : "Son 14 gün · sorunlu kalem sayısı").font(.headline)
                    InfoTip(term: hasCosts ? .loss : .diff)
                    Spacer()
                    let unlocked = trend.filter { $0.hasAnyCount && !$0.isLocked }.count
                    if unlocked > 0 {
                        Label("\(unlocked) sayılmış gün henüz kapatılmadı", systemImage: "lock.open").font(.callout).foregroundStyle(.secondary)
                            .help(Term.lock.text)
                    }
                }
                Chart {
                    ForEach(trend) { d in
                        BarMark(x: .value("Gün", DateKey.date(from: d.date) ?? Date(), unit: .day),
                                y: .value(hasCosts ? "Kayıp" : "Kalem", hasCosts ? d.lossValue : Double(d.problemItems)))
                            .foregroundStyle(d.date == store.selectedDate ? Brand.accent : Brand.negative.opacity(0.7))
                            .cornerRadius(3)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 2)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    }
                }
                .frame(height: 150)
                if hasCosts {
                    Label("Toplam: \(Fmt.money(trend.reduce(0) { $0 + $1.lossValue }))", systemImage: "sum").font(.callout)
                }
            }
        }
    }

    // MARK: Hızlı işlemler

    private func actions(_ o: DayOverview) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Hızlı işlemler").font(.headline)
                quick(o.hasAnyCount ? "Sayıma devam et" : "Sayıma başla", "checklist", primary: true) { store.section = .daily }
                quick("Satış raporu aktar…", "doc.badge.plus") { store.pickAndImportFile() }
                quick("Panodan satış yapıştır", "doc.on.clipboard") { store.beginPasteImport() }
                quick("Personel / vardiya", "person.2") { store.section = .labor }
                quick("Sipariş önerisi", "shippingbox.and.arrow.backward") { store.section = .orders }
                quick("Sayım formu (Excel)…", "printer") { store.exportCountSheet() }
                quick("Günü Excel'e aktar…", "square.and.arrow.up") { store.exportDayExcel() }
            }
        }
    }

    @ViewBuilder
    private func quick(_ title: String, _ icon: String, primary: Bool = false, _ action: @escaping () -> Void) -> some View {
        if primary {
            Button(action: action) { Label(title, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading) }
                .buttonStyle(PrimaryButtonStyle())
        } else {
            Button(action: action) { Label(title, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading) }
                .buttonStyle(SoftButtonStyle())
        }
    }

    // MARK: Dikkat gerektirenler

    @ViewBuilder
    private func attention(rows: [ItemCalc], analysis: SalesAnalysis, overview o: DayOverview) -> some View {
        let engine = store.engine
        let problems = rows.filter { $0.severity?.isProblem == true }
            .sorted { abs($0.diffValue ?? $0.diff ?? 0) > abs($1.diffValue ?? $1.diff ?? 0) }
        let low = rows.filter { $0.belowMinimum }
        let prices = engine.priceAlerts(asOf: store.selectedDate, threshold: store.settings.priceAlertPct)
        let orders = store.openOrders
        if problems.isEmpty && low.isEmpty && analysis.unknownLines.isEmpty && prices.isEmpty && orders.isEmpty {
            Card {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill").font(.title2).foregroundStyle(Brand.ok)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Dikkat gerektiren bir şey yok").font(.headline)
                        Text(o.hasAnyCount ? "Sayılan kalemlerde tolerans dışı fark, kritik seviye altında stok veya fiyat artışı yok."
                                           : "Sayım ve satış girildikçe sorunlu kalemler burada listelenir.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        } else {
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 16) {
                    if !problems.isEmpty {
                        ListCard(title: "Tolerans dışı farklar", icon: "exclamationmark.triangle.fill", color: Brand.negative, term: .diff,
                                 linkTitle: "Günlük envantere git", link: { store.section = .daily }) {
                            ForEach(problems.prefix(8), id: \.itemID) { c in
                                if let item = engine.itemsByID[c.itemID], let d = c.diff {
                                    HStack {
                                        Text(item.name)
                                        Spacer()
                                        Text("\(Fmt.number(d, maxFraction: item.maxFraction)) \(item.unit.lowercased())")
                                            .monospacedDigit().foregroundStyle(Brand.color(for: c.severity ?? .zero))
                                        if let v = c.diffValue {
                                            Text(Fmt.money(v)).monospacedDigit().foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
                                        }
                                    }
                                    .font(.callout)
                                }
                            }
                        }
                    }
                    if !prices.isEmpty {
                        ListCard(title: "Fiyat artışları (son 30 gün)", icon: "arrow.up.forward.circle.fill", color: Brand.warn, term: .priceAlert,
                                 linkTitle: "Stok kalemlerine git", link: { store.section = .items }) {
                            ForEach(prices, id: \.item.id) { a in
                                HStack {
                                    Text(a.item.name)
                                    Text("\(engine.productsUsing(itemID: a.item.id)) reçetede").font(.caption).foregroundStyle(.tertiary)
                                    Spacer()
                                    Text("\(Fmt.money(a.from, fraction: 2)) → \(Fmt.money(a.to, fraction: 2))").monospacedDigit().foregroundStyle(.secondary)
                                    DeltaBadge(ratio: a.ratio, higherIsBetter: false)
                                }
                                .font(.callout)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                VStack(spacing: 16) {
                    if !low.isEmpty {
                        ListCard(title: "Kritik seviyenin altında", icon: "arrow.down.to.line", color: Brand.warn, term: .minStock,
                                 linkTitle: "Sipariş önerisini aç", link: { store.section = .orders }) {
                            ForEach(low, id: \.itemID) { c in
                                if let item = engine.itemsByID[c.itemID] {
                                    HStack {
                                        Text(item.name)
                                        Spacer()
                                        Text("\(Fmt.number(c.closing ?? 0, maxFraction: item.maxFraction)) / \(Fmt.number(item.minStock ?? 0, maxFraction: item.maxFraction)) \(item.unit.lowercased())")
                                            .monospacedDigit().foregroundStyle(.secondary)
                                    }
                                    .font(.callout)
                                }
                            }
                        }
                    }
                    if !orders.isEmpty {
                        ListCard(title: "Bekleyen siparişler", icon: "shippingbox", color: Brand.positive, term: .purchaseOrder,
                                 linkTitle: "Siparişlere git", link: { store.section = .orders }) {
                            ForEach(orders) { order in
                                HStack {
                                    Text(DateKey.short(order.date) + (order.supplier.isEmpty ? "" : " · " + order.supplier))
                                    Spacer()
                                    Text("\(order.lines.count) kalem").foregroundStyle(.secondary)
                                }
                                .font(.callout)
                            }
                        }
                    }
                    if !analysis.unknownLines.isEmpty {
                        ListCard(title: "Reçetesi tanımsız satışlar", icon: "questionmark.diamond.fill", color: Brand.warn, term: nil,
                                 linkTitle: "Satış dökümünde reçete tanımla", link: { store.section = .sales }) {
                            ForEach(analysis.unknownLines.sorted { $0.qty > $1.qty }.prefix(6)) { l in
                                HStack {
                                    Text(l.name.isEmpty ? l.code : l.name).lineLimit(1)
                                    Spacer()
                                    Text("\(Fmt.number(l.qty, maxFraction: 0)) adet").monospacedDigit().foregroundStyle(.secondary)
                                }
                                .font(.callout)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

/// Başlıklı liste kartı (dikkat gerektirenler)
private struct ListCard<Content: View>: View {
    var title: String
    var icon: String
    var color: Color
    var term: Term?
    var linkTitle: String
    var link: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Label(title, systemImage: icon).font(.headline).foregroundStyle(color)
                    if let term { InfoTip(term: term) }
                }
                content
                Button(linkTitle, action: link).buttonStyle(.link)
            }
        }
    }
}

/// Ayın maliyet oranları: hammadde, personel, prime cost (hedef çubuklarıyla) ve stok değeri
private struct MonthCards: View {
    @EnvironmentObject var store: AppStore
    let date: String

    var body: some View {
        let engine = store.engine
        let start = DateKey.startOfMonth(date)
        let p = engine.periodStats(from: start, to: date)
        let s = store.settings
        let stock = engine.stockValue(asOf: date)
        let label = "\(DateKey.monthTitle(date)) · \(DateKey.short(start)) – \(DateKey.short(date))"
        StatRow(spacing: 14) {
            StatCard(title: "Hammadde oranı", value: pct(p.actualCostPct),
                     detail: target(s.targetFoodCostPct, label), icon: "fork.knife",
                     color: tone(p.actualCostPct, s.targetFoodCostPct), info: .foodCostPct,
                     targetValue: p.actualCostPct, target: s.targetFoodCostPct)
            StatCard(title: "Personel oranı", value: pct(p.laborPct),
                     detail: p.hasLabor ? target(s.targetLaborPct, label) : "Personel ekranından çalışanları ekleyin",
                     icon: "person.2", color: tone(p.laborPct, s.targetLaborPct), info: .laborPct,
                     targetValue: p.laborPct, target: s.targetLaborPct)
            StatCard(title: "Prime cost", value: pct(p.primeCostPct),
                     detail: p.hasLabor ? Fmt.money(p.primeCost) + " · " + target(s.targetPrimeCostPct, "") : "Hammadde + personel",
                     icon: "chart.pie", color: tone(p.primeCostPct, s.targetPrimeCostPct), info: .primeCost,
                     targetValue: p.primeCostPct, target: s.targetPrimeCostPct)
            StatCard(title: "Stok değeri", value: stock.costedItems > 0 ? Fmt.money(stock.value) : "—",
                     detail: "Son sayımlara göre · \(stock.costedItems) kalem", icon: "archivebox", color: Brand.positive, info: .stockValue)
        }
    }

    private func pct(_ v: Double?) -> String { v.map { "%" + Fmt.number($0 * 100, maxFraction: 1) } ?? "—" }
    private func target(_ t: Double?, _ suffix: String) -> String {
        let head = t.map { "Hedef \(pct($0))" } ?? "Hedef yok"
        return suffix.isEmpty ? head : head + " · " + suffix
    }
    private func tone(_ v: Double?, _ t: Double?) -> Color {
        guard let v, let t else { return Brand.accent }
        return v <= t ? Brand.ok : Brand.negative
    }
}
