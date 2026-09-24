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
