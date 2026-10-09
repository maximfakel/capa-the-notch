import CapacityNotchCore
import Foundation

// Ticket 14: two taps of one finger, read from touch frames.

/// One finger down at `start`, frames every 8 ms while it stays, then a
/// frame with nothing on the glass. `drift` moves it that far by the lift.
private func touch(
    _ id: Int, at start: TimeInterval, x: Double = 60, y: Double = 40,
    lasting duration: TimeInterval = 0.08, drift: Double = 0, size: Double = 9,
    with others: [TouchContact] = []
) -> [TouchFrame] {
    let steps = max(Int(duration / 0.008), 1)
    var frames = (0...steps).map { step in
        let done = Double(step) / Double(steps)
        return TouchFrame(
            time: start + duration * done,
            contacts: [TouchContact(id: id, x: x + drift * done, y: y, size: size)] + others
        )
    }
    frames.append(TouchFrame(time: start + duration + 0.008, contacts: []))
    return frames
}

/// How many times the frames, in order, complete two taps.
private func doubleTaps(_ frames: [TouchFrame], tuning: TapTuning = TapTuning(), press: TimeInterval? = nil) -> Int {
    var recogniser = TrackpadDoubleTap(tuning: tuning)
    var pressed = false
    return frames.reduce(0) { count, frame in
        if let press, !pressed, frame.time >= press {
            pressed = true
            recogniser.press(at: press)
        }
        return count + (recogniser.observe(frame) ? 1 : 0)
    }
}

func twoQuickTapsOfOneFingerOpenTheSurface() throws {
    let frames = touch(1, at: 0) + touch(2, at: 0.25)
    try expect(doubleTaps(frames) == 1, "Two light taps a quarter-second apart are a double tap")
    try expect(doubleTaps(touch(1, at: 0)) == 0, "One tap is not")
    let slightlyApart = touch(1, at: 0, x: 60) + touch(2, at: 0.25, x: 66, drift: 1)
    try expect(doubleTaps(slightlyApart) == 1, "A finger lands a little off the first, and moves a little")
}

func twoFingersAreNotOneFingerTapping() throws {
    let thumb = TouchContact(id: 9, x: 20, y: 5, size: 11)
    let withThumb = touch(1, at: 0, with: [thumb]) + touch(2, at: 0.25, with: [thumb])
    try expect(doubleTaps(withThumb) == 0, "A resting thumb makes each tap two fingers")
    let pair = TouchContact(id: 5, x: 80, y: 40, size: 9)
    let twoFingerDoubleTap = touch(1, at: 0, with: [pair]) + touch(2, at: 0.25, with: [TouchContact(id: 6, x: 80, y: 40, size: 9)])
    try expect(doubleTaps(twoFingerDoubleTap) == 0, "Two fingers tapping twice is not it")
    let betweenThem = touch(1, at: 0) + touch(3, at: 0.1, lasting: 0.05, with: [pair]) + touch(2, at: 0.25)
    try expect(doubleTaps(betweenThem) == 0, "Two fingers between the taps end the first")
}

func aDragOrAPressAndHoldIsNotATap() throws {
    try expect(doubleTaps(touch(1, at: 0) + touch(2, at: 0.25, drift: 8)) == 0, "A second touch that drags is not a tap")
    try expect(doubleTaps(touch(1, at: 0, drift: 8) + touch(2, at: 0.25)) == 0, "Nor a first one")
    try expect(doubleTaps(touch(1, at: 0) + touch(2, at: 0.25, lasting: 0.6)) == 0, "A press-and-hold is not a tap")
    try expect(doubleTaps(touch(1, at: 0, lasting: 0.6) + touch(2, at: 0.8)) == 0, "Nor before one")
}

func aPalmIsNotATap() throws {
    try expect(doubleTaps(touch(1, at: 0, size: 32) + touch(2, at: 0.25, size: 32)) == 0, "A palm laid down twice is not a double tap")
    try expect(doubleTaps(touch(1, at: 0) + touch(2, at: 0.25, size: 32)) == 0, "Nor a tap and then a palm")
}

