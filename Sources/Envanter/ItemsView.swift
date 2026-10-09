import SwiftUI
import EnvanterCore

struct ItemsView: View {
    @EnvironmentObject var store: AppStore
    @State private var newName = ""
    @State private var newUnit = "Adet"
    @State private var deleting: Item?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Stok Kalemleri").font(.title2.weight(.semibold))
                Text("Günlük Envanter ekranındaki satırlar bunlardır (90 Gr, Peynir, Patates…). Sırayı sürükleyerek değiştirebilir, kullanılmayanları gizleyebilirsiniz. \"Katsayı\", reçetedeki birimin envanter birimine çevrilmesidir (ör. 1 dilim peynir = 0,014 kg).")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            HStack(spacing: 0) {
                Text("Aktif").frame(width: 56)
                Text("Ad").frame(maxWidth: .infinity, alignment: .leading)
                Text("Envanter birimi").frame(width: 120)
                Text("Reçete birimi").frame(width: 120)
                Text("Katsayı").frame(width: 100)
                Color.clear.frame(width: 44, height: 1)
            }
            .font(.caption.weight(.semibold)).padding(.vertical, 8).padding(.horizontal, 12)
            .background(Color.primary.opacity(0.05))
            List {
                ForEach(store.data.items) { item in
                    ItemRow(item: item) { deleting = item }
                }
                .onMove { store.moveItems(from: $0, to: $1) }
            }
            .listStyle(.plain)
            Divider()
            HStack(spacing: 10) {
                TextField("Yeni stok kalemi adı", text: $newName).textFieldStyle(.roundedBorder).frame(width: 260)
                Picker("", selection: $newUnit) { Text("Adet").tag("Adet"); Text("Kg").tag("Kg") }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 130)
                Button("Ekle") {
                    let n = newName.trimmingCharacters(in: .whitespaces)
                    guard !n.isEmpty else { return }
                    store.addItem(name: n, unit: newUnit); newName = ""
                }
                .buttonStyle(PrimaryButtonStyle()).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
            }
            .padding(14)
        }
        .navigationTitle("Stok Kalemleri")
        .confirmationDialog("\"\(deleting?.name ?? "")\" silinsin mi?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Sil", role: .destructive) { if let d = deleting { store.deleteItem(d.id) }; deleting = nil }
            Button("Vazgeç", role: .cancel) { deleting = nil }
        } message: {
            Text("Bu kalemin tüm günlük sayım kayıtları ve reçetelerdeki miktarları da silinir. Geçici olarak gizlemek için \"Aktif\" işaretini kaldırın.")
        }
    }
}

private struct ItemRow: View {
    @EnvironmentObject var store: AppStore
    let item: Item
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Toggle("", isOn: Binding(get: { item.active }, set: { v in store.updateItem(item.id) { $0.active = v } }))
                .labelsHidden().frame(width: 56)
            TextField("Ad", text: Binding(get: { item.name }, set: { v in store.updateItem(item.id) { $0.name = v } }))
                .textFieldStyle(.roundedBorder).frame(maxWidth: .infinity)
            Picker("", selection: Binding(get: { item.unit }, set: { v in store.updateItem(item.id) { $0.unit = v } })) {
                Text("Adet").tag("Adet"); Text("Kg").tag("Kg")
            }.labelsHidden().frame(width: 100).padding(.horizontal, 10)
            TextField("birim", text: Binding(get: { item.recipeUnit }, set: { v in store.updateItem(item.id) { $0.recipeUnit = v } }))
                .textFieldStyle(.roundedBorder).frame(width: 100).padding(.horizontal, 10)
            DecimalField(value: Binding(get: { item.factor }, set: { v in store.updateItem(item.id) { $0.factor = max(v, 0.000001) } }), maxFraction: 6, width: 80)
                .padding(.horizontal, 10)
            Button(action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundStyle(Brand.negative.opacity(0.85)).frame(width: 44)
        }
        .padding(.vertical, 3)
        .opacity(item.active ? 1 : 0.55)
    }
}
