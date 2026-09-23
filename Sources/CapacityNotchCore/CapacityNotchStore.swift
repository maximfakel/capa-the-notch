import Combine

public final class CapacityNotchStore: ObservableObject {
    public enum Presentation: Equatable, Sendable {
        case compact
        case expanded
    }

    @Published public private(set) var snapshots: [CapacitySnapshot]
    @Published public private(set) var presentation: Presentation

    public init(
        snapshots: [CapacitySnapshot],
        presentation: Presentation = .compact
    ) {
        self.snapshots = snapshots
        self.presentation = presentation
    }

    /// Replaces the Capacity Snapshot for the Provider it describes, keeping
    /// the order Providers already occupy on the surface.
    public func apply(_ snapshot: CapacitySnapshot) {
        if let index = snapshots.firstIndex(where: { $0.provider == snapshot.provider }) {
            snapshots[index] = snapshot
        } else {
            snapshots.append(snapshot)
        }
    }

    /// Pinned open: the surface stays until it is dismissed, rather than
    /// closing when the pointer wanders off.
    @Published public private(set) var isPinned = false

    /// The Quota Window an alert was about, while it is worth pointing at.
    /// Opening the surface from a notification and then hunting for the row it
    /// meant is not being taken to the window.
    @Published public private(set) var highlighted: HighlightedWindow?

    public struct HighlightedWindow: Equatable, Sendable {
        public let provider: Provider
        public let windowID: String

        public init(provider: Provider, windowID: String) {
            self.provider = provider
            self.windowID = windowID
        }
    }

    public func highlight(_ window: HighlightedWindow?) {
        highlighted = window
    }

    public func pin() {
        isPinned = true
        expand()
    }

    /// Dismisses a pinned surface. Used by a second click, by Escape, and by
    /// a click anywhere else.
    public func dismiss() {
        isPinned = false
        collapse()
    }

    public func togglePin() {
        isPinned ? dismiss() : pin()
    }

    public func toggle() {
        presentation = presentation == .compact ? .expanded : .compact
    }

    public func expand() {
        guard presentation != .expanded else { return }
        presentation = .expanded
    }

    public func collapse() {
        guard presentation != .compact else { return }
        presentation = .compact
    }
}
