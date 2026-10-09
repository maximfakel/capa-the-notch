import Foundation

/// What Settings ▸ Providers ▸ Claude Code shows under its header (Paper
/// "Settings — Providers — Claude mod working", "— Claude mod not added",
/// "— Claude Code too old for the mod"; the author's decisions of
/// 2026-10-08): why Capacity may lag, the mod's row, and — only while the mod
/// is not working — a way to refresh from a terminal.
public struct ClaudeCodeSettings: Equatable, Sendable {
    /// Where the mod stands, as the row says it.
    public enum Mod: Equatable, Sendable {
        /// In place and some Claude Code here runs it: "● Работает".
        case working
        /// Not in place, and it could be: "Не добавлен".
        case notAdded
        /// Not in place, and this copy cannot put it there — a build run
        /// from outside an Applications folder, whose bridge path would not
        /// last.
        case notAddedHere
        /// No Claude Code here runs mods: too old, or none found.
        case needsNewer
        /// In place, but no Claude Code here runs it any more.
        case installedButNeedsNewer
    }

    /// What the mod's button does; nil when it has none.
    public enum Action: Equatable, Sendable {
        case add
        case remove
    }

    /// The line under the header, saying why Capacity may lag.
    public enum Reason: Equatable, Sendable {
        case withoutMod
        case tooOld(ClaudeCodeVersion)
        case notFound
    }

    public let mod: Mod
    public let reason: Reason?

    /// Settings work this out from what is on disk; nothing is run.
    public static func of(
        installed: Bool,
        support: ClaudeModSupport,
        newestVersion: ClaudeCodeVersion?,
        canInstallHere: Bool
    ) -> ClaudeCodeSettings {
        let lacking: Reason = switch support {
        case .supported: .withoutMod
        case .tooOld: newestVersion.map(Reason.tooOld) ?? .notFound
        case .unknown: .notFound
        }
        if installed {
            return support == .supported
                ? ClaudeCodeSettings(mod: .working, reason: nil)
                : ClaudeCodeSettings(mod: .installedButNeedsNewer, reason: lacking)
        }
        guard support == .supported else { return ClaudeCodeSettings(mod: .needsNewer, reason: lacking) }
        return ClaudeCodeSettings(mod: canInstallHere ? .notAdded : .notAddedHere, reason: .withoutMod)
    }

    public init(mod: Mod, reason: Reason?) {
        self.mod = mod
        self.reason = reason
    }

    /// The mod's button: Add where it can be added, Remove wherever
    /// CapaTheNotch's own folder is, nothing otherwise.
    public var action: Action? {
        switch mod {
        case .working, .installedButNeedsNewer: .remove
        case .notAdded: .add
        case .notAddedHere, .needsNewer: nil
        }
    }

    /// The row's green dot, beside "Работает".
    public var isWorking: Bool { mod == .working }

    /// "Обновить из терминала" stands only while the mod is not working.
    public var showsTerminal: Bool { mod != .working }

    /// The words beside the mod's button.
    public var status: String {
        switch mod {
        case .working: Localization.text("Working")
        case .notAdded: Localization.text("Not added")
        case .notAddedHere: Localization.text("Only from CapaTheNotch in Applications")
        case .needsNewer, .installedButNeedsNewer:
            Localization.format("Needs Claude Code %@ or later", ClaudeModSupport.terminalMinimum.description)
        }
    }

    public var reasonText: String? {
        switch reason {
        case nil: nil
        case .withoutMod: Localization.text("Without the mod, Claude's limits update only from a terminal.")
        case let .tooOld(version):
            Localization.format(
                "Claude Code %@ is installed, and mods arrived in %@. Until then, limits update only from a terminal.",
                version.description, ClaudeModSupport.terminalMinimum.description
            )
        case .notFound:
            Localization.format(
                "No Claude Code %@ or later was found where it is usually installed. Until then, limits update only from a terminal.",
                ClaudeModSupport.terminalMinimum.description
            )
        }
    }
}

/// The two "?" notes of the Claude Code card, as drawn in the open popover
/// "Что такое мод".
public struct SettingsNote: Equatable, Sendable {
    public let title: String
    public let body: String
    /// A quieter last line; nil when there is none.
    public let footer: String?

    public static var mod: SettingsNote {
        SettingsNote(
            title: Localization.text("What the mod is"),
            body: Localization.text("A small add-on for Claude Code. After each of Claude's replies — in the Claude app, VS Code or a terminal — it hands over only the percentages and reset times of your limits. No conversations, no tokens."),
            footer: Localization.text("It lives in ~/.claude/skills/capathenotch. Remove takes it away whole.")
        )
    }

    public static var terminal: SettingsNote {
        SettingsNote(
            title: Localization.text("Refreshing from a terminal"),
            body: Localization.text("Claude Code in a terminal draws a status line, and CapaTheNotch's bridge reads the limits from it after each of Claude's replies. Open Terminal starts claude there; send any message and Capacity updates."),
            footer: Localization.text("Nothing is sent for you. Close the window when you are done.")
        )
    }
}

/// "Открыть Терминал": a `.command` file Terminal runs, starting `claude`
/// with no arguments and no prompt. Opening a file in Terminal asks macOS
/// for nothing; scripting Terminal (`do script`) would need Automation
/// permission.
public enum ClaudeTerminal {
    /// Where the file is written each time: CapaTheNotch's own folder.
    public static func commandFile(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/CapacityNotch", isDirectory: true)
            .appendingPathComponent("Claude Code.command")
    }

    /// The script: `claude` from the shell's own PATH, or else from where it
    /// is usually installed; if none is found, it says so and stops.
    public static func script(usualCommands: [URL], notFound: String) -> String {
        var lines = [
            "#!/bin/sh",
            "# Written by CapaTheNotch: starts Claude Code, so its status line hands over your limits.",
            "cd \"$HOME\" || exit 1",
            "command -v claude >/dev/null 2>&1 && exec claude",
        ]
        for command in usualCommands {
            let path = quoted(command.path)
            lines.append("[ -x \(path) ] && exec \(path)")
        }
        lines.append("echo \(quoted(notFound))")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes the file, executable, and returns where it is.
    @discardableResult
    public static func write(home: URL, notFound: String) throws -> URL {
        let file = commandFile(home: home)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = script(usualCommands: ClaudeModSupport.usualCommands(home: home), notFound: notFound)
        try Data(text.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }

    /// Single quotes, each one inside closed, escaped and reopened.
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension ClaudeModSupport {
    /// The newest Claude Code found on disk, terminal or desktop app — the
    /// version the card names when it is too old.
    public static func newestVersion(home: URL, commands: [URL]? = nil) -> ClaudeCodeVersion? {
        [terminalVersion(home: home, commands: commands), desktopVersion(home: home)].compactMap { $0 }.max()
    }
}
