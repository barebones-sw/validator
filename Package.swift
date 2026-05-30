// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "VNUSwift",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "VNUSwiftCore",
            targets: ["VNUSwiftCore"]
        ),
        .executable(
            name: "vnu-swift",
            targets: ["VNUServer"]
        )
    ],
    targets: [
        .target(
            name: "VNUSwiftCore"
        ),
        .executableTarget(
            name: "VNUServer",
            dependencies: ["VNUSwiftCore"]
        ),
        .testTarget(
            name: "VNUSwiftCoreTests",
            dependencies: ["VNUSwiftCore"],
            path: "tests/VNUSwiftCoreTests"
        )
    ]
)
