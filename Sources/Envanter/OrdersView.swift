import SwiftUI
import EnvanterCore

/// Sipariş formu: yeni sipariş (önerilen miktarlarla başlar) ya da açık siparişi düzenleme
struct OrderEditorTarget: Identifiable {
    let id = UUID()
    /// Düzenlenen sipariş (yeni siparişte nil)
    var order: PurchaseOrder?
    /// Yeni siparişin günü
    var date: String
    /// Formun başlangıç satırları
    var lines: [OrderLine]
}

/// Teslim alma penceresi: gün, başlangıç miktarları ve "Gelen'e eklemeden"
struct ReceiveTarget: Identifiable {
    var order: PurchaseOrder
    var date: String
    /// Başlangıç miktarları (verilmeyen kalemde sipariş miktarı)
    var quantities: [String: Double] = [:]
    var addToIncoming = true
    var id: String { order.id + (addToIncoming ? "+" : "=") }
}

/// Sipariş: son günlerin ortalama tüketimine ve kritik seviyeye göre ne kadar sipariş verilmeli (öneri), kaydedilen
/// satın alma siparişleri (düzenlenebilir), teslim alma (gelen miktarlar Gelen sütununa işlenir; tutar tutulmaz) ya da
/// Gelen elle girildiyse "Teslim alındı say".
struct OrdersView: View {
    @EnvironmentObject var store: AppStore
    @State private var onlyNeeded = true
    @State private var copied = false
    @State private var editor: OrderEditorTarget?
    @State private var receiving: ReceiveTarget?

