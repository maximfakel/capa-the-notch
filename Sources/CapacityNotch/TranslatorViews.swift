import AppKit
import CapacityNotchCore
import SwiftUI
@preconcurrency import Translation

// Paper, file CapaTheNotch, page Notch: "Notch — Expanded — Translator",
// "… Translator, selection in a field" and "… Translator, selection to
// read". Geist on black, 18-point margins, inside the 152 points every open
// page has (`.scratch/surface-210`).

/// The translator's page on the open surface: text on the left, the
/// translation on the right, the direction above them. Typed or pasted by
/// hand, or brought by the shortcut from another application, with what can
/// be done with it.
struct TranslatorPage: View {
    @ObservedObject var translator: TranslatorController

    private static let muted = Color.white.opacity(0x8C / 255)
    private static let faint = Color.white.opacity(0x59 / 255)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch translator.mode {
            case let .selection(selection):
                selectionHeader(selection)
                HStack(spacing: 12) {
                    selected(selection)
                    translation(selection)
                }
                .frame(height: 108)
            case let .problem(message):
                header
                problem(message)
            case .typing:
                header
                if translator.readiness == .ready {
                    HStack(spacing: 12) {
                        input
                        result
                    }
                    .frame(height: 108)
                } else {
                    unavailable
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .foregroundStyle(.white)
    }

    // MARK: - Header

    private func direction(_ direction: TranslationDirection) -> some View {
        Button(action: translator.flip) {
            HStack(spacing: 10) {
                Text(direction.label)
                    .font(SurfaceType.geist(15, .semibold))
                Image(systemName: "arrow.right.arrow.left")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Self.muted)
            }
            .contentShape(Rectangle())
        }
        .disabled(translator.readiness != .ready)
        .help(L("Translate the other way"))
        .accessibilityLabel(L("Direction"))
        .accessibilityValue(direction == .russianToEnglish ? L("Russian to English") : L("English to Russian"))
        .accessibilityHint(L("Translate the other way"))
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(SurfaceType.geist(12))
            .foregroundStyle(Self.faint)
            .lineLimit(1)
    }

    private var header: some View {
        HStack(spacing: 10) {
            direction(translator.draft.direction)
            caption(stateLine)
            Spacer(minLength: 0)
            if translator.readiness == .ready, translator.mode == .typing {
                HStack(spacing: 16) {
                    Button(L("Clear"), action: translator.clear)
                        .disabled(!translator.draft.hasText)
                        .foregroundStyle(Self.muted)
                    Button(L("Copy"), action: translator.copyOutput)
                        .disabled(translator.output.isEmpty)
                        .foregroundStyle(translator.output.isEmpty ? Self.muted : .white)
                }
                .font(SurfaceType.geist(13, .medium))
            }
        }
        .buttonStyle(.plain)
        .frame(height: 18)
    }

    /// What is happening, or what the shortcut said last.
    private var stateLine: String {
        if let notice = translator.notice { return L(notice) }
        if translator.isTranslating { return L("Translating…") }
        if translator.draft.isFlipped { return L("Turned round") }
        return L("%@ translates a selection", translator.shortcut.display)
    }

