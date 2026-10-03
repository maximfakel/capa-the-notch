import AppKit
import CapacityNotchCore
import SwiftUI

/// One place for every choice, and nothing beyond a choice.
///
/// Deliberately not a dashboard: no history, no charts, no numbers. The
/// surface shows Capacity; this decides how the surface behaves.
///
/// Drawn in Paper ("Pairtask" / "Settings") after Fluid Functionalism, and
/// built from native controls with their own styles, so VoiceOver and the
/// keyboard treat them as they treat the system's (ticket 19).
struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    // Explicit State, not @State: its macro plugin ships only inside Xcode.
    private let _section: State<SettingsSection>
    private var section: SettingsSection {
        get { _section.wrappedValue }
        nonmutating set { _section.wrappedValue = newValue }
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: SettingsModel, section: SettingsSection = .general) {
        self.model = model
        _section = State(initialValue: section)
    }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: _section.projectedValue)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if section != .modules { SectionHeading(section: section) }
                    content
                }
                .padding(.top, section == .modules && model.dictationPage != .overview ? 28 : 52)
                .padding(.horizontal, 40)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Each section arrives with a short fade and rise; under
                // Reduce Motion it only fades.
                .id(section)
                .transition(
                    reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .offset(y: 6))
                )
            }
            .scrollIndicators(.never)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SettingsPalette.window)
        }
        // A new language draws every word again, not only the views that
        // happen to observe the model.
        .id(model.language)
        // The whole window, title bar included: a fixed 560 left the strip
        // under the title bar's height uncovered at the bottom.
        .frame(minWidth: 760, maxWidth: .infinity, minHeight: 560, maxHeight: .infinity)
        .background(SettingsPalette.window)
        .foregroundStyle(SettingsPalette.text)
        .font(SettingsType.body)
        .ignoresSafeArea()
        .animation(SettingsMotion.change(reduced: reduceMotion), value: section)
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .general: GeneralSection(model: model)
        case .providers: ProvidersSection(model: model)
        case .alerts: AlertsSection(model: model)
        case .modules: ModulesSection(model: model)
        case .diagnostics: DiagnosticsSection(model: model)
        }
    }
}

// MARK: - Sections

enum SettingsSection: Int, CaseIterable, Identifiable {
    case general = 1
    case providers
    case alerts
    case modules
    case diagnostics

    var id: Int { rawValue }

    var title: String { L(englishTitle) }

    private var englishTitle: String {
        switch self {
        case .general: "General"
        case .providers: "Providers"
        case .alerts: "Alerts"
        case .modules: "Modules"
        case .diagnostics: "Diagnostics"
        }
    }

    var subtitle: String { L(englishSubtitle) }

    private var englishSubtitle: String {
        switch self {
        case .general: "Where Capacity Notch appears, and how it starts and updates."
        case .providers: "Where Capacity comes from, and whether it is being read."
        case .alerts: "A notification when a window is about to run out."
        case .modules: "What the notch shows besides Capacity. Each one is off until you turn it on."
        case .diagnostics: "What to send when something is wrong."
        }
    }

    var icon: SettingsIcon {
        switch self {
        case .general: .general
        case .providers: .providers
        case .alerts: .alerts
        case .modules: .modules
        case .diagnostics: .diagnostics
        }
    }
}

private struct GeneralSection: View {
    @ObservedObject var model: SettingsModel
    @AppStorage(KapaPreference.key) private var showsKapa = KapaPreference.defaultValue

