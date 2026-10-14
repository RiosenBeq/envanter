import SwiftUI
import EnvanterCore

private enum IW {
    static let active: CGFloat = 50
    static let unit: CGFloat = 96
    static let recipeUnit: CGFloat = 92
    static let factor: CGFloat = 92
    static let min: CGFloat = 88
    static let tol: CGFloat = 84
    static let estimate: CGFloat = 84
    static let delete: CGFloat = 36
}

struct ItemsView: View {
    @EnvironmentObject var store: AppStore
    @State private var newName = ""
    @State private var newUnit = "Adet"
    @State private var deleting: Item?
    /// Kalem arama (ad ya da kimlik; Günlük Sayım'daki aramayla aynı kural: `ItemSearch`); Gün → Kalem Ara (⌘F) bu ekran
    /// açıkken buraya odaklanır
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        let activeCount = store.data.items.filter { $0.active }.count
        // Kritik seviyesi girilmiş aktif kalem sayısı (sipariş önerisi ve uyarılar bunlar için çalışır)
        let withMin = store.data.items.filter { $0.active && ($0.minStock ?? 0) > 0 }.count
        // Tahmini stok bugün için: sayıldıysa kapanış, değilse son sayım + sonraki hareketler (≈)
        let estimates = Dictionary(store.engine.stockEstimates(date: DateKey.today()).map { ($0.itemID, $0) },
                                   uniquingKeysWith: { a, _ in a })
        // Eşik önerileri: seçili güne kadar son 28 günün sayım farkları ve tüketimi
        let suggestions = store.engine.thresholdSuggestions(asOf: store.selectedDate)
        let changes = ThresholdChange.changes(items: store.data.items, suggestions: suggestions)
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Stok Kalemleri").font(.title2.weight(.semibold))
                    Spacer()
                    if store.canEditCatalog {
                        Button { store.showThresholds = true } label: {
                            Label("Eşik önerileri (\(ThresholdChange.itemCount(changes)))", systemImage: "wand.and.stars")
                        }
                        .buttonStyle(SoftButtonStyle())
                        .help("Son \(Engine.thresholdLookbackDays) günün sayım farkları ve tüketimine göre tolerans ve kritik seviye önerileri")
                    }
                    Pill(text: "\(activeCount) aktif kalem · \(withMin) kalemde kritik seviye tanımlı", color: Brand.positive)
                }
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(ItemSearch.placeholder, text: $query)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .onExitCommand { query = "" }
                        .accessibilityLabel(ItemSearch.placeholder)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .help(ItemSearch.clearLabel)
                    }
                }
                .padding(.horizontal, 8)
                .frame(width: 240, height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(Brand.field))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Brand.line.opacity(0.6), lineWidth: 0.5))
                .help("Ada ya da kimliğe göre ara · aramadayken sıralama sürüklenemez · Esc: temizle")
                Text("Günlük Sayım ekranındaki satırlar bunlardır (90 Gr, Peynir, Patates…). Sırayı sürükleyerek değiştirebilir, kullanılmayanları gizleyebilirsiniz. \"Katsayı\", reçetedeki birimin envanter birimine çevrilmesidir (ör. 1 dilim peynir = 0,014 kg). Kritik seviye sipariş önerisini ve uyarıları, tolerans ise \"normal\" sayılan farkı belirler.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !store.canEditCatalog { ReadOnlyNote() }
            }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            HStack(spacing: 0) {
                Text("Aktif").frame(width: IW.active)
                Text("Ad").frame(maxWidth: .infinity, alignment: .leading)
                Text("Envanter\nbirimi").frame(width: IW.unit + 10)
                Text("Reçete\nbirimi").frame(width: IW.recipeUnit + 10)
                Text("Katsayı").frame(width: IW.factor + 10).explains(.factor)
                Text("Kritik\nseviye").frame(width: IW.min + 10).explains(.minStock)
                Text("Tolerans\n(± birim)").frame(width: IW.tol + 10).explains(.tolerance)
                Text("Tahmini\nstok").frame(width: IW.estimate + 10)
                    .help("Bugün: sayıldıysa kapanış, değilse son sayım + sonraki hareketler (≈)")
                Color.clear.frame(width: IW.delete, height: 1)
            }
            .font(.caption.weight(.semibold)).multilineTextAlignment(.center)
            .padding(.vertical, 6).padding(.horizontal, 12)
            .background(Color.primary.opacity(0.05))
            let shown = store.data.items.filter { ItemSearch.matches($0, query: query) }
            if shown.isEmpty && !query.isEmpty {
                VStack(spacing: 10) {
                    Text(ItemSearch.noMatchText(query)).font(.title3.weight(.semibold))
                    Button(ItemSearch.clearLabel) { query = "" }.buttonStyle(SoftButtonStyle())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(shown) { item in
                        ItemRow(item: item, estimate: estimates[item.id]) { deleting = item }
                            .disabled(!store.canEditCatalog)
                    }
                    // Aramadayken sıra sürüklenemez (görünen sıra tüm listenin sırası değildir)
                    .onMove(perform: query.isEmpty ? { (from: IndexSet, to: Int) in store.moveItems(from: from, to: to) } : nil)
                }
                .listStyle(.plain)
            }
            Divider()
            HStack(spacing: 10) {
                TextField("Yeni stok kalemi adı", text: $newName).textFieldStyle(.roundedBorder).frame(width: 260)
                    .onSubmit(add)
                Picker("", selection: $newUnit) { Text("Adet").tag("Adet"); Text("Kg").tag("Kg") }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 130)
                Button("Ekle", action: add)
                    .buttonStyle(PrimaryButtonStyle()).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
            }
            .padding(14)
            .disabled(!store.canEditCatalog)
        }
        .navigationTitle("Stok Kalemleri")
        .onAppear { takeSearchRequest() }
        .onChange(of: store.focusItemsSearch) { _, _ in takeSearchRequest() }
        .sheet(isPresented: $store.showThresholds) {
            ThresholdsSheet(changes: changes, suggestions: suggestions).environmentObject(store)
        }
        .confirmationDialog("\"\(deleting?.name ?? "")\" silinsin mi?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Sil", role: .destructive) { if let d = deleting { store.deleteItem(d.id) }; deleting = nil }
            Button("Vazgeç", role: .cancel) { deleting = nil }
        } message: {
            Text("Bu kalemin tüm günlük sayım kayıtları ve reçetelerdeki miktarları da silinir (Düzen > Geri Al ile geri alınabilir). Geçici olarak gizlemek için \"Aktif\" işaretini kaldırın.")
        }
    }

    private func add() {
        let n = newName.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        store.addItem(name: n, unit: newUnit)
        newName = ""
    }

    /// Kalem Ara isteği (⌘F, bu ekran açıkken): arama kutusuna odaklanır
    private func takeSearchRequest() {
        guard store.focusItemsSearch else { return }
        store.focusItemsSearch = false
        DispatchQueue.main.async { searchFocused = true }
    }
}

