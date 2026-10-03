import AppKit
import Carbon.HIToolbox
import CapacityNotchCore
import Combine
import CoreText

/// The Teleprompter Module (ticket 16), as the application runs it: the Script
/// laid out into lines for the row, the playback moving over them, and the
/// global shortcuts. Off, it registers nothing and shows nothing (ADR 0003).
@MainActor
final class TeleprompterController: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var script: String
    @Published private(set) var hasPreviousScript: Bool
    @Published private(set) var textSize: TeleprompterTextSize
    @Published private(set) var lines: [String] = []
    @Published private(set) var playback: TeleprompterPlayback
    /// Shortcuts macOS would not register, usually because something else
    /// holds them. Settings says so on the card.
    @Published private(set) var unavailableShortcuts: Set<TeleprompterAction> = []

    /// Edit Script on the page opens Settings at the Modules section.
    var openSettings: () -> Void = {}

    private let preferences: Preferences
    /// False only for the stand-in the pictures are drawn with.
    private let registersShortcuts: Bool
    private let hotKeys = HotKeys()
    private var timer: Timer?

    init(preferences: Preferences, registersShortcuts: Bool = true) {
        self.preferences = preferences
        self.registersShortcuts = registersShortcuts
        isEnabled = preferences.teleprompterEnabled
        script = preferences.script
        hasPreviousScript = preferences.previousScript != nil
        textSize = preferences.teleprompterTextSize
        playback = TeleprompterPlayback(wordCount: 0, lineCount: 0, multiplier: preferences.teleprompterMultiplier)
        relayout()
        if isEnabled { registerShortcuts() }
    }

    var wordCount: Int { playback.wordCount }

    /// Whether the Teleprompter Row is in view: the Module on and the Script
    /// running, paused or just finished.
    var isShowingRow: Bool { isEnabled && playback.isShowing }

    /// What the pictures are drawn with: the mockup's own words.
    static let sampleScript = """
    Добрый день. Сегодня я покажу, как Capacity Notch держит лимиты Claude и Codex прямо у камеры, и почему это удобнее, чем вкладка со счётчиком, открытая весь день.

    Сначала — как выглядит полоса. Потом — что происходит, когда лимит подходит к концу.
    """

    // MARK: - The Module

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        preferences.teleprompterEnabled = enabled
        if enabled {
            isEnabled = true
            registerShortcuts()
        } else {
            // Stopped before it is off: off, nothing runs — not even the
            // timer waiting for the Script's end (ADR 0003).
            playback.stop()
            schedule()
            isEnabled = false
            hotKeys.unregisterAll()
            unavailableShortcuts = []
        }
    }

    // MARK: - The Script

    /// Typing in Settings changes the Script itself; only Paste keeps the one
    /// before.
    func edit(_ text: String) {
        guard text != script else { return }
        preferences.script = text
        script = text
        relayout()
    }

    /// Reads the clipboard now, and only now.
    func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        preferences.replaceScript(with: text)
        scriptChanged()
    }

    func restorePreviousScript() {
        preferences.restorePreviousScript()
        scriptChanged()
    }

    private func scriptChanged() {
        script = preferences.script
        hasPreviousScript = preferences.previousScript != nil
        playback.stop()
        relayout()
    }

    func setTextSize(_ size: TeleprompterTextSize) {
        preferences.teleprompterTextSize = size
        textSize = size
        relayout()
    }

    // MARK: - Playback

    func toggle() { change { $0.toggle(at: Date()) } }
    func stop() { change { $0.stop() } }
    func faster() { change { $0.faster(at: Date()) } }
    func slower() { change { $0.slower(at: Date()) } }
    func seek(toFraction fraction: Double) { change { $0.seek(toFraction: fraction, at: Date()) } }
    func move(byLines lines: Double) { change { $0.move(byLines: lines, at: Date()) } }


    private func change(_ body: (inout TeleprompterPlayback) -> Void) {
        guard isEnabled else { return }
        let speed = playback.multiplier
        body(&playback)
        if playback.multiplier != speed { preferences.teleprompterMultiplier = playback.multiplier }
        schedule()
    }

    /// Wakes when the Script reaches its end, and again when its row leaves;
    /// nothing ticks in between — the row's motion is Core Animation's.
    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard let next = playback.endsAt ?? playback.leavesAt else { return }
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.playback.advance(to: Date())
                self.schedule()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func relayout() {
        lines = TeleprompterLayout.lines(script, size: textSize)
        playback.relayout(
            wordCount: TeleprompterScript.wordCount(script),
            lineCount: lines.count,
            at: Date()
        )
        schedule()
    }

    // MARK: - Shortcuts

    func shortcut(for action: TeleprompterAction) -> KeyShortcut? {
        preferences.teleprompterShortcut(for: action)
    }

    /// A shortcut already given to another of the four trades places with
    /// it: one key, one action.
    func setShortcut(_ shortcut: KeyShortcut, for action: TeleprompterAction) {
        if let other = TeleprompterAction.allCases.first(where: { $0 != action && self.shortcut(for: $0).map(Self.sameKeys(shortcut)) == true }),
           let previous = self.shortcut(for: action) {
            preferences.setTeleprompterShortcut(previous, for: other)
        }
        preferences.setTeleprompterShortcut(shortcut, for: action)
        objectWillChange.send()
        if isEnabled { registerShortcuts() }
    }

    private static func sameKeys(_ a: KeyShortcut) -> (KeyShortcut) -> Bool {
        { b in a.keyCode == b.keyCode && a.modifiers == b.modifiers }
    }

    /// While Settings records a new shortcut, the old ones stand aside, or
    /// pressing one would work it rather than record it.
    private var shortcutsSuspended = false
    func suspendShortcuts(_ suspended: Bool) {
        shortcutsSuspended = suspended
        guard isEnabled else { return }
        if suspended { hotKeys.unregisterAll() } else { registerShortcuts() }
    }

    private func registerShortcuts() {
        guard registersShortcuts else { return }
        hotKeys.unregisterAll()
        guard !shortcutsSuspended, isEnabled else { return }
        var unavailable: Set<TeleprompterAction> = []
        for action in TeleprompterAction.allCases {
            guard let shortcut = shortcut(for: action) else { continue }
            let registered = hotKeys.register(shortcut) { [weak self] in
                guard let self else { return }
                switch action {
                case .startOrPause: self.toggle()
                case .stop: self.stop()
                case .faster: self.faster()
                case .slower: self.slower()
                }
            }
            if !registered { unavailable.insert(action) }
        }
        unavailableShortcuts = unavailable
    }
}