    var body: some View {
        SettingsGroup(footnote: L("macOS keeps Capacity Notch out of the capture it controls. It cannot promise anything about a camera pointed at the screen.")) {
            // Settings and the menu follow it; the notch and notifications
            // stay in English for now.
            SettingsRow {
                Text(L("Language"))
                Spacer()
                SettingsPicker(selection: $model.language, label: model.language.title) {
                    ForEach(AppLanguage.allCases, id: \.self) { choice in
                        Button(choice.title) { model.language = choice }
                    }
                }
            }
            SettingsRow {
                Text(L("Appearance"))
                Spacer()
                SettingsPicker(selection: $model.appearance, label: L(model.appearance.title)) {
                    ForEach(Appearance.allCases, id: \.self) { choice in
                        Button(L(choice.title)) { model.appearance = choice }
                    }
                }
            }
            SettingsToggleRow(L("Launch at login"), isOn: $model.launchAtLogin)
            SettingsRow {
                Text(L("Show on"))
                Spacer()
                SettingsPicker(selection: $model.displayID, label: displayName) {
                    Button(L("Built-in display")) { model.displayID = 0 }
                    ForEach(model.displays) { display in
                        Button(display.name) { model.displayID = display.id }
                    }
                }
            }
            SettingsToggleRow(L("Appear in screen sharing and recordings"), isOn: $model.screenSharingAllowed)
            // Kapa is how the Modules already on look, not a Module, so it
            // lives here rather than under Modules (ADR 0006).
            SettingsToggleRow(L("Show Kapa"), isOn: $showsKapa)
        }

        SettingsGroup(footnote: L("Opens the latest release on GitHub. Capacity Notch does not check on its own.")) {
            SettingsRow {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Capacity Notch")
                    Text(L("Version %@", model.version))
                        .font(SettingsType.caption)
                        .foregroundStyle(SettingsPalette.muted)
                }
                Spacer()
                Button(L("Check for Updates…")) { model.checkForUpdates() }
                    .buttonStyle(SettingsButtonStyle())
            }
        }
    }

    private var displayName: String {
        guard model.displayID != 0 else { return L("Built-in display") }
        return model.displays.first { $0.id == model.displayID }?.name ?? L("Built-in display")
    }
}

private struct ProvidersSection: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        // The cards are redrawn on a slow beat so "read 2 minutes ago" keeps
        // telling the truth while Settings stays open.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 12) {
                ForEach(model.providers) { choice in
                    ProviderSettingsCard(
                        choice: choice,
                        snapshot: model.snapshot(for: choice.provider),
                        isOn: model.binding(for: choice.provider),
                        canTurnOn: model.canConnect(choice.provider),
                        now: context.date,
                        refresh: { model.refresh(choice.provider) }
                    )
                }
            }
        }

        SettingsGroup {
            SettingsRow {
                Text(L("Shown in the closed strip"))
                Spacer()
                SettingsPicker(selection: $model.compactWindow, label: model.compactWindow.title) {
                    ForEach(CompactWindowChoice.allCases, id: \.self) { choice in
                        Button(choice.title) { model.compactWindow = choice }
                    }
                }
            }
            SettingsRow {
                Text(L("While the surface is closed"))
                Spacer()
                SettingsPicker(
                    selection: $model.backgroundRefresh,
                    label: model.refreshLabel(model.backgroundRefresh)
                ) {
                    ForEach(Preferences.refreshChoices, id: \.self) { seconds in
                        Button(model.refreshLabel(seconds)) { model.backgroundRefresh = seconds }
                    }
                }
            }
        }
    }
}

/// One Provider: whether it is on, what state it is in, when it was last
/// read, why it is not being read when it is not, and a way to read it now.
struct ProviderSettingsCard: View {
    let choice: ProviderChoice
    let snapshot: CapacitySnapshot?
    @Binding var isOn: Bool
    /// False while two other Providers are on: at most two can be
    /// (`ProviderSelection`), so the switch waits for one of them to go.
    let canTurnOn: Bool
    let now: Date
    let refresh: () -> Void

