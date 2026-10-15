import SwiftUI
import Charts
import EnvanterCore

enum RangePreset: String, CaseIterable, Identifiable {
    case last7 = "Son 7 gün", last30 = "Son 30 gün", thisMonth = "Bu ay", lastMonth = "Geçen ay", all = "Tümü", custom = "Özel"
    var id: String { rawValue }

    /// Ön tanımlı aralık (Özel için nil)
    func range(today: String, dataDates: [String]) -> (from: String, to: String)? {
        switch self {
        case .last7: return (DateKey.addDays(-6, to: today), today)
        case .last30: return (DateKey.addDays(-29, to: today), today)
        case .thisMonth: return (DateKey.startOfMonth(today), DateKey.endOfMonth(today))
        case .lastMonth:
            let f = DateKey.startOfPreviousMonth(today)
            return (f, DateKey.endOfMonth(f))
        case .all: return (dataDates.first ?? today, dataDates.last ?? today)
        case .custom: return nil
        }
    }
}

/// Dönem seçici (Raporlar ekranı: Dönem Özeti ve Kalem Analizi aynı dönemi kullanır)
struct RangePicker: View {
    @EnvironmentObject var store: AppStore
    @Binding var preset: RangePreset
    @Binding var from: String
    @Binding var to: String

    var body: some View {
        HStack(spacing: 10) {
            Picker("", selection: $preset) {
                ForEach(RangePreset.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().frame(width: 130)
            DatePicker("", selection: bind({ from }, { from = $0 }), displayedComponents: .date).labelsHidden()
            Text("–")
            DatePicker("", selection: bind({ to }, { to = $0 }), displayedComponents: .date).labelsHidden()
        }
        .onChange(of: preset) { _, p in
            if let r = p.range(today: DateKey.today(), dataDates: store.engine.datesWithData) { from = r.from; to = r.to }
        }
    }

    private func bind(_ get: @escaping () -> String, _ set: @escaping (String) -> Void) -> Binding<Date> {
        Binding(get: { DateKey.date(from: get()) ?? Date() }, set: { set(DateKey.string(from: $0)); preset = .custom })
    }
}

/// Raporlar: seçilen dönemde kalem kalem miktar özeti (Dönem Özeti, Excel'deki "Özet" sayfası) ve tek bir kalemin
/// satış + zayi ile gerçek kullanımı, günlük farkı ve stok seviyesi (Kalem Analizi). Tutar yoktur: tüm değerler kalemin
/// biriminde (adet / kg). Sekme `store.reportsTab`'da, Kalem Analizi'ndeki kalem `store.reportItem`'da tutulur
/// (Dönem Özeti'ndeki "Ayrıntılı analiz" bağlantısı ikisini birden değiştirir); iki sekme aynı dönemi kullanır.
struct ReportsView: View {
    @ObservedObject var store: AppStore
    @State private var preset: RangePreset = .thisMonth
    @State private var from = DateKey.startOfMonth(DateKey.today())
    @State private var to = DateKey.endOfMonth(DateKey.today())

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Picker("", selection: $store.reportsTab) {
                    ForEach(ReportsTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 280)
                RangePicker(preset: $preset, from: $from, to: $to)
                Spacer()
                Button { store.exportHistoryExcel(from: from, to: to) } label: {
                    Label("Excel'e Aktar", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(SoftButtonStyle())
                .help("Seçili dönemin günlük envanteri (Alımlar), Özet ve Günlük Durum sayfaları; varsa Notlar, Zayi Kayıtları ve Ekip")
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            switch store.reportsTab {
            case .summary:
                PeriodSummaryTab(store: store, from: from, to: to)
            case .item:
                ScrollView {
                    ItemAnalysisView(store: store, from: from, to: to).padding(20)
                }
            }
        }
        .navigationTitle("Raporlar")
        .onAppear {
            // Seçili gün dönemin dışındaysa seçili günle biten 30 gün gösterilir (ör. geçmiş bir günden gelince)
            if let r = store.reportRange(containingSelectedDate: from, to) { from = r.from; to = r.to; preset = .custom }
        }
    }
}

// MARK: - Dönem özeti

/// Dönem Özeti: kalem kalem ilk Devreden, Giren, Çıkan, son Kalan, satılan, zayi, gerçek kullanım, toplam fark ve
/// fazla çıkış. Yalnızca Kalan'ı sayılmış günler toplanır (Fark = Satılan + Zayi − Gerçek kullanım dönemde de tutar). Satıra
/// tıklayınca günlük fark grafiği açılır.
private struct PeriodSummaryTab: View {
    @ObservedObject var store: AppStore
    let from: String
    let to: String
    @State private var selected: String?
    @State private var onlyProblems = false

    var body: some View {
        let all = store.engine.summary(from: from, to: to)
        // Sorunlu: dönem farkı tolerans dışı ya da en az bir gün fazla çıkış (komut satırı raporu ve web paneliyle aynı)
        let rows = onlyProblems ? all.filter { $0.daysCounted > 0 && Self.isProblem($0) } : all
        let daysInRange = store.engine.datesWithData.filter { $0 >= from && $0 <= to }.count
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Text("\(daysInRange) günlük kayıt").foregroundStyle(.secondary)
                Toggle("Yalnızca sorunlu kalemler", isOn: $onlyProblems)
                    .help("Dönem farkı tolerans dışı olan ya da en az bir gün fazla çıkış görülen kalemler")
                Spacer()
            }
            .padding(.horizontal, 20).padding(.top, 10)
            if all.allSatisfy({ $0.daysCounted == 0 }) {
                EmptyStateView(icon: "chart.bar.xaxis", title: "Bu dönemde sayılmış gün yok",
                               message: "Özet, Kalan'ı sayılmış günlerden hesaplanır. Günlük Sayım ekranında sayımları girin ya da tarih aralığını değiştirin.")
            } else {
                kpis(all)
                header
                Divider()
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { _, r in
                            // Zebra yerine 1 px satır ayırıcı; seçili satır marka tonunda
                            row(r).background(selected == r.id ? Brand.selection : Color.clear)
                                .rowSeparator(leading: 12)
                                .contentShape(Rectangle())
                                .onTapGesture { selected = (selected == r.id ? nil : r.id) }
                        }
                    }
                }
                Divider()
                if let sel = all.first(where: { $0.id == selected }) {
                    chart(sel)
                } else {
                    Text("Günlük farkı görmek için bir satıra tıklayın.")
                        .font(.callout).foregroundStyle(.secondary).padding(10)
                }
            }
        }
    }

    private static func isProblem(_ r: Engine.SummaryRow) -> Bool { r.severity.isProblem || r.shortageDays > 0 }

    private func kpis(_ rows: [Engine.SummaryRow]) -> some View {
        let counted = rows.filter { $0.daysCounted > 0 }
        let period = store.engine.periodStats(from: from, to: to)
        let problems = counted.filter { Self.isProblem($0) }.count
        // Fazla çıkış: tolerans dışı negatif farkı olan günlerin miktarı (az çıkışlarla mahsup edilmez); en sık olan önde
        let shortages = counted.filter { $0.shortageQty > 0 }
            .map { InventoryReport.Shortage(item: $0.item, qty: $0.shortageQty, days: $0.shortageDays) }
            .sorted(by: InventoryReport.shortageOrder)
        let top = shortages.first
        let topDetail = top.map { "\($0.days) gün · \(Fmt.number($0.qty, maxFraction: $0.item.maxFraction)) \($0.item.unit.lowercased())" }
        return StatRow {
            StatCard(title: "Sayılan kalem", value: "\(counted.count) / \(rows.count)",
                     detail: "\(period.countedDays) sayılmış gün · \(period.salesDays) gün satış raporu",
                     icon: "checklist", color: Brand.accent)
            StatCard(title: "Sorunlu kalem", value: "\(problems)", detail: "Dönem farkı tolerans dışı ya da fazla çıkış günü olan",
                     icon: "exclamationmark.triangle", color: problems == 0 ? Brand.ok : Brand.negative, info: .tolerance)
            StatCard(title: "Fazla çıkış olan kalem", value: "\(shortages.count)",
                     detail: shortages.isEmpty ? "Tolerans dışı fazla çıkış yok" : "Dönemde en az bir gün tolerans dışı fazla çıkan",
                     icon: "arrow.down.right.circle", color: shortages.isEmpty ? Brand.ok : Brand.negative, info: .shortage)
            StatCard(title: "En sık fazla çıkan", value: top?.item.name ?? "—",
                     detail: topDetail ?? "Tolerans dışı fazla çıkış yok",
                     icon: "flame", color: top == nil ? Brand.ok : Brand.negative, info: .shortage)
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
    }

    private let widths: [CGFloat] = [80, 80, 86, 84, 86, 80, 90, 92, 96]
    private let titles = ["İlk Devreden", "Toplam Giren", "Toplam Çıkan", "Son Kalan", "Toplam Satılan",
                          "Toplam Zayi", "Gerçek Kullanım", "Toplam Fark", "Fazla Çıkış"]
    private let terms: [Term] = [.opening, .incoming, .transferOut, .closing, .sold, .waste, .actualUsage, .diff, .shortage]

    private var header: some View {
        HStack(spacing: 0) {
            Text("Ürün").frame(minWidth: 130, maxWidth: .infinity, alignment: .leading).padding(.leading, 12)
            ForEach(Array(titles.enumerated()), id: \.offset) { i, t in
                Text(t).frame(width: widths[i]).explains(terms[i])
            }
        }
        .font(.caption.weight(.semibold)).multilineTextAlignment(.center)
        .padding(.vertical, 8).padding(.trailing, 8)
        .background(Brand.header)
    }

    private func row(_ r: Engine.SummaryRow) -> some View {
        let f: (Double) -> String = { Fmt.number($0, maxFraction: r.item.maxFraction) }
        let counted = r.daysCounted > 0
        return HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text(r.item.name).fontWeight(.medium).lineLimit(1)
                Text("\(r.item.unit.lowercased()) · \(r.daysCounted) gün" + (r.shortageDays > 0 ? " · \(r.shortageDays) gün fazla çıkış" : ""))
                    .font(.caption2).foregroundStyle(.secondary)
            }.frame(minWidth: 130, maxWidth: .infinity, alignment: .leading).padding(.leading, 12)
            cell(counted ? r.firstOpening.map(f) ?? "—" : "—", 0)
            cell(counted ? f(r.incoming) : "—", 1)
            // Çıkan (başka şubeden gelen varsa ipucunda; Gerçek kullanım ikisini de hesaba katar)
            cell(counted ? f(r.transferOut) : "—", 2)
                .help(r.transferIn != 0 ? "\(CountText.transferOut) \(f(r.transferOut)) · \(CountText.transferIn) \(f(r.transferIn))" : Term.transferOut.text)
            cell(counted ? r.lastClosing.map(f) ?? "—" : "—", 3)
            cell(counted ? f(r.sold) : "—", 4)
            cell(counted ? f(r.waste) : "—", 5)
            cell(counted ? f(r.actual) : "—", 6, bold: true)
            Group {
                if counted {
                    let color = Brand.color(for: r.severity)
                    Text(r.severity == .zero ? "0" : f(r.diff)).monospacedDigit().fontWeight(.semibold)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .foregroundStyle(Brand.ink(for: color)).background(Shapes.control.fill(color.opacity(0.12)))
                } else { Text("—").foregroundStyle(.tertiary) }
            }.frame(width: widths[7])
            // Fazla çıkış: tolerans dışı fazla çıkan günlerin toplamı (pozitif miktar, kalemin biriminde)
            Group {
                if counted && r.shortageQty > 0 {
                    Text(f(r.shortageQty)).monospacedDigit().fontWeight(.semibold).foregroundStyle(Brand.negative)
                        .help("\(r.shortageDays) günde toplam \(f(r.shortageQty)) \(r.item.unit.lowercased()) fazla çıkış")
                } else {
                    Text("—").foregroundStyle(Color.secondary.opacity(0.5))
                }
            }
            .lineLimit(1).minimumScaleFactor(0.8)
            .frame(width: widths[8])
        }
        .frame(height: 40).padding(.trailing, 8)
    }

    private func cell(_ text: String, _ i: Int, bold: Bool = false) -> some View {
        Text(text).monospacedDigit().fontWeight(bold ? .semibold : .regular)
            .lineLimit(1).minimumScaleFactor(0.8)
            .foregroundStyle(text == "—" ? Color.secondary.opacity(0.5) : Color.primary)
            .frame(width: widths[i])
    }

    private func chart(_ r: Engine.SummaryRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(r.item.name) — günlük fark (\(r.item.unit.lowercased()))").font(.headline)
                Spacer()
                Button("Ayrıntılı analiz") { store.openItemAnalysis(itemID: r.item.id) }.buttonStyle(.link)
            }
            Chart {
                ForEach(r.daily, id: \.date) { d in
                    BarMark(x: .value("Gün", DateKey.date(from: d.date) ?? Date(), unit: .day),
                            y: .value("Fark", d.diff))
                        .foregroundStyle(Brand.color(for: r.item.severity(of: d.diff)))
                        .cornerRadius(Radius.tiny)
                }
                RuleMark(y: .value("Sıfır", 0)).foregroundStyle(.secondary)
                if let t = r.item.tolerance, t > 0 {
                    RuleMark(y: .value("Tolerans", -t)).foregroundStyle(Brand.warn.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    RuleMark(y: .value("Tolerans", t)).foregroundStyle(Brand.warn.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
            .frame(height: 150)
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
    }
}

// MARK: - Kalem analizi

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

/// Kalem Analizi: seçili kalemin dönemdeki ortalama satış + zayi ve gerçek kullanımı, toplam farkı, tutarlılığı ve grafikleri
private struct ItemAnalysisView: View {
    @ObservedObject var store: AppStore
    let from: String
    let to: String

    var body: some View {
        let items = store.engine.activeItems
        let selectedID = selectedItemID(in: items)
        let item = store.engine.itemsByID[selectedID]
        let series = store.engine.itemSeries(itemID: selectedID, from: from, to: to)
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Picker("Kalem", selection: Binding(get: { selectedID }, set: { store.reportItem = $0 })) {
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
            } else {
                EmptyStateView(icon: "shippingbox", title: "Aktif stok kalemi yok",
                               message: "Stok Kalemleri ekranında kalem ekleyin ya da gizlenmiş bir kalemi yeniden aktif yapın.")
                    .frame(height: 260)
            }
        }
    }

    /// Seçili kalem (`store.reportItem`); seçilmemişse ya da artık aktif değilse ilk aktif kalem
    private func selectedItemID(in items: [Item]) -> String {
        if let id = store.reportItem, items.contains(where: { $0.id == id }) { return id }
        return items.first?.id ?? ""
    }

    private func itemCards(_ item: Item, _ s: [ItemDayPoint]) -> some View {
        let counted = s.filter { $0.actual != nil }
        let avgActual = counted.isEmpty ? nil : counted.reduce(0) { $0 + ($1.actual ?? 0) } / Double(counted.count)
        let avgExpected = s.isEmpty ? 0 : s.reduce(0) { $0 + $1.expected } / Double(s.count)
        let totalDiff = counted.reduce(0) { $0 + ($1.diff ?? 0) }
        let shortageDays = counted.filter { item.severity(of: $0.diff ?? 0) == .shortage }.count
        let accuracy = counted.isEmpty ? nil : Double(counted.filter { item.severity(of: $0.diff ?? 0).isProblem == false }.count) / Double(counted.count)
        let u = item.unit.lowercased()
        return StatRow {
            StatCard(title: "Ort. satış + zayi", value: "\(Fmt.number(avgExpected, maxFraction: item.maxFraction)) \(u)",
                     detail: "Reçeteye göre, günlük", icon: "function", color: Brand.positive, info: .expectedUsage)
            StatCard(title: "Ort. gerçek kullanım", value: avgActual.map { "\(Fmt.number($0, maxFraction: item.maxFraction)) \(u)" } ?? "—",
                     detail: "\(counted.count) sayılmış gün", icon: "scalemass", color: Brand.accent, info: .actualUsage)
            StatCard(title: "Toplam fark", value: "\(Fmt.number(totalDiff, maxFraction: item.maxFraction)) \(u)",
                     detail: shortageDays > 0 ? "\(shortageDays) gün fazla çıkış · eksi: eksik" : "Fazla çıkış günü yok · eksi: eksik",
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
        ChartCard(title: "\(item.name) · satış + zayi ve gerçek kullanım (\(item.unit.lowercased()))",
                  subtitle: "Satış + zayi: satış raporu × reçete, zayi dahil. Gerçek kullanım: sayımdan (Devreden + Giren + Şubeden gelen − Çıkan − Kalan).") {
            Chart {
                ForEach(series) { p in
                    BarMark(x: .value("Gün", day(p.date), unit: .day), y: .value("Miktar", p.expected))
                        .foregroundStyle(by: .value("Seri", "Satış + zayi"))
                        .opacity(0.55)
                        .cornerRadius(Radius.tiny)
                    if let a = p.actual {
                        LineMark(x: .value("Gün", day(p.date), unit: .day), y: .value("Miktar", a))
                            .foregroundStyle(by: .value("Seri", "Gerçek kullanım"))
                            .interpolationMethod(.monotone)
                        PointMark(x: .value("Gün", day(p.date), unit: .day), y: .value("Miktar", a))
                            .foregroundStyle(by: .value("Seri", "Gerçek kullanım"))
                    }
                }
            }
            .chartForegroundStyleScale(domain: ["Satış + zayi", "Gerçek kullanım"], range: [Brand.positive, Brand.accent])
            .chartLegend(position: .top, alignment: .leading)
            .frame(height: 230)
        }
    }
}

private struct DiffChart: View {
    let item: Item
    let series: [ItemDayPoint]

    var body: some View {
        ChartCard(title: "Günlük fark", subtitle: "Eksi: eksik (satışlara göre fazla çıkış) · artı: fazla", info: .diff) {
            Chart {
                ForEach(series.filter { $0.diff != nil }) { p in
                    BarMark(x: .value("Gün", day(p.date), unit: .day), y: .value("Fark", p.diff ?? 0))
                        .foregroundStyle(Brand.color(for: item.severity(of: p.diff ?? 0)))
                        .cornerRadius(Radius.tiny)
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
        ChartCard(title: "Stok seviyesi (Kalan)", subtitle: item.minStock.map { "Kesikli çizgi: kritik seviye \(Fmt.number($0, maxFraction: item.maxFraction))" } ?? "Kritik seviye tanımlı değil", info: .minStock) {
            Chart {
                ForEach(series.filter { $0.closing != nil }) { p in
                    AreaMark(x: .value("Gün", day(p.date), unit: .day), y: .value("Stok", p.closing ?? 0))
                        .foregroundStyle(Brand.accent.opacity(0.12))
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
