import Foundation

/// The status-line bridge's path, moved from the application's old bundle to
/// where it now is. Until 0.3.0 the application was CapacityNotch.app, and the
/// README had people run that bundle's bridge from Claude Code's settings;
/// CapaTheNotch.app is the same application under its new name. A path to the
/// old bundle stops Claude Code's status line once that bundle is gone — the
/// bridge's, and a person's own status line passed to it after `--`.
public enum ClaudeBridgeMove {
    public static let oldBundle = "CapacityNotch.app"
    public static let bridgeInBundle = "Contents/MacOS/CapacityNotchClaudeBridge"

    /// Claude Code's own settings for a person, where a status line is set.
    public static func settingsFiles(home: URL) -> [URL] {
        let folder = home.appendingPathComponent(".claude", isDirectory: true)
        return ["settings.json", "settings.local.json"].map { folder.appendingPathComponent($0) }
    }

    /// `text` with every path to the old bundle's bridge pointed at `bridge`,
    /// or nothing when there is none to move. Only the path changes: the rest
    /// of the file, whatever follows the bridge included, is kept as it was.
    /// A path is the whole word it stands in, so a bundle kept in
    /// ~/Applications moves as wholly as one in /Applications; JSON's escaped
    /// slashes are read as slashes.
    public static func moved(_ text: String, to bridge: String) -> String? {
        let pattern = #"(?<![^"\s])[^"\s]*?CapacityNotch\.app\\?/Contents\\?/MacOS\\?/CapacityNotchClaudeBridge"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        guard regex.firstMatch(in: text, range: range) != nil else { return nil }
        // Written into a JSON string: its quotes and backslashes escaped.
        let json = bridge.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: json))
    }

    /// Each of Claude Code's settings files under `home` that runs the old
    /// bridge, written back with only that path changed — through a link if
    /// it is one, keeping the permissions it had. Nothing read is kept.
    @discardableResult
    public static func move(home: URL, to bridge: String) throws -> [URL] {
        var moved: [URL] = []
        for file in settingsFiles(home: home) {
            let target = file.resolvingSymlinksInPath()
            guard let data = try? Data(contentsOf: target),
                  let text = String(data: data, encoding: .utf8),
                  let changed = self.moved(text, to: bridge) else { continue }
            let permissions = (try? FileManager.default.attributesOfItem(atPath: target.path))?[.posixPermissions]
            try Data(changed.utf8).write(to: target, options: .atomic)
            if let permissions {
                try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
            }
            moved.append(file)
        }
        return moved
    }
}
