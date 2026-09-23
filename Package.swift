// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CapacityNotch",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "CapacityNotch", targets: ["CapacityNotch"]),
        .executable(name: "CapacityNotchClaudeBridge", targets: ["CapacityNotchClaudeBridge"]),
        .executable(name: "CapacityNotchTests", targets: ["CapacityNotchTests"]),
    ],
    targets: [
        .target(name: "CapacityNotchCore"),
        .executableTarget(
            name: "CapacityNotch",
            dependencies: ["CapacityNotchCore"],
            resources: [.process("Resources")]
        ),
        .executableTarget(name: "CapacityNotchClaudeBridge", dependencies: ["CapacityNotchCore"]),
        .executableTarget(
            name: "CapacityNotchTests",
            dependencies: ["CapacityNotchCore"],
            path: "Tests/CapacityNotchTests"
        ),
    ]
)
