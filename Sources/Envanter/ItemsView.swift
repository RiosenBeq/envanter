import SwiftUI
import EnvanterCore

private enum IW {
    static let active: CGFloat = 50
    static let unit: CGFloat = 96
    static let recipeUnit: CGFloat = 92
    static let factor: CGFloat = 92
    static let money: CGFloat = 92
    static let min: CGFloat = 88
    static let tol: CGFloat = 84
    static let delete: CGFloat = 36
}

struct ItemsView: View {
    @EnvironmentObject var store: AppStore
    @State private var newName = ""
    @State private var newUnit = "Adet"
    @State private var deleting: Item?

    var body: some View {
        let costed = store.data.items.filter { $0.active && $0.unitCost != nil }.count
        let activeCount = store.data.items.filter { $0.active }.count
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Stok Kalemleri").font(.title2.weight(.semibold))
                    Spacer()
                    Pill(text: "\(costed) / \(activeCount) kalemde maliyet var", color: costed == activeCount ? Brand.ok : Brand.warn)
                }
                Text("Günlük Sayım ekranındaki satırlar bunlardır (90 Gr, Peynir, Patates…). Sırayı sürükleyerek değiştirebilir, kullanılmayanları gizleyebilirsiniz. \"Katsayı\", reçetedeki birimin envanter birimine çevrilmesidir (ör. 1 dilim peynir = 0,014 kg). Maliyet farkların ₺ karşılığını, kritik seviye sipariş önerisini ve uyarıları, tolerans ise \"normal\" sayılan farkı belirler.")
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
                Text("Birim maliyet\n(₺)").frame(width: IW.money + 10).explains(.unitCost)
                Text("Kritik\nseviye").frame(width: IW.min + 10).explains(.minStock)
                Text("Tolerans\n(± birim)").frame(width: IW.tol + 10).explains(.tolerance)
                Color.clear.frame(width: IW.delete, height: 1)
            }
            .font(.caption.weight(.semibold)).multilineTextAlignment(.center)
            .padding(.vertical, 6).padding(.horizontal, 12)
            .background(Color.primary.opacity(0.05))
            List {
                ForEach(store.data.items) { item in
                    ItemRow(item: item) { deleting = item }
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
}

private struct ItemRow: View {
    @EnvironmentObject var store: AppStore
    let item: Item
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
            OptionalDecimalField(value: Binding(get: { item.unitCost }, set: { v in store.setItemCost(item.id, v) }),
                                 placeholder: "₺", maxFraction: 2, width: IW.money, amount: true)
                .padding(.horizontal, 5)
                .help("1 \(item.unit.lowercased()) \(item.name) maliyeti (₺)")
                .overlay(alignment: .topTrailing) { priceBadge }
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

    /// Son fiyat değişimi (▲%13 gibi; Türkçe yüzde biçimi); ipucunda değişim tarihi ve fiyat geçmişi
    @ViewBuilder private var priceBadge: some View {
        if let c = item.lastPriceChange, abs(c.ratio) >= 0.001 {
            let history = (item.costHistory ?? []).suffix(6).map { p in
                (p.date.map { DateKey.short($0) } ?? "önceki") + ": " + Fmt.money(p.cost, fraction: 2)
            }.joined(separator: "\n")
            let when = c.date.map { " (\(DateKey.short($0)))" } ?? ""
            Text((c.ratio > 0 ? "▲" : "▼") + Fmt.percent(abs(c.ratio), maxFraction: 0))
                .font(.system(size: 9, weight: .bold)).monospacedDigit()
                .padding(.horizontal, 4).padding(.vertical, 1)
                .foregroundStyle(.white)
                .background(Capsule().fill(c.ratio > 0 ? Brand.negative : Brand.ok))
                .offset(x: 2, y: -7)
                .help("Son değişim\(when): \(Fmt.signedPercent(c.ratio))\nFiyat geçmişi:\n" + history)
        }
    }
}
