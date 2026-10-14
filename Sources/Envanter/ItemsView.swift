import SwiftUI
import EnvanterCore

private enum IW {
    static let active: CGFloat = 50
    static let unit: CGFloat = 96
    static let recipeUnit: CGFloat = 92
    static let factor: CGFloat = 92
    static let min: CGFloat = 88
    static let tol: CGFloat = 84
    static let delete: CGFloat = 36
}

/// Onay bekleyen birim değişikliği (kalemin sayım geçmişi var)
private struct UnitChangeRequest {
    let item: Item
    let unit: String
    let history: CatalogOps.ItemHistory
}

/// Onay bekleyen katsayı değişikliği (kalemi kullanan ürünlerin satıldığı günler var)
private struct FactorChangeRequest {
    let item: Item
    let factor: Double
    let history: CatalogOps.ItemHistory
}

struct ItemsView: View {
    @EnvironmentObject var store: AppStore
    @State private var newName = ""
    @State private var newUnit = "Adet"
    @State private var deleting: Item?
    @State private var unitChange: UnitChangeRequest?
    @State private var factorChange: FactorChangeRequest?

    var body: some View {
        let activeCount = store.data.items.filter { $0.active }.count
        // Kritik seviyesi girilmiş aktif kalem sayısı (sipariş önerisi ve uyarılar bunlar için çalışır)
        let withMin = store.data.items.filter { $0.active && ($0.minStock ?? 0) > 0 }.count
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Stok Kalemleri").font(.title2.weight(.semibold))
                    Spacer()
                    Pill(text: "\(activeCount) aktif kalem · \(withMin) kalemde kritik seviye tanımlı", color: Brand.positive)
                }
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
                Color.clear.frame(width: IW.delete, height: 1)
            }
            .font(.caption.weight(.semibold)).multilineTextAlignment(.center)
            .padding(.vertical, 6).padding(.horizontal, 12)
            .background(Color.primary.opacity(0.05))
            List {
                ForEach(store.data.items) { item in
                    ItemRow(item: item, onUnit: { requestUnit(item, $0) }, onFactor: { requestFactor(item, $0) }) { deleting = item }
                        .disabled(!store.canEditCatalog)
                }
                .onMove { store.moveItems(from: $0, to: $1) }
            }
            .listStyle(.plain)
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
        // Silme: geçmişi olan aktif kalemde önerilen işlem "Pasif Yap"; kalıcı silme kapatılmış günlere dokunmaz (CatalogOps)
        .confirmationDialog("\"\(deleting?.name ?? "")\" silinsin mi?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { item in
            if offersDeactivate(item) {
                Button("Pasif Yap (önerilen)") { store.deactivateItem(item.id); deleting = nil }
            }
            Button("Kalıcı Olarak Sil", role: .destructive) { store.deleteItem(item.id); deleting = nil }
            Button("Vazgeç", role: .cancel) { deleting = nil }
        } message: { item in
            Text(deleteMessage(item))
        }
        // Birim: geçmiş yeni birimle okunurdu; önerilen "Yeni Kalem Olarak Aç" (eski kalem "Patates (adet)" adıyla pasif kalır)
        .confirmationDialog(unitChange.map { "Birim \($0.unit) yapılsın mı?" } ?? "",
                            isPresented: Binding(get: { unitChange != nil }, set: { if !$0 { unitChange = nil } }),
                            titleVisibility: .visible, presenting: unitChange) { c in
            Button("Yeni Kalem Olarak Aç (önerilen)") { store.splitItemForUnit(c.item.id, unit: c.unit); unitChange = nil }
            Button("Yine de Değiştir") { store.updateItem(c.item.id) { $0.unit = c.unit }; unitChange = nil }
            Button("Vazgeç", role: .cancel) { unitChange = nil }
        } message: { c in
            Text(CatalogOps.unitChangeMessage(item: c.item, newUnit: c.unit, days: c.history.days)
                 + " Yeni kalem olarak açılınca eski kayıtlar \"\(c.item.name) (\(c.item.unit.lowercased(with: Locale(identifier: "tr_TR"))))\" adıyla pasif kalır; reçetelerdeki miktarlar yeni kaleme taşınır.")
        }
        // Katsayı: kalemi kullanan ürünlerin satıldığı geçmiş günlerin Satılan ve Fark'ı değişir
        .confirmationDialog(factorChange.map { "Katsayı \(Fmt.number($0.item.factor, maxFraction: 6)) → \(Fmt.number($0.factor, maxFraction: 6)) olsun mu?" } ?? "",
                            isPresented: Binding(get: { factorChange != nil }, set: { if !$0 { factorChange = nil } }),
                            titleVisibility: .visible, presenting: factorChange) { c in
            Button("Değiştir") { store.updateItem(c.item.id) { $0.factor = c.factor }; factorChange = nil }
            Button("Vazgeç", role: .cancel) { factorChange = nil }
        } message: { c in
            Text(CatalogOps.factorChangeMessage(c.history) + " Düzen > Geri Al (⌘Z) ile geri alınabilir.")
        }
    }

    private func add() {
        let n = newName.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        // Aynı adlı kalem varsa eklenmez (uyarı gösterilir) ve yazılan ad kalır
        if store.addItem(name: n, unit: newUnit) { newName = "" }
    }

    /// Gün kaydı, sipariş satırı ya da reçete kullanımı olan aktif kalem: silmek yerine pasif yapmak önerilir
    private func offersDeactivate(_ item: Item) -> Bool {
        item.active && CatalogOps.history(item.id, in: store.data).suggestsDeactivate
    }

    private func deleteMessage(_ item: Item) -> String {
        let text = CatalogOps.deleteDescription(CatalogOps.history(item.id, in: store.data))
        let undo = " Düzen > Geri Al (⌘Z) ile geri alınabilir."
        if offersDeactivate(item) {
            return "Kalemin sayım geçmişi, siparişi ya da reçetesi var. Silmek yerine pasif yapın: günlük sayımda ve raporlarda görünmez, geçmişi olduğu gibi kalır.\n\nKalıcı silmede: " + text + undo
        }
        return text + (item.active ? " Geçici olarak gizlemek için \"Aktif\" işaretini kaldırın." : "") + undo
    }

    /// Birim değişikliği: sayım geçmişi olan kalemde önce sorulur
    private func requestUnit(_ item: Item, _ unit: String) {
        guard unit != item.unit else { return }
        let h = CatalogOps.history(item.id, in: store.data)
        if CatalogOps.unitChangeNeedsConfirmation(h) {
            unitChange = UnitChangeRequest(item: item, unit: unit, history: h)
        } else {
            store.updateItem(item.id) { $0.unit = unit }
        }
    }

    /// Katsayı değişikliği: kalemi kullanan ürünlerin satıldığı günler varsa önce sorulur
    private func requestFactor(_ item: Item, _ value: Double) {
        let factor = max(value, 0.000001)
        guard factor != item.factor else { return }
        let h = CatalogOps.history(item.id, in: store.data)
        if CatalogOps.factorChangeNeedsConfirmation(h) {
            factorChange = FactorChangeRequest(item: item, factor: factor, history: h)
        } else {
            store.updateItem(item.id) { $0.factor = factor }
        }
    }
}

