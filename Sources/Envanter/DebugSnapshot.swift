import SwiftUI
import AppKit
import EnvanterCore

/// Geliştirme aracı: ENVANTER_SNAPSHOT_DIR tanımlıysa pencere içeriğini PNG olarak kaydeder (CI'da ekran görüntüleri için).
///   ENVANTER_SECTIONS="overview,daily,analytics:abc,recipes:11101"  ekranlar sırayla gezilir
///     (iki noktadan sonrası: İstatistikler sekmesi — general/item/abc/menu — ya da Reçeteler'de seçilecek ürün kodu)
///   ENVANTER_DATE=2026-08-15                                          seçili gün
///   ENVANTER_SNAPSHOT_SIZE=1440x1000                                  pencere boyutu (ekrandan büyük olabilir)
///   ENVANTER_QUIT_AFTER_SNAPSHOT=1                                    bitince çık
/// Normal kullanımda hiçbir etkisi yoktur.
@MainActor
enum DebugSnapshot {
    /// onAppear birden fazla kez tetiklenebilir (ör. pencere stili değişince); görev yalnızca bir kez çalışmalı,
    /// yoksa iki görev aynı dosyalara farklı anlarda yazar ve görüntüler ekranlarla kayar.
    private static var started = false

    static func installIfRequested(store: AppStore) {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["ENVANTER_SNAPSHOT_DIR"], !dir.isEmpty, !started else { return }
        started = true
        let sections = (env["ENVANTER_SECTIONS"] ?? "daily").split(separator: ",").map(String.init)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let d = env["ENVANTER_DATE"], DateKey.isValid(d) { store.selectedDate = d }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if let size = env["ENVANTER_SNAPSHOT_SIZE"]?.split(separator: "x").compactMap({ Double($0) }), size.count == 2,
               let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) {
                // Başlıklı pencereler ekran yüksekliğine sığdırılır; CI ekranı küçük olduğundan çerçevesiz pencereye geçilir
                window.styleMask = [.borderless, .resizable]
                window.setFrame(NSRect(x: 0, y: 0, width: size[0], height: size[1]), display: true)
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            for (i, spec) in sections.enumerated() {
                let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
                let name = parts[0]
                let arg = parts.count > 1 ? parts[1] : nil
                if name == "analytics", let arg, let tab = AnalyticsTab.named(arg) { store.analyticsTab = tab }
                if name == "recipes", let arg { store.recipeSelection = arg }
                if let s = AppSection(rawValue: name) { store.section = s }
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                let file = "\(dir)/\(String(format: "%02ld", i + 1))-\(spec.replacingOccurrences(of: ":", with: "-")).png"
                snapshot(to: file)
                if env["ENVANTER_DUMP"] == "1" { print("=== \(spec)"); dump() }
            }
            if env["ENVANTER_QUIT_AFTER_SNAPSHOT"] == "1" { NSApp.terminate(nil) }
        }
    }

    static func dump() {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { return }
        print("WINDOW frame=\(window.frame) contentLayoutRect=\(window.contentLayoutRect)")
        func walk(_ v: NSView, _ depth: Int) {
            let f = v.convert(v.bounds, to: nil)
            let name = String(describing: type(of: v))
            if depth <= 14 && (f.height > 300 || depth <= 4) {
                print(String(repeating: " ", count: depth) + "\(name) win=\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height)) hidden=\(v.isHidden)")
            }
            for c in v.subviews { walk(c, depth + 1) }
        }
        if let root = window.contentView?.superview { walk(root, 0) }
        fflush(stdout)
    }

    static func snapshot(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: path)) }
    }
}
