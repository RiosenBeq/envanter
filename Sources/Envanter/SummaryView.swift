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

/// Dönem seçici (Özet ve İstatistikler ekranlarında ortak)
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

struct SummaryView: View {
    @EnvironmentObject var store: AppStore
    @State private var preset: RangePreset = .thisMonth
    @State private var from = DateKey.startOfMonth(DateKey.today())
    @State private var to = DateKey.endOfMonth(DateKey.today())
    @State private var selected: String?
    @State private var onlyProblems = false

    var body: some View {
        let all = store.engine.summary(from: from, to: to)
        let rows = onlyProblems ? all.filter { $0.daysCounted > 0 && $0.severity.isProblem } : all
        let daysInRange = store.engine.datesWithData.filter { $0 >= from && $0 <= to }.count
        VStack(spacing: 0) {
            controls(daysInRange: daysInRange)
            Divider()
            if all.allSatisfy({ $0.daysCounted == 0 }) {
                EmptyStateView(icon: "chart.bar.xaxis", title: "Bu dönemde sayılmış gün yok",
                               message: "Özet, kapanış sayımı girilmiş günlerden hesaplanır. Günlük Sayım ekranında sayımları girin ya da tarih aralığını değiştirin.")
            } else {
                kpis(all)
                header
                Divider()
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                            row(r).background(selected == r.id ? Brand.accent.opacity(0.12) : (i % 2 == 0 ? Color.clear : Color.primary.opacity(0.03)))
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
        .navigationTitle("Özet ve Raporlar")
    }

    private func controls(daysInRange: Int) -> some View {
        HStack(spacing: 14) {
            RangePicker(preset: $preset, from: $from, to: $to)
            Text("\(daysInRange) günlük kayıt").foregroundStyle(.secondary)
            Toggle("Yalnızca sorunlu kalemler", isOn: $onlyProblems)
            Spacer()
            Button { store.exportHistoryExcel(from: from, to: to) } label: {
                Label("Excel'e Aktar", systemImage: "square.and.arrow.up")
            }.buttonStyle(SoftButtonStyle())
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    private func kpis(_ rows: [Engine.SummaryRow]) -> some View {
        let counted = rows.filter { $0.daysCounted > 0 }
        let problems = counted.filter { $0.severity.isProblem }.count
        // Kayıp, İstatistikler ekranıyla aynı tanım: tolerans dışı fazla çıkış olan günlerin toplamı (mahsupsuz)
        let loss = counted.reduce(0) { $0 + $1.shortageValue }
        let net = counted.compactMap { $0.diffValue }.reduce(0, +)
        let worst = counted.filter { $0.shortageValue > 0 }.max { $0.shortageValue < $1.shortageValue }
        let hasCosts = counted.contains { $0.diffValue != nil }
        return StatRow {
            StatCard(title: "Sayılan kalem", value: "\(counted.count) / \(rows.count)", icon: "checklist", color: Brand.accent)
            StatCard(title: "Sorunlu kalem", value: "\(problems)", detail: "Dönem toplamında tolerans dışı",
                     icon: "exclamationmark.triangle", color: problems == 0 ? Brand.ok : Brand.negative, info: .tolerance)
            StatCard(title: "Dönem kaybı", value: hasCosts ? Fmt.money(loss) : "—",
                     detail: hasCosts ? "Net fark: \(Fmt.money(net))" : "Birim maliyet tanımlı değil",
                     icon: "turkishlirasign.circle", color: loss > 0 ? Brand.negative : Brand.ok, info: .loss)
            StatCard(title: "En büyük kayıp", value: worst?.item.name ?? "—",
                     detail: worst.map { r in "\(Fmt.money(r.shortageValue)) · \(r.shortageDays) gün fazla çıkış" } ?? "Tolerans dışı fazla çıkış yok",
                     icon: "arrow.down.right.circle", color: Brand.negative, info: .loss)
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
    }

    private let widths: [CGFloat] = [80, 80, 86, 84, 86, 80, 90, 92, 96]
    private let titles = ["İlk Açılış", "Toplam Gelen", "Net Transfer", "Son Kapanış", "Toplam Satılan",
                          "Toplam Zayi", "Fiili Tüketim", "Toplam Fark", "Fark Tutarı"]
    private let terms: [Term] = [.opening, .incoming, .transfer, .closing, .sold, .waste, .actualUsage, .diff, .netDiff]

    private var header: some View {
        HStack(spacing: 0) {
            Text("Ürün").frame(minWidth: 130, maxWidth: .infinity, alignment: .leading).padding(.leading, 12)
            ForEach(Array(titles.enumerated()), id: \.offset) { i, t in
                Text(t).frame(width: widths[i]).explains(terms[i])
            }
        }
        .font(.caption.weight(.semibold)).multilineTextAlignment(.center)
        .padding(.vertical, 8).padding(.trailing, 8)
        .background(Color.primary.opacity(0.05))
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
            cell(counted ? f(r.transferIn - r.transferOut) : "—", 2)
                .help("Gelen transfer \(f(r.transferIn)) − giden transfer \(f(r.transferOut))")
            cell(counted ? r.lastClosing.map(f) ?? "—" : "—", 3)
            cell(counted ? f(r.sold) : "—", 4)
            cell(counted ? f(r.waste) : "—", 5)
            cell(counted ? f(r.actual) : "—", 6, bold: true)
            Group {
                if counted {
                    let color = Brand.color(for: r.severity)
                    Text(r.severity == .zero ? "0" : f(r.diff)).monospacedDigit().fontWeight(.semibold)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .foregroundStyle(color).background(Capsule().fill(color.opacity(0.13)))
                } else { Text("—").foregroundStyle(.tertiary) }
            }.frame(width: widths[7])
            cell(counted ? (r.diffValue.map { Fmt.money($0) } ?? "—") : "—", 8)
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
                Button("Ayrıntılı analiz") { store.openItemAnalysis(r.item.id) }.buttonStyle(.link)
            }
            Chart {
                ForEach(r.daily, id: \.date) { d in
                    BarMark(x: .value("Gün", DateKey.date(from: d.date) ?? Date(), unit: .day),
                            y: .value("Fark", d.diff))
                        .foregroundStyle(Brand.color(for: r.item.severity(of: d.diff)))
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
