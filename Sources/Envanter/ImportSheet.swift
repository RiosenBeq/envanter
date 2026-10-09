import SwiftUI
import EnvanterCore

struct ImportSheet: View {
    @EnvironmentObject var store: AppStore
    let report: SalesReport
    @State private var date: String

    init(report: SalesReport, initialDate: String) {
        self.report = report
        _date = State(initialValue: initialDate)
    }

    private var dateBinding: Binding<Date> {
        Binding(get: { DateKey.date(from: date) ?? Date() }, set: { date = DateKey.string(from: $0) })
    }

    var body: some View {
        let analysis = store.engine.analyze(sales: report.lines)
        let existing = store.data.days[date]?.sales.count ?? 0
        let locked = store.isLocked(date)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "tray.and.arrow.down.fill").font(.title).foregroundStyle(Brand.accent)
                VStack(alignment: .leading) {
                    Text("Satış Raporunu İçe Aktar").font(.title2.weight(.semibold))
                    Text(report.sourceName).font(.callout).foregroundStyle(.secondary)
                }
            }

            Card {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    GridRow { Text("Rapor tarihi").foregroundStyle(.secondary); Text(report.periodText ?? "Belirtilmemiş") }
                    GridRow { Text("Ürün satırı").foregroundStyle(.secondary); Text("\(report.lines.count)") }
                    GridRow { Text("Toplam adet").foregroundStyle(.secondary); Text(Fmt.number(report.totalQty, maxFraction: 0)) }
                    if let amount = report.totalAmount {
                        GridRow { Text("Satış tutarı").foregroundStyle(.secondary); Text(Fmt.money(amount)) }
                    }
                    GridRow {
                        Text("Stoğa yansıyacak").foregroundStyle(.secondary)
                        Text("\(analysis.trackedLines.count) ürün reçeteye göre hammaddeden düşülecek")
                    }
                    GridRow {
                        Text("Stok etkisi yok").foregroundStyle(.secondary)
                        Text("\(analysis.untrackedLines.count) ürün (içecek, sos vb.)")
                    }
                }
            }

            HStack {
                Text("Hangi güne aktarılsın?").font(.headline)
                Spacer()
                DatePicker("", selection: dateBinding, displayedComponents: .date).labelsHidden()
            }

            if report.isMultiDay {
                notice(icon: "exclamationmark.triangle.fill", color: Brand.warn,
                       text: "Bu rapor birden fazla günü kapsıyor (\(report.periodText ?? "")). Günlük envanter için tek günlük rapor almanız gerekir; aksi halde fark sütunu anlamsız çıkar. Yine de seçili güne aktarabilirsiniz.")
            } else if let d = report.dateFrom, d != date {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle.fill").foregroundStyle(Brand.positive)
                    Text("Raporun tarihi \(DateKey.short(d)); seçili gün \(DateKey.short(date)). Sayım ertesi sabah yapılıyorsa bu normaldir.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Rapor tarihini kullan") { date = d }.buttonStyle(SoftButtonStyle())
                }
            }
            if locked {
                notice(icon: "lock.fill", color: Brand.negative,
                       text: "\(DateKey.short(date)) günü kapatılmış (kilitli). Aktarmak için başka bir gün seçin ya da Günlük Envanter'den kilidi açın.")
            } else if existing > 0 {
                notice(icon: "arrow.triangle.2.circlepath", color: Brand.warn,
                       text: "\(DateKey.short(date)) gününün mevcut satış verisi (\(existing) satır) bu rapor ile değiştirilecek.")
            }
            if !analysis.unknownLines.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    notice(icon: "questionmark.diamond.fill", color: Brand.warn,
                           text: "\(analysis.unknownLines.count) ürünün reçetesi tanımlı değil (\(Fmt.number(analysis.unknownQty, maxFraction: 0)) adet). Bunlar stoğa yansımaz; aktarımdan sonra Satış Dökümü'nden reçete tanımlayabilirsiniz.")
                    ForEach(analysis.unknownLines.sorted { $0.qty > $1.qty }.prefix(6)) { l in
                        Text("• \(l.name) — \(Fmt.number(l.qty, maxFraction: 0)) adet").font(.callout).foregroundStyle(.secondary)
                    }
                    if analysis.unknownLines.count > 6 {
                        Text("… ve \(analysis.unknownLines.count - 6) ürün daha").font(.callout).foregroundStyle(.secondary)
                    }
                }.padding(.leading, 2)
            }

            Spacer(minLength: 4)
            HStack {
                Spacer()
                Button("Vazgeç") { store.importPreview = nil }.keyboardShortcut(.cancelAction)
                Button("İçe Aktar") { store.confirmImport(report: report, date: date) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(locked)
            }
        }
        .padding(22)
        .frame(width: 600)
    }

    private func notice(icon: String, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.12)))
    }
}

struct WorkbookImportSheet: View {
    @EnvironmentObject var store: AppStore
    let imp: WorkbookImport
    @State private var overwrite = false

    var body: some View {
        let conflicts = store.conflicts(for: imp)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "tablecells.badge.ellipsis").font(.title).foregroundStyle(Brand.accent)
                VStack(alignment: .leading) {
                    Text("Excel Verilerini İçe Aktar").font(.title2.weight(.semibold))
                    Text(imp.sourceName).font(.callout).foregroundStyle(.secondary)
                }
            }
            Card {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    GridRow {
                        Text("Geçmiş günler").foregroundStyle(.secondary)
                        Text(imp.historyDates.isEmpty ? "Yok"
                             : "\(imp.historyDates.count) gün (\(DateKey.short(imp.historyDates.first!)) – \(DateKey.short(imp.historyDates.last!)))")
                    }
                    if let d = imp.currentDate {
                        GridRow {
                            Text("Güncel gün").foregroundStyle(.secondary)
                            Text("\(DateKey.short(d)): \(imp.currentCountedItems) kalem sayımı, \(imp.currentSalesLines) satış satırı")
                        }
                    }
                    if imp.duplicatesResolved > 0 {
                        GridRow {
                            Text("Yinelenen kayıt").foregroundStyle(.secondary)
                            Text("\(imp.duplicatesResolved) kalemde aynı gün birden fazla kaydedilmiş; kapanış sayımı olan kayıt alındı")
                        }
                    }
                }
            }
            if !imp.skippedItemNames.isEmpty {
                Text("Eşleşmeyen ürün adları atlandı: \(imp.skippedItemNames.joined(separator: ", "))")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(imp.notes, id: \.self) { Text($0).font(.callout).foregroundStyle(Brand.warn) }
            if !conflicts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(conflicts.count) günün verisi uygulamada zaten var.").font(.callout.weight(.semibold))
                    Toggle("Bu günlerin üzerine yaz (uygulamadaki girişler silinir)", isOn: $overwrite)
                    if !overwrite { Text("Seçmezseniz bu günlere dokunulmaz, yalnızca yeni günler eklenir.").font(.callout).foregroundStyle(.secondary) }
                }
                .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Brand.warn.opacity(0.12)))
            }
            HStack {
                Spacer()
                Button("Vazgeç") { store.workbookPreview = nil }.keyboardShortcut(.cancelAction)
                Button("İçe Aktar") { store.confirmWorkbookImport(imp, overwrite: overwrite) }
                    .keyboardShortcut(.defaultAction).buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(22).frame(width: 600)
    }
}
