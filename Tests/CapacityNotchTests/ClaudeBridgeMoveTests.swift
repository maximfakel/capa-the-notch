import CapacityNotchCore
import Foundation

private let bridge = "/Applications/CapaTheNotch.app/Contents/MacOS/CapacityNotchClaudeBridge"

func theBridgeMovesToTheRenamedApplication() throws {
    let settings = """
    {
      "model": "opus",
      "statusLine": {
        "type": "command",
        "command": "/Applications/CapacityNotch.app/Contents/MacOS/CapacityNotchClaudeBridge",
        "refreshInterval": 60
      }
    }
    """
    let moved = ClaudeBridgeMove.moved(settings, to: bridge)
    try expect(moved == settings.replacingOccurrences(of: "/Applications/CapacityNotch.app/", with: "/Applications/CapaTheNotch.app/"),
               "Only the bridge's path changes; the rest of the file stays as it was")
}

func aStatusLinePassedToTheBridgeIsKept() throws {
    let settings = #"{"statusLine":{"type":"command","command":"/Applications/CapacityNotch.app/Contents/MacOS/CapacityNotchClaudeBridge -- /Users/you/.claude/statusline.sh"}}"#
    try expect(
        ClaudeBridgeMove.moved(settings, to: bridge) == #"{"statusLine":{"type":"command","command":"\#(bridge) -- /Users/you/.claude/statusline.sh"}}"#,
        "The person's own status line after -- keeps running"
    )
}

func theWholeOldPathMovesWhereverTheBundleWas() throws {
    let settings = #"{"statusLine":{"command":"/Users/you/Applications/CapacityNotch.app/Contents/MacOS/CapacityNotchClaudeBridge"}}"#
    try expect(ClaudeBridgeMove.moved(settings, to: bridge) == #"{"statusLine":{"command":"\#(bridge)"}}"#,
               "A bundle in ~/Applications is replaced whole, not left with a stray prefix")
    let escaped = #"{"statusLine":{"command":"\/Applications\/CapacityNotch.app\/Contents\/MacOS\/CapacityNotchClaudeBridge"}}"#
    try expect(ClaudeBridgeMove.moved(escaped, to: bridge) == #"{"statusLine":{"command":"\#(bridge)"}}"#,
               "JSON's escaped slashes are still the old path")
}

func settingsWithoutTheOldBridgeAreLeftAlone() throws {
    try expect(ClaudeBridgeMove.moved(#"{"model":"opus"}"#, to: bridge) == nil, "No status line, nothing to move")
    try expect(ClaudeBridgeMove.moved(#"{"statusLine":{"command":"\#(bridge)"}}"#, to: bridge) == nil, "Already moved, nothing to move")
    try expect(ClaudeBridgeMove.moved(#"{"statusLine":{"command":"~/bin/my-statusline.sh"}}"#, to: bridge) == nil, "Someone else's status line is not ours")
}

func aBridgePathIsWrittenAsJSON() throws {
    let moved = ClaudeBridgeMove.moved(#"{"command":"/Applications/CapacityNotch.app/Contents/MacOS/CapacityNotchClaudeBridge"}"#, to: #"/Odd "place"/CapaTheNotch.app/Contents/MacOS/CapacityNotchClaudeBridge"#)
    try expect(moved == #"{"command":"/Odd \"place\"/CapaTheNotch.app/Contents/MacOS/CapacityNotchClaudeBridge"}"#, "Quotes in the new path are escaped, so the file stays JSON")
}

func theSettingsFileIsRewrittenInPlaceKeepingItsLinkAndPermissions() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("capacity-notch-bridge-move-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let claude = home.appendingPathComponent(".claude", isDirectory: true)
    let dotfiles = home.appendingPathComponent("dotfiles", isDirectory: true)
    try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)

    // settings.json is a link into a dotfiles folder, readable only by its owner.
    let real = dotfiles.appendingPathComponent("claude-settings.json")
    try Data(#"{"env":{"A":"secret"},"statusLine":{"command":"/Applications/CapacityNotch.app/Contents/MacOS/CapacityNotchClaudeBridge"}}"#.utf8).write(to: real)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: real.path)
    try FileManager.default.createSymbolicLink(at: claude.appendingPathComponent("settings.json"), withDestinationURL: real)
    try Data(#"{"permissions":{}}"#.utf8).write(to: claude.appendingPathComponent("settings.local.json"))

    let moved = try ClaudeBridgeMove.move(home: home, to: bridge)
    try expect(moved.map(\.lastPathComponent) == ["settings.json"], "Only the file that ran the old bridge is changed")
    let link = try FileManager.default.destinationOfSymbolicLink(atPath: claude.appendingPathComponent("settings.json").path)
    try expect(link == real.path, "The link stays a link; the file it points at is the one rewritten")
    let written = try String(contentsOf: real, encoding: .utf8)
    try expect(written == #"{"env":{"A":"secret"},"statusLine":{"command":"\#(bridge)"}}"#, "Everything else in it is kept")
    let permissions = try FileManager.default.attributesOfItem(atPath: real.path)[.posixPermissions] as? Int
    try expect(permissions == 0o600, "A file only its owner could read stays that way")
    let again = try ClaudeBridgeMove.move(home: home, to: bridge)
    try expect(again.isEmpty, "A second move finds nothing to move")
}
