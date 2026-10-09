import Foundation

// The Calendar page's Week and Month, beside its Day ("Notch — Expanded —
// Calendar, week", "… month", "… month of six weeks"; the author's decisions
// of 2026-10-07, and the frames as the author edited them on 2026-10-08).
// What each shows is decided here, where it is checked; the application only
// draws it.

/// The Calendar page's frame, as every view of it is drawn since the
/// author's edits of 2026-10-08: the Shelf page's — ten above, an 18-point
/// header, eight under it, 112 for the view and four below — so it is the
/// 152 every page has, with nothing squeezed (`NotchGeometry.pageHeight`).
public enum CalendarPageLayout {
    public static let top: Double = 10
    public static let header: Double = 18
    public static let belowHeader: Double = 8
    public static let content: Double = 112
    public static let bottom: Double = 4

    public static var height: Double { top + header + belowHeader + content + bottom }
}

/// The three views of the Calendar page, in the order the tabs stand.
public enum CalendarTab: String, CaseIterable, Sendable {
    case day
    case week
    case month

    /// The page opens on the tab last used; before any, on the day.
    public static let standard: CalendarTab = .day

    /// The tab's name, in English; the surface translates it.
    public var title: String {
        switch self {
        case .day: "Day"
        case .week: "Week"
        case .month: "Month"
        }
    }
}

/// How a day's number is drawn: today in its red circle; any other day of
/// this month at full strength, past or not (the author's rule, 2026-10-08);
/// one of the month before or after fainter.
public enum CalendarDayTone: Equatable, Sendable {
    case today
    case current
    case otherMonth
}

/// One day as the Week and the Month draw it.
public struct CalendarGridDay: Equatable, Identifiable, Sendable {
    public var id: Date { start }

    /// Its midnight, in the Mac's calendar and time zone.
    public let start: Date
    /// The day of the month.
    public let number: Int
    /// Monday 0 … Sunday 6, whatever the Mac's first weekday: the Month is
    /// Monday first (the author's choice).
    public let weekdayIndex: Int
    public let isToday: Bool
    /// Before today.
    public let isPast: Bool
    /// Of the month shown; always true in the Week.
    public let isInMonth: Bool
    /// Saturday or Sunday.
    public let isWeekend: Bool
    /// Marked by an all-day event in a holiday calendar the person has in
    /// Calendar (`HolidayCalendar`). Without one, no day is a holiday.
    public let isHoliday: Bool
    /// What is on that day: all-day first, then by when they start. Today
    /// keeps only what is not over yet, as the Day does.
    public let events: [CalendarEvent]

    /// Weekends and holidays are drawn in red.
    public var isRed: Bool { isWeekend || isHoliday }

    public var tone: CalendarDayTone {
        if isToday { return .today }
        return isInMonth ? .current : .otherMonth
    }

    /// The Month's dots under the number: the colours of that day's
    /// calendars, each once, in the order their events come, three at most.
    /// A holiday calendar's day has none: its red number says it (as "…
    /// month of six weeks" draws 23 February, 8 and 9 March).
    public var dots: [CalendarColour?] {
        var colours: [CalendarColour?] = []
        for event in events where !event.isHoliday && !colours.contains(event.colour) {
            colours.append(event.colour)
            if colours.count == CalendarMonth.maximumDots { break }
        }
        return colours
    }
}

// MARK: - Days

/// Days, Monday first, and what is on each.
public enum CalendarGrid {
    /// Monday 0 … Sunday 6.
    public static func weekdayIndex(of date: Date, calendar: Calendar) -> Int {
        (calendar.component(.weekday, from: date) + 5) % 7
    }

    public static func day(containing date: Date, calendar: Calendar) -> DateInterval {
        CalendarDay.interval(containing: date, calendar: calendar)
    }

