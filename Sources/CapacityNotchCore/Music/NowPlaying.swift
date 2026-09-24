import Foundation

/// What the system reports as playing, from whichever application plays it.
public struct NowPlaying: Equatable, Sendable {
    public let title: String
    public let artist: String?
    public let album: String?
    /// The bundle identifier of the application playing it, when known.
    public let player: String?
    public let isPlaying: Bool
    public let duration: TimeInterval?
    /// The position `elapsedAt`; it moves on from there at `rate`.
    public let elapsed: TimeInterval?
    public let elapsedAt: Date?
    public let rate: Double?
    public let artwork: Data?

    public init(
        title: String,
        artist: String?,
        album: String? = nil,
        player: String?,
        isPlaying: Bool,
        duration: TimeInterval? = nil,
        elapsed: TimeInterval? = nil,
        elapsedAt: Date? = nil,
        rate: Double? = nil,
        artwork: Data? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.player = player
        self.isPlaying = isPlaying
        self.duration = duration
        self.elapsed = elapsed
        self.elapsedAt = elapsedAt
        self.rate = rate
        self.artwork = artwork
    }
}

/// One observation of Now Playing: a track, or nothing loaded at all.
public enum NowPlayingReading: Equatable, Sendable {
    case nothing
    case item(NowPlaying)
}

/// Follows mediaremote-adapter's `stream`, one line at a time.
///
/// Each line is `{"type":"data","diff":…,"payload":{…}}`. A full payload is
/// the whole state, and an empty one is nothing playing; a diff carries only
/// what changed, with `null` for a key that went away — the artwork, for one,
/// arrives on its own after the track. A line the adapter did not write is
/// not a reading: it changes nothing, and is never shown as nothing playing.
///
/// The adapter also sends a full payload without the artwork and the artwork
/// again as a diff, for a track it already reported. So a full payload for the
/// same content item keeps the artwork it had, rather than blinking it out;
/// a new track does not inherit the last one's.
public struct NowPlayingStream {
    private var fields: [String: Any] = [:]

    public init() {}

    public mutating func apply(_ line: String) -> NowPlayingReading? {
        guard
            let data = line.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["type"] as? String == "data",
            let diff = object["diff"] as? Bool,
            let payload = object["payload"] as? [String: Any]
        else { return nil }

        if diff {
            for (key, value) in payload {
                if value is NSNull { fields[key] = nil } else { fields[key] = value }
            }
        } else {
            var replaced = payload.filter { !($0.value is NSNull) }
            let sameItem = replaced["contentItemIdentifier"] as? String != nil
                && replaced["contentItemIdentifier"] as? String == fields["contentItemIdentifier"] as? String
            if sameItem, replaced["artworkData"] == nil {
                replaced["artworkData"] = fields["artworkData"]
                replaced["artworkMimeType"] = fields["artworkMimeType"]
            }
            fields = replaced
        }
        return reading
    }

    private var reading: NowPlayingReading {
        guard let title = fields["title"] as? String, !title.isEmpty else { return .nothing }

        func text(_ key: String) -> String? {
            (fields[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        func number(_ key: String) -> Double? {
            (fields[key] as? NSNumber)?.doubleValue
        }

        return .item(NowPlaying(
            title: title,
            artist: text("artist"),
            album: text("album"),
            player: text("bundleIdentifier"),
            isPlaying: fields["playing"] as? Bool ?? false,
            duration: number("duration"),
            elapsed: number("elapsedTime"),
            elapsedAt: text("timestamp").flatMap { ISO8601DateFormatter().date(from: $0) },
            rate: number("playbackRate"),
            artwork: text("artworkData").flatMap { Data(base64Encoded: $0) }
        ))
    }
}

/// Whether the compact strip shows its music row, and with what.
///
/// Playing, it shows. Paused, it stays ten seconds — long enough to press play
/// again — and the ten seconds run from the moment of the pause, not from the
/// last time the pause was reported. A track found already paused was never
/// seen playing, so there is no pause to linger on. Nothing loaded, or a
/// reader that failed, shows nothing: a stale track is worse than none.
public struct MusicPresence: Equatable, Sendable {
    public static let pauseLinger: TimeInterval = 10

    private var current: NowPlaying?
    private var pausedAt: Date?

    public init() {}

    public mutating func observe(_ reading: NowPlayingReading, at moment: Date) {
        switch reading {
        case .nothing:
            current = nil
            pausedAt = nil
        case let .item(item) where item.isPlaying:
            current = item
            pausedAt = nil
        case let .item(item):
            let wasPlaying = current?.isPlaying == true
            let pauseStarted = wasPlaying ? moment : (pausedAt ?? .distantPast)
            current = item
            pausedAt = pauseStarted
        }
    }

    /// The track loaded, playing or paused, however long ago it paused. The
    /// strip's row lingers only ten seconds; the expanded surface's page stays
    /// as long as there is a track.
    public var loaded: NowPlaying? { current }

    public mutating func lose() {
        current = nil
        pausedAt = nil
    }

    public func shown(at now: Date) -> NowPlaying? {
        guard let current else { return nil }
        if current.isPlaying { return current }
        guard let pausedAt, now.timeIntervalSince(pausedAt) < Self.pauseLinger else { return nil }
        return current
    }
}
