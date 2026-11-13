// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Hoarder",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "hoarder", targets: ["hoarder"]),
    ],
    targets: [
        .target(name: "HoarderCore"),
        .executableTarget(name: "hoarder", dependencies: ["HoarderCore"]),
        .testTarget(name: "HoarderCoreTests", dependencies: ["HoarderCore"]),
    ]
)

// The menu bar app needs AppKit and SwiftUI. On Linux only the core and the CLI build, for devices.
#if os(macOS)
package.products.append(.executable(name: "HoarderApp", targets: ["HoarderApp"]))
package.targets.append(.executableTarget(name: "HoarderApp", dependencies: ["HoarderCore"]))
#endif