    /// Whether the event is on that day: begun before it ends and not over
    /// before it begins. An event of no length counts on the day it is at.
    static func overlaps(_ event: CalendarEvent, _ day: DateInterval) -> Bool {
        event.start < day.end && (event.end > day.start || event.start >= day.start)
    }

    /// What is on a day: neither declined nor cancelled, all-day first, then
    /// by when they start. On today, only what is not over yet.
    public static func agenda(on date: Date, in events: [CalendarEvent], at now: Date, calendar: Calendar) -> [CalendarEvent] {
        let day = self.day(containing: date, calendar: calendar)
        let isToday = day.contains(now)
        return events
            .filter { $0.counts && overlaps($0, day) && (!isToday || $0.end > now) }
            .sorted { a, b in a.isAllDay != b.isAllDay ? a.isAllDay : CalendarSurface.earlierFirst(a, b) }
    }

    /// A holiday: an all-day event in a holiday calendar is on it.
    public static func isHoliday(_ date: Date, in events: [CalendarEvent], calendar: Calendar) -> Bool {
        let day = self.day(containing: date, calendar: calendar)
        return events.contains { $0.counts && $0.isAllDay && $0.isHoliday && overlaps($0, day) }
    }

    static func gridDay(_ start: Date, inMonth: Bool, events: [CalendarEvent], now: Date, calendar: Calendar) -> CalendarGridDay {
        let today = calendar.startOfDay(for: now)
        let index = weekdayIndex(of: start, calendar: calendar)
        return CalendarGridDay(
            start: start,
            number: calendar.component(.day, from: start),
            weekdayIndex: index,
            isToday: start == today,
            isPast: start < today,
            isInMonth: inMonth,
            isWeekend: index >= 5,
            isHoliday: isHoliday(start, in: events, calendar: calendar),
            events: agenda(on: start, in: events, at: now, calendar: calendar)
        )
    }

    /// The midnight `days` after this one.
    static func adding(_ days: Int, to start: Date, calendar: Calendar) -> Date {
        calendar.startOfDay(for: calendar.date(byAdding: .day, value: days, to: start) ?? start.addingTimeInterval(Double(days) * 86_400))
    }
}

// MARK: - The Week

/// Seven days starting today, not Monday (the author's choice): what is
/// coming, not the week's paperwork.
public struct CalendarWeek: Equatable, Sendable {
    public static let length = 7

    public let days: [CalendarGridDay]
    /// Today's midnight to the midnight seven days on.
    public let interval: DateInterval

    public init(events: [CalendarEvent], at now: Date, calendar: Calendar = .current) {
        interval = Self.interval(containing: now, calendar: calendar)
        let first = interval.start
        days = (0..<Self.length).map { offset in
            CalendarGrid.gridDay(CalendarGrid.adding(offset, to: first, calendar: calendar), inMonth: true, events: events, now: now, calendar: calendar)
        }
        next = CalendarAhead.first(after: interval.end, in: events, calendar: calendar)
    }

    public static func interval(containing now: Date, calendar: Calendar = .current) -> DateInterval {
        let start = calendar.startOfDay(for: now)
        return DateInterval(start: start, end: CalendarGrid.adding(length, to: start, calendar: calendar))
    }

    /// How many events the week shows, each once however many days it
    /// spans: the header's "14 встреч".
    public var eventCount: Int {
        Set(days.flatMap { $0.events.map(\.id) }).count
    }

    /// Nothing on any of the seven days ("… Calendar, week with nothing"):
    /// one box across the week instead of seven free ones.
    public var isFree: Bool { days.allSatisfy(\.events.isEmpty) }

    /// The first event after the week, for a free week to say when the next
    /// one is; nil when nothing is read beyond it.
    public let next: CalendarEvent?
}

/// The Week's chips: two a day at most, as the author drew it on
/// 2026-10-08; with more, "ещё N" under the two says how many are left.
/// Two chips and that line keep inside the 112-point view: 24 for the date,
/// then 3 + 29 + 3 + 29 + 3 + 14.
public enum CalendarChips {
    public static let maximum = 2
    /// Between the date and the chips, between chips, and before "ещё N".
    public static let spacing: Double = 3

