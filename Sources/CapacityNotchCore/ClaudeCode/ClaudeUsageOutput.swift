import Foundation

/// Reads what `claude /usage` prints.
///
/// This is prose, not a contract. A wording change in Claude Code breaks it,
/// which is why every failure here returns nothing rather than a guess: a
/// Provider that cannot be read must say so, not show a number that has
/// quietly stopped moving.
public enum ClaudeUsageOutput {
    /// Turns the printed report into a reading, or nothing when no line in it
    /// is one of the windows CapaTheNotch shows — or when one of its windows
    /// is worded in a way CapaTheNotch does not know. That is what a changed
    /// report looks like, and reading only the lines still recognised would
    /// drop a window without a word.
    public static func reading(
        from text: String,
        capturedAt: Date,
        calendar: Calendar = .current
    ) -> ClaudeCapacityReading? {
        let lines = text.split(separator: "\n").map(String.init)
        guard !lines.contains(where: isUnknownWindow) else { return nil }

        let windows = lines
            .compactMap { window(from: $0, capturedAt: capturedAt, calendar: calendar) }

        guard !windows.isEmpty else { return nil }
        return ClaudeCapacityReading(capturedAt: capturedAt, windows: windows)
    }

    static func window(
        from line: String,
        capturedAt: Date,
        calendar: Calendar = .current
    ) -> QuotaWindow? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let shape = shape(of: trimmed) else { return nil }

        guard
            let colon = trimmed.firstIndex(of: ":"),
            let usedRange = trimmed.range(of: "% used", range: colon ..< trimmed.endIndex)
        else { return nil }

        let percentText = trimmed[trimmed.index(after: colon) ..< usedRange.lowerBound]
            .trimmingCharacters(in: .whitespaces)
        guard let percent = Double(percentText), percent >= 0 else { return nil }

        return QuotaWindow(
            id: shape.id,
            label: shape.label,
            durationMinutes: shape.durationMinutes,
            usedFraction: min(percent / 100, 1),
            resetsAt: resetDate(in: trimmed, capturedAt: capturedAt, calendar: calendar)
        )
    }

    /// Which window a line describes, matching the ids the status-line bridge
    /// publishes so a reading from either source lines up with the other.
    ///
    /// A per-model weekly line — `Current week (Fable)` — is deliberately not
    /// one of these yet. It is a real window, but showing it needs a decision
    /// about what the surface does with three.
    private static func shape(of line: String) -> (id: String, label: String, durationMinutes: Int)? {
        if line.hasPrefix("Current session:") {
            return ("claude-five-hour", "5 hour", 300)
        }
        if line.hasPrefix("Current week (all models):") {
            return ("claude-seven-day", "Weekly", 10_080)
        }
        return nil
    }

    /// A line with a window's form — a name, a colon, a percentage used — that
    /// is neither a window CapaTheNotch shows nor one it knowingly leaves out.
    private static func isUnknownWindow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard
            let colon = trimmed.firstIndex(of: ":"),
            trimmed.range(of: "% used", range: colon ..< trimmed.endIndex) != nil
        else { return false }

        return shape(of: trimmed) == nil && !isPerModelWeek(trimmed)
    }

    private static func isPerModelWeek(_ line: String) -> Bool {
        line.hasPrefix("Current week (")
    }

    /// The reset moment from `resets Sep 20 at 7pm (Europe/Moscow)`.
    ///
    /// The year is not printed, so it comes from the reading's own moment. A
    /// date that lands far enough in the past to be implausible is read as
    /// next year's, which is what a window resetting in January looks like
    /// when read in December.
    private static func resetDate(
        in line: String,
        capturedAt: Date,
        calendar: Calendar
    ) -> Date? {
        guard let resets = line.range(of: "resets ") else { return nil }
        let tail = line[resets.upperBound...]

        let stamp: Substring
        let zone: TimeZone
        if let open = tail.firstIndex(of: "(") {
            stamp = tail[..<open].trimmingCharacters(in: .whitespaces)[...]
            let named = tail[tail.index(after: open)...].prefix { $0 != ")" }
            zone = TimeZone(identifier: String(named)) ?? calendar.timeZone
        } else {
            stamp = tail.trimmingCharacters(in: .whitespaces)[...]
            zone = calendar.timeZone
        }

        var workingCalendar = calendar
        workingCalendar.timeZone = zone

        guard let parsed = parse(stamp: String(stamp), timeZone: zone) else { return nil }

        var components = workingCalendar.dateComponents(
            [.month, .day, .hour, .minute],
            from: parsed
        )
        components.year = workingCalendar.component(.year, from: capturedAt)
        components.timeZone = zone

        guard let candidate = workingCalendar.date(from: components) else { return nil }
        // A reset printed as long past is next year's, seen across the turn of
        // the year. A few days of slack keeps a clock skew from triggering it.
        guard candidate.timeIntervalSince(capturedAt) < -7 * 24 * 60 * 60 else { return candidate }

        components.year = (components.year ?? 0) + 1
        return workingCalendar.date(from: components)
    }

    private static func parse(stamp: String, timeZone: TimeZone) -> Date? {
        for format in ["MMM d 'at' h:mma", "MMM d 'at' ha"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.amSymbol = "am"
            formatter.pmSymbol = "pm"
            formatter.dateFormat = format
            if let date = formatter.date(from: stamp) { return date }
        }
        return nil
    }
}
