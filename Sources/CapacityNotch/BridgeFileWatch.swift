import Foundation

/// Calls back when a file is written anew. The bridge writes atomically — a
/// new file renamed over the old — so the folder is watched, not the file,
/// and a change is the file's modification time moving on; the folder's
/// other files are written too, and are let pass.
final class BridgeFileWatch {
    private let source: DispatchSourceFileSystemObject
    private let file: URL
    private var lastModified: Date?
    private var pending: DispatchWorkItem?

    init?(file: URL, changed: @escaping @MainActor () -> Void) {
        let folder = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        self.file = file
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        lastModified = Self.modified(file)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // A burst of writes is one change; read once it has settled.
            self.pending?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let now = Self.modified(self.file)
                guard now != self.lastModified else { return }
                self.lastModified = now
                MainActor.assumeIsolated { changed() }
            }
            self.pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    deinit {
        pending?.cancel()
        source.cancel()
    }

    /// Read afresh each time: a URL keeps the values it was asked for once.
    private static func modified(_ file: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }
}
