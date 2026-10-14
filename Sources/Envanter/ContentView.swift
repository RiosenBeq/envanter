import SwiftUI
import AppKit
import UniformTypeIdentifiers
import EnvanterCore

struct ContentView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.undoManager) private var undoManager
    @State private var dropTargeted = false

    // Not: NavigationSplitView yerine sabit yükseklikli bir yerleşim kullanılır; NavigationSplitView,
    // uzun listeleri olan ekranlarda içeriğin "ideal" yüksekliğini pencere yüksekliği sayıp pencereden taşıyordu.
    var body: some View {
        HStack(spacing: 0) {
            // Yüzen cam yan menü (macOS 26 Liquid Glass; önceki sürümlerde buzlu cam)
            sidebar
                .frame(width: 228)
                .frame(maxHeight: .infinity)
                .glassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .padding(.leading, 10).padding(.vertical, 10)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Gün dönümü: "bugün" seçiliyken yeni güne geçildi
                .overlay(alignment: .top) {
                    if let notice = store.dayRollover { DayRolloverBanner(notice: notice) }
                }
        }
        .background(AmbientBackground())
        .onAppear { store.undoManager = undoManager }
        // Satış raporu / Excel dosyası her ekranda pencereye bırakılabilir (Günlük Sayım'a geçilir)
        .overlay { if dropTargeted { dropOverlay } }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async {
                    store.section = .daily
                    store.beginImport(url: url)
                }
            }
            return true
        }
        .sheet(item: $store.importPreview) { p in
            ImportSheet(report: p.report, initialDate: store.selectedDate).environmentObject(store)
        }
        .sheet(item: $store.workbookPreview) { p in
            WorkbookImportSheet(imp: p.imp).environmentObject(store)
        }
        .alert(store.alert?.title ?? "", isPresented: Binding(get: { store.alert != nil }, set: { if !$0 { store.alert = nil } }),
               presenting: store.alert) { _ in
            Button("Tamam", role: .cancel) {}
        } message: { a in Text(a.message) }
        // Gün kapatma onayı (Gün menüsü ⌘L, Günlük Sayım düğmesi, Bugün kartı): kontrol listesi (✓ / ⚠ / •: sayım, satış
        // raporu, tanımsız reçete, tolerans dışı fark) ve kilit kuralı. Personel her zaman, patron / müdür eksik varsa görür;
        // eksik varsa düğme "Yine de Kapat" (web paneliyle aynı kural: DayCloseCheck)
        .confirmationDialog(store.pendingDayClose.map { DayCloseCheck.title(date: $0) } ?? "",
                            isPresented: Binding(get: { store.pendingDayClose != nil }, set: { if !$0 { store.pendingDayClose = nil } }),
                            titleVisibility: .visible, presenting: store.pendingDayClose) { date in
            let check = store.dayCloseCheck(date)
            Button(check.confirmLabel) { store.confirmDayClose(date) }
            if check.hasUncounted {
                Button(DayCloseCheck.showUncountedLabel) { store.showUncounted(date) }
            }
            Button("Vazgeç", role: .cancel) { store.pendingDayClose = nil }
        } message: { date in
            Text(store.dayCloseConfirmMessage(date))
        }
        // Genel Bakış → "N gün kapatılmadı" ve Gün menüsü: kapatılmamış günler (patron / müdür topluca kapatır)
        .sheet(isPresented: $store.showUnclosedDays) {
            UnclosedDaysSheet().environmentObject(store)
        }
        // Paylaşılan bilgisayar (bağlantı koduyla bağlı): "Şu an kim çalışıyor?"
        .sheet(isPresented: $store.showWorkerPrompt) {
            WorkerSheet().environmentObject(store)
        }
        .background(WorkerPromptTrigger(cloud: store.cloud))
        // "Web Paneline Bağlan" penceresi (Web'e Bağlan düğmeleri, menü komutu, envanter://baglan… bağlantısı)
        .sheet(item: $store.connectRequest) { request in
            ConnectPanel(cloud: store.cloud, request: request,
                         close: { store.connectRequest = nil },
                         openSettings: { store.section = .backup })
        }
        // Ekran görüntüsü aracı: pencere görüntüsüne sayfa pencereleri girmediği için aynı içerik pencerenin üstünde
        .overlay { if store.previewConnectPanel { connectPreview } }
    }

    /// Bağlanma penceresinin ekran görüntüsü için önizlemesi (örnek kodla; yalnızca ENVANTER_SNAPSHOT_DIR modunda)
    private var connectPreview: some View {
        ZStack {
            Color.black.opacity(0.28)
            ConnectPanel(cloud: store.cloud, request: ConnectRequest(code: "7KQ2M9XP4TRAHW3D"),
                         close: { store.previewConnectPanel = false }, openSettings: {}, isPreview: true)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
                .shadow(color: .black.opacity(0.3), radius: 24, x: 0, y: 10)
        }
        .ignoresSafeArea()
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

    @ViewBuilder private var detail: some View {
        switch store.section ?? .overview {
        case .overview: OverviewView()
        case .daily: DailyView()
        case .sales: SalesView()
        case .orders: OrdersView()
        case .reports: ReportsView(store: store)
        case .recipes: RecipesView()
        case .items: ItemsView()
        case .team: TeamView(store: store)
        case .backup: BackupView()
        case .help: HelpView()
        }
    }

    private var sidebar: some View {
        let o = store.engine.overview(date: store.selectedDate)
        return VStack(alignment: .leading, spacing: 0) {
            // Yazı tabanlı işaret (sembol/logo kullanılmaz)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 0) {
                    Text(Brand.shortName).foregroundStyle(Brand.accent)
                    Text(" Envanter").foregroundStyle(.primary)
                }
                .font(.system(size: 18, weight: .bold, design: .rounded))
                Text(store.settings.branchName.isEmpty ? "Stok, sayım ve sipariş takibi" : store.settings.branchName)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    // Yukarıdan aşağı sıra ⌘1…⌘8 kısayollarıyla aynı: günlük işler başlıksız, sonra tanımlar
                    group(nil, AppSection.mainSections, overview: o)
                    group("Tanımlar", AppSection.definitionSections, overview: o)
                }
                .padding(.horizontal, 10)
            }
            Spacer(minLength: 0)
            // Ayarlar ve Yardım altta, ayrı
            group(nil, AppSection.bottomSections, overview: o)
                .padding(.horizontal, 10).padding(.bottom, 8)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                // Paylaşılan bilgisayarda (cihaz hesabı) şu an çalışan; ada tıklayınca değiştirilir
                WorkerRow(cloud: store.cloud)
                // Web paneline bağlı değilken "Web'e Bağlan"; bağlıyken eşitleme satırı (kayıt durumunun altında)
                SidebarConnectButton(cloud: store.cloud) { store.openConnect() }
                VStack(alignment: .leading, spacing: 3) {
                    SaveStatusView()
                    Text("\(Brand.appName) \(Brand.version)").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
        }
    }

    /// Yan menü grubu; başlık yoksa (ana grup, Ayarlar / Yardım) yalnızca boşluk
    private func group(_ title: String?, _ items: [AppSection], overview: DayOverview) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            if let title {
                // Türkçe büyük harf (Fmt.upper; uppercased() "i"yi "I" yazardı)
                Text(Fmt.upper(title))
                    .font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(.tertiary)
                    .padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 4)
            } else {
                Color.clear.frame(height: 8)
            }
            ForEach(items) { s in
                SidebarRow(section: s, selected: (store.section ?? .overview) == s, badge: badge(for: s, overview)) {
                    store.section = s
                }
            }
        }
    }

    /// Seçili güne ait küçük rozetler: sayım ilerlemesi, reçetesi olmayan satış satırı, açık sipariş
    private func badge(for s: AppSection, _ o: DayOverview) -> (text: String, color: Color)? {
        switch s {
        case .daily:
            guard o.itemCount > 0, o.hasAnyCount else { return nil }
            return ("\(o.countedItems)/\(o.itemCount)", o.isFullyCounted ? Brand.ok : Brand.accent)
        case .sales:
            return o.unknownLines > 0 ? ("\(o.unknownLines)", Brand.warn) : nil
        case .orders:
            let open = store.openOrders.count
            return open > 0 ? ("\(open)", Brand.positive) : nil
        default:
            return nil
        }
    }
}

