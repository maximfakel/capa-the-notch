import Foundation

// The Translator Module (ticket 28): Russian to English and English to
// Russian, on this Mac. What is translated — the text in, the text out —
// never reaches a log, Copy Diagnostics or a Preference; only states do.

/// Which way a text is translated.
public enum TranslationDirection: String, CaseIterable, Equatable, Sendable {
    case russianToEnglish
    case englishToRussian

    /// The other way round.
    public var flipped: Self { self == .russianToEnglish ? .englishToRussian : .russianToEnglish }

    /// BCP 47 codes, as the engine is asked for them.
    public var sourceCode: String { self == .russianToEnglish ? "ru" : "en" }
    public var targetCode: String { self == .russianToEnglish ? "en" : "ru" }

    /// "RU → EN", as the page's switch shows it.
    public var label: String { self == .russianToEnglish ? "RU → EN" : "EN → RU" }

    /// Cyrillic goes to English, Latin to Russian. Letters are counted, so a
    /// Russian sentence with "pull request" in it is still Russian, and an
    /// English one naming "Яндекс" still English; a tie is Russian, the
    /// author's own language. Nothing to count — digits, punctuation, other
    /// scripts alone — is no direction at all.
    public static func detect(_ text: String) -> Self? {
        var cyrillic = 0, latin = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            switch scalar.value {
            case 0x0400...0x052F, 0x1C80...0x1C8F, 0x2DE0...0x2DFF, 0xA640...0xA69F: cyrillic += 1
            case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x024F: latin += 1
            default: break
            }
        }
        guard cyrillic + latin > 0 else { return nil }
        return cyrillic >= latin ? .russianToEnglish : .englishToRussian
    }
}

/// What is typed or pasted on the translator's page, and which way it goes:
/// detected from the text unless the person flipped it. A flip holds while
/// the text is edited and is forgotten once the field is emptied, so the next
/// text is detected afresh.
public struct TranslatorDraft: Equatable, Sendable {
    public private(set) var text = ""
    public private(set) var chosen: TranslationDirection?

    public init(text: String = "") { self.text = text }

    public var direction: TranslationDirection {
        chosen ?? TranslationDirection.detect(text) ?? .russianToEnglish
    }

    /// Whether the person turned it round, rather than the text deciding.
    public var isFlipped: Bool { chosen != nil && chosen != TranslationDirection.detect(text) }

    public var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public mutating func edit(_ text: String) {
        self.text = text
        if !hasText { chosen = nil }
    }

    public mutating func flip() { chosen = direction.flipped }
}

/// Whether the Module can translate on this Mac, and if not, what is missing.
public enum TranslatorReadiness: String, Equatable, Sendable {
    /// Apple's on-device translation can be driven without a window only from
    /// macOS 26 (`TranslationSession(installedSource:target:)`).
    case needsNewerMacOS = "needs-macos-26"
    /// Still asking macOS.
    case checking
    /// Russian or English is not downloaded for translation yet.
    case needsLanguages = "needs-languages"
    case ready

    /// What macOS says about the two languages, read once for each way.
    public static func from(systemSupported: Bool, installed: [TranslationDirection: Bool]?) -> Self {
        guard systemSupported else { return .needsNewerMacOS }
        guard let installed else { return .checking }
        return TranslationDirection.allCases.allSatisfy { installed[$0] == true } ? .ready : .needsLanguages
    }
}

/// One translation asked for by the shortcut: begun once, finished once.
/// The shortcut pressed again while one is under way is not a second one.
public struct TranslatorShortcutSession: Sendable {
    public private(set) var running: UUID?
    public init() {}
    public mutating func begin() -> UUID? {
        guard running == nil else { return nil }
        let id = UUID(); running = id; return id
    }
    /// Whether this run is still the one under way; a cancelled run's late
    /// result is dropped.
    public mutating func finish(_ id: UUID) -> Bool {
        guard running == id else { return false }
        running = nil; return true
    }
    public mutating func cancel() { running = nil }
}

/// What the shortcut did: the selection brought to the page, or why not.
/// Nothing is replaced by the shortcut itself; that waits for the person
/// (`TranslatorSelection.actions`).
public enum TranslatorShortcutOutcome: Equatable, Sendable {
    /// Read and translated; the surface opens on the Translator page with it.
    case shown(TranslatorSelection)
    case nothingSelected
    case secureField
    case nothingToTranslate
    case failed(TranslatorFailure)

