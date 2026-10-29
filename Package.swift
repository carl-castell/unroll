// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "unroll",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "unroll", targets: ["unroll"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "unroll",
            dependencies: [
                "UnrollCore",
                "UnrollDevice",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(name: "UnrollCore"),
        .target(
            name: "UnrollDevice",
            dependencies: ["UnrollCore"],
            linkerSettings: [.linkedFramework("ImageCaptureCore")]
        ),
        .testTarget(name: "UnrollCoreTests", dependencies: ["UnrollCore"]),
    ]
)
