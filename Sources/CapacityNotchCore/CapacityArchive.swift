import Foundation

/// Keeps the last Capacity each Provider reported, so a restart opens on the
/// numbers the person last saw rather than on nothing.
///
/// What comes back is Stale Capacity by definition: it was true when it was
/// written and nothing has confirmed it since. The archive says so rather than
/// leaving the surface to guess.
public struct CapacityArchive: Sendable {
    public static let schemaVersion = 1

    public let fileURL: URL

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CapacityNotch", isDirectory: true)
            .appendingPathComponent("capacity-archive.json")
    }

    public init(fileURL: URL = CapacityArchive.defaultURL) {
        self.fileURL = fileURL
    }

    /// Writes the Providers worth remembering. A Provider with no Quota Window
    /// is not worth remembering: it would come back as a Stale nothing.
    public func save(_ snapshots: [CapacitySnapshot]) {
        let stored = snapshots
            .filter { !$0.windows.isEmpty }
            .map(StoredSnapshot.init)
        guard !stored.isEmpty else { return }

        let archive = StoredArchive(schemaVersion: Self.schemaVersion, snapshots: stored)
        guard let data = try? JSONEncoder().encode(archive) else { return }

        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Everything remembered, as Stale Capacity. Empty when there is nothing,
    /// when the file cannot be read, or when it was written by a version that
    /// no longer applies.
    public func load() -> [CapacitySnapshot] {
        guard
            let data = try? Data(contentsOf: fileURL),
            let archive = try? JSONDecoder().decode(StoredArchive.self, from: data),
            archive.schemaVersion == Self.schemaVersion
        else { return [] }

        return archive.snapshots.compactMap { $0.snapshot(reason: .staleFromArchive) }
    }

    private struct StoredArchive: Codable {
        let schemaVersion: Int
        let snapshots: [StoredSnapshot]
    }

    private struct StoredSnapshot: Codable {
        let provider: String
        let capturedAt: Double
        let windows: [StoredWindow]

        init(_ snapshot: CapacitySnapshot) {
            provider = snapshot.provider.rawValue
            capturedAt = snapshot.capturedAt.timeIntervalSince1970
            windows = snapshot.windows.map(StoredWindow.init)
        }

        func snapshot(reason: CapacityStatusReason) -> CapacitySnapshot? {
            guard let provider = Provider(rawValue: provider) else { return nil }
            return CapacitySnapshot(
                provider: provider,
                capturedAt: Date(timeIntervalSince1970: capturedAt),
                windows: windows.map(\.window),
                connectionState: .stale,
                statusReason: reason
            )
        }
    }

    private struct StoredWindow: Codable {
        let id: String
        let label: String
        let durationMinutes: Int?
        let usedFraction: Double
        let resetsAt: Double?

        init(_ window: QuotaWindow) {
            id = window.id
            label = window.label
            durationMinutes = window.durationMinutes
            usedFraction = window.usedFraction
            resetsAt = window.resetsAt?.timeIntervalSince1970
        }

        var window: QuotaWindow {
            QuotaWindow(
                id: id,
                label: label,
                durationMinutes: durationMinutes,
                usedFraction: usedFraction,
                resetsAt: resetsAt.map(Date.init(timeIntervalSince1970:))
            )
        }
    }
}