func tapsTooFarApartInTimeOrPlaceAreTwoSingleTaps() throws {
    try expect(doubleTaps(touch(1, at: 0) + touch(2, at: 0.7)) == 0, "Further apart than the double-click interval")
    try expect(doubleTaps(touch(1, at: 0, x: 30) + touch(2, at: 0.25, x: 90)) == 0, "Six centimetres apart")
    let slow = TapTuning.matching(doubleClickInterval: 0.9)
    try expect(doubleTaps(touch(1, at: 0) + touch(2, at: 0.7), tuning: slow) == 1, "A slower double-click interval in System Settings allows slower taps")
    let late = touch(1, at: 0) + touch(2, at: 0.7) + touch(3, at: 0.95)
    try expect(doubleTaps(late) == 1, "A tap that came too late can still be the first of the next pair")
}

func aTouchThatClicksIsAClickNotATap() throws {
    try expect(doubleTaps(touch(1, at: 0) + touch(2, at: 0.25), press: 0.28) == 0, "The second touch pressed the trackpad down")
    try expect(doubleTaps(touch(1, at: 0) + touch(2, at: 0.25), press: 0.03) == 0, "The first did")
    try expect(doubleTaps(touch(1, at: 0) + touch(2, at: 0.25), press: 0.12) == 0, "A press reported just after the first lift still counts against it")
}

func aThirdTapStartsOver() throws {
    let four = touch(1, at: 0) + touch(2, at: 0.2) + touch(3, at: 0.4) + touch(4, at: 0.6)
    try expect(doubleTaps(four) == 2, "Four taps are two double taps, not three")
    try expect(doubleTaps(touch(1, at: 0) + touch(2, at: 0.2) + touch(3, at: 0.4)) == 1, "Three taps open once")
}

func aTrackpadThatStopsAnsweringIsNoticed() throws {
    var silence = TrackpadSilence()
    try expect(!silence.trackpadScrolled(at: 10, lastFrame: 9.95), "A scroll with frames around it is fine")
    try expect(!silence.trackpadScrolled(at: 20, lastFrame: 9.95), "One unanswered scroll is not yet silence")
    try expect(!silence.trackpadScrolled(at: 30, lastFrame: 9.95), "Nor two")
    try expect(silence.trackpadScrolled(at: 40, lastFrame: 9.95), "Three in a row with no frame near any is")
    silence.reset()
    try expect(!silence.trackpadScrolled(at: 50, lastFrame: nil), "Counting starts again after a restart")
    try expect(!silence.trackpadScrolled(at: 60, lastFrame: 59.9), "A frame near a scroll answers for the trackpad")
    try expect(!silence.trackpadScrolled(at: 70, lastFrame: nil), "And the count began again")
}

func theTrackpadTapIsOffUntilAskedForAndSaysWhenItCannotWork() throws {
    let suite = "trackpad-tap-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = Preferences(defaults: defaults)
    try expect(!preferences.opensOnTrackpadTap, "Off for anyone who has not asked for it")
    preferences.opensOnTrackpadTap = true
    try expect(Preferences(defaults: defaults).opensOnTrackpadTap, "Remembered once asked for")

    try expect(TrackpadTapStatus.off.diagnosticCode == nil, "Off, the report says nothing about it")
    let failures: [TrackpadTapStatus] = [.unreadable, .noTrackpad, .silent]
    for status in failures + [.listening] {
        let code = status.diagnosticCode ?? ""
        try expect(code.hasPrefix("trackpad-tap-") && code.count < 32, "A short code the report keeps, got \(code)")
        try expect(Redaction.scrub(code) == code, "Redaction leaves \(code) alone")
    }
    for status in failures {
        let guidance = status.guidance ?? ""
        try expect(!guidance.isEmpty, "Settings has a sentence for \(status)")
        try expect(Localization.text(guidance, in: .russian) != guidance, "And it is in Russian: \(guidance)")
    }
    try expect(Localization.text(TrackpadTapModule.cost, in: .russian) != TrackpadTapModule.cost, "The cost is said in Russian too")
    try expect(Localization.text("Open with two taps on the trackpad", in: .russian) != "Open with two taps on the trackpad", "So is the switch")
}

func twoTapsWhileTypingAreAHandOnTheTrackpad() throws {
    try expect(TrackpadTyping.suppresses(secondsSinceKeyDown: 0.05), "a key just pressed means the hands are typing")
    try expect(TrackpadTyping.suppresses(secondsSinceKeyDown: 0.9), "a key under a second ago still counts as typing")
    try expect(!TrackpadTyping.suppresses(secondsSinceKeyDown: 1.5), "a second and more after the last key, two taps open the surface")
}
