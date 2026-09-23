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

    /// Ticket 11 owns the updater. The choice is remembered until it exists.
    /// Off until asked for, like every other default here: checking would be
    /// the application's first network request of its own.
    public var checksForUpdates: Bool {
        get { defaults.bool(forKey: "checksForUpdates") }
        set { defaults.set(newValue, forKey: "checksForUpdates") }
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
