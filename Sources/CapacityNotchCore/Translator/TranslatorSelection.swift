import Foundation

// What ⌃⌥T brings to the notch (ticket 28, 2026-10-07): the selection, its
// translation and where it came from, shown on the Translator page. Nothing
// is put back into the application until the person asks for it.

/// A selection read by the shortcut, translated, waiting on the page.
public struct TranslatorSelection: Equatable, Sendable {
    /// What was selected. Shown read-only; never logged.
    public let text: String
    public private(set) var translation: String
    public private(set) var direction: TranslationDirection
    /// The application in front when the shortcut was pressed ("Telegram").
    public let sourceApplication: String?
    /// The selection is in a field that can take text in its place.
    public let isEditable: Bool

    public init(text: String, translation: String = "", direction: TranslationDirection, sourceApplication: String?, isEditable: Bool) {
        self.text = text
        self.translation = translation
        self.direction = direction
        self.sourceApplication = sourceApplication
        self.isEditable = isEditable
    }

    /// Whether the person turned it round, rather than the text deciding.
    public var isFlipped: Bool { direction != TranslationDirection.detect(text) }

    /// Turned the other way; the translation is to be made again.
    public mutating func flip() {
        direction = direction.flipped
        translation = ""
    }

    /// A translation arrives; one made for the other way, before a flip, is
    /// dropped.
    public mutating func translated(_ translation: String, for direction: TranslationDirection) {
        guard direction == self.direction else { return }
        self.translation = translation
    }

    /// What the header offers: in a field, putting the translation in place
    /// of the selection first and copying beside it; elsewhere only copying.
    public var actions: TranslatorSelectionActions {
        isEditable
            ? TranslatorSelectionActions(primary: .replace, secondary: .copy)
            : TranslatorSelectionActions(primary: .copy, secondary: nil)
    }

    /// Nothing is chosen until there is a translation to choose.
    public var canChoose: Bool { !translation.isEmpty }

    /// A key pressed while the page shows the selection: Return chooses the
    /// primary action. Anything else chooses nothing (Escape closes the
    /// surface, as it closes any pinned surface).
    public func action(for key: TranslatorKey) -> TranslatorSelectionAction? {
        guard canChoose, key == .return else { return nil }
        return actions.primary
    }

    /// Where it came from, for the header: the English format and the name to
    /// put in it. "from Telegram"; "from Safari · not a text field".
    public var provenance: (format: String, application: String?)? {
        switch (sourceApplication, isEditable) {
        case let (name?, true): ("from %@", name)
        case let (name?, false): ("from %@ · not a text field", name)
        case (nil, false): ("not a text field", nil)
        case (nil, true): nil
        }
    }
}

public enum TranslatorSelectionAction: String, Equatable, Sendable {
    /// Put the translation in place of the selection, in the application.
    case replace
    /// Copy the translation.
    case copy

    /// The button's words, in English (the page translates them).
    public var title: String {
        switch self {
        case .replace: "Paste in place of the selection"
        case .copy: "Copy"
        }
    }
}

/// The primary action is the white pill, chosen with Return too; the
/// secondary is quiet text beside it.
public struct TranslatorSelectionActions: Equatable, Sendable {
    public let primary: TranslatorSelectionAction
    public let secondary: TranslatorSelectionAction?

    public init(primary: TranslatorSelectionAction, secondary: TranslatorSelectionAction?) {
        self.primary = primary
        self.secondary = secondary
    }

    public func contains(_ action: TranslatorSelectionAction) -> Bool {
        primary == action || secondary == action
    }
}

/// The keys the Translator page answers while it shows a selection.
public enum TranslatorKey: Equatable, Sendable {
    case `return`
    case other

    /// Return, and Enter on the numeric keypad.
    public init(keyCode: UInt16) {
        self = keyCode == 36 || keyCode == 76 ? .return : .other
    }
}

/// What the Translator page shows: the field to type in, a selection the
/// shortcut brought, or why the shortcut brought none.
public enum TranslatorPageMode: Equatable, Sendable {
    case typing
    case selection(TranslatorSelection)
    /// The shortcut's message, in English.
    case problem(String)

    public var selection: TranslatorSelection? {
        if case let .selection(selection) = self { return selection }
        return nil
    }
}

/// Asking macOS for the languages, as the log hears of it: only changes.
/// The question can come back at once with the same answer — pressed again
/// and again, or refused without being shown — and a pair of lines each time
/// buried the log. The first answer is written, and after it only an answer
/// that differs from the last one written.
public struct TranslatorLanguageLog: Sendable {
    private var lastAnswer: TranslatorReadiness?
    public init() {}

    /// The lines to write for a request just answered; none if nothing changed.
    public mutating func answered(_ readiness: TranslatorReadiness) -> [TranslatorEvent] {
        guard readiness != lastAnswer else { return [] }
        lastAnswer = readiness
        return [.languagesRequested, .languagesAnswered(readiness)]
    }
}
