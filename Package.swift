// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "unroll",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "unroll", targets: ["unroll"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
        .package(url: "https://github.com/tuist/Noora.git", exact: "0.57.6"),
    ],
    targets: [
        .executableTarget(
            name: "unroll",
            dependencies: [
                "UnrollCore",
                "UnrollDevice",
                "UnrollStore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(name: "UnrollCore"),
        .target(
            name: "UnrollDevice",
            dependencies: ["UnrollCore"],
            linkerSettings: [.linkedFramework("ImageCaptureCore")]
        ),
        .target(
            name: "UnrollStore",
            dependencies: ["UnrollCore"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(name: "UnrollTestSupport", dependencies: ["UnrollCore"]),
        .testTarget(name: "UnrollCoreTests", dependencies: ["UnrollCore", "UnrollTestSupport"]),
        .testTarget(name: "UnrollStoreTests", dependencies: ["UnrollStore", "UnrollTestSupport"]),
    ]
)