    var body: some View {
        SettingsCard {
            SettingsRow(height: 52, spacing: 10) {
                ProviderMark(provider: choice.provider, size: 18)
                    .foregroundStyle(choice.provider == .claudeCode ? SettingsPalette.orange : SettingsPalette.text)

                VStack(alignment: .leading, spacing: 2) {
                    Text(choice.name).font(SettingsType.bodyMedium)
                    HStack(spacing: 6) {
                        Circle().fill(state.tint).frame(width: 6, height: 6)
                        Text(state.line)
                            .font(SettingsType.caption)
                            .foregroundStyle(SettingsPalette.muted)
                    }
                    .accessibilityElement(children: .combine)
                }

                Spacer(minLength: 0)

                SettingsIconButton(icon: .refresh, label: L("Refresh %@", choice.name), action: refresh)
                    .disabled(!isOn)
                    .opacity(isOn ? 1 : 0.4)

                Toggle(choice.name, isOn: $isOn)
                    .toggleStyle(SettingsSwitchStyle(standsAlone: true))
                    .disabled(!isOn && !canTurnOn)
            }

            if let reason = isOn || canTurnOn ? reason : L("Turn one off to turn this on.") {
                Text(reason)
                    .font(SettingsType.caption)
                    .foregroundStyle(SettingsPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 38)
                    .padding(.trailing, 10)
                    .padding(.bottom, 10)
            }
        }
    }

    private var state: (tint: Color, line: String) {
        guard isOn else { return (SettingsPalette.muted, L("Off")) }
        switch snapshot?.connectionState {
        case .fresh:
            return (SettingsPalette.green, L("Fresh · read %@", Self.ago(snapshot!.capturedAt, now: now)))
        case .stale:
            let clock = snapshot!.capturedAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Localization.current.locale))
            return (SettingsPalette.yellow, L("Stale · last read at %@", clock))
        case .disconnected:
            return (SettingsPalette.red, L("Disconnected"))
        case .connecting, nil:
            return (SettingsPalette.muted, L("Connecting"))
        case .mock:
            return (SettingsPalette.muted, L("Mock"))
        }
    }

    /// The reason a Provider that is on is not being read, in its own words.
    private var reason: String? {
        guard isOn, let snapshot, let reason = snapshot.statusReason else { return nil }
        switch snapshot.connectionState {
        case .stale, .disconnected: return reason.localizedGuidance
        default: return nil
        }
    }

    private static func ago(_ date: Date, now: Date) -> String {
        guard now.timeIntervalSince(date) >= 60 else { return L("just now") }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Localization.current.locale
        // Russian Settings read "2 мин. назад", as drawn; English keeps words.
        formatter.unitsStyle = Localization.current == .russian ? .short : .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

private struct AlertsSection: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        SettingsGroup(footnote: L("One warning per window, when it first drops below a tenth left, and nothing more until it recovers or resets.")) {
            SettingsToggleRow(L("Warn me when a window is about to run out"), isOn: $model.alertsEnabled)
            SettingsDivider()
            ForEach(model.providers) { choice in
                SettingsToggleRow(choice.name, isOn: model.alertBinding(for: choice.provider), indent: 18)
                    .disabled(!model.alertsEnabled)
            }
        }
    }
}

/// Paper "Settings — Modules — Teleprompter": the Module's switch, and while
/// it is on, the Script with Paste and Restore, the speed, the text size and
/// the four shortcuts.
struct TeleprompterCard: View {
    @ObservedObject var teleprompter: TeleprompterController
    let expanded: Bool
    let expand: () -> Void

    var body: some View {
        SettingsCard {
            ModuleHeader(module: .teleprompter, expanded: expanded, expand: expand, isOn: Binding(
                get: { teleprompter.isEnabled }, set: { teleprompter.setEnabled($0) }
            ))

            if expanded && teleprompter.isEnabled {
                script
                SettingsDivider()
                speed
                SettingsDivider()
                textSize
                SettingsDivider()
                shortcuts
            }
        }
    }