private struct ItemRow: View {
    @EnvironmentObject var store: AppStore
    let item: Item
    /// Birim seçildi (onay ItemsView'da)
    var onUnit: (String) -> Void
    /// Katsayı yazıldı (onay ItemsView'da)
    var onFactor: (Double) -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Toggle("", isOn: Binding(get: { item.active }, set: { v in store.updateItem(item.id) { $0.active = v } }))
                .labelsHidden().frame(width: IW.active)
            // Aynı adlı başka kalem varsa ad değişmez (uyarı); alan kayıtlı adı gösterir
            CommitTextField(title: "Ad", value: Binding(get: { item.name }, set: { v in
                guard !v.isEmpty else { return }
                store.renameItem(item.id, to: v)
            }))
            .frame(maxWidth: .infinity)
            Picker("", selection: Binding(get: { item.unit }, set: { v in onUnit(v) })) {
                Text("Adet").tag("Adet"); Text("Kg").tag("Kg")
            }.labelsHidden().frame(width: IW.unit).padding(.horizontal, 5)
            CommitTextField(title: "birim", value: Binding(get: { item.recipeUnit }, set: { v in store.updateItem(item.id) { $0.recipeUnit = v } }))
                .frame(width: IW.recipeUnit).padding(.horizontal, 5)
            DecimalField(value: Binding(get: { item.factor }, set: { v in onFactor(v) }),
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
            Button(action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundStyle(Brand.negative.opacity(0.85)).frame(width: IW.delete)
                .help("Stok kalemini sil")
                .accessibilityLabel("\(item.name) kalemini sil")
        }
        .padding(.vertical, 3)
        .opacity(item.active ? 1 : 0.55)
    }
}
