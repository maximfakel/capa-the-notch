import Foundation

/// Claude Code's status line set to run the bridge, and put back (ADR 0001,
/// amended 2026-10-06).
///
/// `~/.claude/settings.json` is the person's, and can hold credentials, so it
/// is edited as text: the top-level `statusLine` value alone is replaced,
/// added or removed, and every other byte of the file stays as it was.
public enum ClaudeStatusLineSetup {
    public enum Outcome: Equatable, Sendable {
        /// The new text, and the earlier `statusLine` value as it was
        /// written, to put back on Turn Off — nil when there was none.
        case installed(text: String, previous: String?)
        /// The bridge already runs; nothing to change, nothing to undo.
        case alreadyInstalled
    }

    public enum SetupError: Error, Equatable, Sendable {
        /// Not a JSON object Claude Code could read either: left untouched.
        case notASettingsObject
    }

    static let bridgeName = "CapacityNotchClaudeBridge"

    /// Whether `text` runs this bridge, at this path, as its status line.
    public static func isInstalled(_ text: String, bridge: String) -> Bool {
        guard let command = command(in: text) else { return false }
        return command == bridge || command.hasPrefix(bridge + " ")
    }

    /// Whether `text` runs a bridge from any copy — this one, an older
    /// bundle, one set up by hand — as its status line.
    public static func runsABridge(_ text: String) -> Bool {
        command(in: text)?.contains(bridgeName) == true
    }

    private static func command(in text: String) -> String? {
        guard let object = try? settings(text), let line = object["statusLine"] as? [String: Any] else { return nil }
        return line["command"] as? String
    }

    /// `text` — or a new file when there is none — with the bridge as its
    /// status line. A status line already there runs after the bridge,
    /// through a shell, so a pipe or `~` in it means what it meant.
    public static func install(into text: String?, bridge: String) throws -> Outcome {
        guard let text else {
            return .installed(text: "{\n  \"statusLine\": \(value(command: bridge, keeping: [:]))\n}\n", previous: nil)
        }
        let object = try settings(text)
        let scanned = try TopLevel(text)
        if isInstalled(text, bridge: bridge) { return .alreadyInstalled }
        guard let range = scanned.valueRange(of: "statusLine") else {
            return .installed(text: scanned.inserting(key: "statusLine", value: value(command: bridge, keeping: [:])), previous: nil)
        }
        let previous = String(text[range])
        var kept = (object["statusLine"] as? [String: Any]) ?? [:]
        var command = bridge
        if kept["type"] as? String == "command", let own = kept["command"] as? String, !own.isEmpty {
            let first = own.prefix { !$0.isWhitespace }
            if first.hasSuffix("/" + bridgeName) {
                // Another copy's bridge — the old bundle's, say: only its
                // path changes, whatever it passes on is kept.
                command += own.dropFirst(first.count)
            } else {
                command += " -- /bin/sh -c " + shellQuoted(own)
            }
        }
        kept["type"] = nil
        kept["command"] = nil
        return .installed(text: text.replacingCharacters(in: range, with: value(command: command, keeping: kept)), previous: previous)
    }

    /// `text` with what was there before the bridge put back, or the
    /// status line removed when there was none; nil when the bridge no
    /// longer runs there — the person has changed it since, and it is theirs.
    public static func uninstall(from text: String, previous: String?) throws -> String? {
        _ = try settings(text)
        guard runsABridge(text) else { return nil }
        let scanned = try TopLevel(text)
        guard let range = scanned.valueRange(of: "statusLine") else { return nil }
        if let previous { return text.replacingCharacters(in: range, with: previous) }
        return scanned.removing(key: "statusLine")
    }

    // MARK: - Claude Code's own file

    /// Claude Code's settings for the person, where the status line is set.
    public static func settingsFile(home: URL) -> URL {
        home.appendingPathComponent(".claude/settings.json")
    }

    public static func isInstalled(atHome home: URL, bridge: String) -> Bool {
        settingsText(home: home).map { isInstalled($0, bridge: bridge) } ?? false
    }

    public static func runsABridge(atHome home: URL) -> Bool {
        settingsText(home: home).map(runsABridge) ?? false
    }

    private static func settingsText(home: URL) -> String? {
        try? String(contentsOf: settingsFile(home: home).resolvingSymlinksInPath(), encoding: .utf8)
    }

    /// Sets the bridge as the status line in the person's settings file —
    /// through a link if it is one, keeping its permissions — and returns
    /// the earlier value to put back, or nil when nothing was changed or
    /// there was none.
    public static func install(atHome home: URL, bridge: String) throws -> (changed: Bool, previous: String?) {
        let file = settingsFile(home: home).resolvingSymlinksInPath()
        let text = FileManager.default.fileExists(atPath: file.path) ? try String(contentsOf: file, encoding: .utf8) : nil
        guard case let .installed(changed, previous) = try install(into: text, bridge: bridge) else { return (false, nil) }
        try write(changed, to: file)
        return (true, previous)
    }

    /// Puts back what was there before; does nothing if the bridge no
    /// longer runs there.
    @discardableResult
    public static func uninstall(atHome home: URL, previous: String?) throws -> Bool {
        let file = settingsFile(home: home).resolvingSymlinksInPath()
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let restored = try uninstall(from: text, previous: previous) else { return false }
        try write(restored, to: file)
        return true
    }

