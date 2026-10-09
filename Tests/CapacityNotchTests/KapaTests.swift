import CapacityNotchCore
import Foundation

private let now = Date(timeIntervalSince1970: 1_000_000)

private func snapshot(_ provider: Provider = .codex, used: [Double], state: CapacityConnectionState = .fresh) -> CapacitySnapshot {
    CapacitySnapshot(
        provider: provider,
        capturedAt: now,
        windows: used.enumerated().map { index, used in
            QuotaWindow(id: "w\(index)", label: "w\(index)", usedFraction: used, resetsAt: now.addingTimeInterval(3600))
        },
        connectionState: state
    )
}

func kapaReadsCapacityOffTheWindowWithTheLeastLeft() throws {
    try expect(KapaMood.capacity(snapshot(used: [0.24, 0.31])) == .rest, "plenty left everywhere rests")
    try expect(KapaMood.capacity(snapshot(used: [0.24, 0.5])) == .focused, "half left in one window is attentive")
    try expect(KapaMood.capacity(snapshot(used: [0.96, 0.31])) == .worried, "four percent left worries, whichever window it is")
    try expect(KapaMood.capacity(snapshot(used: [1, 0.4])) == .waiting, "a window used up waits for its reset")
    try expect(KapaMood.capacity(snapshot(used: [0.9])) == .focused, "ten percent belongs to the better state, as Capacity Pace says")
    try expect(KapaMood.capacity(snapshot(used: [])) == .rest, "nothing read yet is nothing to worry about")
}

func kapaJudgesNoOldNumbers() throws {
    try expect(KapaMood.capacity(snapshot(used: [0.96], state: .stale)) == .stale, "stale four percent is stale, not worried")
    try expect(KapaMood.capacity(snapshot(used: [], state: .connecting)) == .stale, "connecting looks like stale")
    let gone = CapacitySnapshot.disconnected(provider: .claudeCode, capturedAt: now, reason: .claudeStatusLineUnavailable)
    try expect(KapaMood.capacity(gone) == .puzzled, "a disconnected Provider puzzles")
}

func oneKapaAPageOnTheCardThatNeedsALook() throws {
    let calm = snapshot(.codex, used: [0.2])
    let low = snapshot(.claudeCode, used: [0.97])
    let focus = KapaMood.capacityFocus([calm, low])
    try expect(focus?.provider == .claudeCode && focus?.expression == .worried, "the worried card has Kapa")

    let tie = KapaMood.capacityFocus([snapshot(.codex, used: [0.2]), snapshot(.claudeCode, used: [0.1])])
    try expect(tie?.provider == .codex, "between equal cards the first keeps Kapa")

    let gone = CapacitySnapshot.disconnected(provider: .codex, capturedAt: now, reason: .codexDisconnected)
    let worse = KapaMood.capacityFocus([gone, snapshot(.claudeCode, used: [1])])
    try expect(worse?.expression == .waiting, "a window used up wants a look before a disconnected Provider")

    try expect(KapaMood.capacityFocus([]) == nil, "no cards, no Kapa")
}

func kapaBlinksEveryTwoToFiveSecondsAndSometimesTwice() throws {
    try expect(KapaBlink.delay(0) == 2.2, "the shortest wait")
    try expect(abs(KapaBlink.delay(1) - 5.4) < 1e-9, "the longest wait")
    try expect(KapaBlink.delay(7) == KapaBlink.delay(1), "a draw out of range is held to it")
    try expect(KapaBlink.isDouble(0.1) && !KapaBlink.isDouble(0.5), "about one blink in five is double")
    try expect(!KapaBlink.blinks(.happy) && !KapaBlink.blinks(.closed), "arcs and shut eyes have no lids to drop")
    try expect(KapaBlink.blinks(.open), "open eyes blink")
}

func kapasEyesSitAsDrawnAndTurnWithTheHead() throws {
    let left = KapaGaze.eye(side: -1, look: .ahead)
    let right = KapaGaze.eye(side: 1, look: .ahead)
    try expect(abs(left.x - 41) < 0.1 && abs(right.x - 63) < 0.1, "looking ahead, the eyes are where the sheet draws them")
    try expect(abs(left.scaleX - 1) < 1e-9 && left.scaleY == 1, "and at the size it draws them")

    let turned = KapaLook(yaw: 0.4, pitch: 0)
    try expect(KapaGaze.eye(side: -1, look: turned).x > left.x, "turning right moves the eyes right")
    try expect(
        KapaGaze.eye(side: 1, look: turned).scaleX < KapaGaze.eye(side: -1, look: turned).scaleX,
        "the eye turning away narrows"
    )
    try expect(KapaGaze.eye(side: 1, look: KapaLook(yaw: 1.5, pitch: 0)).isHidden, "an eye gone round the head is not drawn")
    try expect(KapaGaze.eye(side: -1, look: KapaLook(yaw: 0, pitch: 0.2)).y < 60, "looking up raises the eyes")
}

