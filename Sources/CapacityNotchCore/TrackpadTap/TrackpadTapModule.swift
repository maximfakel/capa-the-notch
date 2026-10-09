import Foundation

/// Where opening the surface with two taps stands (ticket 14).
///
/// The taps are read through MultitouchSupport, a private framework (ADR
/// 0004), which Apple can change or close in any update. When it does, the
/// switch in Settings and Copy Diagnostics say so, rather than two taps
/// quietly doing nothing.
public enum TrackpadTapStatus: Equatable, Sendable {
    /// Off, as it is for anyone who has not asked for it.
    case off
    /// Reading the trackpad.
    case listening
    /// The framework, or something in it this needs, is not there, or would
    /// not start.
    case unreadable
    /// No trackpad to read.
    case noTrackpad
    /// It started, but the trackpad has been used since without a single
    /// touch reaching CapaTheNotch.
    case silent

    /// For the report: each under the 32 characters `Redaction` would rub out.
    public var diagnosticCode: String? {
        switch self {
        case .off: nil
        case .listening: "trackpad-tap-on"
        case .unreadable: "trackpad-tap-unreadable"
        case .noTrackpad: "trackpad-tap-no-trackpad"
        case .silent: "trackpad-tap-silent"
        }
    }

    /// What Settings says beside the switch when it cannot work. English;
    /// shown through the localisation table.
    public var guidance: String? {
        switch self {
        case .off, .listening: nil
        case .unreadable: "macOS no longer lets CapaTheNotch read the trackpad, so two taps cannot open the notch."
        case .noTrackpad: "No trackpad is connected. Two taps will work once one is."
        case .silent: "The trackpad stopped answering CapaTheNotch, so two taps cannot open the notch. Turning the switch off and on tries again."
        }
    }
}

/// Tells a trackpad that has gone quiet from one nobody is touching.
///
/// A scroll that begins with fingers on a multitouch surface is proof that
/// someone is touching it. When several in a row arrive and no frame has
/// come for any of them, the frames have stopped — Apple changed something,
/// or the device went away — and that is a failure to report, not silence
/// to wait out.
public struct TrackpadSilence: Equatable, Sendable {
    /// Scrolls in a row, with no frame near any of them, before it is called.
    public var tolerated: Int
    /// How near a frame must be to a scroll to account for it, in seconds.
    public var window: TimeInterval
    private var unanswered = 0

    public init(tolerated: Int = 3, window: TimeInterval = 1) {
        self.tolerated = tolerated
        self.window = window
    }

    /// A scroll began on a multitouch surface. True once the frames have
    /// stopped answering for long enough to say so.
    public mutating func trackpadScrolled(at time: TimeInterval, lastFrame: TimeInterval?) -> Bool {
        if let lastFrame, abs(time - lastFrame) <= window {
            unanswered = 0
            return false
        }
        unanswered += 1
        return unanswered >= tolerated
    }

    public mutating func reset() {
        unanswered = 0
    }
}

public enum TrackpadTapModule {
    /// What it costs, said beside the switch. Measured on macOS 27.0.1:
    /// reading MultitouchSupport's frames asks TCC for nothing
    /// (docs/research/trackpad-double-tap.md).
    public static let cost = "Asks for no permission. Reads touches through MultitouchSupport, a private part of macOS that Apple can change in any update; if it stops answering, this says so. With Tap to click on, the two taps also double-click where the pointer is."
}

/// Two taps while the hands are on the keyboard are a palm or a thumb
/// brushing the trackpad, not a request — macOS ignores the trackpad while
/// typing for the same reason. Read from how long ago a key went down, which
/// macOS answers without any permission.
public enum TrackpadTyping {
    /// A key pressed this recently, in seconds, makes two taps not count.
    public static let quiet: TimeInterval = 1

    public static func suppresses(secondsSinceKeyDown: TimeInterval) -> Bool {
        secondsSinceKeyDown < quiet
    }
}
