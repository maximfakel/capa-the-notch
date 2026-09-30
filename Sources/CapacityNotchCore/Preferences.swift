import Foundation

/// Every choice a person has made, in one place.
///
/// Settings and onboarding write here and the application reads here, so a
/// choice made in either is the same choice. Nothing is enabled on anyone's
/// behalf: each default is the quiet one, except connecting a Provider the
/// person already installed, which is the whole point of the surface.
public final class Preferences: @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Providers

    /// Whether this Provider is read without being asked for.
    ///
    /// Codex starts connected because it needs nothing from the person. Claude
    /// Code does not, because it is asked for once and explained first.
    public func connectsAtLaunch(_ provider: Provider) -> Bool {
        let key = Self.connectKey(provider)
        guard defaults.object(forKey: key) != nil else {
            return provider == .codex
        }
        return defaults.bool(forKey: key)
    }

    /// Remembers a deliberate Connect or Disconnect, so it outlives the launch
    /// it was made in.
    public func setConnectsAtLaunch(_ provider: Provider, _ connects: Bool) {
        defaults.set(connects, forKey: Self.connectKey(provider))
    }

    private static func connectKey(_ provider: Provider) -> String {
        "connectsAtLaunch.\(provider.rawValue)"
    }

    // MARK: - The surface

    public var preferredDisplayID: UInt32? {
        get {
            let stored = defaults.integer(forKey: "preferredDisplayID")
            return stored > 0 ? UInt32(stored) : nil
        }
        set {
            if let newValue {
                defaults.set(Int(newValue), forKey: "preferredDisplayID")
            } else {
                defaults.removeObject(forKey: "preferredDisplayID")
            }
        }
    }

    /// Off by default: Capacity is the person's account standing, and a shared
    /// screen is the easiest way to show it to a room by accident.
    public var screenSharingAllowed: Bool {
        get { defaults.bool(forKey: "allowScreenSharing") }
        set { defaults.set(newValue, forKey: "allowScreenSharing") }
    }

    // MARK: - Behaviour

    public var alertsEnabled: Bool {
        get { defaults.bool(forKey: "alertsEnabled") }
        set { defaults.set(newValue, forKey: "alertsEnabled") }
    }

    /// Alerts can be silenced for one Provider without silencing the other.
    /// A Provider is heard only when both this and the global switch allow it.
    public func alertsEnabled(for provider: Provider) -> Bool {
        guard alertsEnabled else { return false }
        let key = Self.alertKey(provider)
        guard defaults.object(forKey: key) != nil else { return true }
        return defaults.bool(forKey: key)
    }

    public func setAlertsEnabled(_ enabled: Bool, for provider: Provider) {
        defaults.set(enabled, forKey: Self.alertKey(provider))
    }

    private static func alertKey(_ provider: Provider) -> String {
        "alertsEnabled.\(provider.rawValue)"
    }

    public var launchAtLogin: Bool {
        get { defaults.bool(forKey: "launchAtLogin") }
        set { defaults.set(newValue, forKey: "launchAtLogin") }
    }

    /// How often a Provider is read while the surface is closed. The open pace
    /// is not a choice: an open surface is being watched.
    public var backgroundRefreshSeconds: TimeInterval {
        get {
            let stored = defaults.double(forKey: "backgroundRefreshSeconds")
            return stored > 0 ? stored : RefreshSchedule.standard.whileCompact
        }
        set { defaults.set(newValue, forKey: "backgroundRefreshSeconds") }
    }

    public static let refreshChoices: [TimeInterval] = [60, 300, 900]

    /// Whether the App Server's own output is kept for a bug report. Off by
    /// default; a diagnostic nobody asked for is a log nobody consented to.
    public var keepsDiagnosticLog: Bool {
        get { defaults.bool(forKey: "keepsDiagnosticLog") }
        set { defaults.set(newValue, forKey: "keepsDiagnosticLog") }
    }

    /// Which window the closed strip shows for each Provider while both are on.
    public var compactWindow: CompactWindowChoice {
        get { defaults.string(forKey: "compactWindow").flatMap(CompactWindowChoice.init(rawValue:)) ?? .fiveHour }
        set { defaults.set(newValue.rawValue, forKey: "compactWindow") }
    }

    /// The language Settings speak. The Mac's own until chosen.
    public var language: AppLanguage {
        get { defaults.string(forKey: "language").flatMap(AppLanguage.init(rawValue:)) ?? .system }
        set { defaults.set(newValue.rawValue, forKey: "language") }
    }

    /// Ticket 11 owns the updater. The choice is remembered until it exists.
    /// Off until asked for, like every other default here: checking would be
    /// the application's first network request of its own.
    public var checksForUpdates: Bool {
        get { defaults.bool(forKey: "checksForUpdates") }
        set { defaults.set(newValue, forKey: "checksForUpdates") }
    }

    // MARK: - Modules

    /// The Music Module. Off until asked for, like every Module but Capacity
    /// (ADR 0003): while off, nothing is read.
    public var musicEnabled: Bool {
        get { defaults.bool(forKey: "musicEnabled") }
        set { defaults.set(newValue, forKey: "musicEnabled") }
    }

    /// The Shelf Module. Off until asked for (ADR 0003); what it holds is
    /// never stored, only whether it is on (ADR 0005).
    public var shelfEnabled: Bool {
        get { defaults.bool(forKey: "shelfEnabled") }
        set { defaults.set(newValue, forKey: "shelfEnabled") }
    }

    /// Images copied to the clipboard land on the Shelf. Off until asked for:
    /// it means watching the clipboard (ADR 0005, amended). The key is the
    /// one it had when it took screenshots alone.
    public var shelfTakesClipboardImages: Bool {
        get { defaults.bool(forKey: "shelfTakesScreenshots") }
        set { defaults.set(newValue, forKey: "shelfTakesScreenshots") }
    }

    /// The Teleprompter Module. Off until asked for (ADR 0003): while off, no
    /// shortcut is registered and nothing is shown.
    public var teleprompterEnabled: Bool {
        get { defaults.bool(forKey: "teleprompterEnabled") }
        set { defaults.set(newValue, forKey: "teleprompterEnabled") }
    }

    /// The Script, kept on this Mac. It never reaches diagnostics or a log.
    public var script: String {
        get { defaults.string(forKey: "teleprompterScript") ?? "" }
        set { defaults.set(newValue, forKey: "teleprompterScript") }
    }

    /// The Script before the last one given — one step back, no more.
    public private(set) var previousScript: String? {
        get { defaults.string(forKey: "teleprompterPreviousScript") }
        set { defaults.set(newValue, forKey: "teleprompterPreviousScript") }
    }

    /// Paste from Clipboard: the new Script replaces the current one, which is
    /// kept as the one before.
    public func replaceScript(with text: String) {
        guard text != script else { return }
        previousScript = script.isEmpty ? previousScript : script
        script = text
    }

    /// Restore Previous Script: the two trade places, so a second restore
    /// undoes the first.
    public func restorePreviousScript() {
        guard let previous = previousScript else { return }
        previousScript = script.isEmpty ? nil : script
        script = previous
    }

    /// The Teleprompter's speed, as last turned on the page or in Settings.
    public var teleprompterMultiplier: Double {
        get {
            let stored = defaults.double(forKey: "teleprompterMultiplier")
            return stored > 0 ? stored : 1
        }
        set { defaults.set(TeleprompterPlayback.clampedMultiplier(newValue), forKey: "teleprompterMultiplier") }
    }

    public var teleprompterTextSize: TeleprompterTextSize {
        get { defaults.string(forKey: "teleprompterTextSize").flatMap(TeleprompterTextSize.init(rawValue:)) ?? .medium }
        set { defaults.set(newValue.rawValue, forKey: "teleprompterTextSize") }
    }

    public func teleprompterShortcut(for action: TeleprompterAction) -> KeyShortcut? {
        let key = Self.shortcutKey(action)
        guard let data = defaults.data(forKey: key) else { return TeleprompterShortcuts.standard[action] }
        return try? JSONDecoder().decode(KeyShortcut.self, from: data)
    }

    public func setTeleprompterShortcut(_ shortcut: KeyShortcut, for action: TeleprompterAction) {
        guard let data = try? JSONEncoder().encode(shortcut) else { return }
        defaults.set(data, forKey: Self.shortcutKey(action))
    }

    private static func shortcutKey(_ action: TeleprompterAction) -> String {
        "teleprompterShortcut.\(action.rawValue)"
    }

    // MARK: - Windows

    /// How Settings and onboarding look. The surface is black whatever this
    /// says: it continues the menu bar, not a window.
    public var appearance: Appearance {
        get { defaults.string(forKey: "appearance").flatMap(Appearance.init(rawValue:)) ?? .system }
        set { defaults.set(newValue.rawValue, forKey: "appearance") }
    }

    // MARK: - Onboarding

    public var hasFinishedOnboarding: Bool {
        get { defaults.bool(forKey: "hasFinishedOnboarding") }
        set { defaults.set(newValue, forKey: "hasFinishedOnboarding") }
    }

    /// Whether launch should open the first-run path.
    ///
    /// Not only until Continue is pressed: someone who connected a Provider —
    /// from onboarding, the menu or a card — and closed the window has been
    /// through the first run, and being welcomed again at every launch, with
    /// nothing read until they answer, is the opposite of help. Only a
    /// deliberate Connect counts; Codex's default does not.
    public var needsOnboarding: Bool {
        guard !hasFinishedOnboarding else { return false }
        return !Provider.allCases.contains { provider in
            defaults.object(forKey: Self.connectKey(provider)) != nil
                && defaults.bool(forKey: Self.connectKey(provider))
        }
    }

    public var claudeConsentGiven: Bool {
        get { defaults.bool(forKey: "claudeCodeConsentGiven") }
        set { defaults.set(newValue, forKey: "claudeCodeConsentGiven") }
    }
}

