// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "clapp",
    platforms: [.macOS(.v12)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "clapp",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/clapp",
            linkerSettings: [
                .linkedFramework("Security"),
            ]
        ),
    ]
)
