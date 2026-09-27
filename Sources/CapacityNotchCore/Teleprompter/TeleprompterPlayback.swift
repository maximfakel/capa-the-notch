import Foundation

/// Where the Script is, and how it moves on: the Teleprompter Module's
/// Running, Paused and Stopped (CONTEXT.md), as a value that answers for any
/// moment it is asked about.
///
/// The place is counted in lines of the Script as laid out on the row. The
/// speed is a multiplier, as the page and Settings show it: 1.00x is 130
/// words a minute, an easy pace read aloud, and it turns a quarter at a
/// time. The words meet the lines through the Script's average line: a
/// steady speed in words is a steady speed on screen, which is what the eye
/// can follow.
public struct TeleprompterPlayback: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case stopped
        case running
        case paused
        /// On the last line, still in view for a moment before the row goes.
        case finished
    }

    /// How long the first line holds, so the eyes can come up to it.
    public static let startHold: TimeInterval = 1
    /// How long the last line stays once the Script has been read.
    public static let finishLinger: TimeInterval = 3
    /// Words a minute at 1.00x.
    public static let standardSpeed = 130.0
    public static let multipliers = 0.5 ... 2.0
    public static let multiplierStep = 0.25

    public private(set) var state: State = .stopped
    public private(set) var multiplier: Double
    public private(set) var wordCount: Int
    public private(set) var lineCount: Int

    /// The place at `anchoredAt`; while running it moves on from there.
    private var anchor: Double = 0
    private var anchoredAt = Date.distantPast
    private var finishedAt: Date?

    public init(wordCount: Int, lineCount: Int, multiplier: Double = 1) {
        self.wordCount = max(wordCount, 0)
        self.lineCount = max(lineCount, 0)
        self.multiplier = Self.clampedMultiplier(multiplier)
    }

    /// The speed read at.
    public var wordsPerMinute: Double { Self.standardSpeed * multiplier }

    /// Whether the Teleprompter Row is in view.
    public var isShowing: Bool { state != .stopped }

    /// The place, in lines from the first; the last line is `lineCount - 1`.
    public func position(at now: Date) -> Double {
        guard state == .running else { return anchor }
        return min(anchor + max(now.timeIntervalSince(anchoredAt), 0) * linesPerSecond, lastLine)
    }

    /// How far through the Script, from 0 to 1.
    public func progress(at now: Date) -> Double {
        lastLine > 0 ? position(at: now) / lastLine : 0
    }

    public func elapsedSeconds(at now: Date) -> TimeInterval {
        linesPerSecond > 0 ? position(at: now) / linesPerSecond : 0
    }

    public func remainingSeconds(at now: Date) -> TimeInterval {
        linesPerSecond > 0 ? (lastLine - position(at: now)) / linesPerSecond : 0
    }

    /// The whole Script, first line to last, at the speed it is read at.
    public var durationSeconds: TimeInterval {
        linesPerSecond > 0 ? lastLine / linesPerSecond : 0
    }

    /// When a running Script reaches its last line.
    public var endsAt: Date? {
        guard state == .running, linesPerSecond > 0 else { return nil }
        return anchoredAt.addingTimeInterval((lastLine - anchor) / linesPerSecond)
    }

    /// When a finished Script's row goes.
    public var leavesAt: Date? {
        finishedAt?.addingTimeInterval(Self.finishLinger)
    }

    // MARK: - What a person does

    public mutating func start(at now: Date) {
        guard wordCount > 0, lineCount > 0 else { return }
        state = .running
        anchor = 0
        anchoredAt = now.addingTimeInterval(Self.startHold)
        finishedAt = nil
    }

    /// The one control for start, pause and resume: the click on the row and
    /// the first shortcut.
    public mutating func toggle(at now: Date) {
        switch state {
        case .stopped, .finished: start(at: now)
        case .running: pause(at: now)
        case .paused: resume(at: now)
        }
    }

    public mutating func pause(at now: Date) {
        guard state == .running else { return }
        anchor = position(at: now)
        state = .paused
    }

    public mutating func resume(at now: Date) {
        guard state == .paused else { return }
        anchoredAt = now
        state = .running
    }

    public mutating func stop() {
        state = .stopped
        anchor = 0
        finishedAt = nil
    }

    public mutating func faster(at now: Date) { setMultiplier(multiplier + Self.multiplierStep, at: now) }
    public mutating func slower(at now: Date) { setMultiplier(multiplier - Self.multiplierStep, at: now) }

    public mutating func setMultiplier(_ value: Double, at now: Date) {
        rebase(at: now)
        multiplier = Self.clampedMultiplier(value)
    }


    /// Two fingers on the row: the Script moves under them, and stays put
    /// when they lift.
    public mutating func move(byLines lines: Double, at now: Date) {
        guard isShowing else { return }
        anchor = min(max(position(at: now) + lines, 0), lastLine)
        if state != .paused { state = .paused }
        finishedAt = nil
    }

    /// The progress dragged on the page. A Script not running is left
    /// paused there, so the next start begins where it was put.
    public mutating func seek(toFraction fraction: Double, at now: Date) {
        guard wordCount > 0, lineCount > 0 else { return }
        anchor = min(max(fraction, 0), 1) * lastLine
        finishedAt = nil
        if state == .running {
            anchoredAt = max(now, anchoredAt)
        } else {
            state = .paused
        }
    }

    /// The Script laid out again — another text size, another Script — keeps
    /// its place as a share of the whole.
    public mutating func relayout(wordCount: Int, lineCount: Int, at now: Date) {
        let fraction = progress(at: now)
        rebase(at: now)
        self.wordCount = max(wordCount, 0)
        self.lineCount = max(lineCount, 0)
        anchor = fraction * lastLine
        if self.wordCount == 0 || self.lineCount == 0 { stop() }
    }

    /// Moves the states that change by themselves on to `now`: the last line
    /// reached, and the row leaving three seconds after.
    public mutating func advance(to now: Date) {
        if state == .running, let endsAt, now >= endsAt {
            anchor = lastLine
            state = .finished
            finishedAt = endsAt
        }
        if state == .finished, let leavesAt, now >= leavesAt {
            stop()
        }
    }

    // MARK: -

    private var lastLine: Double { Double(max(lineCount - 1, 0)) }

    private var linesPerSecond: Double {
        guard wordCount > 0, lineCount > 0 else { return 0 }
        let wordsPerLine = Double(wordCount) / Double(lineCount)
        return wordsPerMinute / 60 / wordsPerLine
    }

    /// Fixes the place reached so far as the new starting point, keeping a
    /// hold that has not run out yet.
    private mutating func rebase(at now: Date) {
        guard state == .running else { return }
        anchor = position(at: now)
        anchoredAt = max(now, anchoredAt)
    }

    /// Kept to the hundredth, so a step lands on 1.25 and never drifts to
    /// 1.2499.
    public static func clampedMultiplier(_ value: Double) -> Double {
        (min(max(value, multipliers.lowerBound), multipliers.upperBound) * 100).rounded() / 100
    }
}
