import Foundation

/// Everything on the clipboard at one moment, each item as its types and
/// their bytes, so it can be put back as it was — text, an image, a file.
public struct PasteboardSnapshot: Equatable, Sendable {
    public var items: [[String: Data]]
    public init(items: [[String: Data]]) { self.items = items }
}

/// The clipboard, as the translator borrows it.
@MainActor
public protocol TranslatorPasteboard: AnyObject {
    /// Moves on with every write, by anyone.
    var changeCount: Int { get }
    func snapshot() -> PasteboardSnapshot
    func restore(_ snapshot: PasteboardSnapshot)
    /// The plain text there now, if any.
    func string() -> String?
    /// Writes text marked as CapaTheNotch's own, so the Shelf does not keep
    /// it (ADR 0005).
    func writeOwnText(_ text: String)
    /// While borrowed, what passes through the clipboard is the
    /// translator's, and the Shelf keeps none of it — neither the selection
    /// copied to be read nor what is put back after (ADR 0005).
    func setBorrowed(_ borrowed: Bool)
}

/// The application in front when the shortcut was pressed, as the
/// translator reads its selection and, when asked, replaces it.
@MainActor
public protocol TranslatorTarget: AnyObject {
    /// The focused field is a password field: nothing is read from it.
    var isSecureField: Bool { get }
    /// The selection is in a field that can take text in its place.
    var isEditable: Bool { get }
    /// The application's name, for the page's header ("Telegram").
    var applicationName: String? { get }
    /// The selection as Accessibility reports it; nil where it does not.
    func selectedTextThroughAccessibility() -> String?
    /// Sends ⌘C to the application in front.
    func sendCopy()
    /// Brings the application back in front, its field focused again: the
    /// surface held the keyboard while the person chose.
    func activate() async
    /// Replaces the selection with the text, in place; true only when that
    /// was done (or the paste was sent to the same field). The translation
    /// is on the clipboard while this runs.
    func replaceSelection(with text: String) async -> Bool
}

/// The shortcut's run, in two halves with the person between them.
///
/// `read` takes the selection, translates it and hands it to the page; it
/// never writes into the application. `choose` does what the person picked
/// on the page: copy, or put the translation in place of the selection.
///
/// The clipboard is borrowed twice at most — to copy the selection where
/// Accessibility cannot read it, and to paste the translation where it
/// cannot write it — and each time put back, unless someone else wrote to it
/// meanwhile: then theirs is newer, and stays. Only when the translation
/// could not be put in place does it stay on the clipboard, as Dictation's
/// text does, so it is not lost.
@MainActor
public struct TranslatorShortcutRun {
    public var copyWait: Duration = .milliseconds(400)
    public var pollEvery: Duration = .milliseconds(20)
    /// Long enough for the application to take the paste before the
    /// clipboard is put back.
    public var restoreAfter: Duration = .milliseconds(600)
    public var sleep: @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }

    public init() {}

    /// Reads the selection and translates it, for the page. Nothing in the
    /// application changes.
    public func read(
        target: TranslatorTarget,
        pasteboard: TranslatorPasteboard,
        engine: TranslationEngine,
        readiness: TranslatorReadiness
    ) async -> TranslatorShortcutOutcome {
        switch readiness {
        case .needsNewerMacOS: return .failed(.needsNewerMacOS)
        case .needsLanguages, .checking: return .failed(.languagesMissing)
        case .ready: break
        }
        guard !target.isSecureField else { return .secureField }
        guard let text = await selection(target: target, pasteboard: pasteboard),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .nothingSelected }
        guard let direction = TranslationDirection.detect(text) else { return .nothingToTranslate }

        let translation: String
        do { translation = try await engine.translate(text, direction) } catch {
            return .failed((error as? TranslatorFailure) ?? .engine)
        }
        guard !translation.isEmpty else { return .failed(.engine) }
        return .shown(TranslatorSelection(
            text: text, translation: translation, direction: direction,
            sourceApplication: target.applicationName, isEditable: target.isEditable
        ))
    }

    /// Does what the person chose on the page. Nil when the selection does
    /// not offer that action, or has no translation yet: replacing text that
    /// is not in a field is never tried.
    public func choose(
        _ action: TranslatorSelectionAction,
        for selection: TranslatorSelection,
        target: TranslatorTarget,
        pasteboard: TranslatorPasteboard
    ) async -> TranslatorChoiceOutcome? {
        guard selection.canChoose, selection.actions.contains(action) else { return nil }
        let translation = selection.translation, direction = selection.direction
        switch action {
        case .copy:
            // Asked for, so it stays; marked as CapaTheNotch's own, so the
            // Shelf does not keep it either (ADR 0005).
            pasteboard.writeOwnText(translation)
            return .copied(direction)
        case .replace:
            await target.activate()
            pasteboard.setBorrowed(true)
            defer { pasteboard.setBorrowed(false) }
            let before = pasteboard.snapshot()
            pasteboard.writeOwnText(translation)
            let ours = pasteboard.changeCount
            guard await target.replaceSelection(with: translation) else { return .keptOnClipboard(direction) }
            await sleep(restoreAfter)
            if pasteboard.changeCount == ours { pasteboard.restore(before) }
            return .inserted(direction)
        }
    }

    /// Accessibility first; where an editor does not say what is selected,
    /// ⌘C, read, and the clipboard put back.
    func selection(target: TranslatorTarget, pasteboard: TranslatorPasteboard) async -> String? {
        if let text = target.selectedTextThroughAccessibility(), !text.isEmpty { return text }
        pasteboard.setBorrowed(true)
        defer { pasteboard.setBorrowed(false) }
        let before = pasteboard.snapshot()
        let start = pasteboard.changeCount
        target.sendCopy()
        var waited: Duration = .zero
        while pasteboard.changeCount == start, waited < copyWait {
            await sleep(pollEvery); waited += pollEvery
        }
        // Nothing copied: nothing was selected, and nothing needs putting back.
        guard pasteboard.changeCount != start else { return nil }
        let copied = pasteboard.string()
        pasteboard.restore(before)
        return copied
    }
}