    var body: some View {
        let date = store.selectedDate
        let all = store.orderSuggestions(date: date)
        let list = onlyNeeded ? all.filter { $0.suggested > 0 } : all
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                DateNavigator(compact: true)
                Spacer()
                Button {
                    editor = OrderEditorTarget(order: nil, date: date,
                                               lines: all.filter { $0.suggested > 0 }.map { OrderLine(itemID: $0.item.id, qty: $0.suggested) })
                } label: { Label("Sipariş Oluştur", systemImage: "cart.badge.plus") }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!store.canEditCatalog)
                    .help(store.canEditCatalog ? "Önerilen miktarlarla başlayan bir sipariş formu açar (miktarlar değiştirilebilir); mal gelince \"Teslim al\" ile Gelen'e işlenir"
                          : CloudPermission.ordersStaffNote)
                Button {
                    store.copyOrderText(date: date)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                } label: {
                    Label(copied ? "Kopyalandı" : "Listeyi Kopyala", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(SoftButtonStyle())
                .help("Tedarikçiye WhatsApp / e-posta ile göndermek için düz metin olarak kopyalar")
                Button { store.exportOrdersExcel(date: date) } label: { Label("Excel", systemImage: "square.and.arrow.up") }
                    .buttonStyle(SoftButtonStyle())
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            Divider()

            HStack(spacing: 18) {
                Picker("Ortalama", selection: store.settingsBinding(\.orderLookbackDays)) {
                    // Web panelinde 1–120 gün arası herhangi bir değer seçilebilir; seçili değer listede yoksa ekle
                    ForEach(Array(Set([7, 14, 30, store.settings.orderLookbackDays])).sorted(), id: \.self) { days in
                        Text("Son \(days) gün").tag(days)
                    }
                }
                .frame(width: 210)
                .help("Günlük tüketim bu dönemin ortalamasından hesaplanır")
                .disabled(!store.canEditCatalog)
                Stepper(value: store.settingsBinding(\.orderCoverDays), in: 1...30, step: 1) {
                    Text("\(Fmt.number(store.settings.orderCoverDays, maxFraction: 0)) günlük ihtiyaç")
                        .monospacedDigit()
                }
                .help("Sipariş, bu kadar günü (kritik seviye üstünde) karşılayacak şekilde önerilir")
                .disabled(!store.canEditCatalog)
                Toggle("Yalnızca sipariş gerekenler", isOn: $onlyNeeded)
                InfoTip(term: .orderSuggestion)
                if !store.canEditCatalog { ReadOnlyNote(text: CloudPermission.ordersStaffNote) }
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 10)

            if list.isEmpty {
                EmptyStateView(icon: "checkmark.seal",
                               title: all.allSatisfy({ $0.sampleDays == 0 }) ? "Tüketim verisi yok" : "Sipariş gerekmiyor",
                               message: all.allSatisfy({ $0.sampleDays == 0 })
                                ? "Öneri, son günlerin sayım (fiili tüketim) veya satış verisinden hesaplanır. Birkaç gün sayım girdikten sonra burada görünür."
                                : "Mevcut stoklar seçilen gün sayısına ve kritik seviyelere yetiyor.")
            } else {
                Table(list) {
                    TableColumn("Kalem") { s in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.item.name).fontWeight(.medium)
                            Text(s.item.unit.lowercased()).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    TableColumn("Mevcut stok") { s in
                        // Dar sütun: "≈ 4,2" (son sayıma sonraki hareketler eklenmiş tahmin) ve "09.10 sayımı";
                        // ayrıntı ipucunda
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(stockText(s)).monospacedDigit()
                            if let d = s.stockDate, d != store.selectedDate {
                                Text("\(DateKey.dayMonth(d)) sayımı").lineLimit(1)
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .help(stockHelp(s))
                    }.width(100)
                    TableColumn("Siparişte") { s in
                        Text(s.onOrder > 0 ? num(s.onOrder, s.item) : "—").monospacedDigit()
                            .foregroundStyle(s.onOrder > 0 ? Brand.positive : Color.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .help("Açık siparişlerde teslim alınmayı bekleyen miktar; öneriden düşülür")
                    }.width(80)
                    TableColumn("Günlük tüketim") { s in
                        Text(s.sampleDays > 0 ? Fmt.number(s.dailyUsage, maxFraction: s.item.isKg ? 2 : 1) : "—").monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .help(s.sampleDays > 0 ? "\(s.sampleDays) günün ortalaması" : "Veri yok")
                    }.width(110)
                    TableColumn("Kaç gün yeter") { s in
                        Text(s.daysOfCover.map { Fmt.number($0, maxFraction: 1) + " gün" } ?? "—").monospacedDigit()
                            .foregroundStyle((s.daysOfCover ?? 99) < store.settings.orderCoverDays ? Brand.negative : Color.primary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }.width(100)
                    TableColumn("Kritik seviye") { s in
                        Text(s.item.minStock.map { num($0, s.item) } ?? "—").monospacedDigit().foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }.width(90)
                    TableColumn("Hedef stok") { s in
                        Text(Fmt.number(s.target, maxFraction: s.item.isKg ? 2 : 0)).monospacedDigit().foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }.width(90)
                    TableColumn("Önerilen sipariş") { s in
                        Group {
                            if s.suggested > 0 {
                                Text("\(num(s.suggested, s.item)) \(s.item.unit.lowercased())")
                                    .fontWeight(.bold).foregroundStyle(Brand.accent)
                            } else {
                                Text("Yeterli").foregroundStyle(Brand.ok)
                            }
                        }
                        .monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                    }.width(130)
                }
            }
            if !store.data.purchaseOrders.isEmpty {
                Divider()
                OrdersPanel(receiving: $receiving, editor: $editor)
                    .frame(height: 260)
            }
            Divider()
            HStack(spacing: 14) {
                Label("Önerilen = günlük tüketim × gün sayısı + kritik seviye − mevcut stok − siparişte", systemImage: "function")
                Label("Kritik seviye Stok Kalemleri ekranından girilir", systemImage: "shippingbox")
                Spacer()
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 20).padding(.vertical, 8)
        }
        .navigationTitle("Sipariş")
        .sheet(item: $receiving) { t in ReceiveSheet(target: t).environmentObject(store) }
        .sheet(item: $editor) { t in OrderEditorSheet(target: t).environmentObject(store) }
    }

    private func num(_ v: Double, _ item: Item) -> String { Fmt.number(v, maxFraction: item.maxFraction) }

    /// Mevcut stok: son sayımdan sonra gelen/transfer/satış eklenmişse tahmindir ("≈")
    private func stockText(_ s: OrderSuggestion) -> String {
        guard let v = s.stock else { return "—" }
        return (s.stock != s.countedStock ? "≈ " : "") + num(v, s.item)
    }

    private func stockHelp(_ s: OrderSuggestion) -> String {
        guard let counted = s.countedStock, let d = s.stockDate else { return "Henüz sayım yok" }
        let base = "Son sayım (\(DateKey.short(d))): \(num(counted, s.item))"
        guard let now = s.stock, now != counted else { return base }
        return base + "; sonraki günlerin gelen/transfer ve satışlarıyla tahmini \(num(now, s.item))"
    }
}


// MARK: - Siparişler

/// Açık ve geçmiş satın alma siparişleri; 3 günden eski açık siparişler için uyarı
private struct OrdersPanel: View {
    @EnvironmentObject var store: AppStore
    @Binding var receiving: ReceiveTarget?
    @Binding var editor: OrderEditorTarget?

    var body: some View {
        let orders = store.data.purchaseOrders.sorted { a, b in
            a.status == .open && b.status != .open ? true : (a.status != .open && b.status == .open ? false : a.date > b.date)
        }
        let stale = Purchasing.staleNotice(Purchasing.staleOrders(store.data.purchaseOrders, asOf: store.selectedDate))
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("Siparişler").font(.headline)
                InfoTip(term: .purchaseOrder)
                Spacer()
                Text("\(store.openOrders.count) açık").font(.callout).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20).padding(.vertical, 8)
            if let stale {
                Label(stale, systemImage: "clock.badge.exclamationmark")
                    .font(.callout).foregroundStyle(Brand.warn)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20).padding(.bottom, 6)
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(orders) { o in OrderRow(order: o, receiving: $receiving, editor: $editor) }
                }
            }
        }
    }
}

