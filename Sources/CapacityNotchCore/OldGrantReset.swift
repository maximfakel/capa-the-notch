/// The grants macOS kept under the old ad-hoc signature, cleared once
/// (ticket 33).
///
/// Builds before 0.4.0 were signed ad-hoc, and macOS stored with each grant —
/// microphone, Accessibility, System Events, Calendars — a requirement any
/// build with this bundle identifier satisfies. A build signed with the
/// author's certificate does not replace it (ticket 30 measured that), so
/// until the grants are reset a build someone else signed still gets them.
/// `tccutil reset` needs no administrator, so CapaTheNotch does it itself on
/// its first launch under the certificate, and asks again.
public enum OldGrantReset {
    public enum Outcome: Equatable, Sendable {
        /// Nothing to do: done before, or not running under the certificate.
        case notNeeded
        case reset
        /// At least one was left in place; the next launch tries again.
        case failed
    }

    /// Resets one service's grants for one bundle identifier; true when it
    /// did. tccutil, outside tests.
    public typealias Reset = (_ service: String, _ bundleIdentifier: String) -> Bool

    /// tccutil's names for the four, and nothing else. Notifications are not
    /// a tccutil service: macOS keeps them by bundle identifier.
    public static let services = ["Microphone", "Accessibility", "AppleEvents", "Calendar"]
    public static let bundleIdentifier = "app.capacitynotch.CapacityNotch"

    /// A first run resets nothing and never will: a fresh install has no old
    /// grants, and the ones its own onboarding gives are already the
    /// certificate's — wiping them later would ask again for nothing.
    public static func runOnce(preferences: Preferences, signedWithCertificate: Bool, firstRun: Bool, reset: Reset) -> Outcome {
        guard signedWithCertificate, !preferences.oldGrantsReset else { return .notNeeded }
        guard !firstRun else {
            preferences.oldGrantsReset = true
            return .notNeeded
        }
        // Every one is tried, even after one fails: fewer left is fewer open.
        let failures = services.filter { !reset($0, bundleIdentifier) }
        guard failures.isEmpty else { return .failed }
        preferences.oldGrantsReset = true
        return .reset
    }

    /// The person removed the old grants in Privacy & Security themselves,
    /// after tccutil could not: the way out of asking at every launch.
    public static func removedByHand(preferences: Preferences) {
        preferences.oldGrantsReset = true
        preferences.oldGrantsAskAgain = true
    }

    /// Try Again worked. The process that reset keeps the answers macOS gave
    /// it before — the microphone, Accessibility and Calendars answer once
    /// for its life — so the asking is the relaunch's.
    public static func resetWhileRunning(preferences: Preferences) {
        preferences.oldGrantsAskAgain = true
    }

    /// What launch opens after trying.
    public enum Opening: Equatable, Sendable {
        /// The first-run path, as on any first launch.
        case onboarding
        /// Onboarding's permissions step, saying why it asks again.
        case permissionsAgain
        /// The same step, saying the old grants are still there and how to
        /// remove them by hand.
        case permissionsNotReset
    }

    /// A first run is welcomed as ever — there was nothing to reset; someone
    /// who used an older build is taken to the permissions, told why; after
    /// that, nothing.
    public static func opening(after outcome: Outcome, firstRun: Bool, preferences: Preferences) -> Opening? {
        if firstRun { return .onboarding }
        if preferences.oldGrantsAskAgain {
            preferences.oldGrantsAskAgain = false
            return .permissionsAgain
        }
        switch outcome {
        case .notNeeded: return nil
        case .reset: return .permissionsAgain
        case .failed: return .permissionsNotReset
        }
    }
}
