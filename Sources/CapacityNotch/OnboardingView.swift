import CapacityNotchCore
import SwiftUI

/// The first-run path: a welcome, everything macOS will be asked for, the
/// Providers, then each Module in turn.
///
/// Drawn in Paper beside Settings ("Pairtask" / "Settings", the
/// "Onboarding — …" row, after Fluid Functionalism) and built from Settings' own pieces, writing through the
/// same `SettingsModel`: a switch flicked here is the switch in Settings, and
/// takes effect at once, as it does there. The permissions are asked for
/// together, so no prompt interrupts work later. Continue waits for a Provider
/// to answer, and Skip goes on without one. Every Module can be passed by with
/// its switch left off.
///
/// Opened at the permissions step instead, it is how someone who used a
/// build signed before the author's certificate is asked again, once, after
/// the old grants were reset (ticket 33; Paper: "Permissions again — …").
@MainActor
final class OnboardingModel: ObservableObject {
    enum Step: Int, CaseIterable, Identifiable {
        case welcome
        case permissions
        case providers
        case music
        case teleprompter
        case dictation

        var id: Int { rawValue }

        var name: String { L(englishName) }

        private var englishName: String {
            switch self {
            case .welcome: "Welcome"
            case .permissions: "Permissions"
            case .providers: "Providers"
            case .music: "Music"
            case .teleprompter: "Teleprompter"
            case .dictation: "Dictation"
            }
        }

        var title: String { L(englishTitle) }

        private var englishTitle: String {
            switch self {
            case .welcome: "Welcome to CapaTheNotch"
            case .permissions: "Permissions"
            case .providers: "Connect a Provider"
            case .music: "Music"
            case .teleprompter: "Teleprompter"
            case .dictation: "Dictation"
            }
        }

        var subtitle: String { L(englishSubtitle) }

        private var englishSubtitle: String {
            switch self {
            case .welcome: "How much of Codex, Claude Code and OpenCode is left, right under the notch — and a few tools beside it."
            case .permissions: "Everything macOS will ask about, at once, so nothing interrupts you later."
            case .providers: "CapaTheNotch reads nothing until a Provider is on."
            case .music: "Control what's playing without leaving what you're doing."
            case .teleprompter: "Read your Script beside the camera, without looking away."
            case .dictation: "Speech becomes text on this Mac. The speech model is downloaded once."
            }
        }

        var icon: SettingsIcon {
            switch self {
            case .welcome: .notch
            case .permissions: .permissions
            case .providers: .providers
            case .music: .music
            case .teleprompter: .teleprompter
            case .dictation: .dictation
            }
        }
    }

    @Published private(set) var step: Step = .welcome
    /// The furthest step reached; the sidebar goes back to any step up to it.
    @Published private(set) var reached: Step = .welcome
    /// Why the permissions step is shown again, if it is (ticket 33).
    let permissionsAgain: OldGrantReset.Opening?
    /// Try Again was pressed and tccutil refused once more.
    @Published private(set) var retryFailed = false

    let settings: SettingsModel
    let access: SystemAccess
    private let preferences: Preferences
    private unowned let application: AppDelegate

    /// `step` and the stand-ins are for the pictures onboarding renders of
    /// itself; a person always starts at the welcome, with their own Modules.
    init(
        preferences: Preferences,
        application: AppDelegate,
        store: CapacityNotchStore,
        notifications: CapacityNotifications?,
        step: Step = .welcome,
        permissionsAgain: OldGrantReset.Opening? = nil,
        teleprompter: TeleprompterController? = nil,
        dictation: DictationController? = nil
    ) {
        self.preferences = preferences
        self.application = application
        settings = SettingsModel(
            preferences: preferences,
            application: application,
            store: store,
            teleprompter: teleprompter,
            dictation: dictation
        )
        access = SystemAccess(dictation: settings.dictation, notifications: notifications, calendar: application.calendar)
        self.permissionsAgain = permissionsAgain
        self.step = permissionsAgain == nil ? step : .permissions
        reached = self.step
    }

