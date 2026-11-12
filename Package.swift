// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Hoarder",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "hoarder", targets: ["hoarder"]),
        .executable(name: "HoarderApp", targets: ["HoarderApp"]),
    ],
    targets: [
        .target(name: "HoarderCore"),
        .executableTarget(name: "hoarder", dependencies: ["HoarderCore"]),
        .executableTarget(name: "HoarderApp", dependencies: ["HoarderCore"]),
        .testTarget(name: "HoarderCoreTests", dependencies: ["HoarderCore"]),
    ]
)
