import Foundation

/// One display Capacity Notch could sit on.
public struct DisplayDescriptor: Equatable, Sendable, Identifiable {
    public let id: UInt32
    public let name: String
    public let isBuiltIn: Bool

    public init(id: UInt32, name: String, isBuiltIn: Bool) {
        self.id = id
        self.name = name
        self.isBuiltIn = isBuiltIn
    }
}

/// Which display the surface belongs on.
///
/// Exactly one, always. A copy on every screen is not a notch, and a preferred
/// display that has been unplugged must not strand the surface where nobody
/// can see it — the choice is made again from what is actually connected each
/// time the displays change.
public enum DisplaySelection {
    public static func chosen(
        preferred: UInt32?,
        available: [DisplayDescriptor]
    ) -> DisplayDescriptor? {
        if let preferred, let match = available.first(where: { $0.id == preferred }) {
            return match
        }
        return available.first(where: \.isBuiltIn) ?? available.first
    }
}

/// A surface put away for a while.
///
/// Hiding is not the same as quitting: the Providers keep being read, and the
/// surface comes back on its own. A person who hides it for an hour should not
/// have to remember to bring it back.
public struct SurfaceHide: Equatable, Sendable {
    public static let defaultDuration: TimeInterval = 3600

    public let until: Date

    public init(until: Date) {
        self.until = until
    }

    public init(from now: Date, lasting duration: TimeInterval = SurfaceHide.defaultDuration) {
        until = now.addingTimeInterval(duration)
    }

    public func isOver(at now: Date) -> Bool {
        now >= until
    }

    /// What the menu says, so the person can see when it comes back.
    public func remainingText(at now: Date) -> String {
        isOver(at: now) ? "moments" : ResetCountdown.text(until: until, at: now)
    }
}
