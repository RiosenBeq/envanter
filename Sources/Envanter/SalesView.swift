import SwiftUI
import EnvanterCore

private enum SalesFilter: String, CaseIterable, Identifiable {
    case all = "Tümü", tracked = "Reçeteli", untracked = "Stok etkisi yok", unknown = "Reçete tanımsız"
    var id: String { rawValue }
}

struct SalesView: View {
    @EnvironmentObject var store: AppStore
    @State private var search = ""
    @State private var filter: SalesFilter = .all

    var body: some View {
        let date = store.selectedDate
        let day = store.data.days[date]
        let sales = day?.sales ?? []
        let analysis = store.engine.analyze(sales: sales)
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                DateNavigator()
                Spacer()
                Button { store.pickAndImportFile() } label: { Label("Dosyadan Aktar", systemImage: "doc.badge.plus") }
                    .buttonStyle(PrimaryButtonStyle())
                Button { store.beginPasteImport() } label: { Label("Panodan Yapıştır", systemImage: "doc.on.clipboard") }
                    .buttonStyle(SoftButtonStyle())
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            Divider()

            if sales.isEmpty {
                EmptyStateView(icon: "cart", title: "Bu gün için satış verisi yok",
                               message: "ModPos satış raporunu (.xlsx) aktarın. Her ürünün reçetesine göre hangi hammaddeden ne kadar düşüldüğü burada görünür.")
            } else {
                let lines = filtered(sales, analysis: analysis)
                chips(sales: sales, analysis: analysis)
                HStack(spacing: 12) {
                    Picker("", selection: $filter) {
                        ForEach(SalesFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 520)
                    Spacer()
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Ürün veya kod ara", text: $search).textFieldStyle(.plain).frame(width: 190)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.07)))
                }
                .padding(.horizontal, 20).padding(.bottom, 8)

                Table(lines) {
                    TableColumn("Kod") { l in Text(l.code).monospacedDigit().foregroundStyle(.secondary) }.width(70)
                    TableColumn("Ürün") { l in Text(l.name).lineLimit(1) }
                    TableColumn("Adet") { l in
                        Text(Fmt.number(l.qty, maxFraction: 2)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                    }.width(70)
                    TableColumn("Durum") { l in statusPill(analysis.status[l.code] ?? .unknown) }.width(130)
                    TableColumn("Stoktan düşen") { l in
                        Text(effect(of: l, status: analysis.status[l.code] ?? .unknown))
                            .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                    TableColumn("") { l in
                        if (analysis.status[l.code] ?? .unknown) == .unknown {
                            Button("Reçete tanımla") { store.startNewProduct(from: l) }.buttonStyle(SoftButtonStyle(tint: Brand.warn))
                                .disabled(!store.canEditCatalog)
                                .help(store.canEditCatalog ? "Bu ürün için reçete oluştur" : CloudPermission.catalogReadOnlyNote)
                        } else {
                            Button("Reçeteyi aç") { store.recipeSelection = l.code; store.section = .recipes }
                                .buttonStyle(.link)
                        }
                    }.width(130)
                }
            }
        }
        .navigationTitle("Satış Dökümü")
    }

    private func filtered(_ sales: [SaleLine], analysis: SalesAnalysis) -> [SaleLine] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased(with: Locale(identifier: "tr_TR"))
        return sales
            .filter { l in
                switch filter {
                case .all: return true
                case .tracked: return analysis.status[l.code] == .tracked
                case .untracked: return analysis.status[l.code] == .untracked
                case .unknown: return analysis.status[l.code] == .unknown
                }
            }
            .filter { q.isEmpty || l(q, $0) }
            .sorted { $0.qty > $1.qty }
    }

    private func l(_ q: String, _ line: SaleLine) -> Bool {
        line.code.contains(q) || line.name.lowercased(with: Locale(identifier: "tr_TR")).contains(q)
    }

    private func chips(sales: [SaleLine], analysis: SalesAnalysis) -> some View {
        HStack(spacing: 10) {
            chip("\(sales.count)", "ürün satırı", Brand.positive)
            chip(Fmt.number(sales.reduce(0) { $0 + $1.qty }, maxFraction: 0), "toplam adet", .secondary)
            chip("\(analysis.trackedLines.count)", "reçeteli", Brand.ok)
            chip("\(analysis.untrackedLines.count)", "stok etkisi yok", .secondary)
            chip("\(analysis.unknownLines.count)", "reçete tanımsız (\(Fmt.number(analysis.unknownQty, maxFraction: 0)) adet)",
                 analysis.unknownLines.isEmpty ? Brand.ok : Brand.warn)
            Spacer()
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
    }

    private func chip(_ big: String, _ small: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Text(big).font(.title3.weight(.bold)).foregroundStyle(color)
            Text(small).font(.callout).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.10)))
    }

    @ViewBuilder private func statusPill(_ s: LineStatus) -> some View {
        switch s {
        case .tracked: Pill(text: "Reçeteli", color: Brand.ok)
        case .untracked: Pill(text: "Stok etkisi yok", color: .secondary)
        case .unknown: Pill(text: "Reçete tanımsız", color: Brand.warn)
        }
    }

    private func effect(of line: SaleLine, status: LineStatus) -> String {
        guard status == .tracked, let p = store.product(line.code) else { return "" }
        let parts: [String] = store.data.items.compactMap { item in
            guard let per = p.amounts[item.id], per != 0 else { return nil }
            return "\(item.name) \(Fmt.number(line.qty * per * item.factor, maxFraction: item.maxFraction)) \(item.unit.lowercased())"
        }
        return parts.joined(separator: " · ")
    }
}
