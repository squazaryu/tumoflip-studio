// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TumoflipStudio",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TumoflipStudio", targets: ["TumoflipStudio"]),
        .library(name: "TumoCardCore", targets: ["TumoCardCore"]),
        .library(name: "MarauderKit", targets: ["MarauderKit"]),
        .library(name: "TumoflipFapCore", targets: ["TumoflipFapCore"]),
        .library(name: "TumoflipDeviceKit", targets: ["TumoflipDeviceKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0"),
    ],
    targets: [
        .target(
            name: "CPCSCBridge",
            publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("PCSC")]
        ),
        .target(name: "TumoCardCore"),
        .target(name: "MarauderKit"),
        .target(name: "TumoflipFapCore"),
        .target(
            name: "TumoflipDeviceKit",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .executableTarget(
            name: "TumoflipStudio",
            dependencies: [
                "CPCSCBridge",
                "TumoCardCore",
                "MarauderKit",
                "TumoflipFapCore",
                "TumoflipDeviceKit",
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("Network"),
                .linkedFramework("PCSC"),
            ]
        ),
        .testTarget(name: "TumoflipStudioTests", dependencies: ["TumoflipStudio"]),
        .testTarget(name: "TumoCardCoreTests", dependencies: ["TumoCardCore"]),
        .testTarget(name: "MarauderKitTests", dependencies: ["MarauderKit"]),
        .testTarget(name: "TumoflipDeviceKitTests", dependencies: ["TumoflipDeviceKit"]),
    ]
)
