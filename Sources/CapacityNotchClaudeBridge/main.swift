import CapacityNotchCore
import Foundation

let input = FileHandle.standardInput.readDataToEndOfFile()

/// Leaves a trace when a reading cannot be taken, so the absence of Capacity
/// can be told apart from the absence of the bridge itself.
///
/// It records only the names of the top-level fields it was given, never a
/// value, so no session data, prompt, or path is written down.
func recordUnreadable(_ reason: String, from data: Data) {
    let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    let names = object.map { $0.keys.sorted() } ?? []
    let note: [String: Any] = [
        "at": Date().timeIntervalSince1970,
        "reason": reason,
        "top_level_field_names": names,
        "input_bytes": data.count,
    ]

    let url = ClaudeStatusLineBridge.defaultSnapshotURL
        .deletingLastPathComponent()
        .appendingPathComponent("claude-bridge-last-unreadable.json")
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    guard let encoded = try? JSONSerialization.data(
        withJSONObject: note,
        options: [.sortedKeys, .prettyPrinted]
    ) else { return }
    try? encoded.write(to: url, options: .atomic)
}

do {
    try ClaudeStatusLineBridge.publish(
        statusLineJSON: input,
        to: ClaudeStatusLineBridge.defaultSnapshotURL
    )
} catch ClaudeStatusLineBridgeError.missingRateLimits {
    // Claude Code omits rate_limits before the first API response. Preserve
    // the last useful snapshot and keep the status line working.
    recordUnreadable("missingRateLimits", from: input)
} catch {
    recordUnreadable("\(error)", from: input)
    FileHandle.standardError.write(Data("CapaTheNotch bridge: \(error)\n".utf8))
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--", arguments.count > 1 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: arguments[1])
    process.arguments = Array(arguments.dropFirst(2))
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError

    let forwardedInput = Pipe()
    process.standardInput = forwardedInput

    do {
        try process.run()
        forwardedInput.fileHandleForWriting.write(input)
        try forwardedInput.fileHandleForWriting.close()
        process.waitUntilExit()
        exit(process.terminationStatus)
    } catch {
        FileHandle.standardError.write(Data("CapaTheNotch passthrough: \(error)\n".utf8))
        exit(1)
    }
}
