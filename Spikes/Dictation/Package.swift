// swift-tools-version:6.0
import PackageDescription

// Ticket 12's spike, kept apart from Capacity Notch: it proves GigaAM through
// sherpa-onnx on this Mac and is not part of the product. The libraries and
// the model are downloaded into Vendor/ and Models/ (see README.md) and never
// committed.
let package = Package(
    name: "DictationSpike",
    platforms: [.macOS(.v14)],
    targets: [
        .binaryTarget(name: "SherpaOnnxC", path: "Vendor/sherpa-onnx.xcframework"),
        .binaryTarget(name: "onnxruntime", path: "Vendor/onnxruntime.xcframework"),
        .target(
            name: "SherpaOnnx",
            dependencies: ["SherpaOnnxC", "onnxruntime"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("c++")]
        ),
        .target(name: "SpikeCore"),
        .executableTarget(name: "dictation-spike", dependencies: ["SpikeCore", "SherpaOnnx"]),
        .executableTarget(name: "SpikeCoreTests", dependencies: ["SpikeCore"], path: "Tests/SpikeCoreTests"),
    ]
)
