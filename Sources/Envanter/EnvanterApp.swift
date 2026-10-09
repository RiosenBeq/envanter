import SwiftUI
import AppKit
import EnvanterCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct EnvanterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup("Envanter") {
            ContentView()
                .environmentObject(store)
                .environment(\.locale, Locale(identifier: "tr_TR"))
                .frame(minWidth: 1120, minHeight: 700)
                .tint(Brand.accent)
                .onAppear { DebugSnapshot.installIfRequested(store: store) }
        }
        .defaultSize(width: 1400, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Satış Raporu İçe Aktar…") { store.section = .daily; store.pickAndImportFile() }
                    .keyboardShortcut("o")
                Button("Panodan Satış Yapıştır") { store.section = .daily; store.beginPasteImport() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                Divider()
                Button("Günü Excel'e Aktar…") { store.exportDayExcel() }
                    .keyboardShortcut("e")
            }
            CommandMenu("Gün") {
                Button("Önceki Gün") { store.shiftDay(-1) }.keyboardShortcut("[")
                Button("Sonraki Gün") { store.shiftDay(1) }.keyboardShortcut("]")
                Button("Bugün") { store.goToday() }.keyboardShortcut("t")
            }
        }
    }
}
