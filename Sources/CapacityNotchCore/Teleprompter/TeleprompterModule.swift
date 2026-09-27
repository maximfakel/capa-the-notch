import Foundation

/// The Script (CONTEXT.md): the one text the Teleprompter Module reads out.
/// Plain text — line breaks and blank lines are kept, nothing is parsed.
public enum TeleprompterScript {
    /// Words as a person reading aloud counts them: runs of text holding at
    /// least one letter or digit. A dash standing alone is not a word.
    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace)
            .filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
            .count
    }

    /// How long reading it takes at a speed, to the nearest minute, and a
    /// minute at least for anything at all.
    public static func minutes(words: Int, wordsPerMinute: Double) -> Int {
        guard words > 0, wordsPerMinute > 0 else { return 0 }
        return max(Int((Double(words) / wordsPerMinute).rounded()), 1)
    }

    /// The Script as the row's lines: its own line breaks kept, a blank line
    /// kept as a gap, each paragraph wrapped by `wrap` — the type decides
    /// where — and nothing blank before the first line or after the last.
    public static func lines(_ text: String, wrap: (String) -> [String]) -> [String] {
        var lines: [String] = []
        for paragraph in text.components(separatedBy: .newlines) {
            let trimmed = paragraph.trimmingCharacters(in: .whitespaces)
            lines += trimmed.isEmpty ? [""] : wrap(trimmed)
        }
        while lines.first == "" { lines.removeFirst() }
        while lines.last == "" { lines.removeLast() }
        return lines
    }
}

/// What the Teleprompter Module says about itself in Copy Diagnostics: that it
/// is on, and how long the Script is. Never a word of the Script itself — the
/// report is built from closed vocabularies (`DiagnosticReport`), and a
/// count is one.
public enum TeleprompterModule {
    public static func observation(enabled: Bool, script: String) -> String {
        enabled ? "teleprompter-on-\(TeleprompterScript.wordCount(script))-words" : "teleprompter-off"
    }
}

/// The text sizes Settings offers; medium is the mockup's.
public enum TeleprompterTextSize: String, CaseIterable, Sendable {
    case small
    case medium
    case large

    public var points: Double {
        switch self {
        case .small: 15
        case .medium: 17
        case .large: 20
        }
    }

    public var title: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }
}
