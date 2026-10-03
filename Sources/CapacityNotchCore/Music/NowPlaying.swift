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
            player: text("parentApplicationBundleIdentifier") ?? text("bundleIdentifier"),
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
///
/// Nothing loaded is believed only once it has lasted two seconds. Some
/// players — Yandex Music, between tracks — report nothing and then the next
/// track within the same second; taken at its word, that nothing would close
/// the expanded surface's page and send it back to Capacity.
///
/// Once a track has gone — its player quit, its tab closed — the last one
/// is remembered, with when it went, for the music page to show until
/// another plays. Only switching the Module off forgets it.
///
/// A new track arrives without its artwork, which follows a moment later. For
/// up to the same two seconds the last cover stays in its place, so the
/// player's icon does not blink in between.
public struct MusicPresence: Equatable, Sendable {
    public static let pauseLinger: TimeInterval = 10
    public static let vanishGrace: TimeInterval = 2

    private var current: NowPlaying?
    private var pausedAt: Date?
    /// When nothing was reported, while the track before it is still held.
    private var vanishedAt: Date?
    /// The last track's cover, held for a new one that has none yet.
    private var heldArtwork: Data?
    private var heldSince: Date?
    /// The last track loaded, and when it stopped being loaded.
    private var memory: NowPlaying?
    private var memoryEndedAt: Date?

    public init() {}

    public mutating func observe(_ reading: NowPlayingReading, at moment: Date) {
        // A nothing that outlasted its grace was believed: what came before
        // it is gone, and lends nothing to what comes next.
        if let vanishedAt, moment.timeIntervalSince(vanishedAt) >= Self.vanishGrace { lose() }
        if case let .item(item) = reading {
            holdArtwork(for: item, at: moment)
            remember(item)
        } else if memory != nil, memoryEndedAt == nil {
            memoryEndedAt = moment
        }
        switch reading {
        case .nothing:
            if current != nil, vanishedAt == nil { vanishedAt = moment }
        case let .item(item) where item.isPlaying:
            current = item
            pausedAt = nil
            vanishedAt = nil
        case let .item(item):
            let wasPlaying = current?.isPlaying == true && vanishedAt == nil
            let pauseStarted = wasPlaying ? moment : (pausedAt ?? .distantPast)
            current = item
            pausedAt = pauseStarted
            vanishedAt = nil
        }
    }

    /// The track loaded, playing or paused, however long ago it paused. The
    /// strip's row lingers only ten seconds; the expanded surface's page stays
    /// as long as there is a track.
    public func loaded(at now: Date) -> NowPlaying? {
        if let vanishedAt, now.timeIntervalSince(vanishedAt) >= Self.vanishGrace { return nil }
        guard let current else { return nil }
        if let heldArtwork, let heldSince, now.timeIntervalSince(heldSince) < Self.vanishGrace {
            return current.with(artwork: heldArtwork)
        }
        return current
    }

    /// Something is held for its grace — a track reported gone, or a cover
    /// waiting for its replacement: whoever shows this must look again once
    /// the grace is over.
    public func isHolding(at now: Date) -> Bool {
        guard current != nil else { return false }
        let since = [vanishedAt, heldSince].compactMap { $0 }
        return since.contains { now.timeIntervalSince($0) < Self.vanishGrace }
    }

    private mutating func holdArtwork(for item: NowPlaying, at moment: Date) {
        if let since = heldSince, moment.timeIntervalSince(since) >= Self.vanishGrace {
            heldArtwork = nil
            heldSince = nil
        }
        if item.artwork != nil {
            heldArtwork = nil
            heldSince = nil
        } else if heldSince == nil, let last = current?.artwork, current?.title != item.title || current?.artist != item.artist {
            heldArtwork = last
            heldSince = moment
        } else if heldSince == nil {
            heldArtwork = nil
        }
    }

    /// The reader failed or stopped: nothing is known to be loaded any more.
    public mutating func lose(at moment: Date = Date()) {
        if memory != nil, memoryEndedAt == nil { memoryEndedAt = moment }
        current = nil
        pausedAt = nil
        vanishedAt = nil
        heldArtwork = nil
        heldSince = nil
    }

    /// The Module switched off: nothing is kept.
    public mutating func forget() {
        lose()
        memory = nil
        memoryEndedAt = nil
    }

    /// The last track, while nothing is loaded.
    public func remembered(at now: Date) -> RememberedTrack? {
        guard loaded(at: now) == nil, let memory, let memoryEndedAt else { return nil }
        return RememberedTrack(track: memory.with(isPlaying: false), endedAt: memoryEndedAt)
    }

    private mutating func remember(_ item: NowPlaying) {
        let artwork = item.artwork ?? (memory?.title == item.title ? memory?.artwork : nil)
        memory = item.with(artwork: artwork)
        memoryEndedAt = nil
    }

    public func shown(at now: Date) -> NowPlaying? {
        guard let current = loaded(at: now) else { return nil }
        if current.isPlaying { return current }
        guard let pausedAt, now.timeIntervalSince(pausedAt) < Self.pauseLinger else { return nil }
        return current
    }
}

/// The last track loaded, after it has gone.
public struct RememberedTrack: Equatable, Sendable {
    public let track: NowPlaying
    /// When it stopped being loaded.
    public let endedAt: Date

    public init(track: NowPlaying, endedAt: Date) {
        self.track = track
        self.endedAt = endedAt
    }
}

extension NowPlaying {
    func with(artwork: Data?) -> NowPlaying {
        NowPlaying(
            title: title, artist: artist, album: album, player: player, isPlaying: isPlaying,
            duration: duration, elapsed: elapsed, elapsedAt: elapsedAt, rate: rate, artwork: artwork
        )
    }

    func with(isPlaying: Bool) -> NowPlaying {
        NowPlaying(
            title: title, artist: artist, album: album, player: player, isPlaying: isPlaying,
            duration: duration, elapsed: elapsed, elapsedAt: elapsedAt, rate: rate, artwork: artwork
        )
    }
}