    var title: String {
        guard step == .permissions else { return step.title }
        switch permissionsAgain {
        case .permissionsAgain: return L("Permissions, Once More")
        case .permissionsNotReset: return L("The Earlier Permissions Were Not Reset")
        case .onboarding, nil: return step.title
        }
    }

    var subtitle: String {
        guard step == .permissions else { return step.subtitle }
        switch permissionsAgain {
        case .permissionsAgain:
            return L("From this version on, CapaTheNotch is signed with its author's certificate. The permissions given to earlier builds were reset — once, so that a build someone else signed cannot use them.")
        case .permissionsNotReset:
            return L("CapaTheNotch is now signed with its author's certificate, but macOS did not let it reset the permissions of earlier builds. While they are there, a build someone else signed can use them. Remove them by hand:")
        case .onboarding, nil:
            return step.subtitle
        }
    }

    /// Tries the reset again; once it is done, CapaTheNotch opens again and
    /// asks there.
    func retryReset() {
        retryFailed = application.retryOldGrantReset() != .reset
    }

    /// Removed in Privacy & Security by hand: CapaTheNotch opens again and
    /// asks there.
    func removedByHand() {
        application.oldGrantsRemovedByHand()
    }

    /// A Provider that is on and has said something about its Capacity.
    var providerAnswered: Bool {
        settings.providers.contains { choice in
            guard settings.isOn(choice.provider) else { return false }
            switch settings.snapshot(for: choice.provider)?.connectionState {
            case .fresh, .stale: return true
            default: return false
            }
        }
    }

    var canGoOn: Bool { step != .providers || providerAnswered }

    /// The Providers were passed by without one answering.
    var skippedProviders: Bool {
        reached.rawValue > Step.providers.rawValue && !providerAnswered
    }

    var isLast: Bool { step == Step.allCases.last }

    func go(to step: Step) {
        guard step.rawValue <= reached.rawValue else { return }
        self.step = step
    }

    func goOn() {
        guard canGoOn else { return }
        advance()
    }

    /// On without a Provider; one can be turned on later in Settings.
    func skip() {
        advance()
    }