    private static func write(_ text: String, to file: URL) throws {
        let permissions = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.posixPermissions]
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file, options: .atomic)
        if let permissions {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path)
        }
    }

    // MARK: -

    private static func settings(_ text: String) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw SetupError.notASettingsObject
        }
        return object
    }

    /// The status line as written into the file, at the first level of
    /// indentation, `type` and `command` first.
    private static func value(command: String, keeping kept: [String: Any]) -> String {
        var pairs = [("type", json("command")), ("command", json(command))]
        for key in kept.keys.sorted() { pairs.append((key, json(kept[key]!))) }
        let lines = pairs.map { "    \(json($0.0)): \($0.1)" }.joined(separator: ",\n")
        return "{\n\(lines)\n  }"
    }

    private static func json(_ value: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes, .sortedKeys])) ?? Data("null".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// Single quotes for `/bin/sh`, a quote inside closed, escaped and
    /// reopened.
    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}

/// Where each top-level key's value sits in a JSON object's text, found
/// without rewriting anything around it.
private struct TopLevel {
    let text: String
    /// Each key with the range of its key (from its opening quote) and of
    /// its value.
    private(set) var members: [(key: String, keyStart: String.Index, value: Range<String.Index>)] = []
    private(set) var close: String.Index

    init(_ text: String) throws {
        self.text = text
        var i = text.startIndex
        func skipSpace() { while i < text.endIndex, text[i].isWhitespace { i = text.index(after: i) } }
        func fail() -> ClaudeStatusLineSetup.SetupError { .notASettingsObject }
        func string() throws -> String {
            guard i < text.endIndex, text[i] == "\"" else { throw fail() }
            let start = text.index(after: i)
            i = start
            while i < text.endIndex, text[i] != "\"" {
                if text[i] == "\\" { i = text.index(after: i) }
                guard i < text.endIndex else { throw fail() }
                i = text.index(after: i)
            }
            guard i < text.endIndex else { throw fail() }
            let raw = String(text[start..<i])
            i = text.index(after: i)
            return (try? JSONSerialization.jsonObject(with: Data("\"\(raw)\"".utf8), options: .fragmentsAllowed) as? String) ?? raw
        }
        func skipValue() throws {
            guard i < text.endIndex else { throw fail() }
            switch text[i] {
            case "\"": _ = try string()
            case "{", "[":
                var depth = 0
                repeat {
                    guard i < text.endIndex else { throw fail() }
                    switch text[i] {
                    case "\"": _ = try string(); continue
                    case "{", "[": depth += 1
                    case "}", "]": depth -= 1
                    default: break
                    }
                    i = text.index(after: i)
                } while depth > 0
            default:
                while i < text.endIndex, !",}] \n\r\t".contains(text[i]) { i = text.index(after: i) }
            }
        }
        skipSpace()
        guard i < text.endIndex, text[i] == "{" else { throw fail() }
        i = text.index(after: i)
        skipSpace()
        close = i
        while i < text.endIndex, text[i] != "}" {
            let keyStart = i
            let key = try string()
            skipSpace()
            guard i < text.endIndex, text[i] == ":" else { throw fail() }
            i = text.index(after: i)
            skipSpace()
            let valueStart = i
            try skipValue()
            // A key twice leaves it unclear which one Claude Code reads.
            guard !members.contains(where: { $0.key == key }) else { throw fail() }
            members.append((key, keyStart, valueStart..<i))
            skipSpace()
            if i < text.endIndex, text[i] == "," { i = text.index(after: i); skipSpace() }
        }
        guard i < text.endIndex else { throw fail() }
        close = i
    }

    func valueRange(of key: String) -> Range<String.Index>? {
        members.first { $0.key == key }?.value
    }

    /// The key added last, after the last member, indented as that member is.
    func inserting(key: String, value: String) -> String {
        let entry = "\"\(key)\": \(value)"
        guard let last = members.last else {
            return text.replacingCharacters(in: close..<close, with: "\n  \(entry)\n")
        }
        let indent = Self.indent(before: last.keyStart, in: text)
        return text.replacingCharacters(in: last.value.upperBound..<last.value.upperBound, with: ",\n\(indent)\(entry)")
    }

    /// The member gone, with the comma and line that joined it to the rest.
    func removing(key: String) -> String? {
        guard let index = members.firstIndex(where: { $0.key == key }) else { return nil }
        let member = members[index]
        if index > 0 {
            return text.replacingCharacters(in: members[index - 1].value.upperBound..<member.value.upperBound, with: "")
        }
        if members.count > 1 {
            return text.replacingCharacters(in: member.keyStart..<members[1].keyStart, with: "")
        }
        var start = member.keyStart
        while start > text.startIndex, text[text.index(before: start)].isWhitespace { start = text.index(before: start) }
        return text.replacingCharacters(in: start..<close, with: "")
    }

    private static func indent(before index: String.Index, in text: String) -> String {
        var start = index
        while start > text.startIndex, text[text.index(before: start)] == " " || text[text.index(before: start)] == "\t" {
            start = text.index(before: start)
        }
        return String(text[start..<index])
    }
}