    /// The direction, where the text came from, and what can be done with
    /// it: the white pill is what Return does.
    private func selectionHeader(_ selection: TranslatorSelection) -> some View {
        HStack(spacing: 10) {
            direction(selection.direction)
            caption(selectionLine(selection))
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                if let secondary = selection.actions.secondary {
                    Button(L(secondary.title)) { translator.choose(secondary) }
                        .font(SurfaceType.geist(13, .medium))
                        .foregroundStyle(Self.muted)
                }
                Button { translator.choose(selection.actions.primary) } label: {
                    HStack(spacing: 6) {
                        Text(L(selection.actions.primary.title))
                            .font(SurfaceType.geist(13, .semibold))
                            .foregroundStyle(.black)
                        Text("⏎")
                            .font(SurfaceType.geist(12, .medium))
                            .foregroundStyle(Color.black.opacity(0.5))
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background(Color.white, in: Capsule())
                    .contentShape(Capsule())
                }
                .accessibilityHint(L("Press Return"))
            }
            .disabled(!selection.canChoose)
            .opacity(selection.canChoose ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .frame(height: 18)
    }

    private func selectionLine(_ selection: TranslatorSelection) -> String {
        if let notice = translator.notice { return L(notice) }
        if translator.isTranslating { return L("Translating…") }
        guard let provenance = selection.provenance else { return "" }
        if let application = provenance.application { return L(provenance.format, application) }
        return L(provenance.format)
    }

    // MARK: - Boxes

    /// Twelve-point corners, 14-point text on 19, as drawn.
    private func box<Content: View>(_ fill: Double, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.white.opacity(fill / 255), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func boxText(_ text: String, colour: Color) -> some View {
        ScrollView {
            Text(text)
                .font(SurfaceType.geist(14))
                .lineSpacing(2)
                .foregroundStyle(colour)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .scrollIndicators(.never)
    }

    /// What was selected, read-only and quiet: the translation is the point.
    private func selected(_ selection: TranslatorSelection) -> some View {
        box(0x0A) { boxText(selection.text, colour: Self.muted) }
            .accessibilityLabel(L("Selected text"))
    }

    private func translation(_ selection: TranslatorSelection) -> some View {
        box(0x14) { boxText(selection.translation, colour: .white) }
            .accessibilityLabel(L("Translation"))
    }

    private var input: some View {
        box(0x14) {
            ZStack(alignment: .topLeading) {
                if !translator.draft.hasText {
                    Text(L("Type or paste text"))
                        .font(SurfaceType.geist(14))
                        .foregroundStyle(Self.muted)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                }
                TextEditor(text: Binding(get: { translator.draft.text }, set: { translator.edit($0) }))
                    .font(SurfaceType.geist(14))
                    .lineSpacing(2)
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 10)
                    .accessibilityLabel(L("Text to translate"))
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0x33 / 255), lineWidth: 1))
        // Typing needs the surface to stay open and take the keyboard.
        .simultaneousGesture(TapGesture().onEnded { translator.holdSurfaceOpen() })
    }

    private var result: some View {
        box(0x0A) { boxText(translator.output, colour: Color.white.opacity(0xD9 / 255)) }
            .accessibilityLabel(L("Translation"))
    }

    // MARK: - Nothing to show

    /// What the shortcut said instead of bringing a selection: nothing
    /// selected, a password field, the languages missing.
    private func problem(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L(message))
                .font(SurfaceType.geist(15))
                .foregroundStyle(Self.muted)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if translator.readiness != .ready, translator.readiness != .needsNewerMacOS {
                Button(L("Translator Settings…"), action: translator.openSettings)
                    .buttonStyle(.plain)
                    .font(SurfaceType.geist(13, .medium))
            }
        }
        .padding(.top, 12)
    }

    private var unavailable: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L(unavailableText))
                .font(SurfaceType.geist(15))
                .foregroundStyle(Self.muted)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if translator.readiness == .needsLanguages {
                Button(L("Translator Settings…"), action: translator.openSettings)
                    .buttonStyle(.plain)
                    .font(SurfaceType.geist(13, .medium))
            }
        }
        .padding(.top, 12)
    }

    private var unavailableText: String {
        switch translator.readiness {
        case .needsNewerMacOS: TranslatorFailure.needsNewerMacOS.message
        case .needsLanguages: "Russian and English are not downloaded for translation yet."
        case .checking, .ready: "Checking translation languages…"
        }
    }
}

/// The Translator's card under Settings ▸ Modules.
struct TranslatorCard: View {
    @ObservedObject var translator: TranslatorController
    let expanded: Bool
    let expand: () -> Void

