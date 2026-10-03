import Foundation

/// What the Music Module says when macOS stops telling it what is playing.
///
/// It reads through a private interface (ADR 0004), which Apple can close in
/// any update. When that happens the strip shows nothing — there is no track to
/// show — so the failure is said where the person will look for it.
public enum MusicModule {
    /// Under 32 characters, so `Redaction` leaves it in the report.
    public static let unreadableCode = "music-unreadable"
    public static let unreadableGuidance = "macOS no longer lets CapaTheNotch read what's playing."
}

/// A control, as the arguments mediaremote-adapter takes for it: `send` with
/// MediaRemote's command id, `seek` with a position in microseconds.
public enum MusicCommand: Equatable, Sendable {
    case previous
    case togglePlayPause
    case next
    case seek(to: TimeInterval)

    public var arguments: [String] {
        switch self {
        case .previous: ["send", "5"]
        case .togglePlayPause: ["send", "2"]
        case .next: ["send", "4"]
        case let .seek(seconds): ["seek", String(Int64((max(seconds, 0) * 1_000_000).rounded()))]
        }
    }
}

public extension NowPlaying {
    /// Where in the track it is now: the reported position, moved on at the
    /// reported rate, and never outside the track.
    func position(at now: Date) -> TimeInterval? {
        guard let elapsed else { return nil }
        let moved = elapsedAt.map { now.timeIntervalSince($0) * (rate ?? 0) } ?? 0
        let position = max(elapsed + moved, 0)
        return duration.map { min(position, $0) } ?? position
    }
}
