import Foundation

/// How Kapa moves, as plain functions of time: each movement is a pose at a
/// moment, so it can be tested at that moment, and an interrupted one picks
/// up from wherever it was. Coucou writes its greeting and its drop scene the
/// same way (docs/research/coucou-character.md §1.5); the numbers are Kapa's.
public enum KapaMotion {
    // MARK: Following a target

    /// Moves `value` toward `target` the same distance per second at any frame
    /// rate: after one second, `base` of the gap is left. A base of 0.0025
    /// settles in about a sixth of a second.
    public static func approach(_ value: Double, to target: Double, base: Double, dt: Double) -> Double {
        value + (target - value) * (1 - pow(base, max(dt, 0)))
    }

    /// One step of a damped spring: the mouth, which overshoots a little as
    /// it snaps open and shut. ω₀ = 2π / 0.25 s, ζ = 0.6, as Coucou's.
    public static func spring(
        _ value: Double, velocity: Double, to target: Double, dt: Double,
        omega: Double = 2 * .pi / 0.25, damping: Double = 0.6
    ) -> (value: Double, velocity: Double) {
        let step = min(max(dt, 0), 0.05)
        let acceleration = omega * omega * (target - value) - 2 * damping * omega * velocity
        let velocity = velocity + acceleration * step
        return (value + velocity * step, velocity)
    }

    // MARK: Living

    /// Breathing at rest: a slow rise and fall, too small to read as motion
    /// and enough to read as alive.
    public static func breath(at time: Double) -> (sx: Double, sy: Double) {
        let wave = sin(time * 1.8)
        return (1 - wave * 0.012, 1 + wave * 0.022)
    }

    /// The tempo Kapa nods at while music plays. Nothing measures the music's
    /// own beat (ADR 0006), so this is a moderate one, near most pop.
    public static let musicTempo = 104.0

    /// Nodding along: a dip on every beat that eases back up, and a sway from
    /// side to side every two.
    public static func bob(at time: Double) -> (dy: Double, tilt: Double, sy: Double) {
        // A hair added, so a moment that is a beat lands on it rather than a
        // binary fraction short of it, with the dip all spent.
        let beats = time * musicTempo / 60 + 1e-9
        let phase = beats - floor(beats)
        let dip = exp(-phase * 7)
        return (dip * 3.2, sin(beats * .pi) * 4, 1 - dip * 0.05)
    }

    // MARK: Blinking

    /// The lids over a blink begun `elapsed` seconds ago: shut in 70 ms, open
    /// in 130, and fully open outside it.
    public static func lid(sinceBlink elapsed: Double) -> Double {
        let closed = 0.08
        if elapsed < 0 { return 1 }
        if elapsed < KapaBlink.closing {
            return 1 - (1 - closed) * easeIn(elapsed / KapaBlink.closing)
        }
        let opening = elapsed - KapaBlink.closing
        if opening < KapaBlink.opening {
            return closed + (1 - closed) * easeOut(opening / KapaBlink.opening)
        }
        return 1
    }

    // MARK: One-off movements

    /// A squash, stretch or lift, added to whatever else is moving.
    public struct Kick: Equatable, Sendable {
        public var sx = 1.0
        public var sy = 1.0
        /// Downward, in the sheet's units.
        public var dy = 0.0
        /// Sideways, in the sheet's units.
        public var dx = 0.0

        public init(sx: Double = 1, sy: Double = 1, dy: Double = 0, dx: Double = 0) {
            self.sx = sx
            self.sy = sy
            self.dy = dy
            self.dx = dx
        }
    }

    /// How long each reaction runs.
    public static func duration(of reaction: KapaFace.Reaction) -> Double {
        switch reaction {
        case .none: 0
        case .nod: 0.35
        case .gulp: 0.5
        case .hop: 0.45
        }
    }

