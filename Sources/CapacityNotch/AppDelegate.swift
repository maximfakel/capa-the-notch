import AppKit
import Combine
import CapacityNotchCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let preferences = Preferences()
    /// The Music Module's reader (ticket 17); running only while the Module is on.
    let music = MusicReader()
    /// The Teleprompter Module (ticket 16); its shortcuts registered only
    /// while the Module is on.
    private(set) lazy var dictation = DictationController(preferences: preferences)
    private var dictationPreviewTask: Task<Void, Never>?
    private var shortcutCapture: AnyCancellable?
    private var dictationPanel: DictationPanelController?
    private(set) lazy var teleprompter = TeleprompterController(preferences: preferences)
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
        // A Provider switched off does not come back with its old numbers.
        let preferences = preferences
        store = CapacityNotchStore(
            snapshots: UnreadCapacity.snapshots(
                restoring: archive.load(),
                switchedOff: Set(Provider.allCases.filter { !preferences.connectsAtLaunch($0) })
            )
        )
        super.init()
    }

    private static var applicationVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        Localization.current = preferences.language
        SettingsType.registerFont()
        if let state = ProcessInfo.processInfo.environment["CAPACITY_NOTCH_PREVIEW_DICTATION"] {
            previewDictation(state)
            return
        }
        // Hears the default input for a few seconds and says what came back,
        // so a microphone can be checked without holding the shortcut.
        if let seconds = ProcessInfo.processInfo.environment["CAPACITY_NOTCH_MIC_TEST"].flatMap(Double.init) {
            testMicrophone(for: seconds)
            return
        }
        if let folder = ProcessInfo.processInfo.environment["CAPACITY_NOTCH_DUMP_DICTATION"] {
            drawDictation(into: folder)
            NSApplication.shared.terminate(nil)
            return
        }
        applyAppearance(preferences.appearance)
        DiagnosticLog.record(.launched(version: Self.applicationVersion, system: ProcessInfo.processInfo.operatingSystemVersionString))
        DiagnosticLog.record(.dictation(dictation.observation))

        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termination.setEventHandler { NSApplication.shared.terminate(nil) }
        termination.resume()
        self.termination = termination

        let panelController = NotchPanelController(
            store: store,
            music: music,
            teleprompter: teleprompter,
            connect: { [weak self] provider in self?.connect(provider) },
            refresh: { [weak self] provider in self?.refresh(provider) }
        )
        self.panelController = panelController
        panelController.show()
        let capsule = DictationPanelController(controller: dictation)
        dictationPanel = capsule
        panelController.surfaceFrameChanged = { [weak capsule] frame in capsule?.anchor(to: frame) }
        panelController.sharingTypeChanged = { [weak capsule] type in capsule?.setSharingType(type) }
        capsule.anchor(to: panelController.surfaceFrame)
        shortcutCapture = NotificationCenter.default.publisher(for: ModuleShortcutCapture.notification).sink { [weak self] notice in
            MainActor.assumeIsolated {
                guard let self, let active = notice.object as? Bool else { return }
                self.teleprompter.suspendShortcuts(active)
                self.dictation.suspendShortcut(active)
            }
        }
        dictation.openSettings = { [weak self] in self?.showSettings(section: .modules, forDictation: true) }
        if preferences.musicEnabled { music.start() }
        teleprompter.openSettings = { [weak self] in self?.showSettings(section: .modules) }

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
                Self.drawSettings(model: model, section: section, height: 560, into: folder, named: "settings-\(section)")
            }
        }

        // The Teleprompter's row, page and Settings card, drawn from a stand-in
        // with a sample Script — never the person's own — to hold against
        // Paper "Notch — … — Teleprompter" and "Settings — Modules — Teleprompter".
        if let folder = ProcessInfo.processInfo.environment["CAPACITY_NOTCH_DUMP_TELEPROMPTER"] {
            let suite = "capacity-notch-dump-\(UUID().uuidString)"
            if let defaults = UserDefaults(suiteName: suite) {
                let demo = Preferences(defaults: defaults)
                demo.teleprompterEnabled = true
                demo.replaceScript(with: TeleprompterController.sampleScript)
                let standIn = TeleprompterController(preferences: demo, registersShortcuts: false)
                standIn.toggle()
                panelController.drawTeleprompter(standIn, to: folder)
                let model = SettingsModel(preferences: preferences, application: self, store: store, teleprompter: standIn)
                Self.drawSettings(model: model, section: .modules, height: 700, into: folder, named: "settings-teleprompter")
                UserDefaults.standard.removePersistentDomain(forName: suite)
            }
        }

        if ProcessInfo.processInfo.environment["CAPACITY_NOTCH_DUMP_EXIT"] == "1" {
            NSApplication.shared.terminate(nil)
            return
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
        if ProcessInfo.processInfo.environment["CAPACITY_NOTCH_PREVIEW_DICTATION"] != nil || ProcessInfo.processInfo.environment["CAPACITY_NOTCH_DUMP_DICTATION"] != nil { return }
        archive.save(store.snapshots)
        panelController?.stopPointerTracking()
        music.stop()
        dictation.cancel()
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
        // Its last reading leaves the surface with it: the strip says "—" and
        // the other Provider's card takes the width.
        store.apply(UnreadCapacity.snapshot(for: .codex))
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
        store.apply(UnreadCapacity.snapshot(for: .claudeCode))
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

    /// Settings redraw themselves; only the window's own title is AppKit's.
    func applyLanguage() {
        settings?.window?.title = L("Capacity Notch Settings")
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

    /// Settings, both appearances of one section, as pictures.
    private static func drawSettings(model: SettingsModel, section: SettingsSection, height: CGFloat, into folder: String, named name: String) {
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let host = NSHostingView(rootView: SettingsView(model: model, section: section))
            host.appearance = NSAppearance(named: appearance)
            host.frame = NSRect(x: 0, y: 0, width: 760, height: height)
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(
                to: URL(fileURLWithPath: folder).appendingPathComponent("\(name)-\(suffix).png")
            )
        }
    }

    /// Motion/CPU fixture: no microphone, hotkeys, providers or user text.
    private func previewDictation(_ state: String) {
        let suite = "capacity-notch-motion-\(UUID())"
        guard let defaults = UserDefaults(suiteName: suite), let screen = NSScreen.main else { return }
        let demo = Preferences(defaults: defaults)
        let controller = DictationController(preferences: demo, registersShortcuts: false)
        let capsule = DictationPanelController(controller: controller)
        dictationPanel = capsule
        capsule.anchor(to: NSRect(x: screen.frame.midX - 211, y: screen.frame.maxY - 38, width: 422, height: 38))
        // One state, or a sequence such as "recording:3,recognizing:0.8,inserted:1.6"
        // (seconds each), so a recording of the orb moves between them without
        // the capsule leaving in between.
        let states: [String: DictationController.Presentation] = ["recording": .recording, "recognizing": .recognizing, "inserted": .inserted, "copied": .copied, "error": .error]
        let steps: [(DictationController.Presentation, Double)] = state.split(separator: ",").map { part in
            let pieces = part.split(separator: ":")
            return (states[String(pieces[0])] ?? .hidden, pieces.count > 1 ? Double(pieces[1]) ?? 20 : 20)
        }
        dictationPreviewTask = Task {
            var tick = 0
            for (presentation, seconds) in steps {
                controller.preview(presentation)
                for _ in 0..<Int(seconds * 10) {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    tick += 1
                    if presentation == .recording { controller.previewLevel(Float(0.35 + sin(Double(tick) * 0.4) * 0.25)) }
                }
            }
            defaults.removePersistentDomain(forName: suite)
            NSApplication.shared.terminate(nil)
        }
    }

    private func testMicrophone(for seconds: Double) {
        let microphone = DictationMicrophone()
        let peak = LockedPeak()
        let say = { (line: String) in FileHandle.standardError.write(Data((line + "\n").utf8)) }
        microphone.inputChanged = { input in say("input changed: \(input.map { "\($0.sampleRate) Hz, \($0.channels) ch" } ?? "could not restart")") }
        do {
            let input = try microphone.start(level: { peak.note($0) }, limit: {})
            say("input: \(input.sampleRate) Hz, \(input.channels) ch")
        } catch {
            say("start failed: \(error.localizedDescription)"); NSApplication.shared.terminate(nil); return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            let samples = microphone.stop()
            say("samples: \(samples.count) (\(String(format: "%.1f", Double(samples.count) / 16_000)) s), peak level: \(String(format: "%.2f", peak.value))")
            NSApplication.shared.terminate(nil)
        }
    }

    private func drawDictation(into folder: String) {
        let suite = "capacity-notch-dictation-dump-\(UUID())"
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        defer { defaults.removePersistentDomain(forName: suite) }
        let demo = Preferences(defaults: defaults)
        demo.dictationEnabled = true; demo.teleprompterEnabled = true
        demo.replaceScript(with: TeleprompterController.sampleScript)
        var history = DictationHistory()
        history.append("После обновления TypeScript проверь frontend и backend. Оставь комментарий в GitHub, если сборка не пройдёт.", enabled: true)
        history.append("Проверь pull request и добавь тесты перед deploy.", enabled: true)
        demo.dictationHistory = history; demo.dictationKeepsHistory = true
        let dictation = DictationController(preferences: demo, registersShortcuts: false)
        dictation.preview(.recording)
        let teleprompter = TeleprompterController(preferences: demo, registersShortcuts: false)
        let model = SettingsModel(preferences: demo, application: self, teleprompter: teleprompter, dictation: dictation)
        for module in BuiltInModule.allCases {
            model.expandedModule = module
            Self.drawSettings(model: model, section: .modules, height: module == .teleprompter ? 740 : 650, into: folder, named: "modules-\(module.rawValue.lowercased())")
        }
        for (page, name, height) in [(DictationSettingsPage.history, "history", CGFloat(620)), (.replacements, "replacements", 886), (.setup, "setup", 620)] {
            model.dictationPage = page
            Self.drawSettings(model: model, section: .modules, height: height, into: folder, named: name)
        }
        for (state, name) in [(DictationController.Presentation.recording, "recording"), (.recognizing, "recognizing"), (.inserted, "inserted"), (.copied, "copied"), (.error, "error")] {
            dictation.preview(state)
            let host = NSHostingView(rootView: DictationCapsule(controller: dictation).padding(16))
            host.frame = NSRect(x: 0, y: 0, width: 112, height: 112)
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder).appendingPathComponent("capsule-\(name).png"))
        }
    }

    /// Opens Settings; asked for a section — Edit Script asks for Modules —
    /// it goes there even when the window is already open.
    func showSettings(section: SettingsSection? = nil, forDictation: Bool = false) {
        if let settings {
            if let section, let hosting = settings.contentViewController as? NSHostingController<SettingsView> {
                if forDictation { configureDictationSettings(hosting.rootView.model) }
                hosting.rootView = SettingsView(model: hosting.rootView.model, section: section)
            }
            settings.window?.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        let model = SettingsModel(preferences: preferences, application: self, store: store)
        if forDictation { configureDictationSettings(model) }
        settings = Self.settingsWindow(content: SettingsView(model: model, section: section ?? .general))
        settings?.window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func configureDictationSettings(_ model: SettingsModel) {
        model.expandedModule = .dictation
        model.dictationPage = dictation.modelReady && dictation.microphoneAllowed ? .overview : .setup
    }

    /// The drawing's window: 760 by 560, the sidebar running to the top edge
    /// under the traffic lights, no title — the sidebar says where you are.
    private static func settingsWindow(content: some View) -> NSWindowController {
        let hosting = NSHostingController(rootView: content)
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = L("Capacity Notch Settings")
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
        observations.append(contentsOf: dictation.observation.observations)
        observations.append(
            TeleprompterModule.observation(enabled: preferences.teleprompterEnabled, script: preferences.script)
        )

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

/// The loudest level heard, for the microphone check.
private final class LockedPeak: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Float = 0
    func note(_ level: Float) { lock.withLock { peak = max(peak, level) } }
    var value: Float { lock.withLock { peak } }
}