/// Gün dönümü şeridi: "Yeni gün başladı: 15.10.2026 · Dünkü güne dön" (kapatılana kadar kalır; web'deki bildirim de böyle)
private struct DayRolloverBanner: View {
    @EnvironmentObject var store: AppStore
    let notice: DayRolloverNotice

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sunrise.fill").foregroundStyle(Brand.accent)
            Text(DayRollover.title(notice.to)).fontWeight(.semibold)
            Button(DayRollover.backLabel) { store.returnFromRollover() }
                .buttonStyle(SoftButtonStyle())
            Button {
                store.dayRollover = nil
            } label: {
                Image(systemName: "xmark").font(.caption.weight(.bold))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help("Kapat")
            .accessibilityLabel("Kapat")
        }
        .font(.callout)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 4)
        .padding(.top, 12)
    }
}

/// Yan menü satırı: seçili satır yumuşak vurgulu, fareyle üzerine gelince hafif arka plan
private struct SidebarRow: View {
    let section: AppSection
    let selected: Bool
    let badge: (text: String, color: Color)?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: section.icon)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Brand.accent : Color.secondary)
                    .frame(width: 20)
                Text(section.title).lineLimit(1).minimumScaleFactor(0.75)
                Spacer(minLength: 2)
                if let badge {
                    Text(badge.text)
                        .font(.caption2.weight(.bold)).monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .foregroundStyle(badge.color)
                        .background(Capsule().fill(badge.color.opacity(0.15)))
                }
            }
            .font(.system(size: 13, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? Brand.accent : Color.primary)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Brand.accent.opacity(0.15) : (hovering ? Color.primary.opacity(0.06) : Color.clear))
            )
            .overlay(alignment: .leading) {
                if selected {
                    Capsule().fill(Brand.accent).frame(width: 3, height: 16).offset(x: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(section.shortcut.map { "\(section.title) (⌘\($0.character))" } ?? section.title)
    }
}