    private func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return finish() }
        step = next
        if next.rawValue > reached.rawValue { reached = next }
    }

    func goBack() {
        if let previous = Step(rawValue: step.rawValue - 1) { step = previous }
    }

    func finish() {
        Sounds.shared.play(.onboardingFinished)
        preferences.hasFinishedOnboarding = true
        application.finishOnboarding()
    }
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject private var settings: SettingsModel
    @Namespace private var highlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: OnboardingModel) {
        self.model = model
        _settings = ObservedObject(wrappedValue: model.settings)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar

            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        SectionHeading(title: model.title, subtitle: model.subtitle)
                        content
                    }
                    .padding(.top, 52)
                    .padding(.horizontal, 40)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(model.step)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6)))
                }
                .scrollIndicators(.never)

                footer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SettingsPalette.window)
        }
        // A new language draws every word again, as in Settings.
        .id(settings.language)
        .frame(width: 760, height: 560)
        .background(SettingsPalette.window)
        .foregroundStyle(SettingsPalette.text)
        .font(SettingsType.body)
        .ignoresSafeArea()
        .animation(SettingsMotion.change(reduced: reduceMotion), value: model.step)
    }

    // MARK: - Sidebar and footer

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(OnboardingModel.Step.allCases) { step in
                let reachable = step.rawValue <= model.reached.rawValue
                SidebarItem(
                    icon: step.icon,
                    title: step.name,
                    isSelected: model.step == step,
                    highlight: highlight,
                    action: { model.go(to: step) }
                ) {
                    marker(for: step)
                }
                .disabled(!reachable)
                .opacity(reachable ? 1 : 0.45)
            }
            Spacer()
            Text(L("Everything chosen here can be changed later in Settings."))
                .font(SettingsType.caption)
                .foregroundStyle(SettingsPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
        }
        .padding(.top, 52)
        .padding(.horizontal, 8)
        .padding(.bottom, 16)
        .frame(width: 200)
        .frame(maxHeight: .infinity)
        .background(SettingsPalette.sidebar)
        .overlay(alignment: .trailing) {
            Rectangle().fill(SettingsPalette.ring).frame(width: 1)
        }
        .animation(SettingsMotion.spring(reduced: reduceMotion), value: model.step)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Onboarding steps"))
    }

    /// A step's number in a keycap, a tick once it has been passed, or a
    /// dash for Providers passed by without one.
    private func marker(for step: OnboardingModel.Step) -> some View {
        let skipped = step == .providers && model.skippedProviders
        let passed = step.rawValue < model.reached.rawValue && !skipped
        return Text(passed ? "✓" : skipped ? "–" : "\(step.rawValue + 1)")
            .font(SettingsType.keycap)
            .foregroundStyle(passed ? SettingsPalette.positive : SettingsPalette.muted)
            .frame(minWidth: 20, minHeight: 20)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(SettingsPalette.keycap))
            .accessibilityLabel(passed ? L("Done") : skipped ? L("Skipped") : L("Step %d", step.rawValue + 1))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if model.step != .welcome {
                Button(L("Back")) { model.goBack() }
                    .buttonStyle(SettingsButtonStyle())
            }
            Spacer()
            if !model.canGoOn {
                Button(L("Skip")) { model.skip() }
                    .buttonStyle(SettingsButtonStyle())
            }
            Button(model.isLast ? L("Finish") : L("Continue")) { model.goOn() }
                .buttonStyle(SettingsButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canGoOn)
        }
        .padding(.horizontal, 40)
        .frame(height: 56)
        .overlay(alignment: .top) {
            Rectangle().fill(SettingsPalette.ring).frame(height: 1)
        }
    }

    // MARK: - Steps

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .welcome: welcome
        case .permissions:
            OnboardingPermissions(
                access: model.access, again: model.permissionsAgain, retryFailed: model.retryFailed,
                retry: model.retryReset, removedByHand: model.removedByHand
            )
        case .providers: providers
        case .music: music
        case .teleprompter: OnboardingTeleprompter(teleprompter: settings.teleprompter)
        case .dictation: OnboardingDictation(controller: settings.dictation)
        }
    }

    private var welcome: some View {
        Group {
            SettingsCard {
                feature(.providers, name: L("Capacity"), summary: L("What is left of each window, and whether it will last."))
                ForEach([BuiltInModule.music, .teleprompter, .dictation], id: \.self) { module in
                    SettingsDivider()
                    feature(module.icon, name: module.name, summary: module.summary)
                }
            }

            SettingsGroup(footnote: L("Settings and the notch speak it; you can change it at any time.")) {
                SettingsRow {
                    Text(L("Language"))
                    Spacer()
                    SettingsPicker(selection: $settings.language, label: settings.language.title) {
                        ForEach(AppLanguage.allCases, id: \.self) { choice in
                            Button(choice.title) { settings.language = choice }
                        }
                    }
                }
            }
        }
    }

    private func feature(_ icon: SettingsIcon, name: String, summary: String) -> some View {
        SettingsRow(height: 52, spacing: 12, hovers: false) {
            SettingsIconView(icon)
                .foregroundStyle(SettingsPalette.icon)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(SettingsType.bodyMedium)
                Text(summary)
                    .font(SettingsType.caption)
                    .foregroundStyle(SettingsPalette.muted)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var providers: some View {
        Group {
            VStack(alignment: .leading, spacing: 8) {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(settings.providers) { choice in
                            ProviderSettingsCard(
                                choice: choice,
                                snapshot: settings.snapshot(for: choice.provider),
                                isOn: settings.binding(for: choice.provider),
                                canTurnOn: settings.canConnect(choice.provider),
                                now: context.date,
                                refresh: { settings.refresh(choice.provider) }
                            )
                        }
                    }
                }
                Text(L("Claude Code and OpenCode are experimental. CapaTheNotch says what it reads before reading anything."))
                    .font(SettingsType.caption)
                    .foregroundStyle(SettingsPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
            }

            // Asked only once a Provider has answered, and neither is set
            // for anyone (ticket 07).
            if model.providerAnswered {
                SettingsGroup(footnote: L("One warning per window, when it first drops below a tenth left, and nothing more until it recovers or resets.")) {
                    SettingsToggleRow(L("Warn me when a window is about to run out"), isOn: $settings.alertsEnabled)
                    SettingsDivider()
                    SettingsToggleRow(L("Launch at login"), isOn: $settings.launchAtLogin)
                }
                .transition(.opacity)
            }
        }
        .animation(SettingsMotion.change(reduced: reduceMotion), value: model.providerAnswered)
    }

    private var music: some View {
        ModuleCard(
            icon: .music,
            name: BuiltInModule.music.name,
            summary: BuiltInModule.music.summary,
            note: L("Open, the surface has a page for it. It is read through a part of macOS that Apple does not publish, which a macOS update could close."),
            warning: settings.musicEnabled && settings.musicUnreadable ? L(MusicModule.unreadableGuidance) : nil,
            isOn: $settings.musicEnabled
        )
    }
}

