import Foundation

/// A global shortcut: the key, as the hardware numbers it, and the modifiers
/// held with it.
public struct KeyShortcut: Codable, Equatable, Hashable, Sendable {
    public struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    public let keyCode: UInt32
    public let modifiers: Modifiers
    /// What the key is called, as it was when recorded: "Space", "Esc", "↑", "P".
    public let keyLabel: String

    public init(keyCode: UInt32, modifiers: Modifiers, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    /// The modifiers in the Mac's own order, then the key: "⌃⌥Space".
    public var display: String { modifierSymbols.joined() + keyLabel }

    /// Each keycap on its own, for drawing them apart.
    public var keycaps: [String] { modifierSymbols + [keyLabel] }

    /// What to call a key just pressed, for its keycap. Keys the keyboard
    /// prints nothing readable for — Space, the arrows, function keys — are
    /// named, since their characters draw blank or as private symbols.
    public static func keyLabel(keyCode: UInt32, characters: String?) -> String {
        switch keyCode {
        case 49: return "Space"
        case 53: return "Esc"
        case 36: return "Return"
        case 48: return "Tab"
        case 51: return "Delete"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default: break
        }
        // The arrows' and function keys' characters live in the private use area.
        guard let characters, !characters.isEmpty,
              characters.unicodeScalars.allSatisfy({ !(0xE000...0xF8FF).contains($0.value) && !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) })
        else { return "Key \(keyCode)" }
        return characters.uppercased()
    }

    private var modifierSymbols: [String] {
        [(Modifiers.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { modifiers.contains($0.0) }
            .map(\.1)
    }
}

/// The four things a shortcut can do to the Teleprompter.
public enum TeleprompterAction: String, CaseIterable, Sendable {
    case startOrPause
    case stop
    case faster
    case slower

    public var title: String {
        switch self {
        case .startOrPause: "Start or pause"
        case .stop: "Stop"
        case .faster: "Faster"
        case .slower: "Slower"
        }
    }
}

public enum TeleprompterShortcuts {
    /// As drawn: Control-Option with Space, Escape and the up and down arrows.
    public static let standard: [TeleprompterAction: KeyShortcut] = [
        .startOrPause: KeyShortcut(keyCode: 49, modifiers: [.control, .option], keyLabel: "Space"),
        .stop: KeyShortcut(keyCode: 53, modifiers: [.control, .option], keyLabel: "Esc"),
        .faster: KeyShortcut(keyCode: 126, modifiers: [.control, .option], keyLabel: "↑"),
        .slower: KeyShortcut(keyCode: 125, modifiers: [.control, .option], keyLabel: "↓"),
    ]
}
