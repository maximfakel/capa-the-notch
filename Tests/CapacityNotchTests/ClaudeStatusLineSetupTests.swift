import CapacityNotchCore
import Foundation

private let bridge = "/Applications/CapaTheNotch.app/Contents/MacOS/CapacityNotchClaudeBridge"

private func statusLine(_ text: String) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    guard let line = object?["statusLine"] as? [String: Any] else {
        throw TestFailure(description: "No statusLine in \(text)")
    }
    return line
}

private func installed(_ settings: String?) throws -> (text: String, previous: String?) {
    guard case let .installed(text, previous) = try ClaudeStatusLineSetup.install(into: settings, bridge: bridge) else {
        throw TestFailure(description: "It should be installed into \(settings ?? "nothing")")
    }
    return (text, previous)
}

func theStatusLineIsAddedAndTheRestOfTheFileKeptByteForByte() throws {
    let settings = """
    {
      "model": "opus",
      "env": { "SECRET": "a/b" },
      "permissions": {"allow": ["Bash(ls)"]}
    }

    """
    let (text, previous) = try installed(settings)
    let line = try statusLine(text)
    try expect(previous == nil, "There was no status line before")
    try expect(line["command"] as? String == bridge, "The bridge runs, got \(text)")
    try expect(line["type"] as? String == "command", "as a command")
    try expect(text.hasPrefix(String(settings.dropLast(4))), "Everything before is untouched, got \(text)")
    try expect(text.contains(#""env": { "SECRET": "a/b" }"#), "the env block as written, slashes and all")
    try expect(ClaudeStatusLineSetup.isInstalled(text, bridge: bridge), "and it is seen as installed")
}

func aStatusLineAlreadyThereRunsAfterTheBridge() throws {
    let settings = #"{"statusLine": {"type": "command", "command": "npx -y ccusage statusline | head -1", "padding": 0}, "model": "opus"}"#
    let (text, previous) = try installed(settings)
    let line = try statusLine(text)
    try expect(
        previous == #"{"type": "command", "command": "npx -y ccusage statusline | head -1", "padding": 0}"#,
        "The earlier value is kept to put back, got \(previous ?? "nil")"
    )
    try expect(
        line["command"] as? String == bridge + " -- /bin/sh -c 'npx -y ccusage statusline | head -1'",
        "The person's own line runs after the bridge, through a shell, got \(line["command"] ?? "nil")"
    )
    try expect(line["padding"] as? Int == 0, "with its other settings kept")
    try expect(text.hasSuffix(#", "model": "opus"}"#), "and the rest of the file as it was, got \(text)")

    let (quotedText, _) = try installed(#"{"statusLine": {"type": "command", "command": "echo 'it''s'"}}"#)
    let quoted = try statusLine(quotedText)
    try expect(
        quoted["command"] as? String == bridge + #" -- /bin/sh -c 'echo '\''it'\'''\''s'\'''"#,
        "Single quotes inside survive the shell, got \(quoted["command"] ?? "nil")"
    )
}

func aBridgeAlreadySetUpIsLeftAsItIs() throws {
    let settings = #"{"statusLine": {"type": "command", "command": "/Applications/CapaTheNotch.app/Contents/MacOS/CapacityNotchClaudeBridge -- /Users/you/line.sh", "refreshInterval": 60}}"#
    let outcome = try ClaudeStatusLineSetup.install(into: settings, bridge: bridge)
    try expect(outcome == .alreadyInstalled, "Nothing to do when the bridge already runs, got \(outcome)")
}

func noSettingsFileYetGetsOneWithTheStatusLineAlone() throws {
    let (text, previous) = try installed(nil)
    let line = try statusLine(text)
    try expect(previous == nil && line["command"] as? String == bridge, "A new file with the status line, got \(text)")
    let (empty, _) = try installed("{}")
    let emptyLine = try statusLine(empty)
    try expect(emptyLine["command"] as? String == bridge, "An empty object takes it too, got \(empty)")
}

func turningOffPutsBackWhatWasThere() throws {
    let original = #"{"statusLine": {"type": "command", "command": "~/line.sh"}, "model": "opus"}"#
    let (withBridge, previous) = try installed(original)
    let restored = try ClaudeStatusLineSetup.uninstall(from: withBridge, previous: previous)
    try expect(restored == original, "The person's own line comes back exactly, got \(restored ?? "nil")")

    let none = "{\n  \"model\": \"opus\"\n}\n"
    let (added, nothing) = try installed(none)
    let removed = try ClaudeStatusLineSetup.uninstall(from: added, previous: nothing)
    try expect(removed == none, "A line it added goes, leaving the file as it was, got \(removed ?? "nil")")

    let changedSince = try ClaudeStatusLineSetup.uninstall(from: #"{"statusLine": {"type": "command", "command": "~/other.sh"}}"#, previous: nil)
    try expect(changedSince == nil, "A status line the person changed since is not touched")
}

func aFileThatIsNotJSONIsNotTouched() throws {
    for broken in ["{ \"model\": ", "[1, 2]", "// comment\n{}"] {
        do {
            _ = try ClaudeStatusLineSetup.install(into: broken, bridge: bridge)
            throw TestFailure(description: "\(broken) should be refused")
        } catch ClaudeStatusLineSetup.SetupError.notASettingsObject {}
    }
}

func whatTheStatusLineReplacedIsRememberedToPutBack() throws {
    let suite = "status-line-\(UUID())"
    guard let defaults = UserDefaults(suiteName: suite) else { throw TestFailure(description: "No defaults") }
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = Preferences(defaults: defaults)
    try expect(!preferences.claudeStatusLineAsked, "Not asked until asked")
    try expect(preferences.claudeStatusLineSetUp == nil, "Nothing set up by CapaTheNotch")
    preferences.claudeStatusLineAsked = true
    preferences.claudeStatusLineSetUp = .init(previous: #"{"type": "command", "command": "~/line.sh"}"#)
    let again = Preferences(defaults: defaults)
    try expect(again.claudeStatusLineAsked, "The answer is kept")
    try expect(again.claudeStatusLineSetUp?.previous == #"{"type": "command", "command": "~/line.sh"}"#, "and what to put back")
    again.claudeStatusLineSetUp = .init(previous: nil)
    try expect(Preferences(defaults: defaults).claudeStatusLineSetUp == .init(previous: nil), "Set up over nothing is still set up")
    again.claudeStatusLineSetUp = nil
    try expect(Preferences(defaults: defaults).claudeStatusLineSetUp == nil, "and forgotten once put back")
}

func aBridgeFromTheOldBundleIsPointedAtThisOne() throws {
    let old = #"{"statusLine": {"type": "command", "command": "/Applications/CapacityNotch.app/Contents/MacOS/CapacityNotchClaudeBridge -- /Users/you/line.sh"}}"#
    try expect(!ClaudeStatusLineSetup.isInstalled(old, bridge: bridge), "The old bundle's bridge is not this one")
    let (text, previous) = try installed(old)
    let line = try statusLine(text)
    try expect(line["command"] as? String == bridge + " -- /Users/you/line.sh", "Only the bridge's path changes, got \(line["command"] ?? "nil")")
    try expect(previous != nil, "and the old line is kept to put back")
}

func aFileWithTwoStatusLinesIsNotTouched() throws {
    let twice = #"{"statusLine": {"type": "command", "command": "a"}, "statusLine": {"type": "command", "command": "b"}}"#
    do {
        _ = try ClaudeStatusLineSetup.install(into: twice, bridge: bridge)
        throw TestFailure(description: "Two status lines leave it unclear which Claude Code runs")
    } catch ClaudeStatusLineSetup.SetupError.notASettingsObject {}
}
