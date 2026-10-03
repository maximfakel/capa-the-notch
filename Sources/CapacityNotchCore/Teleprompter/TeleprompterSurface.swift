import Foundation

/// How the Teleprompter changes the rest of the surface while it shows.
public enum TeleprompterSurface {
    /// What sits under the compact strip.
    public enum CompactRow: Equatable, Sendable {
        case none
        case music
        case teleprompter
    }

    /// The Teleprompter Row takes the music row's place — nearness to the
    /// camera is the point — and shows over a fullscreen application too,
    /// where music does not: calls are often fullscreen.
    public static func compactRow(teleprompterShowing: Bool, musicShown: Bool, fullscreen: Bool) -> CompactRow {
        if teleprompterShowing { return .teleprompter }
        if musicShown, !fullscreen { return .music }
        return .none
    }

    /// A Script on screen is never shared, whatever "Appear in screen
    /// sharing and recordings" says: a Script the audience can read is no
    /// help to the one reading it. Nor is the surface while the Shelf holds a
    /// Clipping: that switch is there to show Capacity on a call, not the
    /// token copied a minute ago (ADR 0005).
    public static func excludedFromCapture(sharingAllowed: Bool, teleprompterShowing: Bool, holdsClippings: Bool = false) -> Bool {
        teleprompterShowing || holdsClippings || !sharingAllowed
    }

    /// While the Script runs a pointer passing over the notch does not open
    /// the surface over it; a click still does.
    public static func hoverOpens(teleprompter: TeleprompterPlayback.State) -> Bool {
        teleprompter != .running
    }
}
