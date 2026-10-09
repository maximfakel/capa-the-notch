import CapacityNotchCore
import Foundation

// MARK: - Direction

func cyrillicGoesToEnglishAndLatinToRussian() throws {
    try expect(TranslationDirection.detect("Привет, как дела?") == .russianToEnglish, "Russian goes to English")
    try expect(TranslationDirection.detect("Ship the fix before Friday.") == .englishToRussian, "English goes to Russian")
    try expect(TranslationDirection.detect("Надо смержить pull request до релиза") == .russianToEnglish, "Russian with English terms is still Russian")
    try expect(TranslationDirection.detect("Deploy it to Яндекс Cloud tomorrow morning") == .englishToRussian, "English naming a Russian word is still English")
    try expect(TranslationDirection.detect("Ёжик") == .russianToEnglish, "Ё is Cyrillic")
    try expect(TranslationDirection.detect("café naïve") == .englishToRussian, "Accented Latin is Latin")
    try expect(TranslationDirection.detect("abc где") == .russianToEnglish, "A tie is Russian")
    try expect(TranslationDirection.detect("12:30 — 42 % !") == nil, "No letters, no direction")
    try expect(TranslationDirection.detect("こんにちは") == nil, "Another script alone is no direction")
    try expect(TranslationDirection.detect("") == nil, "Nothing is no direction")
    try expect(TranslationDirection.russianToEnglish.flipped == .englishToRussian, "Flipped")
    try expect(TranslationDirection.englishToRussian.sourceCode == "en" && TranslationDirection.englishToRussian.targetCode == "ru", "Codes")
}

func aFlipHoldsWhileTypingAndIsForgottenWhenEmptied() throws {
    var draft = TranslatorDraft()
    try expect(draft.direction == .russianToEnglish && !draft.isFlipped, "Empty starts Russian to English")
    draft.edit("Hello")
    try expect(draft.direction == .englishToRussian, "Detected from the text")
    draft.flip()
    try expect(draft.direction == .russianToEnglish && draft.isFlipped, "Flipped by hand")
    draft.edit("Hello there")
    try expect(draft.direction == .russianToEnglish, "The flip holds while editing")
    draft.flip()
    try expect(draft.direction == .englishToRussian && !draft.isFlipped, "Flipped back agrees with the text again")
    draft.edit("Hello")
    draft.flip()
    draft.edit("   ")
    try expect(!draft.hasText, "Whitespace is no text")
    draft.edit("Привет")
    try expect(draft.direction == .russianToEnglish && !draft.isFlipped, "Emptied, the next text is detected afresh")
}

// MARK: - Readiness and the run

func theTranslatorIsReadyOnlyWithBothWaysDownloaded() throws {
    try expect(TranslatorReadiness.from(systemSupported: false, installed: [.russianToEnglish: true, .englishToRussian: true]) == .needsNewerMacOS, "Older macOS")
    try expect(TranslatorReadiness.from(systemSupported: true, installed: nil) == .checking, "Not asked yet")
    try expect(TranslatorReadiness.from(systemSupported: true, installed: [.russianToEnglish: true, .englishToRussian: false]) == .needsLanguages, "One way missing")
    try expect(TranslatorReadiness.from(systemSupported: true, installed: [.russianToEnglish: true]) == .needsLanguages, "One way unknown")
    try expect(TranslatorReadiness.from(systemSupported: true, installed: [.russianToEnglish: true, .englishToRussian: true]) == .ready, "Both ways")
}

func theShortcutRunsOnceAtATime() throws {
    var session = TranslatorShortcutSession()
    guard let first = session.begin() else { throw TestFailure(description: "The first press begins") }
    try expect(session.begin() == nil, "A second press while one runs is not a second run")
    try expect(session.finish(first), "The run finishes once")
    try expect(!session.finish(first), "and only once")
    guard let second = session.begin() else { throw TestFailure(description: "A press after it begins again") }
    session.cancel()
    try expect(!session.finish(second), "A cancelled run's late result is dropped")
}

