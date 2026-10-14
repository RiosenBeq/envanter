import SwiftUI
import EnvanterCore

/// Satış raporu aktarım önizlemesi (web: ImportPreview.tsx): rapor özeti, hedef gün ve uyarılar (aynı rapor başka güne
/// aktarılmış, aynı dönem, anormal toplam, tarih farkı, okunamayan satırlar — `SalesImportCheck`; çok günlük rapor,
/// kilitli gün, mevcut satışların değişmesi, reçetesi olmayan ürünler). Aynı rapor ya da çok sayıda okunamayan satır
/// varsa "Yine de bu güne aktar" onayı istenir.
struct ImportSheet: View {
    @EnvironmentObject var store: AppStore
    let report: SalesReport
    @State private var date: String
    /// "Yine de bu güne aktar" hangi gün için işaretlendi (gün değişince yeniden sorulur)
    @State private var confirmedFor: String? = nil

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
        let warnings = SalesImportCheck.warnings(report: report, targetDate: date, data: store.data)
        let needsConfirm = SalesImportCheck.needsConfirmation(warnings)
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

            ForEach(warnings, id: \.kind) { w in warningRow(w) }
            if report.isMultiDay {
                notice(icon: "exclamationmark.triangle.fill", color: Brand.warn,
                       text: "Bu rapor birden fazla günü kapsıyor (\(report.periodText ?? "")). Günlük sayım için tek günlük rapor almanız gerekir; aksi halde fark sütunu anlamsız çıkar. Yine de seçili güne aktarabilirsiniz.")
            }
            if locked {
                notice(icon: "lock.fill", color: Brand.negative,
                       text: store.canChangeLockedDays
                        ? "\(DateKey.short(date)) günü kapatılmış (kilitli). Aktarmak için başka bir gün seçin ya da Günlük Sayım'dan kilidi açın."
                        : "\(DateKey.short(date)) günü kapatılmış (kilitli). \(CloudPermission.lockedDayPickAnotherNote)")
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
                if needsConfirm {
                    Toggle("Yine de bu güne aktar", isOn: Binding(get: { confirmedFor == date }, set: { confirmedFor = $0 ? date : nil }))
                }
                Spacer()
                Button("Vazgeç") { store.importPreview = nil }.keyboardShortcut(.cancelAction)
                Button("İçe Aktar") { store.confirmImport(report: report, date: date) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(locked || (needsConfirm && confirmedFor != date))
            }
        }
        .padding(22)
        .frame(width: 600)
    }

    /// Aktarım uyarısı: renk, simge, metin ve işlem ("O güne git" / "Rapor tarihini kullan"); okunamayan satırların listesi
    @ViewBuilder
    private func warningRow(_ w: SalesImportWarning) -> some View {
        let color: Color = w.tone == .bad ? Brand.negative : (w.tone == .warn ? Brand.warn : Brand.positive)
        let icon = w.tone == .info ? "info.circle.fill" : (w.kind == .skipped ? "questionmark.diamond.fill" : "exclamationmark.triangle.fill")
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon).foregroundStyle(color)
                Text(w.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                Spacer()
                if let d = w.date, w.kind == .duplicate || w.kind == .samePeriod {
                    Button("O güne git") {
                        store.selectedDate = d
                        store.importPreview = nil
                    }
                    .buttonStyle(SoftButtonStyle())
                } else if let d = w.date, w.kind == .dateGap {
                    Button("Rapor tarihini kullan") { date = d }.buttonStyle(SoftButtonStyle())
                }
            }
            if w.kind == .skipped {
                DisclosureGroup("Okunamayan satırları göster") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(report.skipped.prefix(20)), id: \.self) { r in
                            Text("Satır \(r.row): \(r.text.replacingOccurrences(of: "\t", with: " · "))")
                                .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        if report.skipped.count > 20 {
                            Text("… ve \(report.skipped.count - 20) satır daha").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.callout)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.12)))
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