    public struct Fit: Equatable, Sendable {
        public let shown: [CalendarEvent]
        /// How many are left out, for "ещё N"; zero when all are shown.
        public let more: Int

        public init(shown: [CalendarEvent], more: Int) {
            self.shown = shown
            self.more = more
        }
    }

    public static func fit(_ events: [CalendarEvent]) -> Fit {
        let shown = Array(events.prefix(maximum))
        return Fit(shown: shown, more: events.count - shown.count)
    }
}

// MARK: - The Month

/// The current month's grid, Monday first, from the week holding the first
/// to the week holding the last: five rows, or six (March 2026: 23 February
/// to 5 April).
public struct CalendarMonth: Equatable, Sendable {
    public static let maximumDots = 3

    /// How the grid is drawn for the weeks it has: it fills the view's 112.
    public var metrics: CalendarMonthMetrics { CalendarMonthMetrics(weeks: weeks.count) }

    public let year: Int
    /// 1 … 12.
    public let month: Int
    /// Five or six weeks of seven days.
    public let weeks: [[CalendarGridDay]]
    /// The grid's first midnight to the midnight after its last day.
    public let interval: DateInterval

    public init(events: [CalendarEvent], at now: Date, calendar: Calendar = .current) {
        let components = calendar.dateComponents([.year, .month], from: now)
        year = components.year ?? 0
        month = components.month ?? 1
        interval = Self.interval(containing: now, calendar: calendar)
        let first = interval.start
        let count = Int((interval.duration / 86_400).rounded()) // whole days; a clock change is an hour either way
        let days = (0..<count).map { offset -> CalendarGridDay in
            let start = CalendarGrid.adding(offset, to: first, calendar: calendar)
            let inMonth = calendar.component(.month, from: start) == components.month
            return CalendarGrid.gridDay(start, inMonth: inMonth, events: events, now: now, calendar: calendar)
        }
        weeks = stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }
    }

    /// From the Monday on or before the first of the month to the midnight
    /// after the Sunday on or after its last day.
    public static func interval(containing now: Date, calendar: Calendar = .current) -> DateInterval {
        let today = calendar.startOfDay(for: now)
        let firstOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: today)) ?? today
        let days = calendar.range(of: .day, in: .month, for: firstOfMonth)?.count ?? 30
        let lastOfMonth = CalendarGrid.adding(days - 1, to: firstOfMonth, calendar: calendar)
        let start = CalendarGrid.adding(-CalendarGrid.weekdayIndex(of: firstOfMonth, calendar: calendar), to: firstOfMonth, calendar: calendar)
        let end = CalendarGrid.adding(7 - CalendarGrid.weekdayIndex(of: lastOfMonth, calendar: calendar), to: lastOfMonth, calendar: calendar)
        return DateInterval(start: start, end: end)
    }

    public var days: [CalendarGridDay] { weeks.flatMap { $0 } }

    /// The grid's day holding this moment, if the grid holds it: each runs
    /// from its midnight to the next day's, the last to the grid's end.
    public func day(containing date: Date) -> CalendarGridDay? {
        let all = days
        guard interval.start <= date, date < interval.end else { return nil }
        return all.indices.last { all[$0].start <= date }.map { all[$0] }
    }

    public var today: CalendarGridDay? { days.first(where: \.isToday) }

    /// The day whose events the list beside the grid shows: the one clicked,
    /// while it is in the grid; otherwise today.
    public func selected(_ chosen: Date?) -> CalendarGridDay? {
        if let chosen, let day = day(containing: chosen) { return day }
        return today
    }
}

