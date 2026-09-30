import CapacityNotchCore
import Foundation

/// What the adapter's `stream` prints, shaped as it prints it.
private let fullLine = #"{"type":"data","diff":false,"payload":{"title":"Mad Technology","artist":"CZARFACE","album":"Czarface Meets Metal Face","bundleIdentifier":"com.google.Chrome","playing":true,"duration":224.0,"elapsedTime":46.0,"playbackRate":1,"timestamp":"2026-09-24T02:00:00Z"}}"#

func aFullLineFromTheAdapterSaysWhatIsPlaying() throws {
    var stream = NowPlayingStream()
    guard case let .item(item)? = stream.apply(fullLine) else {
        throw TestFailure(description: "A full payload is a track")
    }
    try expect(item.title == "Mad Technology" && item.artist == "CZARFACE", "Title and artist, got \(item)")
    try expect(item.player == "com.google.Chrome" && item.isPlaying, "Who plays it, and that it plays")
    try expect(item.duration == 224 && item.elapsed == 46 && item.rate == 1, "Where in the track it is")
    try expect(
        item.elapsedAt == ISO8601DateFormatter().date(from: "2026-09-24T02:00:00Z"),
        "And as of when, since the position moves on from there"
    )

    try expect(
        stream.apply(#"{"type":"data","diff":false,"payload":{}}"#) == .nothing,
        "An empty full payload is nothing playing"
    )
}

func aDiffLineUpdatesTheLastFullOne() throws {
    var stream = NowPlayingStream()
    _ = stream.apply(fullLine)

    let artwork = Data("artwork".utf8).base64EncodedString()
    guard case let .item(withArtwork)? = stream.apply(
        #"{"type":"data","diff":true,"payload":{"artworkData":"\#(artwork)","artworkMimeType":"image/jpeg"}}"#
    ) else { throw TestFailure(description: "A diff keeps the track it updates") }
    try expect(withArtwork.title == "Mad Technology", "The artwork arrives on its own and the track stays")
    try expect(withArtwork.artwork == Data("artwork".utf8), "The artwork is the bytes the adapter sent")

    guard case let .item(paused)? = stream.apply(
        #"{"type":"data","diff":true,"payload":{"playing":false,"artist":null}}"#
    ) else { throw TestFailure(description: "A diff keeps the track it updates") }
    try expect(!paused.isPlaying, "A diff can pause it")
    try expect(paused.artist == nil, "A key set to null is gone")
    try expect(paused.artwork == Data("artwork".utf8), "And what the diff does not mention is kept")
}

func theArtworkOutlivesAFullLineForTheSameTrackOnly() throws {
    // What the adapter really does: a full payload without the artwork, then
    // the artwork as a diff — and again, for the same track, a while later.
    let artwork = Data("cover".utf8).base64EncodedString()
    func full(_ id: String, _ title: String) -> String {
        #"{"type":"data","diff":false,"payload":{"title":"\#(title)","contentItemIdentifier":"\#(id)","playing":true}}"#
    }
    var stream = NowPlayingStream()
    _ = stream.apply(full("a", "Mad Technology"))
    _ = stream.apply(#"{"type":"data","diff":true,"payload":{"artworkData":"\#(artwork)"}}"#)

    guard case let .item(same)? = stream.apply(full("a", "Mad Technology")) else {
        throw TestFailure(description: "A full payload is a track")
    }
    try expect(same.artwork == Data("cover".utf8), "The same track keeps its artwork, rather than blinking")

    guard case let .item(next)? = stream.apply(full("b", "Something Else")) else {
        throw TestFailure(description: "A full payload is a track")
    }
    try expect(next.artwork == nil, "A new track does not wear the last one's artwork")
}

func aMusicModuleThatCannotReadSaysSoInTheReport() throws {
    let code = MusicModule.unreadableCode
    try expect(code == "music-unreadable", "The report's word for it, got \(code)")
    try expect(Redaction.scrub(code) == code, "It survives the report's scrubbing")
    try expect(!MusicModule.unreadableGuidance.isEmpty, "And Settings has a sentence for it")
}

func eachControlIsTheCommandTheAdapterExpects() throws {
    // From the adapter's README: send takes MediaRemote's command ids, seek a
    // position in microseconds.
    try expect(MusicCommand.previous.arguments == ["send", "5"], "Previous is kMRPreviousTrack")
    try expect(MusicCommand.togglePlayPause.arguments == ["send", "2"], "Play/pause is kMRTogglePlayPause")
    try expect(MusicCommand.next.arguments == ["send", "4"], "Next is kMRNextTrack")
    try expect(
        MusicCommand.seek(to: 46.5).arguments == ["seek", "46500000"],
        "A position in seconds is sent in microseconds, got \(MusicCommand.seek(to: 46.5).arguments)"
    )
    try expect(MusicCommand.seek(to: -3).arguments == ["seek", "0"], "Never before the start")
}

func thePositionMovesOnFromWhenItWasReported() throws {
    let reportedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let playing = NowPlaying(
        title: "Mad Technology", artist: nil, player: nil, isPlaying: true,
        duration: 224, elapsed: 46, elapsedAt: reportedAt, rate: 1
    )
    try expect(playing.position(at: reportedAt.addingTimeInterval(10)) == 56, "Ten seconds on, at normal speed")
    try expect(playing.position(at: reportedAt.addingTimeInterval(500)) == 224, "Never past the end")

    let paused = NowPlaying(
        title: "Mad Technology", artist: nil, player: nil, isPlaying: false,
        duration: 224, elapsed: 46, elapsedAt: reportedAt, rate: 0
    )
    try expect(paused.position(at: reportedAt.addingTimeInterval(10)) == 46, "Paused, it stays where it stopped")

    let unknown = NowPlaying(title: "Live", artist: nil, player: nil, isPlaying: true)
    try expect(unknown.position(at: reportedAt) == nil, "Without a reported position there is none to show")
}

func aLineTheAdapterDidNotWriteIsNotAReading() throws {
    var stream = NowPlayingStream()
    _ = stream.apply(fullLine)
    for line in ["", "not json", #"{"type":"data","payload":{}}"#, #"{"type":"other","diff":false,"payload":{}}"#, "[1,2,3]"] {
        try expect(stream.apply(line) == nil, "\"\(line)\" is not a reading, and must not read as nothing playing")
    }
    guard case let .item(item)? = stream.apply(#"{"type":"data","diff":true,"payload":{}}"#) else {
        throw TestFailure(description: "The track survives lines that were not readings")
    }
    try expect(item.title == "Mad Technology", "Lines that were not readings changed nothing")
}

private let heardAt = Date(timeIntervalSince1970: 1_800_000_000)
private let track = NowPlaying(title: "Mad Technology", artist: "CZARFACE", player: "com.google.Chrome", isPlaying: true)
private let paused = NowPlaying(title: "Mad Technology", artist: "CZARFACE", player: "com.google.Chrome", isPlaying: false)

func theRowShowsWhilePlayingAndLingersBrieflyOnPause() throws {
    var presence = MusicPresence()

    presence.observe(.item(track), at: heardAt)
    try expect(presence.shown(at: heardAt) == track, "Playing is shown")

    presence.observe(.item(paused), at: heardAt.addingTimeInterval(60))
    try expect(
        presence.shown(at: heardAt.addingTimeInterval(69)) == paused,
        "Paused, it stays long enough to press play again"
    )
    try expect(
        presence.shown(at: heardAt.addingTimeInterval(71)) == nil,
        "Then the strip collapses"
    )
    try expect(
        presence.loaded == paused,
        "But the track is still loaded, so the expanded surface keeps its page"
    )

    presence.observe(.item(track), at: heardAt.addingTimeInterval(80))
    try expect(presence.shown(at: heardAt.addingTimeInterval(80)) == track, "Playing again brings it back")

    presence.observe(.item(paused), at: heardAt.addingTimeInterval(90))
    presence.observe(.item(paused), at: heardAt.addingTimeInterval(95))
    try expect(
        presence.shown(at: heardAt.addingTimeInterval(101)) == nil,
        "The ten seconds run from the pause, not from the last time the pause was reported"
    )
}

func nothingPlayingOrUnreadableShowsNoRow() throws {
    var presence = MusicPresence()
    presence.observe(.item(paused), at: heardAt)
    try expect(
        presence.shown(at: heardAt) == nil,
        "A track found already paused was never seen playing, so there is no pause to linger on"
    )

    presence.observe(.item(track), at: heardAt)
    presence.observe(.nothing, at: heardAt.addingTimeInterval(1))
    try expect(presence.shown(at: heardAt.addingTimeInterval(1)) == nil, "Nothing loaded shows nothing")
    try expect(presence.loaded == nil, "And has no page")

    presence.observe(.item(track), at: heardAt.addingTimeInterval(2))
    presence.lose()
    try expect(
        presence.shown(at: heardAt.addingTimeInterval(2)) == nil,
        "A reader that failed shows nothing rather than the last track it saw"
    )
}

func theSpeakerIsStruckThroughWhenNothingIsHeard() throws {
    try expect(Speaker(level: 0.6).symbol == "speaker.wave.2.fill", "Two waves at an ordinary level")
    try expect(Speaker(level: 0.2).symbol == "speaker.wave.1.fill", "One wave when it is low")
    try expect(Speaker(level: 0).symbol == "speaker.slash.fill", "Struck through at zero")
    try expect(Speaker(level: 0.6, isMuted: true).symbol == "speaker.slash.fill", "And when muted, at any level")
}

func mutingEmptiesTheBarAndKeepsTheLevel() throws {
    let muted = Speaker(level: 0.6, isMuted: true)
    try expect(muted.shownLevel == 0, "The bar is empty while muted")
    try expect(muted.level == 0.6, "The level waits for the sound to come back")
    try expect(Speaker(level: 1.4).level == 1 && Speaker(level: -1).level == 0, "Never outside 0 to 1")
}