private struct OrderRow: View {
    @EnvironmentObject var store: AppStore
    let order: PurchaseOrder
    @Binding var receiving: ReceiveTarget?
    @Binding var editor: OrderEditorTarget?
    @State private var confirmCancel = false
    @State private var confirmDelete = false

    /// "23.08.2026 · Et Tedarikçisi → teslim 24.08.2026"
    private var title: String {
        var t = DateKey.short(order.date)
        if !order.supplier.isEmpty { t += " · " + order.supplier }
        if let r = order.receivedOn { t += " → teslim " + DateKey.short(r) }
        return t
    }

    var body: some View {
        let items = store.engine.itemsByID
        let asOf = store.selectedDate
        let summary = order.lines.compactMap { l -> String? in
            guard let item = items[l.itemID] else { return nil }
            let q = l.received ?? l.qty
            return "\(item.name) \(Fmt.number(q, maxFraction: item.isKg ? 1 : 0))"
        }.joined(separator: " · ")
        let waiting = Purchasing.waitingText(order, asOf: asOf)
        let stale = Purchasing.isStale(order, asOf: asOf)
        let hint = order.status == .open && store.canEditCatalog ? Purchasing.incomingHint(order: order, data: store.data, asOf: asOf) : nil
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Pill(text: order.status.title, color: order.status == .open ? Brand.positive : (order.status == .received ? Brand.ok : .secondary))
                    .frame(width: 104, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).fontWeight(.medium)
                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let waiting {
                        Label(waiting, systemImage: "clock")
                            .font(.caption2.weight(stale ? .semibold : .regular))
                            .foregroundStyle(stale ? Brand.warn : Color.secondary)
                    }
                    if let note = order.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                        Text("Not: \(note)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            .help(note)
                    }
                    if order.receivedWithoutIncoming == true {
                        Text("Gelen elle girilmişti; Gelen'e eklenmedi").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text("\(order.lines.count) kalem").font(.callout).foregroundStyle(.secondary)
                if order.status == .open {
                    Button("Teslim al") { receiving = ReceiveTarget(order: order, date: asOf) }
                        .buttonStyle(SoftButtonStyle(tint: Brand.positive))
                        .disabled(!store.canEditCatalog)
                        .help(store.canEditCatalog ? "Gelen miktarları seçilen günün Gelen sütununa işler" : CloudPermission.ordersStaffNote)
                } else if order.status == .cancelled {
                    Button("Yeniden Aç") { store.reopenOrder(order.id) }
                        .buttonStyle(SoftButtonStyle())
                        .disabled(!store.canEditCatalog)
                        .help(store.canEditCatalog ? "Siparişi yeniden açar: miktarları yeniden öneriden düşülür" : CloudPermission.ordersStaffNote)
                }
                Menu {
                    Button("Metni kopyala") { store.copyOrder(order.id) }
                    if order.status == .open {
                        Button("Düzenle…") { editor = OrderEditorTarget(order: order, date: order.date, lines: order.lines) }
                            .disabled(!store.canEditCatalog)
                        Button("İptal et…") { confirmCancel = true }.disabled(!store.canEditCatalog)
                    }
                    if order.status == .cancelled {
                        Button("Yeniden Aç") { store.reopenOrder(order.id) }.disabled(!store.canEditCatalog)
                    }
                    Divider()
                    Button("Sil…", role: .destructive) { confirmDelete = true }.disabled(!store.canEditCatalog)
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Metni kopyala, düzenle, iptal et ya da sil")
                    .accessibilityLabel("Sipariş işlemleri")
            }
            if let hint {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle.fill").foregroundStyle(Brand.positive)
                    Text(OrderTexts.hint(hint, items: items) + " Öyleyse Gelen'e eklemeden teslim alındı sayın.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Teslim alındı say") {
                        receiving = ReceiveTarget(order: order, date: hint.date, quantities: OrderTexts.hintQuantities(order, hint), addToIncoming: false)
                    }
                    .buttonStyle(SoftButtonStyle(tint: Brand.positive))
                }
                .padding(.leading, 116)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 6)
        .confirmationDialog("Sipariş iptal edilsin mi?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("İptal et", role: .destructive) { store.cancelOrder(order.id) }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("\(title) iptal edilir; siparişteki miktarlar öneriden düşülmez.")
        }
        .confirmationDialog("Sipariş silinsin mi?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Sil", role: .destructive) { store.deleteOrder(order.id) }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("\(title) kaydı kalıcı olarak silinir. Teslim alınmışsa Gelen sütununa işlenen miktarlar değişmez.")
        }
    }
}

