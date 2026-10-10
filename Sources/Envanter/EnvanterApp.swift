import SwiftUI
import AppKit
import EnvanterCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Çıkışta odaktaki alanın yazısı kaybolmasın: önce düzenlemeyi bitir (alan değerini kaydeder),
    /// bir sonraki turda çıkışa izin ver; son kayıt willTerminate'te yapılır.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let window = NSApp.keyWindow, window.firstResponder is NSTextView else { return .terminateNow }
        window.makeFirstResponder(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            MainActor.assumeIsolated { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }
}

@main
struct EnvanterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup(Brand.appName) {
            ContentView()
                .environmentObject(store)
                .environment(\.locale, Locale(identifier: "tr_TR"))
                .frame(minWidth: 1180, minHeight: 720)
                .tint(Brand.accent)
                .onAppear {
                    SelfTest.runIfRequested()
                    DebugSnapshot.installIfRequested(store: store)
                }
        }
        .defaultSize(width: 1440, height: 920)
        // Başlık çubuğu içerikle birleşir (cam yüzeyler pencerenin tepesine kadar ortam ışığını gösterir)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("\(Brand.appName) Hakkında") { showAbout() }
            }
            CommandGroup(replacing: .appSettings) {
                Button("Ayarlar…") { store.section = .backup }.keyboardShortcut(",")
            }
            CommandGroup(replacing: .newItem) {
                Button("Satış Raporu İçe Aktar…") { store.section = .daily; store.pickAndImportFile() }
                    .keyboardShortcut("o")
                Button("Panodan Satış Yapıştır") { store.section = .daily; store.beginPasteImport() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                Divider()
                Button("Günü Excel'e Aktar…") { store.exportDayExcel() }
                    .keyboardShortcut("e")
                Button("Sayım Formu (Excel)…") { store.exportCountSheet() }
                Button("Sipariş Listesini Kopyala") { store.copyOrderText(date: store.selectedDate) }
            }
            CommandMenu("Gün") {
                Button("Önceki Gün") { store.shiftDay(-1) }.keyboardShortcut("[")
                Button("Sonraki Gün") { store.shiftDay(1) }.keyboardShortcut("]")
                Button("Bugün") { store.goToday() }.keyboardShortcut("t")
                Divider()
                Button(store.lockMenuTitle(store.selectedDate)) {
                    store.requestLockToggle(store.selectedDate)
                }
                .keyboardShortcut("l")
                // Günlük Sayım düğmesiyle aynı kural: sayım yapılmamış gün kapatılmaz; personel hesabıyla kapatmadan
                // önce onay istenir ve kapatılmış günün kilidini yalnızca patron / müdür açar
                .disabled(!store.lockAction(store.selectedDate).isAvailable)
            }
            CommandMenu("Git") {
                ForEach(AppSection.allCases.filter { $0 != .backup }) { s in
                    if let key = s.shortcut {
                        Button(s.title) { store.section = s }.keyboardShortcut(key, modifiers: .command)
                    } else {
                        Button(s.title) { store.section = s }
                    }
                }
            }
        }
    }

    private func showAbout() {
        let credits = NSAttributedString(
            string: "Restoran stok, fire ve maliyet takibi.\nModPos satış raporu + reçete motoru, sayım, sipariş önerisi ve istatistikler.\n\nVeri klasörü: \(store.persistence.directory.path)",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: Brand.appName,
            .credits: credits,
        ])
        NSApp.activate(ignoringOtherApps: true)
    }
}
