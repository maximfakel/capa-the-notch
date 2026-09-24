import AppKit
import CapacityNotchCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let preferences = Preferences()
    /// The Music Module's reader (ticket 17); running only while the Module is on.
    let music = MusicReader()
    /// SIGTERM — what `pkill` sends, and the install loop uses — quits the
    /// application properly, so its children are stopped rather than orphaned.
    private var termination: DispatchSourceSignal?
    private var alertDecider = CapacityAlertDecider()
    private var notifications: CapacityNotifications?
    private let archive = CapacityArchive()
    private let store: CapacityNotchStore
    private let codex = CodexCapacityService(
        clientInfo: CodexClientInfo(version: AppDelegate.applicationVersion),
        // The Provider's own output is kept only while the person has asked
        // for it. The switch in Settings is read at the moment a connection is
        // made, so turning it on takes effect on the next reconnect.
        makeTransport: {
            CodexInstallation.locate().map { executable in
                CodexProcessTransport(
                    executablePath: executable,
                    logURL: Preferences().keepsDiagnosticLog ? DiagnosticLog.prepare() : nil
                )
            }
        }
    )
    private let claude = ClaudeCapacityService(
        // Two ways to the same windows. The bridge is free and structured but
        // only runs in a terminal; `/usage` costs a subprocess and works
        // wherever the person is. Whichever saw the windows last wins.
        capacitySource: NewestClaudeCapacity([
            ClaudeFileCapacitySource(fileURL: ClaudeStatusLineBridge.defaultSnapshotURL),
            ThrottledCapacitySource(
                ClaudeUsageCommandSource(),
                interval: AppDelegate.usageCommandInterval
            ),
        ])
    )
    private var panelController: NotchPanelController?
    private var codexSnapshots: Task<Void, Never>?
    private var codexRefresh: Task<Void, Never>?
    private var claudeSnapshots: Task<Void, Never>?
    private var claudeRefresh: Task<Void, Never>?

    private let schedule = RefreshSchedule.standard
    /// Consecutive failures worth retrying, per Provider. A Provider waiting
    /// on a person is not counted here: backing off does not help it.
    private var transientFailures: [Provider: Int] = [:]
    /// How often Claude Code itself is asked. Capacity moves slowly and the
    /// question costs a process, so it is asked far less often than the
    /// surface refreshes.
    private static let usageCommandInterval: TimeInterval = 300

    override init() {
        // The last numbers seen come back first, marked Stale, so a restart
        // does not open on nothing while the Providers are asked again.
        store = CapacityNotchStore(
            snapshots: UnreadCapacity.snapshots(restoring: archive.load())
        )
        super.init()
    }

    private static var applicationVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        applyAppearance(preferences.appearance)

        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termination.setEventHandler { NSApplication.shared.terminate(nil) }
        termination.resume()
        self.termination = termination

        let panelController = NotchPanelController(
            store: store,
            music: music,
            connect: { [weak self] provider in self?.connect(provider) },
            refresh: { [weak self] provider in self?.refresh(provider) }
        )
        self.panelController = panelController
        panelController.show()
        if preferences.musicEnabled { music.start() }

        if CapacityNotifications.isAvailable {
            notifications = CapacityNotifications { [weak self] provider, window in
                self?.openAlert(provider: provider, windowID: window)
            }
        }

        if ProcessInfo.processInfo.environment["CAPACITY_NOTCH_DUMP_REPORT"] == "1" {
            FileHandle.standardError.write(Data((diagnosticReport() + "\n").utf8))
        }

        // Settings, every section in both appearances, to hold against the
        // Paper drawing ("Pairtask" / "Settings") without anyone squinting.
        if let folder = ProcessInfo.processInfo.environment["CAPACITY_NOTCH_DUMP_SETTINGS"] {
            let model = SettingsModel(preferences: preferences, application: self, store: store)
            for section in SettingsSection.allCases {
                for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    let host = NSHostingView(rootView: SettingsView(model: model, section: section))
                    host.appearance = NSAppearance(named: appearance)
                    host.frame = NSRect(x: 0, y: 0, width: 760, height: 560)
                    host.layoutSubtreeIfNeeded()
                    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(
                        to: URL(fileURLWithPath: folder).appendingPathComponent("settings-\(section.title.lowercased())-\(name).png")
                    )
                }
            }
        }

        observeCodex()
        observeClaudeCode()

        guard !preferences.needsOnboarding else {
            startOnboarding(force: false)
            return
        }
        connectChosenProviders()
    }

    func applicationWillTerminate(_ notification: Notification) {
        archive.save(store.snapshots)
        panelController?.stopPointerTracking()
        music.stop()
        stopCodex()
        stopClaudeCode()
    }

    // MARK: - The surface

    // This and three more methods below switch on the Provider by hand. That
    // is deliberate: there are two, their services connect differently —
    // Claude Code through a request, Codex directly — and an exhaustive switch
    // makes a third Provider a compile error at every place that must know
    // about it. A shared Provider handle would be an abstraction for two.
    private func isConnected(_ provider: Provider) -> Bool {
        switch provider {
        case .codex: codexRefresh != nil
        case .claudeCode: claudeRefresh != nil
        }
    }

    var displays: [DisplayDescriptor] { panelController?.displays ?? [] }
    var chosenDisplayID: UInt32? { panelController?.chosenDisplay?.id }

    func useDisplay(_ id: UInt32) {
        panelController?.useDisplay(id)
    }

    var sharingAllowed: Bool { panelController?.sharingAllowed ?? false }

    func setSharingAllowed(_ allowed: Bool) {
        panelController?.setSharingAllowed(allowed)
    }

    /// Opens and holds the surface open, so it can be read and left with the
    /// keyboard alone: the status menu is reachable with the system's own
    /// shortcut, this pins the surface and makes it key, Tab moves between its
    /// buttons, and Escape closes it.
    func openSurface() {
        panelController?.show()
        panelController?.open()
    }

    /// Starts whatever the person left connected. Called once at launch and
    /// again when onboarding finishes, and starting a Provider that is already
    /// running is a no-op, so neither doubles anything.
    func connectChosenProviders() {
        if preferences.connectsAtLaunch(.codex) { connectCodex() }
        if preferences.connectsAtLaunch(.claudeCode) { connectClaudeCode() }
    }

    func connectCodex() {
        guard codexRefresh == nil else { return }
        preferences.setConnectsAtLaunch(.codex, true)

        codexRefresh = Task { [weak self, codex] in
            await codex.connect()
            while !Task.isCancelled {
                guard let delay = await self?.nextDelay(for: .codex) else { return }
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                await codex.refresh()
            }
        }
    }

    /// A deliberate Disconnect: remembered, so the next launch honours it.
    func disconnectCodex() {
        preferences.setConnectsAtLaunch(.codex, false)
        stopCodex()
    }

    /// Stops reading Codex without deciding anything about the next launch —
    /// which is all that quitting should do.
    private func stopCodex() {
        codexRefresh?.cancel()
        codexRefresh = nil

        let codex = codex
        Task { await codex.disconnect() }
    }

    func requestClaudeCodeConnection() {
        // Consent is asked once. A question re-asked after it has been
        // answered is not consent, it is nagging.
        guard !preferences.claudeConsentGiven else {
            connectClaudeCode()
            return
        }

        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Turn on Claude Code?"
        alert.informativeText = "Capacity Notch asks Claude Code for its /usage — the report you see when you type /usage — and reads the Capacity in it, and the status line where Claude Code publishes one. It never reads Claude credentials, sessions, prompts or transcripts, and never talks to Anthropic itself."
        alert.addButton(withTitle: "Turn On")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        preferences.claudeConsentGiven = true
        connectClaudeCode()
    }

    /// A deliberate Disconnect: remembered, so the next launch honours it.
    func disconnectClaudeCode() {
        preferences.setConnectsAtLaunch(.claudeCode, false)
        stopClaudeCode()
    }

    private func stopClaudeCode() {
        claudeRefresh?.cancel()
        claudeRefresh = nil

        let claude = claude
        Task { await claude.disconnect() }
    }

    /// Quitting stops everything and remembers nothing: a Provider connected
    /// when the application quit is connected when it starts. Quit used to go
    /// through Disconnect, which recorded both Providers as switched off, so
    /// every launch after a quit read nothing and opened the welcome window.
    func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func observeCodex() {
        let stream = codex.snapshots
        codexSnapshots = Task { [weak self] in
            for await snapshot in stream {
                self?.store.apply(snapshot)
                self?.record(snapshot)
            }
        }
    }

    func connectClaudeCode() {
        preferences.setConnectsAtLaunch(.claudeCode, true)
        // Reconnect replaces a failed refresh loop after the bridge is added.
        claudeRefresh?.cancel()

        claudeRefresh = Task { [weak self, claude] in
            await claude.connect()
            while !Task.isCancelled {
                guard let delay = await self?.nextDelay(for: .claudeCode) else { return }
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                await claude.refresh()
            }
        }
    }

    /// How long before this Provider is read again: the surface's own pace,
    /// stretched by any run of failures worth retrying.
    private func nextDelay(for provider: Provider) -> TimeInterval {
        schedule.delay(
            expanded: store.presentation == .expanded,
            consecutiveFailures: transientFailures[provider] ?? 0
        )
    }

    // MARK: - Onboarding and Settings

    private var onboarding: NSWindowController?
    private var settings: NSWindowController?

    func isProviderRunning(_ provider: Provider) -> Bool {
        isConnected(provider)
    }

    /// Shows the first-run path. Re-running it opens the same window rather
    /// than a second one, and changes nothing until it is finished.
    func startOnboarding(force: Bool) {
        if force { preferences.hasFinishedOnboarding = false }

        if let onboarding {
            onboarding.window?.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        let model = OnboardingModel(preferences: preferences, application: self)
        onboarding = Self.window(
            titled: "Welcome to Capacity Notch",
            content: OnboardingView(model: model)
        )
        onboarding?.window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// Closes onboarding and opens the surface on what was chosen.
    func finishOnboarding() {
        onboarding?.close()
        onboarding = nil
        connectChosenProviders()
        panelController?.show()
        panelController?.open()
    }

    /// Turns the Music Module on or off. Off, nothing is read and the adapter
    /// is not running (ADR 0003).
    func setMusicEnabled(_ enabled: Bool) {
        preferences.musicEnabled = enabled
        if enabled { music.start() } else { music.stop() }
    }

    /// Light, dark, or the Mac's own, for every window the application opens.
    /// The surface draws its own black and is not affected.
    func applyAppearance(_ appearance: Appearance) {
        preferences.appearance = appearance
        NSApplication.shared.appearance = switch appearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// Opens the latest release in the browser. See `Releases` for why this
    /// is done by hand.
    func checkForUpdates() {
        NSWorkspace.shared.open(Releases.latest)
    }

    func showSettings() {
        if let settings {
            settings.window?.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        let model = SettingsModel(preferences: preferences, application: self, store: store)
        settings = Self.settingsWindow(content: SettingsView(model: model))
        settings?.window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// The drawing's window: 760 by 560, the sidebar running to the top edge
    /// under the traffic lights, no title — the sidebar says where you are.
    private static func settingsWindow(content: some View) -> NSWindowController {
        let hosting = NSHostingController(rootView: content)
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = "Capacity Notch Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.isMovableByWindowBackground = true
        window.setContentSize(NSSize(width: 760, height: 560))
        window.isReleasedWhenClosed = false
        window.center()
        return NSWindowController(window: window)
    }

    private static func window(titled title: String, content: some View) -> NSWindowController {
        let hosting = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        return NSWindowController(window: window)
    }

    /// Stops one Provider, and remembers that it was stopped on purpose.
    func disconnect(_ provider: Provider) {
        // A Provider switched off and back on should be able to tell you the
        // news, so what it has already said is forgotten with it.
        alertDecider.forget(provider)

        switch provider {
        case .codex:
            disconnectCodex()
        case .claudeCode:
            disconnectClaudeCode()
        }
    }

    /// Moves the surface to whichever display is now chosen.
    func useChosenDisplay() {
        panelController?.useDisplay(preferences.preferredDisplayID)
    }

    /// Starts one Provider from its own card.
    func connect(_ provider: Provider) {
        switch provider {
        case .codex:
            connectCodex()
        case .claudeCode:
            requestClaudeCodeConnection()
        }
    }

    /// Reads one Provider at once, without waiting for its turn.
    ///
    /// A Provider that is not connected cannot be read, and a button that
    /// silently does nothing is worse than no button: asking an unconnected
    /// Provider to refresh connects it instead.
    func refresh(_ provider: Provider) {
        transientFailures[provider] = 0

        guard isConnected(provider) else {
            connect(provider)
            return
        }

        switch provider {
        case .codex:
            let codex = codex
            Task { await codex.refresh() }
        case .claudeCode:
            let claude = claude
            Task { await claude.refresh() }
        }
    }

    /// Reads every connected Provider at once, without waiting for its turn.
    func refreshNow() {
        transientFailures.removeAll()

        let codex = codex
        let claude = claude
        Task {
            await codex.refresh()
            await claude.refresh()
        }
    }

    /// Everything a bug report may carry about this machine, and nothing else.
    func diagnosticReport() -> String {
        var observations: [String] = []
        if let bridge = ClaudeStatusLineBridge.observation() {
            observations.append(bridge)
        }
        if ClaudeUsageCommandSource.locate() == nil {
            observations.append("claude-binary-not-found")
        }
        if CodexInstallation.locate() == nil {
            observations.append("codex-binary-not-found")
        }
        if !LaunchAtLogin.isEnabled {
            observations.append("launch-at-login-off")
        }
        if preferences.musicEnabled, music.isUnreadable {
            observations.append(MusicModule.unreadableCode)
        }

        return DiagnosticReport(
            applicationVersion: Self.applicationVersion,
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            generatedAt: Date(),
            providers: store.snapshots.map {
                ProviderDiagnostic(
                    snapshot: $0,
                    consecutiveTransientFailures: transientFailures[$0.provider] ?? 0
                )
            },
            observations: observations
        ).text()
    }

    /// Brings someone back to the window an alert was about: the surface
    /// opens, pinned, with that row pointed at for a few seconds.
    private func openAlert(provider: Provider, windowID: String) {
        openSurface()
        store.highlight(.init(provider: provider, windowID: windowID))

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            self?.store.highlight(nil)
        }
    }

    /// Switches alerts on, asking the system for permission at that moment and
    /// not before. Returns what the system decided.
    func enableAlerts() async -> Bool {
        let granted = await notifications?.requestPermission() ?? false
        preferences.alertsEnabled = granted
        return granted
    }

    /// Counts what just arrived, so the next wait knows whether this Provider
    /// is answering, and keeps the archive current while it is.
    private func record(_ snapshot: CapacitySnapshot) {
        for alert in alertDecider.alerts(
            for: snapshot,
            at: Date(),
            isEnabled: { [preferences] in preferences.alertsEnabled(for: $0) }
        ) {
            notifications?.send(alert)
        }

        switch snapshot.connectionState {
        case .fresh:
            transientFailures[snapshot.provider] = 0
            archive.save(store.snapshots)
        case .stale, .disconnected:
            if snapshot.statusReason?.isTransient == true {
                transientFailures[snapshot.provider, default: 0] += 1
            } else {
                transientFailures[snapshot.provider] = 0
            }
        case .connecting, .mock:
            break
        }
    }

    private func observeClaudeCode() {
        let stream = claude.snapshots
        claudeSnapshots = Task { [weak self] in
            for await snapshot in stream {
                self?.store.apply(snapshot)
                self?.record(snapshot)
            }
        }
    }
}
