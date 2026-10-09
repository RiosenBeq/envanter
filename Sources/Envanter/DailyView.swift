import SwiftUI
import UniformTypeIdentifiers
import EnvanterCore

/// Sütun genişlikleri: en küçük pencere genişliğinde (1180) de taşmayacak şekilde ayarlıdır.
private enum W {
    static let input: CGFloat = 80
    static let calc: CGFloat = 80
    static let info: CGFloat = 30
    static let nameMin: CGFloat = 130
}

private enum RowFilter: String, CaseIterable, Identifiable {
    case all = "Tümü", uncounted = "Sayılmayan", problems = "Sorunlu"
    var id: String { rawValue }
}

struct DailyView: View {
    @EnvironmentObject var store: AppStore
    @FocusState private var focus: CellID?
    @State private var detailItem: String?
    @State private var dropTargeted = false
    @State private var filter: RowFilter = .all
    @State private var showNote = false
    @State private var fillMessage: String?

    var body: some View {
        let date = store.selectedDate
        let locked = store.isLocked(date)
        let result = store.engine.calc(date: date)
        let allRows = result.rows
        let rows = allRows.filter { c in
            switch filter {
            case .all: return true
            case .uncounted: return !c.isCounted
            case .problems: return c.severity?.isProblem == true || c.belowMinimum
            }
        }
        VStack(spacing: 0) {
            header(rows: allRows, date: date, locked: locked)
            Divider()
            SalesStatusBar(date: date, analysis: result.analysis)
            toolbar(date: date, locked: locked, allRows: allRows)
            gridHeader
            Divider()
            if rows.isEmpty {
                EmptyStateView(icon: filter == .uncounted ? "checkmark.circle" : "line.3.horizontal.decrease.circle",
                               title: filter == .uncounted ? "Tüm kalemler sayıldı" : "Bu filtrede kalem yok",
                               message: filter == .problems ? "Tolerans dışı fark veya kritik seviye altında stok yok." : "Filtreyi \"Tümü\" yaparak bütün kalemleri görebilirsiniz.")
            } else {
                let order = rows.map { $0.itemID }
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.itemID) { idx, calc in
                            if let item = store.engine.itemsByID[calc.itemID] {
                                DailyRow(order: order, calc: calc, item: item, date: date,
                                         focus: $focus, detail: $detailItem)
                                    .background(idx % 2 == 0 ? Color.clear : Color.primary.opacity(0.03))
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .disabled(locked)
                }
                .id(date)
            }
            Divider()
            legend(rows: allRows)
        }
        .navigationTitle("Günlük Envanter")
        .overlay { if dropTargeted { dropOverlay } }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { store.beginImport(url: url) }
            }
            return true
        }
        .onChange(of: date) { _, _ in fillMessage = nil }
    }

    // MARK: Parçalar

    private func header(rows: [ItemCalc], date: String, locked: Bool) -> some View {
        let counted = rows.filter { $0.isCounted }.count
        let problems = rows.filter { $0.severity?.isProblem == true }.count
        return HStack(spacing: 16) {
            DateNavigator()
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Sayım").foregroundStyle(.secondary)
                    Text("\(counted) / \(rows.count) kalem").fontWeight(.semibold)
                    ProgressView(value: Double(counted), total: Double(max(rows.count, 1)))
                        .frame(width: 70)
                        .tint(counted == rows.count ? Brand.ok : Brand.accent)
                }
                if counted > 0 {
                    HStack(spacing: 6) {
                        Text("Sorunlu").foregroundStyle(.secondary)
                        Pill(text: "\(problems) kalem", color: problems == 0 ? Brand.ok : Brand.negative)
                    }
                }
            }
            .font(.callout)
            Menu {
                Button("Bu günü Excel'e aktar…") { store.exportDayExcel() }
            } label: { Label("Excel", systemImage: "square.and.arrow.up") }
                .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    private func toolbar(date: String, locked: Bool, allRows: [ItemCalc]) -> some View {
        let day = store.data.days[date]
        let note = day?.note ?? ""
        let countedBy = day?.countedBy ?? ""
        return HStack(spacing: 12) {
            Picker("", selection: $filter) {
                ForEach(RowFilter.allCases) { f in Text(f.rawValue).tag(f) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 270)

            Button { showNote = true } label: {
                Label(note.isEmpty && countedBy.isEmpty ? "Not / Sayan" : (countedBy.isEmpty ? "Not var" : countedBy),
                      systemImage: note.isEmpty ? "note.text" : "note.text.badge.plus")
            }
            .buttonStyle(SoftButtonStyle(tint: note.isEmpty ? .primary : Brand.accent))
            .help(note.isEmpty ? "Güne not ekleyin, sayımı yapanı seçin" : note)
            .popover(isPresented: $showNote, arrowEdge: .bottom) { DayNotePopover(date: date).environmentObject(store) }

            if !locked {
                Button {
                    let n = store.fillUncountedWithOpening(date: date)
                    fillMessage = n == 0 ? "Doldurulacak hareketsiz kalem yok" : "\(n) kalemin kapanışı açılışla dolduruldu (⌘Z ile geri alınır)"
                } label: { Label("Hareketsizleri Doldur", systemImage: "equal.circle") }
                    .buttonStyle(SoftButtonStyle())
                    .help("Hiç hareketi (gelen, transfer, satış) olmayan ve sayılmamış kalemlere kapanış = açılış yazar")
            }
            if let fillMessage { Text(fillMessage).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
            Spacer()
            Button { store.setLocked(date, !locked) } label: {
                Label(locked ? "Kilidi Aç" : "Günü Kapat", systemImage: locked ? "lock.open" : "lock")
            }
            .buttonStyle(SoftButtonStyle(tint: locked ? Brand.warn : .primary))
            .help(locked ? "Girişleri tekrar düzenlenebilir yapar" : Term.lock.text)
            .disabled(!locked && allRows.allSatisfy { !$0.isCounted })
        }
        .padding(.horizontal, 20).padding(.bottom, 8)
    }

    private var gridHeader: some View {
        HStack(spacing: 0) {
            Text("Ürün").frame(minWidth: W.nameMin, maxWidth: .infinity, alignment: .leading).padding(.leading, 12)
            ForEach([("Açılış", Term.opening), ("Gelen", .incoming), ("Gelen\nTransfer (+)", .transfer),
                     ("Giden\nTransfer (−)", .transfer), ("Kapanış", .closing)], id: \.0) { t, term in
                Text(t).frame(width: W.input + 8).explains(term)
            }
            ForEach([("Satılan", Term.sold), ("Zaiyat", .waste), ("Fiili\nTüketim", .actualUsage), ("Fark", .diff)], id: \.0) { t, term in
                Text(t).frame(width: W.calc).foregroundStyle(.secondary).explains(term)
            }
            Color.clear.frame(width: W.info, height: 1)
        }
        .font(.caption.weight(.semibold))
        .multilineTextAlignment(.center)
        .padding(.vertical, 8).padding(.trailing, 8)
        .background(Color.primary.opacity(0.05))
    }

    private func legend(rows: [ItemCalc]) -> some View {
        let loss = rows.compactMap { $0.severity == .shortage ? $0.diffValue : nil }.reduce(0, +)
        return HStack(spacing: 16) {
            Label("Açılış boşsa önceki günün kapanışı kullanılır", systemImage: "arrow.turn.down.right")
            Label("Fark = (Satılan + Zaiyat) − Fiili Tüketim", systemImage: "function")
            Label("Kırmızı: fazla stok çıkışı · Mavi: eksik çıkış · Yeşil: tolerans içinde", systemImage: "paintpalette")
            Spacer()
            if loss < 0 {
                Text("Günün kaybı: \(Fmt.money(-loss))").fontWeight(.semibold).foregroundStyle(Brand.negative)
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 20).padding(.vertical, 8)
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 14)
            .strokeBorder(Brand.accent, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
            .background(Brand.accent.opacity(0.08))
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 40))
                    Text("Satış raporunu veya Excel envanter dosyasını buraya bırakın").font(.title3.weight(.semibold))
                }.foregroundStyle(Brand.accent)
            }
            .padding(10)
            .allowsHitTesting(false)
    }
}