@MainActor
private final class FakePasteboard: TranslatorPasteboard {
    var changeCount = 1
    var items: [[String: Data]]
    var borrowed: [Bool] = []
    /// Someone else copying while the translator waits.
    var interloper: (() -> Void)?
    init(text: String?) { items = text.map { [["public.utf8-plain-text": Data($0.utf8)]] } ?? [] }
    func snapshot() -> PasteboardSnapshot { PasteboardSnapshot(items: items) }
    func restore(_ snapshot: PasteboardSnapshot) { items = snapshot.items; changeCount += 1 }
    func string() -> String? { items.first?["public.utf8-plain-text"].flatMap { String(data: $0, encoding: .utf8) } }
    func writeOwnText(_ text: String) { items = [["public.utf8-plain-text": Data(text.utf8), "own": Data()]]; changeCount += 1 }
    func setBorrowed(_ borrowed: Bool) { self.borrowed.append(borrowed) }
    func copy(_ text: String) { items = [["public.utf8-plain-text": Data(text.utf8)]]; changeCount += 1 }
}

@MainActor
private final class FakeTarget: TranslatorTarget {
    var isSecureField = false
    var isEditable = true
    var applicationName: String? = "Telegram"
    private(set) var activations = 0
    func activate() async { activations += 1 }
    var accessibilityText: String?
    /// What ⌘C copies; nil copies nothing.
    var selection: String?
    weak var pasteboard: FakePasteboard?
    var inserts = true
    private(set) var replaced: [String] = []
    private(set) var copies = 0
    func selectedTextThroughAccessibility() -> String? { accessibilityText }
    func sendCopy() { copies += 1; if let selection { pasteboard?.copy(selection) } }
    func replaceSelection(with text: String) async -> Bool {
        replaced.append(text)
        return inserts
    }
}

@MainActor
private final class FakeEngine: TranslationEngine {
    var asked: [(String, TranslationDirection)] = []
    var failure: TranslatorFailure?
    func translate(_ text: String, _ direction: TranslationDirection) async throws -> String {
        asked.append((text, direction))
        if let failure { throw failure }
        return direction == .russianToEnglish ? "EN(\(text))" : "RU(\(text))"
    }
}

@MainActor
private func quickRun(_ pasteboard: FakePasteboard) -> TranslatorShortcutRun {
    var run = TranslatorShortcutRun()
    // Each sleep lets the interloper, if any, copy; no real time passes.
    run.sleep = { _ in pasteboard.interloper?(); pasteboard.interloper = nil }
    return run
}

/// Reads through the run and returns the selection it would show.
@MainActor
private func shown(_ run: TranslatorShortcutRun, _ target: FakeTarget, _ pasteboard: FakePasteboard, _ engine: TranslationEngine = FakeEngine()) async throws -> TranslatorSelection {
    let outcome = await run.read(target: target, pasteboard: pasteboard, engine: engine, readiness: .ready)
    guard case let .shown(selection) = outcome else { throw TestFailure(description: "Shown, got \(outcome)") }
    return selection
}

@MainActor
func aSelectionReadThroughAccessibilityIsReplacedAndTheClipboardPutBack() async throws {
    let pasteboard = FakePasteboard(text: "what I copied earlier")
    let target = FakeTarget(); target.accessibilityText = "Привет"; target.pasteboard = pasteboard
    let run = quickRun(pasteboard)
    let selection = try await shown(run, target, pasteboard)
    try expect(selection.text == "Привет" && selection.translation == "EN(Привет)" && selection.direction == .russianToEnglish, "Read and translated")
    try expect(selection.sourceApplication == "Telegram" && selection.isEditable, "From Telegram, in a field")
    try expect(target.copies == 0, "Accessibility read it; nothing was copied")
    try expect(target.replaced.isEmpty && pasteboard.borrowed.isEmpty, "Reading replaced nothing and did not touch the clipboard")
    let outcome = await run.choose(.replace, for: selection, target: target, pasteboard: pasteboard)
    try expect(outcome == .inserted(.russianToEnglish), "Inserted, got \(String(describing: outcome))")
    try expect(target.activations == 1, "The application was brought back in front first")
    try expect(target.replaced == ["EN(Привет)"], "The translation replaced the selection")
    try expect(pasteboard.string() == "what I copied earlier", "The clipboard is as it was, got \(pasteboard.string() ?? "nil")")
    try expect(pasteboard.borrowed == [true, false], "Borrowed while the translation passed through it")
}