// MARK: - Layout

/// The row's type and rhythm, from Paper "Notch — Compact — Teleprompter":
/// Geist Medium, 17 on 22 at the mockup's size, lines two points apart, a
/// little tighter tracked, set in after the controls' column.
enum TeleprompterLayout {
    static let rowWidth: CGFloat = 560
    /// The controls' column on the left, 15 points and 12 to the text.
    static let controlsWidth: CGFloat = 15
    static let controlsGap: CGFloat = 12
    static let textInset: CGFloat = 18 + controlsWidth + controlsGap
    static let textWidth: CGFloat = rowWidth - textInset - 18
    static let lineGap: CGFloat = 2
    static let topInset: CGFloat = 2
    static let bottomInset: CGFloat = 16
    /// Between the strip and the first line, as in the music row.
    static let stripGap: CGFloat = 6
    /// The open page's lines: under them stand the progress and controls.
    static let visibleLines = 3

    /// The Teleprompter Row's lines: as many as its room holds. The row was
    /// made as tall as an open page so the surface keeps its height opening
    /// and closing, and three lines left the lower half of it dark; it now
    /// shows what comes next there — six lines at the smaller sizes, five
    /// at the largest. The line read is still the top one, by the camera.
    static func rowLines(_ size: TeleprompterTextSize) -> Int {
        let room = NotchGeometry.compactTeleprompterRow - stripGap - topInset - bottomInset + lineGap
        return max(visibleLines, Int(room / pitch(size)))
    }

    /// How bright each line in view is, from the one read down: the drawing's
    /// three — #FFF, #FFFFFF8C, #FFFFFF40 — then quieter still, so the eye
    /// stays at the top.
    static func lineOpacity(_ row: Int) -> Double {
        switch row {
        case ..<1: 1
        case 1: 0x8C / 255.0
        case 2: 0x40 / 255.0
        default: max(0x40 / 255.0 * pow(0.82, Double(row - 2)), 0.1)
        }
    }

