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

/// "Zayi Ekle" penceresi isteği (kalem seçili gelebilir)
private struct WasteRequest: Identifiable {
    let id = UUID()
    var itemID: String?
}

struct DailyView: View {
    @EnvironmentObject var store: AppStore
    @FocusState private var focus: CellID?
    @State private var detailItem: String?
    @State private var dropTargeted = false
    @State private var filter: RowFilter = .all
    @State private var showNote = false
    @State private var fillMessage: String?
    @State private var wasteRequest: WasteRequest?
    /// Zayi hücresi açık olan satır (döküm penceresi)
    @State private var wasteDetail: String?
    @State private var showWasteList = false

    var body: some View {
        let date = store.selectedDate
        let locked = store.isLocked(date)
        let result = store.engine.calc(date: date)
        let allRows = result.rows
        let rows = allRows.filter { c in
            switch filter {
            case .all: return true
            case .uncounted: return !c.isCounted
            case .problems: return c.severity?.isProblem == true || c.belowMinimum || c.openingJumpIsProblem
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
                               message: filter == .problems ? "Tolerans dışı fark, kritik seviye altında stok ya da beklenenden farklı elle açılış yok." : "Filtreyi \"Tümü\" yaparak bütün kalemleri görebilirsiniz.")
            } else {
                let order = rows.map { $0.itemID }
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.itemID) { idx, calc in
                            if let item = store.engine.itemsByID[calc.itemID] {
                                DailyRow(order: order, calc: calc, item: item, date: date,
                                         focus: $focus, detail: $detailItem, wasteDetail: $wasteDetail,
                                         onAddWaste: { openWaste($0) })
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
        .navigationTitle("Günlük Sayım")
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
        .sheet(item: $wasteRequest) { r in
            WasteSheet(date: date, initialItemID: r.itemID, onSaved: { fillMessage = $0 + " (⌘Z ile geri alınır)" })
                .environmentObject(store)
        }
    }

    /// "Zayi Ekle" (açık döküm penceresi önce kapanır; sayfa penceresi onun ardından açılır)
    private func openWaste(_ itemID: String?) {
        let wasOpen = wasteDetail != nil || showWasteList
        wasteDetail = nil
        showWasteList = false
        if wasOpen {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { wasteRequest = WasteRequest(itemID: itemID) }
        } else {
            wasteRequest = WasteRequest(itemID: itemID)
        }
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
                let wasteEntries = store.data.days[date]?.wasteLog ?? []
                if !wasteEntries.isEmpty {
                    // Günün elle girilen zayi kayıtları (silme düğmeleriyle)
                    Button(WasteText.listLink(wasteEntries.count)) { showWasteList = true }
                        .buttonStyle(.link)
                        .popover(isPresented: $showWasteList, arrowEdge: .bottom) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("\(DateKey.short(date)) zayi kayıtları").font(.headline)
                                WasteEntryList(date: date, entries: wasteEntries)
                                if !locked {
                                    Button { openWaste(nil) } label: { Label(WasteText.addTitle, systemImage: "plus") }
                                        .buttonStyle(SoftButtonStyle())
                                }
                            }
                            .padding(16).frame(width: 380)
                            .environmentObject(store)
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
                Label(noteButtonTitle(note: note, countedBy: countedBy), systemImage: note.isEmpty ? "note.text" : "note.text.badge.plus")
            }
            .buttonStyle(SoftButtonStyle(tint: note.isEmpty ? .primary : Brand.accent))
            .help(note.isEmpty ? "Güne not ekleyin, sayımı yapanı seçin" : note)
            .popover(isPresented: $showNote, arrowEdge: .bottom) { DayNotePopover(date: date).environmentObject(store) }

            // Elle zayi: kapatılmış günde kapalı (nedeni ipucunda)
            Button { openWaste(nil) } label: { Label(WasteText.addTitle, systemImage: "plus.circle") }
                .buttonStyle(SoftButtonStyle())
                .disabled(locked)
                .help(locked ? WasteText.lockedNote : "Bozulan, yanan, düşen ya da iade edilen malı girin")

            if !locked {
                // Satış raporu olmadan hangi kalemin hareketsiz olduğu bilinemez: düğme kapalı, nedeni ipucunda
                let hasSales = day?.hasSalesData ?? false
                Button {
                    let r = store.fillUncountedWithOpening(date: date)
                    if r.refusal == .noSales {
                        fillMessage = OpeningText.fillNoSales
                    } else {
                        fillMessage = r.count == 0 ? OpeningText.fillNothing : OpeningText.fillDone(r.count) + " (⌘Z ile geri alınır)"
                    }
                } label: { Label("Hareketsizleri Doldur", systemImage: "equal.circle") }
                    .buttonStyle(SoftButtonStyle())
                    .disabled(!hasSales)
                    .help(hasSales ? OpeningText.fillHelp : OpeningText.fillNoSales)
            }
            if let fillMessage { Text(fillMessage).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
            Spacer()
            if locked && !store.canChangeLockedDays {
                // Personel: kapatılmış günün kilidini yalnızca patron / müdür açar (sunucu da reddeder)
                Label(CloudPermission.lockedDayStaffNote, systemImage: "lock.fill")
                    .font(.callout).foregroundStyle(Brand.warn)
                    .help("Düzeltme gerekiyorsa patron ya da müdür web panelinden veya kendi hesabıyla günün kilidini açabilir.")
            } else {
                let nothingCounted = !locked && allRows.allSatisfy { !$0.isCounted }
                if nothingCounted {
                    // Düğme kapalıyken nedeni görünsün (ipucu kapalı düğmede çıkmayabilir)
                    Text(DayLockAction.nothingCountedNote).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                // Personel hesabıyla önce onay istenir (kapatılan günün kilidini yalnızca patron / müdür açar)
                Button { store.requestLockToggle(date) } label: {
                    Label(locked ? "Kilidi Aç" : (store.canChangeLockedDays ? "Günü Kapat" : "Günü Kapat…"),
                          systemImage: locked ? "lock.open" : "lock")
                }
                .buttonStyle(SoftButtonStyle(tint: locked ? Brand.warn : .primary))
                .help(locked ? "Girişleri tekrar düzenlenebilir yapar" : Term.lock.text)
                .disabled(nothingCounted)
            }
        }
        .padding(.horizontal, 20).padding(.bottom, 8)
    }

    /// "Not / Sayan" düğmesinin adı: sayımı yapan kişi yazılmışsa "Sayan: Selin K." (not da varsa "· not")
    private func noteButtonTitle(note: String, countedBy: String) -> String {
        if countedBy.isEmpty { return note.isEmpty ? "Not / Sayan" : "Not var" }
        return "Sayan: \(countedBy)" + (note.isEmpty ? "" : " · not")
    }

    private var gridHeader: some View {
        HStack(spacing: 0) {
            Text("Ürün").frame(minWidth: W.nameMin, maxWidth: .infinity, alignment: .leading).padding(.leading, 12)
            ForEach([("Açılış", Term.opening), ("Gelen", .incoming), ("Gelen\nTransfer (+)", .transfer),
                     ("Giden\nTransfer (−)", .transfer), ("Kapanış", .closing)], id: \.0) { t, term in
                Text(t).frame(width: W.input + 8).explains(term)
            }
            ForEach([("Satılan", Term.sold), ("Zayi", .waste), ("Fiili\nTüketim", .actualUsage), ("Fark", .diff)], id: \.0) { t, term in
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
        // Tolerans dışı fazla çıkış olan kalem sayısı (miktar kalemin biriminde; tutar gösterilmez)
        let shortages = rows.filter { $0.severity == .shortage }.count
        return HStack(spacing: 16) {
            Label(OpeningText.legend, systemImage: "arrow.turn.down.right")
            Label("Fark = (Satılan + Zayi) − Fiili Tüketim", systemImage: "function")
            Label("Kırmızı: fazla çıkış · Mavi: az çıkış · Yeşil: tolerans içinde", systemImage: "paintpalette")
            Spacer()
            if shortages > 0 {
                Text("\(shortages) kalemde fazla çıkış").fontWeight(.semibold).foregroundStyle(Brand.negative)
                    .help(Term.shortage.text)
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
        let readOnly = store.isReadOnlyDay(date)
        VStack(alignment: .leading, spacing: 10) {
            Text("\(DateKey.short(date)) notu").font(.headline)
            if readOnly {
                Label(CloudPermission.lockedDayStaffNote, systemImage: "lock.fill")
                    .font(.callout).foregroundStyle(Brand.warn)
            }
            HStack {
                Text("Sayımı yapan").foregroundStyle(.secondary)
                TextField("Ad Soyad", text: $countedBy).textFieldStyle(.roundedBorder).frame(width: 180)
                // Ekip ekranındaki aktif üyeler (liste sırasıyla) + eski hızlı seçim listesindeki adlar; yeniden
                // sıralanmaz. Listede olmayan yeni ad yazılırsa kaydederken ekibe de eklenir (`setCountedBy`).
                let names = store.counterNames
                if !names.isEmpty {
                    Menu {
                        ForEach(names, id: \.self) { n in Button(n) { countedBy = n } }
                    } label: { Image(systemName: "person.crop.circle") }
                        .menuStyle(.borderlessButton).fixedSize()
                }
            }
            .disabled(readOnly)
            TextEditor(text: $note)
                .font(.body)
                .frame(width: 360, height: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Brand.line))
                .disabled(readOnly)
            Text(String(WasteText.noteHint.prefix(1)).uppercased() + String(WasteText.noteHint.dropFirst()) + ". Not Excel'e ve raporlara geçer.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Kaydet") { save(); dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(PrimaryButtonStyle())
                    .disabled(readOnly)
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
        // Personel kapatılmış günü değiştiremez (alanlar kapalı; kapanırken de yazılmaz)
        guard !store.isReadOnlyDay(date) else { return }
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
    @Binding var wasteDetail: String?
    /// Bu kalem seçili "Zayi Ekle"
    var onAddWaste: (String) -> Void

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
                if calc.openingJumpIsProblem {
                    // Elle açılış beklenenden tolerans dışı farklı ("Sorunlu" nedeni)
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(Brand.warn)
                        .help(OpeningText.jumpText(calc, item: item) ?? "")
                }
            }
            .frame(minWidth: W.nameMin, maxWidth: .infinity, alignment: .leading).padding(.leading, 12)

            // Tahmini (devreden) açılış "≈ 25" yazılır; ipucu dayanağı ve sayılmayan günlerin hareketlerini gösterir
            cell(0, \.opening, placeholder: calc.openingIsAuto ? OpeningText.placeholder(calc, item: item) : "")
                .help(openingHelp)
            cell(1, \.incoming)
            cell(2, \.transferIn)
            cell(3, \.transferOut)
            cell(4, \.closing)

            calcText(calc.sold)
            wasteCell
            if calc.isBaseline {
                baselinePill
            } else if let a = calc.actual {
                calcText(a, bold: true)
            } else {
                Text("—").foregroundStyle(.tertiary).frame(width: W.calc)
            }
            diffCell
            Button { detail = item.id } label: { Image(systemName: "info.circle") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .frame(width: W.info)
                .help("Hesabın dökümü")
                .accessibilityLabel("\(item.name) hesabının dökümü")
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
                   placeholder: placeholder, maxFraction: item.maxFraction,
                   label: "\(item.name) \(Self.columnNames[min(col, Self.columnNames.count - 1)])", focus: $focus)
            .frame(width: W.input + 8)
    }

    /// Zayi: 0 ise düz metin; değilse ModPos ve elle girilen zayinin dökümünü açan düğme (elle girilen varsa turuncu nokta)
    @ViewBuilder private var wasteCell: some View {
        if calc.waste == 0 {
            calcText(0)
        } else {
            Button { wasteDetail = item.id } label: {
                HStack(spacing: 3) {
                    if calc.manualWaste > 0 { Circle().fill(Brand.warn).frame(width: 5, height: 5) }
                    Text(Fmt.number(calc.waste, maxFraction: item.maxFraction)).monospacedDigit().underline(pattern: .dot)
                }
            }
            .buttonStyle(.plain)
            .frame(width: W.calc)
            .help(wasteHelp)
            .accessibilityLabel("\(item.name) zayi dökümü")
            .popover(isPresented: Binding(get: { wasteDetail == item.id }, set: { if !$0 { wasteDetail = nil } }), arrowEdge: .bottom) {
                WastePopover(itemID: item.id, date: date, onAdd: onAddWaste).environmentObject(store)
            }
        }
    }

    /// "Zayi 1,5 kg (ModPos 0,4 + elle 1,1) — …"; Excel'den aktarılan günde "Excel" (web `wasteCellHelp` ile aynı)
    private var wasteHelp: String {
        WasteText.cellHelp(calc, legacy: store.data.days[date]?.usesLegacySales ?? false, item: item)
    }

    /// Giriş sütunlarının ekran okuyucudaki adları (sütun sırasıyla)
    private static let columnNames = ["açılış", "gelen", "gelen transfer", "giden transfer", "kapanış"]

    /// Açılış ipucu: son sayımdan / devreden (sayılmayan günlerin hareketleriyle) / elle / önceki sayım yok
    private var openingHelp: String {
        let carry = calc.openingSource == .carried ? store.engine.carryBreakdown(itemID: item.id, date: date) : []
        return OpeningText.help(calc, item: item, date: date, breakdown: carry)
    }

    /// İlk sayım: önceki kapanış yok (ya da çok eski), fark hesaplanmaz (Fiili ve Fark hücresi)
    private var baselinePill: some View {
        Text(OpeningText.baselinePill)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .foregroundStyle(.secondary)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .frame(width: W.calc)
            .help(OpeningText.baselineHelp(calc, date: date))
    }

    private func calcText(_ v: Double, bold: Bool = false) -> some View {
        Text(v == 0 ? "0" : Fmt.number(v, maxFraction: item.maxFraction))
            .monospacedDigit()
            .fontWeight(bold ? .semibold : .regular)
            .foregroundStyle(v == 0 ? .secondary : .primary)
            .frame(width: W.calc)
    }

    @ViewBuilder private var diffCell: some View {
        if calc.isBaseline {
            baselinePill
        } else if let d = calc.diff, let sev = calc.severity {
            let color = Brand.color(for: sev)
            Text(sev == .zero ? "0" : Fmt.number(d, maxFraction: item.maxFraction))
                .monospacedDigit().fontWeight(.semibold)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .foregroundStyle(color)
                .background(Capsule().fill(color.opacity(sev == .withinTolerance ? 0.07 : 0.13)))
                .frame(width: W.calc)
                .help(diffHelp(d, sev))
        } else {
            Text("—").foregroundStyle(.tertiary).frame(width: W.calc).help(withJump("Kapanış sayımı girilince hesaplanır"))
        }
    }

    /// Açılış elle ve beklenenden farklı girildiyse ipucuna eklenir (web `diffHelp` ile aynı)
    private func withJump(_ text: String) -> String {
        guard let jump = OpeningText.jumpText(calc, item: item) else { return text }
        return text + " · " + jump
    }

    private func diffHelp(_ d: Double, _ sev: DiffSeverity) -> String {
        let unit = item.unit.lowercased()
        let amount = Fmt.number(abs(d), maxFraction: item.maxFraction)
        switch sev {
        case .zero: return withJump("Satışlarla stok hareketi tutuyor")
        case .withinTolerance:
            return withJump("Fark \(amount) \(unit): tolerans (±\(Fmt.number(item.tolerance ?? 0, maxFraction: item.maxFraction))) içinde, normal sayılır")
        case .shortage: return withJump("Satışlara göre beklenenden \(amount) \(unit) FAZLA stok çıkmış")
        case .surplus: return withJump("Satışlara göre beklenenden \(amount) \(unit) AZ stok çıkmış — sayım veya reçeteyi kontrol edin")
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
                Text("Bu günün Satılan ve Zayi değerleri Excel'de hesaplandığı haliyle aktarıldı; satış dökümü yok. ModPos raporunu aktarırsanız değerler yeniden hesaplanır.")
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
                .help("Başka rapor aktar, panodan yapıştır ya da bu günün satışlarını sil")
                .accessibilityLabel("Satış raporu işlemleri")
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
                let carry = store.engine.carryBreakdown(itemID: itemID, date: date)
                let missing = calc.isBaseline ? OpeningText.baselinePill : "—"
                Text("\(item.name) / \(item.unit)").font(.headline)
                Text(OpeningText.help(calc, item: item, date: date, breakdown: carry))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    line(OpeningText.breakdownLabel(calc), (calc.openingSource == .carried ? "≈ " : "") + f(calc.opening))
                    line("+ Gelen", f(calc.incoming))
                    line("+ Gelen transfer", f(calc.transferIn))
                    line("− Giden transfer", f(calc.transferOut))
                    line("− Kapanış", calc.closing.map(f) ?? "girilmedi")
                    Divider().gridCellColumns(2)
                    line("= Fiili tüketim", calc.actual.map(f) ?? missing, bold: true)
                    line("Satılan (reçeteden)", f(calc.sold))
                    line("Zayi", f(calc.waste))
                    line("Fark (Satılan + Zayi − Fiili)", calc.diff.map(f) ?? missing, bold: true)
                    if let t = item.tolerance, t > 0 { line("Tolerans", "± " + f(t)) }
                    if let m = item.minStock, m > 0 { line("Kritik seviye", f(m)) }
                }
                .font(.callout)
                let manual = WasteLog.entries(store.data.days[date], itemID: itemID)
                if let legacy = WasteText.legacyLine(calc, legacy: store.data.days[date]?.usesLegacySales ?? false, item: item) {
                    Text(legacy).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                if !manual.isEmpty {
                    Divider()
                    Text(WasteText.manualSection).font(.subheadline.weight(.semibold))
                    ForEach(manual) { e in
                        Text(([WasteText.amount(e.qty, item: item), WasteText.detail(e)] + [WasteLog.time(e)].compactMap { $0 }).joined(separator: " · "))
                            .font(.callout).monospacedDigit()
                    }
                }
                if !carry.isEmpty {
                    Divider()
                    Text("Devreden günler").font(.subheadline.weight(.semibold))
                    ForEach(carry, id: \.date) { d in
                        Text(OpeningText.carryLine(d, item: item)).font(.callout).monospacedDigit()
                    }
                }
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
        .frame(width: 470, height: 540)
    }

    private func line(_ title: String, _ value: String, bold: Bool = false) -> some View {
        GridRow {
            Text(title).foregroundStyle(bold ? .primary : .secondary)
            Text(value).monospacedDigit().fontWeight(bold ? .semibold : .regular).gridColumnAlignment(.trailing)
        }
    }
}
