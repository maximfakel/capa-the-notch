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
    dependencies: [
        .package(path: "Vendor/Murmur"),
    ],
    targets: [
        .target(name: "CapacityNotchCore"),
        .binaryTarget(name: "SherpaOnnxC", path: "Vendor/Dictation/sherpa-onnx.xcframework"),
        .binaryTarget(name: "onnxruntime", path: "Vendor/Dictation/onnxruntime.xcframework"),
        .executableTarget(
            name: "CapacityNotch",
            dependencies: [
                "CapacityNotchCore",
                "SherpaOnnxC",
                "onnxruntime",
                .product(name: "Murmur", package: "murmur"),
            ],
            resources: [.process("Resources")],
            linkerSettings: [.linkedLibrary("c++")]
        ),
        .executableTarget(name: "CapacityNotchClaudeBridge", dependencies: ["CapacityNotchCore"]),
        .executableTarget(
            name: "CapacityNotchTests",
            dependencies: ["CapacityNotchCore"],
            path: "Tests/CapacityNotchTests"
        ),
    ]
)
