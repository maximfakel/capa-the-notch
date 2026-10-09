import AppKit
import CapacityNotchCore
import Combine
import SwiftUI

struct ProviderChoice: Identifiable {
    let provider: Provider
    let name: String

    var id: String { provider.rawValue }
}

/// What Settings and onboarding both write through.
///
/// Every property writes to `Preferences` and then tells the application, so a
/// switch flicked here takes effect at once rather than at the next launch.
@MainActor
final class SettingsModel: ObservableObject {
    @Published var expandedModule: BuiltInModule = .music
    @Published var dictationPage: DictationSettingsPage = .overview
    private let dictationOverride: DictationController?
    var dictation: DictationController { dictationOverride ?? application.dictation }
    private let preferences: Preferences
    private unowned let application: AppDelegate
    private var watching: Set<AnyCancellable> = []

    init(
        preferences: Preferences,
        application: AppDelegate,
        store: CapacityNotchStore? = nil,
        teleprompter: TeleprompterController? = nil,
        dictation: DictationController? = nil,
        shelf: ShelfController? = nil,
        claudeCode: ClaudeCodeSettings? = nil
    ) {
        self.preferences = preferences
        self.application = application
        teleprompterOverride = teleprompter
        shelfOverride = shelf
        dictationOverride = dictation
        snapshots = store?.snapshots ?? []
        appearance = preferences.appearance
        displayID = preferences.preferredDisplayID ?? 0
        screenSharingAllowed = preferences.screenSharingAllowed
        refreshInterval = preferences.refreshInterval
        claudeCodeOverride = claudeCode
        self.claudeCode = claudeCode ?? application.claudeCodeSettings
        launchAtLogin = LaunchAtLogin.isEnabled
        alertsEnabled = preferences.alertsEnabled
        keepsDiagnosticLog = preferences.keepsDiagnosticLog
        language = preferences.language
        compactWindow = preferences.compactWindow
        musicEnabled = preferences.musicEnabled
        trackpadTapEnabled = preferences.opensOnTrackpadTap
        application.music.$isUnreadable
            .receive(on: DispatchQueue.main)
            .sink { [weak self] unreadable in self?.musicUnreadable = unreadable }
            .store(in: &watching)
        application.trackpadTap.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in self?.trackpadTapStatus = status }
            .store(in: &watching)
        // The Providers section shows each Provider's state as the surface
        // knows it, and follows it while Settings is open.
        store?.$snapshots
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshots in self?.snapshots = snapshots }
            .store(in: &watching)
    }

    /// What the surface currently knows about each Provider.
    @Published private(set) var snapshots: [CapacitySnapshot]

    func snapshot(for provider: Provider) -> CapacitySnapshot? {
        snapshots.first { $0.provider == provider }
    }

    func isOn(_ provider: Provider) -> Bool {
        preferences.connectsAtLaunch(provider)
    }

    /// What Claude Code's card shows under its header: why Capacity may
    /// lag, the mod's row, and the terminal's while the mod is not working.
    @Published private(set) var claudeCode: ClaudeCodeSettings

    /// A stand-in state for the pictures Settings renders of itself, so
    /// each of the mockup's states can be drawn without touching `~/.claude`.
    private let claudeCodeOverride: ClaudeCodeSettings?

    /// Reads the mod's state from disk again: when the section appears, and
    /// after every Add, Remove or switch.
    func reloadClaudeCode() {
        let now = claudeCodeOverride ?? application.claudeCodeSettings
        if now != claudeCode { claudeCode = now }
    }

    /// "Добавить": put in place at once — the button is the person's
    /// explicit action, so there is no second question.
    func addClaudeMod() {
        guard claudeCodeOverride == nil else { return }
        application.addClaudeMod()
        reloadClaudeCode()
    }

    /// "Удалить": only CapaTheNotch's own folder goes.
    func removeClaudeMod() {
        guard claudeCodeOverride == nil else { return }
        application.removeClaudeMod()
        reloadClaudeCode()
    }

    /// "Открыть Терминал": `claude` in a new Terminal window.
    func openClaudeInTerminal() {
        guard claudeCodeOverride == nil else { return }
        application.openClaudeInTerminal()
    }

    /// Reads one Provider now, as the surface's own Refresh does.
    func refresh(_ provider: Provider) {
        application.refresh(provider)
    }

    var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    /// The Music Module. Off until asked for; off, nothing is read.
    @Published var musicEnabled: Bool {
        didSet { application.setMusicEnabled(musicEnabled) }
    }

    /// macOS stopped telling CapaTheNotch what is playing (ADR 0004).
    @Published private(set) var musicUnreadable = false

    /// Two taps on the trackpad open the surface (ticket 14). Off until
    /// asked for; off, the trackpad is not read.
    @Published var trackpadTapEnabled: Bool {
        didSet { application.setTrackpadTapEnabled(trackpadTapEnabled) }
    }

    /// Whether the trackpad is being read, or why it cannot be (ADR 0004).
    @Published private(set) var trackpadTapStatus: TrackpadTapStatus = .off

    /// The Teleprompter Module, observed directly: its Script, speed and
    /// shortcuts are the controller's, and the card follows them live.
    var teleprompter: TeleprompterController { teleprompterOverride ?? application.teleprompter }
    var shelf: ShelfController { shelfOverride ?? application.shelf }
    var calendar: CalendarController { application.calendar }
    var translator: TranslatorController { application.translator }
    /// A stand-in for the pictures, so drawing the Shelf card never touches
    /// the person's own Shelf or its switches.
    private let shelfOverride: ShelfController?
    /// A stand-in for the pictures Settings renders of itself, so drawing the
    /// Teleprompter card never touches the person's own Script.
    private let teleprompterOverride: TeleprompterController?

    /// In surface order, the one order Providers stand in (`ProviderSelection`).
    let providers = Provider.allCases.map { ProviderChoice(provider: $0, name: $0.spokenName) }

    func binding(for provider: Provider) -> Binding<Bool> {
        Binding(
            get: { self.preferences.connectsAtLaunch(provider) },
            set: { self.setProvider(provider, connected: $0) }
        )
    }

    /// Whether this Provider's switch can be turned on: at most two can be.
    func canConnect(_ provider: Provider) -> Bool {
        preferences.canConnect(provider)
    }

    private func setProvider(_ provider: Provider, connected: Bool) {
        // Refused past the two-at-most rule: the switch stays off.
        guard preferences.setConnectsAtLaunch(provider, connected) else { return }
        objectWillChange.send()

        if connected {
            application.connect(provider)
        } else {
            application.disconnect(provider)
        }
        // Turn On may have put the mod in place, Turn Off taken it away.
        if provider == .claudeCode { reloadClaudeCode() }
    }

    /// The language Settings speak; changing it redraws them at once.
    @Published var language: AppLanguage {
        didSet {
            // The language first: the defaults write below is what the
            // notch and the menu watch, and they must redraw in the new one.
            Localization.current = language
            preferences.language = language
            application.applyLanguage()
        }
    }

    @Published var appearance: Appearance {
        didSet { application.applyAppearance(appearance) }
    }

    @Published var displayID: UInt32 {
        didSet {
            preferences.preferredDisplayID = displayID == 0 ? nil : displayID
            application.useChosenDisplay()
        }
    }

    @Published var screenSharingAllowed: Bool {
        didSet { application.setSharingAllowed(screenSharingAllowed) }
    }

    @Published var compactWindow: CompactWindowChoice {
        didSet { preferences.compactWindow = compactWindow }
    }

    /// How often Codex and OpenCode are read while the surface is closed.
    @Published var refreshInterval: RefreshInterval {
        didSet { preferences.refreshInterval = refreshInterval }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            let settled = LaunchAtLogin.set(launchAtLogin)
            preferences.launchAtLogin = settled
            // macOS has the last word; if it declined, say so rather than
            // leaving a switch on that does nothing.
            if settled != launchAtLogin { launchAtLogin = settled }
        }
    }


    @Published var alertsEnabled: Bool {
        didSet {
            guard alertsEnabled else {
                preferences.alertsEnabled = false
                return
            }
            // Permission is asked at the moment alerts are switched on. If the
            // system says no, the switch says no too rather than sitting on
            // and delivering nothing.
            Task { [weak self] in
                guard let self else { return }
                let granted = await self.application.enableAlerts()
                if !granted { self.alertsEnabled = false }
            }
        }
    }

    func alertBinding(for provider: Provider) -> Binding<Bool> {
        Binding(
            get: { self.preferences.alertsEnabled(for: provider) },
            set: {
                self.preferences.setAlertsEnabled($0, for: provider)
                self.objectWillChange.send()
            }
        )
    }

    @Published var keepsDiagnosticLog: Bool {
        didSet { preferences.keepsDiagnosticLog = keepsDiagnosticLog }
    }

    var displays: [DisplayDescriptor] { application.displays }

    func checkForUpdates() {
        application.checkForUpdates()
    }

    func revealLog() {
        NSWorkspace.shared.activateFileViewerSelecting([DiagnosticLog.fileURL])
    }

    /// What was last copied, shown so nobody has to paste it somewhere to find
    /// out what they are about to send.
    @Published private(set) var lastCopiedReport: String?

    func copyDiagnostics() {
        let report = application.diagnosticReport()
        OwnClipboard.copy(report)
        lastCopiedReport = report
    }

    func restartOnboarding() {
        application.startOnboarding(force: true)
    }
}
