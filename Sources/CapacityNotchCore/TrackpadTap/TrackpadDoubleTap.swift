import Foundation

/// One finger on the trackpad, as one frame reports it.
public struct TouchContact: Equatable, Sendable {
    /// The same finger keeps its number from touch-down to lift.
    public var id: Int
    /// Where it is, in millimetres from a corner of the trackpad.
    public var x: Double
    public var y: Double
    /// How long the contact is, along its long axis, in the units
    /// MultitouchSupport reports: a fingertip is small, a palm is not.
    public var size: Double

    public init(id: Int, x: Double, y: Double, size: Double) {
        self.id = id
        self.x = x
        self.y = y
        self.size = size
    }
}

/// Everything touching the trackpad at one moment. Only contacts on the
/// glass are here — not a finger hovering above it or lifting off it.
public struct TouchFrame: Equatable, Sendable {
    /// Seconds, on any clock that only moves forward.
    public var time: TimeInterval
    public var contacts: [TouchContact]

    public init(time: TimeInterval, contacts: [TouchContact]) {
        self.time = time
        self.contacts = contacts
    }
}

/// How quick, still and close two taps have to be (ticket 14).
public struct TapTuning: Equatable, Sendable {
    /// A touch held longer than this is a press-and-hold, not a tap.
    public var longestTap: TimeInterval
    /// A touch that wanders further than this, in millimetres, is a drag.
    public var furthestDrift: Double
    /// From the first lift to the second touch: the Mac's own double-click
    /// interval, so the two taps are as quick as a double-click is.
    public var longestGap: TimeInterval
    /// How far the second tap may land from the first, in millimetres.
    public var furthestApart: Double
    /// A contact larger than this is a palm or the side of a hand.
    public var largestContact: Double

    public init(
        longestTap: TimeInterval = 0.3,
        furthestDrift: Double = 2.5,
        longestGap: TimeInterval = 0.5,
        furthestApart: Double = 12,
        largestContact: Double = 20
    ) {
        self.longestTap = longestTap
        self.furthestDrift = furthestDrift
        self.longestGap = longestGap
        self.furthestApart = furthestApart
        self.largestContact = largestContact
    }

    /// The defaults, timed to the double-click interval chosen in System
    /// Settings (`NSEvent.doubleClickInterval`).
    public static func matching(doubleClickInterval: TimeInterval) -> TapTuning {
        TapTuning(longestGap: doubleClickInterval)
    }
}

/// Two taps of one finger, read from the touches themselves rather than from
/// the clicks they may produce (ticket 14).
///
/// It only watches: it is given frames and says when two taps have
/// completed. It never sees, holds or swallows an event, so a double-click
/// goes on reaching whatever is under the pointer.
public struct TrackpadDoubleTap: Sendable {
    public var tuning: TapTuning

    private struct Touch {
        let id: Int
        let start: TimeInterval
        let x: Double, y: Double
        var drift: Double = 0
        /// Something made it not a tap: a second finger, a palm, a press.
        var spoiled: Bool
    }

    private struct Tap {
        let lifted: TimeInterval
        let x: Double, y: Double
    }

    private var touch: Touch?
    private var firstTap: Tap?

    public init(tuning: TapTuning = TapTuning()) {
        self.tuning = tuning
    }

    /// Takes the next frame; true on the frame that completes two taps.
    public mutating func observe(_ frame: TouchFrame) -> Bool {
        switch frame.contacts.count {
        case 0:
            return lift(at: frame.time)
        case 1:
            let contact = frame.contacts[0]
            if var current = touch {
                // A different finger without a lift between: not one tap.
                if contact.id != current.id { current.spoiled = true }
                current.drift = max(current.drift, distance(contact.x - current.x, contact.y - current.y))
                if contact.size > tuning.largestContact { current.spoiled = true }
                touch = current
            } else {
                touch = Touch(
                    id: contact.id, start: frame.time, x: contact.x, y: contact.y,
                    spoiled: contact.size > tuning.largestContact
                )
            }
        default:
            // Two fingers, or a finger and a resting thumb, are not one
            // finger tapping; and they end whatever a first tap began.
            let contact = frame.contacts[0]
            var current = touch ?? Touch(id: contact.id, start: frame.time, x: contact.x, y: contact.y, spoiled: true)
            current.spoiled = true
            touch = current
            firstTap = nil
        }
        return false
    }

    /// The trackpad was pressed down, physically. A touch that clicks is a
    /// click, not a tap; nor does a press just after a lift count as one.
    public mutating func press(at time: TimeInterval) {
        if touch != nil {
            touch?.spoiled = true
        } else if let first = firstTap, time - first.lifted < 0.1 {
            firstTap = nil
        }
    }

    /// Forgets any tap begun, as after the trackpad goes quiet or restarts.
    public mutating func reset() {
        touch = nil
        firstTap = nil
    }

    private mutating func lift(at time: TimeInterval) -> Bool {
        guard let ended = touch else { return false }
        touch = nil
        let isTap = !ended.spoiled
            && time - ended.start <= tuning.longestTap
            && ended.drift <= tuning.furthestDrift
        guard isTap else {
            firstTap = nil
            return false
        }
        if let first = firstTap,
           ended.start - first.lifted <= tuning.longestGap,
           distance(ended.x - first.x, ended.y - first.y) <= tuning.furthestApart {
            firstTap = nil
            return true
        }
        firstTap = Tap(lifted: time, x: ended.x, y: ended.y)
        return false
    }

    private func distance(_ dx: Double, _ dy: Double) -> Double {
        (dx * dx + dy * dy).squareRoot()
    }
}
