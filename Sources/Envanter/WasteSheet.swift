import SwiftUI
import EnvanterCore

// Elle zayi (web: ops/count/WasteDialog.tsx): "Zayi Ekle" penceresi ve zayi kayıtları listesi. Kayıtlar gün kaydının
// `wasteLog` alanına yazılır (docs/SYNC.md §1 "Elle zayi"); toplamı kalemin Zayi sütununa eklenir.

/// "Zayi Ekle": kalem (aranabilir liste), miktar (> 0), neden (zorunlu), not (en fazla 200 karakter) ve kim. Seçilen
/// kalemin o günkü ModPos zayisi ve önceden elle girilenler gösterilir (aynı zayi iki kez girilmesin).
struct WasteSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let date: String
    /// Hesap dökümünden / satırdan açılınca seçili gelen kalem
    var initialItemID: String?
    /// Kaydedilince Günlük Sayım'da gösterilecek metin ("Zayi kaydedildi: Patates 3 kg · …")
    var onSaved: (String) -> Void = { _ in }

    @State private var search = ""
    @State private var itemID: String?
    @State private var qty: Double?
    @State private var reason: WasteReason?
    @State private var note = ""
    @State private var by = ""
    /// "Kim" listesinin varsayılanı (açılışta bir kez hesaplanır)
    @State private var defaultBy = ""
    @State private var tried = false

    init(date: String, initialItemID: String? = nil, onSaved: @escaping (String) -> Void = { _ in }) {
        self.date = date
        self.initialItemID = initialItemID
        self.onSaved = onSaved
    }

    var body: some View {
        let engine = store.engine
        let tr = Locale(identifier: "tr_TR")
        let q = search.trimmingCharacters(in: .whitespaces).lowercased(with: tr)
        let list = engine.activeItems.filter { q.isEmpty || $0.name.lowercased(with: tr).contains(q) || $0.id.lowercased().contains(q) }
        let item = itemID.flatMap { engine.itemsByID[$0] }
        let locked = store.isLocked(date)
        VStack(alignment: .leading, spacing: 12) {
            Text("\(WasteText.addTitle) · \(DateKey.short(date))").font(.title2.weight(.semibold))
            Text("Bozulan, yanan, düşen ya da iade edilen malı kalemin kendi biriminde girin; günün Zayi'sine eklenir.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Kalem").font(.callout.weight(.medium))
                TextField("Kalem ara (ör. patates)", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if list.count == 1 { itemID = list[0].id } }
                List(list, selection: $itemID) { i in
                    HStack {
                        Text(i.name)
                        Spacer()
                        Text(i.unit.lowercased()).foregroundStyle(.secondary)
                    }
                }
                .frame(height: 170)
                if tried && item == nil { errorText(WasteText.itemRequired) }
            }

            if let item, let hint = duplicateHint(item) {
                Label(hint, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(Brand.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Miktar").foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        OptionalDecimalField(value: $qty, placeholder: "0", maxFraction: item?.maxFraction ?? 3, width: 110, live: true)
                        Text(item?.unit.lowercased() ?? "").foregroundStyle(.secondary)
                        if tried && !((qty ?? 0) > 0) { errorText(WasteText.qtyRequired) }
                    }
                }
                GridRow {
                    Text("Neden").foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Picker("Neden", selection: $reason) {
                            Text("Seçin").tag(WasteReason?.none)
                            ForEach(WasteReason.allCases, id: \.self) { r in Text(r.title).tag(WasteReason?.some(r)) }
                        }
                        .labelsHidden().pickerStyle(.menu).frame(width: 220)
                        if tried && reason == nil { errorText(WasteText.reasonRequired) }
                    }
                }
                GridRow {
                    Text("Not").foregroundStyle(.secondary)
                    TextField("ör. Dondurucu arızası (isteğe bağlı)", text: $note)
                        .textFieldStyle(.roundedBorder).frame(width: 320)
                        .onChange(of: note) { _, v in
                            if v.count > WasteLog.noteMaxLength { note = String(v.prefix(WasteLog.noteMaxLength)) }
                        }
                }
                GridRow {
                    Text("Kim").foregroundStyle(.secondary)
                    Picker("Kim", selection: $by) {
                        Text("Belirtilmedi").tag("")
                        ForEach(byOptions, id: \.self) { n in Text(n).tag(n) }
                    }
                    .labelsHidden().pickerStyle(.menu).frame(width: 220)
                }
            }

            if locked {
                Label(WasteText.lockedNote, systemImage: "lock.fill").font(.callout).foregroundStyle(Brand.negative)
            }
            HStack {
                Spacer()
                Button("Vazgeç") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Kaydet") { save() }
                    .keyboardShortcut(.defaultAction).buttonStyle(PrimaryButtonStyle())
                    .disabled(locked)
            }
        }
        .padding(22).frame(width: 520)
        .onAppear {
            if let id = initialItemID, store.engine.itemsByID[id] != nil { itemID = id }
            defaultBy = store.defaultWasteBy(date: date)
            by = defaultBy
        }
    }

    /// "Kim" seçenekleri: Sayan listesi (+ listede olmayan varsayılan ad başta; web `wasteByOptions`)
    private var byOptions: [String] {
        let names = store.counterNames
        return !defaultBy.isEmpty && !names.contains(defaultBy) ? [defaultBy] + names : names
    }

    private func duplicateHint(_ item: Item) -> String? {
        guard let row = store.engine.calc(date: date).rows.first(where: { $0.itemID == item.id }) else { return nil }
        return WasteText.duplicateHint(row, day: store.data.days[date], item: item)
    }

    private func errorText(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(Brand.negative)
    }

    private func save() {
        tried = true
        guard let item = itemID.flatMap({ store.engine.itemsByID[$0] }), let chosen = reason, let amount = qty, amount > 0,
              let entry = WasteLog.make(itemID: item.id, qty: amount, reason: chosen, note: note, by: by) else { return }
        if store.addWaste(date: date, entry: entry) {
            onSaved(WasteText.saved(entry, item: item))
            dismiss()
        }
    }
}