    /// The reaction's kick `elapsed` seconds in; nil once it is over.
    public static func kick(_ reaction: KapaFace.Reaction, elapsed: Double) -> Kick? {
        let length = duration(of: reaction)
        guard elapsed >= 0, elapsed < length else { return nil }
        let p = elapsed / length
        let wave = sin(p * .pi)
        switch reaction {
        case .none:
            return nil
        case .nod:
            return Kick(sy: 1 - wave * 0.07, dy: wave * 1.5)
        case .gulp:
            // Squash as it swallows, overshoot, settle.
            let squash = sin(p * 2 * .pi) * (1 - p)
            return Kick(sx: 1 + squash * 0.08, sy: 1 - squash * 0.1)
        case .hop:
            let up = sin(p * .pi)
            let land = p > 0.75 ? sin((p - 0.75) / 0.25 * .pi) : 0
            return Kick(sx: 1 + land * 0.06, sy: 1 + up * 0.04 - land * 0.08, dy: -up * 9)
        }
    }

    /// A tap on Kapa: squashed flat, and back with a bounce.
    public static let boopLength = 0.42
    public static func boop(elapsed: Double) -> Kick? {
        guard elapsed >= 0, elapsed < boopLength else { return nil }
        let p = elapsed / boopLength
        let squash = sin(p * 3 * .pi) * pow(1 - p, 1.5)
        return Kick(sx: 1 + squash * 0.16, sy: 1 - squash * 0.2)
    }

    /// A shake of the head, for a dictation that failed: Coucou's error
    /// shake, side to side and settling.
    public static let shakeLength = 0.45
    public static func shake(elapsed: Double) -> Kick? {
        guard elapsed >= 0, elapsed < shakeLength else { return nil }
        let p = elapsed / shakeLength
        return Kick(dx: sin(p * 4 * .pi) * 3 * (1 - p))
    }

    // MARK: Eating a file

    /// How far Kapa opens its mouth for a file held over the Shelf: wider the
    /// nearer it is, never quite shut while one is held. `distance` and
    /// `reach` in the same units.
    public static func appetite(distance: Double, reach: Double) -> Double {
        let near = 1 - min(max(distance / max(reach, 1), 0), 1)
        return 0.35 + 0.65 * near * near
    }

    /// Kapa eating a dropped file, `elapsed` seconds after the drop: the file
    /// is drawn from above into a wide mouth, the mouth snaps shut, Kapa
    /// chews three times and settles, pleased. Nil once it is over.
    public struct Gulp: Equatable, Sendable {
        /// How open the mouth is, 0 to 1.
        public var mouth: Double
        /// How far the file has travelled to the mouth, 0 to 1; nil once it
        /// is inside.
        public var file: Double?
        public var kick: Kick
        /// Eyes shut in a happy squint: chewing and after.
        public var pleased: Bool
    }

    public static let gulpLength = 1.3

    public static func gulp(elapsed: Double) -> Gulp? {
        guard elapsed >= 0, elapsed < gulpLength else { return nil }
        switch elapsed {
        case ..<0.28:
            // The file sinks into the mouth, which opens to meet it.
            let p = elapsed / 0.28
            return Gulp(mouth: 0.6 + 0.4 * easeOut(p), file: easeIn(p), kick: Kick(sy: 1 + 0.04 * p), pleased: false)
        case ..<0.38:
            // Shut: a squash as it goes down.
            let p = (elapsed - 0.28) / 0.1
            return Gulp(mouth: 1 - easeIn(p), file: nil, kick: Kick(sx: 1 + 0.1 * p, sy: 1 - 0.12 * p), pleased: false)
        case ..<1.0:
            // Three chews.
            let p = (elapsed - 0.38) / 0.62
            let chew = abs(sin(p * 3 * .pi))
            return Gulp(mouth: chew * 0.25, file: nil, kick: Kick(sx: 1 + chew * 0.05, sy: 1 - chew * 0.07), pleased: true)
        default:
            let p = (elapsed - 1.0) / (gulpLength - 1.0)
            return Gulp(mouth: 0, file: nil, kick: Kick(sy: 1 + sin(p * .pi) * 0.03), pleased: true)
        }
    }

    // MARK: Easing

    static func easeIn(_ t: Double) -> Double { t * t * t }
    static func easeOut(_ t: Double) -> Double { 1 - pow(1 - min(max(t, 0), 1), 3) }
}
