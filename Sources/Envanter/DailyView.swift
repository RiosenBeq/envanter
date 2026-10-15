import SwiftUI
import UniformTypeIdentifiers
import EnvanterCore

/// Sütun genişlikleri: en küçük pencere genişliğinde (1180) de taşmayacak şekilde ayarlıdır.
private enum W {
    static let input: CGFloat = 80
    static let calc: CGFloat = 80
    /// Kalan: asıl giriş (diğer girişlerden geniş)
    static let closing: CGFloat = 100
    /// Fark kapsülü ("0,126 kg eksik")
    static let diff: CGFloat = 124
    static let info: CGFloat = 30
    static let nameMin: CGFloat = 130
}

/// "Zayi Ekle" penceresi isteği (kalem seçili gelebilir)
private struct WasteRequest: Identifiable {
    let id = UUID()
    var itemID: String?
}

/// Günlük Sayım: Ürün · Devreden · Giren · Çıkan · Satılan · Zayi · Kalan · Fark · döküm (web CountGrid ile aynı sütunlar)
struct DailyView: View {
    @EnvironmentObject var store: AppStore
    @FocusState private var focus: CellID?
    @State private var detailItem: String?
    @State private var dropTargeted = false
    /// Kalem arama (ad ya da kimlik; Türkçe harf farkı gözetilmez); Gün menüsündeki "Kalem Ara" (⌘F) odaklanır
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var showNote = false
    @State private var fillMessage: String?
    @State private var wasteRequest: WasteRequest?
    @State private var showWasteList = false