private struct ItemRow: View {
    @EnvironmentObject var store: AppStore
    let item: Item
    let estimate: StockEstimate?
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Toggle("", isOn: Binding(get: { item.active }, set: { v in store.updateItem(item.id) { $0.active = v } }))
                .labelsHidden().frame(width: IW.active)
            CommitTextField(title: "Ad", value: Binding(get: { item.name }, set: { v in
                guard !v.isEmpty else { return }
                store.updateItem(item.id) { $0.name = v }
            }))
            .frame(maxWidth: .infinity)
            Picker("", selection: Binding(get: { item.unit }, set: { v in store.updateItem(item.id) { $0.unit = v } })) {
                Text("Adet").tag("Adet"); Text("Kg").tag("Kg")
            }.labelsHidden().frame(width: IW.unit).padding(.horizontal, 5)
            CommitTextField(title: "birim", value: Binding(get: { item.recipeUnit }, set: { v in store.updateItem(item.id) { $0.recipeUnit = v } }))
                .frame(width: IW.recipeUnit).padding(.horizontal, 5)
            DecimalField(value: Binding(get: { item.factor }, set: { v in store.updateItem(item.id) { $0.factor = max(v, 0.000001) } }),
                         maxFraction: 6, width: IW.factor)
                .padding(.horizontal, 5)
            OptionalDecimalField(value: Binding(get: { item.minStock }, set: { v in store.updateItem(item.id, actionName: "Kritik Seviye") { $0.minStock = v } }),
                                 placeholder: "—", maxFraction: item.maxFraction, width: IW.min)
                .padding(.horizontal, 5)
                .help("Kapanış bu değerin altına düşerse uyarı verilir (\(item.unit.lowercased()))")
            OptionalDecimalField(value: Binding(get: { item.tolerance }, set: { v in store.updateItem(item.id, actionName: "Tolerans") { $0.tolerance = v } }),
                                 placeholder: "0", maxFraction: item.maxFraction, width: IW.tol)
                .padding(.horizontal, 5)
                .help("Bu kadarlık fark normal sayılır (± \(item.unit.lowercased()))")
            estimateText
                .frame(width: IW.estimate).padding(.horizontal, 5)
            Button(action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundStyle(Brand.negative.opacity(0.85)).frame(width: IW.delete)
                .help("Stok kalemini sil")
                .accessibilityLabel("\(item.name) kalemini sil")
        }
        .padding(.vertical, 3)
        .opacity(item.active ? 1 : 0.55)
    }

    /// "≈ 4,2 kg" (bugün sayıldıysa düz değer); dayanak yoksa ya da kalem pasifse "—"
    @ViewBuilder private var estimateText: some View {
        if let e = estimate, item.active {
            Text(StockEstimateText.value(e, item: item))
                .monospacedDigit()
                .fontWeight(e.below ? .semibold : .regular)
                .foregroundStyle(e.below ? Brand.warn : (e.counted ? Color.primary : Color.secondary))
                .lineLimit(1).minimumScaleFactor(0.8)
                .help(StockEstimateText.help(e, item: item))
        } else {
            Text("—").foregroundStyle(.tertiary).help(StockEstimateText.noEstimate)
        }
    }
}

