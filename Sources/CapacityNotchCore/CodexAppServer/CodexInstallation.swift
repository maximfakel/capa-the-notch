import Foundation

/// Where an installed Codex runtime lives on this machine.
public enum CodexInstallation {
    public static let defaultSearchPaths = [
        "/Applications/ChatGPT.app/Contents/Resources/codex",
        // Where ChatGPT keeps its Codex since its September 2026 releases: a
        // native build behind a small shell launcher, needing nothing else.
        "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex",
        "\(NSHomeDirectory())/.local/bin/codex",
        "\(NSHomeDirectory())/.codex/bin/codex",
    ]

    /// Returns the first executable Codex binary, or `nil` when Codex is not
    /// installed. Capacity Notch reads no Codex file other than this binary.
    public static func locate(
        searchPaths: [String] = defaultSearchPaths,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        searchPaths.first(where: isExecutable)
    }

    /// What Codex runs with: the application's own environment, with the
    /// places a Terminal would look for programs added to its PATH. Opened
    /// from Finder, an application has only the system's directories, and a
    /// Codex installed with npm — a script that runs `node` — finds no Node
    /// there and ends before it can answer.
    public static func environment(
        base: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String: String] {
        var environment = base
        var path = (base["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        for extra in ["/opt/homebrew/bin", "/usr/local/bin", home.appendingPathComponent(".local/bin").path] where !path.contains(extra) {
            path.append(extra)
        }
        environment["PATH"] = path.joined(separator: ":")
        return environment
    }
}
