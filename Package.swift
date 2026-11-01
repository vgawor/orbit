// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Orbit",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Orbit", targets: ["Orbit"]),
        .executable(name: "orbit-cli", targets: ["OrbitCLI"]),
    ],
    dependencies: [
        // Automatic updates for builds shipped outside the App Store.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.7.3"),
    ],
    targets: [
        // Shared by the app and the CLI: API config, message types, Claude hook installer.
        .target(name: "OrbitKit", path: "OrbitKit"),
        .executableTarget(name: "Orbit", dependencies: ["OrbitKit", .product(name: "Sparkle", package: "Sparkle")], path: "Orbit"),
        .executableTarget(name: "OrbitCLI", dependencies: ["OrbitKit"], path: "OrbitCLI"),
        // Tests: `swift test`
        .testTarget(name: "OrbitTests", dependencies: ["Orbit", "OrbitKit"], path: "Tests/OrbitTests"),
        .testTarget(name: "OrbitKitTests", dependencies: ["OrbitKit"], path: "Tests/OrbitKitTests"),
    ]
)
