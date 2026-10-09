// swift-tools-version:6.0
import PackageDescription

// Ticket 14's spike, kept apart from CapaTheNotch: it measures which route can
// see a one-finger tap on the trackpad from anywhere, and is not part of the
// product. Nothing is downloaded; MultitouchSupport is opened at run time.
let package = Package(
    name: "TrackpadTapSpike",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "trackpad-tap-spike",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
