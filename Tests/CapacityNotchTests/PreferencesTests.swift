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
    preferences.refreshInterval = .everyFifteenMinutes
    preferences.compactWindow = .weekly

    let elsewhere = Preferences(defaults: defaults)
    try expect(elsewhere.alertsEnabled, "Alerts")
    try expect(elsewhere.launchAtLogin, "Launch at login")
    try expect(elsewhere.preferredDisplayID == 7, "The chosen display")
    try expect(elsewhere.refreshInterval == .everyFifteenMinutes, "The background pace")
    try expect(elsewhere.compactWindow == .weekly, "The strip's window")

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
        preferences.refreshInterval.rawValue == RefreshSchedule.standard.whileCompact,
        "Unset, the pace is the schedule's own"
    )
    try expect(
        RefreshInterval.allCases.map(\.rawValue).contains(RefreshSchedule.standard.whileCompact),
        "And the schedule's own pace is one a person can choose"
    )
    // A pace stored before the choices were these three — "Every hour" was
    // once drawn — reads as the nearest one offered.
    defaults.set(3600.0, forKey: "backgroundRefreshSeconds")
    try expect(preferences.refreshInterval == .everyFifteenMinutes, "An hour reads as fifteen minutes")
    defaults.set(120.0, forKey: "backgroundRefreshSeconds")
    try expect(preferences.refreshInterval == .everyMinute, "Two minutes reads as one")
}

/// "Обновлять данные": the choice sets the closed surface's pace; open, the
/// surface is still read every minute, and a failing Provider still backs
/// off — never sooner than the pace chosen.
func theChosenPaceSetsTheClosedSurfacesSchedule() throws {
    let standard = RefreshSchedule.standard
    try expect(standard.closed(every: .standard) == standard, "The default changes nothing")

    let minute = standard.closed(every: .everyMinute)
    try expect(minute.delay(expanded: false, consecutiveFailures: 0) == 60, "Every minute, closed")
    try expect(minute.delay(expanded: true, consecutiveFailures: 0) == 60, "and open")

    let quarter = standard.closed(every: .everyFifteenMinutes)
    try expect(quarter.delay(expanded: false, consecutiveFailures: 0) == 900, "Every fifteen minutes, closed")
    try expect(quarter.delay(expanded: true, consecutiveFailures: 0) == 60, "Open, still every minute")
    try expect(quarter.delay(expanded: false, consecutiveFailures: 1) == 30, "A first failure is tried again soon")
    try expect(quarter.delay(expanded: false, consecutiveFailures: 5) == 900, "Backing off stops at the pace chosen")

    let language = Localization.current
    defer { Localization.current = language }
    Localization.current = .english
    try expect(
        RefreshInterval.allCases.map(\.title) == ["Every minute", "Every 5 min", "Every 15 min"],
        "Three choices, as drawn"
    )
    Localization.current = .russian
    try expect(
        RefreshInterval.allCases.map(\.title) == ["Каждую минуту", "Каждые 5 мин", "Каждые 15 мин"],
        "and in Russian"
    )
    try expect(CompactWindowChoice.allCases.map(\.title) == ["5 часов", "Неделя"], "The strip's two choices, as drawn")
}

func theAppearanceFollowsTheMacUntilChosen() throws {
    let (preferences, defaults, suite) = freshPreferences()
    defer { defaults.removePersistentDomain(forName: suite) }

    try expect(preferences.appearance == .system, "Until chosen, the windows look as the Mac does")

    preferences.appearance = .dark
    try expect(
        Preferences(defaults: defaults).appearance == .dark,
        "A chosen appearance outlives the launch it was chosen in"
    )

    defaults.set("sepia", forKey: "appearance")
    try expect(
        preferences.appearance == .system,
        "Something stored that is not an appearance falls back to the Mac's"
    )
}

/// Preferences keep the two-at-most rule wherever a Provider is turned on.
func preferencesRefuseAProviderPastTheLimit() throws {
    let (preferences, _, _) = freshPreferences()
    preferences.setConnectsAtLaunch(.claudeCode, true)
    try expect(preferences.connectedProviders == [.codex, .claudeCode], "Codex by default, and Claude Code turned on")
    try expect(preferences.canConnect(.codex) && preferences.canConnect(.claudeCode), "Both on, both may stay on")
    try expect(!preferences.canConnect(.openCode), "Two on, a third may not")
    try expect(!preferences.setConnectsAtLaunch(.openCode, true), "Turning it on is refused")
    try expect(!preferences.connectsAtLaunch(.openCode), "And it stays off")
    preferences.setConnectsAtLaunch(.codex, false)
    try expect(preferences.connectedProviders == [.claudeCode], "One switched off")
    try expect(preferences.canConnect(.codex), "And the other may come back")
    try expect(preferences.setConnectsAtLaunch(.openCode, true), "Or OpenCode in its place")
    try expect(preferences.connectedProviders == [.claudeCode, .openCode], "In surface order")
}