    private var script: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: Binding(get: { teleprompter.script }, set: { teleprompter.edit($0) }))
                .font(SettingsType.caption)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 5)
                .padding(.vertical, 6)
                .frame(height: 76)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(SettingsPalette.control)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(SettingsPalette.ring, lineWidth: 1)
                )
                // The length sits in the field's corner: beside the buttons,
                // as drawn, the system's type leaves it no room.
                .overlay(alignment: .bottomTrailing) {
                    Text(length)
                        .font(SettingsType.caption)
                        .foregroundStyle(SettingsPalette.muted)
                        .padding(.horizontal, 6)
                        .background(SettingsPalette.control)
                        .padding(8)
                        .allowsHitTesting(false)
                }
                .accessibilityLabel(L("Script"))

            HStack(spacing: 8) {
                Button(L("Paste from Clipboard")) { teleprompter.pasteFromClipboard() }
                    .buttonStyle(SettingsButtonStyle())
                    .fixedSize()
                Button(L("Restore Previous Script")) { teleprompter.restorePreviousScript() }
                    .buttonStyle(SettingsButtonStyle())
                    .fixedSize()
                    .disabled(!teleprompter.hasPreviousScript)
                Spacer(minLength: 0)
            }
        }
        .padding(.leading, 54)
        .padding(.trailing, 10)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    private var length: String {
        let words = teleprompter.wordCount
        let minutes = TeleprompterScript.minutes(words: words, wordsPerMinute: teleprompter.playback.wordsPerMinute)
        return L("%d words · %d min", words, minutes)
    }

    private var speed: some View {
        SettingsRow(indent: 44, hovers: false) {
            Text(L("Speed"))
            Spacer()
            // The same speed the surface turns, and shown as it shows it.
            Text(String(format: "%.2fx", teleprompter.playback.multiplier))
                .monospacedDigit()
            VStack(spacing: 0) {
                stepButton("chevron.up", label: L("Faster")) { teleprompter.faster() }
                stepButton("chevron.down", label: L("Slower")) { teleprompter.slower() }
            }
            .frame(width: 16, height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(SettingsPalette.control))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(SettingsPalette.ring, lineWidth: 1))
        }
    }

    private func stepButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(SettingsPalette.muted)
                .frame(width: 16, height: 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var textSize: some View {
        SettingsRow(indent: 44, hovers: false) {
            Text(L("Text size"))
            Spacer()
            SettingsPicker(
                selection: Binding(get: { teleprompter.textSize }, set: { teleprompter.setTextSize($0) }),
                label: L(teleprompter.textSize.title)
            ) {
                ForEach(TeleprompterTextSize.allCases, id: \.self) { size in
                    Button(L(size.title)) { teleprompter.setTextSize(size) }
                }
            }
        }
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Shortcuts"))
            ForEach(TeleprompterAction.allCases, id: \.self) { action in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L(action.title))
                            .font(SettingsType.caption)
                            .foregroundStyle(SettingsPalette.muted)
                        if teleprompter.unavailableShortcuts.contains(action) {
                            Text(L("Another app already uses this shortcut."))
                                .font(SettingsType.caption)
                                .foregroundStyle(SettingsPalette.red)
                        }
                    }
                    Spacer()
                    ShortcutRecorder(teleprompter: teleprompter, action: action)
                }
            }
        }
        .padding(.leading, 54)
        .padding(.trailing, 10)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }
}

/// A shortcut's keycaps, and a click to record another: the next key pressed
/// with Control, Option or Command becomes the shortcut; Escape alone cancels.
private struct ShortcutRecorder: View {
    @Environment(\.moduleEditing) private var editing
    @ObservedObject var teleprompter: TeleprompterController
    let action: TeleprompterAction

    private let _recording = State(initialValue: false)
    private var recording: Bool {
        get { _recording.wrappedValue }
        nonmutating set { _recording.wrappedValue = newValue }
    }
    private let _monitor = State<Any?>(initialValue: nil)
    private var monitor: Any? {
        get { _monitor.wrappedValue }
        nonmutating set { _monitor.wrappedValue = newValue }
    }

