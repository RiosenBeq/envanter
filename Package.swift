// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Envanter",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Envanter", targets: ["Envanter"]),
    ],
    targets: [
        .target(name: "EnvanterCore"),
        .executableTarget(name: "Envanter", dependencies: ["EnvanterCore"]),
        .executableTarget(name: "EnvanterTool", dependencies: ["EnvanterCore"]),
        .testTarget(
            name: "EnvanterCoreTests",
            dependencies: ["EnvanterCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
