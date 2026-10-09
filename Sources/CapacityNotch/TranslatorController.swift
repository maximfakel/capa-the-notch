@preconcurrency import ApplicationServices
import AppKit
import CapacityNotchCore
import Combine

/// The Translator Module (ticket 28): a shortcut that brings the selection,
/// translated, to the notch — to copy, or to put in its place when it was in
/// a field — and a page to type or paste into.
///
/// What is translated lives only here, in memory, while the page shows it:
/// never in Preferences, the log or Copy Diagnostics. Turning the Module off
/// forgets it.
@MainActor
final class TranslatorController: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var readiness: TranslatorReadiness {
        // Text typed while the languages arrived is translated once they have.
        didSet { if readiness == .ready, oldValue != .ready, draft.hasText { translateDraftSoon(after: .zero) } }
    }
    @Published private(set) var shortcut: KeyShortcut
    @Published private(set) var shortcutUnavailable = false
    @Published private(set) var insertionAllowed = AXIsProcessTrusted()
    @Published private(set) var draft = TranslatorDraft()
    /// What the page shows: the field, or what the shortcut brought.
    @Published private(set) var mode: TranslatorPageMode = .typing
    @Published private(set) var output = ""
    @Published private(set) var isTranslating = false
    /// The last thing worth saying, in English (the page translates it).
    @Published private(set) var notice: String?
    /// Set while macOS is being asked to download the languages; Settings
    /// hosts the system's own question (`TranslatorLanguageRequest`).
    @Published private(set) var requestingLanguages = false
    /// Asks the surface to stay open while the page's field is typed in.
    var holdSurfaceOpen: () -> Void = {}
    /// Opens the surface pinned on the Translator page, for what the
    /// shortcut brought.
    var showOnSurface: () -> Void = {}
    /// Closes the pinned surface once the person has chosen.
    var closeSurface: () -> Void = {}
    var openSettings: () -> Void = {}

    private let preferences: Preferences
    private let engine = AppleTranslationEngine()
    private let registersShortcuts: Bool
    private var hotKey: TranslatorHotKey?
    private var shortcutSuspended = false
    private var session = TranslatorShortcutSession()
    /// The application the selection came from, kept while the page shows
    /// it, so the translation can be put back there if asked.
    private var selectionTarget: FrontmostTranslatorTarget?
    private var selectionTranslation: Task<Void, Never>?
    private var choosing = false
    private var languageLog = TranslatorLanguageLog()
    private var pageTranslation: Task<Void, Never>?
    private var noticeTimer: Task<Void, Never>?
    private var observing: AnyCancellable?

    init(preferences: Preferences, registersShortcuts: Bool = true) {
        self.preferences = preferences
        self.registersShortcuts = registersShortcuts
        isEnabled = preferences.translatorEnabled && AppleTranslationEngine.isSupported
        readiness = AppleTranslationEngine.isSupported ? .checking : .needsNewerMacOS
        shortcut = preferences.translatorShortcut
        if registersShortcuts {
            observing = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
                .sink { [weak self] _ in Task { @MainActor in self?.refresh() } }
            register()
            if isEnabled { refresh() }
        }
    }

    var isSupported: Bool { AppleTranslationEngine.isSupported }

    /// Only the picture dump sets a state without translating anything; its
    /// text is synthetic.
    func preview(readiness: TranslatorReadiness, text: String = "", output: String = "", flipped: Bool = false, mode: TranslatorPageMode = .typing) {
        guard !registersShortcuts else { return }
        isEnabled = true
        self.readiness = readiness
        pageTranslation?.cancel()
        draft.edit(text)
        if flipped { draft.flip() }
        self.output = output
        self.mode = mode
    }

    /// What Copy Diagnostics says: states only.
    var observations: [String] {
        TranslatorEvent.observations(enabled: isEnabled, readiness: readiness, insertionAllowed: AXIsProcessTrusted())
    }

    func setEnabled(_ enabled: Bool) {
        // Without macOS 26 the switch stays off; the card says why.
        let enabled = enabled && isSupported
        isEnabled = enabled
        preferences.translatorEnabled = enabled
        if enabled { refresh() } else { forget() }
        register()
        DiagnosticLog.record(.translator(.state(enabled: enabled, readiness: readiness, insertionAllowed: insertionAllowed)))
    }

    /// Reads again what macOS has downloaded and what it allows.
    func refresh() {
        insertionAllowed = AXIsProcessTrusted()
        guard isEnabled else { return }
        Task { readiness = await engine.readiness() }
    }

    // MARK: - Languages and permission, asked for only when on

    /// Has macOS ask to download Russian and English; Settings shows the
    /// system's own question.
    func requestLanguages() {
        guard isEnabled, readiness == .needsLanguages, !requestingLanguages else { return }
        requestingLanguages = true
    }

    /// The system's question was answered, or could not be asked.
    func languagesAnswered() async {
        requestingLanguages = false
        readiness = await engine.readiness()
        // Only a change: the same answer again is not news (ticket 28).
        for event in languageLog.answered(readiness) { DiagnosticLog.record(.translator(event)) }
    }

    func requestInsertion() {
        guard isEnabled else { return }
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        insertionAllowed = AXIsProcessTrusted()
    }

    /// Where macOS lists and removes its translation languages.
    func openLanguageSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - The shortcut

    func setShortcut(_ shortcut: KeyShortcut) {
        self.shortcut = shortcut
        preferences.translatorShortcut = shortcut
        register()
    }

    func suspendShortcut(_ suspend: Bool) {
        shortcutSuspended = suspend
        register()
    }

    private func register() {
        guard registersShortcuts else { return }
        guard isEnabled, !shortcutSuspended else { _ = hotKey?.register(nil); return }
        if hotKey == nil {
            let key = TranslatorHotKey()
            key.pressed = { [weak self] in self?.translateSelection() }
            hotKey = key
        }
        shortcutUnavailable = !(hotKey?.register(shortcut) ?? false)
    }

    /// Reads what is selected in the application in front, translates it
    /// and opens the surface on the Translator page with it. Nothing in the
    /// application changes until the person chooses (`choose`).
    func translateSelection() {
        guard isEnabled, let id = session.begin() else { return }
        insertionAllowed = AXIsProcessTrusted()
        // The field, its selection and its text, as they are now.
        let target = FrontmostTranslatorTarget()
        let readiness = readiness
        Task { [weak self] in
            guard let self else { return }
            await FrontmostTranslatorTarget.waitForModifiersReleased()
            let outcome = await TranslatorShortcutRun().read(
                target: target, pasteboard: SystemTranslatorPasteboard(), engine: engine, readiness: readiness
            )
            guard session.finish(id) else { return }
            DiagnosticLog.record(.translator(.shortcut(outcome)))
            selectionTranslation?.cancel()
            if case let .shown(selection) = outcome {
                selectionTarget = target
                mode = .selection(selection)
            } else {
                selectionTarget = nil
                mode = .problem(outcome.message(accessibilityAllowed: insertionAllowed) ?? "")
                NSSound.beep()
                if outcome == .failed(.languagesMissing) { refresh() }
            }
            showOnSurface()
        }
    }

    /// Return on the page: the primary action, while a selection is shown.
    func handleKey(_ keyCode: UInt16) -> Bool {
        guard let selection = mode.selection, let action = selection.action(for: TranslatorKey(keyCode: keyCode)) else { return false }
        choose(action)
        return true
    }

    /// What the person chose for the selection: copy, or put the
    /// translation in its place. The surface closes either way.
    func choose(_ action: TranslatorSelectionAction) {
        guard !choosing, let selection = mode.selection, let target = selectionTarget else { return }
        choosing = true
        let run = TranslatorShortcutRun(), pasteboard = SystemTranslatorPasteboard()
        Task { [weak self] in
            guard let self else { return }
            defer { choosing = false }
            if action == .replace {
                // The surface held the keyboard; it lets go before the
                // application is brought back in front.
                mode = .typing
                selectionTarget = nil
                closeSurface()
            }
            guard let outcome = await run.choose(action, for: selection, target: target, pasteboard: pasteboard) else { return }
            DiagnosticLog.record(.translator(.choice(outcome)))
            switch outcome {
            case .inserted: break
            case .copied:
                mode = .typing
                selectionTarget = nil
                closeSurface()
            case .keptOnClipboard:
                NSSound.beep()
                mode = .problem("The translation could not be put in place. It is on the clipboard.")
                showOnSurface()
            }
        }
    }

    /// The surface closed. A selection nobody acted on is let go: nothing
    /// was replaced, and the page is the field again next time.
    func surfaceClosed() {
        guard !choosing else { return }
        if mode.selection != nil { DiagnosticLog.record(.translator(.selectionDismissed)) }
        selectionTranslation?.cancel()
        selectionTarget = nil
        mode = .typing
    }

        // MARK: - The page

    func edit(_ text: String) {
        draft.edit(text)
        translateDraftSoon()
    }

    func flip() {
        if var selection = mode.selection {
            selection.flip()
            mode = .selection(selection)
            translateSelectionAgain(selection)
            return
        }
        draft.flip()
        translateDraftSoon(after: .zero)
    }

    /// The selection turned the other way, translated again.
    private func translateSelectionAgain(_ selection: TranslatorSelection) {
        selectionTranslation?.cancel()
        let text = selection.text, direction = selection.direction
        isTranslating = true
        selectionTranslation = Task { [weak self] in
            guard let self else { return }
            do {
                let translated = try await engine.translate(text, direction)
                guard !Task.isCancelled, var current = mode.selection, current.text == text else { return }
                current.translated(translated, for: direction)
                mode = .selection(current)
                DiagnosticLog.record(.translator(.pageTranslated(direction, failed: false)))
            } catch {
                guard !Task.isCancelled else { return }
                DiagnosticLog.record(.translator(.pageTranslated(direction, failed: true)))
                say(((error as? TranslatorFailure) ?? .engine).message)
            }
            isTranslating = false
        }
    }

    func clear() {
        pageTranslation?.cancel()
        draft.edit("")
        output = ""
        isTranslating = false
    }

    func copyOutput() {
        guard !output.isEmpty else { return }
        OwnClipboard.copy(output)
        say("Copied")
    }

    /// A pause in typing, then the translation; each keystroke starts over.
    private func translateDraftSoon(after delay: Duration = .milliseconds(450)) {
        pageTranslation?.cancel()
        guard draft.hasText else { output = ""; isTranslating = false; return }
        guard readiness == .ready else { return }
        let text = draft.text, direction = draft.direction
        pageTranslation = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self else { return }
            isTranslating = true
            do {
                let translated = try await engine.translate(text, direction)
                guard !Task.isCancelled else { return }
                output = translated
                DiagnosticLog.record(.translator(.pageTranslated(direction, failed: false)))
            } catch {
                guard !Task.isCancelled else { return }
                DiagnosticLog.record(.translator(.pageTranslated(direction, failed: true)))
                let failure = (error as? TranslatorFailure) ?? .engine
                say(failure.message)
                if failure == .languagesMissing { refresh() }
            }
            isTranslating = false
        }
    }

    private func say(_ message: String) {
        notice = message
        noticeTimer?.cancel()
        noticeTimer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            self?.notice = nil
        }
    }

    /// Off: the shortcut goes, and so does whatever the page held.
    private func forget() {
        session.cancel()
        selectionTranslation?.cancel()
        selectionTarget = nil
        mode = .typing
        clear()
        notice = nil
        requestingLanguages = false
    }
}