    var body: some View {
        Button(action: toggleRecording) {
            HStack(spacing: 2) {
                if recording {
                    keycap(L("Type a shortcut"), wide: true)
                } else {
                    let caps = teleprompter.shortcut(for: action)?.keycaps ?? ["—"]
                    ForEach(Array(caps.enumerated()), id: \.offset) { index, cap in
                        keycap(cap, wide: index == caps.count - 1)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("%@ shortcut", L(action.title)))
        .accessibilityValue(teleprompter.shortcut(for: action)?.display ?? L("None"))
        .onDisappear { finish() }
    }

    /// The last cap is the key and takes a fixed width, so the modifier caps
    /// line up in a column down the card.
    private func keycap(_ text: String, wide: Bool) -> some View {
        Text(text)
            .font(SettingsType.keycap)
            .foregroundStyle(SettingsPalette.muted)
            .lineLimit(1)
            .padding(.horizontal, 4)
            .frame(minWidth: wide ? 48 : 20)
            .frame(height: 20)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(SettingsPalette.keycap))
    }

    private func toggleRecording() {
        if recording { finish(); return }
        recording = true
        editing.wrappedValue = true
        ModuleShortcutCapture.setActive(true)
        teleprompter.suspendShortcuts(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 53, flags.isDisjoint(with: [.control, .option, .command]) {
                finish()
                return nil
            }
            var modifiers: KeyShortcut.Modifiers = []
            if flags.contains(.control) { modifiers.insert(.control) }
            if flags.contains(.option) { modifiers.insert(.option) }
            if flags.contains(.shift) { modifiers.insert(.shift) }
            if flags.contains(.command) { modifiers.insert(.command) }
            guard !modifiers.isDisjoint(with: [.control, .option, .command]) else { return nil }
            teleprompter.setShortcut(
                KeyShortcut(
                    keyCode: UInt32(event.keyCode),
                    modifiers: modifiers,
                    keyLabel: KeyShortcut.keyLabel(keyCode: UInt32(event.keyCode), characters: event.charactersIgnoringModifiers)
                ),
                for: action
            )
            finish()
            return nil
        }
    }

    private func finish() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { ModuleShortcutCapture.setActive(false); teleprompter.suspendShortcuts(false) }
        recording = false
        editing.wrappedValue = false
    }
}

/// One Module that can be switched on. Every Module but the Capacity Module
/// is off until a person turns it on (CONTEXT.md), so onboarding gives each
/// one of these.
struct ModuleCard: View {
    let icon: SettingsIcon
    let name: String
    let summary: String
    let note: String?
    let warning: String?
    @Binding var isOn: Bool

    var body: some View {
        SettingsCard {
            SettingsRow(height: 56, spacing: 12) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(SettingsPalette.text)
                    .frame(width: 32, height: 32)
                    .overlay {
                        SettingsIconView(icon)
                            .foregroundStyle(SettingsPalette.window)
                    }
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(SettingsType.bodyMedium)
                    Text(summary)
                        .font(SettingsType.caption)
                        .foregroundStyle(SettingsPalette.muted)
                }

                Spacer(minLength: 0)

                Toggle(name, isOn: $isOn)
                    .toggleStyle(SettingsSwitchStyle(standsAlone: true))
            }

            ForEach([note, warning].compactMap(\.self), id: \.self) { line in
                Text(line)
                    .font(SettingsType.caption)
                    .foregroundStyle(line == warning ? SettingsPalette.red : SettingsPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 54)
                    .padding(.trailing, 10)
                    .padding(.bottom, 10)
            }
        }
    }
}

private struct DiagnosticsSection: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        SettingsGroup(footnote: L("Copied text carries versions, the states of Providers and Dictation, and timings. It carries no credential, address, identifier, Provider message or dictated text — those cannot reach it.")) {
            SettingsToggleRow(L("Keep a log for bug reports"), isOn: $model.keepsDiagnosticLog)
            SettingsDivider()
            SettingsRow(height: 48, spacing: 8, hovers: false) {
                Button(L("Copy Diagnostics")) { model.copyDiagnostics() }
                    .buttonStyle(SettingsButtonStyle())
                Button(L("Reveal Log")) { model.revealLog() }
                    .buttonStyle(SettingsButtonStyle())
                    .disabled(!model.keepsDiagnosticLog)
                Spacer()
                Button(L("Run Onboarding Again")) { model.restartOnboarding() }
                    .buttonStyle(SettingsButtonStyle())
            }

            if let report = model.lastCopiedReport {
                ScrollView {
                    Text(report)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 140)
                .padding(10)
            }
        }
    }
}

// MARK: - Sidebar