/// Zayi kayıtları: "Patates 3 kg" · neden, not, kim · saat; düzenlenebilir günde silme düğmesi (⌘Z ile geri alınır).
/// `showItem`: kalem adı da yazılır (gün düzeyindeki listede).
struct WasteEntryList: View {
    @EnvironmentObject var store: AppStore
    let date: String
    let entries: [WasteEntry]
    var showItem = true

    var body: some View {
        let editable = !store.isLocked(date)
        VStack(alignment: .leading, spacing: 6) {
            if entries.isEmpty {
                Text(WasteText.empty).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(entries) { e in
                let item = store.engine.itemsByID[e.itemID]
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(showItem ? WasteText.itemAmount(e, item: item) : WasteText.amount(e.qty, item: item))
                            .fontWeight(.medium).monospacedDigit()
                        Text([WasteText.detail(e), WasteLog.time(e)].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    if editable {
                        Button { _ = store.removeWaste(date: date, id: e.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).foregroundStyle(Brand.negative)
                            .help("Kaydı sil (⌘Z ile geri alınır)")
                            .accessibilityLabel("Zayi kaydını sil: \(WasteText.itemAmount(e, item: item))")
                    }
                }
            }
        }
    }
}

/// Günlük Sayım satırındaki Zayi hücresinin açtığı döküm: ModPos ZAYİ ürünleri ve elle girilen kayıtlar
struct WastePopover: View {
    @EnvironmentObject var store: AppStore
    let itemID: String
    let date: String
    /// Bu kalem seçili "Zayi Ekle"
    var onAdd: (String) -> Void

    var body: some View {
        let result = store.engine.calc(date: date)
        let item = store.engine.itemsByID[itemID]
        let calc = result.rows.first { $0.itemID == itemID }
        let pos = (result.analysis.contributions[itemID] ?? []).filter { $0.isWaste }.sorted { $0.amount > $1.amount }
        VStack(alignment: .leading, spacing: 10) {
            if let item, let calc {
                Text("\(item.name) · \(WasteText.section) \(WasteText.amount(calc.waste, item: item))").font(.headline)
                if !pos.isEmpty {
                    Text(WasteText.posSection).font(.subheadline.weight(.semibold))
                    ForEach(pos) { c in
                        HStack {
                            Text(c.name).lineLimit(1)
                            Spacer()
                            Text(WasteText.amount(c.amount, item: item)).monospacedDigit()
                        }
                        .font(.callout)
                    }
                }
                Text(WasteText.manualSection).font(.subheadline.weight(.semibold))
                WasteEntryList(date: date, entries: WasteLog.entries(store.data.days[date], itemID: itemID), showItem: false)
                if !store.isLocked(date) {
                    Button { onAdd(itemID) } label: { Label(WasteText.addTitle, systemImage: "plus") }
                        .buttonStyle(SoftButtonStyle())
                }
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}