@MainActor
func whereAccessibilityCannotReadTheSelectionItIsCopiedAndTheClipboardPutBack() async throws {
    let pasteboard = FakePasteboard(text: "earlier")
    let target = FakeTarget(); target.selection = "Ship it"; target.pasteboard = pasteboard
    let engine = FakeEngine()
    let run = quickRun(pasteboard)
    let selection = try await shown(run, target, pasteboard, engine)
    try expect(target.copies == 1, "⌘C once")
    try expect(engine.asked.map(\.0) == ["Ship it"], "The copied selection was translated")
    try expect(pasteboard.string() == "earlier", "The clipboard is as it was after reading")
    try expect(pasteboard.borrowed == [true, false], "Borrowed for the copy")
    let outcome = await run.choose(.replace, for: selection, target: target, pasteboard: pasteboard)
    try expect(outcome == .inserted(.englishToRussian), "Inserted, got \(String(describing: outcome))")
    try expect(pasteboard.string() == "earlier", "The clipboard is as it was")
    try expect(pasteboard.borrowed == [true, false, true, false], "Borrowed for the copy and for the paste")
}

@MainActor
func aTranslationThatCannotBePutInPlaceStaysOnTheClipboard() async throws {
    let pasteboard = FakePasteboard(text: "earlier")
    let target = FakeTarget(); target.accessibilityText = "Hello"; target.inserts = false
    let run = quickRun(pasteboard)
    let selection = try await shown(run, target, pasteboard)
    let outcome = await run.choose(.replace, for: selection, target: target, pasteboard: pasteboard)
    try expect(outcome == .keptOnClipboard(.englishToRussian), "Kept on the clipboard, got \(String(describing: outcome))")
    try expect(pasteboard.string() == "RU(Hello)", "The translation is on the clipboard, not lost")
}

@MainActor
func somethingCopiedMeanwhileIsNotOverwrittenByTheRestore() async throws {
    let pasteboard = FakePasteboard(text: "earlier")
    let target = FakeTarget(); target.accessibilityText = "Hello"
    let run = quickRun(pasteboard)
    let selection = try await shown(run, target, pasteboard)
    pasteboard.interloper = { pasteboard.copy("the person's newer copy") }
    let outcome = await run.choose(.replace, for: selection, target: target, pasteboard: pasteboard)
    try expect(outcome == .inserted(.englishToRussian), "Inserted")
    try expect(pasteboard.string() == "the person's newer copy", "The newer copy stays, got \(pasteboard.string() ?? "nil")")
}

// MARK: - The selection on the page (2026-10-07)

@MainActor
func theShortcutReplacesNothingUntilThePersonAsks() async throws {
    let pasteboard = FakePasteboard(text: "earlier")
    let target = FakeTarget(); target.accessibilityText = "Привет"; target.pasteboard = pasteboard
    let before = pasteboard.changeCount
    let outcome = await quickRun(pasteboard).read(target: target, pasteboard: pasteboard, engine: FakeEngine(), readiness: .ready)
    guard case .shown = outcome else { throw TestFailure(description: "Shown, got \(outcome)") }
    try expect(target.replaced.isEmpty && target.activations == 0, "Nothing replaced by the shortcut itself")
    try expect(pasteboard.changeCount == before && pasteboard.string() == "earlier", "The clipboard untouched")
}