    /// For the log: a closed set of words, never the text.
    public var code: String {
        switch self {
        case let .shown(selection):
            "shown-\(selection.direction.sourceCode)-\(selection.direction.targetCode)-\(selection.isEditable ? "field" : "not-field")"
        case .nothingSelected: "nothing-selected"
        case .secureField: "secure-field"
        case .nothingToTranslate: "nothing-to-translate"
        case let .failed(failure): "failed-\(failure.rawValue)"
        }
    }

    /// What the opened page says when there is no selection to show, in
    /// English (the page translates it); nil when there is one.
    public func message(accessibilityAllowed: Bool) -> String? {
        switch self {
        case .shown: nil
        case .nothingSelected:
            accessibilityAllowed ? "Select text to translate first." : "Allow Accessibility in Translator settings to translate a selection."
        case .secureField: "Password fields are not translated."
        case .nothingToTranslate: "There is nothing to translate in the selection."
        case let .failed(failure): failure.message
        }
    }
}

/// What came of the action the person chose for a selection.
public enum TranslatorChoiceOutcome: Equatable, Sendable {
    /// The translation replaced the selection, and the clipboard is as it was.
    case inserted(TranslationDirection)
    /// It could not be put in place; it is on the clipboard instead.
    case keptOnClipboard(TranslationDirection)
    /// Copied, as asked.
    case copied(TranslationDirection)

    public var code: String {
        switch self {
        case let .inserted(direction): "inserted-\(direction.sourceCode)-\(direction.targetCode)"
        case let .keptOnClipboard(direction): "kept-on-clipboard-\(direction.sourceCode)-\(direction.targetCode)"
        case let .copied(direction): "copied-\(direction.sourceCode)-\(direction.targetCode)"
        }
    }
}

/// Why a translation did not happen, as the person is told it.
public enum TranslatorFailure: String, Error, Equatable, Sendable {
    case needsNewerMacOS = "needs-macos-26"
    case languagesMissing = "languages-missing"
    case engine

    public var message: String {
        switch self {
        case .needsNewerMacOS: "Translation on this Mac needs macOS 26 or later."
        case .languagesMissing: "Download Russian and English for translation in Translator settings."
        case .engine: "The translation failed. Try again."
        }
    }
}

/// The translation itself, behind a seam: Apple's on-device engine in the
/// application, a stand-in in the tests.
@MainActor
public protocol TranslationEngine: AnyObject {
    func translate(_ text: String, _ direction: TranslationDirection) async throws -> String
}

/// The log's words for the Translator: states and outcomes, never text.
public enum TranslatorEvent: Equatable, Sendable {
    case state(enabled: Bool, readiness: TranslatorReadiness, insertionAllowed: Bool)
    case languagesRequested
    case languagesAnswered(TranslatorReadiness)
    case shortcut(TranslatorShortcutOutcome)
    /// What the person chose for a selection brought by the shortcut.
    case choice(TranslatorChoiceOutcome)
    /// The surface closed on a selection nobody acted on: nothing replaced.
    case selectionDismissed
    case pageTranslated(TranslationDirection, failed: Bool)

    public var line: String {
        switch self {
        case let .state(enabled, readiness, insertion):
            enabled ? "translator on \(readiness.rawValue) insertion-\(insertion ? "allowed" : "not-allowed")" : "translator off"
        case .languagesRequested: "translator languages requested"
        case let .languagesAnswered(readiness): "translator languages answered \(readiness.rawValue)"
        case let .shortcut(outcome): "translator shortcut \(outcome.code)"
        case let .choice(outcome): "translator choice \(outcome.code)"
        case .selectionDismissed: "translator selection dismissed"
        case let .pageTranslated(direction, failed):
            "translator page \(direction.sourceCode)-\(direction.targetCode)\(failed ? " failed" : "")"
        }
    }

    /// What Copy Diagnostics carries: whether the Module is on, and what it
    /// lacks. Each under the 32 characters `Redaction` would rub out.
    public static func observations(enabled: Bool, readiness: TranslatorReadiness, insertionAllowed: Bool) -> [String] {
        guard enabled else { return ["translator-off"] }
        return ["translator-\(readiness.rawValue)", insertionAllowed ? "translator-ax-allowed" : "translator-ax-not-allowed"]
    }
}
