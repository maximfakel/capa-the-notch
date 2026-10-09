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

    // MARK: - Kapa

    /// Whether Kapa is drawn (ADR 0006). The one default that is on: it asks
    /// for nothing and reads nothing new.
    public var showsKapa: Bool {
        get { defaults.object(forKey: KapaPreference.key) as? Bool ?? KapaPreference.defaultValue }
        set { defaults.set(newValue, forKey: KapaPreference.key) }
    }

    // MARK: - Providers

    /// Whether this Provider is read without being asked for.
    ///
    /// Codex starts connected because it needs nothing from the person. Claude
    /// Code does not, because it is asked for once and explained first.
    ///
    /// Only the first two chosen, in surface order, are on: a third chosen
    /// somewhere this rule was not kept is read as off (`ProviderSelection`).
    public func connectsAtLaunch(_ provider: Provider) -> Bool {
        connectedProviders.contains(provider)
    }

    private func chosen(_ provider: Provider) -> Bool {
        let key = Self.connectKey(provider)
        guard defaults.object(forKey: key) != nil else {
            return provider == .codex
        }
        return defaults.bool(forKey: key)
    }

    /// Remembers a deliberate Connect or Disconnect, so it outlives the launch
    /// it was made in. A Connect past the two-at-most rule is refused.
    @discardableResult
    public func setConnectsAtLaunch(_ provider: Provider, _ connects: Bool) -> Bool {
        guard !connects || canConnect(provider) else { return false }
        defaults.set(connects, forKey: Self.connectKey(provider))
        return true
    }

    /// The Providers to be read, in surface order, two at most.
    public var connectedProviders: [Provider] {
        ProviderSelection.toConnect(Provider.allCases.filter(chosen))
    }

    /// Whether this Provider may be turned on beside those already on
    /// (`ProviderSelection`).
    public func canConnect(_ provider: Provider) -> Bool {
        ProviderSelection.canTurnOn(provider, alreadyOn: Set(connectedProviders))
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

    /// How often a polled Provider — Codex, OpenCode — is read while the
    /// surface is closed: "Обновлять данные" in Settings ▸ Providers. Open,
    /// it is read at least every minute: an open surface is being watched.
    /// Claude Code is not polled; its readings arrive after each reply.
    public var refreshInterval: RefreshInterval {
        get { RefreshInterval(stored: defaults.double(forKey: "backgroundRefreshSeconds")) }
        set { defaults.set(newValue.rawValue, forKey: "backgroundRefreshSeconds") }
    }

    /// Whether the App Server's own output is kept for a bug report. Off by
    /// default; a diagnostic nobody asked for is a log nobody consented to.
    public var keepsDiagnosticLog: Bool {
        get { defaults.bool(forKey: "keepsDiagnosticLog") }
        set { defaults.set(newValue, forKey: "keepsDiagnosticLog") }
    }

    /// Which window the closed strip shows for each Provider while two are
    /// on. The notch watches the same key, so a choice shows at once.
    public var compactWindow: CompactWindowChoice {
        get { CompactWindowChoice(stored: defaults.string(forKey: "compactWindow")) }
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

    /// Text copied lands under the Shelf's Clipboard tab. Off until asked for,
    /// on its own switch (ADR 0005, amended 2026-10-02).
    public var shelfKeepsText: Bool {
        get { defaults.bool(forKey: "shelfKeepsText") }
        set { defaults.set(newValue, forKey: "shelfKeepsText") }
    }

    /// How many Clippings are kept: 20 unless chosen.
    public var clippingLimit: ClippingLimit {
        get { ClippingLimit(rawValue: defaults.integer(forKey: "clippingLimit")) ?? .default }
        set { defaults.set(newValue.rawValue, forKey: "clippingLimit") }
    }

    /// Each Clipping goes after a day, unless this is switched off.
    public var clippingsExpire: Bool {
        get { !defaults.bool(forKey: "clippingsKeptPastADay") }
        set { defaults.set(!newValue, forKey: "clippingsKeptPastADay") }
    }

    /// Applications nothing is kept from while they are in front, chosen in
    /// Settings, by bundle identifier.
    public var clipboardExcludedApplications: [String] {
        get { defaults.stringArray(forKey: "clipboardExcludedApplications") ?? [] }
        set { defaults.set(newValue, forKey: "clipboardExcludedApplications") }
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

    /// Ticket 20: the Script follows the voice reading it rather than moving
    /// at the set speed. Off until turned on; the microphone is asked for
    /// only then (ADR 0003).
    public var teleprompterFollowsVoice: Bool {
        get { defaults.bool(forKey: "teleprompterFollowsVoice") }
        set { defaults.set(newValue, forKey: "teleprompterFollowsVoice") }
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

    /// The person agreed that CapaTheNotch reads OpenCode's key from its
    /// own file to ask for its Go plan's usage (ADR 0001, amended).
    public var openCodeConsentGiven: Bool {
        get { defaults.bool(forKey: "openCodeConsentGiven") }
        set { defaults.set(newValue, forKey: "openCodeConsentGiven") }
    }

    /// Whether setting Claude Code's status line up has been asked about
    /// (ADR 0001, amended 2026-10-06). A person who connected before that is
    /// asked once at launch.
    public var claudeStatusLineAsked: Bool {
        get { defaults.bool(forKey: "claudeStatusLineAsked") }
        set { defaults.set(newValue, forKey: "claudeStatusLineAsked") }
    }

    /// Whether the person said yes to it. Only then is `settings.json`
    /// changed, on any Turn On after; "Not Now" means asking again next time.
    public var claudeStatusLineAgreed: Bool {
        get { defaults.bool(forKey: "claudeStatusLineAgreed") }
        set { defaults.set(newValue, forKey: "claudeStatusLineAgreed") }
    }

    /// The status line CapaTheNotch set up, with what it replaced, so Turn
    /// Off puts back exactly that and touches nothing it did not add.
    public struct ClaudeStatusLineSetUp: Equatable, Sendable {
        /// The earlier `statusLine` value as it was written; nil when there
        /// was none.
        public var previous: String?
        public init(previous: String?) { self.previous = previous }
    }

    public var claudeStatusLineSetUp: ClaudeStatusLineSetUp? {
        get {
            guard defaults.bool(forKey: "claudeStatusLineSetUp") else { return nil }
            return ClaudeStatusLineSetUp(previous: defaults.string(forKey: "claudeStatusLinePrevious"))
        }
        set {
            defaults.set(newValue != nil, forKey: "claudeStatusLineSetUp")
            defaults.set(newValue?.previous, forKey: "claudeStatusLinePrevious")
        }
    }

    /// Whether putting CapaTheNotch's Claude Code mod in place has been
    /// asked about (ADR 0001, amended 2026-10-08). A person who connected
    /// before the mod existed is asked once at launch.
    public var claudeModAsked: Bool {
        get { defaults.bool(forKey: "claudeModAsked") }
        set { defaults.set(newValue, forKey: "claudeModAsked") }
    }

    /// Whether the person said yes to it. Only then is the mod copied to
    /// `~/.claude/skills/capathenotch`, on any Turn On after and at launch.
    public var claudeModAgreed: Bool {
        get { defaults.bool(forKey: "claudeModAgreed") }
        set { defaults.set(newValue, forKey: "claudeModAgreed") }
    }

    /// Whether moving Claude Code's status-line bridge to the renamed
    /// application has been settled: offered once and answered, or found to
    /// have nothing to move. A question re-asked is not consent.
    public var claudeBridgeMoveSettled: Bool {
        get { defaults.bool(forKey: "claudeBridgeMoveSettled") }
        set { defaults.set(newValue, forKey: "claudeBridgeMoveSettled") }
    }

    /// Whether the grants kept under the old ad-hoc signature have been
    /// reset (ticket 33). Set only once every one of them was, by tccutil or
    /// by the person; on a first run, at once, with nothing to reset.
    public var oldGrantsReset: Bool {
        get { defaults.bool(forKey: "oldGrantsReset") }
        set { defaults.set(newValue, forKey: "oldGrantsReset") }
    }

    /// The next launch asks for the permissions again, once: the reset was
    /// done in a process that keeps the answers macOS gave it before.
    public var oldGrantsAskAgain: Bool {
        get { defaults.bool(forKey: "oldGrantsAskAgain") }
        set { defaults.set(newValue, forKey: "oldGrantsAskAgain") }
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

extension Preferences {
    /// The Calendar Module. Off until asked for (ADR 0003): while off, no
    /// calendar is read and macOS is not asked for access.
    public var calendarEnabled: Bool {
        get { defaults.bool(forKey: "calendarEnabled") }
        set { defaults.set(newValue, forKey: "calendarEnabled") }
    }

    /// The Calendar page's view last used — Day, Week or Month — which it
    /// opens on; the Day until another is chosen.
    public var calendarTab: CalendarTab {
        get { defaults.string(forKey: "calendarTab").flatMap(CalendarTab.init(rawValue:)) ?? .standard }
        set { defaults.set(newValue.rawValue, forKey: "calendarTab") }
    }
}

extension Preferences {
    /// Two taps of one finger on the trackpad open the surface (ticket 14).
    /// Off until asked for: it reads a private framework (ADR 0004).
    public var opensOnTrackpadTap: Bool {
        get { defaults.bool(forKey: "trackpadTap.enabled") }
        set { defaults.set(newValue, forKey: "trackpadTap.enabled") }
    }
    /// The Translator Module (ticket 28). Off until asked for (ADR 0003):
    /// while off, no shortcut is registered and nothing is translated. What
    /// was translated is never kept here.
    public var translatorEnabled: Bool {
        get { defaults.bool(forKey: "translator.enabled") }
        set { defaults.set(newValue, forKey: "translator.enabled") }
    }
    public var translatorShortcut: KeyShortcut {
        get {
            defaults.data(forKey: "translator.shortcut").flatMap { try? JSONDecoder().decode(KeyShortcut.self, from: $0) }
                ?? TranslatorShortcutDefault.standard
        }
        set { if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: "translator.shortcut") } }
    }
}

public enum TranslatorShortcutDefault {
    /// ⌃⌥T: beside Dictation's ⌃⌥D and the Teleprompter's ⌃⌥Space, Esc, ↑
    /// and ↓, and none of them.
    public static let standard = KeyShortcut(keyCode: 17, modifiers: [.control, .option], keyLabel: "T")
}