private struct SettingsSidebar: View {
    @Binding var selection: SettingsSection
    @Namespace private var highlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsSection.allCases) { section in
                SidebarItem(
                    icon: section.icon,
                    title: section.title,
                    isSelected: selection == section,
                    highlight: highlight,
                    action: { selection = section }
                ) {
                    KeyCaps(keys: ["⌘", String(section.rawValue)])
                }
                // ⌘1–⌘5, in the order the sidebar shows them.
                .keyboardShortcut(KeyEquivalent(Character(String(section.rawValue))), modifiers: .command)
            }
            Spacer()
        }
        .padding(.top, 52)
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .frame(width: 200)
        .frame(maxHeight: .infinity)
        .background(SettingsPalette.sidebar)
        .overlay(alignment: .trailing) {
            Rectangle().fill(SettingsPalette.ring).frame(width: 1)
        }
        .focusable()
        .focusEffectDisabled()
        .onMoveCommand { direction in
            switch direction {
            case .up: step(by: -1)
            case .down: step(by: 1)
            default: break
            }
        }
        .animation(SettingsMotion.spring(reduced: reduceMotion), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Settings sections"))
    }

    private func step(by offset: Int) {
        let next = selection.rawValue + offset
        if let section = SettingsSection(rawValue: next) { selection = section }
    }
}

/// One line of a sidebar — Settings' sections, onboarding's steps — with
/// whatever belongs at its end: keycaps, a step's number or its tick.
struct SidebarItem<Trailing: View>: View {
    let icon: SettingsIcon
    let title: String
    let isSelected: Bool
    let highlight: Namespace.ID
    let action: () -> Void
    @ViewBuilder let trailing: Trailing

    private let _hovering = State(initialValue: false)
    private var hovering: Bool {
        get { _hovering.wrappedValue }
        nonmutating set { _hovering.wrappedValue = newValue }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                SettingsIconView(icon)
                    .foregroundStyle(isSelected ? SettingsPalette.text : SettingsPalette.icon)
                Text(title)
                    .font(isSelected ? SettingsType.bodyMedium : SettingsType.body)
                Spacer(minLength: 0)
                trailing
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background {
                // One highlight, moved between items on a spring, so the eye
                // follows it rather than seeing one go out and another come on.
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(SettingsPalette.selection)
                        .matchedGeometryEffect(id: "selection", in: highlight)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(SettingsPalette.hover)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A shortcut spelled out in keycaps, as Fluid Functionalism's command menu
/// shows them: one cap per key, 20 points tall, two points apart. Only
/// shortcuts that work in this window are shown.
struct KeyCaps: View {
    let keys: [String]
    /// What VoiceOver says; Settings' sidebar shortcuts by default.
    var label: String?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(SettingsType.keycap)
                    .foregroundStyle(SettingsPalette.muted)
                    .padding(.horizontal, 4)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(SettingsPalette.keycap)
                    )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label ?? "Command \(keys.last ?? "")")
    }
}

struct SectionHeading: View {
    let title: String
    let subtitle: String

    init(section: SettingsSection) {
        self.init(title: section.title, subtitle: section.subtitle)
    }

    init(title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // The drawing's line heights, 28 and 18, rather than the font's;
            // a subtitle too long for one line takes a second.
            Text(title)
                .font(SettingsType.title)
                .tracking(-0.22)
                .frame(height: 28)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(SettingsType.body)
                .foregroundStyle(SettingsPalette.muted)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 18)
        }
    }
}

// MARK: - Pieces

/// A card with the footnote that belongs to it.
struct SettingsGroup<Content: View>: View {
    let footnote: String?
    @ViewBuilder let content: Content

    init(footnote: String? = nil, @ViewBuilder content: () -> Content) {
        self.footnote = footnote
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsCard { content }
            if let footnote {
                Text(footnote)
                    .font(SettingsType.caption)
                    .foregroundStyle(SettingsPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
            }
        }
    }
}

struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(SettingsPalette.card)
                    .shadow(color: SettingsPalette.ring, radius: 0.5, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(SettingsPalette.ring, lineWidth: 1)
            )
    }
}

