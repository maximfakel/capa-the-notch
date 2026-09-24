import CapacityNotchCore
import Foundation

private func freshPreferences() -> (Preferences, UserDefaults, String) {
    let suite = "capacity-notch-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    return (Preferences(defaults: defaults), defaults, suite)
}

func nothingIsEnabledOnAnybodysBehalf() throws {
    let (preferences, defaults, suite) = freshPreferences()
    defer { defaults.removePersistentDomain(forName: suite) }

    try expect(!preferences.alertsEnabled, "Alerts are not switched on for anyone")
    try expect(!preferences.launchAtLogin, "Nor is launching at login")
    try expect(!preferences.screenSharingAllowed, "Nor is appearing in a shared screen")
    try expect(!preferences.keepsDiagnosticLog, "Nor is keeping a log")
    try expect(!preferences.checksForUpdates, "Nor is asking the network about updates")
    try expect(!preferences.musicEnabled, "Nor is reading what is playing")
    try expect(!preferences.hasFinishedOnboarding, "A first run has not been through onboarding")
    try expect(!preferences.claudeConsentGiven, "And has consented to nothing")
}

func codexStartsConnectedAndClaudeDoesNot() throws {
    let (preferences, defaults, suite) = freshPreferences()
    defer { defaults.removePersistentDomain(forName: suite) }

    try expect(
        preferences.connectsAtLaunch(.codex),
        "Codex asks nothing of the person, so it is read without being asked for"
    )
    try expect(
        !preferences.connectsAtLaunch(.claudeCode),
        "Claude Code is explained and asked for first"
    )
}

func aDeliberateDisconnectOutlivesTheLaunchItWasMadeIn() throws {
    let (preferences, defaults, suite) = freshPreferences()
    defer { defaults.removePersistentDomain(forName: suite) }

    preferences.setConnectsAtLaunch(.codex, false)
    preferences.setConnectsAtLaunch(.claudeCode, true)

    // The next launch reads the same store.
    let nextLaunch = Preferences(defaults: defaults)
    try expect(
        !nextLaunch.connectsAtLaunch(.codex),
        "A Provider disconnected on purpose stays disconnected"
    )
    try expect(
        nextLaunch.connectsAtLaunch(.claudeCode),
        "And one connected on purpose comes back connected"
    )
}

func aChoiceMadeAnywhereIsTheSameChoice() throws {
    let (preferences, defaults, suite) = freshPreferences()
    defer { defaults.removePersistentDomain(forName: suite) }

    preferences.alertsEnabled = true
    preferences.launchAtLogin = true
    preferences.preferredDisplayID = 7
    preferences.backgroundRefreshSeconds = 900

    let elsewhere = Preferences(defaults: defaults)
    try expect(elsewhere.alertsEnabled, "Alerts")
    try expect(elsewhere.launchAtLogin, "Launch at login")
    try expect(elsewhere.preferredDisplayID == 7, "The chosen display")
    try expect(elsewhere.backgroundRefreshSeconds == 900, "The background pace")

    elsewhere.preferredDisplayID = nil
    try expect(
        Preferences(defaults: defaults).preferredDisplayID == nil,
        "Clearing the chosen display returns to whichever display is built in"
    )
}

func onboardingIsOfferedOnlyToSomeoneWhoHasConnectedNothing() throws {
    let (preferences, defaults, suite) = freshPreferences()
    defer { defaults.removePersistentDomain(forName: suite) }

    try expect(preferences.needsOnboarding, "A first run is offered onboarding")

    // Connected from onboarding, the menu or a card, then the window closed
    // without Continue: that person has been through the first run.
    preferences.setConnectsAtLaunch(.claudeCode, true)
    try expect(
        !preferences.needsOnboarding,
        "Someone who connected a Provider should not be welcomed again at every launch"
    )

    preferences.setConnectsAtLaunch(.claudeCode, false)
    try expect(
        preferences.needsOnboarding,
        "With everything deliberately disconnected and onboarding never finished, it is offered again"
    )

    preferences.hasFinishedOnboarding = true
    try expect(!preferences.needsOnboarding, "Finishing onboarding ends it")
}

func theBackgroundPaceFallsBackToTheScheduleItCameFrom() throws {
    let (preferences, defaults, suite) = freshPreferences()
    defer { defaults.removePersistentDomain(forName: suite) }

    try expect(
        preferences.backgroundRefreshSeconds == RefreshSchedule.standard.whileCompact,
        "Unset, the pace is the schedule's own"
    )
    try expect(
        Preferences.refreshChoices.contains(RefreshSchedule.standard.whileCompact),
        "And the schedule's own pace is one a person can choose"
    )
}
