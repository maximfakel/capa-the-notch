import AppKit
import Combine
import CapacityNotchCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let preferences = Preferences()
    /// The Music Module's reader (ticket 17); running only while the Module is on.
    let music = MusicReader()
    /// Two taps on the trackpad open the surface (ticket 14); reading only
    /// while switched on.
    let trackpadTap = TrackpadTapController()
    /// The Teleprompter Module (ticket 16); its shortcuts registered only
    /// while the Module is on.
    private(set) lazy var dictation = DictationController(preferences: preferences)
    private var dictationPreviewTask: Task<Void, Never>?
    private var shortcutCapture: AnyCancellable?
    private var dictationPanel: DictationPanelController?
    private(set) lazy var teleprompter = TeleprompterController(preferences: preferences)
    private(set) lazy var shelf = ShelfController(preferences: preferences)
    /// The Calendar Module (ticket 23); reads nothing while off.
    private(set) lazy var calendar = CalendarController(preferences: preferences)
    /// The Translator Module (ticket 28); its shortcut registered only while on.
    private(set) lazy var translator = TranslatorController(preferences: preferences)
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
    /// Claude Code's own status line, through the bridge, is the one source
    /// (ADR 0001, amended 2026-10-06): `/usage` no longer prints the plan's
    /// limits, and every run of it was one more process able to sign the
    /// person out.
    private let claude = ClaudeCapacityService(
        capacitySource: ClaudeFileCapacitySource(fileURL: ClaudeStatusLineBridge.defaultSnapshotURL),
        // With CapaTheNotch's mod in place a reply anywhere brings the next
        // reading; without it, only one in a terminal (ticket 31).
        nextReadingFromAnyReply: { ClaudeModSetup.isInstalled(atHome: FileManager.default.homeDirectoryForCurrentUser) }
    )
    /// OpenCode's Go plan: its key read from OpenCode's own file at each
    /// request, and only its usage asked of opencode.ai (ADR 0001, amended).
    private let openCode = OpenCodeCapacityService()
    private var openCodeSnapshots: Task<Void, Never>?
    private var openCodeRefresh: Task<Void, Never>?
    private var panelController: NotchPanelController?
    private var codexSnapshots: Task<Void, Never>?
    private var codexRefresh: Task<Void, Never>?
    private var claudeSnapshots: Task<Void, Never>?
    private var claudeRefresh: Task<Void, Never>?
    /// Hears the bridge write, so Claude Code's Capacity is on the notch the
    /// moment its status line runs rather than at the next turn.
    private var claudeBridgeWatch: BridgeFileWatch?

    /// The surface's pace, with the closed one chosen in Settings ▸
    /// Providers ("Обновлять данные"); read at every turn, so a new choice
    /// applies to the wait already under way.
    private var schedule: RefreshSchedule { RefreshSchedule.standard.closed(every: preferences.refreshInterval) }
    /// Consecutive failures worth retrying, per Provider. A Provider waiting
    /// on a person is not counted here: backing off does not help it.
    private var transientFailures: [Provider: Int] = [:]
    /// Each Provider's last state, to hear one that stops answering once.
    private var lastConnection: [Provider: CapacityConnectionState] = [:]

    /// The reset of the old grants (ticket 33), done before anything asks
    /// macOS about a permission: the microphone, Accessibility and Calendars
    /// answer the first question for the life of the process, so a reset
    /// after it still read as granted (seen on the author's Mac 2026-10-09).
    private let firstRun: Bool
    private let oldGrantReset: OldGrantReset.Outcome

    override init() {
        // Launches that only draw pictures change nothing of macOS's.
        let drawsPictures = ProcessInfo.processInfo.environment.keys.contains {
            $0.hasPrefix("CAPACITY_NOTCH_DUMP_") && $0 != "CAPACITY_NOTCH_DUMP_REPORT"
        }
        let launchPreferences = Preferences()
        firstRun = launchPreferences.needsOnboarding
        oldGrantReset = drawsPictures ? .notNeeded : OldGrantResetRunner.runOnce(preferences: launchPreferences, firstRun: firstRun)
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
        // Files left from dragging, should the last run not have quit cleanly.
        ShelfDragFiles.removeAll()
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
        if let folder = ProcessInfo.processInfo.environment["CAPACITY_NOTCH_DUMP_KAPA"] {
            KapaPictures.draw(into: folder)
            NSApplication.shared.terminate(nil)
            return
        }
        if let seconds = ProcessInfo.processInfo.environment["CAPACITY_NOTCH_KAPA_PLAYGROUND"].flatMap(Double.init) {
            KapaPictures.play(for: seconds)
            return
        }
        if let folder = ProcessInfo.processInfo.environment["CAPACITY_NOTCH_DUMP_TRANSLATOR"] {
            TranslatorPictures.draw(into: folder)
            NSApplication.shared.terminate(nil)
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
            shelf: shelf,
            calendar: calendar.reader,
            translator: translator,
            connect: { [weak self] provider in self?.connect(provider) },
            refresh: { [weak self] provider in self?.refresh(provider) },
            openProviderSettings: { [weak self] in self?.showSettings(section: .providers) }
        )
        self.panelController = panelController
        panelController.show()
        // Quiet while a Script is read aloud (ADR 0007); drawn ahead of use.
        Sounds.shared.isQuiet = { [weak self] in self?.teleprompter.playback.state == .running }
        Sounds.shared.prepare()
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
                self.translator.suspendShortcut(active)
            }
        }
        dictation.openSettings = { [weak self] in self?.showSettings(section: .modules, forDictation: true) }
        translator.openSettings = { [weak self] in self?.showTranslatorSettings() }
        // Typing on its page keeps the surface open and gives it the keyboard.
        translator.holdSurfaceOpen = { [weak self] in self?.store.pin() }
        // The shortcut brings the selection to the notch (2026-10-07).
        translator.showOnSurface = { [weak self] in
            self?.panelController?.show()
            self?.panelController?.openTranslator()
        }
        translator.closeSurface = { [weak self] in self?.store.dismiss() }
        if preferences.musicEnabled { music.start() }
        calendar.resume()
        trackpadTap.onDoubleTap = { [weak self] in self?.peekSurface() }
        if preferences.opensOnTrackpadTap { trackpadTap.setEnabled(true) }
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
            drawProviderSettings(into: folder)
        }

        // The Shelf's card with every switch on, from a stand-in, to hold
        // against "Settings — Modules — Shelf".
        if let folder = ProcessInfo.processInfo.environment["CAPACITY_NOTCH_DUMP_SETTINGS"] {
            let suite = "capacity-notch-dump-\(UUID().uuidString)"
            if let defaults = UserDefaults(suiteName: suite) {
                let demo = Preferences(defaults: defaults)
                demo.shelfEnabled = true
                let standIn = ShelfController(preferences: demo)
                standIn.setTakesClipboardImages(true)
                standIn.setKeepsText(true)
                standIn.setExcludedApplications(["com.apple.Safari"])
                let model = SettingsModel(preferences: preferences, application: self, store: store, shelf: standIn)
                model.expandedModule = .shelf
                Self.drawSettings(model: model, section: .modules, height: 900, into: folder, named: "settings-shelf")
                standIn.setEnabled(false)
                UserDefaults.standard.removePersistentDomain(forName: suite)
            }
        }

        // Onboarding, every step in both appearances, for the same comparison.
        if let folder = ProcessInfo.processInfo.environment["CAPACITY_NOTCH_DUMP_ONBOARDING"] {
            for step in OnboardingModel.Step.allCases {
                let model = OnboardingModel(preferences: preferences, application: self, store: store, notifications: notifications, step: step)
                Self.draw(OnboardingView(model: model), height: 560, into: folder, named: "onboarding-\(step.rawValue + 1)-\(step)")
            }
            // The permissions asked again after the reset, and the reset
            // failed (ticket 33), to hold against Paper "Permissions again — …".
            for again in [OldGrantReset.Opening.permissionsAgain, .permissionsNotReset] {
                let model = OnboardingModel(preferences: preferences, application: self, store: store, notifications: notifications, permissionsAgain: again)
                Self.draw(OnboardingView(model: model), height: 560, into: folder, named: "onboarding-2-\(again)")
            }
            // The two Modules switched on, from stand-ins that touch neither
            // the person's Script nor their Dictation.
            let suite = "capacity-notch-dump-\(UUID().uuidString)"
            if let defaults = UserDefaults(suiteName: suite) {
                let demo = Preferences(defaults: defaults)
                demo.teleprompterEnabled = true
                demo.dictationEnabled = true
                let teleprompter = TeleprompterController(preferences: demo, registersShortcuts: false)
                let dictation = DictationController(preferences: demo, registersShortcuts: false)
                for step in [OnboardingModel.Step.teleprompter, .dictation] {
                    let model = OnboardingModel(preferences: preferences, application: self, store: store, notifications: notifications, step: step, teleprompter: teleprompter, dictation: dictation)
                    Self.draw(OnboardingView(model: model), height: 560, into: folder, named: "onboarding-\(step.rawValue + 1)-\(step)-on")
                }
                UserDefaults.standard.removePersistentDomain(forName: suite)
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
        observeOpenCode()

        // Anyone who had used a build signed before the certificate is asked
        // again, once the old grants were reset in init (ticket 33).
        let askAgain = OldGrantReset.opening(after: oldGrantReset, firstRun: firstRun, preferences: preferences)

        guard !firstRun else {
            // A first launch has no bridge of the old application's to move.
            preferences.claudeBridgeMoveSettled = true
            startOnboarding(force: false)
            return
        }
        connectChosenProviders()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let askAgain { self.startOnboarding(force: false, permissionsAgain: askAgain) }
            // The permissions asked again after the reset take this one
            // launch; the questions below wait for the next. A reset that
            // failed is shown at every launch until it is done, so it does
            // not hold them back.
            if askAgain == .permissionsAgain {
                self.keepClaudeModCurrent()
                return
            }
            // Setting the status line up points an old bundle's bridge at
            // this copy too, so one question at launch, not two.
            if self.offerClaudeStatusLineOnce() {
                self.preferences.claudeBridgeMoveSettled = true
            } else if !self.offerClaudeModOnce() {
                self.offerToMoveClaudeBridge()
            }
            // Agreed to before: this copy's mod, brought up to date — a new
            // version of the application, or one moved — with no question.
            self.keepClaudeModCurrent()
        }
    }

    // MARK: - The bridge, after the rename

    /// Once, on the first launch as CapaTheNotch.app: Claude Code's settings
    /// may still run the status-line bridge from CapacityNotch.app, and its
    /// status line stops when that bundle goes. Asked only where the bridge
    /// has run — it leaves its reading in this application's own folder — and
    /// Claude Code's settings are opened only after a yes (ADR 0001, amended).
    private func offerToMoveClaudeBridge() {
        guard !preferences.claudeBridgeMoveSettled else { return }
        let bundle = Bundle.main.bundleURL
        // An installed copy only: a build run from .build/ is not where the
        // status line should point, and must not settle the question either.
        guard bundle.pathExtension == "app", bundle.lastPathComponent != ClaudeBridgeMove.oldBundle,
              bundle.deletingLastPathComponent().lastPathComponent == "Applications" else { return }
        preferences.claudeBridgeMoveSettled = true

        let folder = ClaudeStatusLineBridge.defaultSnapshotURL.deletingLastPathComponent()
        let bridgeHasRun = ["claude-capacity.json", "claude-bridge-last-unreadable.json"].contains {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
        let bridge = bundle.appendingPathComponent(ClaudeBridgeMove.bridgeInBundle).path
        // A path with a space would split the status line's command in two.
        guard bridgeHasRun, !bridge.contains(where: \.isWhitespace) else { return }

        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L("Move Claude Code's status line to CapaTheNotch?")
        alert.informativeText = L("Capacity Notch is now CapaTheNotch.app. If ~/.claude/settings.json runs the status-line bridge from CapacityNotch.app, Claude Code's status line stops once that app is gone — yours too, if it runs through the bridge. CapaTheNotch can point that one path at this copy. It opens Claude Code's settings only for this, keeps nothing it reads and changes nothing else.")
        alert.addButton(withTitle: L("Update Path"))
        alert.addButton(withTitle: L("Leave It"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let result = NSAlert()
        result.alertStyle = .informational
        do {
            let moved = try ClaudeBridgeMove.move(home: FileManager.default.homeDirectoryForCurrentUser, to: bridge)
            if moved.isEmpty {
                result.messageText = L("Nothing to change")
                result.informativeText = L("No path to CapacityNotch.app was found in Claude Code's settings.")
            } else {
                result.messageText = L("Claude Code's status line now runs the bridge from this copy.")
                result.informativeText = L("Changed: %@. CapacityNotch.app can go to the Trash.", moved.map { "~/.claude/" + $0.lastPathComponent }.joined(separator: ", "))
            }
        } catch {
            result.alertStyle = .warning
            result.messageText = L("Claude Code's settings were not changed")
            result.informativeText = error.localizedDescription
        }
        result.runModal()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["CAPACITY_NOTCH_PREVIEW_DICTATION"] != nil || ProcessInfo.processInfo.environment["CAPACITY_NOTCH_DUMP_DICTATION"] != nil { return }
        archive.save(store.snapshots)
        ShelfDragFiles.removeAll()
        panelController?.stopPointerTracking()
        music.stop()
        dictation.cancel()
        stopCodex()
        stopClaudeCode()
        stopOpenCode()
    }

    // MARK: - The surface

    // This and several methods below switch on the Provider by hand. Their
    // services connect differently — Codex directly, Claude Code and OpenCode
    // only after consent, OpenCode at its own five-minute pace — and an
    // exhaustive switch makes each new Provider a compile error everywhere
    // that must know about it. With three, the observe/connect/stop methods
    // are close copies; a shared Provider handle is the next step if a fourth
    // comes.
    private func isConnected(_ provider: Provider) -> Bool {
        switch provider {
        case .codex: codexRefresh != nil
        case .claudeCode: claudeRefresh != nil
        case .openCode: openCodeRefresh != nil
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

    /// Two taps on the trackpad: the surface for a glance, closing by itself.
    func peekSurface() {
        panelController?.show()
        panelController?.peek()
    }

    /// Starts whatever the person left connected. Called once at launch and
    /// again when onboarding finishes, and starting a Provider that is already
    /// running is a no-op, so neither doubles anything.
    ///
    /// At most two, the first in order, should more have been chosen.
    func connectChosenProviders() {
        for provider in ProviderSelection.toConnect(preferences.connectedProviders) {
            switch provider {
            case .codex: connectCodex()
            case .claudeCode: connectClaudeCode()
            case .openCode: connectOpenCode()
            }
        }
    }

    func connectCodex() {
        guard codexRefresh == nil else { return }
        preferences.setConnectsAtLaunch(.codex, true)

        codexRefresh = Task { [weak self, codex] in
            await codex.connect()
            while !Task.isCancelled {
                guard await self?.waitForTurn(of: .codex) == true else { return }
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
        // answered is not consent, it is nagging. Turned on again later, the
        // status line agreed to is set up again; one not agreed to is asked
        // about, never set up silently.
        guard !preferences.claudeConsentGiven else {
            if preferences.claudeStatusLineAgreed {
                setUpClaudeStatusLine()
            }
            if preferences.claudeModAgreed {
                setUpClaudeMod()
            }
            // Whatever is still unanswered, in one question.
            askToSetUpClaude(
                statusLine: !preferences.claudeStatusLineAgreed,
                mod: !preferences.claudeModAgreed && claudeModCanRun
            )
            connectClaudeCode()
            return
        }

        let withMod = claudeModCanRun
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L("Turn on Claude Code?")
        alert.informativeText = withMod
            ? L("CapaTheNotch adds its bridge to Claude Code's status line in ~/.claude/settings.json, and a small Claude Code mod in ~/.claude/skills/capathenotch that hands it only the plan's limits after each reply — in the desktop app and VS Code too. Your own status line keeps working, and turning Claude Code off removes both.")
            : L("CapaTheNotch adds its bridge to Claude Code's status line in ~/.claude/settings.json. Your own status line keeps working, and turning Claude Code off puts everything back.")
        alert.addButton(withTitle: L("Turn On"))
        alert.addButton(withTitle: L("Cancel"))

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        preferences.claudeConsentGiven = true
        preferences.claudeStatusLineAsked = true
        preferences.claudeStatusLineAgreed = true
        setUpClaudeStatusLine()
        if withMod {
            preferences.claudeModAsked = true
            preferences.claudeModAgreed = true
            setUpClaudeMod()
        }
        connectClaudeCode()
    }

    /// A deliberate Disconnect: remembered, so the next launch honours it.
    /// The status line CapaTheNotch set up goes with it, and what it
    /// replaced comes back.
    func disconnectClaudeCode() {
        preferences.setConnectsAtLaunch(.claudeCode, false)
        stopClaudeCode()
        store.apply(UnreadCapacity.snapshot(for: .claudeCode))
        if let setUp = preferences.claudeStatusLineSetUp {
            do {
                try ClaudeStatusLineSetup.uninstall(atHome: FileManager.default.homeDirectoryForCurrentUser, previous: setUp.previous)
                preferences.claudeStatusLineSetUp = nil
            } catch {
                tellClaudeSettingsUnchanged(error)
            }
        }
        // The mod goes too: only CapaTheNotch's own folder, which it marks.
        // One that cannot be removed shows in Copy Diagnostics as installed.
        _ = try? ClaudeModSetup.uninstall(atHome: FileManager.default.homeDirectoryForCurrentUser)
    }

    // MARK: - Claude Code's status line (ADR 0001, amended 2026-10-06)

    /// The bridge inside this copy, for Claude Code to run; nil for a build
    /// outside an Applications folder, whose path would not last, or for a
    /// path with a space, which would split the command in two.
    private var installedBridge: String? {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app", bundle.deletingLastPathComponent().lastPathComponent == "Applications" else { return nil }
        let bridge = bundle.appendingPathComponent(ClaudeBridgeMove.bridgeInBundle).path
        return bridge.contains(where: \.isWhitespace) ? nil : bridge
    }

    /// Sets the bridge as Claude Code's status line, once agreed to. This
    /// copy's bridge already there — set up by hand from the README — is
    /// left as it is, and is not taken away on Turn Off.
    private func setUpClaudeStatusLine() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        // A build run from outside Applications is not set up; Copy
        // Diagnostics says the status line is not.
        guard let bridge = installedBridge, !ClaudeStatusLineSetup.isInstalled(atHome: home, bridge: bridge) else { return }
        do {
            let result = try ClaudeStatusLineSetup.install(atHome: home, bridge: bridge)
            if result.changed { preferences.claudeStatusLineSetUp = .init(previous: result.previous) }
        } catch {
            tellClaudeSettingsUnchanged(error)
        }
    }

    /// Someone who connected Claude Code before CapaTheNotch set its status
    /// line up is asked once at launch, never edited silently. Whether it
    /// asked.
    @discardableResult
    private func offerClaudeStatusLineOnce() -> Bool {
        guard preferences.connectedProviders.contains(.claudeCode), preferences.claudeConsentGiven,
              !preferences.claudeStatusLineAsked, let bridge = installedBridge else { return false }
        if ClaudeStatusLineSetup.isInstalled(atHome: FileManager.default.homeDirectoryForCurrentUser, bridge: bridge) {
            preferences.claudeStatusLineAsked = true
            return false
        }
        askToSetUpClaudeStatusLine()
        return true
    }

    /// The status line alone, for someone who turned Claude Code on before
    /// it was set up this way, or said "Not Now".
    private func askToSetUpClaudeStatusLine() {
        askToSetUpClaude(statusLine: true, mod: false)
    }

    /// One question for whatever of Claude Code's setup is still unanswered:
    /// the status line, the mod, or both. "Not Now" is remembered as asked,
    /// and the next Turn On asks again rather than setting anything up.
    private func askToSetUpClaude(statusLine: Bool, mod: Bool) {
        guard installedBridge != nil, statusLine || mod else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        switch (statusLine, mod) {
        case (true, false):
            alert.messageText = L("Set up Claude Code's status line?")
            alert.informativeText = L("CapaTheNotch now reads Claude Code's Capacity from its status line. It can add its bridge there, in ~/.claude/settings.json. Your own status line keeps working, and turning Claude Code off puts everything back.")
        case (false, true):
            alert.messageText = L("Keep Claude Code's Capacity fresh in the desktop app?")
            alert.informativeText = L("CapaTheNotch can add a small Claude Code mod in ~/.claude/skills/capathenotch. After each reply — in the desktop app, VS Code or a terminal — it hands CapaTheNotch only the plan's limits: no prompts, no code, no sign-in. settings.json is not changed, and turning Claude Code off removes it.")
        default:
            alert.messageText = L("Set up Claude Code for CapaTheNotch?")
            alert.informativeText = L("CapaTheNotch can add its bridge to Claude Code's status line in ~/.claude/settings.json, and a small Claude Code mod in ~/.claude/skills/capathenotch that hands it only the plan's limits after each reply — in the desktop app and VS Code too. Your own status line keeps working, and turning Claude Code off removes both.")
        }
        alert.addButton(withTitle: L("Set Up"))
        alert.addButton(withTitle: L("Not Now"))
        let answer = alert.runModal()
        if statusLine { preferences.claudeStatusLineAsked = true }
        if mod { preferences.claudeModAsked = true }
        guard answer == .alertFirstButtonReturn else { return }
        if statusLine {
            preferences.claudeStatusLineAgreed = true
            setUpClaudeStatusLine()
        }
        if mod {
            preferences.claudeModAgreed = true
            setUpClaudeMod()
        }
    }

    // MARK: - Claude Code's mod (ADR 0001, amended 2026-10-08)

    /// The mod as shipped in this copy, copied out on consent.
    private var bundledClaudeMod: URL? {
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("ClaudeMod", isDirectory: true)
            .appendingPathComponent(ClaudeModSetup.name, isDirectory: true),
            FileManager.default.fileExists(atPath: folder.path) else { return nil }
        return folder
    }

    /// The bridge the mod runs: this copy's, once installed in an
    /// Applications folder. The mod runs it by argv, so a space is fine.
    private var bridgeForClaudeMod: String? {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app", bundle.deletingLastPathComponent().lastPathComponent == "Applications" else { return nil }
        return bundle.appendingPathComponent(ClaudeBridgeMove.bridgeInBundle).path
    }

    /// Whether some Claude Code on this Mac runs mods (2.1.287, or 2.1.286
    /// in the desktop app), read from what is on disk. Older or not found:
    /// the mod is not offered, and Settings says why Capacity may lag.
    private var claudeModSupport: ClaudeModSupport {
        ClaudeModSupport.onThisMac(home: FileManager.default.homeDirectoryForCurrentUser)
    }

    private var claudeModCanRun: Bool {
        bridgeForClaudeMod != nil && bundledClaudeMod != nil && claudeModSupport == .supported
    }

    /// Copies the mod to where Claude Code loads it, once agreed to. A
    /// folder of that name CapaTheNotch did not make is left alone, and Copy
    /// Diagnostics says the mod is not installed.
    private func setUpClaudeMod() {
        guard claudeModCanRun, let bridge = bridgeForClaudeMod, let source = bundledClaudeMod else { return }
        _ = try? ClaudeModSetup.install(from: source, atHome: FileManager.default.homeDirectoryForCurrentUser, bridge: bridge)
    }

    /// For someone connected and agreed: the mod as this copy ships it.
    private func keepClaudeModCurrent() {
        guard preferences.connectedProviders.contains(.claudeCode), preferences.claudeModAgreed else { return }
        setUpClaudeMod()
    }

    /// Someone who connected Claude Code before the mod existed is asked
    /// once at launch, never set up silently. Whether it asked.
    @discardableResult
    private func offerClaudeModOnce() -> Bool {
        guard preferences.connectedProviders.contains(.claudeCode), preferences.claudeConsentGiven,
              !preferences.claudeModAsked, claudeModCanRun else { return false }
        if ClaudeModSetup.isInstalled(atHome: FileManager.default.homeDirectoryForCurrentUser) {
            preferences.claudeModAsked = true
            preferences.claudeModAgreed = true
            return false
        }
        askToSetUpClaude(statusLine: false, mod: true)
        return true
    }

    /// What Settings ▸ Providers ▸ Claude Code shows under its header: why
    /// Capacity may lag, the mod's row, and whether to offer the terminal.
    /// Read from disk each time; nothing is run.
    var claudeCodeSettings: ClaudeCodeSettings {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ClaudeCodeSettings.of(
            installed: ClaudeModSetup.isInstalled(atHome: home),
            support: claudeModSupport,
            newestVersion: ClaudeModSupport.newestVersion(home: home),
            canInstallHere: bridgeForClaudeMod != nil && bundledClaudeMod != nil
        )
    }

    /// "Добавить" in Settings: the person's own deliberate action, so it is
    /// done at once, with no question in between, and remembered as agreed —
    /// the next launch keeps it up to date as it would after Set Up.
    func addClaudeMod() {
        guard claudeModCanRun, let bridge = bridgeForClaudeMod, let source = bundledClaudeMod else { return }
        do {
            try ClaudeModSetup.install(from: source, atHome: FileManager.default.homeDirectoryForCurrentUser, bridge: bridge)
            preferences.claudeModAsked = true
            preferences.claudeModAgreed = true
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L("The mod was not added")
            alert.informativeText = error as? ClaudeModSetup.SetupError == .notOurs
                ? L("~/.claude/skills/capathenotch is already there, and CapaTheNotch did not put it there, so it is left alone.")
                : error.localizedDescription
            alert.runModal()
        }
    }

    /// "Удалить" in Settings: only CapaTheNotch's own, marked folder goes.
    /// Remembered as no longer agreed, so a launch does not put it back; a
    /// later Turn On asks again.
    func removeClaudeMod() {
        _ = try? ClaudeModSetup.uninstall(atHome: FileManager.default.homeDirectoryForCurrentUser)
        preferences.claudeModAsked = true
        preferences.claudeModAgreed = false
    }

    /// "Открыть Терминал": Terminal opens a small `.command` file that starts
    /// `claude` — no arguments, nothing typed for the person. Opening a file
    /// in Terminal needs no permission; scripting it would ask for
    /// Automation.
    func openClaudeInTerminal() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let file = try? ClaudeTerminal.write(home: home, notFound: L("Claude Code was not found. Install it, or start claude yourself.")),
              let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            tellTerminalUnopened()
            return
        }
        NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            guard error != nil else { return }
            DispatchQueue.main.async { [weak self] in self?.tellTerminalUnopened() }
        }
    }

    private func tellTerminalUnopened() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Terminal could not be opened.")
        alert.runModal()
    }

    /// The mod's state, for Copy Diagnostics: one word, no path.
    private var claudeModState: ClaudeModState {
        ClaudeModState.of(
            installed: ClaudeModSetup.isInstalled(atHome: FileManager.default.homeDirectoryForCurrentUser),
            asked: preferences.claudeModAsked,
            agreed: preferences.claudeModAgreed,
            support: claudeModSupport
        )
    }

    private func tellClaudeSettingsUnchanged(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Claude Code's settings were not changed")
        alert.informativeText = error as? ClaudeStatusLineSetup.SetupError == .notASettingsObject
            ? L("~/.claude/settings.json is not JSON CapaTheNotch can safely change. Add the status line by hand, as the README shows.")
            : error.localizedDescription
        alert.runModal()
    }

    private func stopClaudeCode() {
        claudeRefresh?.cancel()
        claudeRefresh = nil
        claudeBridgeWatch = nil

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
                guard await self?.waitForTurn(of: .claudeCode) == true else { return }
                guard !Task.isCancelled else { return }
                await claude.refresh()
            }
        }
        // The turn above stays, for a watch that misses a write.
        claudeBridgeWatch = BridgeFileWatch(file: ClaudeStatusLineBridge.defaultSnapshotURL) { [claude] in
            Task { await claude.refresh() }
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

    /// Waits for this Provider's next read; false once the loop is
    /// cancelled. The wait is weighed again every few seconds against the
    /// pace as it is then — a choice made in Settings meanwhile, the surface
    /// opened or closed — so fifteen minutes chosen down to one does not
    /// first sit out the fifteen.
    private func waitForTurn(of provider: Provider) async -> Bool {
        let started = Date()
        while !Task.isCancelled {
            let left = nextDelay(for: provider) - Date().timeIntervalSince(started)
            guard left > 0 else { return true }
            try? await Task.sleep(for: .seconds(min(left, 15)))
        }
        return false
    }

    // MARK: - Onboarding and Settings

    private var onboarding: NSWindowController?
    private var settings: NSWindowController?

    /// Shows the first-run path. Re-running it opens the same window rather
    /// than a second one, and changes nothing until it is finished.
    func startOnboarding(force: Bool, permissionsAgain: OldGrantReset.Opening? = nil) {
        if force { preferences.hasFinishedOnboarding = false }

        if let onboarding {
            onboarding.window?.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        let model = OnboardingModel(
            preferences: preferences, application: self, store: store, notifications: notifications,
            permissionsAgain: permissionsAgain
        )
        onboarding = Self.settingsWindow(
            titled: L("Welcome to CapaTheNotch"),
            content: OnboardingView(model: model)
        )
        onboarding?.window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// The reset of the old grants, tried again from onboarding (ticket 33).
    /// Once it works, CapaTheNotch opens again to ask: this process keeps
    /// the answers macOS gave it before.
    func retryOldGrantReset() -> OldGrantReset.Outcome {
        let outcome = OldGrantResetRunner.runOnce(preferences: preferences, firstRun: false)
        if outcome == .reset {
            OldGrantReset.resetWhileRunning(preferences: preferences)
            relaunch()
        }
        return outcome
    }

    /// The person removed the old grants in Privacy & Security themselves;
    /// CapaTheNotch opens again to ask, for the same reason.
    func oldGrantsRemovedByHand() {
        OldGrantReset.removedByHand(preferences: preferences)
        relaunch()
    }

    /// A new copy of this application, then this one quits.
    private func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
        }
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

    /// Two taps on the trackpad open the surface, or no longer do. Off, the
    /// trackpad is not read (ADR 0004).
    func setTrackpadTapEnabled(_ enabled: Bool) {
        preferences.opensOnTrackpadTap = enabled
        trackpadTap.setEnabled(enabled)
    }

    /// Settings redraw themselves; only the window's own title is AppKit's.
    func applyLanguage() {
        settings?.window?.title = L("CapaTheNotch Settings")
        onboarding?.window?.title = L("Welcome to CapaTheNotch")
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

    /// Settings ▸ Providers in each state the mockups draw — "Claude mod
    /// working", "— not added", "— Claude Code too old for the mod" — and
    /// the "?" note, in Russian as drawn and once in English. From stand-ins:
    /// the person's preferences and `~/.claude` are not read or touched.
    private func drawProviderSettings(into folder: String) {
        let suite = "capacity-notch-providers-dump-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let demo = Preferences(defaults: defaults)
        demo.setConnectsAtLaunch(.codex, true)
        demo.setConnectsAtLaunch(.claudeCode, true)
        let windows = [
            QuotaWindow(id: "a", label: "5 hour", durationMinutes: 300, usedFraction: 0.4, resetsAt: Date().addingTimeInterval(7_200)),
            QuotaWindow(id: "b", label: "Weekly", durationMinutes: 10_080, usedFraction: 0.3, resetsAt: Date().addingTimeInterval(300_000)),
        ]
        let codex = CapacitySnapshot(provider: .codex, capturedAt: Date().addingTimeInterval(-120), windows: windows, connectionState: .fresh)
        let earlier = Calendar.current.date(bySettingHour: 13, minute: 56, second: 0, of: Date()) ?? Date()
        let fresh = CapacitySnapshot(provider: .claudeCode, capturedAt: Date(), windows: windows, connectionState: .fresh)
        let stale = CapacitySnapshot(provider: .claudeCode, capturedAt: earlier, windows: windows, connectionState: .stale)
        let states: [(String, ClaudeCodeSettings, CapacitySnapshot)] = [
            ("mod-working", .of(installed: true, support: .supported, newestVersion: ClaudeCodeVersion("2.1.290"), canInstallHere: true), fresh),
            ("mod-not-added", .of(installed: false, support: .supported, newestVersion: ClaudeCodeVersion("2.1.290"), canInstallHere: true), stale),
            ("mod-too-old", .of(installed: false, support: .tooOld, newestVersion: ClaudeCodeVersion("2.1.250"), canInstallHere: true), stale),
        ]
        let language = Localization.current
        defer { Localization.current = language }
        for (code, chosen) in [("ru", AppLanguage.russian), ("en", .english)] {
            Localization.current = chosen
            for (name, state, claude) in states where code == "ru" || name == "mod-not-added" {
                let store = CapacityNotchStore(snapshots: [codex, claude, UnreadCapacity.snapshot(for: .openCode)])
                let model = SettingsModel(preferences: demo, application: self, store: store, claudeCode: state)
                Self.drawSettings(model: model, section: .providers, height: 760, into: folder, named: "providers-\(name)-\(code)")
            }
            Self.draw(
                SettingsNoteView(note: .mod)
                    .background(RoundedRectangle(cornerRadius: 10).fill(SettingsPalette.card))
                    .padding(20)
                    .frame(width: 760, alignment: .leading)
                    .background(SettingsPalette.window),
                height: 200, into: folder, named: "providers-note-mod-\(code)"
            )
            Self.draw(
                SettingsNoteView(note: .terminal)
                    .background(RoundedRectangle(cornerRadius: 10).fill(SettingsPalette.card))
                    .padding(20)
                    .frame(width: 760, alignment: .leading)
                    .background(SettingsPalette.window),
                height: 200, into: folder, named: "providers-note-terminal-\(code)"
            )
        }
    }

    /// Settings, both appearances of one section, as pictures.
    private static func drawSettings(model: SettingsModel, section: SettingsSection, height: CGFloat, into folder: String, named name: String) {
        draw(SettingsView(model: model, section: section), height: height, into: folder, named: name)
    }

    private static func draw(_ view: some View, height: CGFloat, into folder: String, named name: String) {
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let host = NSHostingView(rootView: view)
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
        settings = Self.settingsWindow(titled: L("CapaTheNotch Settings"), content: SettingsView(model: model, section: section ?? .general))
        settings?.window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func showTranslatorSettings() {
        showSettings(section: .modules)
        (settings?.contentViewController as? NSHostingController<SettingsView>)?.rootView.model.expandedModule = .translator
    }

    private func configureDictationSettings(_ model: SettingsModel) {
        model.expandedModule = .dictation
        model.dictationPage = dictation.modelReady && dictation.microphoneAllowed ? .overview : .setup
    }

    /// The drawing's window, for Settings and onboarding alike: 760 by 560,
    /// the sidebar running to the top edge under the traffic lights, no title
    /// shown — the sidebar says where you are.
    private static func settingsWindow(titled title: String, content: some View) -> NSWindowController {
        let hosting = NSHostingController(rootView: content)
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.isMovableByWindowBackground = true
        window.setContentSize(NSSize(width: 760, height: 560))
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
        case .openCode:
            disconnectOpenCode()
        }
    }

    /// Moves the surface to whichever display is now chosen.
    func useChosenDisplay() {
        panelController?.useDisplay(preferences.preferredDisplayID)
    }

    /// Starts one Provider from its own card.
    func connect(_ provider: Provider) {
        // Wherever it is asked from — Settings, a card's refresh — a third
        // Provider is not connected while two are on.
        guard preferences.canConnect(provider) else { return }
        switch provider {
        case .codex:
            connectCodex()
        case .claudeCode:
            requestClaudeCodeConnection()
        case .openCode:
            requestOpenCodeConnection()
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
            // Nothing can pull a reading from Claude Code: the file is read
            // again and, if nothing is newer, the card says where the next
            // one comes from and how old this one is — for a few seconds,
            // then the gauges come back.
            let claude = claude
            Task {
                await claude.refresh(asked: true)
                try? await Task.sleep(for: .seconds(6))
                await claude.refresh()
            }
        case .openCode:
            // A person asked: answered at once, past the five-minute pace.
            let openCode = openCode
            Task { await openCode.refresh(force: true) }
        }
    }

    /// Reads every connected Provider at once, without waiting for its turn.
    func refreshNow() {
        transientFailures.removeAll()

        let codex = codex
        let claude = claude
        let openCode = openCode
        Task {
            await codex.refresh()
            await claude.refresh()
            await openCode.refresh(force: true)
        }
    }

    /// Everything a bug report may carry about this machine, and nothing else.
    func diagnosticReport() -> String {
        var observations: [String] = []
        if let bridge = ClaudeStatusLineBridge.observation() {
            observations.append(bridge)
        }
        if !ClaudeStatusLineSetup.runsABridge(atHome: FileManager.default.homeDirectoryForCurrentUser) {
            observations.append("claude-status-line-not-set-up")
        }
        observations.append(claudeModState.diagnosticCode)
        if CodexInstallation.locate() == nil {
            observations.append("codex-binary-not-found")
        }
        if !LaunchAtLogin.isEnabled {
            observations.append("launch-at-login-off")
        }
        if preferences.musicEnabled, music.isUnreadable {
            observations.append(MusicModule.unreadableCode)
        }
        if let trackpadTap = trackpadTap.status.diagnosticCode { observations.append(trackpadTap) }
        observations.append(contentsOf: dictation.observation.observations)
        observations.append(contentsOf: translator.observations)
        observations.append(
            TeleprompterModule.observation(enabled: preferences.teleprompterEnabled, script: preferences.script)
        )
        observations.append(ShelfModule.observation(enabled: shelf.isEnabled, shelf: shelf.shelf, clippings: shelf.clippings))
        if shelf.isEnabled, shelf.clipboardRefused { observations.append("shelf-clipboard-refused") }
        if shelf.isEnabled, shelf.screenshotFolderRefused { observations.append("shelf-screenshot-folder-refused") }
        // A count and a state, never a title.
        observations.append(CalendarModule.observation(
            enabled: calendar.reader.isEnabled,
            access: calendar.reader.access,
            eventsToday: calendar.reader.day(at: Date()).eventCount
        ))

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
        if !alertDecider.recovered.isEmpty { Sounds.shared.play(.capacityRecovered) }

        // A Provider that was answering and stopped: once, on the change,
        // and not for a blip that is retried, nor one never connected this
        // session — that would sound at every launch (ADR 0007).
        let stopped: Bool
        switch snapshot.connectionState {
        case let .disconnected(reason): stopped = !reason.isTransient
        // Old numbers alone are only time passing; a reason is a failure.
        case .stale: stopped = snapshot.statusReason.map { !$0.isTransient } ?? false
        case .mock, .connecting, .fresh: stopped = false
        }
        if stopped, lastConnection[snapshot.provider] == .fresh { Sounds.shared.play(.providerStopped) }
        lastConnection[snapshot.provider] = snapshot.connectionState

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

    private func observeOpenCode() {
        let stream = openCode.snapshots
        openCodeSnapshots = Task { [weak self] in
            for await snapshot in stream {
                self?.store.apply(snapshot)
                self?.record(snapshot)
            }
        }
    }

    func requestOpenCodeConnection() {
        guard !preferences.openCodeConsentGiven else {
            connectOpenCode()
            return
        }

        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L("Turn on OpenCode?")
        alert.informativeText = L("CapaTheNotch reads your OpenCode Go key from OpenCode's own file and asks opencode.ai only for your plan's percentages and reset times — every five minutes, and when you refresh. The key is kept nowhere and sent nowhere else.")
        alert.addButton(withTitle: L("Turn On"))
        alert.addButton(withTitle: L("Cancel"))

        guard alert.runModal() == .alertFirstButtonReturn else {
            // Declined: the switch Settings turned on goes back off, so no
            // later launch reads the key unasked.
            preferences.setConnectsAtLaunch(.openCode, false)
            store.apply(UnreadCapacity.snapshot(for: .openCode))
            return
        }
        preferences.openCodeConsentGiven = true
        connectOpenCode()
    }

    /// Never without consent, from wherever it is called — the next launch
    /// included (ADR 0001, amended).
    func connectOpenCode() {
        guard preferences.openCodeConsentGiven else { return }
        guard preferences.setConnectsAtLaunch(.openCode, true) else { return }
        openCodeRefresh?.cancel()

        // Asked on the surface's pace like the others; the service itself
        // keeps opencode.ai to once every five minutes.
        openCodeRefresh = Task { [weak self, openCode] in
            await openCode.connect()
            while !Task.isCancelled {
                guard await self?.waitForTurn(of: .openCode) == true else { return }
                guard !Task.isCancelled else { return }
                await openCode.refresh()
            }
        }
    }

    /// A deliberate Disconnect: remembered, so the next launch honours it.
    func disconnectOpenCode() {
        preferences.setConnectsAtLaunch(.openCode, false)
        stopOpenCode()
        store.apply(UnreadCapacity.snapshot(for: .openCode))
    }

    private func stopOpenCode() {
        openCodeRefresh?.cancel()
        openCodeRefresh = nil

        let openCode = openCode
        Task { await openCode.disconnect() }
    }
}

/// The loudest level heard, for the microphone check.
private final class LockedPeak: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Float = 0
    func note(_ level: Float) { lock.withLock { peak = max(peak, level) } }
    var value: Float { lock.withLock { peak } }
}
