import Foundation

/// Finds Murmur's compiled shader bundle in a packaged app while retaining
/// SwiftPM's adjacent-bundle lookup for command-line builds.
enum MurmurShaderResources {
    static let bundle: Bundle = {
        let name = "Murmur_Murmur.bundle"
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(name),
            Bundle.main.bundleURL.appendingPathComponent(name),
        ]

        for case let url? in candidates {
            if let bundle = Bundle(url: url) { return bundle }
        }

        return .module
    }()
}
