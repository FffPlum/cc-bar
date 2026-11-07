// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CCBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CCBar", targets: ["CCBar"]),
        .library(name: "CCBarConfiguration", targets: ["CCBarConfiguration"])
    ],
    dependencies: [
        .package(url: "https://github.com/facebook/zstd.git", exact: "1.5.7"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
        .package(url: "https://github.com/LebJe/TOMLKit.git", exact: "0.6.0"),
        .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2")
    ],
    targets: [
        .target(name: "CCBarConfiguration", dependencies: ["TOMLKit", "Yams"]),
        .executableTarget(
            name: "CCBar",
            dependencies: ["CCBarConfiguration", .product(name: "libzstd", package: "zstd"), "Sparkle"],
            resources: [
                .process("Resources/Assets.xcassets"),
                .process("Resources/Logos"),
                .process("Resources/MenuBarIcon"),
                .copy("Resources/WebInterface")
            ],
            swiftSettings: [.defaultIsolation(MainActor.self), .enableUpcomingFeature("MemberImportVisibility")]
        ),
        .testTarget(name: "CCBarConfigurationTests", dependencies: ["CCBarConfiguration"]),
        .testTarget(
            name: "CCBarTests",
            dependencies: ["CCBar", "CCBarConfiguration", .product(name: "libzstd", package: "zstd"), "Sparkle"],
            resources: [.process("Fixtures")],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        )
    ],
    swiftLanguageModes: [.v5]
)