/// Light, dark, or whatever the Mac is set to.
public enum Appearance: String, CaseIterable, Sendable {
    case system
    case light
    case dark

    public var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

extension Preferences {
    public var dictationEnabled: Bool {
        get { defaults.bool(forKey: "dictation.enabled") }
        set { defaults.set(newValue, forKey: "dictation.enabled") }
    }
    public var dictationKeepsHistory: Bool {
        get { defaults.bool(forKey: "dictation.keepsHistory") }
        set { defaults.set(newValue, forKey: "dictation.keepsHistory") }
    }
    public var dictationShortcut: KeyShortcut {
        get { dictationValue("shortcut") ?? KeyShortcut(keyCode: 2, modifiers: [.control, .option], keyLabel: "D") }
        set { setDictationValue(newValue, "shortcut") }
    }
    public var dictationReplacements: [DictationReplacement] {
        get { dictationValue("replacements") ?? DictationReplacement.defaults }
        set { setDictationValue(newValue, "replacements") }
    }
    public var dictationHistory: DictationHistory {
        get { dictationValue("history") ?? DictationHistory() }
        set { setDictationValue(newValue, "history") }
    }
    private func dictationValue<T: Decodable>(_ name: String) -> T? {
        defaults.data(forKey: "dictation." + name).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
    private func setDictationValue<T: Encodable>(_ value: T, _ name: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: "dictation." + name) }
    }
}