func everyKapaPoseSaysItWithMoreThanColour() throws {
    // ADR 0006: the body never changes colour, so each pose a person must
    // tell apart differs in its face or its sign.
    let faces = KapaExpression.allCases.map { KapaFace.of($0) }
    for (index, face) in faces.enumerated() {
        for other in faces[(index + 1)...] where face == other {
            throw TestFailure(description: "two poses draw the same face: \(face)")
        }
    }
    try expect(KapaFace.of(.copied).badge != KapaFace.of(.inserted).badge, "copied is not drawn as inserted")
    try expect(KapaFace.of(.music).headphones && KapaFace.of(.paused).headphones, "headphones say music, playing or paused")
    try expect(KapaPreference.defaultValue, "Kapa is on until a person turns it off")
}

func kapaFollowsATargetTheSameAtAnyFrameRate() throws {
    var thirty = 0.0
    for _ in 0 ..< 30 { thirty = KapaMotion.approach(thirty, to: 1, base: 0.0025, dt: 1.0 / 30) }
    var sixty = 0.0
    for _ in 0 ..< 60 { sixty = KapaMotion.approach(sixty, to: 1, base: 0.0025, dt: 1.0 / 60) }
    try expect(abs(thirty - sixty) < 1e-9, "a second at 30 frames ends where a second at 60 does")
    try expect(abs(thirty - 0.9975) < 1e-9, "after a second, the base of the gap is left")
}

func kapaNodsOnEveryBeatOfTheMusic() throws {
    let beat = 60 / KapaMotion.musicTempo
    try expect(KapaMotion.bob(at: 0).dy > 3, "the dip falls on the beat")
    try expect(KapaMotion.bob(at: beat * 0.7).dy < 0.1, "and has eased back up before the next")
    try expect(abs(KapaMotion.bob(at: beat).dy - KapaMotion.bob(at: 0).dy) < 1e-9, "every beat alike")
    try expect(KapaMotion.bob(at: beat / 2).tilt > 0 && KapaMotion.bob(at: beat * 1.5).tilt < 0, "swaying one way, then the other")
}

func kapaBlinksShutAndOpenInAFifthOfASecond() throws {
    try expect(KapaMotion.lid(sinceBlink: -1) == 1 && KapaMotion.lid(sinceBlink: 1) == 1, "open outside a blink")
    try expect(abs(KapaMotion.lid(sinceBlink: KapaBlink.closing) - 0.08) < 0.01, "shut at 70 ms")
    try expect(KapaMotion.lid(sinceBlink: KapaBlink.closing + KapaBlink.opening) == 1, "open again by 200 ms")
}

func kapaOpensWiderTheNearerAFileIsHeld() throws {
    let far = KapaMotion.appetite(distance: 1000, reach: 150)
    let middle = KapaMotion.appetite(distance: 75, reach: 150)
    let over = KapaMotion.appetite(distance: 0, reach: 150)
    try expect(far > 0, "a file held anywhere opens the mouth a little")
    try expect(far < middle && middle < over, "wider as it comes closer")
    try expect(over == 1, "wide open over the mouth")
}

func kapaEatsADroppedFileAndSettles() throws {
    let start = try unwrap(KapaMotion.gulp(elapsed: 0))
    try expect(start.file == 0 && !start.pleased, "the file starts where it was let go")
    let sinking = try unwrap(KapaMotion.gulp(elapsed: 0.2))
    try expect(sinking.file! > 0.2 && sinking.mouth > 0.8, "it is drawn into a wide mouth")
    let swallowed = try unwrap(KapaMotion.gulp(elapsed: 0.33))
    try expect(swallowed.file == nil && swallowed.kick.sy < 1, "then gone, with a squash")
    let chewing = (0 ..< 30).compactMap { KapaMotion.gulp(elapsed: 0.38 + Double($0) * 0.02) }
    try expect(chewing.allSatisfy(\.pleased) && chewing.contains { $0.mouth > 0.2 }, "chewed, pleased")
    try expect(KapaMotion.gulp(elapsed: KapaMotion.gulpLength) == nil, "and over")
}

func kapasMovementsEndWhereTheyBegan() throws {
    for reaction in [KapaFace.Reaction.nod, .gulp, .hop] {
        try expect(KapaMotion.kick(reaction, elapsed: KapaMotion.duration(of: reaction)) == nil, "\(reaction) ends")
        let near = try unwrap(KapaMotion.kick(reaction, elapsed: KapaMotion.duration(of: reaction) - 0.001))
        try expect(abs(near.sx - 1) < 0.02 && abs(near.sy - 1) < 0.02 && abs(near.dy) < 0.1, "\(reaction) lands at rest")
    }
    try expect(KapaMotion.boop(elapsed: KapaMotion.boopLength) == nil, "a boop ends")
    try expect(KapaMotion.shake(elapsed: KapaMotion.shakeLength) == nil, "a shake ends")
}

private func unwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw TestFailure(description: "expected a value") }
    return value
}
