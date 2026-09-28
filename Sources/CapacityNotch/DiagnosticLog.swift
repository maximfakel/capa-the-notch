import CapacityNotchCore
import Foundation
import Security

/// Where a Provider's own output is kept, when the person has asked for it.
///
/// Off unless asked: a diagnostic nobody requested is a log nobody consented
/// to. Ticket 10 decides what may go in one; this only decides where it lives
/// and whether it is being written at all.
enum DiagnosticLog {
    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CapacityNotch", isDirectory: true)
            .appendingPathComponent("capacity-notch.log")
    }

    static func prepare() -> URL? {
        let url = fileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        return url
    }

    private static let queue = DispatchQueue(label: "CapacityNotch.DiagnosticLog")

    /// The application's own line, beside the Provider's output, and only
    /// while the log is on. Written in order, off the caller's thread.
    static func record(_ event: DiagnosticEvent) {
        guard Preferences().keepsDiagnosticLog else { return }
        let line = event.entry(at: Date()) + "\n"
        queue.async {
            guard let url = prepare(), let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }

    /// Whether this build is signed so macOS could ever ask for the microphone.
    /// Under the Hardened Runtime, without the entitlement, it never asks.
    static var microphoneEntitled: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, "com.apple.security.device.audio-input" as CFString, nil) as? Bool == true
    }
}
