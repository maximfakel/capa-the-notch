import CapacityNotchCore
import Foundation

/// Runs the real `claude /usage`. Skipped unless CAPACITY_NOTCH_LIVE_CLAUDE=1,
/// because it needs Claude Code installed and signed in on this machine.
func liveClaudeUsageReportsCapacity() throws {
    guard ProcessInfo.processInfo.environment["CAPACITY_NOTCH_LIVE_CLAUDE"] == "1" else {
        print("  (skipped: set CAPACITY_NOTCH_LIVE_CLAUDE=1 to ask a live Claude Code)")
        return
    }

    guard let executable = ClaudeUsageCommandSource.locate() else {
        throw TestFailure(description: "No Claude Code binary found on this machine")
    }
    print("  (asking \(executable))")

    let started = Date()
    let reading = try ClaudeUsageCommandSource().read()
    let elapsed = Date().timeIntervalSince(started)

    try expect(
        !reading.windows.isEmpty,
        "A signed-in Claude Code should report at least one Quota Window"
    )
    for window in reading.windows {
        print("  \(window.label): \(Int(window.remainingPercentage))% left")
    }
    print(String(format: "  (%.1fs)", elapsed))
}
