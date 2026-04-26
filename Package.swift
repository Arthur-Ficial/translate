// swift-tools-version: 6.0

import PackageDescription

let strictSwiftSettings: [SwiftSetting] = [
    .unsafeFlags([
        "-warn-concurrency",
        "-strict-concurrency=complete"
    ])
]

let package = Package(
    name: "translate",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "translate", targets: ["translate"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-argument-parser.git",
            from: "1.5.0"
        ),
        .package(
            url: "https://github.com/hummingbird-project/hummingbird.git",
            from: "2.0.0"
        )
    ],
    targets: [
        .executableTarget(
            name: "translate",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Hummingbird", package: "hummingbird")
            ],
            path: "Sources/translate",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "translateTests",
            dependencies: ["translate"],
            path: "Tests/translateTests",
            swiftSettings: strictSwiftSettings
        )
    ]
)
