import SwiftUI
import EnvanterCore

/// Sipariş önerisi: son günlerin ortalama tüketimine ve kritik seviyeye göre ne kadar sipariş verilmeli.
struct OrdersView: View {
    @EnvironmentObject var store: AppStore
    @State private var onlyNeeded = true
    @State private var copied = false

    var body: some View {
        let date = store.selectedDate
        let all = store.orderSuggestions(date: date)
        let list = onlyNeeded ? all.filter { $0.suggested > 0 } : all
        let totalCost = all.compactMap { $0.suggested > 0 ? $0.cost : nil }.reduce(0, +)
        let hasCosts = all.contains { $0.item.unitCost != nil }
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                DateNavigator(compact: true)
                Spacer()
                Button {
                    store.copyOrderText(date: date)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                } label: {
                    Label(copied ? "Kopyalandı" : "Listeyi Kopyala", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(PrimaryButtonStyle())
                .help("Tedarikçiye WhatsApp / e-posta ile göndermek için düz metin olarak kopyalar")
                Button { store.exportOrdersExcel(date: date) } label: { Label("Excel", systemImage: "square.and.arrow.up") }
                    .buttonStyle(SoftButtonStyle())
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            Divider()

            HStack(spacing: 18) {
                Picker("Ortalama", selection: store.settingsBinding(\.orderLookbackDays)) {
                    Text("Son 7 gün").tag(7)
                    Text("Son 14 gün").tag(14)
                    Text("Son 30 gün").tag(30)
                }
                .frame(width: 210)
                .help("Günlük tüketim bu dönemin ortalamasından hesaplanır")
                Stepper(value: store.settingsBinding(\.orderCoverDays), in: 1...30, step: 1) {
                    Text("\(Fmt.number(store.settings.orderCoverDays, maxFraction: 0)) günlük ihtiyaç")
                        .monospacedDigit()
                }
                .help("Sipariş, bu kadar günü (kritik seviye üstünde) karşılayacak şekilde önerilir")
                Toggle("Yalnızca sipariş gerekenler", isOn: $onlyNeeded)
                Spacer()
                if hasCosts && totalCost > 0 {
                    Text("Tahmini tutar: \(Fmt.money(totalCost))").font(.callout.weight(.semibold))
                }
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
                    TableColumn("Son stok") { s in
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(s.stock.map { num($0, s.item) } ?? "—").monospacedDigit()
                            if let d = s.stockDate, d != store.selectedDate {
                                Text(DateKey.short(d)).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }.width(90)
                    TableColumn("Günlük tüketim") { s in
                        Text(s.sampleDays > 0 ? num(s.dailyUsage, s.item) : "—").monospacedDigit()
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
                        Text(num(s.target, s.item)).monospacedDigit().foregroundStyle(.secondary)
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
                    TableColumn("Tutar") { s in
                        Text(s.suggested > 0 ? (s.cost.map { Fmt.money($0) } ?? "—") : "").monospacedDigit().foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }.width(100)
                }
            }
            Divider()
            HStack(spacing: 14) {
                Label("Önerilen = günlük tüketim × gün sayısı + kritik seviye − son stok", systemImage: "function")
                Label("Kritik seviye ve maliyet Stok Kalemleri ekranından girilir", systemImage: "shippingbox")
                Spacer()
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 20).padding(.vertical, 8)
        }
        .navigationTitle("Sipariş Önerisi")
    }

    private func num(_ v: Double, _ item: Item) -> String { Fmt.number(v, maxFraction: item.maxFraction) }
}
