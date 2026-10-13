import SwiftUI
import Charts
import EnvanterCore

/// Pano: seçili günün durumu (sayım, satış raporu, sorunlu kalem, kritik seviye), son 30 günün durum şeridi, sorunlu
/// kalem eğilimi ve dikkat gerektirenler. Tutar gösterilmez: farklar kalemin biriminde (adet / kg) ve kalem sayısıdır.
struct OverviewView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        let date = store.selectedDate
        let engine = store.engine
        let result = engine.calc(date: date)
        let rows = result.rows
        let analysis = result.analysis
        let o = engine.overview(date: date, rows: rows, analysis: analysis)
        let trend30 = engine.trend(endingAt: date, days: 30)
        // İlk kullanım (henüz günlük kayıt, ekip üyesi, sipariş yok): başlangıç seçenekleri; boş grafikler gösterilmez
        let firstRun = store.isFirstRun
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center) {
                    DateNavigator()
                    Spacer()
                    // Web paneline bağlıyken: canlı bağlantı ve son eşitleme
                    LiveSyncLine(cloud: store.cloud)
                }
                if firstRun { WelcomeCard(cloud: store.cloud) }
                dayCards(o, trend: Array(trend30.suffix(14)))
                if !firstRun {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(spacing: 16) {
                            trackerCard(trend30)
                            trendCard(Array(trend30.suffix(14)))
                        }
                        .frame(maxWidth: .infinity)
                        todayCard(o).frame(width: 300)
                    }
                    attention(rows: rows, analysis: analysis, overview: o)
                }
            }
            .padding(22)
        }
        .navigationTitle("Genel Bakış")
    }

    // MARK: Günün kartları

    private func dayCards(_ o: DayOverview, trend: [DayOverview]) -> some View {
        let open = store.openOrders.count
        return StatRow(spacing: 14) {
            StatCard(title: "Sayım", value: "\(o.countedItems) / \(o.itemCount)",
                     detail: o.isFullyCounted ? "Tüm kalemler sayıldı" : (o.hasAnyCount ? "\(o.itemCount - o.countedItems) kalem bekliyor" : (o.date == DateKey.today() ? "Bugün henüz sayım girilmedi" : "Bu gün için sayım girilmedi")),
                     icon: "checklist", color: o.isFullyCounted ? Brand.ok : Brand.accent,
                     progress: o.itemCount > 0 ? Double(o.countedItems) / Double(o.itemCount) : 0, info: .closing)
            StatCard(title: "Satış raporu", value: o.hasSales ? (o.salesLines > 0 ? "\(o.salesLines) satır" : "Excel'den") : "Yok",
                     detail: o.unknownLines > 0 ? "\(o.unknownLines) ürünün reçetesi tanımsız" : (o.hasSales ? "Tüm ürünler eşleşti" : "ModPos raporunu aktarın"),
                     icon: "cart", color: o.hasSales ? (o.unknownLines > 0 ? Brand.warn : Brand.ok) : Brand.negative, info: .sold)
            // Sorunlu kalem: tolerans dışı fark (fazla ya da az çıkış); ayrıntıda fazla çıkış, çizgide son 14 gün
            StatCard(title: "Sorunlu kalem", value: o.hasAnyCount ? "\(o.problemItems)" : "—",
                     detail: o.hasAnyCount ? problemDetail(o) + " · çizgi son 14 gün" : "Sayım girilince hesaplanır",
                     icon: "exclamationmark.triangle", color: o.problemItems == 0 ? Brand.ok : Brand.negative, info: .diff,
                     spark: trend.map { Double($0.problemItems) })
            StatCard(title: "Kritik seviye altı", value: o.hasAnyCount ? "\(o.belowMinimumItems)" : "—",
                     detail: open > 0 ? "\(open) açık sipariş teslim bekliyor"
                        : (o.belowMinimumItems > 0 ? "Sipariş önerisine bakın"
                           : (o.hasAnyCount ? "Stoklar kritik seviyenin üstünde" : "Sayım girilince hesaplanır")),
                     icon: "arrow.down.to.line", color: o.belowMinimumItems > 0 ? Brand.warn : Brand.ok, info: .minStock)
        }
    }

    /// "Farklar tolerans içinde" / "3 kalemde fazla çıkış" / "Fazla çıkış yok, 2 kalemde az çıkış"
    private func problemDetail(_ o: DayOverview) -> String {
        if o.problemItems == 0 { return "Farklar tolerans içinde" }
        if o.shortageItems > 0 { return "\(o.shortageItems) kalemde fazla çıkış" }
        return "Fazla çıkış yok, \(o.problemItems) kalemde az çıkış"
    }

    // MARK: Durum şeridi

    /// Şeridin başındaki / sonundaki günün kısa tarihi
    private func trackerDate(_ day: DayOverview?) -> some View {
        Text(DateKey.short(day?.date ?? "")).font(.caption2).foregroundStyle(.tertiary)
    }

    private func trackerCard(_ days: [DayOverview]) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Son 30 gün").font(.headline)
                    Text("Her kutu bir gün: üzerine gelince özet, tıklayınca o güne gider").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    let counted = days.filter { $0.hasAnyCount }.count
                    Text("\(counted) günde sayım").font(.callout).foregroundStyle(.secondary)
                }
                TrackerStrip(days: days, selected: store.selectedDate) { store.selectedDate = $0 }
                // Dar pencerede renk açıklaması tarihlerin altındaki satıra iner (kesilmesin)
                ViewThatFits(in: .horizontal) {
                    HStack {
                        trackerDate(days.first)
                        Spacer()
                        TrackerLegend()
                        Spacer()
                        trackerDate(days.last)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            trackerDate(days.first)
                            Spacer()
                            trackerDate(days.last)
                        }
                        TrackerLegend()
                    }
                }
            }
        }
    }

    // MARK: Eğilim

    /// Son 14 günün sorunlu kalem sayısı: kırmızı kısım fazla çıkış, mavi kısım az çıkış (tolerans dışı)
    private func trendCard(_ trend: [DayOverview]) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Son 14 gün · sorunlu kalem sayısı").font(.headline)
                    InfoTip(term: .diff)
                    Spacer()
                    let unlocked = trend.filter { $0.hasAnyCount && !$0.isLocked }.count
                    if unlocked > 0 {
                        Label("\(unlocked) sayılmış gün henüz kapatılmadı", systemImage: "lock.open").font(.callout).foregroundStyle(.secondary)
                            .help(Term.lock.text)
                    }
                }
                Chart {
                    ForEach(trend) { d in
                        // Aynı güne iki çubuk üst üste yığılır: fazla çıkış (alt) + az çıkış (üst); seçili gün koyu
                        BarMark(x: .value("Gün", DateKey.date(from: d.date) ?? Date(), unit: .day),
                                y: .value("Kalem", Double(d.shortageItems)))
                            .foregroundStyle(Brand.negative.opacity(d.date == store.selectedDate ? 1 : 0.65))
                            .cornerRadius(3)
                        BarMark(x: .value("Gün", DateKey.date(from: d.date) ?? Date(), unit: .day),
                                y: .value("Kalem", Double(max(d.problemItems - d.shortageItems, 0))))
                            .foregroundStyle(Brand.positive.opacity(d.date == store.selectedDate ? 1 : 0.55))
                            .cornerRadius(3)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 2)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    }
                }
                .frame(height: 150)
                HStack(spacing: 14) {
                    legendItem(Brand.negative, "Fazla çıkış")
                    legendItem(Brand.positive, "Az çıkış")
                    Spacer()
                    let shortageDays = trend.filter { $0.shortageItems > 0 }.count
                    Text(shortageDays == 0 ? "14 günde fazla çıkış yok" : "\(shortageDays) günde fazla çıkış")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
    }

    private func legendItem(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 4) { RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 10, height: 10); Text(t) }
    }

    // MARK: Bugün

    /// Günün üç adımı (web panelindeki "Bugün" kartıyla aynı sıra): ① satış raporunu aktar ② sayımı tamamla ③ günü kapat.
    /// Sıradaki adımın düğmesi vurgulu; diğer işlemler altta tek bir menüde.
    private func todayCard(_ o: DayOverview) -> some View {
        let steps = DaySteps(o)
        let lock = store.lockAction(o.date)
        return Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(o.date == DateKey.today() ? "Bugün" : DateKey.short(o.date)).font(.headline)
                    Spacer()
                    if let next = steps.next {
                        Text("Sıradaki: \(next.rawValue). adım").font(.caption).foregroundStyle(.secondary)
                    } else if steps.closed {
                        Label("Gün kapatıldı", systemImage: "lock.fill").font(.caption).foregroundStyle(Brand.ok)
                    }
                }
                todayStep(.sales, steps: steps, title: "Satış raporunu aktar", status: salesStatus(o),
                          warning: o.unknownLines > 0) {
                    // ⌘O gibi: aktarımdan sonra sayımın girileceği Günlük Sayım açık olsun
                    quick("Satış Raporu Aktar…", "doc.badge.plus", primary: steps.next == .sales) {
                        store.section = .daily
                        store.pickAndImportFile()
                    }
                }
                todayStep(.count, steps: steps, title: "Sayımı tamamla",
                          status: steps.isDone(.count) ? "Tüm kalemler sayıldı (\(steps.countText))" : "\(steps.countText) kalem sayıldı") {
                    quick(o.hasAnyCount ? "Sayıma Devam Et" : "Sayıma Başla", "checklist", primary: steps.next == .count) {
                        store.section = .daily
                    }
                }
                todayStep(.close, steps: steps, title: "Günü kapat", status: closeStatus(steps, lock)) {
                    if steps.closed {
                        quick("Günlük Sayımı Aç", "lock", primary: false) { store.section = .daily }
                    } else {
                        // Gün menüsü (⌘L) ve Günlük Sayım düğmesiyle aynı kural: personel onaylar, boş gün kapatılmaz
                        quick(lock == .confirmClose ? "Günü Kapat…" : "Günü Kapat", "lock", primary: steps.next == .close) {
                            store.requestLockToggle(o.date)
                        }
                        .disabled(!lock.isAvailable)
                        .help(lock.isAvailable ? Term.lock.text : DayLockAction.nothingCountedNote)
                    }
                }
                Divider()
                otherActions
            }
        }
    }

    /// Adım satırı: numara (yapıldıysa yeşil onay), başlık, durum ve tek düğme
    private func todayStep<Action: View>(_ step: DaySteps.Step, steps: DaySteps, title: String, status: String,
                                         warning: Bool = false, @ViewBuilder action: () -> Action) -> some View {
        let done = steps.isDone(step)
        let current = steps.next == step
        let button = action()
        return HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(done ? Brand.ok.opacity(0.15) : (current ? Brand.accent.opacity(0.15) : Color.primary.opacity(0.06)))
                if done {
                    Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(Brand.ok)
                } else {
                    Text("\(step.rawValue)").font(.callout.weight(.bold)).foregroundStyle(current ? Brand.accent : Color.secondary)
                }
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(.semibold))
                    Text(status).font(.caption).foregroundStyle(warning ? Brand.warn : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                button
            }
        }
    }

    /// "121 satır aktarıldı" / "3 ürünün reçetesi tanımsız" / "ModPos raporu henüz aktarılmadı"
    private func salesStatus(_ o: DayOverview) -> String {
        guard o.hasSales else { return "ModPos satış raporu henüz aktarılmadı" }
        if o.unknownLines > 0 { return "\(o.unknownLines) ürünün reçetesi tanımsız" }
        return o.salesLines > 0 ? "\(o.salesLines) satır aktarıldı" : "Excel'den aktarıldı"
    }

    private func closeStatus(_ steps: DaySteps, _ lock: DayLockAction) -> String {
        if steps.closed { return "Gün kapatıldı; sayım ve satış kilitli" }
        switch lock {
        case .nothingCounted: return DayLockAction.nothingCountedNote
        case .confirmClose: return "Kapatınca kilidi yalnızca patron veya müdür açabilir"
        case .close, .unlock, .unlockNotAllowed: return "Sayım bitince günü kapatın; sayım ve satış kilitlenir"
        }
    }

    /// Diğer işlemler: tek menüde (Bugün kartının altında)
    private var otherActions: some View {
        Menu {
            Button { store.beginPasteImport() } label: { Label("Panodan satış yapıştır", systemImage: "doc.on.clipboard") }
            Button { store.section = .orders } label: { Label("Sipariş önerisi", systemImage: "shippingbox.and.arrow.backward") }
            Button { store.section = .reports } label: { Label("Dönem raporu", systemImage: "chart.bar.xaxis") }
            Button { store.section = .team } label: { Label("Ekip", systemImage: "person.2") }
            Divider()
            Button { store.exportCountSheet() } label: { Label("Sayım formu (Excel)…", systemImage: "printer") }
            Button { store.exportDayExcel() } label: { Label("Günü Excel'e aktar…", systemImage: "square.and.arrow.up") }
        } label: {
            Label("Diğer işlemler", systemImage: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Panodan satış, sipariş önerisi, dönem raporu, ekip, sayım formu ve Excel'e aktarım")
    }

    @ViewBuilder
    private func quick(_ title: String, _ icon: String, primary: Bool = false, _ action: @escaping () -> Void) -> some View {
        if primary {
            Button(action: action) { quickLabel(title, icon) }
                .buttonStyle(PrimaryButtonStyle())
        } else {
            Button(action: action) { quickLabel(title, icon) }
                .buttonStyle(SoftButtonStyle())
        }
    }

    /// Simgeler sabit genişlikte: düğme yazıları alt alta hizalı başlar
    private func quickLabel(_ title: String, _ icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).frame(width: 20)
            Text(title)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Dikkat gerektirenler

    @ViewBuilder
    private func attention(rows: [ItemCalc], analysis: SalesAnalysis, overview o: DayOverview) -> some View {
        let engine = store.engine
        // Önce fazla çıkışlar, sonra az çıkışlar; her grupta farkı büyük olan üstte (kalemin biriminde)
        let problems = rows.filter { $0.severity?.isProblem == true }
            .sorted { a, b in
                let sa = a.severity == .shortage, sb = b.severity == .shortage
                if sa != sb { return sa }
                return abs(a.diff ?? 0) > abs(b.diff ?? 0)
            }
        let low = rows.filter { $0.belowMinimum }
        let orders = store.openOrders
        if problems.isEmpty && low.isEmpty && analysis.unknownLines.isEmpty && orders.isEmpty {
            Card {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill").font(.title2).foregroundStyle(Brand.ok)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Dikkat gerektiren bir şey yok").font(.headline)
                        Text(o.hasAnyCount ? "Sayılan kalemlerde tolerans dışı fark ya da kritik seviye altında stok yok."
                                           : "Sayım ve satış girildikçe sorunlu kalemler burada listelenir.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        } else {
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 16) {
                    if !problems.isEmpty {
                        ListCard(title: "Tolerans dışı farklar", icon: "exclamationmark.triangle.fill", color: Brand.negative, term: .diff,
                                 linkTitle: "Günlük sayıma git", link: { store.section = .daily }) {
                            ForEach(problems.prefix(8), id: \.itemID) { c in
                                if let item = engine.itemsByID[c.itemID], let d = c.diff {
                                    HStack {
                                        Text(item.name)
                                        Spacer()
                                        Text(c.severity == .shortage ? "fazla çıkış" : "az çıkış")
                                            .font(.caption).foregroundStyle(.tertiary)
                                        Text("\(Fmt.number(d, maxFraction: item.maxFraction)) \(item.unit.lowercased())")
                                            .monospacedDigit().foregroundStyle(Brand.color(for: c.severity ?? .zero))
                                    }
                                    .font(.callout)
                                }
                            }
                        }
                    }
                    if !analysis.unknownLines.isEmpty {
                        ListCard(title: "Reçetesi tanımsız satışlar", icon: "questionmark.diamond.fill", color: Brand.warn, term: nil,
                                 linkTitle: "Satış dökümünde reçete tanımla", link: { store.section = .sales }) {
                            ForEach(analysis.unknownLines.sorted { $0.qty > $1.qty }.prefix(6)) { l in
                                HStack {
                                    Text(l.name.isEmpty ? l.code : l.name).lineLimit(1)
                                    Spacer()
                                    Text("\(Fmt.number(l.qty, maxFraction: 0)) adet").monospacedDigit().foregroundStyle(.secondary)
                                }
                                .font(.callout)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                VStack(spacing: 16) {
                    if !low.isEmpty {
                        ListCard(title: "Kritik seviyenin altında", icon: "arrow.down.to.line", color: Brand.warn, term: .minStock,
                                 linkTitle: "Sipariş önerisini aç", link: { store.section = .orders }) {
                            ForEach(low, id: \.itemID) { c in
                                if let item = engine.itemsByID[c.itemID] {
                                    HStack {
                                        Text(item.name)
                                        Spacer()
                                        Text("\(Fmt.number(c.closing ?? 0, maxFraction: item.maxFraction)) / \(Fmt.number(item.minStock ?? 0, maxFraction: item.maxFraction)) \(item.unit.lowercased())")
                                            .monospacedDigit().foregroundStyle(.secondary)
                                    }
                                    .font(.callout)
                                }
                            }
                        }
                    }
                    if !orders.isEmpty {
                        ListCard(title: "Bekleyen siparişler", icon: "shippingbox", color: Brand.positive, term: .purchaseOrder,
                                 linkTitle: "Siparişlere git", link: { store.section = .orders }) {
                            ForEach(orders) { order in
                                HStack {
                                    Text(DateKey.short(order.date) + (order.supplier.isEmpty ? "" : " · " + order.supplier))
                                    Spacer()
                                    Text("\(order.lines.count) kalem").foregroundStyle(.secondary)
                                }
                                .font(.callout)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

/// Başlıklı liste kartı (dikkat gerektirenler)
private struct ListCard<Content: View>: View {
    var title: String
    var icon: String
    var color: Color
    var term: Term?
    var linkTitle: String
    var link: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Label(title, systemImage: icon).font(.headline).foregroundStyle(color)
                    if let term { InfoTip(term: term) }
                }
                content
                Button(linkTitle, action: link).buttonStyle(.link)
            }
        }
    }
}

/// Web paneline bağlıyken Genel Bakış'ın üst satırındaki küçük durum: canlı bağlantı (web panelindeki değişiklikler
/// anında gelir) ve son eşitleme zamanı. Bağlı değilken hiçbir şey göstermez.
private struct LiveSyncLine: View {
    @ObservedObject var cloud: CloudSyncController

    var body: some View {
        if cloud.isConnected {
            HStack(spacing: 6) {
                if cloud.status == .syncing {
                    ProgressView().controlSize(.mini)
                    Text("Eşitleniyor…")
                } else {
                    Image(systemName: cloud.isLive ? "bolt.fill" : "bolt.slash")
                        .foregroundStyle(cloud.isLive ? Brand.ok : Brand.warn)
                    Text(cloud.isLive ? "Canlı" : "Canlı bağlantı yok").fontWeight(.medium)
                        .foregroundStyle(cloud.isLive ? Color.primary : Color.secondary)
                    Text("· son eşitleme: " + CloudSyncGuide.lastSyncText(cloud.state.lastSyncAt))
                }
            }
            .font(.callout).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .glassSurface(in: Capsule())
            .help(RealtimeStatusLabel.text(cloud.realtimeStatus) + "\nAyrıntı: Ayarlar → Web paneli ile eşitleme")
        }
    }
}

// MARK: - İlk kullanım

/// Bu Mac'te henüz günlük kayıt yokken Genel Bakış'ın başındaki başlangıç kartı (web panelindeki "Bu şubede henüz veri
/// yok" kartının karşılığı): verisi web panelinde olan için bağlantı koduyla bağlanma, yedeği olan için geri yükleme,
/// sıfırdan başlayan için tanımlar ve ilk satış raporu. İlk kayıt (günlük kayıt, ekip üyesi ya da sipariş) girilince
/// kendiliğinden kaybolur (`Onboarding.isEmpty`).
private struct WelcomeCard: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var cloud: CloudSyncController

    var body: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Hoş geldiniz").font(.title2.weight(.semibold))
                    Text("Bu Mac'te henüz sayım ya da satış kaydı yok. Verileriniz web panelinde ya da bir yedek dosyasındaysa önce onları getirin; sıfırdan başlıyorsanız tanımları gözden geçirip ilk satış raporunu aktarın.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .top, spacing: 12) {
                    connectTile
                    backupTile
                    freshTile
                }
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text("Bu kart ilk kayıt (sayım, satış, ekip üyesi ya da sipariş) girilince kendiliğinden kaybolur.")
                    Button("Adım adım anlatım: Yardım") { store.section = .help }
                        .buttonStyle(.link)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var connectTile: some View {
        let connected = cloud.isConnected
        let name = cloud.state.config?.workspaceName ?? ""
        let text: String = connected
            ? "Bu Mac \"\(name)\" şubesiyle eşitleniyor (\(CloudRole.title(cloud.role))). Web panelindeki veriler kendiliğinden buraya gelir."
            : "Patronunuzdan aldığınız bağlantı koduyla tek adımda bağlanın; veriler kendiliğinden gelir."
        return StartTile(icon: "arrow.triangle.2.circlepath.icloud", title: "Web paneline bağlanın", text: text, done: connected) {
            if connected {
                Button { store.section = .backup } label: { Label("Eşitleme Durumu", systemImage: "link") }
                    .buttonStyle(SoftButtonStyle())
            } else {
                // Web panelinin bağlantı adımlarındaki adla aynı: "Web'e Bağlan"
                Button { store.openConnect() } label: { Label("Web'e Bağlan", systemImage: "link") }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private var backupTile: some View {
        StartTile(icon: "arrow.counterclockwise", title: "Yedekten geri yükleyin",
                  text: "Başka bir Mac'te Ayarlar → Yedek Oluştur… ile alınmış bir yedek dosyası (.json) varsa tüm veriyi tek seferde yükleyin. Eski Excel envanter dosyanızdaki (.xlsm) geçmiş günler de aktarılabilir.") {
            Button { store.restoreBackup() } label: { Label("Yedek Dosyası Seç…", systemImage: "doc") }
                .buttonStyle(SoftButtonStyle())
                .disabled(!store.canEditCatalog)
                .help(store.canEditCatalog ? "Bir yedek dosyasındaki veriyi geri yükler" : CloudPermission.catalogReadOnlyNote)
            Button { store.pickAndImportWorkbook() } label: { Label("Excel'den…", systemImage: "tablecells") }
                .buttonStyle(SoftButtonStyle())
                .help("Eski Excel envanter dosyasındaki (ör. 01.08.xlsm) geçmiş günleri aktarır")
        }
    }

    /// Sıfırdan başlayan için: hazır tanımlar ve ilk satış raporu
    private var freshTile: some View {
        let active = store.engine.activeItems
        var text = "\(store.data.products.count) hazır reçete ve \(active.count) stok kalemi yüklü. Stok Kalemleri'nde kritik seviye ve toleransı girin, Reçeteler'i kontrol edin; gün sonunda ModPos satış raporunu aktarıp Günlük Sayım'da kapanışı yazın."
        if !store.canEditCatalog { text += " Personel hesabıyla tanımlar salt okunurdur." }
        return StartTile(icon: "shippingbox", title: "Sıfırdan başlayın", text: text) {
            Button { store.section = .items } label: { Label("Stok Kalemleri", systemImage: "shippingbox") }
                .buttonStyle(SoftButtonStyle())
            Button { store.section = .recipes } label: { Label("Reçeteler", systemImage: "fork.knife") }
                .buttonStyle(SoftButtonStyle())
            // ⌘O gibi: aktarımdan sonra sayımın girileceği Günlük Sayım açık olsun
            Button { store.section = .daily; store.pickAndImportFile() } label: { Label("Satış Raporu Aktar…", systemImage: "doc.badge.plus") }
                .buttonStyle(SoftButtonStyle())
        }
    }
}

/// Başlangıç kartındaki seçenek: simge, başlık, açıklama ve düğmeler (yapıldıysa yeşil onay)
private struct StartTile<Actions: View>: View {
    var icon: String
    var title: String
    var text: String
    var done = false
    @ViewBuilder var actions: Actions

    var body: some View {
        let tint = done ? Brand.ok : Brand.accent
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: done ? "checkmark.circle.fill" : icon)
                    .font(.callout.weight(.semibold)).foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7).fill(tint.opacity(0.13)))
                Text(title).font(.headline)
            }
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            // Dar pencerede düğmeler alt alta iner (kesilmesin)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { actions }
                VStack(alignment: .leading, spacing: 8) { actions }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
    }
}
