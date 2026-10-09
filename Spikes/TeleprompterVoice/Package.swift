// swift-tools-version:6.0
import PackageDescription

// Ticket 20's measurement, kept apart from CapaTheNotch: can GigaAM, re-decoding
// a sliding window, follow a voice reading the Script closely enough? It links
// the app's own speech libraries (Vendor → ../../Vendor/Dictation) and measures
// the app's own ScriptFollower (a link to Sources/CapacityNotchCore). Audio is
// synthesised with `say` into Audio/, which is never committed; so are the
// models (see README.md).
let package = Package(
    name: "TeleprompterVoiceSpike",
    platforms: [.macOS(.v14)],
    targets: [
        .binaryTarget(name: "SherpaOnnxC", path: "Vendor/sherpa-onnx.xcframework"),
        .binaryTarget(name: "onnxruntime", path: "Vendor/onnxruntime.xcframework"),
        .target(name: "FollowCore"),
        .executableTarget(
            name: "voice-follow-spike",
            dependencies: ["FollowCore", "SherpaOnnxC", "onnxruntime"],
            linkerSettings: [.linkedLibrary("c++")]
        ),
    ]
)