    var body: some View {
        SettingsCard {
            ModuleHeader(module: .translator, expanded: expanded, expand: expand, isOn: Binding(
                get: { translator.isEnabled },
                set: { on in
                    translator.setEnabled(on)
                    if on { expand() }
                }
            ))
            if expanded {
                if !translator.isSupported {
                    caption(L(TranslatorFailure.needsNewerMacOS.message) + " " + L("CapaTheNotch uses Apple's on-device translation, which apps can use without a window only from macOS 26."))
                } else if !translator.isEnabled {
                    caption(L("Select text in any app and press the shortcut — the surface opens with the translation. You can copy it, and if the selection is in a text field, paste it in place of the selection. macOS translates on this Mac; the text goes nowhere."))
                } else {
                    caption(L("Select text in any app and press the shortcut — the surface opens with the translation. You can copy it, and if the selection is in a text field, paste it in place of the selection. macOS translates on this Mac; the text goes nowhere."))
                    SettingsDivider()
                    SettingsRow(indent: 44, hovers: false) {
                        Text(L("Translate selection")); Spacer(); TranslatorShortcutEditor(translator: translator)
                    }
                    if translator.shortcutUnavailable {
                        Text(L("This shortcut is in use. Choose another.")).font(SettingsType.caption).foregroundStyle(SettingsPalette.destructive).padding(.leading, 54).padding(.bottom, 8)
                    }
                    SettingsDivider()
                    SettingsRow(indent: 44) {
                        Text(L("Languages")); Spacer()
                        switch translator.readiness {
                        case .ready:
                            Text(L("Russian and English ready")).font(SettingsType.caption).foregroundStyle(SettingsPalette.positive)
                        case .checking:
                            Text(L("Checking…")).font(SettingsType.caption).foregroundStyle(SettingsPalette.muted)
                        case .needsLanguages:
                            Button(translator.requestingLanguages ? L("Asking macOS…") : L("Download…")) { translator.requestLanguages() }
                                .buttonStyle(SettingsButtonStyle())
                                .disabled(translator.requestingLanguages)
                        case .needsNewerMacOS:
                            Text(L("Unavailable")).font(SettingsType.caption).foregroundStyle(SettingsPalette.destructive)
                        }
                    }
                    if translator.readiness != .ready {
                        caption(L("Russian and English are downloaded by macOS, which asks you first. Apple does not tell apps the size in advance. The languages are shared with other apps and can be removed in System Settings › General › Language & Region › Translation Languages."))
                    }
                    SettingsDivider()
                    SettingsRow(indent: 44) {
                        Text(L("Accessibility")); Spacer()
                        if translator.insertionAllowed { Text(L("Granted")).font(SettingsType.caption).foregroundStyle(SettingsPalette.positive) }
                        else { Button(L("Enable")) { translator.requestInsertion() }.buttonStyle(SettingsButtonStyle()) }
                    }
                    caption(L("Accessibility lets the shortcut read the selection and, when you ask, put the translation in its place; your clipboard is put back after. The text is never saved or logged."))
                }
            }
        }
        .background {
            if #available(macOS 26, *), translator.requestingLanguages {
                TranslatorLanguageRequest(translator: translator)
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(SettingsType.caption).foregroundStyle(SettingsPalette.muted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 54).padding(.trailing, 10).padding(.bottom, 10)
    }
}

/// Hosts macOS's own question to download the two languages. A session that
/// may ask for downloads comes only from a view's `translationTask`.
@available(macOS 26, *)
private struct TranslatorLanguageRequest: View {
    @ObservedObject var translator: TranslatorController
    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .translationTask(TranslationSession.Configuration(
                source: Locale.Language(identifier: "ru"),
                target: Locale.Language(identifier: "en")
            )) { session in
                // Russian with English covers both ways; the question is
                // macOS's, and a refusal is only a readiness read again.
                try? await session.prepareTranslation()
                await translator.languagesAnswered()
            }
    }
}

/// The translator shortcut's keycaps and Edit, as Dictation's are drawn.
struct TranslatorShortcutEditor: View {
    @ObservedObject var translator: TranslatorController
    private let _monitor = State<Any?>(initialValue: nil)
    private let _recording = State(initialValue: false)
    @Environment(\.moduleEditing) private var editing
    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 2) {
                ForEach(Array(translator.shortcut.keycaps.enumerated()), id: \.offset) { _, cap in
                    Text(cap).font(SettingsType.keycap).foregroundStyle(SettingsPalette.muted).padding(.horizontal, 4).frame(minWidth: 20).frame(height: 20).background(SettingsPalette.keycap, in: RoundedRectangle(cornerRadius: 5))
                }
            }
            Button(_recording.wrappedValue ? L("Press keys…") : L("Edit"), action: record).buttonStyle(SettingsButtonStyle())
        }.onDisappear { finish() }
    }
    private func record() {
        if _recording.wrappedValue { finish(); return }
        _recording.wrappedValue = true; editing.wrappedValue = true; ModuleShortcutCapture.setActive(true)
        _monitor.wrappedValue = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { finish(); return nil }
            var mods: KeyShortcut.Modifiers = []
            if event.modifierFlags.contains(.control) { mods.insert(.control) }
            if event.modifierFlags.contains(.option) { mods.insert(.option) }
            if event.modifierFlags.contains(.command) { mods.insert(.command) }
            if event.modifierFlags.contains(.shift) { mods.insert(.shift) }
            guard !mods.isDisjoint(with: [.control, .option, .command]) else { return nil }
            translator.setShortcut(.init(keyCode: UInt32(event.keyCode), modifiers: mods, keyLabel: KeyShortcut.keyLabel(keyCode: UInt32(event.keyCode), characters: event.charactersIgnoringModifiers)))
            finish(); return nil
        }
    }
    private func finish() {
        if let monitor = _monitor.wrappedValue { NSEvent.removeMonitor(monitor) }
        _monitor.wrappedValue = nil
        if _recording.wrappedValue { ModuleShortcutCapture.setActive(false) }
        _recording.wrappedValue = false; editing.wrappedValue = false
    }
}

