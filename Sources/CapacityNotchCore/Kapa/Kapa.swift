import Foundation

/// What Kapa shows: one pose for each thing the surface can honestly say
/// (ADR 0006). Every one is read off a signal that already exists — a
/// Capacity Snapshot, a dictation's phase, a drag over the Shelf, a track —
/// and none is invented: there is no "thinking Claude", no dancing to a beat
/// that is never measured.
public enum KapaExpression: String, CaseIterable, Equatable, Sendable {
    /// Plenty left; nothing happening.
    case rest
    /// A Quota Window tightening: attentive, not alarmed.
    case focused
    /// The empty Shelf, inviting a file.
    case curious
    /// A track playing.
    case music
    /// A track loaded and paused.
    case paused
    /// A file held over the Shelf: the mouth opens.
    case dropReady
    /// Something landed on the Shelf.
    case received
    /// A dictation recording.
    case listening
    /// A dictation being recognised.
    case thinking
    /// Dictated text inserted (and copied).
    case inserted
    /// Dictated text copied only — not inserted.
    case copied
    /// A Quota Window unsustainable: below a tenth.
    case worried
    /// A Quota Window used up, waiting for its reset.
    case waiting
    /// Capacity stale, or still connecting: no judgement on old numbers.
    case stale
    /// A Provider disconnected.
    case puzzled
    /// A dictation that failed.
    case failed
    /// Nothing connected yet: the first launch.
    case hello
    /// Beside the Teleprompter's controls: still, whatever the Script does —
    /// nothing moves near a person reading.
    case quiet
}

// MARK: - The face each pose draws

/// The face, as parts. A pose is a face; the renderer draws parts, so a new
/// pose is a new row in `KapaFace.of`, not a new drawing.
public struct KapaFace: Equatable, Sendable {
    public enum Eyes: Equatable, Sendable {
        /// Round, with a catch-light.
        case open
        /// Larger and higher: something is coming.
        case wide
        /// Upturned arcs: pleased.
        case happy
        /// Downturned arcs: calm, waiting with eyes shut.
        case closed
        /// A lid drawn flat across the top half: sleepy, unsure.
        case lidded
        /// Narrowed: working something out.
        case narrowed
        /// One eye smaller than the other: puzzled.
        case uneven
    }

    public enum Mouth: Equatable, Sendable {
        case smile
        case small
        case line
        /// An open "o", for the file about to be swallowed.
        case open
        /// An open smile.
        case grin
        /// A turned-down curve.
        case worried
        /// A wavy line: not sure.
        case wobble
    }

    public enum Brows: Equatable, Sendable {
        case none
        /// Inner ends raised.
        case worried
        /// One raised, one flat.
        case puzzled
    }

    /// The one sign beside Kapa that carries the meaning colour alone must
    /// not (ADR 0006: the body never changes colour).
    public enum Badge: Equatable, Sendable {
        case none
        case check
        case alert
        case clock
        case dashedClock
        case cross
        case clipboard
        case file
        case note
        case unplugged
        case sparkle
        case pause
    }

    /// A one-off movement when the pose is entered, never repeated.
    public enum Reaction: Equatable, Sendable {
        case none
        /// A small nod: a track starts, text goes in.
        case nod
        /// Squash and recover: the Shelf took something.
        case gulp
        /// A little hop: hello.
        case hop
    }

    public var eyes: Eyes
    public var mouth: Mouth
    public var brows: Brows = .none
    public var badge: Badge = .none
    public var headphones = false
    public var blush = false
    /// Where Kapa looks, as turns of the head (see `KapaGaze`).
    public var look = KapaLook.ahead
    /// Lean of the whole body, in degrees; negative leans left.
    public var tilt: Double = 0
    public var reaction: Reaction = .none

