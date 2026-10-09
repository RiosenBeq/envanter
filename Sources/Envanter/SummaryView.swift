import SwiftUI
import Charts
import EnvanterCore

private enum RangePreset: String, CaseIterable, Identifiable {
    case last7 = "Son 7 gün", thisMonth = "Bu ay", lastMonth = "Geçen ay", all = "Tümü", custom = "Özel"
    var id: String { rawValue }
}

struct SummaryView: View {
    @EnvironmentObject var store: AppStore
    @State private var preset: RangePreset = .thisMonth
    @State private var from = DateKey.startOfMonth(DateKey.today())
    @State private var to = DateKey.endOfMonth(DateKey.today())
    @State private var selected: String?

    private func bind(_ get: @escaping () -> String, _ set: @escaping (String) -> Void) -> Binding<Date> {
        Binding(get: { DateKey.date(from: get()) ?? Date() }, set: { set(DateKey.string(from: $0)); preset = .custom })
    }

    var body: some View {
        let rows = store.engine.summary(from: from, to: to)
        let daysInRange = store.engine.datesWithData.filter { $0 >= from && $0 <= to }.count
        VStack(spacing: 0) {
            controls(daysInRange: daysInRange)
            Divider()
            if rows.allSatisfy({ $0.daysCounted == 0 }) {
                EmptyStateView(icon: "chart.bar.xaxis", title: "Bu dönemde sayılmış gün yok",
                               message: "Özet, kapanış sayımı girilmiş günlerden hesaplanır. Günlük Envanter ekranında sayımları girin ya da tarih aralığını değiştirin.")
            } else {
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
                if let sel = rows.first(where: { $0.id == selected }) {
                    Divider()
                    chart(sel)
                } else {
                    Divider()
                    Text("Günlük farkı görmek için bir satıra tıklayın.")
                        .font(.callout).foregroundStyle(.secondary).padding(10)
                }
            }
        }
        .navigationTitle("Özet ve Raporlar")
        .onChange(of: preset) { _, p in apply(p) }
    }

    private func controls(daysInRange: Int) -> some View {
        HStack(spacing: 14) {
            Picker("", selection: $preset) {
                ForEach(RangePreset.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 360)
            DatePicker("", selection: bind({ from }, { from = $0 }), displayedComponents: .date).labelsHidden()
            Text("–")
            DatePicker("", selection: bind({ to }, { to = $0 }), displayedComponents: .date).labelsHidden()
            Text("\(daysInRange) günlük kayıt").foregroundStyle(.secondary)
            Spacer()
            Button { store.exportHistoryExcel(from: from, to: to) } label: {
                Label("Excel'e Aktar", systemImage: "square.and.arrow.up")
            }.buttonStyle(SoftButtonStyle())
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    private func apply(_ p: RangePreset) {
        let today = DateKey.today()
        switch p {
        case .last7: from = DateKey.addDays(-6, to: today); to = today
        case .thisMonth: from = DateKey.startOfMonth(today); to = DateKey.endOfMonth(today)
        case .lastMonth:
            from = DateKey.startOfPreviousMonth(today); to = DateKey.endOfMonth(from)
        case .all:
            let d = store.engine.datesWithData
            from = d.first ?? today; to = d.last ?? today
        case .custom: break
        }
    }

    private let widths: [CGFloat] = [64, 90, 90, 100, 100, 90, 92, 92, 100, 100]
    private let titles = ["Gün", "İlk Açılış", "Toplam Gelen", "Gelen Transfer (+)", "Giden Transfer (−)",
                          "Son Kapanış", "Toplam Satılan", "Toplam Zaiyat", "Fiili Tüketim", "Toplam Fark"]

    private var header: some View {
        HStack(spacing: 0) {
            Text("Ürün").frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 12)
            ForEach(Array(titles.enumerated()), id: \.offset) { i, t in
                Text(t).frame(width: widths[i])
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
                Text(r.item.name).fontWeight(.medium)
                Text(r.item.unit.lowercased()).font(.caption2).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 12)
            cell("\(r.daysCounted)", 0)
            cell(counted ? r.firstOpening.map(f) ?? "—" : "—", 1)
            cell(counted ? f(r.incoming) : "—", 2)
            cell(counted ? f(r.transferIn) : "—", 3)
            cell(counted ? f(r.transferOut) : "—", 4)
            cell(counted ? r.lastClosing.map(f) ?? "—" : "—", 5)
            cell(counted ? f(r.sold) : "—", 6)
            cell(counted ? f(r.waste) : "—", 7)
            cell(counted ? f(r.actual) : "—", 8, bold: true)
            Group {
                if counted {
                    let zero = r.diff.isZero(maxFraction: r.item.maxFraction)
                    let color = zero ? Brand.ok : (r.diff < 0 ? Brand.negative : Brand.positive)
                    Text(zero ? "0" : f(r.diff)).monospacedDigit().fontWeight(.semibold)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .foregroundStyle(color).background(Capsule().fill(color.opacity(0.13)))
                } else { Text("—").foregroundStyle(.tertiary) }
            }.frame(width: widths[9])
        }
        .frame(height: 38).padding(.trailing, 8)
    }

    private func cell(_ text: String, _ i: Int, bold: Bool = false) -> some View {
        Text(text).monospacedDigit().fontWeight(bold ? .semibold : .regular)
            .foregroundStyle(text == "—" ? Color.secondary.opacity(0.5) : Color.primary)
            .frame(width: widths[i])
    }

    private func chart(_ r: Engine.SummaryRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(r.item.name) — günlük fark (\(r.item.unit.lowercased()))").font(.headline)
            Chart {
                ForEach(r.daily, id: \.date) { d in
                    BarMark(x: .value("Gün", DateKey.date(from: d.date) ?? Date(), unit: .day),
                            y: .value("Fark", d.diff))
                        .foregroundStyle(d.diff < 0 ? Brand.negative : Brand.positive)
                }
                RuleMark(y: .value("Sıfır", 0)).foregroundStyle(.secondary)
            }
            .frame(height: 150)
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
    }
}
