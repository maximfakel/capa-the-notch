@preconcurrency import ApplicationServices
import AppKit
import AVFoundation
import EventKit
import UserNotifications

/// Everything CapaTheNotch asks macOS for, asked for together in
/// onboarding so nothing interrupts work later: notifications for Capacity
/// Alerts, the microphone for Dictation, Accessibility to insert its text,
/// and System Events for the paste Dictation falls back on — and Calendars,
/// when the Calendar Module is on.
///
/// Music and Launch at Login need nothing: the one reads what is playing
/// without a prompt (ADR 0004), the other is macOS's own switch.
@MainActor
final class SystemAccess: ObservableObject {
    enum Kind: CaseIterable, Identifiable {
        case notifications
        case microphone
        case accessibility
        case automation
        case calendars

        var id: Self { self }

        var name: String { L(englishName) }

        private var englishName: String {
            switch self {
            case .notifications: "Notifications"
            case .microphone: "Microphone"
            case .accessibility: "Accessibility"
            case .automation: "System Events"
            case .calendars: "Calendars"
            }
        }

        var reason: String { L(englishReason) }

        private var englishReason: String {
            switch self {
            case .notifications: "A Capacity Alert when a window is about to run out."
            case .microphone: "Dictation hears you only while you hold its shortcut."
            case .accessibility: "Dictation types its text where the cursor is."
            case .automation: "Dictation's fallback for pasting its text."
            case .calendars: "What's next in your calendar, under Capacity."
            }
        }

        /// Its list's name in Privacy & Security, where it is removed by hand.
        var paneName: String { self == .automation ? L("Automation") : name }

        /// The reason in a few words, beside Open Settings.
        var shortReason: String { L(englishShortReason) }

        private var englishShortReason: String {
            switch self {
            case .microphone: "Dictation and the Teleprompter hear you."
            case .accessibility: "Text goes where the cursor is."
            case .automation: "System Events, the fallback for pasting."
            case .notifications, .calendars: englishReason
            }
        }

        var icon: SettingsIcon {
            switch self {
            case .notifications: .alerts
            case .microphone: .dictation
            case .accessibility: .accessibility
            case .automation: .automation
            case .calendars: .calendar
            }
        }

        /// The pane of Privacy & Security where a refusal is undone.
        fileprivate var settingsURL: URL? {
            switch self {
            case .notifications: URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
            case .microphone: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            case .accessibility: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            case .automation: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
            case .calendars: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
            }
        }
    }

    enum State: Equatable {
        case granted
        /// macOS has not asked yet, so asking shows its own prompt.
        case notAsked
        /// Refused, or asked and not yet switched on: only System Settings
        /// can change it now.
        case refused
        /// Notifications, run outside an application bundle.
        case unavailable
    }

    @Published private(set) var states: [Kind: State] = [:]

    private let dictation: DictationController
    private let notifications: CapacityNotifications?
    /// Asked about only while its Module is on.
    private let calendar: CalendarController?
    /// Accessibility has no "refused": once its prompt has been shown, the
    /// next step is System Settings.
    private var askedAccessibility = false
    private var watching: Task<Void, Never>?

    init(dictation: DictationController, notifications: CapacityNotifications?, calendar: CalendarController? = nil) {
        self.dictation = dictation
        self.notifications = notifications
        self.calendar = calendar
    }

    /// What this Mac is asked about: Calendars only with the Calendar on.
    var kinds: [Kind] {
        Kind.allCases.filter { $0 != .calendars || calendar?.reader.isEnabled == true }
    }

    /// Opens a kind's pane in Privacy & Security, whatever its state: where
    /// the old grants are removed by hand (ticket 33).
    func openSettings(_ kind: Kind) {
        if let url = kind.settingsURL { NSWorkspace.shared.open(url) }
    }

    func state(_ kind: Kind) -> State { states[kind] ?? .notAsked }

    /// Anything macOS can still be asked about.
    var anyToAsk: Bool { kinds.contains { state($0) == .notAsked } }

    /// Reads what macOS has decided, without asking anything.
    func refresh() async {
        var next: [Kind: State] = [:]
        if let notifications {
            next[.notifications] = switch await notifications.authorization() {
            case .authorized, .provisional, .ephemeral: .granted
            case .denied: .refused
            default: .notAsked
            }
        } else {
            next[.notifications] = .unavailable
        }
        next[.microphone] = switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notAsked
        default: .refused
        }
        next[.accessibility] = AXIsProcessTrusted() ? .granted : askedAccessibility ? .refused : .notAsked
        next[.automation] = await Self.automation(asking: false)
        if calendar?.reader.isEnabled == true {
            next[.calendars] = switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess: .granted
            case .notDetermined: .notAsked
            default: .refused
            }
        }
        if next != states { states = next }
        dictation.refreshPermissions()
    }

    /// Shows macOS's prompt for one kind, or its pane in System Settings once
    /// the prompt has had its answer.
    func request(_ kind: Kind) async {
        guard state(kind) == .notAsked else {
            if let url = kind.settingsURL { NSWorkspace.shared.open(url) }
            return
        }
        switch kind {
        case .notifications:
            _ = await notifications?.requestPermission()
        case .microphone:
            await dictation.askForMicrophone()
        case .accessibility:
            askedAccessibility = true
            dictation.askForInsertion()
        case .automation:
            _ = await Self.automation(asking: true)
        case .calendars:
            await calendar?.askForAccess()
        }
        await refresh()
    }

    /// Every prompt still to be shown, one after another. Accessibility goes
    /// last: its prompt sends the person to System Settings.
    func requestAll() async {
        for kind in [Kind.notifications, .microphone, .automation, .calendars, .accessibility]
        where kinds.contains(kind) && state(kind) == .notAsked {
            await request(kind)
        }
    }

    /// Keeps the states current while they are on screen: Accessibility, and
    /// anything changed in System Settings, never says it changed.
    func watch() {
        watching?.cancel()
        watching = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stopWatching() {
        watching?.cancel()
        watching = nil
    }

    /// Whether CapaTheNotch may send System Events its paste. Asking needs
    /// System Events running; without asking, a System Events that is not
    /// running cannot say, and is treated as not asked — asking then launches
    /// it and, when access was already given, returns without a prompt.
    private static func automation(asking: Bool) async -> State {
        let systemEvents = "com.apple.systemevents"
        if asking, NSRunningApplication.runningApplications(withBundleIdentifier: systemEvents).isEmpty,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: systemEvents) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
        // It can wait on the person's answer, so never on the main thread.
        let status = await Task.detached {
            let target = NSAppleEventDescriptor(bundleIdentifier: systemEvents)
            guard let address = target.aeDesc else { return OSStatus(procNotFound) }
            return AEDeterminePermissionToAutomateTarget(address, typeWildCard, typeWildCard, asking)
        }.value
        switch Int(status) {
        case Int(noErr): return .granted
        case Int(errAEEventNotPermitted): return .refused
        default: return .notAsked
        }
    }
}