    public static func of(_ expression: KapaExpression) -> KapaFace {
        switch expression {
        case .rest:
            KapaFace(eyes: .open, mouth: .smile)
        case .focused:
            KapaFace(eyes: .open, mouth: .line)
        case .curious:
            KapaFace(eyes: .open, mouth: .small, look: KapaLook(yaw: 0.12, pitch: 0.12))
        case .music:
            KapaFace(eyes: .happy, mouth: .grin, badge: .note, headphones: true, reaction: .nod)
        case .paused:
            KapaFace(eyes: .open, mouth: .line, headphones: true)
        case .dropReady:
            KapaFace(eyes: .wide, mouth: .open, badge: .file, look: KapaLook(yaw: -0.08, pitch: 0.14))
        case .received:
            KapaFace(eyes: .happy, mouth: .small, badge: .check, blush: true, reaction: .gulp)
        case .listening:
            KapaFace(eyes: .open, mouth: .small, look: .towardTheOrb)
        case .thinking:
            KapaFace(eyes: .narrowed, mouth: .line, look: .towardTheOrb)
        case .inserted:
            KapaFace(eyes: .happy, mouth: .grin, badge: .check, reaction: .nod)
        case .copied:
            KapaFace(eyes: .open, mouth: .small, badge: .clipboard, look: .towardTheOrb)
        case .worried:
            KapaFace(eyes: .open, mouth: .worried, brows: .worried, badge: .alert)
        case .waiting:
            KapaFace(eyes: .closed, mouth: .line, badge: .clock)
        case .stale:
            KapaFace(eyes: .lidded, mouth: .line, badge: .dashedClock)
        case .puzzled:
            KapaFace(eyes: .uneven, mouth: .wobble, brows: .puzzled, badge: .unplugged, tilt: -4)
        case .failed:
            KapaFace(eyes: .uneven, mouth: .wobble, brows: .puzzled, badge: .cross, tilt: -4)
        case .hello:
            KapaFace(eyes: .happy, mouth: .grin, badge: .sparkle, reaction: .hop)
        case .quiet:
            KapaFace(eyes: .open, mouth: .line, badge: .pause)
        }
    }
}

// MARK: - Where the eyes sit

/// A turn of the head: yaw to the right, pitch upwards, in radians.
public struct KapaLook: Equatable, Sendable {
    public var yaw: Double
    public var pitch: Double

    public init(yaw: Double, pitch: Double) {
        self.yaw = yaw
        self.pitch = pitch
    }

    public static let ahead = KapaLook(yaw: 0, pitch: 0)
    /// Up and to the left: where the Dictation Capsule's orb is from the
    /// corner Kapa sits in.
    public static let towardTheOrb = KapaLook(yaw: -0.2, pitch: 0.15)
}

/// The eyes are drawn as if on a sphere, so a turn of the head moves them
/// round the body and narrows the one turning away. The idea is Coucou's
/// (MIT; docs/research/coucou-character.md §1.2); the numbers are this
/// drawing's.
///
/// Everything is in the drawing's own units: a 100-unit square, y down, the
/// face centred at (52, 60) with the eyes 11 either side, as in Paper
/// ("Kapa — 01 Character sheet").
public enum KapaGaze {
    public struct Eye: Equatable, Sendable {
        public var x: Double
        public var y: Double
        /// Foreshortening: 1 facing, narrower turned away.
        public var scaleX: Double
        public var scaleY: Double
        /// Gone round the side of the head.
        public var isHidden: Bool
    }

    static let faceX = 52.0
    static let faceY = 60.0
    /// Half the body's width at the eyes, and half its height about them.
    static let radiusX = 40.0
    static let radiusY = 30.0
    /// Each eye's own turn from the middle: sin(0.28) × 40 ≈ 11 units.
    static let spread = 0.28

    /// One eye: `side` is −1 for the left, 1 for the right.
    public static func eye(side: Double, look: KapaLook) -> Eye {
        let turn = side * spread + look.yaw
        let facing = cos(turn) * cos(look.pitch)
        return Eye(
            x: faceX + sin(turn) * cos(look.pitch) * radiusX,
            y: faceY - sin(look.pitch) * radiusY,
            // Measured against the eye's own resting turn, so looking ahead
            // draws the eye at exactly the size it was drawn.
            scaleX: max(0.18, cos(turn)) / cos(spread),
            scaleY: max(0.18, cos(look.pitch)),
            isHidden: facing < 0.04
        )
    }

