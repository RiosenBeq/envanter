import SwiftUI
import EnvanterCore

/// Sipariş: son günlerin ortalama tüketimine ve kritik seviyeye göre ne kadar sipariş verilmeli (öneri), kaydedilen
/// satın alma siparişleri ve teslim alma (gelen miktarlar Gelen sütununa işlenir; tutar tutulmaz).
struct OrdersView: View {
    @EnvironmentObject var store: AppStore
    @State private var onlyNeeded = true
    @State private var copied = false
    @State private var showCreate = false
    @State private var supplier = ""
    @State private var receiving: PurchaseOrder?

    var body: some View {
        let date = store.selectedDate
        let all = store.orderSuggestions(date: date)
        let list = onlyNeeded ? all.filter { $0.suggested > 0 } : all
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                DateNavigator(compact: true)
                Spacer()
                Button { showCreate = true } label: { Label("Sipariş Oluştur", systemImage: "cart.badge.plus") }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!store.canEditCatalog || !all.contains(where: { $0.suggested > 0 }))
                    .help(store.canEditCatalog ? "Önerilen miktarlarla bir satın alma siparişi kaydeder; mal gelince \"Teslim al\" ile Gelen'e işlenir"
                          : CloudPermission.ordersStaffNote)
                    .popover(isPresented: $showCreate, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Sipariş oluştur").font(.headline)
                            TextField("Tedarikçi (isteğe bağlı)", text: $supplier).textFieldStyle(.roundedBorder).frame(width: 260)
                            Text("\(all.filter { $0.suggested > 0 }.count) kalem önerilen miktarlarla eklenecek.").font(.callout).foregroundStyle(.secondary)
                            HStack {
                                Spacer()
                                Button("Oluştur") {
                                    store.createOrder(date: date, supplier: supplier.trimmingCharacters(in: .whitespaces))
                                    supplier = ""; showCreate = false
                                }
                                .keyboardShortcut(.defaultAction).buttonStyle(PrimaryButtonStyle())
                            }
                        }
                        .padding(16)
                    }
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
                        // Dar sütun: "≈ 4,2" (son sayıma sonraki hareketler eklenmiş tahmin) ve "sayım 09.10 + hareket";
                        // ayrıntı ipucunda (metinler web ile ortak: OrderStockText)
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(OrderStockText.value(s)).monospacedDigit()
                            if let note = OrderStockText.note(s, date: date) {
                                Text(note).lineLimit(1)
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .help(OrderStockText.help(s, date: date))
                    }.width(min: 100, ideal: 130)
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
                OrdersPanel(receiving: $receiving)
                    .frame(height: 230)
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
        .sheet(item: $receiving) { o in ReceiveSheet(order: o).environmentObject(store) }
    }

    private func num(_ v: Double, _ item: Item) -> String { Fmt.number(v, maxFraction: item.maxFraction) }
}


// MARK: - Siparişler

/// Açık ve geçmiş satın alma siparişleri
private struct OrdersPanel: View {
    @EnvironmentObject var store: AppStore
    @Binding var receiving: PurchaseOrder?

    var body: some View {
        let orders = store.data.purchaseOrders.sorted { a, b in
            a.status == .open && b.status != .open ? true : (a.status != .open && b.status == .open ? false : a.date > b.date)
        }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("Siparişler").font(.headline)
                InfoTip(term: .purchaseOrder)
                Spacer()
                Text("\(store.openOrders.count) açık").font(.callout).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20).padding(.vertical, 8)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(orders) { o in OrderRow(order: o, receiving: $receiving) }
                }
            }
        }
    }
}

private struct OrderRow: View {
    @EnvironmentObject var store: AppStore
    let order: PurchaseOrder
    @Binding var receiving: PurchaseOrder?

    var body: some View {
        let items = store.engine.itemsByID
        let summary = order.lines.compactMap { l -> String? in
            guard let item = items[l.itemID] else { return nil }
            let q = l.received ?? l.qty
            return "\(item.name) \(Fmt.number(q, maxFraction: item.isKg ? 1 : 0))"
        }.joined(separator: " · ")
        var title: String = DateKey.short(order.date)
        if !order.supplier.isEmpty { title += " · " + order.supplier }
        if let r = order.receivedOn { title += " → teslim " + DateKey.short(r) }
        return HStack(spacing: 12) {
            Pill(text: order.status.title, color: order.status == .open ? Brand.positive : (order.status == .received ? Brand.ok : .secondary))
                .frame(width: 104, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.medium)
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text("\(order.lines.count) kalem").font(.callout).foregroundStyle(.secondary)
            if order.status == .open {
                Button("Teslim al") { receiving = order }.buttonStyle(SoftButtonStyle(tint: Brand.positive))
                    .disabled(!store.canEditCatalog)
                    .help(store.canEditCatalog ? "Gelen miktarları seçili günün Gelen sütununa işler" : CloudPermission.ordersStaffNote)
            }
            Menu {
                Button("Metni kopyala") { store.copyOrder(order.id) }
                if order.status == .open { Button("İptal et") { store.cancelOrder(order.id) }.disabled(!store.canEditCatalog) }
                Divider()
                Button("Sil", role: .destructive) { store.deleteOrder(order.id) }.disabled(!store.canEditCatalog)
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Metni kopyala, iptal et ya da sil")
                .accessibilityLabel("Sipariş işlemleri")
        }
        .padding(.horizontal, 20).padding(.vertical, 6)
    }
}

/// Teslim alma: gelen miktarlar (yalnızca miktar; fiyat sorulmaz)
private struct ReceiveSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let order: PurchaseOrder
    @State private var quantities: [String: Double?] = [:]

    var body: some View {
        let items = store.engine.itemsByID
        let date = store.selectedDate
        VStack(alignment: .leading, spacing: 14) {
            Text("Teslim al").font(.title2.weight(.semibold))
            Text("Gelen miktarlar \(DateKey.long(date)) gününün Gelen sütununa eklenecek. Eksik gelen kalemin miktarını düzeltin; hiç gelmediyse 0 yazın.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                        Text(item?.name ?? l.itemID)
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
            } else if store.isLocked(date) {
                Label("Seçili gün kapatılmış; önce kilidi açın veya başka bir gün seçin.", systemImage: "lock.fill")
                    .font(.callout).foregroundStyle(Brand.negative)
            }
            HStack {
                Spacer()
                Button("Vazgeç") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Teslim Al") {
                    var q: [String: Double] = [:]
                    for l in order.lines { q[l.itemID] = (quantities[l.itemID] ?? l.qty) ?? 0 }
                    if store.receiveOrder(order.id, on: date, quantities: q) { dismiss() }
                }
                .keyboardShortcut(.defaultAction).buttonStyle(PrimaryButtonStyle())
                .disabled(store.isLocked(date) || !store.canEditCatalog)
            }
        }
        .padding(22).frame(width: 520)
    }
}
