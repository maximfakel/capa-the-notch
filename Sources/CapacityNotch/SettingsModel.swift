import AppKit
import CapacityNotchCore
import Combine
import SwiftUI

struct ProviderChoice: Identifiable {
    let provider: Provider
    let name: String
    let note: String?

    var id: String { provider.rawValue }
}

/// What Settings and onboarding both write through.
///
/// Every property writes to `Preferences` and then tells the application, so a
/// switch flicked here takes effect at once rather than at the next launch.
@MainActor
final class SettingsModel: ObservableObject {
    private let preferences: Preferences
    private unowned let application: AppDelegate
    private var watching: Set<AnyCancellable> = []

    init(preferences: Preferences, application: AppDelegate) {
        self.preferences = preferences
        self.application = application
        displayID = preferences.preferredDisplayID ?? 0
        screenSharingAllowed = preferences.screenSharingAllowed
        backgroundRefresh = preferences.backgroundRefreshSeconds
        launchAtLogin = LaunchAtLogin.isEnabled
        alertsEnabled = preferences.alertsEnabled
        keepsDiagnosticLog = preferences.keepsDiagnosticLog
        musicEnabled = preferences.musicEnabled
        application.music.$isUnreadable
            .receive(on: DispatchQueue.main)
            .sink { [weak self] unreadable in self?.musicUnreadable = unreadable }
            .store(in: &watching)
    }

    /// The Music Module. Off until asked for; off, nothing is read.
    @Published var musicEnabled: Bool {
        didSet { application.setMusicEnabled(musicEnabled) }
    }

    /// macOS stopped telling Capacity Notch what is playing (ADR 0004).
    @Published private(set) var musicUnreadable = false

    let providers = [
        ProviderChoice(provider: .codex, name: "Codex", note: nil),
        ProviderChoice(
            provider: .claudeCode,
            name: "Claude Code",
            note: "Experimental. Reads only the Capacity its status line publishes."
        ),
    ]

    func binding(for provider: Provider) -> Binding<Bool> {
        Binding(
            get: { self.preferences.connectsAtLaunch(provider) },
            set: { self.setProvider(provider, connected: $0) }
        )
    }

    private func setProvider(_ provider: Provider, connected: Bool) {
        preferences.setConnectsAtLaunch(provider, connected)
        objectWillChange.send()

        if connected {
            application.connect(provider)
        } else {
            application.disconnect(provider)
        }
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

    @Published var backgroundRefresh: TimeInterval {
        didSet { preferences.backgroundRefreshSeconds = backgroundRefresh }
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

    func refreshLabel(_ seconds: TimeInterval) -> String {
        seconds < 3600
            ? "Every \(Int(seconds / 60)) minutes"
            : "Every hour"
    }

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
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        lastCopiedReport = report
    }

    func restartOnboarding() {
        application.startOnboarding(force: true)
    }
}