@MainActor
func aSelectionInAFieldOffersPastingInPlaceFirst() async throws {
    let pasteboard = FakePasteboard(text: "earlier")
    let target = FakeTarget(); target.accessibilityText = "Привет"; target.applicationName = "Telegram"
    let selection = try await shown(quickRun(pasteboard), target, pasteboard)
    try expect(selection.actions == TranslatorSelectionActions(primary: .replace, secondary: .copy), "Paste in place first, copy beside it")
    try expect(selection.provenance?.format == "from %@" && selection.provenance?.application == "Telegram", "From Telegram")
    try expect(Localization.text("Paste in place of the selection", in: .russian) == "Вставить вместо выделенного", "The pill, in Russian")
    try expect(String(format: Localization.text("from %@", in: .russian), "Telegram") == "из Telegram", "The header, in Russian")
}

@MainActor
func aSelectionToReadOffersOnlyCopying() async throws {
    let pasteboard = FakePasteboard(text: "earlier")
    let target = FakeTarget(); target.accessibilityText = "Ship it"; target.isEditable = false; target.applicationName = "Safari"
    let run = quickRun(pasteboard)
    let selection = try await shown(run, target, pasteboard)
    try expect(selection.actions == TranslatorSelectionActions(primary: .copy, secondary: nil), "Only copying")
    try expect(selection.provenance?.format == "from %@ · not a text field", "Says it is not a field")
    try expect(String(format: Localization.text("from %@ · not a text field", in: .russian), "Safari") == "из Safari · не поле ввода", "In Russian")
    let replaced = await run.choose(.replace, for: selection, target: target, pasteboard: pasteboard)
    try expect(replaced == nil && target.replaced.isEmpty && target.activations == 0, "Replacing outside a field is never tried")
    let copied = await run.choose(.copy, for: selection, target: target, pasteboard: pasteboard)
    try expect(copied == .copied(.englishToRussian), "Copied, got \(String(describing: copied))")
    try expect(pasteboard.string() == "RU(Ship it)", "The translation is on the clipboard, as asked")
    try expect(pasteboard.items.first?["own"] != nil, "Marked as CapaTheNotch's own, so the Shelf does not keep it")
    try expect(pasteboard.borrowed.isEmpty, "Nothing borrowed to copy")
    try expect(TranslatorSelection(text: "Hi", direction: .englishToRussian, sourceApplication: nil, isEditable: false).provenance?.format == "not a text field", "No name, still says so")
}

func returnChoosesThePrimaryAction() throws {
    let field = TranslatorSelection(text: "Привет", translation: "Hello", direction: .russianToEnglish, sourceApplication: "Telegram", isEditable: true)
    try expect(field.action(for: TranslatorKey(keyCode: 36)) == .replace, "Return pastes in place, in a field")
    try expect(field.action(for: TranslatorKey(keyCode: 76)) == .replace, "Enter on the keypad too")
    try expect(field.action(for: TranslatorKey(keyCode: 53)) == nil, "Escape chooses nothing; it closes the surface")
    try expect(field.action(for: TranslatorKey(keyCode: 49)) == nil, "Space chooses nothing")
    let page = TranslatorSelection(text: "Hi", translation: "Привет", direction: .englishToRussian, sourceApplication: "Safari", isEditable: false)
    try expect(page.action(for: .return) == .copy, "Return copies, outside a field")
    var turned = field
    turned.flip()
    try expect(turned.direction == .englishToRussian && turned.isFlipped, "Flipped by hand")
    try expect(turned.action(for: .return) == nil, "Nothing to choose until translated again")
    turned.translated("Hello", for: .russianToEnglish)
    try expect(turned.translation.isEmpty, "A translation for the old way is dropped")
    turned.translated("Привет", for: .englishToRussian)
    try expect(turned.action(for: .return) == .replace, "Translated again, Return chooses")
}

