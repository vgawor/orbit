// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Viktor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Viktor", targets: ["Viktor"]),
        .executable(name: "viktor-cli", targets: ["ViktorCLI"]),
    ],
    dependencies: [
        // Automatic updates for builds shipped outside the App Store.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.7.3"),
    ],
    targets: [
        // Shared by the app and the CLI: API config, message types, Claude hook installer.
        .target(name: "ViktorKit", path: "ViktorKit"),
        .executableTarget(name: "Viktor", dependencies: ["ViktorKit", .product(name: "Sparkle", package: "Sparkle")], path: "Viktor"),
        .executableTarget(name: "ViktorCLI", dependencies: ["ViktorKit"], path: "ViktorCLI"),
        // Tests: `swift test`
        .testTarget(name: "ViktorTests", dependencies: ["Viktor", "ViktorKit"], path: "Tests/ViktorTests"),
        .testTarget(name: "ViktorKitTests", dependencies: ["ViktorKit"], path: "Tests/ViktorKitTests"),
    ]
)