    var body: some View {
        let date = store.selectedDate
        let locked = store.isLocked(date)
        let result = store.engine.calc(date: date)
        let allRows = result.rows
        let filter = store.dailyFilter
        let rows = store.dailyRows(date: date, filter: filter, query: query)
        let searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(spacing: 0) {
            header(rows: allRows, date: date, locked: locked, firstItem: rows.first?.itemID)
            Divider()
            SalesStatusBar(date: date, analysis: result.analysis)
            toolbar(date: date, locked: locked, allRows: allRows)
            gridHeader
            Divider()
            if rows.isEmpty && searching {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text(ItemSearch.noMatchText(query)).font(.title3.weight(.semibold))
                    Text(filter == .all ? "Aramayı değiştirin ya da temizleyin." : "Filtre: \(filter.rawValue). Aramayı ya da filtreyi değiştirin.")
                        .foregroundStyle(.secondary)
                    Button(ItemSearch.clearLabel) { query = "" }.buttonStyle(SoftButtonStyle())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(40)
            } else if rows.isEmpty {
                EmptyStateView(icon: filter == .uncounted ? "checkmark.circle" : "line.3.horizontal.decrease.circle",
                               title: filter == .uncounted ? "Tüm kalemler sayıldı" : "Bu filtrede kalem yok",
                               message: filter == .problems ? "Tolerans dışı fark, kritik seviye altında stok ya da beklenenden farklı elle Devreden yok." : "Filtreyi \"Tümü\" yaparak bütün kalemleri görebilirsiniz.")
            } else {
                let order = rows.map { $0.itemID }
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.itemID) { idx, calc in
                            if let item = store.engine.itemsByID[calc.itemID] {
                                DailyRow(order: order, calc: calc, item: item, date: date,
                                         focus: $focus, detail: $detailItem, onAddWaste: { openWaste($0) })
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
            legend(rows: allRows, locked: locked)
        }
        .navigationTitle("Günlük Sayım")
        // Gün menüsü → Kalem Ara (⌘F): ekran yeni açıldıysa da arama kutusuna odaklanılır. "Sayılmayanları Göster"
        // aramayı temizler (sayılmayanların hepsi görünsün)
        .onAppear { takeSearchRequest(); takeClearRequest(); takeNotice() }
        .onChange(of: store.focusDailySearch) { _, _ in takeSearchRequest() }
        .onChange(of: store.clearDailySearch) { _, _ in takeClearRequest() }
        .onChange(of: store.dailyNotice) { _, _ in takeNotice() }
        .overlay { if dropTargeted { dropOverlay } }
        // Satış raporu, sayım Excel'i (seçili güne yükleme önizlemesi) ya da eski Excel envanter dosyası
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

    /// Kalem Ara isteği (⌘F): arama kutusuna odaklanır
    private func takeSearchRequest() {
        guard store.focusDailySearch else { return }
        store.focusDailySearch = false
        DispatchQueue.main.async { searchFocused = true }
    }

    /// "Sayılmayanları Göster" isteği: arama temizlenir
    private func takeClearRequest() {
        guard store.clearDailySearch else { return }
        store.clearDailySearch = false
        query = ""
    }

    /// Mağazanın bıraktığı bildirim (ör. Excel'den yükleme): araç çubuğunda gösterilir. Gün de değiştiyse gün değişikliği
    /// bildirimi silmesin diye bir tur sonra yazılır.
    private func takeNotice() {
        guard let notice = store.dailyNotice else { return }
        store.dailyNotice = nil
        DispatchQueue.main.async { fillMessage = notice }
    }

    /// "Zayi Ekle" (açık döküm ya da zayi listesi önce kapanır; sayfa penceresi onun ardından açılır)
    private func openWaste(_ itemID: String?) {
        let wasOpen = detailItem != nil || showWasteList
        detailItem = nil
        showWasteList = false
        if wasOpen {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { wasteRequest = WasteRequest(itemID: itemID) }
        } else {
            wasteRequest = WasteRequest(itemID: itemID)
        }
    }

    // MARK: Parçalar

    private func header(rows: [ItemCalc], date: String, locked: Bool, firstItem: String?) -> some View {
        let counted = rows.filter { $0.isCounted }.count
        let problems = rows.filter { $0.severity?.isProblem == true }.count
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                DateNavigator()
                searchField(firstItem: firstItem)
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
                // Sayım şablonu (Excel) ve doldurulan şablonun yüklenmesi; günün Excel'i
                Menu {
                    Button(CountImportText.templateButton) { store.exportCountSheet() }
                    Button(CountImportText.uploadButton) { store.pickCountImport() }
                    Divider()
                    Button("Bu günü Excel'e aktar…") { store.exportDayExcel() }
                } label: { Label(CountImportText.menu, systemImage: "tablecells") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Sayım şablonunu indirin, doldurulan şablonu yükleyin (dosyayı bu pencereye de bırakabilirsiniz) ya da günü Excel'e aktarın")
            }
            Text(CountText.subtitle).font(.callout).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    /// Kalem arama: Enter görünen ilk kalemin Kalan hücresine geçer, Esc temizler
    private func searchField(firstItem: String?) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(ItemSearch.placeholder, text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit {
                    if let firstItem { focus = CellID(item: firstItem, col: 4) }
                }
                .onExitCommand { query = "" }
                .accessibilityLabel(ItemSearch.placeholder)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(ItemSearch.clearLabel)
            }
        }
        .padding(.horizontal, 8)
        .frame(width: 200, height: 28)
        .background(RoundedRectangle(cornerRadius: 7).fill(Brand.field))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(searchFocused ? Brand.accent : Brand.line.opacity(0.6), lineWidth: searchFocused ? 1.5 : 0.5))
        .help("Kalem ara (⌘F) · Enter: ilk kalemin Kalan'ı · Esc: temizle")
    }

    private func toolbar(date: String, locked: Bool, allRows: [ItemCalc]) -> some View {
        let day = store.data.days[date]
        let note = day?.note ?? ""
        let countedBy = day?.countedBy ?? ""
        return HStack(spacing: 12) {
            Picker("", selection: $store.dailyFilter) {
                ForEach(DailyRowFilter.allCases) { f in Text(f.rawValue).tag(f) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 270)

            Button { showNote = true } label: {
                Label(noteButtonTitle(note: note, countedBy: countedBy), systemImage: note.isEmpty ? "note.text" : "note.text.badge.plus")
            }
            .buttonStyle(SoftButtonStyle(tint: note.isEmpty ? .primary : Brand.accent))
            .help(note.isEmpty ? "Güne not ekleyin, sayımı yapanı seçin" : note)
            // Gün değişirse (gün dönümü) not penceresi yeniden kurulur: yazılan not açıldığı güne kaydedilir
            .popover(isPresented: $showNote, arrowEdge: .bottom) { DayNotePopover(date: date).environmentObject(store).id(date) }

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
                // Kontrol listesinde eksik varsa ya da personelse önce onay istenir ("…"; kapatılan günün kilidini yalnızca
                // patron / müdür açar)
                Button { store.requestLockToggle(date) } label: {
                    Label(locked ? "Kilidi Aç" : store.lockMenuTitle(date), systemImage: locked ? "lock.open" : "lock")
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

    /// Sütun başlıkları (`CountText.columns` sırasıyla); fareyle üzerine gelince terimin açıklaması
    private var gridHeader: some View {
        HStack(spacing: 0) {
            Text(CountText.item).frame(minWidth: W.nameMin, maxWidth: .infinity, alignment: .leading).padding(.leading, 12)
            Text(CountText.opening).frame(width: W.calc).foregroundStyle(.secondary).explains(.opening)
            Text(CountText.incoming).frame(width: W.input + 8).explains(.incoming)
            Text(CountText.transferOut).frame(width: W.input + 8).explains(.transferOut)
            Text(CountText.sold).frame(width: W.calc).foregroundStyle(.secondary).explains(.sold)
            Text(CountText.waste).frame(width: W.calc).explains(.waste)
            Text(CountText.closing).frame(width: W.closing + 8).foregroundStyle(Brand.accent).explains(.closing)
            Text(CountText.diff).frame(width: W.diff).explains(.diff)
            Color.clear.frame(width: W.info, height: 1)
        }
        .font(.caption.weight(.semibold))
        .multilineTextAlignment(.center)
        .padding(.vertical, 8).padding(.trailing, 8)
        .background(Color.primary.opacity(0.05))
    }

    private func legend(rows: [ItemCalc], locked: Bool) -> some View {
        // Tolerans dışı eksik olan kalem sayısı (miktar kalemin biriminde; tutar gösterilmez)
        let shortages = rows.filter { $0.severity == .shortage }.count
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 16) {
                Label(CountText.diffLegend, systemImage: "function")
                Label(CountText.colorLegend, systemImage: "paintpalette")
                Spacer()
                if shortages > 0 {
                    Text("\(shortages) kalemde eksik").fontWeight(.semibold).foregroundStyle(Brand.negative)
                        .help(Term.shortage.text)
                }
            }
            HStack(spacing: 16) {
                Label(CountText.openingLegend, systemImage: "arrow.turn.down.right").lineLimit(1)
                // Toplayarak giriş: "12+8+5", "3x24+7" (adet kalemde 1.200 = 1200)
                if !locked { Label(CountEntryText.expressionHint, systemImage: "plus.forwardslash.minus").lineLimit(1) }
                Spacer()
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
                    Text("Satış raporunu, sayım Excel'ini veya Excel envanter dosyasını buraya bırakın").font(.title3.weight(.semibold))
                    Text("Sayım Excel'i \(DateKey.short(store.selectedDate)) gününe yüklenmeden önce önizlemesi gösterilir")
                        .font(.callout)
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
    /// Bu kalem seçili "Zayi Ekle"
    var onAddWaste: (String) -> Void

    var body: some View {
        HStack(spacing: 0) {
            nameColumn
            openingCell
            incomingCell
            cell(3, \.transferOut)
            calcText(calc.sold)
            wasteButton
            // Kalan: asıl giriş; soluk değer olması gereken ("≈ 14,406")
            cell(4, \.closing, placeholder: CountText.closingPlaceholder(calc, item: item), tint: Brand.accent, width: W.closing)
            diffCell
            Button { detail = item.id } label: { Image(systemName: "info.circle") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .frame(width: W.info)
                .help("Hesabın dökümü · \(CountText.editOpening) · \(CountText.transferIn)")
                .accessibilityLabel("\(item.name) hesabının dökümü")
                .popover(isPresented: Binding(get: { detail == item.id }, set: { if !$0 { detail = nil } }), arrowEdge: .leading) {
                    ItemDetailView(itemID: item.id, date: date).environmentObject(store)
                }
        }
        .frame(height: 42)
        .padding(.trailing, 8)
    }

    private var nameColumn: some View {
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
                // Elle Devreden beklenenden tolerans dışı farklı ("Sorunlu" nedeni)
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(Brand.warn)
                    .help(CountText.openingJumpWords(calc, item: item) ?? "")
            }
        }
        .frame(minWidth: W.nameMin, maxWidth: .infinity, alignment: .leading).padding(.leading, 12)
    }

    /// Sayım hücresi: toplayarak giriş ("12+8+5", "3x24+7"; adet kalemde "1.200" = 1200)
    private func cell(_ col: Int, _ kp: WritableKeyPath<DayEntry, Double?>, placeholder: String = "", tint: Color? = nil,
                      width: CGFloat = W.input) -> some View {
        NumberCell(id: CellID(item: item.id, col: col), order: order,
                   value: store.entryBinding(item: item.id, date: date, kp),
                   placeholder: placeholder, maxFraction: item.maxFraction, tint: tint,
                   label: "\(item.name) \(Self.columnNames[min(col, Self.columnNames.count - 1)])",
                   isKg: item.isKg, focus: $focus)
            .frame(width: width + 8)
    }

    /// Devreden: salt okunur soluk sayı (tahminiyse "≈ 150", önceki sayım yoksa "—"); elle girilmişse "elle" işareti.
    /// Düzeltme satırın dökümünde ("Devreden'i düzelt")
    private var openingCell: some View {
        HStack(spacing: 3) {
            Text(CountText.openingValue(calc, item: item))
                .monospacedDigit().foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.8)
            if calc.openingSource == .manual {
                Text(CountText.manualMark)
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(Brand.warn)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Capsule().fill(Brand.warn.opacity(0.14)))
            }
        }
        .frame(width: W.calc)
        .help(openingHelp)
    }

    /// Giren; başka şubeden gelen varsa altında "+5 şubeden"
    private var incomingCell: some View {
        VStack(spacing: 0) {
            cell(1, \.incoming)
            if let note = CountText.transferInNote(calc, item: item) {
                Text(note).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                    .help(Term.transferIn.text)
            }
        }
        .frame(width: W.input + 8)
    }

    /// Zayi: toplamı gösteren düğme; tıklayınca bu kalem seçili Zayi Ekle açılır (elle girilen kayıtlar orada listelenir).
    /// Elle girilen zayi varsa turuncu nokta.
    private var wasteButton: some View {
        Button { onAddWaste(item.id) } label: {
            HStack(spacing: 3) {
                if calc.manualWaste > 0 { Circle().fill(Brand.warn).frame(width: 5, height: 5) }
                Text(calc.waste == 0 ? "0" : Fmt.number(calc.waste, maxFraction: item.maxFraction))
                    .monospacedDigit()
                    .foregroundStyle(calc.waste == 0 ? Color.secondary : Color.primary)
            }
            .frame(minWidth: 40)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Brand.line.opacity(0.6), lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: W.calc)
        .help(WasteText.buttonHelp(calc, legacy: store.data.days[date]?.usesLegacySales ?? false, item: item))
        .accessibilityLabel("\(item.name) zayi \(WasteText.amount(calc.waste, item: item)), \(WasteText.addTitle)")
    }

    /// Giriş sütunlarının ekran okuyucudaki adları (sütun sırasıyla)
    private static let columnNames = ["devreden", "giren", "şubeden gelen", "çıkan", "kalan"]

    /// Devreden ipucu: son sayımdan / devreden (sayılmayan günlerin hareketleriyle) / elle / önceki sayım yok
    private var openingHelp: String {
        let carry = calc.openingSource == .carried ? store.engine.carryBreakdown(itemID: item.id, date: date) : []
        return OpeningText.help(calc, item: item, date: date, breakdown: carry) + " · Düzeltmek için dökümü (ⓘ) açın"
    }

    /// İlk sayım: önceki kalan yok (ya da çok eski), fark hesaplanmaz
    private var baselinePill: some View {
        Text(OpeningText.baselinePill)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .foregroundStyle(.secondary)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .frame(width: W.diff)
            .help(OpeningText.baselineHelp(calc, date: date))
    }

    private func calcText(_ v: Double, bold: Bool = false) -> some View {
        Text(v == 0 ? "0" : Fmt.number(v, maxFraction: item.maxFraction))
            .monospacedDigit()
            .fontWeight(bold ? .semibold : .regular)
            .foregroundStyle(v == 0 ? .secondary : .primary)
            .frame(width: W.calc)
    }

    /// Fark kapsülü: "Tamam" (✓, tolerans içinde), "0,126 kg eksik", "3 adet fazla"; sayılmadıysa "—"; ilk sayım
    @ViewBuilder private var diffCell: some View {
        if calc.isBaseline {
            baselinePill
        } else if let d = calc.diff, let sev = calc.severity {
            let color = Brand.color(for: sev)
            HStack(spacing: 3) {
                if !sev.isProblem { Image(systemName: "checkmark").font(.caption2.weight(.bold)) }
                Text(CountText.diffWords(d, severity: sev, item: item)).monospacedDigit()
            }
            .font(.callout.weight(.semibold))
            .lineLimit(1).minimumScaleFactor(0.7)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(sev.isProblem ? 0.13 : 0.08)))
            .frame(width: W.diff)
            .help(CountText.diffHelp(calc, item: item))
        } else {
            Text("—").foregroundStyle(.tertiary).frame(width: W.diff).help(CountText.diffHelp(calc, item: item))
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

/// Satırın dökümü (ⓘ): düz formül ("Devreden 16,8 + Giren 0 − … = Olması gereken 14,406 · Sayılan 14,28 → 0,126 kg
/// eksik"), kalem kalem hesap, Devreden'i düzeltme ve Şubeden gelen girişi, elle zayi, devreden günler ve satışlar
struct ItemDetailView: View {
    @EnvironmentObject var store: AppStore
    let itemID: String
    let date: String

    var body: some View {
        let result = store.engine.calc(date: date)
        let item = store.engine.itemsByID[itemID]
        let calc = result.rows.first { $0.itemID == itemID }
        let contribs = (result.analysis.contributions[itemID] ?? []).sorted { $0.amount > $1.amount }
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let item, let calc {
                    let f: (Double) -> String = { Fmt.number($0, maxFraction: item.maxFraction) }
                    let carry = store.engine.carryBreakdown(itemID: itemID, date: date)
                    let missing = calc.isBaseline ? OpeningText.baselinePill : "—"
                    Text("\(item.name) / \(item.unit)").font(.headline)
                    Text(CountText.formula(calc, item: item))
                        .font(.callout).monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                        line(CountText.opening + (calc.openingSource == .manual ? " (\(CountText.manualMark))" : ""),
                             CountText.openingValue(calc, item: item))
                        line("+ \(CountText.incoming)", f(calc.incoming))
                        if calc.transferIn != 0 { line("+ \(CountText.transferIn)", f(calc.transferIn)) }
                        line("− \(CountText.transferOut)", f(calc.transferOut))
                        line("− \(CountText.sold) (reçeteden)", f(calc.sold))
                        line("− \(CountText.waste)", f(calc.waste))
                        Divider().gridCellColumns(2)
                        line("= \(CountText.expected)", calc.expectedClosing.map(f) ?? missing, bold: true)
                        line("\(CountText.closing) (sayılan)", calc.closing.map(f) ?? "girilmedi")
                        line(CountText.diff, CountText.diffPill(calc, item: item), bold: true)
                        if let t = item.tolerance, t > 0 { line("Tolerans", "± " + f(t)) }
                        if let m = item.minStock, m > 0 { line("Kritik seviye", f(m)) }
                    }
                    .font(.callout)
                    Text(OpeningText.help(calc, item: item, date: date, breakdown: carry))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    corrections(calc, item: item)
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
            .padding(16)
        }
        .frame(width: 480, height: 560)
    }

    /// Devreden'i düzelt (elle Devreden; boşsa önceki sayımdan devreden) ve Şubeden gelen (sütunu yok). Kapatılmış günde kapalı.
    @ViewBuilder private func corrections(_ calc: ItemCalc, item: Item) -> some View {
        let readOnly = store.isLocked(date)
        Divider()
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                Text(CountText.editOpening).foregroundStyle(.secondary)
                OptionalDecimalField(value: store.entryBinding(item: itemID, date: date, \.opening),
                                     placeholder: calc.openingSource == .manual ? "" : CountText.openingValue(calc, item: item),
                                     maxFraction: item.maxFraction, width: 110)
                Text(item.unit.lowercased()).foregroundStyle(.secondary)
            }
            GridRow {
                Text(CountText.transferIn).foregroundStyle(.secondary)
                OptionalDecimalField(value: store.entryBinding(item: itemID, date: date, \.transferIn),
                                     placeholder: "0", maxFraction: item.maxFraction, width: 110)
                Text(item.unit.lowercased()).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .disabled(readOnly)
        Text(readOnly ? "Gün kapatılmış; düzeltmek için önce günün kilidini açın." : CountText.editOpeningHelp + " " + CountText.transferInHelp)
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func line(_ title: String, _ value: String, bold: Bool = false) -> some View {
        GridRow {
            Text(title).foregroundStyle(bold ? .primary : .secondary)
            Text(value).monospacedDigit().fontWeight(bold ? .semibold : .regular).gridColumnAlignment(.trailing)
        }
    }
}