/// Each thing macOS is asked for, why, and where it stands; one button asks
/// for all of them in turn. Asked again after the reset (ticket 33), only
/// what was reset is listed; when the reset failed, each opens its pane in
/// Privacy & Security, where the old grant is removed by hand.
private struct OnboardingPermissions: View {
    @ObservedObject var access: SystemAccess
    let again: OldGrantReset.Opening?
    let retryFailed: Bool
    let retry: () -> Void
    let removedByHand: () -> Void

    private var notReset: Bool { again == .permissionsNotReset }

    /// Notifications were not reset, so they are not asked for again; and
    /// an old Calendars grant is there to remove whether the Module is on or
    /// not.
    private var kinds: [SystemAccess.Kind] {
        switch again {
        case .permissionsNotReset: [.microphone, .accessibility, .automation, .calendars]
        case .permissionsAgain: access.kinds.filter { $0 != .notifications }
        case .onboarding, nil: access.kinds
        }
    }

    private var footnote: String {
        switch again {
        case .permissionsNotReset:
            L("In each list, choose CapaTheNotch and press −; under Automation, turn System Events off. CapaTheNotch asks again after that.")
        case .permissionsAgain:
            L("macOS asks about each one in turn; Accessibility is switched on in System Settings. After this, updates keep the permissions again.")
        case .onboarding, nil:
            L("macOS asks about each one in turn. Accessibility is switched on in System Settings; its state here follows when you come back.")
        }
    }

    var body: some View {
        SettingsGroup(footnote: footnote) {
            ForEach(kinds) { kind in
                if kind != kinds.first { SettingsDivider() }
                row(kind)
            }
        }

        HStack {
            if notReset {
                Button(L("Try Again"), action: retry)
                    .buttonStyle(SettingsButtonStyle())
                Button(L("Already Removed"), action: removedByHand)
                    .buttonStyle(SettingsButtonStyle())
                if retryFailed {
                    Text(L("macOS refused again."))
                        .font(SettingsType.caption)
                        .foregroundStyle(SettingsPalette.muted)
                }
            } else {
                Button(L("Allow All")) { Task { await access.requestAll() } }
                    .buttonStyle(SettingsButtonStyle(prominent: true))
                    .disabled(!access.anyToAsk)
            }
            Spacer()
        }
        .onAppear { access.watch() }
        .onDisappear { access.stopWatching() }
    }

