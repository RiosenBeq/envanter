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
                .frame(width: 220)
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
        case .recipes: RecipesView()
        case .items: ItemsView()
        case .backup: BackupView()
        case .help: HelpView()
        }
    }

    private var sidebar: some View {
        let o = store.engine.overview(date: store.selectedDate)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Brand.gradient))
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        Text(Brand.shortName).foregroundStyle(Brand.accent)
                        Text(" Envanter")
                    }
                    .font(.headline.weight(.bold))
                    Text(store.settings.branchName.isEmpty ? "Stok ve fire takibi" : store.settings.branchName)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    group("Envanter", [.overview, .daily, .sales, .orders], overview: o)
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
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
    }

    private func group(_ title: String, _ items: [AppSection], overview: DayOverview) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 4)
            ForEach(items) { s in row(s, badge: badge(for: s, overview)) }
        }
    }

    /// Seçili güne ait küçük rozetler: sayım ilerlemesi, reçetesi olmayan satış satırı
    private func badge(for s: AppSection, _ o: DayOverview) -> (text: String, color: Color)? {
        switch s {
        case .daily:
            guard o.itemCount > 0, o.hasAnyCount else { return nil }
            return ("\(o.countedItems)/\(o.itemCount)", o.isFullyCounted ? Brand.ok : Brand.accent)
        case .sales:
            return o.unknownLines > 0 ? ("\(o.unknownLines)", Brand.warn) : nil
        default:
            return nil
        }
    }

    private func row(_ s: AppSection, badge: (text: String, color: Color)?) -> some View {
        let selected = (store.section ?? .overview) == s
        return Button { store.section = s } label: {
            HStack(spacing: 10) {
                Image(systemName: s.icon).frame(width: 20)
                Text(s.title)
                Spacer()
                if let badge {
                    Text(badge.text)
                        .font(.caption2.weight(.bold)).monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .foregroundStyle(selected ? Brand.accent : Color.white)
                        .background(Capsule().fill(selected ? Color.white : badge.color))
                }
            }
            .font(.body.weight(selected ? .semibold : .regular))
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Brand.accent : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