// MARK: - Gün notu

private struct DayNotePopover: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let date: String
    @State private var note = ""
    @State private var countedBy = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(DateKey.short(date)) notu").font(.headline)
            HStack {
                Text("Sayımı yapan").foregroundStyle(.secondary)
                TextField("Ad Soyad", text: $countedBy).textFieldStyle(.roundedBorder).frame(width: 180)
                if !store.settings.staff.isEmpty {
                    Menu {
                        ForEach(store.settings.staff, id: \.self) { n in Button(n) { countedBy = n } }
                    } label: { Image(systemName: "person.crop.circle") }
                        .menuStyle(.borderlessButton).fixedSize()
                }
            }
            TextEditor(text: $note)
                .font(.body)
                .frame(width: 360, height: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Brand.line))
            Text("Örn: \"Dondurucu arızası, 3 kg patates atıldı\" — Excel'e ve raporlara not olarak geçer.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Kaydet") { save(); dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(16)
        .onAppear {
            note = store.data.days[date]?.note ?? ""
            countedBy = store.data.days[date]?.countedBy ?? ""
        }
        .onDisappear { save() }
    }

    private func save() {
        store.setDayNote(date, note)
        store.setCountedBy(date, countedBy)
    }
}

// MARK: - Satır

private struct DailyRow: View {
    @EnvironmentObject var store: AppStore
    let order: [String]
    let calc: ItemCalc
    let item: Item
    let date: String
    @FocusState.Binding var focus: CellID?
    @Binding var detail: String?

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name).font(.body.weight(.medium)).lineLimit(1)
                    Text(item.unit.lowercased()).font(.caption2).foregroundStyle(.secondary)
                }
                if calc.belowMinimum {
                    Image(systemName: "arrow.down.to.line.circle.fill").foregroundStyle(Brand.warn)
                        .help("Kritik seviyenin altında (en az \(Fmt.number(item.minStock ?? 0, maxFraction: item.maxFraction)) \(item.unit.lowercased()))")
                }
            }
            .frame(minWidth: W.nameMin, maxWidth: .infinity, alignment: .leading).padding(.leading, 12)

            cell(0, \.opening, placeholder: calc.openingIsAuto ? Fmt.number(calc.opening, maxFraction: item.maxFraction) : "")
                .help(calc.openingIsAuto ? "Önceki günün kapanışından otomatik geldi. Değiştirmek için bir değer yazın." : "Elle girilmiş açılış. Silerseniz önceki günün kapanışı kullanılır.")
            cell(1, \.incoming)
            cell(2, \.transferIn)
            cell(3, \.transferOut)
            cell(4, \.closing)

            calcText(calc.sold)
            calcText(calc.waste)
            if let a = calc.actual { calcText(a, bold: true) } else { Text("—").foregroundStyle(.tertiary).frame(width: W.calc) }
            diffCell
            Button { detail = item.id } label: { Image(systemName: "info.circle") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .frame(width: W.info)
                .help("Hesabın dökümü")
                .popover(isPresented: Binding(get: { detail == item.id }, set: { if !$0 { detail = nil } }), arrowEdge: .leading) {
                    ItemDetailView(itemID: item.id, date: date)
                }
        }
        .frame(height: 38)
        .padding(.trailing, 8)
    }

    private func cell(_ col: Int, _ kp: WritableKeyPath<DayEntry, Double?>, placeholder: String = "") -> some View {
        NumberCell(id: CellID(item: item.id, col: col), order: order,
                   value: store.entryBinding(item: item.id, date: date, kp),
                   placeholder: placeholder, maxFraction: item.maxFraction, focus: $focus)
            .frame(width: W.input + 8)
    }

    private func calcText(_ v: Double, bold: Bool = false) -> some View {
        Text(v == 0 ? "0" : Fmt.number(v, maxFraction: item.maxFraction))
            .monospacedDigit()
            .fontWeight(bold ? .semibold : .regular)
            .foregroundStyle(v == 0 ? .secondary : .primary)
            .frame(width: W.calc)
    }

    @ViewBuilder private var diffCell: some View {
        if let d = calc.diff, let sev = calc.severity {
            let color = Brand.color(for: sev)
            Text(sev == .zero ? "0" : Fmt.number(d, maxFraction: item.maxFraction))
                .monospacedDigit().fontWeight(.semibold)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .foregroundStyle(color)
                .background(Capsule().fill(color.opacity(sev == .withinTolerance ? 0.07 : 0.13)))
                .frame(width: W.calc)
                .help(diffHelp(d, sev))
        } else {
            Text("—").foregroundStyle(.tertiary).frame(width: W.calc).help("Kapanış sayımı girilince hesaplanır")
        }
    }

    private func diffHelp(_ d: Double, _ sev: DiffSeverity) -> String {
        let unit = item.unit.lowercased()
        let amount = Fmt.number(abs(d), maxFraction: item.maxFraction)
        let value = calc.diffValue.map { " (\(Fmt.money(abs($0))))" } ?? ""
        switch sev {
        case .zero: return "Satışlarla stok hareketi tutuyor"
        case .withinTolerance:
            return "Fark \(amount) \(unit): tolerans (±\(Fmt.number(item.tolerance ?? 0, maxFraction: item.maxFraction))) içinde, normal sayılır"
        case .shortage: return "Satışlara göre beklenenden \(amount) \(unit) FAZLA stok çıkmış\(value)"
        case .surplus: return "Satışlara göre beklenenden \(amount) \(unit) AZ stok çıkmış\(value) — sayım veya reçeteyi kontrol edin"
        }
    }
}

