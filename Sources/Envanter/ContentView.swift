import SwiftUI
import AppKit
import EnvanterCore

/// Yan menü arka planı (macOS'un yerel "sidebar" malzemesi)
struct SidebarBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .sidebar
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct ContentView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.undoManager) private var undoManager

    // Not: NavigationSplitView yerine sabit yükseklikli bir yerleşim kullanılır; NavigationSplitView,
    // uzun listeleri olan ekranlarda içeriğin "ideal" yüksekliğini pencere yüksekliği sayıp pencereden taşıyordu.
    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 228)
                .frame(maxHeight: .infinity)
                .background(SidebarBackground())
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { store.undoManager = undoManager }
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
    }

    @ViewBuilder private var detail: some View {
        switch store.section ?? .overview {
        case .overview: OverviewView()
        case .daily: DailyView()
        case .sales: SalesView()
        case .summary: SummaryView()
        case .analytics: AnalyticsView()
        case .orders: OrdersView()
        case .labor: LaborView()
        case .recipes: RecipesView()
        case .items: ItemsView()
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
                Text(store.settings.branchName.isEmpty ? "Stok, maliyet ve personel takibi" : store.settings.branchName)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    group("Envanter", [.overview, .daily, .sales, .orders], overview: o)
                    group("Personel", [.labor], overview: o)
                    group("Raporlar", [.summary, .analytics], overview: o)
                    group("Tanımlar", [.recipes, .items], overview: o)
                    group("Diğer", [.backup, .help], overview: o)
                }
                .padding(.horizontal, 10)
            }
            Spacer(minLength: 0)
            Divider()
            VStack(alignment: .leading, spacing: 3) {
                SaveStatusView()
                Text("\(Brand.appName) \(Brand.version)").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
        }
    }

    private func group(_ title: String, _ items: [AppSection], overview: DayOverview) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(.tertiary)
                .padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 4)
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
            let open = store.data.purchaseOrders.filter { $0.status == .open }.count
            return open > 0 ? ("\(open)", Brand.positive) : nil
        default:
            return nil
        }
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
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? Brand.accent.opacity(0.13) : (hovering ? Color.primary.opacity(0.06) : Color.clear))
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
