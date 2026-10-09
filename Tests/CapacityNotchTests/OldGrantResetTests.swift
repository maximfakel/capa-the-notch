import CapacityNotchCore
import Foundation

private func freshPreferences() -> (Preferences, UserDefaults, String) {
    let suite = "capacity-notch-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    return (Preferences(defaults: defaults), defaults, suite)
}

/// Stands in for tccutil: records what it was asked to reset, and fails the
/// services it is told to.
private final class ResetLog: @unchecked Sendable {
    var calls: [String] = []
    var failing: Set<String> = []

    func reset(_ service: String, _ bundleIdentifier: String) -> Bool {
        calls.append("\(service) \(bundleIdentifier)")
        return !failing.contains(service)
    }
}

func theOldGrantsAreResetOnceAndOnlyUnderTheCertificate() throws {
    let (preferences, defaults, suite) = freshPreferences()
    defer { defaults.removePersistentDomain(forName: suite) }
    let log = ResetLog()

    try expect(OldGrantReset.runOnce(preferences: preferences, signedWithCertificate: false, firstRun: false, reset: log.reset) == .notNeeded,
               "A build without the certificate — a development run — resets nothing")
    try expect(log.calls.isEmpty, "and does not call tccutil at all")

    try expect(OldGrantReset.runOnce(preferences: preferences, signedWithCertificate: true, firstRun: false, reset: log.reset) == .reset,
               "The first launch signed with the certificate resets the old grants")
    try expect(!log.calls.isEmpty, "by calling tccutil")

    log.calls = []
    try expect(OldGrantReset.runOnce(preferences: preferences, signedWithCertificate: true, firstRun: false, reset: log.reset) == .notNeeded,
               "Once it has succeeded it is not done again")
    try expect(log.calls.isEmpty, "and tccutil is not called again")
}

func exactlyTheFourGrantsAreResetForCapaTheNotch() throws {
    let (preferences, defaults, suite) = freshPreferences()
    defer { defaults.removePersistentDomain(forName: suite) }
    let log = ResetLog()

    _ = OldGrantReset.runOnce(preferences: preferences, signedWithCertificate: true, firstRun: false, reset: log.reset)
    try expect(log.calls.sorted() == [
        "Accessibility app.capacitynotch.CapacityNotch",
        "AppleEvents app.capacitynotch.CapacityNotch",
        "Calendar app.capacitynotch.CapacityNotch",
        "Microphone app.capacitynotch.CapacityNotch",
    ], "Microphone, Accessibility, System Events and Calendars, for CapaTheNotch alone — got \(log.calls)")
}

func aResetThatFailsIsSaidAndTriedAgainAtTheNextLaunch() throws {
    let (preferences, defaults, suite) = freshPreferences()
    defer { defaults.removePersistentDomain(forName: suite) }
    let log = ResetLog()
    log.failing = ["Accessibility"]

    try expect(OldGrantReset.runOnce(preferences: preferences, signedWithCertificate: true, firstRun: false, reset: log.reset) == .failed,
               "One grant left in place is a failure, not a reset")
    try expect(log.calls.count == 4, "The others are still reset — got \(log.calls)")

    log.calls = []
    log.failing = []
    try expect(OldGrantReset.runOnce(preferences: preferences, signedWithCertificate: true, firstRun: false, reset: log.reset) == .reset,
               "The next launch tries again, and this time it is done")
    try expect(log.calls.count == 4, "all four again")
}

func onboardingSaysWhyItAsksAgainOnlyToSomeoneWhoGrantedBefore() throws {
    let (preferences, defaults, suite) = freshPreferences()
    defer { defaults.removePersistentDomain(forName: suite) }
    try expect(OldGrantReset.opening(after: .reset, firstRun: true, preferences: preferences) == .onboarding,
               "A first run is welcomed as ever: there was nothing to reset")
    try expect(OldGrantReset.opening(after: .notNeeded, firstRun: true, preferences: preferences) == .onboarding,
               "and so is a first run of a development build")
    try expect(OldGrantReset.opening(after: .reset, firstRun: false, preferences: preferences) == .permissionsAgain,
               "Someone who used an older build is taken to the permissions, told why")
    try expect(OldGrantReset.opening(after: .failed, firstRun: false, preferences: preferences) == .permissionsNotReset,
               "and told plainly when the reset did not happen")
    try expect(OldGrantReset.opening(after: .notNeeded, firstRun: false, preferences: preferences) == nil,
               "After that, launches open nothing")
}

func aFirstRunResetsNothingThenOrLater() throws {
    let (preferences, defaults, suite) = freshPreferences()
    defer { defaults.removePersistentDomain(forName: suite) }
    let log = ResetLog()

    try expect(OldGrantReset.runOnce(preferences: preferences, signedWithCertificate: true, firstRun: true, reset: log.reset) == .notNeeded,
               "A fresh install has no old grants to reset")
    try expect(log.calls.isEmpty, "and tccutil is not called")
    try expect(OldGrantReset.runOnce(preferences: preferences, signedWithCertificate: true, firstRun: false, reset: log.reset) == .notNeeded,
               "Nor later: the grants given in its first onboarding are already the certificate's")
    try expect(log.calls.isEmpty, "so they are never wiped")
}

func grantsRemovedByHandEndTheAsking() throws {
    let (preferences, defaults, suite) = freshPreferences()
    defer { defaults.removePersistentDomain(forName: suite) }
    let log = ResetLog()
    log.failing = Set(OldGrantReset.services)

    try expect(OldGrantReset.runOnce(preferences: preferences, signedWithCertificate: true, firstRun: false, reset: log.reset) == .failed,
               "tccutil refusing everything is a failure")
    OldGrantReset.removedByHand(preferences: preferences)
    log.calls = []
    try expect(OldGrantReset.runOnce(preferences: preferences, signedWithCertificate: true, firstRun: false, reset: log.reset) == .notNeeded,
               "Once the person has removed them in Privacy & Security, launches stop asking")
    try expect(log.calls.isEmpty, "and stop calling tccutil")
}

func aResetDoneWhileRunningAsksAgainAtTheRelaunchOnce() throws {
    let (preferences, defaults, suite) = freshPreferences()
    defer { defaults.removePersistentDomain(forName: suite) }

    // The process that reset keeps the answers macOS gave it before, so the
    // asking happens in the next one.
    OldGrantReset.removedByHand(preferences: preferences)
    try expect(OldGrantReset.opening(after: .notNeeded, firstRun: false, preferences: preferences) == .permissionsAgain,
               "The relaunch after removing them by hand asks again")
    try expect(OldGrantReset.opening(after: .notNeeded, firstRun: false, preferences: preferences) == nil,
               "and only that relaunch")

    OldGrantReset.resetWhileRunning(preferences: preferences)
    try expect(OldGrantReset.opening(after: .notNeeded, firstRun: false, preferences: preferences) == .permissionsAgain,
               "So does the relaunch after Try Again worked")
}
