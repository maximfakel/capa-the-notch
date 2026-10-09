import CapacityNotchCore
import Foundation

/// The Week and the Month of the Calendar page (the author's mockups and
/// decisions, 2026-10-07), checked in Moscow so midnight is where the checks
/// expect it.
private let moscow: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
    // A Sunday-first calendar, as an American Mac has: the Month is Monday
    // first whatever the Mac says.
    calendar.firstWeekday = 1
    return calendar
}()

private func on(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    moscow.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

private func timed(_ id: String, _ start: Date, minutes: Double = 30, colour: CalendarColour? = nil, holiday: Bool = false) -> CalendarEvent {
    CalendarEvent(id: id, title: "Title \(id)", start: start, end: start.addingTimeInterval(minutes * 60), colour: colour, isHoliday: holiday)
}

private func allDay(_ id: String, _ day: Date, days: Int = 1, holiday: Bool = false, colour: CalendarColour? = nil) -> CalendarEvent {
    CalendarEvent(id: id, title: "Title \(id)", start: day, end: day.addingTimeInterval(Double(days) * 86_400), isAllDay: true, colour: colour, isHoliday: holiday)
}

private let blue = CalendarColour(red: 0, green: 0.5, blue: 1)
private let orange = CalendarColour(red: 1, green: 0.6, blue: 0)
private let purple = CalendarColour(red: 0.7, green: 0.3, blue: 0.9)
private let green = CalendarColour(red: 0.2, green: 0.8, blue: 0.3)

// MARK: - The Week

func theWeekIsSevenDaysStartingToday() throws {
    // Sunday 4 October 2026, at 17:49, as drawn.
    let now = on(2026, 10, 4, 17, 49)
    let over = timed("over", on(2026, 10, 4, 9))
    let coming = timed("coming", on(2026, 10, 4, 17, 57))
    let marathon = allDay("marathon", on(2026, 10, 4))
    let monday = timed("monday", on(2026, 10, 5, 10))
    let trip = allDay("trip", on(2026, 10, 6), days: 3)
    let saturday = timed("saturday", on(2026, 10, 10, 23))
    let nextSunday = timed("next-sunday", on(2026, 10, 11, 10))
    let declined = CalendarEvent(id: "declined", title: "x", start: on(2026, 10, 5, 12), end: on(2026, 10, 5, 13), isDeclined: true)
    let week = CalendarWeek(events: [nextSunday, saturday, trip, monday, marathon, coming, over, declined], at: now, calendar: moscow)

    try expect(week.days.count == 7, "Seven days")
    try expect(week.days.map(\.number) == [4, 5, 6, 7, 8, 9, 10], "From today, not from Monday: \(week.days.map(\.number))")
    try expect(week.interval == DateInterval(start: on(2026, 10, 4), end: on(2026, 10, 11)), "Today's midnight to a week on")
    try expect(week.days.map(\.isToday) == [true, false, false, false, false, false, false], "Only the first is today")
    try expect(week.days.map(\.isRed) == [true, false, false, false, false, false, true], "Sunday and Saturday are red")
    try expect(week.days.allSatisfy { $0.tone != .otherMonth }, "Nothing in the week is past or another month's")

    try expect(week.days[0].events.map(\.id) == ["marathon", "coming"], "Today: all-day first, and nothing already over: \(week.days[0].events.map(\.id))")
    try expect(week.days[1].events.map(\.id) == ["monday"], "Monday, without the declined: \(week.days[1].events.map(\.id))")
    try expect(week.days[2...4].allSatisfy { $0.events.map(\.id) == ["trip"] }, "A three-day event is on each of its days")
    try expect(week.days[5].events.isEmpty, "A day with nothing is free")
    try expect(week.days[6].events.map(\.id) == ["saturday"], "Saturday's late event")
    try expect(week.eventCount == 5, "Each event counted once, however many days: \(week.eventCount)")
}

func theWeeksChipsAreTwoAtMostAndTheRestAreCounted() throws {
    let day = on(2026, 10, 5)
    let events = (0..<5).map { timed("e\($0)", day.addingTimeInterval(Double(9 + $0) * 3600)) }
    try expect(CalendarChips.maximum == 2, "Two chips a day, as the author drew it on 2026-10-08")
    try expect(CalendarChips.fit([]) == .init(shown: [], more: 0), "Nothing: nothing to count")
    try expect(CalendarChips.fit(Array(events.prefix(1))) == .init(shown: Array(events.prefix(1)), more: 0), "One: one chip")
    try expect(CalendarChips.fit(Array(events.prefix(2))) == .init(shown: Array(events.prefix(2)), more: 0), "Two: both, and no \"ещё\"")
    let three = CalendarChips.fit(Array(events.prefix(3)))
    try expect(three.shown.map(\.id) == ["e0", "e1"] && three.more == 1, "Three: two, and \"ещё 1\", as Wednesday the 7th is drawn")
    let five = CalendarChips.fit(events)
    try expect(five.shown.map(\.id) == ["e0", "e1"] && five.more == 3, "Five: the first two, and \"ещё 3\"")

    // Two chips and "ещё N" keep inside the view under the date.
    let column = 24 + CalendarChips.spacing + 2 * 29 + CalendarChips.spacing + CalendarChips.spacing + 14
    try expect(column <= CalendarPageLayout.content, "Two chips and \"ещё N\" fit the 112: \(column)")

    // In the Week itself: today keeps what is not over, two of it shown.
    let now = on(2026, 10, 7, 9)
    let wednesday = [timed("stand-up", on(2026, 10, 7, 10)), timed("lunch", on(2026, 10, 7, 12, 30)), timed("demo", on(2026, 10, 7, 16))]
    let week = CalendarWeek(events: wednesday, at: now, calendar: moscow)
    let fit = CalendarChips.fit(week.days[0].events)
    try expect(fit.shown.map(\.id) == ["stand-up", "lunch"] && fit.more == 1, "Стендап, Обед с Олей, ещё 1")
    try expect(!week.isFree && week.days[1].events.isEmpty, "A week with something is not free; its empty days are")
}

func aWeekWithNothingSaysWhenTheNextEventIs() throws {
    // Sunday 4 October 2026, as "… week with nothing" draws it.
    let now = on(2026, 10, 4, 17, 49)
    let over = timed("over", on(2026, 10, 4, 9))
    let holiday = allDay("unity-day", on(2026, 11, 4), holiday: true)
    let declined = CalendarEvent(id: "declined", title: "x", start: on(2026, 10, 11, 9), end: on(2026, 10, 11, 10), isDeclined: true)
    let vacation = allDay("vacation", on(2026, 10, 12))
    let standUp = CalendarEvent(id: "stand-up", title: "Стендап", start: on(2026, 10, 12, 10), end: on(2026, 10, 12, 10, 15))
    let later = timed("later", on(2026, 10, 13, 10))
    let week = CalendarWeek(events: [later, standUp, vacation, declined, holiday, over], at: now, calendar: moscow)

    try expect(week.isFree, "Nothing on any of the seven days: one box across the week")
    try expect(week.eventCount == 0, "No events counted")
    try expect(CalendarTitles.weekCount(week, in: .russian) == "нет встреч", "\(CalendarTitles.weekCount(week, in: .russian))")
    try expect(CalendarTitles.weekCount(week, in: .english) == "no events", "\(CalendarTitles.weekCount(week, in: .english))")
    try expect(week.days.count == 7 && week.days[0].isToday && week.days[6].isRed, "The row of seven dates stays, today and weekends marked")
    try expect(week.next?.id == "stand-up", "The next event after the week: Monday's first timed, past the declined: \(week.next?.id ?? "none")")

    let time = { (date: Date) in hhmm(date) }
    try expect(CalendarTitles.weekHint(week.next, time: time, calendar: moscow, in: .russian) == "Ближайшее — пн, 12 октября, 10:00 · Стендап",
               CalendarTitles.weekHint(week.next, time: time, calendar: moscow, in: .russian))
    try expect(CalendarTitles.weekHint(week.next, time: time, calendar: moscow, in: .english) == "Next — Mon, October 12, 10:00 · Стендап",
               CalendarTitles.weekHint(week.next, time: time, calendar: moscow, in: .english))

    let onlyHoliday = CalendarWeek(events: [holiday], at: now, calendar: moscow)
    try expect(onlyHoliday.isFree && onlyHoliday.next == nil, "A holiday calendar's day is no event to go to")
    try expect(CalendarTitles.weekHint(onlyHoliday.next, time: time, calendar: moscow, in: .russian) == "Впереди пусто", "Nothing read ahead")
    try expect(CalendarTitles.weekHint(nil, time: time, calendar: moscow, in: .english) == "Nothing ahead", "In English")

    let allDayOnly = CalendarWeek(events: [vacation], at: now, calendar: moscow)
    try expect(CalendarTitles.weekHint(allDayOnly.next, time: time, calendar: moscow, in: .russian) == "Ближайшее — пн, 12 октября, весь день · Title vacation",
               "An all-day one says so: \(CalendarTitles.weekHint(allDayOnly.next, time: time, calendar: moscow, in: .russian))")
}

/// The Mac's clock stands in as 24 hours in the checks.
private func hhmm(_ date: Date) -> String {
    let parts = moscow.dateComponents([.hour, .minute], from: date)
    return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
}

// MARK: - Kapa in free time

func kapaWearsSunglassesOnlyInAnEmptyDayOrWeek() throws {
    // The author's decision of 2026-10-08 (ADR 0006): Kapa stands on the
    // Calendar page only in free time, in sunglasses.
    let now = on(2026, 10, 4, 17, 49)
    let coming = timed("coming", on(2026, 10, 4, 18))
    let over = timed("over", on(2026, 10, 4, 9))
    let nextWeek = timed("next-week", on(2026, 10, 12, 10))

    try expect(KapaMood.calendar(CalendarDay(events: [over, nextWeek], at: now, calendar: moscow)) == .free, "Nothing left today: free time")
    try expect(KapaMood.calendar(CalendarDay(events: [coming], at: now, calendar: moscow)) == nil, "Something left today: no Kapa on the Day")
    try expect(KapaMood.calendar(CalendarDay(events: [allDay("marathon", on(2026, 10, 4))], at: now, calendar: moscow)) == nil,
               "An all-day event left: the Day is not empty")
    try expect(KapaMood.calendar(CalendarWeek(events: [nextWeek], at: now, calendar: moscow)) == .free, "Nothing this week: free time")
    try expect(KapaMood.calendar(CalendarWeek(events: [coming], at: now, calendar: moscow)) == nil, "A week with a meeting: no Kapa")

    let face = KapaFace.of(.free)
    try expect(face.sunglasses && face.badge == .none, "Sunglasses, and no sign beside them")
    try expect(face.mouth == .wide, "The wider smile")
    try expect(!KapaBlink.blinks(face), "Behind the lenses nothing blinks")
    try expect(KapaBlink.blinks(KapaFace.of(.rest)), "A face without them still does")
    try expect(KapaExpression.allCases.filter { KapaFace.of($0).sunglasses } == [.free], "Only free time wears them")
}

// MARK: - The Day with nothing left

func aDayWithNothingLeftSaysWhatComesNext() throws {
    let now = on(2026, 10, 4, 17, 49)
    let over = timed("over", on(2026, 10, 4, 9))
    let tomorrowAllDay = allDay("marathon", on(2026, 10, 5))
    let tomorrowStandUp = CalendarEvent(id: "stand-up", title: "Стендап", start: on(2026, 10, 5, 10), end: on(2026, 10, 5, 10, 15))
    let tomorrowLunch = timed("lunch", on(2026, 10, 5, 13))
    let monday = CalendarEvent(id: "monday", title: "Стендап", start: on(2026, 10, 12, 10), end: on(2026, 10, 12, 10, 15))
    let holiday = allDay("holiday", on(2026, 10, 5), holiday: true)
    let time = { (date: Date) in hhmm(date) }

    let withTomorrow = [over, tomorrowLunch, tomorrowStandUp, tomorrowAllDay, monday]
    try expect(CalendarDay(events: withTomorrow, at: now, calendar: moscow).isEmpty, "Nothing left today")
    let next = CalendarDay.next(in: withTomorrow, at: now, calendar: moscow)
    try expect(next == .tomorrow(tomorrowStandUp), "Tomorrow's first timed event, before its all-day one: \(next)")
    try expect(CalendarTitles.dayHint(next, time: time, calendar: moscow, in: .russian) == "Ближайшее — завтра, 10:00 · Стендап",
               CalendarTitles.dayHint(next, time: time, calendar: moscow, in: .russian))
    try expect(CalendarTitles.dayHint(next, time: time, calendar: moscow, in: .english) == "Next — tomorrow, 10:00 · Стендап",
               CalendarTitles.dayHint(next, time: time, calendar: moscow, in: .english))
    try expect(CalendarDay.next(in: [tomorrowAllDay], at: now, calendar: moscow) == .tomorrow(tomorrowAllDay), "Or tomorrow's all-day one")
    try expect(CalendarTitles.dayHint(.tomorrow(tomorrowAllDay), time: time, calendar: moscow, in: .russian) == "Ближайшее — завтра, весь день · Title marathon",
               "All day, said so")

    let later = CalendarDay.next(in: [over, holiday, monday], at: now, calendar: moscow)
    try expect(later == .later(monday), "Nothing tomorrow but a holiday: the next one read, later: \(later)")
    try expect(CalendarTitles.dayHint(later, time: time, calendar: moscow, in: .russian) == "Ближайшее — пн, 12 октября, 10:00 · Стендап",
               CalendarTitles.dayHint(later, time: time, calendar: moscow, in: .russian))
    try expect(CalendarTitles.dayHint(later, time: time, calendar: moscow, in: .english) == "Next — Mon, October 12, 10:00 · Стендап",
               CalendarTitles.dayHint(later, time: time, calendar: moscow, in: .english))

    let none = CalendarDay.next(in: [over], at: now, calendar: moscow)
    try expect(none == .nothing, "Nothing ahead in what is read")
    try expect(CalendarTitles.dayHint(none, time: time, calendar: moscow, in: .russian) == "Впереди пусто", "Впереди пусто")
    try expect(CalendarTitles.dayHint(none, time: time, calendar: moscow, in: .english) == "Nothing ahead", "Nothing ahead")

    let untitled = CalendarEvent(id: "untitled", title: "  ", start: on(2026, 10, 5, 9), end: on(2026, 10, 5, 10))
    try expect(CalendarTitles.dayHint(.tomorrow(untitled), time: time, calendar: moscow, in: .russian) == "Ближайшее — завтра, 09:00 · Без названия",
               "An untitled event says so")
}

// MARK: - The Month

func octoberIsFiveWeeksFromTheTwentyEighthOfSeptember() throws {
    let now = on(2026, 10, 4, 17, 49)
    let month = CalendarMonth(events: [], at: now, calendar: moscow)
    try expect(month.year == 2026 && month.month == 10, "October 2026")
    try expect(month.weeks.count == 5 && month.weeks.allSatisfy { $0.count == 7 }, "Five rows of seven: \(month.weeks.map(\.count))")
    try expect(month.interval == DateInterval(start: on(2026, 9, 28), end: on(2026, 11, 2)), "28 September to 1 November: \(month.interval)")
    let days = month.days
    try expect(days.first?.number == 28 && days.last?.number == 1, "From the 28th to the 1st")
    try expect(days.allSatisfy { $0.weekdayIndex == days.firstIndex(of: $0)! % 7 }, "Monday first, though this Mac's week starts on Sunday")
    try expect(days.prefix(3).allSatisfy { $0.tone == .otherMonth } && days.last?.tone == .otherMonth, "September's and November's days are the neighbours'")
    try expect(days[3].number == 1 && days[3].tone == .current && days[3].isPast, "1 October is past, and drawn at full strength")
    try expect(days[5].number == 3 && days[5].tone == .current && days[5].isRed, "Saturday the 3rd: past, red, at full strength")
    try expect(days[6].number == 4 && days[6].tone == .today, "Sunday the 4th is today")
    try expect(days[7].tone == .current, "Monday the 5th is still to come")
    try expect(days.filter(\.isWeekend).map(\.number) == [3, 4, 10, 11, 17, 18, 24, 25, 31, 1], "Weekends: \(days.filter(\.isWeekend).map(\.number))")
}

func marchTwentyTwentySixIsSixWeeks() throws {
    let now = on(2026, 3, 4, 15)
    let month = CalendarMonth(events: [], at: now, calendar: moscow)
    try expect(month.weeks.count == 6, "Six rows, so every row keeps its height and the grid still fits: \(month.weeks.count)")
    try expect(month.interval == DateInterval(start: on(2026, 2, 23), end: on(2026, 4, 6)), "23 February to 5 April: \(month.interval)")
    let days = month.days
    try expect(days.count == 42, "Forty-two days")
    try expect(days.first?.number == 23 && days.last?.number == 5, "From the 23rd to the 5th")
    try expect(days[6].number == 1 && days[6].isInMonth && days[6].tone == .current && days[6].isRed, "Sunday 1 March: this month's, past, red, at full strength")
    try expect(days[9].tone == .today, "Wednesday the 4th is today")
    try expect(days.suffix(5).allSatisfy { $0.tone == .otherMonth }, "April's five are the neighbours'")
}

func everyMonthsGridFillsTheView() throws {
    try expect(CalendarPageLayout.height == Double(NotchGeometry.pageHeight),
               "10 + 18 + 8 + 112 + 4 is the page every Module has: \(CalendarPageLayout.height)")
    let october = CalendarMonth(events: [], at: on(2026, 10, 4, 17, 49), calendar: moscow)
    let march = CalendarMonth(events: [], at: on(2026, 3, 4, 15), calendar: moscow)
    try expect(october.weeks.count == 5 && march.weeks.count == 6, "October five weeks, March six")

    // Five weeks: weekdays 12, rows 20 — a 16 frame at 11, a point, the dots.
    let five = october.metrics
    try expect(five.weekdayHeight == 12 && five.rowHeight == 20, "October: 12 and rows of 20: \(five)")
    try expect(five.numberFrame == 16 && five.numberSize == 11 && five.numberTracking == 0 && five.dotGap == 1, "A 16 frame at 11, a point above the dots: \(five)")
    try expect(five.numberFrame + five.dotGap + CalendarMonthMetrics.dotSize == five.rowHeight, "Frame, gap and dots make the row")
    try expect(five.gridHeight(weeks: 5) == CalendarPageLayout.content, "12 + 5 × 20 = 112: \(five.gridHeight(weeks: 5))")
    try expect(five.rowTops(weeks: 5) == [12, 32, 52, 72, 92], "\(five.rowTops(weeks: 5))")

    // Six weeks: weekdays 10, rows 17 — a 14 frame at 10.5, tighter, the dots straight under.
    let six = march.metrics
    try expect(six.weekdayHeight == 10 && six.rowHeight == 17, "March: 10 and rows of 17: \(six)")
    try expect(six.numberFrame == 14 && six.numberSize == 10.5 && six.numberTracking == -0.02 && six.dotGap == 0, "A 14 frame at 10.5, no gap: \(six)")
    try expect(six.gridHeight(weeks: 6) == CalendarPageLayout.content, "10 + 6 × 17 = 112: \(six.gridHeight(weeks: 6))")

    // A four-week February (2027 starts on a Monday) keeps rows of 20 and leaves room below.
    let february = CalendarMonth(events: [], at: on(2027, 2, 10), calendar: moscow)
    try expect(february.weeks.count == 4 && february.metrics.rowHeight == 20, "Rows never grow past 20: \(february.metrics)")
    try expect(february.metrics.gridHeight(weeks: 4) <= CalendarPageLayout.content, "And fit")

    // Today and the chosen day are circles the size of the frame; two digits grow a 14 to 16.
    try expect(five.circle(for: 4) == 16 && five.circle(for: 28) == 16, "Five weeks: 16 either way")
    try expect(six.circle(for: 4) == 14, "Six weeks: a single digit in 14")
    try expect(six.circle(for: 17) == 16, "Two digits do not fit 14: the circle grows to 16 rather than stretching")
}

func aFreeDayChosenInTheMonthSaysWhatComesAfterIt() throws {
    // Wednesday 4 March 2026, 7 March chosen, as "… month of six weeks" draws it.
    let now = on(2026, 3, 4, 15)
    let womensDay = allDay("8-mar", on(2026, 3, 8), holiday: true)
    let transferred = allDay("9-mar", on(2026, 3, 9), holiday: true)
    let friday = timed("friday", on(2026, 3, 6, 10))
    let standUp = CalendarEvent(id: "stand-up", title: "Стендап", start: on(2026, 3, 10, 10), end: on(2026, 3, 10, 10, 15))
    let events = [standUp, transferred, womensDay, friday]
    let month = CalendarMonth(events: events, at: now, calendar: moscow)
    let time = { (date: Date) in hhmm(date) }

    let seventh = month.selected(on(2026, 3, 7))!
    try expect(seventh.number == 7 && seventh.events.isEmpty && !seventh.isToday, "Saturday the 7th, chosen, has nothing on it")
    try expect(seventh.isRed, "A weekend: its date is red")
    try expect(CalendarTitles.dayDate(seventh.start, calendar: moscow, in: .russian) == "сб, 7 марта", "Its date")
    let next = CalendarAhead.after(seventh, in: events, at: now, calendar: moscow)
    try expect(next?.id == "stand-up", "Past the holidays of the 8th and 9th, the next is Tuesday's stand-up: \(next?.id ?? "none")")
    try expect(CalendarTitles.freeDayHint(next, time: time, calendar: moscow, in: .russian) == "Ближайшее — вт, 10 марта, 10:00 · Стендап",
               CalendarTitles.freeDayHint(next, time: time, calendar: moscow, in: .russian))
    try expect(CalendarTitles.freeDayHint(next, time: time, calendar: moscow, in: .english) == "Next — Tue, March 10, 10:00 · Стендап",
               CalendarTitles.freeDayHint(next, time: time, calendar: moscow, in: .english))
    try expect(Localization.text("A free day", in: .russian) == "Свободный день", "Свободный день")

    let fifth = month.selected(on(2026, 3, 5))!
    try expect(CalendarAhead.after(fifth, in: events, at: now, calendar: moscow)?.id == "friday", "After Thursday the 5th, Friday's")
    let today = month.selected(nil)!
    try expect(today.isToday && CalendarAhead.after(today, in: events, at: now, calendar: moscow)?.id == "friday", "After today, from now")

    let lastFree = month.selected(on(2026, 3, 11))!
    let nothing = CalendarAhead.after(lastFree, in: events, at: now, calendar: moscow)
    try expect(nothing == nil, "Nothing read after the 11th")
    try expect(CalendarTitles.freeDayHint(nothing, time: time, calendar: moscow, in: .russian) == "Впереди пусто", "Впереди пусто")
}

@MainActor
func aDayInTheMonthCanBeChosenAndTodayIsTheDefault() throws {
    let now = on(2026, 10, 4, 17, 49)
    let earlier = timed("earlier", on(2026, 10, 4, 9))
    let later = timed("later", on(2026, 10, 4, 19))
    let ninth = timed("ninth", on(2026, 10, 9, 10))
    let month = CalendarMonth(events: [earlier, later, ninth], at: now, calendar: moscow)
    try expect(month.selected(nil)?.number == 4, "Nothing chosen: today")
    try expect(month.selected(nil)?.events.map(\.id) == ["later"], "Today's list keeps what is not over, as the Day does")
    try expect(month.selected(on(2026, 10, 9))?.events.map(\.id) == ["ninth"], "The 9th chosen: its events")
    try expect(month.selected(on(2026, 10, 9, 13))?.number == 9, "Any moment of the day finds it")
    try expect(month.selected(on(2026, 9, 29))?.number == 29, "A neighbour's day in the grid can be chosen")
    try expect(month.selected(on(2026, 12, 1))?.number == 4, "A day the grid no longer holds falls back to today")
    let past = CalendarMonth(events: [timed("second", on(2026, 10, 2, 9))], at: now, calendar: moscow)
    try expect(past.day(containing: on(2026, 10, 2))?.events.map(\.id) == ["second"], "A past day lists everything it had")

    let source = StandInMonthCalendar(events: [ninth])
    let reader = CalendarReader(source: source, enabled: true, calendar: moscow, clock: { now })
    reader.resume()
    reader.selectDay(on(2026, 10, 9, 15))
    try expect(reader.selectedDay == on(2026, 10, 9), "A click chooses the day, as its midnight")
    try expect(reader.month(at: now).selected?.events.map(\.id) == ["ninth"], "And the list shows it")
    reader.selectDay(on(2026, 10, 4, 8))
    try expect(reader.selectedDay == nil, "Choosing today is the default again")
}

// MARK: - Weekends and holidays

func weekendsAndHolidaysAreRed() throws {
    let now = on(2026, 3, 4, 15)
    let defender = allDay("23-feb", on(2026, 2, 23), holiday: true)
    let transferred = allDay("9-mar", on(2026, 3, 9), holiday: true)
    let observance = timed("timed-in-holidays", on(2026, 3, 12, 10), holiday: true)
    let personal = allDay("own-all-day", on(2026, 3, 13))
    let month = CalendarMonth(events: [defender, transferred, observance, personal], at: now, calendar: moscow)
    let day = { (n: Int, inMonth: Bool) in month.days.first { $0.number == n && $0.isInMonth == inMonth }! }

    try expect(day(9, true).isHoliday && day(9, true).isRed && !day(9, true).isWeekend, "Monday 9 March, a holiday: red")
    try expect(day(23, false).isHoliday && day(23, false).isRed && day(23, false).tone == .otherMonth, "23 February: red, at the neighbours' strength")
    try expect(!day(12, true).isHoliday, "A timed event in a holiday calendar marks no holiday")
    try expect(!day(13, true).isHoliday, "An all-day event of the person's own marks none")
    try expect(day(7, true).isRed && day(8, true).isRed, "Saturday and Sunday are red")
    try expect(day(10, true).isRed == false, "A weekday is not")

    let none = CalendarMonth(events: [], at: now, calendar: moscow)
    try expect(none.days.filter(\.isRed) == none.days.filter(\.isWeekend), "Without a holiday calendar, only weekends are red")

    let week = CalendarWeek(events: [transferred], at: on(2026, 3, 8, 12), calendar: moscow)
    try expect(week.days[1].isHoliday && week.days[1].isRed, "The Week marks it too")

    try expect(HolidayCalendar.recognises(title: "Праздники России", isSubscribed: true, isReadOnly: true), "macOS's Russian holidays")
    try expect(HolidayCalendar.recognises(title: "Russian Holidays", isSubscribed: true, isReadOnly: true), "In English")
    try expect(HolidayCalendar.recognises(title: "Holidays in Russia", isSubscribed: false, isReadOnly: true), "Google's, read-only")
    try expect(!HolidayCalendar.recognises(title: "Holidays", isSubscribed: false, isReadOnly: false), "A person's own \"Holidays\" is time off, not a holiday calendar")
    try expect(!HolidayCalendar.recognises(title: "Birthdays", isSubscribed: true, isReadOnly: true), "A subscribed calendar of something else")
}

func theMonthsDotsAreItsCalendarsColoursThreeAtMost() throws {
    let now = on(2026, 10, 4, 9)
    let day = on(2026, 10, 7)
    let events = [
        timed("a", day.addingTimeInterval(9 * 3600), colour: blue),
        timed("b", day.addingTimeInterval(10 * 3600), colour: blue),
        timed("c", day.addingTimeInterval(11 * 3600), colour: orange),
        timed("d", day.addingTimeInterval(12 * 3600), colour: purple),
        timed("e", day.addingTimeInterval(13 * 3600), colour: green),
    ]
    let seventh = CalendarMonth(events: events, at: now, calendar: moscow).day(containing: day)!
    try expect(seventh.dots == [blue, orange, purple], "Each calendar once, in order, three at most: \(seventh.dots)")

    let red = CalendarColour(red: 1, green: 0.27, blue: 0.22)
    let eighth = on(2026, 10, 8)
    let holiday = allDay("holiday", eighth, holiday: true, colour: red)
    let withHoliday = CalendarMonth(events: [holiday, timed("f", eighth.addingTimeInterval(9 * 3600), colour: blue)], at: now, calendar: moscow)
    try expect(withHoliday.day(containing: eighth)!.dots == [blue], "A holiday calendar's day leaves no dot; its red number says it")
}

// MARK: - The tab

@MainActor
private final class StandInMonthCalendar: CalendarSource {
    let stored: [CalendarEvent]
    private(set) var intervals: [DateInterval] = []
    init(events: [CalendarEvent]) { stored = events }
    func access() -> CalendarAccess { .granted }
    func requestAccess() async -> CalendarAccess { .granted }
    func events(in interval: DateInterval) -> [CalendarEvent] {
        intervals.append(interval)
        return stored.filter { $0.start < interval.end && $0.end > interval.start }
    }
}

@MainActor
func thePageOpensOnTheTabLastUsed() async throws {
    let suite = "calendar-tab-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = Preferences(defaults: defaults)
    try expect(preferences.calendarTab == .day, "Before any is chosen, the Day")
    try expect(CalendarTab.allCases == [.day, .week, .month], "День · Неделя · Месяц, in that order")

    let source = StandInMonthCalendar(events: [])
    let reader = CalendarReader(source: source, enabled: true, calendar: moscow, tab: preferences.calendarTab,
                                rememberTab: { preferences.calendarTab = $0 }, clock: { on(2026, 10, 4, 12) })
    try expect(reader.tab == .day, "It opens on the Day")
    reader.select(.month)
    try expect(reader.tab == .month, "A tab clicked is shown")
    try expect(Preferences(defaults: defaults).calendarTab == .month, "And remembered across launches")

    let next = CalendarReader(source: source, enabled: true, calendar: moscow, tab: Preferences(defaults: defaults).calendarTab)
    try expect(next.tab == .month, "The next launch opens on it")
    defaults.set("fortnight", forKey: "calendarTab")
    try expect(Preferences(defaults: defaults).calendarTab == .day, "Something unreadable is the Day")
}

// MARK: - Reading

@MainActor
func theWeekAndTheMonthWidenWhatIsReadAndNothingElse() async throws {
    // 30 October: the week runs past the grid's end; the grid starts before the week.
    let now = on(2026, 10, 30, 12)
    let read = CalendarReading.interval(containing: now, calendar: moscow)
    try expect(read.start == on(2026, 9, 28), "From the grid's first Monday: \(read.start)")
    try expect(CalendarReading.daysAhead >= 30, "At least thirty days past today")
    try expect(read.end == on(2026, 11, 30), "To thirty days past today, past the week and the grid: \(read.end)")

    let late = CalendarReading.interval(containing: on(2026, 10, 4, 23, 58), calendar: moscow)
    try expect(late.contains(on(2026, 10, 5, 0, 5)), "Still past midnight as far as the row reaches")
    try expect(late.end == on(2026, 11, 4), "Thirty days past the 4th of October, past the grid's 1 November: \(late.end)")
    let march = CalendarReading.interval(containing: on(2026, 3, 4, 15), calendar: moscow)
    try expect(march == DateInterval(start: on(2026, 2, 23), end: on(2026, 4, 6)), "March: the six weeks of its grid, which already reach past thirty days")
    let lastOfMarch = CalendarReading.interval(containing: on(2026, 3, 31, 12), calendar: moscow)
    try expect(lastOfMarch.end == on(2026, 5, 1), "From the 31st of March, to the 30th of April: \(lastOfMarch.end)")

    let source = StandInMonthCalendar(events: [timed("in-a-week", on(2026, 11, 5, 10)), timed("in-a-month", on(2026, 11, 29, 10)), timed("too-far", on(2026, 11, 30, 10))])
    let reader = CalendarReader(source: source, enabled: false, calendar: moscow, clock: { now })
    reader.reload()
    try expect(source.intervals.isEmpty, "Off, nothing is read, however wide")
    await reader.setEnabled(true)
    try expect(source.intervals.last == read, "On and allowed, the whole interval is read")
    try expect(reader.events.map(\.id) == ["in-a-week", "in-a-month"], "And what is in it is kept, up to thirty days on: \(reader.events.map(\.id))")
    try expect(reader.week(at: now).days.last?.events.map(\.id) == ["in-a-week"], "Thursday 5 November closes the Week")
    try expect(CalendarModule.observation(enabled: true, access: .granted, eventsToday: reader.day(at: now).eventCount) == "calendar-on-0-events",
               "Diagnostics still count today, and only count")
}

// MARK: - Words

func theCalendarsHeadingsSpeakBothLanguages() throws {
    let sunday = on(2026, 10, 4, 17, 49)
    try expect(CalendarTitles.dayDate(sunday, calendar: moscow, in: .russian) == "вс, 4 октября", "\(CalendarTitles.dayDate(sunday, calendar: moscow, in: .russian))")
    try expect(CalendarTitles.dayDate(sunday, calendar: moscow, in: .english) == "Sun, October 4", "\(CalendarTitles.dayDate(sunday, calendar: moscow, in: .english))")

    // The compact range the author wrote on 2026-10-08: day-day.month.
    let week = CalendarWeek.interval(containing: sunday, calendar: moscow)
    try expect(CalendarTitles.weekRange(week, calendar: moscow, in: .russian) == "4-10.10", "\(CalendarTitles.weekRange(week, calendar: moscow, in: .russian))")
    try expect(CalendarTitles.weekRange(week, calendar: moscow, in: .english) == "Oct 4–10", "\(CalendarTitles.weekRange(week, calendar: moscow, in: .english))")
    let across = CalendarWeek.interval(containing: on(2026, 9, 28), calendar: moscow)
    try expect(CalendarTitles.weekRange(across, calendar: moscow, in: .russian) == "28.09-4.10", "\(CalendarTitles.weekRange(across, calendar: moscow, in: .russian))")
    try expect(CalendarTitles.weekRange(across, calendar: moscow, in: .english) == "Sep 28–Oct 4", "\(CalendarTitles.weekRange(across, calendar: moscow, in: .english))")
    let newYear = CalendarWeek.interval(containing: on(2026, 12, 29), calendar: moscow)
    try expect(CalendarTitles.weekRange(newYear, calendar: moscow, in: .russian) == "29.12-4.01", "Across a year: \(CalendarTitles.weekRange(newYear, calendar: moscow, in: .russian))")
    let march = CalendarWeek.interval(containing: on(2026, 3, 2), calendar: moscow)
    try expect(CalendarTitles.weekRange(march, calendar: moscow, in: .russian) == "2-8.03", "A month below ten keeps its nought: \(CalendarTitles.weekRange(march, calendar: moscow, in: .russian))")

    let october = CalendarMonth(events: [], at: sunday, calendar: moscow)
    try expect(CalendarTitles.month(october, in: .russian) == ("Октябрь", "2026"), "The month in the nominative over the grid")
    try expect(CalendarTitles.month(october, in: .english) == ("October", "2026"), "And in English")
    try expect(CalendarTitles.spokenDate(on(2026, 10, 7), calendar: moscow, in: .russian) == "среда, 7 октября", "A cell speaks its date")

    for (count, words) in [(1, "1 встреча"), (2, "2 встречи"), (5, "5 встреч"), (11, "11 встреч"), (14, "14 встреч"), (21, "21 встреча"), (22, "22 встречи"), (0, "0 встреч")] {
        try expect(Localization.eventCount(count, in: .russian) == words, "\(count): \(Localization.eventCount(count, in: .russian))")
    }
    try expect(Localization.eventCount(1, in: .english) == "1 event" && Localization.eventCount(14, in: .english) == "14 events", "English counts")
    try expect((0..<7).map { CalendarNames.weekdayShort($0, in: .russian) } == ["пн", "вт", "ср", "чт", "пт", "сб", "вс"], "Weekdays, Monday first")
    for english in ["Day", "Week", "Month", "Free", "%d more", "That's all for today", "no events", "all day", "A free week", "A free day",
                    "Next — %@ · %@", "tomorrow, %@", "Nothing ahead"] {
        try expect(Localization.text(english, in: .russian) != english, "“\(english)” must be translated")
    }
    try expect(Localization.format("%d more", 3, in: .russian) == "ещё 3", "The Week's \"ещё 3\"")
    try expect(Localization.format("+%d more", 1, in: .russian) == "и ещё 1", "The Day's \"и ещё 1\"")
}

func theComingEventSaysWhatItsCallIsOn() throws {
    try expect(CallLink.service(of: URL(string: "https://us02web.zoom.us/j/1")!) == "Zoom", "Zoom")
    try expect(CallLink.service(of: URL(string: "https://meet.google.com/abc")!) == "Google Meet", "Meet")
    try expect(CallLink.service(of: URL(string: "https://telemost.yandex.ru/j/1")!) == "Telemost", "Telemost")
    try expect(Localization.text("Telemost", in: .russian) == "Телемост", "In Russian, Телемост")
    try expect(CallLink.service(of: URL(string: "zoommtg://zoom.us/join?confno=1")!) == "Zoom", "Zoom's own scheme")
    try expect(CallLink.service(of: URL(string: "https://example.com/call")!) == nil, "Not a call service, no name")
}