/// A row that lights up under the pointer before it is clicked.
struct SettingsRow<Content: View>: View {
    var height: CGFloat = 40
    var spacing: CGFloat = 8
    var indent: CGFloat = 0
    var hovers = true
    @ViewBuilder let content: Content

    private let _hovering = State(initialValue: false)
    private var hovering: Bool {
        get { _hovering.wrappedValue }
        nonmutating set { _hovering.wrappedValue = newValue }
    }

    init(
        height: CGFloat = 40,
        spacing: CGFloat = 8,
        indent: CGFloat = 0,
        hovers: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.height = height
        self.spacing = spacing
        self.indent = indent
        self.hovers = hovers
        self.content = content()
    }

    var body: some View {
        // The height is the row's least: a caption that wraps makes the row
        // taller rather than spilling over the next one.
        HStack(spacing: spacing) { content }
            .padding(.leading, 10 + indent)
            .padding(.trailing, 10)
            .frame(minHeight: height)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovers && hovering ? SettingsPalette.hover : .clear)
            )
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

struct SettingsToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    var indent: CGFloat = 0

    init(_ title: String, isOn: Binding<Bool>, indent: CGFloat = 0) {
        self.title = title
        _isOn = isOn
        self.indent = indent
    }

    var body: some View {
        SettingsRow(indent: indent) {
            Toggle(title, isOn: $isOn)
                .toggleStyle(SettingsSwitchStyle())
        }
    }
}

struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(SettingsPalette.ring)
            .frame(height: 1)
            .padding(.horizontal, 10)
    }
}

/// The drawing's switch: 34 by 20, a 16-point thumb, on a spring that picks
/// up from wherever it is when flipped back mid-way. The label, when there is
/// one, sits on the left and the switch on the right.
struct SettingsSwitchStyle: ToggleStyle {
    /// A switch on its own, as on a card's header: no label drawn and no
    /// room taken beyond its 34 points. The label still reaches VoiceOver.
    var standsAlone = false

    func makeBody(configuration: Configuration) -> some View {
        SettingsSwitch(configuration: configuration, standsAlone: standsAlone)
    }
}

private struct SettingsSwitch: View {
    let configuration: ToggleStyleConfiguration
    let standsAlone: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            if !standsAlone {
                configuration.label
                Spacer(minLength: 0)
            }
            Capsule()
                .fill(configuration.isOn ? SettingsPalette.accent : SettingsPalette.switchOff)
                .frame(width: 34, height: 20)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.1), radius: 1, y: 1)
                        .frame(width: 16, height: 16)
                        .padding(2)
                }
                // The reference's focus ring, round the switch alone — not
                // the system's rectangle round the whole row.
                .overlay {
                    if focused {
                        Capsule()
                            .strokeBorder(SettingsPalette.accent, lineWidth: 2)
                            .padding(-3)
                    }
                }
                .animation(SettingsMotion.spring(reduced: reduceMotion), value: configuration.isOn)
        }
        .opacity(isEnabled ? 1 : 0.5)
        .contentShape(Rectangle())
        .onTapGesture { if isEnabled { configuration.isOn.toggle() } }
        // Focus as a button has it on the Mac: reached with the keyboard
        // (Tab, with Full Keyboard Access), never taken by a click — a click
        // that left a ring round the row looked like a fault.
        .focusable(isEnabled, interactions: .activate)
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.space) {
            configuration.isOn.toggle()
            return .handled
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? L("On") : L("Off"))
        .accessibilityAction { configuration.isOn.toggle() }
    }
}

struct SettingsButtonStyle: ButtonStyle {
    /// The one button a page leads with, dark on light as the drawing's
    /// "Download • 170MB" is.
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(SettingsType.body)
            .foregroundStyle(prominent ? SettingsPalette.window : isEnabled ? SettingsPalette.text : SettingsPalette.muted)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(prominent ? SettingsPalette.text.opacity(configuration.isPressed ? 0.8 : 1) : configuration.isPressed ? SettingsPalette.hover : SettingsPalette.control)
                    .shadow(color: SettingsPalette.ring, radius: 1, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(SettingsPalette.ring, lineWidth: 1)
            )
            .opacity(isEnabled ? 1 : 0.5)
    }
}