/// The Month's grid fills the view's 112 points whatever weeks it has (the
/// author's revision of 2026-10-08, "… month" and "… month of six weeks"):
///
/// - five weeks: weekdays 12 high, rows of 20 — the number in a 16 × 16
///   frame at 11 points, a point's gap, the 3-point dots. 12 + 5 × 20 = 112.
/// - six weeks: weekdays 10 high, rows of 17 — the number in a 14 × 14
///   frame at 10.5 points drawn a little tighter, the dots straight under.
///   10 + 6 × 17 = 112.
///
/// A row never grows past 20 (a four-week February leaves room below).
/// Today and the chosen day are circles the size of the number's frame.
public struct CalendarMonthMetrics: Equatable, Sendable {
    public static let dotSize: Double = 3
    public static let largestRow: Double = 20

    public let weekdayHeight: Double
    public let rowHeight: Double
    /// The number's square frame, and the circle of today or the chosen day.
    public let numberFrame: Double
    public let numberSize: Double
    /// Letter spacing, in ems.
    public let numberTracking: Double
    /// Between the number's frame and the dots.
    public let dotGap: Double

    public init(weeks: Int, height: Double = CalendarPageLayout.content) {
        let weeks = Double(max(weeks, 1))
        let roomy = weeks <= 5
        weekdayHeight = roomy ? 12 : 10
        rowHeight = min(((height - weekdayHeight) / weeks).rounded(.down), Self.largestRow)
        dotGap = rowHeight >= Self.largestRow ? 1 : 0
        numberFrame = rowHeight - Self.dotSize - dotGap
        numberSize = numberFrame >= 16 ? 11 : 10.5
        numberTracking = numberFrame >= 16 ? 0 : -0.02
    }

    /// The grid's height: the weekdays and the rows.
    public func gridHeight(weeks: Int) -> Double {
        weekdayHeight + Double(weeks) * rowHeight
    }

    /// Where each week's row starts, from the top of the grid.
    public func rowTops(weeks: Int) -> [Double] {
        (0..<weeks).map { weekdayHeight + Double($0) * rowHeight }
    }

    /// Today's circle, or the chosen day's: the number's frame, never an
    /// ellipse. A two-digit number does not fit a 14-point circle, so its
    /// circle grows to 16 and reaches over the dots' row.
    public func circle(for number: Int) -> Double {
        number >= 10 && numberFrame < 16 ? 16 : numberFrame
    }
}

// MARK: - Reading

/// What the page needs read: today and just past midnight for the row and
/// the Day, seven days from today for the Week, the Month's whole grid — up
/// to six weeks — and thirty days past today, so a page with nothing on it
/// can say when the next event is; whichever reaches furthest each way.
public enum CalendarReading {
    /// How far past today is read for "Ближайшее — …".
    public static let daysAhead = 30

    public static func interval(containing now: Date, calendar: Calendar = .current) -> DateInterval {
        let day = CalendarDay.readInterval(containing: now, calendar: calendar)
        let week = CalendarWeek.interval(containing: now, calendar: calendar)
        let month = CalendarMonth.interval(containing: now, calendar: calendar)
        let ahead = CalendarGrid.adding(1 + daysAhead, to: calendar.startOfDay(for: now), calendar: calendar)
        return DateInterval(
            start: min(day.start, week.start, month.start),
            end: max(day.end, week.end, month.end, ahead)
        )
    }
}

// MARK: - What comes next

/// What a page with nothing on it says is coming: the Day with nothing left
/// today, the Week with nothing in it, the Month's chosen day free.
public enum CalendarAhead {
    /// The first event at or after the moment, among what was read: on the
    /// first day that has one, its first timed event, or, with none, its
    /// all-day one. A holiday calendar's days are not events anyone goes to
    /// (they are red in the Week and the Month), so they are passed over.
    public static func first(after moment: Date, in events: [CalendarEvent], calendar: Calendar = .current) -> CalendarEvent? {
        let coming = events.filter { $0.counts && !$0.isHoliday && $0.start >= moment }
        guard let earliest = coming.min(by: CalendarSurface.earlierFirst) else { return nil }
        let day = CalendarGrid.day(containing: earliest.start, calendar: calendar)
        let thatDay = coming.filter { day.contains($0.start) }.sorted(by: CalendarSurface.earlierFirst)
        return thatDay.first { !$0.isAllDay } ?? thatDay.first
    }

