import SwiftUI
import EnvanterCore

// Elle zayi (web: ops/count/WasteDialog.tsx): "Zayi Ekle" penceresi ve zayi kayıtları listesi. Kayıtlar gün kaydının
// `wasteLog` alanına yazılır (docs/SYNC.md §1 "Elle zayi"); toplamı kalemin Zayi sütununa eklenir.

/// "Zayi Ekle": kalem (aranabilir liste), miktar (> 0), neden (zorunlu), not (en fazla 200 karakter) ve kim. Seçilen
/// kalemin o günkü ModPos zayisi ve önceden elle girilenler gösterilir (aynı zayi iki kez girilmesin); elle girilen kayıtlar
/// listelenir ve gün açıkken silinebilir. Günlük Sayım'daki Zayi düğmesi bu pencereyi o kalem seçili açar.
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
                // Seçili kalem liste kaydırılsa da görünür
                HStack(spacing: 6) {
                    Text("Kalem").font(.callout.weight(.medium))
                    if let item {
                        Text(item.name).font(.callout.weight(.semibold)).foregroundStyle(Brand.accent).lineLimit(1)
                    }
                }
                TextField("Kalem ara (ör. patates)", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if list.count == 1 { itemID = list[0].id } }
                ScrollViewReader { proxy in
                    List(list, selection: $itemID) { i in
                        HStack {
                            Text(i.name)
                            Spacer()
                            Text(i.unit.lowercased()).foregroundStyle(.secondary)
                        }
                    }
                    .frame(height: 170)
                    .onAppear {
                        // Hesap dökümünden açılınca seçili kalem listede görünsün (liste en üstten başlar)
                        guard let id = initialItemID, store.engine.itemsByID[id] != nil else { return }
                        DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
                    }
                }
                if tried && item == nil { errorText(WasteText.itemRequired) }
            }

            if let item, let hint = duplicateHint(item) {
                Label(hint, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(Brand.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Seçili kalemin bu gün elle girilen kayıtları (Günlük Sayım'daki Zayi düğmesiyle açılınca da); gün açıkken silinebilir
            if let item {
                let manual = WasteLog.entries(store.data.days[date], itemID: item.id)
                if !manual.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(WasteText.manualSection) · \(item.name)").font(.callout.weight(.semibold))
                        WasteEntryList(date: date, entries: manual, showItem: false)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tintedSurface(Color.primary, opacity: 0.04)
                }
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
/// Ayrıntı satırı kesilmez, alt satıra geçer (web ile aynı). `showItem`: kalem adı da yazılır (gün düzeyindeki listede);
/// yoksa liste o kaleme süzülüdür ve boşken kaleme özgü metin gösterilir.
struct WasteEntryList: View {
    @EnvironmentObject var store: AppStore
    let date: String
    let entries: [WasteEntry]
    var showItem = true

    var body: some View {
        let editable = !store.isLocked(date)
        VStack(alignment: .leading, spacing: 6) {
            if entries.isEmpty {
                Text(showItem ? WasteText.empty : WasteText.emptyItem).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(entries) { e in
                let item = store.engine.itemsByID[e.itemID]
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(showItem ? WasteText.itemAmount(e, item: item) : WasteText.amount(e.qty, item: item))
                            .fontWeight(.medium).monospacedDigit()
                        Text([WasteText.detail(e), WasteLog.time(e)].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
