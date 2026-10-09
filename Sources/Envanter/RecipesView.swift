import SwiftUI
import EnvanterCore

private enum RecipeFilter: String, CaseIterable, Identifiable {
    case all = "Tümü", tracked = "Reçeteli", untracked = "Stok etkisi yok", warning = "Notlu"
    var id: String { rawValue }
}

struct RecipesView: View {
    @EnvironmentObject var store: AppStore
    @State private var search = ""
    @State private var filter: RecipeFilter = .all
    @State private var showNew = false

    var body: some View {
        HSplitView {
            list.frame(minWidth: 330, idealWidth: 380, maxWidth: 480)
            Group {
                if let code = store.recipeSelection, store.product(code) != nil {
                    RecipeEditor(code: code).id(code)
                } else {
                    EmptyStateView(icon: "fork.knife", title: "Bir ürün seçin",
                                   message: "Soldan bir ürün seçip hangi hammaddeden kaç adet/kg kullandığını düzenleyin. Satış raporu aktarılınca stok bu reçetelere göre düşer.")
                }
            }
            .frame(minWidth: 520, maxWidth: .infinity)
        }
        .navigationTitle("Reçeteler")
        .sheet(isPresented: $showNew, onDismiss: { store.newProductDraft = nil }) {
            NewProductSheet(draft: store.newProductDraft).environmentObject(store)
        }
        .onAppear { if store.newProductDraft != nil { showNew = true } }
        .onChange(of: store.newProductDraft?.code) { _, c in if c != nil { showNew = true } }
    }

    private var filtered: [Product] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased(with: Locale(identifier: "tr_TR"))
        return store.data.products.filter { p in
            switch filter {
            case .all: break
            case .tracked: if !p.isTracked { return false }
            case .untracked: if p.isTracked { return false }
            case .warning: if (p.note ?? "").isEmpty { return false }
            }
            return q.isEmpty || p.code.contains(q) || p.name.lowercased(with: Locale(identifier: "tr_TR")).contains(q)
                || p.category.lowercased(with: Locale(identifier: "tr_TR")).contains(q)
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Ürün, kod veya kategori ara", text: $search).textFieldStyle(.plain)
                Button { showNew = true } label: { Image(systemName: "plus") }
                    .buttonStyle(SoftButtonStyle()).help("Yeni ürün ekle")
            }
            .padding(10)
            Picker("", selection: $filter) {
                ForEach(RecipeFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 10).padding(.bottom, 8)
            Divider()
            let items = filtered
            List(selection: $store.recipeSelection) {
                ForEach(items) { p in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(p.name).lineLimit(1)
                            if !(p.note ?? "").isEmpty { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Brand.warn).font(.caption) }
                            if p.isWaste { Pill(text: "zayi", color: Brand.warn) }
                            Spacer()
                            if !p.isTracked { Pill(text: "etkisiz", color: .secondary) }
                        }
                        Text("\(p.code) · \(p.category)").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .tag(p.code)
                }
            }
            .listStyle(.inset)
            Divider()
            Text("\(items.count) / \(store.data.products.count) ürün").font(.caption).foregroundStyle(.secondary).padding(6)
        }
    }
}

// MARK: - Düzenleyici

private struct RecipeEditor: View {
    @EnvironmentObject var store: AppStore
    let code: String
    @State private var showCopy = false
    @State private var confirmDelete = false