/// Sipariş ekranı metinleri (web: src/components/ops/orders/logic.ts ile aynı)
enum OrderTexts {
    /// "140 adet", "2,5 kg"
    static func amount(_ v: Double, _ item: Item?) -> String {
        "\(Fmt.number(v, maxFraction: item?.maxFraction ?? 2)) \(item?.unit.lowercased() ?? "birim")"
    }

    /// "31.08.2026 günü bu kalemlere Gelen girilmiş: 90 Gr 420 adet. Bu teslimat bu siparişten mi?"
    static func hint(_ hint: Purchasing.IncomingHint, items: [String: Item]) -> String {
        let parts = hint.lines.map { "\(items[$0.itemID]?.name ?? $0.itemID) \(amount($0.incoming, items[$0.itemID]))" }
        return "\(DateKey.short(hint.date)) günü bu kalemlere Gelen girilmiş: \(parts.joined(separator: ", ")). Bu teslimat bu siparişten mi?"
    }

    /// "Teslim alındı say" başlangıç miktarları: o gün Gelen'i olan satır en çok sipariş miktarı kadar, diğerleri 0
    static func hintQuantities(_ order: PurchaseOrder, _ hint: Purchasing.IncomingHint) -> [String: Double] {
        var out: [String: Double] = [:]
        for l in order.lines { out[l.itemID] = hint.lines.first(where: { $0.itemID == l.itemID }).map { min($0.incoming, l.qty) } ?? 0 }
        return out
    }
}

