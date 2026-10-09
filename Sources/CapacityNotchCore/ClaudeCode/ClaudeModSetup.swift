import Foundation

/// CapaTheNotch's Claude Code mod, put where Claude Code loads it and taken
/// away again (ADR 0001, amended 2026-10-08).
///
/// The mod is a plugin folder, `~/.claude/skills/capathenotch/`: Claude Code
/// loads a folder there with a `.claude-plugin/plugin.json` as
/// `capathenotch@skills-dir`, at the person's scope, in place, with no
/// install step and nothing written to `settings.json`. The folder is
/// CapaTheNotch's own — it says so in a marker file — so Turn Off removes it
/// whole, Claude Code's type files inside it included, and a folder of that
/// name someone else made is never touched.
public enum ClaudeModSetup {
    public static let name = "capathenotch"

    /// The files shipped in the application bundle, copied as they are.
    public static let shipped = [".claude-plugin/plugin.json", "hooks/hooks.json", "hooks/register.ts"]

    /// Written at install: where this copy's bridge is.
    static let bridgeModule = "hooks/bridge.ts"

    /// Says the folder is CapaTheNotch's, so it is the only one it removes.
    static let marker = ".capathenotch"
    static let markerText = "Put here by CapaTheNotch. Turning Claude Code off in CapaTheNotch removes this folder.\n"

    public enum SetupError: Error, Equatable, Sendable {
        /// A folder by that name that CapaTheNotch did not make: left alone.
        case notOurs
        /// The bundle lacks a file of the mod: nothing was written.
        case incomplete
    }

    public static func folder(home: URL) -> URL {
        home.appendingPathComponent(".claude/skills", isDirectory: true).appendingPathComponent(name, isDirectory: true)
    }

    /// The module naming the bridge, as TypeScript: one string constant.
    public static func bridgeSource(bridge: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: bridge, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data("\"\"".utf8)
        return "export const bridge = \(String(decoding: data, as: UTF8.self))\n"
    }

    /// Every file of the mod as it should be on disk, by its path in the
    /// folder.
    static func contents(from source: URL, bridge: String) throws -> [String: Data] {
        var files: [String: Data] = [:]
        for path in shipped {
            guard let data = try? Data(contentsOf: source.appendingPathComponent(path)) else { throw SetupError.incomplete }
            files[path] = data
        }
        files[bridgeModule] = Data(bridgeSource(bridge: bridge).utf8)
        files[marker] = Data(markerText.utf8)
        return files
    }

    /// Whether CapaTheNotch's mod is there — this copy's or an older one's.
    public static func isInstalled(atHome home: URL) -> Bool {
        isOurs(folder(home: home))
    }

    /// Whether the mod there is exactly this copy's, running this bridge.
    public static func isCurrent(atHome home: URL, from source: URL, bridge: String) -> Bool {
        let folder = folder(home: home)
        guard isOurs(folder), let files = try? contents(from: source, bridge: bridge) else { return false }
        return files.allSatisfy { path, data in (try? Data(contentsOf: folder.appendingPathComponent(path))) == data }
    }

    /// Puts the mod in place, or brings an older one up to date; whether
    /// anything was written. Files Claude Code put in the folder are kept.
    @discardableResult
    public static func install(from source: URL, atHome home: URL, bridge: String) throws -> Bool {
        let folder = folder(home: home)
        let manager = FileManager.default
        if isLink(folder) || (manager.fileExists(atPath: folder.path) && !isOurs(folder)) { throw SetupError.notOurs }
        let files = try contents(from: source, bridge: bridge)

        var changed = false
        // The marker last: a folder half written is not yet called ours, and
        // a second try finishes it.
        let order = files.keys.sorted { ($0 == marker ? 1 : 0, $0) < ($1 == marker ? 1 : 0, $1) }
        for path in order where (try? Data(contentsOf: folder.appendingPathComponent(path))) != files[path] {
            let file = folder.appendingPathComponent(path)
            try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try files[path]!.write(to: file, options: .atomic)
            changed = true
        }
        return changed
    }

    /// Removes the mod — only CapaTheNotch's own folder; whether one was
    /// removed.
    @discardableResult
    public static func uninstall(atHome home: URL) throws -> Bool {
        let folder = folder(home: home)
        guard isOurs(folder) else { return false }
        try FileManager.default.removeItem(at: folder)
        return true
    }