    var body: some View {
        if let p = store.product(code) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Ürün adı").font(.caption).foregroundStyle(.secondary)
                            CommitTextField(title: "Ürün adı", value: Binding(get: { p.name }, set: { v in
                                guard !v.isEmpty else { return }
                                store.updateProduct(code, actionName: "Ürün Adı") { $0.name = v }
                            }), font: .title3)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("ModPos kodu").font(.caption).foregroundStyle(.secondary)
                            Text(p.code).font(.title3.monospacedDigit()).padding(.vertical, 3)
                        }
                        .frame(width: 100, alignment: .leading)
                    }

                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Kategori").font(.caption).foregroundStyle(.secondary)
                            Picker("", selection: Binding(get: { p.category }, set: { v in store.updateProduct(code) { $0.category = v } })) {
                                ForEach(categories(including: p.category), id: \.self) { Text($0).tag($0) }
                            }.labelsHidden().frame(width: 260)
                        }
                        if p.isWaste {
                            Pill(text: "Zayi ürünü: tüketim Zayi sütununa yazılır", color: Brand.warn)
                        }
                    }

                    if let note = p.note, !note.isEmpty {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Brand.warn)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(note).font(.callout).fixedSize(horizontal: false, vertical: true)
                                Button("Notu kaldır (kontrol ettim)") { store.updateProduct(code) { $0.note = nil } }.buttonStyle(.link)
                            }
                            Spacer()
                        }
                        .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Brand.warn.opacity(0.12)))
                    }

                    costCard(p)

                    Divider()
                    HStack {
                        Text("Hammadde kullanımı (1 adet satış için)").font(.headline)
                        Spacer()
                        Menu {
                            ForEach(store.data.items.filter { p.amounts[$0.id] == nil }) { item in
                                Button("\(item.name) (\(item.recipeUnit))") {
                                    store.updateProduct(code, actionName: "Hammadde Ekle") { $0.amounts[item.id] = 1 }
                                }
                            }
                        } label: { Label("Hammadde ekle", systemImage: "plus.circle") }
                            .menuStyle(.borderlessButton).fixedSize()
                    }

                    let used = store.data.items.filter { p.amounts[$0.id] != nil }
                    if used.isEmpty {
                        Card {
                            Text("Bu ürün stoktan bir şey düşmüyor (içecek, sos vb.). Hammadde eklerseniz satış adedine göre düşülür.")
                                .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        Card(padding: 8) {
                            VStack(spacing: 0) {
                                ForEach(used) { item in
                                    IngredientRow(code: code, item: item)
                                    if item.id != used.last?.id { Divider() }
                                }
                            }
                        }
                    }

                    HStack(spacing: 10) {
                        Button { showCopy = true } label: { Label("Başka üründen kopyala…", systemImage: "doc.on.doc") }
                            .buttonStyle(SoftButtonStyle())
                        Button { duplicate(p) } label: { Label("Çoğalt", systemImage: "plus.square.on.square") }
                            .buttonStyle(SoftButtonStyle())
                        Spacer()
                        Button(role: .destructive) { confirmDelete = true } label: { Label("Ürünü sil", systemImage: "trash") }
                            .buttonStyle(SoftButtonStyle(tint: Brand.negative))
                    }
                }
                .padding(22)
            }
            .sheet(isPresented: $showCopy) { CopyRecipeSheet(targetCode: code).environmentObject(store) }
            .confirmationDialog("\"\(p.name)\" silinsin mi?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Sil", role: .destructive) { store.deleteProduct(code) }
                Button("Vazgeç", role: .cancel) {}
            } message: { Text("Bu ürün satış raporlarında görünürse \"reçete tanımsız\" olarak işaretlenir. Düzen > Geri Al ile geri alınabilir.") }
        }
    }

    /// Reçete maliyeti ve (son satış raporundan) fiyata göre maliyet yüzdesi
    @ViewBuilder private func costCard(_ p: Product) -> some View {
        if p.isTracked {
            let rc = store.engine.recipeCost(p)
            let price = store.engine.lastUnitPrice(code: p.code)
            let limit = store.settings.targetFoodCostPct ?? 0.35
            StatRow {
                StatCard(title: "Maliyet", value: rc.cost > 0 || rc.isComplete ? Fmt.money(rc.cost, fraction: 2) : "—",
                         detail: rc.isComplete ? "1 adet için hammadde maliyeti" : "Maliyeti eksik: " + rc.missing.joined(separator: ", "),
                         icon: "turkishlirasign.circle", color: rc.isComplete ? Brand.accent : Brand.warn)
                StatCard(title: "Satış fiyatı", value: price.map { Fmt.money($0.price, fraction: 2) } ?? "—",
                         detail: price.map { "\(DateKey.short($0.date)) satış raporundan" } ?? "Raporda tutar sütunu yok",
                         icon: "tag", color: Brand.positive)
                let pct: Double? = (rc.isComplete && (price?.price ?? 0) > 0) ? rc.cost / price!.price : nil
                StatCard(title: "Oran", value: pct.map { "%" + Fmt.number($0 * 100, maxFraction: 1) } ?? "—",
                         detail: pct.map { $0 > limit ? "Hedefin (%\(Fmt.number(limit * 100, maxFraction: 1))) üzerinde: fiyatı veya porsiyonu gözden geçirin" : "Kâr payı: \(Fmt.money(price!.price - rc.cost, fraction: 2))" } ?? "Maliyet ve fiyat gerekli",
                         icon: "percent", color: (pct ?? 0) > limit ? Brand.negative : Brand.ok)
            }
        }
    }

    private func categories(including current: String) -> [String] {
        Category.standard.contains(current) ? Category.standard : Category.standard + [current]
    }

    /// Kopyaya, satış raporlarıyla çakışmayan geçici bir rakamsal kod verilir (ör. 9 + kod + sıra); kullanıcı sonra düzeltebilir.
    private func duplicate(_ p: Product) {
        var n = 1
        var newCode = "9\(p.code)\(n)"
        while store.product(newCode) != nil { n += 1; newCode = "9\(p.code)\(n)" }
        var copy = p
        copy.code = newCode; copy.name = p.name + " (kopya)"
        copy.note = "Kopya ürün: ModPos'taki gerçek kodu \(newCode) yerine Yeni Ürün ile tanımlayın veya bu kaydı silin."
        store.addProduct(copy)
        store.recipeSelection = newCode
    }
}

