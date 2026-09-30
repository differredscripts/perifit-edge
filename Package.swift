// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PerifitEdge",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "PerifitEdge", targets: ["PerifitApp"]),
               .executable(name: "perifit-replay", targets: ["Replay"]),
               .executable(name: "perifit-checks", targets: ["Checks"])],
    targets: [
        .target(name: "EOMCore", publicHeadersPath: "include"),
        .target(name: "PerifitCore", dependencies: ["EOMCore"]),
        .executableTarget(name: "PerifitApp", dependencies: ["PerifitCore"]),
        .executableTarget(name: "Replay", dependencies: ["PerifitCore"]),
        .executableTarget(name: "Checks", dependencies: ["PerifitCore"], path: "Tests/PerifitCoreTests")
    ],
    swiftLanguageModes: [.v5]
)
