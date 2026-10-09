import SwiftUI
import AppKit

/// Geliştirme aracı: ENVANTER_SNAPSHOT_DIR tanımlıysa, pencere içeriğini PNG olarak kaydeder.
/// ENVANTER_SECTIONS="daily,sales" ile ekranlar sırayla gezilir. Normal kullanımda hiçbir etkisi yoktur.
@MainActor
enum DebugSnapshot {
    static func installIfRequested(store: AppStore) {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["ENVANTER_SNAPSHOT_DIR"], !dir.isEmpty else { return }
        let sections = (env["ENVANTER_SECTIONS"] ?? "daily").split(separator: ",").map(String.init)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            for (i, name) in sections.enumerated() {
                if let s = AppSection(rawValue: name) { store.section = s }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                snapshot(to: "\(dir)/\(i)-\(name).png")
                if env["ENVANTER_DUMP"] == "1" { print("=== \(name)"); dump() }
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
              let view = window.contentView?.superview ?? window.contentView else { return }
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: path)) }
    }
}