/// Pictures of the translator's page in each state, with synthetic text, to
/// hold against the other pages (`CAPACITY_NOTCH_DUMP_TRANSLATOR=<folder>`).
/// Each is measured too: the open surface must stay 210 points.
@MainActor
enum TranslatorPictures {
    static func draw(into folder: String) {
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let suite = "capacity-notch-translator-dump-\(UUID())"
        let demo = Preferences(defaults: UserDefaults(suiteName: suite)!)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let translator = TranslatorController(preferences: demo, registersShortcuts: false)
        let geometry = NotchGeometry(menuBarHeight: 32, notchWidth: 185)
        let width = geometry.surfaceWidth()
        var heights: [String] = []
        func picture(_ name: String) {
            let column = SurfaceColumn(
                snapshots: [], geometry: geometry, now: Date(), isExpanded: true,
                translator: translator, page: .translator, connect: { _ in }, refresh: { _ in }, toggle: {}
            )
            let host = NSHostingView(rootView: column.background(Color.black))
            host.frame = NSRect(x: 0, y: 0, width: width, height: 0)
            host.layoutSubtreeIfNeeded()
            host.frame.size = host.fittingSize
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            host.layoutSubtreeIfNeeded()
            heights.append("\(name)=\(host.frame.height)")
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
        translator.preview(readiness: .ready)
        picture("translator-empty")
        translator.preview(
            readiness: .ready,
            text: "Перед релизом надо смержить pull request и прогнать тесты на CI.",
            output: "Before the release, we need to merge the pull request and run the tests on CI."
        )
        picture("translator-ru-en")
        translator.preview(
            readiness: .ready,
            text: "The build fails when the cache is cold; retry with a clean checkout.",
            output: "Сборка падает, когда кэш холодный; повторите с чистого checkout.",
            flipped: false
        )
        picture("translator-en-ru")
        // What the shortcut brings, as "… selection in a field" and
        // "… selection to read" draw it.
        translator.preview(readiness: .ready, mode: .selection(TranslatorSelection(
            text: "Перед релизом надо смержить pull request и прогнать тесты на CI.",
            translation: "Before the release, we need to merge the pull request and run the tests on CI.",
            direction: .russianToEnglish, sourceApplication: "Telegram", isEditable: true
        )))
        picture("translator-selection-field")
        translator.preview(readiness: .ready, mode: .selection(TranslatorSelection(
            text: "The build fails when the cache is cold; retry with a clean checkout.",
            translation: "Сборка падает, когда кэш холодный; повторите с чистого checkout.",
            direction: .englishToRussian, sourceApplication: "Safari", isEditable: false
        )))
        picture("translator-selection-read")
        translator.preview(readiness: .ready, mode: .problem("Select text to translate first."))
        picture("translator-nothing-selected")
        translator.preview(readiness: .needsLanguages, mode: .problem(TranslatorFailure.languagesMissing.message))
        picture("translator-shortcut-needs-languages")
        translator.preview(readiness: .needsLanguages)
        picture("translator-needs-languages")
        translator.preview(readiness: .needsNewerMacOS)
        picture("translator-needs-macos")

        // The Settings card, as Modules shows it expanded.
        func card(_ name: String) {
            let host = NSHostingView(rootView: TranslatorCard(translator: translator, expanded: true, expand: {})
                .padding(24).frame(width: 600).background(SettingsPalette.window).foregroundStyle(SettingsPalette.text).font(SettingsType.body))
            host.frame = NSRect(x: 0, y: 0, width: 600, height: 0)
            host.layoutSubtreeIfNeeded()
            host.frame.size = host.fittingSize
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
        translator.preview(readiness: .needsLanguages)
        card("settings-translator-needs-languages")
        translator.preview(readiness: .ready)
        card("settings-translator-ready")
        FileHandle.standardError.write(Data(("translator: " + heights.joined(separator: " ") + "\n").utf8))
    }
}