    static func font(_ size: TeleprompterTextSize) -> NSFont {
        SurfaceType.geistNSFont(size.points, .medium)
    }

    static func lineHeight(_ size: TeleprompterTextSize) -> CGFloat {
        (size.points * 1.3).rounded()
    }

    static func pitch(_ size: TeleprompterTextSize) -> CGFloat {
        lineHeight(size) + lineGap
    }

    static func kern(_ size: TeleprompterTextSize) -> CGFloat {
        -0.01 * size.points
    }

    /// The row's text area under the strip: its lines and their insets.
    static func textAreaHeight(_ size: TeleprompterTextSize) -> CGFloat {
        let lines = rowLines(size)
        return topInset + CGFloat(lines) * lineHeight(size) + CGFloat(lines - 1) * lineGap + bottomInset
    }

    /// Everything the row adds under the strip: as tall as an open page and
    /// its dots, the three lines at the top and the rest left dark ("Compact
    /// — Teleprompter running"). Three lines at the largest size take 106.
    static func rowHeight(_ size: TeleprompterTextSize) -> CGFloat {
        NotchGeometry.compactTeleprompterRow
    }

    static func attributes(_ size: TeleprompterTextSize) -> [NSAttributedString.Key: Any] {
        [.font: font(size), .kern: kern(size), .foregroundColor: NSColor.white]
    }

    /// The Script broken into the lines the row shows: its own line breaks
    /// kept, blank lines kept as gaps, long lines wrapped where the type does.
    static func lines(_ script: String, size: TeleprompterTextSize, width: CGFloat = textWidth) -> [String] {
        TeleprompterScript.lines(script) { paragraph in
            let attributed = NSAttributedString(string: paragraph, attributes: attributes(size)) as CFAttributedString
            let typesetter = CTTypesetterCreateWithAttributedString(attributed)
            let length = CFAttributedStringGetLength(attributed)
            var wrapped: [String] = []
            var start = 0
            while start < length {
                let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
                guard count > 0 else { break }
                let range = NSRange(location: start, length: count)
                wrapped.append((paragraph as NSString).substring(with: range).trimmingCharacters(in: .whitespaces))
                start += count
            }
            return wrapped
        }
    }
}

// MARK: - Global shortcuts

/// Carbon's hot keys: global, and needing no Accessibility access, which a
/// keyboard monitor would. Carbon calls back on the main thread.
private final class HotKeys {
    private var references: [EventHotKeyRef] = []
    private var actions: [UInt32: @MainActor () -> Void] = [:]
    private var nextID: UInt32 = 1
    private var handler: EventHandlerRef?

    deinit {
        references.forEach { UnregisterEventHotKey($0) }
        if let handler { RemoveEventHandler(handler) }
    }

    /// False when macOS will not have it — usually because something else
    /// already does.
    func register(_ shortcut: KeyShortcut, action: @escaping @MainActor () -> Void) -> Bool {
        guard installHandlerIfNeeded() else { return false }
        let id = nextID
        nextID += 1
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            Self.carbonModifiers(shortcut.modifiers),
            EventHotKeyID(signature: Self.signature, id: id),
            GetEventDispatcherTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else { return false }
        references.append(reference)
        actions[id] = action
        return true
    }

    func unregisterAll() {
        references.forEach { UnregisterEventHotKey($0) }
        references = []
        actions = [:]
    }

    fileprivate func fire(_ id: UInt32) {
        guard let action = actions[id] else { return }
        MainActor.assumeIsolated { action() }
    }

    private func installHandlerIfNeeded() -> Bool {
        guard handler == nil else { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &id
                )
                guard status == noErr, id.signature == HotKeys.signature else { return OSStatus(eventNotHandledErr) }
                Unmanaged<HotKeys>.fromOpaque(userData).takeUnretainedValue().fire(id.id)
                return noErr
            },
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
        return status == noErr
    }

    /// "CNTP".
    static let signature: OSType = 0x434E_5450

    private static func carbonModifiers(_ modifiers: KeyShortcut.Modifiers) -> UInt32 {
        var carbon: UInt32 = 0
        if modifiers.contains(.command) { carbon |= UInt32(cmdKey) }
        if modifiers.contains(.option) { carbon |= UInt32(optionKey) }
        if modifiers.contains(.control) { carbon |= UInt32(controlKey) }
        if modifiers.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }
}
