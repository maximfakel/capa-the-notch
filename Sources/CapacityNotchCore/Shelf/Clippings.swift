import Foundation

/// One copied text the Shelf keeps: what was copied, and when (CONTEXT:
/// Clipping).
public struct Clipping: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let text: String
    public let copiedAt: Date

    public init(id: UUID = UUID(), text: String, copiedAt: Date) {
        self.id = id
        self.text = text
        self.copiedAt = copiedAt
    }
}

/// How many Clippings the Clipboard tab keeps, as chosen in Settings.
public enum ClippingLimit: Int, CaseIterable, Sendable {
    case twenty = 20
    case fifty = 50
    case hundred = 100

    public static let `default` = ClippingLimit.twenty
}

/// The Clipboard tab's Clippings, newest first, in memory only (ADR 0005,
/// amended 2026-10-02): for pasting again what was copied a little while
/// ago, not an archive.
public struct Clippings: Equatable, Sendable {
    /// A text longer than this is not kept at all: cut short, it would paste
    /// without its end and no one would notice.
    public static let maximumLength = 100_000
    /// How long each is kept, unless that is switched off.
    public static let lifetime: TimeInterval = 24 * 60 * 60

    public private(set) var items: [Clipping] = []

    public init() {}

    /// Kept in front. A text copied again rises, with a new day, rather than
    /// appearing twice; past the limit the oldest give way.
    @discardableResult
    public mutating func keep(_ text: String, at date: Date, limit: ClippingLimit = .default) -> Bool {
        guard text.count <= Self.maximumLength,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        items.removeAll { $0.text == text }
        items.insert(Clipping(text: text, copiedAt: date), at: 0)
        trim(to: limit)
        return true
    }

    /// Fewer chosen: the oldest give way now, not at the next copy; the rest
    /// stay as they were.
    public mutating func trim(to limit: ClippingLimit) {
        if items.count > limit.rawValue { items.removeLast(items.count - limit.rawValue) }
    }

    /// Those a day old go, when expiry is on.
    public mutating func forgetOld(at now: Date, expiring: Bool) {
        guard expiring else { return }
        items.removeAll { now.timeIntervalSince($0.copiedAt) >= Self.lifetime }
    }

    public mutating func remove(_ id: Clipping.ID) {
        items.removeAll { $0.id == id }
    }

    public mutating func clear() {
        items.removeAll()
    }
}

/// Whether a text on the clipboard is kept as a Clipping (ADR 0005): plain
/// text, not a copied file's name, nothing a password manager marks, nothing
/// copied while Passwords, Keychain Access or a chosen application is in
/// front, and nothing Capacity Notch put there itself — whether it wrote it,
/// or someone pressed ⌘C in one of its windows.
public enum ClipboardText {
    /// The type Capacity Notch adds to everything it puts on the clipboard,
    /// so that its own copies are never kept.
    public static let ownMarker = "app.capacitynotch.own"

    static let textTypes: Set<String> = ["public.utf8-plain-text", "public.plain-text"]

    /// - Parameters:
    ///   - types: each pasteboard item's type identifiers.
    ///   - frontmost: the application in front when it was copied; macOS
    ///     does not say which one wrote it.
    ///   - excluded: the applications chosen in Settings.
    ///   - ownApplication: Capacity Notch's own identifier.
    public static func isKept(types: [[String]], frontmost: String?, excluded: Set<String>, ownApplication: String?) -> Bool {
        let all = Set(types.flatMap { $0 })
        guard !all.isDisjoint(with: textTypes),
              !all.contains("public.file-url"),
              !all.contains(ownMarker),
              all.isDisjoint(with: ClipboardTake.secretMarkers) else { return false }
        if ClipboardTake.isExcludedApplication(frontmost) { return false }
        if let frontmost, excluded.contains(frontmost) || frontmost == ownApplication { return false }
        return true
    }
}
