import SwiftUI
import Charts
import EnvanterCore

/// Pano: seçili günün durumu, son 14 günün eğilimi ve dikkat gerektiren kalemler.
struct OverviewView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        let date = store.selectedDate
        let engine = store.engine
        let result = engine.calc(date: date)
        let rows = result.rows
        let analysis = result.analysis
        let o = engine.overview(date: date, rows: rows, analysis: analysis)
        let trend = engine.trend(endingAt: date, days: 14)
        let hasCosts = engine.activeItems.contains { $0.unitCost != nil }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center) {
                    DateNavigator()
                    Spacer()
                }
                cards(o, hasCosts: hasCosts)
                HStack(alignment: .top, spacing: 16) {
                    trendCard(trend, hasCosts: hasCosts).frame(maxWidth: .infinity)
                    actions(o).frame(width: 290)
                }
                attention(rows: rows, analysis: analysis, overview: o)
            }
            .padding(22)
        }
        .navigationTitle("Genel Bakış")
    }

    // MARK: Kartlar

    private func cards(_ o: DayOverview, hasCosts: Bool) -> some View {
        StatRow(spacing: 14) {
            StatCard(title: "Sayım", value: "\(o.countedItems) / \(o.itemCount)",
                     detail: o.isFullyCounted ? "Tüm kalemler sayıldı" : (o.hasAnyCount ? "\(o.itemCount - o.countedItems) kalem bekliyor" : "Bugün henüz sayım girilmedi"),
                     icon: "checklist", color: o.isFullyCounted ? Brand.ok : Brand.accent,
                     progress: o.itemCount > 0 ? Double(o.countedItems) / Double(o.itemCount) : 0)
            StatCard(title: "Satış raporu", value: o.hasSales ? (o.salesLines > 0 ? "\(o.salesLines) satır" : "Excel'den") : "Yok",
                     detail: o.unknownLines > 0 ? "\(o.unknownLines) ürünün reçetesi tanımsız" : (o.hasSales ? "Tüm ürünler eşleşti" : "ModPos raporunu aktarın"),
                     icon: "cart", color: o.hasSales ? (o.unknownLines > 0 ? Brand.warn : Brand.ok) : Brand.negative)
            StatCard(title: "Sorunlu kalem", value: o.hasAnyCount ? "\(o.problemItems)" : "—",
                     detail: o.hasAnyCount ? (o.problemItems == 0 ? "Farklar tolerans içinde" : "\(o.shortageItems) kalemde fazla çıkış") : "Sayım girilince hesaplanır",
                     icon: "exclamationmark.triangle", color: o.problemItems == 0 ? Brand.ok : Brand.negative)
            StatCard(title: "Günün kaybı", value: hasCosts ? (o.hasAnyCount ? Fmt.money(o.lossValue) : "—") : "—",
                     detail: hasCosts ? "Fazla çıkışların maliyeti (net: \(Fmt.money(o.netValue)))" : "Stok Kalemleri'nde birim maliyet girin",
                     icon: "turkishlirasign.circle", color: o.lossValue > 0 ? Brand.negative : Brand.ok)
        }
    }

    // MARK: Eğilim

    private func trendCard(_ trend: [DayOverview], hasCosts: Bool) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(hasCosts ? "Son 14 gün · günlük kayıp (₺)" : "Son 14 gün · sorunlu kalem sayısı").font(.headline)
                    Spacer()
                    let counted = trend.filter { $0.hasAnyCount }.count
                    Text("\(counted) günde sayım var").font(.callout).foregroundStyle(.secondary)
                }
                Chart {
                    ForEach(trend) { d in
                        BarMark(x: .value("Gün", DateKey.date(from: d.date) ?? Date(), unit: .day),
                                y: .value(hasCosts ? "Kayıp" : "Kalem", hasCosts ? d.lossValue : Double(d.problemItems)))
                            .foregroundStyle(d.date == store.selectedDate ? Brand.accent : Brand.negative.opacity(0.75))
                            .cornerRadius(3)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 2)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    }
                }
                .frame(height: 170)
                HStack(spacing: 14) {
                    let total = trend.reduce(0) { $0 + $1.lossValue }
                    if hasCosts { Label("Toplam: \(Fmt.money(total))", systemImage: "sum").font(.callout) }
                    let unlocked = trend.filter { $0.hasAnyCount && !$0.isLocked }.count
                    if unlocked > 0 {
                        Label("\(unlocked) sayılmış gün henüz kapatılmadı", systemImage: "lock.open").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: Hızlı işlemler

    private func actions(_ o: DayOverview) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Hızlı işlemler").font(.headline)
                Button { store.section = .daily } label: {
                    Label(o.hasAnyCount ? "Sayıma devam et" : "Sayıma başla", systemImage: "checklist").frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(PrimaryButtonStyle())
                Button { store.pickAndImportFile() } label: {
                    Label("Satış raporu aktar…", systemImage: "doc.badge.plus").frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(SoftButtonStyle())
                Button { store.beginPasteImport() } label: {
                    Label("Panodan satış yapıştır", systemImage: "doc.on.clipboard").frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(SoftButtonStyle())
                Button { store.section = .orders } label: {
                    Label("Sipariş önerisi", systemImage: "shippingbox.and.arrow.backward").frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(SoftButtonStyle())
                Button { store.exportDayExcel() } label: {
                    Label("Günü Excel'e aktar…", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(SoftButtonStyle())
            }
        }
    }

    // MARK: Dikkat gerektirenler

    @ViewBuilder
    private func attention(rows: [ItemCalc], analysis: SalesAnalysis, overview o: DayOverview) -> some View {
        let engine = store.engine
        let problems = rows.filter { $0.severity?.isProblem == true }
            .sorted { abs($0.diffValue ?? $0.diff ?? 0) > abs($1.diffValue ?? $1.diff ?? 0) }
        let low = rows.filter { $0.belowMinimum }
        if problems.isEmpty && low.isEmpty && analysis.unknownLines.isEmpty {
            Card {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill").font(.title2).foregroundStyle(Brand.ok)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Dikkat gerektiren bir şey yok").font(.headline)
                        Text(o.hasAnyCount ? "Sayılan kalemlerde tolerans dışı fark ve kritik seviye altında stok yok."
                                           : "Sayım ve satış girildikçe sorunlu kalemler burada listelenir.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        } else {
            HStack(alignment: .top, spacing: 16) {
                if !problems.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Tolerans dışı farklar", systemImage: "exclamationmark.triangle.fill")
                                .font(.headline).foregroundStyle(Brand.negative)
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
                            Button("Günlük envantere git") { store.section = .daily }.buttonStyle(.link)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                VStack(spacing: 16) {
                    if !low.isEmpty {
                        Card {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Kritik seviyenin altında", systemImage: "arrow.down.to.line")
                                    .font(.headline).foregroundStyle(Brand.warn)
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
                                Button("Sipariş önerisini aç") { store.section = .orders }.buttonStyle(.link)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if !analysis.unknownLines.isEmpty {
                        Card {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Reçetesi tanımsız satışlar", systemImage: "questionmark.diamond.fill")
                                    .font(.headline).foregroundStyle(Brand.warn)
                                ForEach(analysis.unknownLines.sorted { $0.qty > $1.qty }.prefix(6)) { l in
                                    HStack {
                                        Text(l.name.isEmpty ? l.code : l.name).lineLimit(1)
                                        Spacer()
                                        Text("\(Fmt.number(l.qty, maxFraction: 0)) adet").monospacedDigit().foregroundStyle(.secondary)
                                    }
                                    .font(.callout)
                                }
                                Button("Satış dökümünde reçete tanımla") { store.section = .sales }.buttonStyle(.link)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}
