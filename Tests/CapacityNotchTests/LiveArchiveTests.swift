import CapacityNotchCore
import Foundation

/// Reads the archive this machine's CapaTheNotch actually wrote. Skipped
/// unless CAPACITY_NOTCH_LIVE_ARCHIVE=1.
func liveArchiveReadsBackWhatTheAppWrote() throws {
    guard ProcessInfo.processInfo.environment["CAPACITY_NOTCH_LIVE_ARCHIVE"] == "1" else {
        print("  (skipped: set CAPACITY_NOTCH_LIVE_ARCHIVE=1 to read this machine's archive)")
        return
    }

    let archive = CapacityArchive()
    let restored = archive.load()
    guard !restored.isEmpty else {
        throw TestFailure(description: "No archive at \(archive.fileURL.path)")
    }

    for snapshot in restored {
        try expect(
            snapshot.connectionState == .stale,
            "Everything read back is Stale Capacity, got \(snapshot.connectionState)"
        )
        let windows = snapshot.windows
            .map { "\($0.label) \(Int($0.remainingPercentage))% left" }
            .joined(separator: ", ")
        print("  \(snapshot.provider.rawValue): \(windows)")
    }
}