@MainActor
func shortcutProblemsAreSaidOnThePage() async throws {
    try expect(TranslatorShortcutOutcome.nothingSelected.message(accessibilityAllowed: true) == "Select text to translate first.", "Nothing selected")
    try expect(TranslatorShortcutOutcome.nothingSelected.message(accessibilityAllowed: false) == "Allow Accessibility in Translator settings to translate a selection.", "Without Accessibility")
    try expect(TranslatorShortcutOutcome.secureField.message(accessibilityAllowed: true) == "Password fields are not translated.", "Password field")
    try expect(TranslatorShortcutOutcome.failed(.languagesMissing).message(accessibilityAllowed: true) == TranslatorFailure.languagesMissing.message, "Languages missing")
    let selection = TranslatorSelection(text: "x", translation: "y", direction: .englishToRussian, sourceApplication: nil, isEditable: false)
    try expect(TranslatorShortcutOutcome.shown(selection).message(accessibilityAllowed: true) == nil, "A selection is no problem")
    for outcome in [TranslatorShortcutOutcome.nothingSelected, .secureField, .nothingToTranslate, .failed(.engine), .failed(.needsNewerMacOS)] {
        let message = outcome.message(accessibilityAllowed: true) ?? ""
        try expect(Localization.text(message, in: .russian) != message, "“\(message)” is said in Russian")
    }
}

func askingForLanguagesLogsOnlyChanges() throws {
    var log = TranslatorLanguageLog()
    try expect(log.answered(.needsLanguages) == [.languagesRequested, .languagesAnswered(.needsLanguages)], "The first answer is written")
    for _ in 0..<5 { try expect(log.answered(.needsLanguages).isEmpty, "The same answer again is not") }
    try expect(log.answered(.ready) == [.languagesRequested, .languagesAnswered(.ready)], "A different answer is")
}

@MainActor
func nothingSelectedLeavesTheClipboardUntouched() async throws {
    let pasteboard = FakePasteboard(text: "earlier")
    let target = FakeTarget(); target.pasteboard = pasteboard
    let engine = FakeEngine()
    let before = pasteboard.changeCount
    let outcome = await quickRun(pasteboard).read(target: target, pasteboard: pasteboard, engine: engine, readiness: .ready)
    try expect(outcome == .nothingSelected, "Nothing selected, got \(outcome)")
    try expect(pasteboard.changeCount == before && pasteboard.string() == "earlier", "The clipboard was not touched")
    try expect(engine.asked.isEmpty, "Nothing was translated")
}

@MainActor
func passwordFieldsAndUnreadyTranslatorsReadNothing() async throws {
    let pasteboard = FakePasteboard(text: "earlier")
    let secure = FakeTarget(); secure.isSecureField = true; secure.accessibilityText = "hunter2"; secure.pasteboard = pasteboard
    let engine = FakeEngine()
    let fromSecure = await quickRun(pasteboard).read(target: secure, pasteboard: pasteboard, engine: engine, readiness: .ready)
    try expect(fromSecure == .secureField, "A password field is not read")
    try expect(secure.copies == 0 && engine.asked.isEmpty, "Nothing copied or translated from it")

    let target = FakeTarget(); target.accessibilityText = "Hello"
    let missing = await quickRun(pasteboard).read(target: target, pasteboard: pasteboard, engine: engine, readiness: .needsLanguages)
    try expect(missing == .failed(.languagesMissing), "Languages missing")
    let older = await quickRun(pasteboard).read(target: target, pasteboard: pasteboard, engine: engine, readiness: .needsNewerMacOS)
    try expect(older == .failed(.needsNewerMacOS), "Older macOS")
    try expect(engine.asked.isEmpty, "Nothing translated while unready")

    let digits = FakeTarget(); digits.accessibilityText = "404"
    let fromDigits = await quickRun(pasteboard).read(target: digits, pasteboard: pasteboard, engine: engine, readiness: .ready)
    try expect(fromDigits == .nothingToTranslate, "No letters, nothing to translate")

    engine.failure = .engine
    let failed = await quickRun(pasteboard).read(target: target, pasteboard: pasteboard, engine: engine, readiness: .ready)
    try expect(failed == .failed(.engine), "An engine failure is said")
    try expect(pasteboard.string() == "earlier", "and the clipboard is as it was")
}

// MARK: - What leaves the Module

