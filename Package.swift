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
        ),
        .executable(
            name: "vnu-parity",
            targets: ["VNUParity"]
        )
    ],
    targets: [
        .target(
            name: "VNUSwiftCore"
        ),
        .target(
            name: "VNUParityCore",
            dependencies: ["VNUSwiftCore"]
        ),
        .executableTarget(
            name: "VNUServer",
            dependencies: ["VNUSwiftCore"]
        ),
        .executableTarget(
            name: "VNUParity",
            dependencies: ["VNUParityCore"]
        ),
        .testTarget(
            name: "VNUSwiftCoreTests",
            dependencies: ["VNUSwiftCore"],
            path: "tests/VNUSwiftCoreTests"
        ),
        .testTarget(
            name: "VNUParityCoreTests",
            dependencies: ["VNUParityCore"],
            path: "tests/VNUParityCoreTests"
        )
    ]
)
