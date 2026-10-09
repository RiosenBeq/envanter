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
        switch store.section ?? .daily {
        case .daily: DailyView()
        case .sales: SalesView()
        case .summary: SummaryView()
        case .recipes: RecipesView()
        case .items: ItemsView()
        case .backup: BackupView()
        case .help: HelpView()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "shippingbox.fill").font(.title2).foregroundStyle(Brand.accent)
                Text("Envanter").font(.title3.weight(.bold))
                Spacer()
            }
            .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    group("Envanter", [.daily, .sales, .summary])
                    group("Tanımlar", [.recipes, .items])
                    group("Diğer", [.backup, .help])
                }
                .padding(.horizontal, 10)
            }
            Spacer(minLength: 0)
        }
    }

    private func group(_ title: String, _ items: [AppSection]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 4)
            ForEach(items) { s in row(s) }
        }
    }

    private func row(_ s: AppSection) -> some View {
        let selected = (store.section ?? .daily) == s
        return Button { store.section = s } label: {
            HStack(spacing: 10) {
                Image(systemName: s.icon).frame(width: 20)
                Text(s.title)
                Spacer()
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