    /// After a day chosen in the Month with nothing on it: the first event
    /// after that day — after now, for today.
    public static func after(_ day: CalendarGridDay, in events: [CalendarEvent], at now: Date, calendar: Calendar = .current) -> CalendarEvent? {
        let moment = day.isToday ? now : CalendarGrid.adding(1, to: day.start, calendar: calendar)
        return first(after: moment, in: events, calendar: calendar)
    }
}

/// What the Day says under "На сегодня всё".
public enum CalendarNext: Equatable, Sendable {
    /// Tomorrow's first: "Ближайшее — завтра, 10:00 · Стендап".
    case tomorrow(CalendarEvent)
    /// Nothing tomorrow, so the next after it: "Ближайшее — пн, 12 октября,
    /// 10:00 · Стендап".
    case later(CalendarEvent)
    /// Nothing in what is read: "Впереди пусто".
    case nothing
}

// MARK: - Holidays

/// Which calendars mark holidays. EventKit has no flag for it: macOS's own
/// holiday calendar ("Праздники России", "Russian Holidays", "US Holidays")
/// arrives as a subscribed, read-only calendar, and Google's ("Holidays in
/// Russia") as a read-only one. A calendar of either kind whose name speaks
/// of holidays is taken as one; a person's own, writable "Holidays" — a
/// holiday, as in time off — is not.
public enum HolidayCalendar {
    private static let words = ["holiday", "праздник"]

    public static func recognises(title: String, isSubscribed: Bool, isReadOnly: Bool) -> Bool {
        guard isSubscribed || isReadOnly else { return false }
        let name = title.lowercased()
        return words.contains { name.contains($0) }
    }
}

// MARK: - Words

/// The page's headings and dates, in the language the surface speaks: kept
/// here, with their own tables, so a check can read them in either language.
public enum CalendarTitles {
    /// The Day's date: "вс, 4 октября", "Sun, October 4".
    public static func dayDate(_ date: Date, calendar: Calendar = .current, in language: AppLanguage = Localization.current) -> String {
        let weekday = CalendarGrid.weekdayIndex(of: date, calendar: calendar)
        let day = calendar.component(.day, from: date)
        let month = calendar.component(.month, from: date)
        switch language.resolved() {
        case .russian:
            return "\(CalendarNames.weekdayShort(weekday, in: .russian)), \(day) \(CalendarNames.monthGenitive(month, in: .russian))"
        case .english, .system:
            return "\(CalendarNames.weekdayShort(weekday, in: .english)), \(CalendarNames.monthGenitive(month, in: .english)) \(day)"
        }
    }

    /// The day a Month cell speaks: "среда, 7 октября", "Wednesday, October 7".
    public static func spokenDate(_ date: Date, calendar: Calendar = .current, in language: AppLanguage = Localization.current) -> String {
        let weekday = CalendarGrid.weekdayIndex(of: date, calendar: calendar)
        let day = calendar.component(.day, from: date)
        let month = calendar.component(.month, from: date)
        switch language.resolved() {
        case .russian:
            return "\(CalendarNames.weekdayWide(weekday, in: .russian)), \(day) \(CalendarNames.monthGenitive(month, in: .russian))"
        case .english, .system:
            return "\(CalendarNames.weekdayWide(weekday, in: .english)), \(CalendarNames.monthGenitive(month, in: .english)) \(day)"
        }
    }