    private func row(_ kind: SystemAccess.Kind) -> some View {
        SettingsRow(height: 56, spacing: 12, hovers: false) {
            SettingsIconView(kind.icon)
                .foregroundStyle(SettingsPalette.icon)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(notReset ? kind.paneName : kind.name).font(SettingsType.bodyMedium)
                Text(notReset ? kind.shortReason : kind.reason)
                    .font(SettingsType.caption)
                    .foregroundStyle(SettingsPalette.muted)
            }
            Spacer(minLength: 0)
            if notReset {
                Button(L("Open Settings")) { access.openSettings(kind) }
                    .buttonStyle(SettingsButtonStyle())
            } else {
                switch access.state(kind) {
                case .granted:
                    Text(L("Granted"))
                        .font(SettingsType.caption)
                        .foregroundStyle(SettingsPalette.positive)
                case .notAsked:
                    Button(L("Allow")) { Task { await access.request(kind) } }
                        .buttonStyle(SettingsButtonStyle())
                case .refused:
                    Button(L("Open Settings")) { Task { await access.request(kind) } }
                        .buttonStyle(SettingsButtonStyle())
                case .unavailable:
                    Text(L("Unavailable"))
                        .font(SettingsType.caption)
                        .foregroundStyle(SettingsPalette.muted)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// The Teleprompter's switch and, once it is on, the shortcuts that drive it.
private struct OnboardingTeleprompter: View {
    @ObservedObject var teleprompter: TeleprompterController

    var body: some View {
        ModuleCard(
            icon: .teleprompter,
            name: BuiltInModule.teleprompter.name,
            summary: BuiltInModule.teleprompter.summary,
            note: nil,
            warning: nil,
            isOn: Binding(get: { teleprompter.isEnabled }, set: { teleprompter.setEnabled($0) })
        )

        if teleprompter.isEnabled {
            SettingsGroup(footnote: L("Write or paste the Script in Settings, under Modules. The shortcuts can be changed there too.")) {
                ForEach(TeleprompterAction.allCases, id: \.self) { action in
                    SettingsRow(hovers: false) {
                        Text(L(action.title))
                        Spacer()
                        let shortcut = teleprompter.shortcut(for: action)
                        KeyCaps(keys: shortcut?.keycaps ?? ["—"], label: L("%@ shortcut", L(action.title)))
                            .accessibilityValue(shortcut?.display ?? L("None"))
                    }
                }
            }
            .transition(.opacity)
        }
    }
}

/// Dictation's switch and, once it is on, its shortcut and the steps that
/// make it work: the speech model, the microphone, insertion.
private struct OnboardingDictation: View {
    @ObservedObject var controller: DictationController

    var body: some View {
        ModuleCard(
            icon: .dictation,
            name: BuiltInModule.dictation.name,
            summary: BuiltInModule.dictation.summary,
            note: controller.isEnabled ? nil : L("Hold a shortcut to turn speech into text, entirely on this Mac."),
            warning: nil,
            isOn: Binding(get: { controller.isEnabled }, set: { controller.setEnabled($0) })
        )

        if controller.isEnabled {
            SettingsCard {
                SettingsRow(spacing: 12, hovers: false) {
                    Text(L("Hold to dictate"))
                    Spacer()
                    DictationShortcutEditor(controller: controller)
                }
                if controller.shortcutUnavailable {
                    Text(L("This shortcut is in use. Choose another."))
                        .font(SettingsType.caption)
                        .foregroundStyle(SettingsPalette.destructive)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 8)
                }
            }
            DictationSetup(controller: controller)
        }
    }
}

private extension BuiltInModule {
    var icon: SettingsIcon {
        switch self {
        case .music: .music
        case .teleprompter: .teleprompter
        case .dictation: .dictation
        case .shelf: .shelf
        case .calendar: .calendar
        case .translator: .translator
        }
    }
}