/// Sipariş formu (web: OrderEditorDialog): miktarlar, "Kalem ekle" (arama), tedarikçi ve tedarikçiye not.
/// Miktarı 0 olan satır kaydedilmez.
private struct OrderEditorSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let target: OrderEditorTarget
    @State private var supplier: String
    @State private var note: String
    @State private var rows: [DraftRow]
    @State private var query = ""
    /// "Kalem ara" odakta: Return ilk eşleşeni ekler, varsayılan düğme (Oluştur/Kaydet) çalışmaz (web ile aynı)
    @FocusState private var searchFocused: Bool

    struct DraftRow: Identifiable, Equatable {
        var itemID: String
        var qty: Double?
        var id: String { itemID }
    }

    init(target: OrderEditorTarget) {
        self.target = target
        _supplier = State(initialValue: target.order?.supplier ?? "")
        _note = State(initialValue: target.order?.note ?? "")
        _rows = State(initialValue: target.lines.map { DraftRow(itemID: $0.itemID, qty: $0.qty) })
    }

    private var lines: [OrderLine] { rows.map { OrderLine(itemID: $0.itemID, qty: $0.qty ?? 0) } }
    private var hasLines: Bool { rows.contains { ($0.qty ?? 0) > 0 } }

    /// Satırın miktarı (kalem kimliğiyle; satır silinince eski bağlama yazılmaz)
    private func qtyBinding(_ id: String) -> Binding<Double?> {
        Binding(get: { rows.first(where: { $0.itemID == id })?.qty },
                set: { v in if let i = rows.firstIndex(where: { $0.itemID == id }) { rows[i].qty = v } })
    }

    private var addable: [Item] {
        let q = TextFold.ascii(query.trimmingCharacters(in: .whitespacesAndNewlines))
        return store.data.items.filter { item in
            item.active && !rows.contains { $0.itemID == item.id } && (q.isEmpty || TextFold.ascii(item.name).contains(q))
        }
    }

    private func add(_ item: Item) {
        rows.append(DraftRow(itemID: item.id, qty: nil))
        query = ""
    }

    /// Arama alanındayken Return'e bağlı kısayol yok (yoksa macOS siparişi aranan kalem eklenmeden kaydeder)
    private var submitShortcut: KeyboardShortcut? { searchFocused ? nil : .defaultAction }

    private var subtitle: String {
        if let o = target.order {
            return "\(DateKey.short(o.date)) tarihli açık sipariş. Miktarları değiştirebilir, kalem ekleyip çıkarabilirsiniz."
        }
        return rows.isEmpty
            ? "\(DateKey.short(target.date)) için önerilen sipariş yok; \"Kalem ekle\" ile kalemleri seçin."
            : "\(rows.count) kalem önerilen miktarlarla \(DateKey.short(target.date)) tarihli siparişe eklendi; miktarları değiştirebilir, kalem ekleyip çıkarabilirsiniz. Mal gelince \"Teslim al\" ile Gelen'e işlenir."
    }

    var body: some View {
        let items = store.engine.itemsByID
        let choices = addable
        let addTitle: String = choices.isEmpty ? (query.isEmpty ? "Eklenecek kalem kalmadı" : "Eşleşen kalem yok") : "Kalem ekle (\(choices.count))"
        VStack(alignment: .leading, spacing: 14) {
            Text(target.order == nil ? "Sipariş oluştur" : "Siparişi düzenle").font(.title2.weight(.semibold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Tedarikçi (isteğe bağlı)", text: $supplier).textFieldStyle(.roundedBorder)
            if rows.isEmpty {
                Text("Siparişte henüz kalem yok.").font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        ForEach(rows) { row in
                            GridRow {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(items[row.itemID]?.name ?? row.itemID).lineLimit(1)
                                    if items[row.itemID] == nil {
                                        Text("(kalem silinmiş)").font(.caption).foregroundStyle(Brand.warn)
                                    }
                                }
                                OptionalDecimalField(value: qtyBinding(row.itemID), placeholder: "0",
                                                     maxFraction: items[row.itemID]?.maxFraction ?? 3, width: 100, live: true)
                                Text(items[row.itemID]?.unit.lowercased() ?? "").font(.caption).foregroundStyle(.secondary)
                                Button {
                                    rows.removeAll { $0.itemID == row.itemID }
                                } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless)
                                    .help("Siparişten çıkar")
                                    .accessibilityLabel("\(items[row.itemID]?.name ?? row.itemID) kalemini siparişten çıkar")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: min(CGFloat(rows.count) * 32, 260), maxHeight: 260)
            }
            HStack(spacing: 8) {
                TextField("Kalem ara", text: $query)
                    .textFieldStyle(.roundedBorder).frame(width: 200)
                    .focused($searchFocused)
                    .onSubmit {
                        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !q.isEmpty, let first = choices.first { add(first) }
                    }
                    .help("Yazıp Return'e basınca ilk eşleşen kalem eklenir")
                Menu {
                    ForEach(choices) { item in
                        Button("\(item.name) (\(item.unit.lowercased()))") { add(item) }
                    }
                } label: {
                    Label(addTitle, systemImage: "plus")
                }
                .menuStyle(.borderlessButton).fixedSize()
                .disabled(choices.isEmpty)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Not (tedarikçiye)").font(.callout.weight(.medium))
                TextField("ör. Sabah 9'dan önce getirin", text: $note, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: note) { _, v in
                        if v.count > Purchasing.noteLimit { note = String(v.prefix(Purchasing.noteLimit)) }
                    }
                Text("İsteğe bağlı; kopyalanan sipariş metninin sonuna eklenir.").font(.caption).foregroundStyle(.secondary)
            }
            if !rows.isEmpty && !hasLines {
                Label("Siparişte miktarı girilmiş kalem yok.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(Brand.negative)
            }
            if !store.canEditCatalog {
                Label(CloudPermission.ordersStaffNote, systemImage: "lock.fill").font(.callout).foregroundStyle(Brand.negative)
            }
            HStack {
                Spacer()
                Button("Vazgeç") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(target.order == nil ? "Oluştur" : "Kaydet") {
                    let ok: Bool
                    if let o = target.order {
                        ok = store.updateOrder(o.id, supplier: supplier, note: note, lines: lines)
                    } else {
                        ok = store.createOrder(date: target.date, supplier: supplier, note: note, lines: lines)
                    }
                    if ok { dismiss() }
                }
                .keyboardShortcut(submitShortcut).buttonStyle(PrimaryButtonStyle())
                .disabled(!hasLines || !store.canEditCatalog)
            }
        }
        .padding(22).frame(width: 540)
    }
}

/// Teslim alma: gelen miktarlar (yalnızca miktar; fiyat sorulmaz). "Gelen'e eklemeden teslim alındı say": teslimat
/// Günlük Sayım'da elle girildiyse sipariş yalnızca kapanır (Gelen iki kez sayılmaz).
private struct ReceiveSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let order: PurchaseOrder
    @State private var date: String
    @State private var addToIncoming: Bool
    @State private var quantities: [String: Double?]

    init(target: ReceiveTarget) {
        order = target.order
        _date = State(initialValue: target.date)
        _addToIncoming = State(initialValue: target.addToIncoming)
        _quantities = State(initialValue: target.quantities.mapValues { Optional($0) })
    }

    private var dateBinding: Binding<Date> {
        Binding(get: { DateKey.date(from: date) ?? Date() }, set: { date = DateKey.string(from: $0) })
    }

    private func incoming(_ itemID: String) -> Double { store.data.days[date]?.entries[itemID]?.incoming ?? 0 }

    var body: some View {
        let items = store.engine.itemsByID
        let blocked = addToIncoming && store.isLocked(date)
        let alreadyEntered = order.lines.contains { incoming($0.itemID) > 0 }
        let info: String = addToIncoming
            ? "Gelen miktarlar \(DateKey.long(date)) gününün Gelen sütununa eklenecek. Eksik gelen kalemin miktarını düzeltin; hiç gelmediyse 0 yazın."
            : "Sipariş \(DateKey.long(date)) gününe teslim alındı sayılacak; Gelen sütununa dokunulmaz."
        VStack(alignment: .leading, spacing: 14) {
            Text("Teslim al").font(.title2.weight(.semibold))
            Text(info)
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Teslim günü").font(.headline)
                Spacer()
                DatePicker("", selection: dateBinding, displayedComponents: .date).labelsHidden()
            }
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Gelen'e eklemeden teslim alındı say", isOn: Binding(get: { !addToIncoming }, set: { addToIncoming = !$0 }))
                Text("Teslimat Günlük Sayım'da Gelen olarak elle girildiyse seçin: sipariş kapanır, Gelen iki kez sayılmaz.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    Text("Kalem").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text("Sipariş").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text("Gelen").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    // Birim sütunu (başlıksız)
                    Color.clear.frame(width: 1, height: 1)
                }
                ForEach(order.lines) { l in
                    let item = items[l.itemID]
                    GridRow {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item?.name ?? l.itemID)
                            if item == nil {
                                Text("Kalem silinmiş").font(.caption).foregroundStyle(Brand.warn)
                            }
                            if incoming(l.itemID) > 0 {
                                Text("Bu günde zaten Gelen: \(OrderTexts.amount(incoming(l.itemID), item))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Text("\(Fmt.number(l.qty, maxFraction: 2)) \(item?.unit.lowercased() ?? "")").monospacedDigit().foregroundStyle(.secondary)
                        OptionalDecimalField(value: Binding(get: { quantities[l.itemID] ?? l.qty }, set: { quantities[l.itemID] = $0 }),
                                             placeholder: "0", maxFraction: 3, width: 100, live: true)
                        Text(item?.unit.lowercased() ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if !store.canEditCatalog {
                Label(CloudPermission.ordersStaffNote, systemImage: "lock.fill")
                    .font(.callout).foregroundStyle(Brand.negative)
            } else if blocked {
                Label("Seçili gün kapatılmış; önce kilidi açın veya başka bir gün seçin.", systemImage: "lock.fill")
                    .font(.callout).foregroundStyle(Brand.negative)
            } else if addToIncoming && alreadyEntered {
                Label("Bu günde bu kalemlere zaten Gelen girilmiş. Teslimat elle girildiyse \"Gelen'e eklemeden teslim alındı say\"ı seçin; yoksa miktarlar mevcut Gelen'in üstüne eklenir.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(Brand.warn).fixedSize(horizontal: false, vertical: true)
            }
            if date > DateKey.today() {
                Label("İleri tarihli teslim günü seçtiniz.", systemImage: "calendar.badge.exclamationmark")
                    .font(.callout).foregroundStyle(Brand.warn)
            }
            HStack {
                Spacer()
                Button("Vazgeç") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(addToIncoming ? "Teslim Al" : "Teslim alındı say") {
                    var q: [String: Double] = [:]
                    for l in order.lines { q[l.itemID] = (quantities[l.itemID] ?? l.qty) ?? 0 }
                    if store.receiveOrder(order.id, on: date, quantities: q, addToIncoming: addToIncoming) { dismiss() }
                }
                .keyboardShortcut(.defaultAction).buttonStyle(PrimaryButtonStyle())
                .disabled(blocked || !store.canEditCatalog)
            }
        }
        .padding(22).frame(width: 560)
    }
}