func theTranslatorTellsTheLogAndDiagnosticsStatesNeverText() throws {
    let secret = "Совершенно секретный текст"
    let events: [TranslatorEvent] = [
        .state(enabled: true, readiness: .needsLanguages, insertionAllowed: false),
        .languagesRequested, .languagesAnswered(.ready),
        .shortcut(.shown(TranslatorSelection(text: secret, translation: secret, direction: .russianToEnglish, sourceApplication: "Telegram", isEditable: true))),
        .shortcut(.failed(.engine)),
        .choice(.inserted(.russianToEnglish)), .choice(.keptOnClipboard(.englishToRussian)), .choice(.copied(.englishToRussian)),
        .selectionDismissed,
        .pageTranslated(.englishToRussian, failed: true),
    ]
    for event in events {
        let entry = DiagnosticEvent.translator(event).entry(at: Date(timeIntervalSince1970: 0))
        try expect(!entry.contains(secret) && !entry.contains("redacted"), "A log line is states only: \(entry)")
        try expect(entry.unicodeScalars.allSatisfy(\.isASCII), "A log line carries no text in another script: \(entry)")
    }
    try expect(DiagnosticEvent.translator(.choice(.inserted(.russianToEnglish))).line == "translator choice inserted-ru-en", "The words")
    let shown = TranslatorShortcutOutcome.shown(TranslatorSelection(text: secret, direction: .englishToRussian, sourceApplication: "Safari", isEditable: false))
    try expect(DiagnosticEvent.translator(.shortcut(shown)).line == "translator shortcut shown-en-ru-not-field", "States only, got \(DiagnosticEvent.translator(.shortcut(shown)).line)")
    try expect(TranslatorEvent.observations(enabled: false, readiness: .ready, insertionAllowed: true) == ["translator-off"], "Off says only off")
    let on = TranslatorEvent.observations(enabled: true, readiness: .needsLanguages, insertionAllowed: false)
    try expect(on == ["translator-needs-languages", "translator-ax-not-allowed"], "On says what it lacks, got \(on)")
    try expect(on.allSatisfy { $0.count < 32 }, "Each under Redaction's 32 characters")
}

func theTranslatorIsOffUntilTurnedOnWithItsOwnShortcut() throws {
    let suite = "translator-test-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = Preferences(defaults: defaults)
    try expect(!preferences.translatorEnabled, "Off until turned on (ADR 0003)")
    try expect(preferences.translatorShortcut.display == "⌃⌥T", "⌃⌥T by default, got \(preferences.translatorShortcut.display)")
    try expect(preferences.translatorShortcut != preferences.dictationShortcut, "Not Dictation's")
    try expect(!TeleprompterShortcuts.standard.values.contains(preferences.translatorShortcut), "Not the Teleprompter's")
    preferences.translatorEnabled = true
    preferences.translatorShortcut = KeyShortcut(keyCode: 17, modifiers: [.control, .option, .shift], keyLabel: "T")
    let again = Preferences(defaults: defaults)
    try expect(again.translatorEnabled && again.translatorShortcut.display == "⌃⌥⇧T", "Remembered")
    try expect(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("translator.") }.sorted() == ["translator.enabled", "translator.shortcut"], "Nothing translated is kept")
}

func theTranslatorsPageComesLast() throws {
    try expect(SurfacePageOrder.pages(music: true, teleprompter: true, shelf: true, translator: true) == [.capacity, .music, .teleprompter, .shelf, .translator], "Last, as it arrived last")
    try expect(SurfacePageOrder.pages(music: false, teleprompter: false, translator: true) == [.capacity, .translator], "Beside Capacity alone")
    try expect(SurfacePageOrder.pages(music: true, teleprompter: false) == [.capacity, .music], "Off, no page")
}

func theTranslatorSpeaksRussian() throws {
    for (english, russian) in Localization.translatorRussian {
        try expect(english.components(separatedBy: "%@").count == russian.components(separatedBy: "%@").count, "“\(english)” keeps its arguments")
        try expect(!russian.isEmpty, "“\(english)” must not translate to nothing")
    }
    try expect(Localization.text("Translator", in: .russian) == "Переводчик", "The Module's name")
    for failure in [TranslatorFailure.needsNewerMacOS, .languagesMissing, .engine] {
        try expect(Localization.text(failure.message, in: .russian) != failure.message, "“\(failure.message)” is translated")
    }
}
