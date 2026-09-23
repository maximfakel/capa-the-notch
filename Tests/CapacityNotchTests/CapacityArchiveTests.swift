import CapacityNotchCore
import Foundation

private let savedAt = Date(timeIntervalSince1970: 1_700_000_000)

private func temporaryArchive() -> CapacityArchive {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("capacity-notch-tests-\(UUID().uuidString)", isDirectory: true)
    return CapacityArchive(fileURL: directory.appendingPathComponent("archive.json"))
}

private let codexReading = CapacitySnapshot(
    provider: .codex,
    capturedAt: savedAt,
    windows: [
        QuotaWindow(
            id: "codex-primary",
            label: "5 hour",
            durationMinutes: 300,
            usedFraction: 0.7,
            resetsAt: savedAt.addingTimeInterval(3600)
        ),
    ],
    connectionState: .fresh
)

func whatWasSeenLastComesBackAsStale() throws {
    let archive = temporaryArchive()
    defer { try? FileManager.default.removeItem(at: archive.fileURL) }

    archive.save([codexReading])
    let restored = archive.load()

    try expect(restored.count == 1, "The Provider with a reading should come back")
    let snapshot = restored[0]
    try expect(snapshot.provider == .codex, "It should come back as the Provider it was")
    try expect(
        snapshot.connectionState == .stale,
        "A reading nothing has confirmed since is Stale, not Fresh"
    )
    try expect(
        snapshot.capturedAt == savedAt,
        "It keeps the moment it was true, not the moment it was read back"
    )
    try expect(
        snapshot.windows.first?.remainingPercentage == 30,
        "The numbers should survive the round trip"
    )
    try expect(
        snapshot.windows.first?.durationMinutes == 300,
        "And so should the window's shape, which Capacity Pace needs"
    )
    try expect(
        snapshot.statusReason?.guidance.contains("restarted") == true,
        "It should say why it is Stale"
    )
}

func aProviderWithNothingToShowIsNotRemembered() throws {
    let archive = temporaryArchive()
    defer { try? FileManager.default.removeItem(at: archive.fileURL) }

    archive.save([
        CapacitySnapshot.disconnected(
            provider: .codex,
            capturedAt: savedAt,
            reason: .codexDisconnected
        ),
    ])

    try expect(
        archive.load().isEmpty,
        "Remembering a Provider with no windows would bring back a Stale nothing"
    )
}

func anUnreadableArchiveCostsNothing() throws {
    let archive = temporaryArchive()
    defer { try? FileManager.default.removeItem(at: archive.fileURL) }

    try expect(archive.load().isEmpty, "A missing archive is simply empty")

    try FileManager.default.createDirectory(
        at: archive.fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("not json".utf8).write(to: archive.fileURL)
    try expect(archive.load().isEmpty, "Nor does a damaged one throw")
}

func aRestartOpensOnWhatWasThereAndAsksForTheRest() throws {
    let restored = UnreadCapacity.snapshots(
        restoring: [codexReading],
        capturedAt: savedAt
    )

    try expect(
        restored.map(\.provider) == [.codex, .claudeCode],
        "Both Providers still appear, in their order"
    )
    try expect(
        restored[0].windows.count == 1,
        "The remembered Provider opens on its numbers"
    )
    try expect(
        restored[1].windows.isEmpty,
        "The one with nothing remembered still shows nothing rather than a guess"
    )
}

func theWaitStretchesWhileAProviderIsFailing() throws {
    let schedule = RefreshSchedule.standard

    try expect(
        schedule.delay(expanded: true, consecutiveFailures: 0) == 60,
        "An open surface is watched, so it is read every minute"
    )
    try expect(
        schedule.delay(expanded: false, consecutiveFailures: 0) == 300,
        "A closed one is glanced at, so five minutes will do"
    )
    try expect(
        schedule.delay(expanded: true, consecutiveFailures: 1) == 30,
        "One failure is a blip until it happens twice, so it is tried again soon"
    )
    try expect(
        schedule.delay(expanded: false, consecutiveFailures: 1) == 30,
        "Soon whichever pace the surface is at — a closed one would otherwise wait ten minutes"
    )
    try expect(
        schedule.delay(expanded: true, consecutiveFailures: 2) == 120,
        "The second failure starts the doubling"
    )
    try expect(
        schedule.delay(expanded: true, consecutiveFailures: 3) == 240,
        "And each one after doubles it again"
    )
    try expect(
        schedule.delay(expanded: false, consecutiveFailures: 2) == 600,
        "From the closed surface's own pace"
    )
    try expect(
        schedule.delay(expanded: true, consecutiveFailures: 40) == 900,
        "A long run of failures stops at the ceiling rather than running away"
    )
    try expect(
        schedule.delay(expanded: false, consecutiveFailures: 40) == 900,
        "The ceiling is a ceiling whichever pace it started from"
    )
}

func aFailureWorthRetryingIsToldFromOneThatIsNot() throws {
    let transient: [CapacityStatusReason] = [
        .providerUnavailable(detail: "the connection closed."),
        .providerCouldNotRead(detail: "error sending request"),
        .claudeStatusLineStale,
        .claudeUsageFailed,
        .staleFromArchive,
    ]
    let terminal: [CapacityStatusReason] = [
        .providerNotInstalled,
        .providerIncompatible(detail: "too old"),
        .providerNotAuthenticated,
        .providerAnswerNotUnderstood,
        .codexDisconnected,
        .claudeDisconnected,
        .claudeStatusLineUnavailable,
        .claudeCodeNotInstalled,
        .claudeUsageNotUnderstood,
    ]

    try expect(
        transient.allSatisfy(\.isTransient),
        "A Provider that stopped answering is worth asking again"
    )
    try expect(
        terminal.allSatisfy { !$0.isTransient },
        "A Provider waiting on a person is not helped by asking again"
    )
}
