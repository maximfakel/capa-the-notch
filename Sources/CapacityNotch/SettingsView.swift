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
    @State private var section: SettingsSection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: SettingsModel, section: SettingsSection = .general) {
        self.model = model
        _section = State(initialValue: section)
    }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: $section)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    SectionHeading(section: section)
                    content
                }
                .padding(.top, 52)
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

    var title: String {
        switch self {
        case .general: "General"
        case .providers: "Providers"
        case .alerts: "Alerts"
        case .modules: "Modules"
        case .diagnostics: "Diagnostics"
        }
    }

    var subtitle: String {
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

    var body: some View {
        SettingsGroup(footnote: "macOS keeps Capacity Notch out of the capture it controls. It cannot promise anything about a camera pointed at the screen.") {
            SettingsRow {
                Text("Appearance")
                Spacer()
                SettingsPicker(selection: $model.appearance, label: model.appearance.title) {
                    ForEach(Appearance.allCases, id: \.self) { choice in
                        Button(choice.title) { model.appearance = choice }
                    }
                }
            }
            SettingsToggleRow("Launch at login", isOn: $model.launchAtLogin)
            SettingsRow {
                Text("Show on")
                Spacer()
                SettingsPicker(selection: $model.displayID, label: displayName) {
                    Button("Built-in display") { model.displayID = 0 }
                    ForEach(model.displays) { display in
                        Button(display.name) { model.displayID = display.id }
                    }
                }
            }
            SettingsToggleRow("Appear in screen sharing and recordings", isOn: $model.screenSharingAllowed)
        }

        SettingsGroup(footnote: "Opens the latest release on GitHub. Capacity Notch does not check on its own.") {
            SettingsRow {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Capacity Notch")
                    Text("Version \(model.version)")
                        .font(SettingsType.caption)
                        .foregroundStyle(SettingsPalette.muted)
                }
                Spacer()
                Button("Check for Updates…") { model.checkForUpdates() }
                    .buttonStyle(SettingsButtonStyle())
            }
        }
    }

    private var displayName: String {
        guard model.displayID != 0 else { return "Built-in display" }
        return model.displays.first { $0.id == model.displayID }?.name ?? "Built-in display"
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
                        now: context.date,
                        refresh: { model.refresh(choice.provider) }
                    )
                }
            }
        }

        SettingsGroup(footnote: "An open surface is read every minute; that is not a choice, because an open surface is being watched.") {
            SettingsRow {
                Text("While the surface is closed")
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
private struct ProviderSettingsCard: View {
    let choice: ProviderChoice
    let snapshot: CapacitySnapshot?
    @Binding var isOn: Bool
    let now: Date
    let refresh: () -> Void

    var body: some View {
        SettingsCard {
            SettingsRow(height: 52, spacing: 10) {
                ProviderMark(provider: choice.provider, size: 18)
                    .foregroundStyle(choice.provider == .codex ? SettingsPalette.text : SettingsPalette.orange)

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

                SettingsIconButton(icon: .refresh, label: "Refresh \(choice.name)", action: refresh)
                    .disabled(!isOn)
                    .opacity(isOn ? 1 : 0.4)

                Toggle(choice.name, isOn: $isOn)
                    .toggleStyle(SettingsSwitchStyle(standsAlone: true))
            }

            if let reason {
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
        guard isOn else { return (SettingsPalette.muted, "Off") }
        switch snapshot?.connectionState {
        case .fresh:
            return (SettingsPalette.green, "Fresh · read \(Self.ago(snapshot!.capturedAt, now: now))")
        case .stale:
            let clock = snapshot!.capturedAt.formatted(date: .omitted, time: .shortened)
            return (SettingsPalette.yellow, "Stale · last read at \(clock)")
        case .disconnected:
            return (SettingsPalette.red, "Disconnected")
        case .connecting, nil:
            return (SettingsPalette.muted, "Connecting")
        case .mock:
            return (SettingsPalette.muted, "Mock")
        }
    }

    /// The reason a Provider that is on is not being read, in its own words.
    private var reason: String? {
        guard isOn, let snapshot, let reason = snapshot.statusReason else { return nil }
        switch snapshot.connectionState {
        case .stale, .disconnected: return reason.guidance
        default: return nil
        }
    }

    private static func ago(_ date: Date, now: Date) -> String {
        guard now.timeIntervalSince(date) >= 60 else { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

private struct AlertsSection: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        SettingsGroup(footnote: "One warning per window, when it first drops below a tenth left, and nothing more until it recovers or resets.") {
            SettingsToggleRow("Warn me when a window is about to run out", isOn: $model.alertsEnabled)
            SettingsDivider()
            ForEach(model.providers) { choice in
                SettingsToggleRow(choice.name, isOn: model.alertBinding(for: choice.provider), indent: 18)
                    .disabled(!model.alertsEnabled)
            }
        }
    }
}

private struct ModulesSection: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        ModuleCard(
            icon: .music,
            name: "Music",
            summary: "What's playing, with its controls, under Capacity.",
            note: "Open, the surface has a page for it. It is read through a part of macOS that Apple does not publish, which a macOS update could close.",
            warning: model.musicEnabled && model.musicUnreadable ? MusicModule.unreadableGuidance : nil,
            isOn: $model.musicEnabled
        )
    }
}

/// One Module that can be switched on. Every Module but the Capacity Module
/// is off until a person turns it on (CONTEXT.md), so each gets a card here.
private struct ModuleCard: View {
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
        SettingsGroup(footnote: "Copied text carries versions, Provider states and timings. It carries no credential, address, identifier or Provider message — those cannot reach it.") {
            SettingsToggleRow("Keep a log for bug reports", isOn: $model.keepsDiagnosticLog)
            SettingsDivider()
            SettingsRow(height: 48, spacing: 8, hovers: false) {
                Button("Copy Diagnostics") { model.copyDiagnostics() }
                    .buttonStyle(SettingsButtonStyle())
                Button("Reveal Log") { model.revealLog() }
                    .buttonStyle(SettingsButtonStyle())
                    .disabled(!model.keepsDiagnosticLog)
                Spacer()
                Button("Run Onboarding Again") { model.restartOnboarding() }
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
                    section: section,
                    isSelected: selection == section,
                    highlight: highlight
                ) {
                    selection = section
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
        .accessibilityLabel("Settings sections")
    }

    private func step(by offset: Int) {
        let next = selection.rawValue + offset
        if let section = SettingsSection(rawValue: next) { selection = section }
    }
}

private struct SidebarItem: View {
    let section: SettingsSection
    let isSelected: Bool
    let highlight: Namespace.ID
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                SettingsIconView(section.icon)
                    .foregroundStyle(isSelected ? SettingsPalette.text : SettingsPalette.icon)
                Text(section.title)
                    .font(isSelected ? SettingsType.bodyMedium : SettingsType.body)
                Spacer(minLength: 0)
                KeyCaps(keys: ["⌘", String(section.rawValue)])
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
private struct KeyCaps: View {
    let keys: [String]

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
        .accessibilityLabel("Command \(keys.last ?? "")")
    }
}

private struct SectionHeading: View {
    let section: SettingsSection

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // The drawing's line heights, 28 and 18, rather than the font's.
            Text(section.title)
                .font(SettingsType.title)
                .tracking(-0.22)
                .frame(height: 28)
                .accessibilityAddTraits(.isHeader)
            Text(section.subtitle)
                .font(SettingsType.body)
                .foregroundStyle(SettingsPalette.muted)
                .frame(height: 18)
        }
    }
}

// MARK: - Pieces

/// A card with the footnote that belongs to it.
private struct SettingsGroup<Content: View>: View {
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

private struct SettingsCard<Content: View>: View {
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
private struct SettingsRow<Content: View>: View {
    var height: CGFloat = 40
    var spacing: CGFloat = 8
    var indent: CGFloat = 0
    var hovers = true
    @ViewBuilder let content: Content

    @State private var hovering = false

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
        HStack(spacing: spacing) { content }
            .padding(.leading, 10 + indent)
            .padding(.trailing, 10)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovers && hovering ? SettingsPalette.hover : .clear)
            )
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct SettingsToggleRow: View {
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

private struct SettingsDivider: View {
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
        .accessibilityValue(configuration.isOn ? "On" : "Off")
        .accessibilityAction { configuration.isOn.toggle() }
    }
}

private struct SettingsButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(SettingsType.body)
            .foregroundStyle(isEnabled ? SettingsPalette.text : SettingsPalette.muted)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(configuration.isPressed ? SettingsPalette.hover : SettingsPalette.control)
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

    @State private var hovering = false

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
private struct SettingsPicker<Value: Hashable, Items: View>: View {
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

enum SettingsType {
    static let title = Font.system(size: 22, weight: .semibold)
    static let body = Font.system(size: 13)
    static let bodyMedium = Font.system(size: 13, weight: .medium)
    static let caption = Font.system(size: 12)
    static let keycap = Font.system(size: 11)
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