/// "Eşik önerileri" (patron / müdür): son 28 günün sayım farklarına göre tolerans (%80'lik dilim) ve tüketimine göre
/// kritik seviye (günlük tüketim × 1,5). Boş alanlar önceden seçili; elle girilmiş değerler kendiliğinden değişmez.
/// Web panelindeki pencereyle aynı kural (`ThresholdChange`).
private struct ThresholdsSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let changes: [ThresholdChange]
    let suggestions: [ThresholdSuggestion]
    @State private var selected: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Eşik önerileri").font(.title2.weight(.semibold))
            Text("Son \(Engine.thresholdLookbackDays) güne göre: tolerans, sayım farklarının %80'inin kaldığı sınır; kritik seviye, günlük tüketimin 1,5 katı. En az \(Engine.thresholdMinDays) günlük veri gerekir. Boş alanlar seçili gelir; elle girdiğiniz değerler yalnızca işaretlerseniz değişir.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if changes.isEmpty {
                Text("Şu an önerilecek bir değişiklik yok: eşikler önerilerle aynı ya da en az \(Engine.thresholdMinDays) günlük sayım / satış verisi henüz yok.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            } else {
                List {
                    ForEach(itemsWithChanges) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(item.name).fontWeight(.medium)
                                Spacer()
                                Text(basis(item)).font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(changes.filter { $0.itemID == item.id }) { c in
                                Toggle(isOn: binding(c)) { Text(changeText(c, item)).monospacedDigit() }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .frame(minHeight: 260)
            }
            HStack {
                Text("\(chosen.count) / \(changes.count) öneri seçili").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Vazgeç") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Önerilenleri uygula") {
                    if store.applyThresholds(chosen) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(PrimaryButtonStyle())
                .disabled(chosen.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 580, height: 540)
        .onAppear { selected = Set(changes.filter { $0.preselected }.map { $0.id }) }
    }

    private var chosen: [ThresholdChange] { changes.filter { selected.contains($0.id) } }

    private var itemsWithChanges: [Item] {
        let ids = Set(changes.map { $0.itemID })
        return store.data.items.filter { ids.contains($0.id) }
    }

    private func binding(_ c: ThresholdChange) -> Binding<Bool> {
        Binding(get: { selected.contains(c.id) },
                set: { on in if on { selected.insert(c.id) } else { selected.remove(c.id) } })
    }

    /// "Tolerans  — → ± 5 adet"
    private func changeText(_ c: ThresholdChange, _ item: Item) -> String {
        let f: (Double) -> String = { Fmt.number($0, maxFraction: item.maxFraction) }
        let label = c.field == .tolerance ? "Tolerans" : "Kritik seviye"
        let current = c.current.map(f) ?? "—"
        return "\(label): \(current) → \(c.field == .tolerance ? "± " : "")\(f(c.suggested)) \(item.unit.lowercased())"
    }

    /// "10 sayım günü · günlük ≈ 3,6 adet"
    private func basis(_ item: Item) -> String {
        guard let s = suggestions.first(where: { $0.itemID == item.id }) else { return "" }
        var parts: [String] = []
        if s.countedDays > 0 { parts.append("\(s.countedDays) sayım günü") }
        if s.dailyUsage > 0 { parts.append("günlük ≈ \(Fmt.number(s.dailyUsage, maxFraction: item.maxFraction)) \(item.unit.lowercased())") }
        return parts.joined(separator: " · ")
    }
}