    /// How far the mouth and brows move with the head: less than the eyes,
    /// since they sit lower on the curve.
    public static func features(look: KapaLook) -> (dx: Double, dy: Double) {
        (sin(look.yaw) * radiusX * 0.8, -sin(look.pitch) * radiusY * 0.6)
    }
}

// MARK: - Blinking

/// When Kapa blinks: every 2.2 to 5.4 seconds, and about one time in five
/// twice. Coucou's rhythm (docs/research/coucou-character.md §1.5), which
/// reads as alive without reading as busy. The application wakes only for
/// these; the render server moves the lids.
public enum KapaBlink {
    public static let shortest: TimeInterval = 2.2
    public static let spread: TimeInterval = 3.2
    public static let doubleChance = 0.22
    public static let doubleGap: TimeInterval = 0.23
    /// Shut quickly, open a little slower.
    public static let closing: TimeInterval = 0.07
    public static let opening: TimeInterval = 0.13

    /// The wait before the next blink, from a uniform draw in 0...1.
    public static func delay(_ draw: Double) -> TimeInterval {
        shortest + spread * min(max(draw, 0), 1)
    }

    public static func isDouble(_ draw: Double) -> Bool {
        draw < doubleChance
    }

    /// Eyes that are already shut, or arcs, have no lids to drop.
    public static func blinks(_ eyes: KapaFace.Eyes) -> Bool {
        switch eyes {
        case .open, .wide, .lidded, .narrowed, .uneven: true
        case .happy, .closed: false
        }
    }
}

// MARK: - Which pose, from what the surface knows

/// The signals, read into poses. Pure, so each rule can be tested where it
/// is written.
public enum KapaMood {
    /// One Provider's pose, from its connection and the window with the least
    /// left. Old numbers get no judgement: stale and connecting look the same.
    public static func capacity(_ snapshot: CapacitySnapshot) -> KapaExpression {
        switch snapshot.connectionState {
        case .disconnected:
            return .puzzled
        case .connecting, .stale:
            return .stale
        case .fresh, .mock:
            guard let window = snapshot.headlineWindow else { return .rest }
            guard window.remainingFraction > 0 else { return .waiting }
            switch window.pace {
            case .sustainable: return .rest
            case .tightening: return .focused
            case .unsustainable: return .worried
            }
        }
    }

    /// One Kapa a page: on the card that explains the pose, which is the one
    /// needing the most attention. A tie goes to the card that comes first,
    /// so the choice does not wander between equal cards.
    public static func capacityFocus(_ snapshots: [CapacitySnapshot]) -> (provider: Provider, expression: KapaExpression)? {
        var best: (provider: Provider, expression: KapaExpression, urgency: Int)?
        for snapshot in snapshots {
            let expression = capacity(snapshot)
            let urgency = urgency(of: expression)
            if best == nil || urgency < best!.urgency {
                best = (snapshot.provider, expression, urgency)
            }
        }
        return best.map { ($0.provider, $0.expression) }
    }

    /// Lower first: what most wants a look.
    static func urgency(of expression: KapaExpression) -> Int {
        switch expression {
        case .worried: 0
        case .waiting: 1
        case .puzzled: 2
        case .stale: 3
        case .focused: 4
        default: 5
        }
    }

    public static func music(isPlaying: Bool) -> KapaExpression {
        isPlaying ? .music : .paused
    }
}

/// Whether Kapa is drawn. On unless a person turns it off: it asks for no
/// permission, reads nothing new and never takes the compact strip, so it is
/// part of how Modules already on look rather than a Module of its own
/// (ADR 0006).
public enum KapaPreference {
    public static let key = "showsKapa"
    public static let defaultValue = true
}

/// Whether CapaTheNotch plays its sounds (ADR 0007): on, with one switch to
/// turn them off, as Kapa has.
public enum SoundPreference {
    public static let key = "playsSounds"
    public static let defaultValue = true
    public static var isOn: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? defaultValue }
}