    /// The Week's heading, compact, as the author wrote it on 2026-10-08:
    /// "4-10.10", and across months "28.09-4.10". In English "Oct 4–10" and
    /// "Sep 28–Oct 4".
    public static func weekRange(_ week: DateInterval, calendar: Calendar = .current, in language: AppLanguage = Localization.current) -> String {
        let first = week.start
        let last = CalendarGrid.adding(-1, to: week.end, calendar: calendar)
        let (firstDay, lastDay) = (calendar.component(.day, from: first), calendar.component(.day, from: last))
        let (firstMonth, lastMonth) = (calendar.component(.month, from: first), calendar.component(.month, from: last))
        if language.resolved() == .russian {
            let month = { (number: Int) in number < 10 ? "0\(number)" : "\(number)" }
            return firstMonth == lastMonth
                ? "\(firstDay)-\(lastDay).\(month(lastMonth))"
                : "\(firstDay).\(month(firstMonth))-\(lastDay).\(month(lastMonth))"
        }
        let a = CalendarNames.monthShort(firstMonth, in: .english)
        let b = CalendarNames.monthShort(lastMonth, in: .english)
        return firstMonth == lastMonth ? "\(a) \(firstDay)–\(lastDay)" : "\(a) \(firstDay)–\(b) \(lastDay)"
    }

    /// Beside the Week's heading: "14 встреч", or "нет встреч".
    public static func weekCount(_ week: CalendarWeek, in language: AppLanguage = Localization.current) -> String {
        week.eventCount == 0
            ? Localization.text("no events", in: language)
            : Localization.eventCount(week.eventCount, in: language)
    }

    /// An event's title as the surface shows it; an untitled one says so.
    public static func eventTitle(_ event: CalendarEvent, in language: AppLanguage = Localization.current) -> String {
        let trimmed = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Localization.text("No title", in: language) : trimmed
    }

    /// When an event is: its time, or "весь день"; with its date first when
    /// asked, "пн, 12 октября, 10:00". The time is the Mac's own clock, 12 or
    /// 24 hours, which the surface passes in.
    static func when(_ event: CalendarEvent, dated: Bool, time: (Date) -> String, calendar: Calendar, in language: AppLanguage) -> String {
        let hour = event.isAllDay ? Localization.text("all day", in: language) : time(event.start)
        return dated ? "\(dayDate(event.start, calendar: calendar, in: language)), \(hour)" : hour
    }

    private static func line(_ format: String, _ event: CalendarEvent, dated: Bool, time: (Date) -> String, calendar: Calendar, in language: AppLanguage) -> String {
        Localization.format(format, when(event, dated: dated, time: time, calendar: calendar, in: language), eventTitle(event, in: language), in: language)
    }

    /// Under the Day's "На сегодня всё": "Ближайшее — завтра, 10:00 · Стендап";
    /// "Ближайшее — пн, 12 октября, 10:00 · Стендап"; "Впереди пусто".
    public static func dayHint(_ next: CalendarNext, time: (Date) -> String, calendar: Calendar = .current, in language: AppLanguage = Localization.current) -> String {
        switch next {
        case .tomorrow(let event): Localization.format("Next — %@ · %@", Localization.format("tomorrow, %@", when(event, dated: false, time: time, calendar: calendar, in: language), in: language), eventTitle(event, in: language), in: language)
        case .later(let event): line("Next — %@ · %@", event, dated: true, time: time, calendar: calendar, in: language)
        case .nothing: Localization.text("Nothing ahead", in: language)
        }
    }

    /// Under the Week's "Неделя свободна": "Ближайшее — пн,
    /// 12 октября, 10:00 · Стендап", or "Впереди пусто".
    public static func weekHint(_ next: CalendarEvent?, time: (Date) -> String, calendar: Calendar = .current, in language: AppLanguage = Localization.current) -> String {
        guard let next else { return Localization.text("Nothing ahead", in: language) }
        return line("Next — %@ · %@", next, dated: true, time: time, calendar: calendar, in: language)
    }

