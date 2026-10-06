// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "XcodeTailscaleBridge",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "XcodeTailscaleBridge", path: "Sources/XcodeTailscaleBridge"),
    ],
    swiftLanguageModes: [.v5]
)
