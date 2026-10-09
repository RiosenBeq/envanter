// swift-tools-version:5.9
import PackageDescription

var products: [Product] = []
var targets: [Target] = [
    // Platformdan bağımsız iş mantığı: reçete motoru, Excel/ModPos okuma-yazma, kayıt
    .target(name: "EnvanterCore"),
    // Komut satırı aracı (uygulama kapalıyken Excel aktarımı)
    .executableTarget(name: "EnvanterTool", dependencies: ["EnvanterCore"]),
    .testTarget(
        name: "EnvanterCoreTests",
        dependencies: ["EnvanterCore"],
        resources: [.copy("Fixtures")]
    ),
]

// SwiftUI uygulaması yalnızca macOS'ta derlenir; çekirdek ve testler Linux'ta (CI) da çalışır.
#if os(macOS)
products.append(.executable(name: "Envanter", targets: ["Envanter"]))
targets.append(.executableTarget(name: "Envanter", dependencies: ["EnvanterCore"]))
#endif

let package = Package(
    name: "Envanter",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
