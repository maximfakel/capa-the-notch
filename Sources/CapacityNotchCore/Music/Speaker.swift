import Foundation

/// The Mac's output volume as the music page shows it: a level and whether
/// it is muted, read from the output device and written back to it.
public struct Speaker: Equatable, Sendable {
    /// From 0 to 1, as Core Audio keeps it. Muting leaves it where it was.
    public var level: Double
    public var isMuted: Bool

    public init(level: Double, isMuted: Bool = false) {
        self.level = min(max(level, 0), 1)
        self.isMuted = isMuted
    }

    /// Muted reads as silent, as Control Center shows it: the bar empties
    /// and the level comes back with the sound.
    public var shownLevel: Double { isMuted ? 0 : level }

    /// The SF Symbol for the speaker: struck through when nothing is heard,
    /// one wave low, two otherwise.
    public var symbol: String {
        if shownLevel <= 0 { return "speaker.slash.fill" }
        return shownLevel < 1.0 / 3 ? "speaker.wave.1.fill" : "speaker.wave.2.fill"
    }
}