    private static func isOurs(_ folder: URL) -> Bool {
        !isLink(folder) && FileManager.default.fileExists(atPath: folder.appendingPathComponent(marker).path)
    }

    private static func isLink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}

/// A Claude Code release, as its folders and `package.json` name it.
public struct ClaudeCodeVersion: Comparable, CustomStringConvertible, Sendable {
    public let parts: [Int]

    public init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 3, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        self.parts = parts.map { $0! }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
    public var description: String { parts.map(String.init).joined(separator: ".") }
}

/// Whether the Claude Code on this Mac runs mods, found from what is on disk:
/// no `claude` is run for it (ADR 0001, amended 2026-10-06).
public enum ClaudeModSupport: Equatable, Sendable {
    /// Some Claude Code here runs mods.
    case supported
    /// Every Claude Code found is older than mods.
    case tooOld
    /// No Claude Code was found where it is usually installed.
    case unknown

    /// Mods are on by default from these releases (Mods overview).
    public static let terminalMinimum = ClaudeCodeVersion("2.1.287")!
    public static let desktopMinimum = ClaudeCodeVersion("2.1.286")!

    public static func verdict(terminal: ClaudeCodeVersion?, desktop: ClaudeCodeVersion?) -> ClaudeModSupport {
        if let terminal, terminal >= terminalMinimum { return .supported }
        if let desktop, desktop >= desktopMinimum { return .supported }
        return terminal == nil && desktop == nil ? .unknown : .tooOld
    }

    public static func onThisMac(home: URL, commands: [URL]? = nil) -> ClaudeModSupport {
        verdict(terminal: terminalVersion(home: home, commands: commands), desktop: desktopVersion(home: home))
    }

    /// The newest Claude Code the desktop app keeps for its Code tab.
    public static func desktopVersion(home: URL) -> ClaudeCodeVersion? {
        let folder = home.appendingPathComponent("Library/Application Support/Claude/claude-code", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.compactMap(ClaudeCodeVersion.init).max()
    }

    /// Where a `claude` command is usually installed.
    public static func usualCommands(home: URL) -> [URL] {
        [
            home.appendingPathComponent(".local/bin/claude"),
            home.appendingPathComponent(".claude/local/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
        ]
    }

    /// The newest `claude` among the usual places: the native installer's
    /// `versions/<version>` file, or the npm package the command belongs to.
    public static func terminalVersion(home: URL, commands: [URL]? = nil) -> ClaudeCodeVersion? {
        (commands ?? usualCommands(home: home)).compactMap(version(of:)).max()
    }

    static func version(of command: URL) -> ClaudeCodeVersion? {
        guard FileManager.default.fileExists(atPath: command.path) else { return nil }
        let resolved = command.resolvingSymlinksInPath()
        let parts = resolved.pathComponents
        if let index = parts.lastIndex(of: "versions"), index + 1 < parts.count, let version = ClaudeCodeVersion(parts[index + 1]) {
            return version
        }
        var candidates = [command.deletingLastPathComponent().appendingPathComponent("node_modules/@anthropic-ai/claude-code/package.json")]
        var folder = resolved.deletingLastPathComponent()
        for _ in 0..<4 {
            candidates.append(folder.appendingPathComponent("package.json"))
            folder = folder.deletingLastPathComponent()
        }
        for candidate in candidates {
            guard let data = try? Data(contentsOf: candidate),
                  let package = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  package["name"] as? String == "@anthropic-ai/claude-code",
                  let version = (package["version"] as? String).flatMap(ClaudeCodeVersion.init) else { continue }
            return version
        }
        return nil
    }
}

/// The mod's state as one word for Copy Diagnostics.
public enum ClaudeModState: String, Sendable {
    case installed
    case notInstalled = "not-installed"
    case tooOld = "too-old"
    case refused

    public static func of(installed: Bool, asked: Bool, agreed: Bool, support: ClaudeModSupport) -> ClaudeModState {
        if installed { return .installed }
        if support == .tooOld { return .tooOld }
        if asked, !agreed { return .refused }
        return .notInstalled
    }

    public var diagnosticCode: String { "claude-mod-\(rawValue)" }
}