private struct SettingsIconButton: View {
    let icon: SettingsIcon
    let label: String
    let action: () -> Void

    private let _hovering = State(initialValue: false)
    private var hovering: Bool {
        get { _hovering.wrappedValue }
        nonmutating set { _hovering.wrappedValue = newValue }
    }

    var body: some View {
        Button(action: action) {
            SettingsIconView(icon)
                .foregroundStyle(SettingsPalette.icon)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering ? SettingsPalette.hover : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
    }
}

/// A pop-up choice drawn as the mockup's small white control with its
/// chevrons; the menu it opens is the system's.
struct SettingsPicker<Value: Hashable, Items: View>: View {
    @Binding var selection: Value
    let label: String
    @ViewBuilder let items: Items

    var body: some View {
        Menu {
            items
        } label: {
            HStack(spacing: 6) {
                Text(label)
                SettingsIconView(.chevrons)
                    .foregroundStyle(SettingsPalette.muted)
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(SettingsPalette.control)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(SettingsPalette.ring, lineWidth: 1)
            )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityValue(label)
    }
}

// MARK: - Look

/// The drawing's colours, light and dark, following the Mac's appearance.
enum SettingsPalette {
    static let window = dynamic(light: 0xFAFAFA, dark: 0x171717)
    static let sidebar = dynamic(light: 0xF4F4F5, dark: 0x1E1E1E)
    static let card = dynamic(light: 0xFFFFFF, dark: 0x252525)
    static let control = dynamic(light: 0xFFFFFF, dark: 0x333333)
    static let selection = dynamic(light: 0xE5E5E5, dark: 0x2C2C2C)
    static let hover = dynamic(light: 0xF4F4F5, dark: 0x2C2C2C)
    static let text = dynamic(light: 0x171717, dark: 0xF5F5F5)
    static let muted = dynamic(light: 0x737373, dark: 0xA3A3A3)
    static let icon = dynamic(light: 0x525252, dark: 0xA3A3A3)
    static let switchOff = dynamic(light: 0xE5E5E5, dark: 0x404040)
    static let keycap = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor.white.withAlphaComponent(0x0F / 255)
            : NSColor.black.withAlphaComponent(0x0A / 255)
    })
    static let ring = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor.white.withAlphaComponent(0x0F / 255)
            : NSColor.black.withAlphaComponent(0x0F / 255)
    })

    static let accent = Color(red: 0x6B / 255, green: 0x97 / 255, blue: 0xFF / 255)
    static let positive = dynamic(light: 0x21834A, dark: 0x56DF9A)
    static let destructive = dynamic(light: 0xC5332A, dark: 0xFF625D)
    static let green = SurfaceType.green
    static let yellow = SurfaceType.yellow
    static let red = SurfaceType.red
    static let orange = SurfaceType.orange

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            NSColor(hex: appearance.isDark ? dark : light)
        })
    }
}

/// Geist, the variable font under the SIL Open Font License that ships in
/// Resources beside its licence. Keycaps stay in the system's font: Geist has
/// no ⌘, ⌥ or ⌃.
enum SettingsType {
    static let title = geist(22, .semibold)
    static let step = geist(14, .semibold)
    static let body = geist(13)
    static let bodyMedium = geist(13, .medium)
    static let caption = geist(12)
    static let keycap = Font.system(size: 11)

    private static func geist(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Font.custom("Geist", fixedSize: size).weight(weight)
    }

    /// For this process only; nothing is installed on the Mac.
    static func registerFont() {
        guard let url = Bundle.main.url(forResource: "Geist", withExtension: "ttf")
            ?? Bundle.module.url(forResource: "Geist", withExtension: "ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
}

enum SettingsMotion {
    /// Switches and the sidebar's highlight.
    static func spring(reduced: Bool) -> Animation {
        reduced ? .easeInOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.75)
    }

    /// Changing section.
    static func change(reduced: Bool) -> Animation {
        reduced ? .easeInOut(duration: 0.15) : .spring(response: 0.32, dampingFraction: 0.9)
    }
}

private extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