// MARK: - Satış durumu çubuğu

private struct SalesStatusBar: View {
    @EnvironmentObject var store: AppStore
    let date: String
    let analysis: SalesAnalysis

    var body: some View {
        let day = store.data.days[date]
        Card(padding: 12) {
            HStack(spacing: 14) {
                if let day, !day.sales.isEmpty { imported(day) } else { empty }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
    }

    @ViewBuilder private var empty: some View {
        if store.data.days[date]?.usesLegacySales == true { legacyInfo } else { emptyPrompt }
    }

    private var legacyInfo: some View {
        Group {
            Image(systemName: "clock.arrow.circlepath").font(.title2).foregroundStyle(Brand.positive)
            VStack(alignment: .leading, spacing: 2) {
                Text("Excel'den aktarılan geçmiş kayıt").font(.headline)
                Text("Bu günün Satılan ve Zaiyat değerleri Excel'de hesaplandığı haliyle aktarıldı; satış dökümü yok. ModPos raporunu aktarırsanız değerler yeniden hesaplanır.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button { store.pickAndImportFile() } label: { Label("Satış Raporu Aktar", systemImage: "doc.badge.plus") }
                .buttonStyle(SoftButtonStyle())
                .disabled(store.isLocked(date))
        }
    }

    private var emptyPrompt: some View {
        Group {
            Image(systemName: "tray.and.arrow.down").font(.title2).foregroundStyle(Brand.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Bu gün için satış raporu aktarılmadı").font(.headline)
                Text("ModPos satış raporunu aktarın; satılan 90 gr, 130 gr, patates... reçeteye göre otomatik hesaplanır. Dosyayı bu pencereye sürükleyip bırakabilirsiniz.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button { store.pickAndImportFile() } label: { Label("Dosyadan Aktar", systemImage: "doc.badge.plus") }
                .buttonStyle(PrimaryButtonStyle())
            Button { store.beginPasteImport() } label: { Label("Panodan Yapıştır", systemImage: "doc.on.clipboard") }
                .buttonStyle(SoftButtonStyle())
        }
        .disabled(store.isLocked(date))
    }

    private func imported(_ day: DayRecord) -> some View {
        let total = day.sales.reduce(0) { $0 + $1.qty }
        let stamp = day.salesImportedAt.map { Self.time.string(from: $0) } ?? ""
        return Group {
            Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(Brand.ok)
            VStack(alignment: .leading, spacing: 2) {
                Text("Satış raporu aktarıldı").font(.headline)
                Text([day.salesSource, day.salesPeriod.map { "Rapor tarihi: \($0)" },
                      "\(day.sales.count) satır · \(Fmt.number(total, maxFraction: 0)) adet", stamp.isEmpty ? nil : stamp]
                        .compactMap { $0 }.joined(separator: "  ·  "))
                    .font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 12)
            if !analysis.unknownLines.isEmpty {
                Button { store.section = .sales } label: {
                    Label("\(analysis.unknownLines.count) ürünün reçetesi yok", systemImage: "exclamationmark.triangle.fill")
                }
                .buttonStyle(SoftButtonStyle(tint: Brand.warn))
                .help("Stoğa yansımayan ürünleri görmek ve reçete tanımlamak için tıklayın")
            }
            Button { store.section = .sales } label: { Label("Dökümü Gör", systemImage: "list.bullet.rectangle") }
                .buttonStyle(SoftButtonStyle())
            Menu {
                Button("Başka dosyadan aktar…") { store.pickAndImportFile() }
                Button("Panodan yapıştır") { store.beginPasteImport() }
                Divider()
                Button("Bu günün satışlarını sil", role: .destructive) { store.clearSales(date: date) }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
                .disabled(store.isLocked(date))
        }
    }

    private static let time: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "tr_TR"); f.dateFormat = "dd.MM HH:mm"; return f
    }()
}

// MARK: - Hesap dökümü

struct ItemDetailView: View {
    @EnvironmentObject var store: AppStore
    let itemID: String
    let date: String

    var body: some View {
        let result = store.engine.calc(date: date)
        let item = store.engine.itemsByID[itemID]
        let calc = result.rows.first { $0.itemID == itemID }
        let contribs = (result.analysis.contributions[itemID] ?? []).sorted { $0.amount > $1.amount }
        VStack(alignment: .leading, spacing: 10) {
            if let item, let calc {
                let f: (Double) -> String = { Fmt.number($0, maxFraction: item.maxFraction) }
                Text("\(item.name) / \(item.unit)").font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    line("Açılış" + (calc.openingIsAuto ? " (önceki günün kapanışı)" : ""), f(calc.opening))
                    line("+ Gelen", f(calc.incoming))
                    line("+ Gelen transfer", f(calc.transferIn))
                    line("− Giden transfer", f(calc.transferOut))
                    line("− Kapanış", calc.closing.map(f) ?? "girilmedi")
                    Divider().gridCellColumns(2)
                    line("= Fiili tüketim", calc.actual.map(f) ?? "—", bold: true)
                    line("Satılan (reçeteden)", f(calc.sold))
                    line("Zaiyat", f(calc.waste))
                    line("Fark (Satılan + Zaiyat − Fiili)", calc.diff.map(f) ?? "—", bold: true)
                    if let v = calc.diffValue { line("Farkın tutarı", Fmt.money(v), bold: true) }
                    if let t = item.tolerance, t > 0 { line("Tolerans", "± " + f(t)) }
                    if let m = item.minStock, m > 0 { line("Kritik seviye", f(m)) }
                }
                .font(.callout)
                Divider()
                Text("Bu kaleme etki eden satışlar").font(.subheadline.weight(.semibold))
                if contribs.isEmpty {
                    Text("Bu gün için bu kalemi kullanan satış yok.").font(.callout).foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(spacing: 5) {
                            ForEach(contribs) { c in
                                HStack(alignment: .firstTextBaseline) {
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(c.name).lineLimit(1)
                                        Text("\(Fmt.number(c.qty, maxFraction: 0)) adet × \(Fmt.number(c.perUnit, maxFraction: 4)) \(item.recipeUnit)\(item.factor != 1 ? " × \(Fmt.number(item.factor, maxFraction: 4))" : "")")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if c.isWaste { Pill(text: "zayi", color: Brand.warn) }
                                    Text("\(f(c.amount)) \(item.unit.lowercased())").monospacedDigit().fontWeight(.medium)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 470, height: 480)
    }

    private func line(_ title: String, _ value: String, bold: Bool = false) -> some View {
        GridRow {
            Text(title).foregroundStyle(bold ? .primary : .secondary)
            Text(value).monospacedDigit().fontWeight(bold ? .semibold : .regular).gridColumnAlignment(.trailing)
        }
    }
}
