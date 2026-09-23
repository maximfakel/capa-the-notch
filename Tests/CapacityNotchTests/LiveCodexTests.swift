import CapacityNotchCore
import Foundation

/// Drives a real `codex app-server`. Skipped unless CAPACITY_NOTCH_LIVE_CODEX=1,
/// because it needs Codex installed and signed in on this machine.
func liveCodexPublishesFreshCapacity() async throws {
    guard ProcessInfo.processInfo.environment["CAPACITY_NOTCH_LIVE_CODEX"] == "1" else {
        print("  (skipped: set CAPACITY_NOTCH_LIVE_CODEX=1 to read a live Codex)")
        return
    }

    guard let executable = CodexInstallation.locate() else {
        throw TestFailure(description: "No Codex runtime found on this machine")
    }
    print("  (reading live Codex at \(executable))")

    let service = CodexCapacityService(clientInfo: CodexClientInfo(version: "0.1.0"))
    var iterator = service.snapshots.makeAsyncIterator()
    await service.connect()

    guard let snapshot = await iterator.next() else {
        throw TestFailure(description: "A live Codex published no Capacity Snapshot")
    }

    guard case .fresh = snapshot.connectionState else {
        throw TestFailure(
            description: "A live, signed-in Codex should report Fresh Capacity, got \(snapshot.connectionState)"
        )
    }
    try expect(
        !snapshot.windows.isEmpty,
        "A live Codex should report at least one Quota Window"
    )
    for window in snapshot.windows {
        print("  \(window.label): \(Int(window.remainingPercentage))% left")
    }

    await service.disconnect()
    let stillConnected = await service.isConnected
    try expect(stillConnected == false, "Disconnecting should leave no connection")
}
