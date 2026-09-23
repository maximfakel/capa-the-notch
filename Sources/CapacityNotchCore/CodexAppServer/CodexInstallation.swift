import Foundation

/// Where an installed Codex runtime lives on this machine.
public enum CodexInstallation {
    public static let defaultSearchPaths = [
        "/Applications/ChatGPT.app/Contents/Resources/codex",
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
}