private struct IngredientRow: View {
    @EnvironmentObject var store: AppStore
    let code: String
    let item: Item

    var body: some View {
        let amount = store.product(code)?.amounts[item.id] ?? 0
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).fontWeight(.medium)
                Text("envanter birimi: \(item.unit.lowercased())").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            DecimalField(value: Binding(get: { amount }, set: { v in store.updateProduct(code) { $0.amounts[item.id] = v } }))
            Text(item.recipeUnit).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
            if item.factor != 1 {
                Text("= \(Fmt.number(amount * item.factor, maxFraction: 4)) \(item.unit.lowercased())")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit().frame(width: 96, alignment: .trailing)
            } else {
                Color.clear.frame(width: 96, height: 1)
            }
            Button { store.updateProduct(code, actionName: "Hammadde Çıkar") { $0.amounts[item.id] = nil } } label: { Image(systemName: "minus.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(Brand.negative.opacity(0.85)).help("Bu hammaddeyi reçeteden çıkar")
        }
        .padding(.vertical, 6).padding(.horizontal, 6)
    }
}

// MARK: - Yeni ürün

private struct NewProductSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let draft: SaleLine?
    @State private var code = ""
    @State private var name = ""
    @State private var category = "MENÜLER"
    @State private var copyFrom: String = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Yeni ürün / reçete").font(.title2.weight(.semibold))
            if draft != nil {
                Text("Bu ürün satış raporunda var ama reçete tablosunda yok. Reçetesini tanımlayınca stoğa yansır.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow { Text("ModPos kodu"); TextField("ör. 19991", text: $code).textFieldStyle(.roundedBorder).frame(width: 160) }
                GridRow { Text("Ürün adı"); TextField("ör. KACMAZ MENU", text: $name).textFieldStyle(.roundedBorder) }
                GridRow {
                    Text("Kategori")
                    Picker("", selection: $category) { ForEach(Category.standard, id: \.self) { Text($0).tag($0) } }.labelsHidden()
                }
                GridRow {
                    Text("Reçete")
                    Picker("", selection: $copyFrom) {
                        Text("Boş başla (sonra düzenlerim)").tag("")
                        ForEach(store.data.products.filter { $0.isTracked }) { Text("\($0.name) reçetesini kopyala").tag($0.code) }
                    }.labelsHidden()
                }
            }
            if let error { Text(error).foregroundStyle(Brand.negative).font(.callout) }
            HStack {
                Spacer()
                Button("Vazgeç") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Ekle") { add() }.keyboardShortcut(.defaultAction).buttonStyle(PrimaryButtonStyle())
                    .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22).frame(width: 520)
        .onAppear { if let d = draft { code = d.code; name = d.name } }
    }

    private func add() {
        let c = code.trimmingCharacters(in: .whitespaces)
        guard SalesParser.isCode(c) else { error = "ModPos kodu en az 3 haneli ve yalnızca rakamlardan oluşmalı (satış raporlarıyla bu kodla eşleşir)."; return }
        guard store.product(c) == nil else { error = "Bu kodla bir ürün zaten var."; return }
        let amounts = copyFrom.isEmpty ? [:] : (store.product(copyFrom)?.amounts ?? [:])
        let note = copyFrom.isEmpty ? nil : "\(store.product(copyFrom)?.name ?? "") reçetesinden kopyalandı; lütfen kontrol edin."
        store.addProduct(Product(code: c, name: name.trimmingCharacters(in: .whitespaces), category: category, amounts: amounts, note: note))
        store.recipeSelection = c
        dismiss()
    }
}

private struct CopyRecipeSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let targetCode: String
    @State private var search = ""

    var body: some View {
        let q = search.lowercased(with: Locale(identifier: "tr_TR"))
        let list = store.data.products.filter { $0.isTracked && $0.code != targetCode &&
            (q.isEmpty || $0.name.lowercased(with: Locale(identifier: "tr_TR")).contains(q) || $0.code.contains(q)) }
        VStack(alignment: .leading, spacing: 10) {
            Text("Hangi ürünün reçetesi kopyalansın?").font(.title3.weight(.semibold))
            TextField("Ara", text: $search).textFieldStyle(.roundedBorder)
            List(list) { p in
                Button {
                    store.updateProduct(targetCode) {
                        $0.amounts = p.amounts
                        $0.note = "\(p.name) reçetesinden kopyalandı; lütfen kontrol edin."
                    }
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.name)
                        Text(summary(p)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }.buttonStyle(.plain)
            }
            .frame(height: 320)
            HStack { Spacer(); Button("Vazgeç") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(20).frame(width: 520)
    }

    private func summary(_ p: Product) -> String {
        store.data.items.compactMap { i in p.amounts[i.id].map { "\(i.name) \(Fmt.number($0, maxFraction: 4))" } }.joined(separator: " · ")
    }
}