    /// Under a free day chosen in the Month: "Ближайшее — вт, 10 марта, 10:00 ·
    /// Стендап", or "Впереди пусто".
    public static func freeDayHint(_ next: CalendarEvent?, time: (Date) -> String, calendar: Calendar = .current, in language: AppLanguage = Localization.current) -> String {
        guard let next else { return Localization.text("Nothing ahead", in: language) }
        return line("Next — %@ · %@", next, dated: true, time: time, calendar: calendar, in: language)
    }

    /// The Month's heading: "Октябрь" and, beside it, "2026".
    public static func month(_ month: CalendarMonth, in language: AppLanguage = Localization.current) -> (name: String, year: String) {
        (CalendarNames.monthNominative(month.month, in: language), String(month.year))
    }
}

/// Weekday and month names. Explicit, like the rest of `Localization`, so
/// Russian has its two forms of a month — "Октябрь" over the grid,
/// "4 октября" in a date — whatever the Mac's own locale says.
public enum CalendarNames {
    private static let russianWeekdaysShort = ["пн", "вт", "ср", "чт", "пт", "сб", "вс"]
    private static let englishWeekdaysShort = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    private static let russianWeekdays = ["понедельник", "вторник", "среда", "четверг", "пятница", "суббота", "воскресенье"]
    private static let englishWeekdays = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
    private static let russianMonths = ["Январь", "Февраль", "Март", "Апрель", "Май", "Июнь", "Июль", "Август", "Сентябрь", "Октябрь", "Ноябрь", "Декабрь"]
    private static let russianMonthsGenitive = ["января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа", "сентября", "октября", "ноября", "декабря"]
    private static let russianMonthsShort = ["янв.", "февр.", "мар.", "апр.", "мая", "июн.", "июл.", "авг.", "сент.", "окт.", "нояб.", "дек."]
    private static let englishMonths = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
    private static let englishMonthsShort = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    private static func pick(_ list: [String], _ index: Int) -> String {
        list[min(max(index, 0), list.count - 1)]
    }

    private static func isRussian(_ language: AppLanguage) -> Bool { language.resolved() == .russian }

    /// Monday 0 … Sunday 6: "пн", "Mon".
    public static func weekdayShort(_ index: Int, in language: AppLanguage = Localization.current) -> String {
        pick(isRussian(language) ? russianWeekdaysShort : englishWeekdaysShort, index)
    }

    public static func weekdayWide(_ index: Int, in language: AppLanguage = Localization.current) -> String {
        pick(isRussian(language) ? russianWeekdays : englishWeekdays, index)
    }

    /// 1 … 12, as a heading: "Октябрь", "October".
    public static func monthNominative(_ month: Int, in language: AppLanguage = Localization.current) -> String {
        pick(isRussian(language) ? russianMonths : englishMonths, month - 1)
    }

    /// 1 … 12, in a date: "октября", "October".
    public static func monthGenitive(_ month: Int, in language: AppLanguage = Localization.current) -> String {
        pick(isRussian(language) ? russianMonthsGenitive : englishMonths, month - 1)
    }

    public static func monthShort(_ month: Int, in language: AppLanguage = Localization.current) -> String {
        pick(isRussian(language) ? russianMonthsShort : englishMonthsShort, month - 1)
    }
}

public extension Localization {
    /// "14 встреч", "1 встреча", "3 встречи"; "14 events".
    static func eventCount(_ count: Int, in language: AppLanguage = current) -> String {
        switch language.resolved() {
        case .russian:
            let tens = count % 100, ones = count % 10
            let word = (11...14).contains(tens) ? "встреч" : ones == 1 ? "встреча" : (2...4).contains(ones) ? "встречи" : "встреч"
            return "\(count) \(word)"
        case .english, .system:
            return count == 1 ? "1 event" : "\(count) events"
        }
    }
}
