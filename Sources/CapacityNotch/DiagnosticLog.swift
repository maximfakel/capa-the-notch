import Foundation

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
}
