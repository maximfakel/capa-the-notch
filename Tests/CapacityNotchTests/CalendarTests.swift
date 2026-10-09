import CapacityNotchCore
import Foundation

/// A fixed calendar, so midnight is where the checks expect it whatever the
/// Mac running them is set to.
private let moscow: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
    return calendar
}()

/// 7 October 2026 at this time in Moscow; a day later or earlier with `day`.
private func at(_ hour: Int, _ minute: Int, _ second: Int = 0, day: Int = 7) -> Date {
    moscow.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute, second: second))!
}

private func event(
    _ id: String, _ start: Date, _ end: Date,
    allDay: Bool = false, declined: Bool = false, cancelled: Bool = false
) -> CalendarEvent {
    CalendarEvent(id: id, title: "Title \(id)", start: start, end: end, isAllDay: allDay, isDeclined: declined, isCancelled: cancelled)
}

// MARK: - The row beneath Capacity

func theRowAppearsTenMinutesBeforeAnEventAndLeavesFiveAfter() throws {
    let standUp = event("stand-up", at(10, 30), at(11, 0))
    try expect(CalendarSurface.rowEvent(in: [standUp], at: at(10, 19, 59)) == nil, "Eleven minutes before, the strip is Capacity's")
    try expect(CalendarSurface.rowEvent(in: [standUp], at: at(10, 20)) == standUp, "Ten minutes before, the row appears")
    try expect(CalendarSurface.rowEvent(in: [standUp], at: at(10, 30)) == standUp, "As it starts")
    try expect(CalendarSurface.rowEvent(in: [standUp], at: at(10, 34, 59)) == standUp, "And for whoever joins late")
    try expect(CalendarSurface.rowEvent(in: [standUp], at: at(10, 35)) == nil, "Five minutes in, it goes")

    let short = event("short", at(10, 30), at(10, 32))
    try expect(CalendarSurface.rowEvent(in: [short], at: at(10, 32, 30)) == nil, "An event already over has no row, grace or not")
}

func anEventStillToComeOutranksOneAlreadyStarted() throws {
    let first = event("first", at(10, 0), at(10, 30))
    let second = event("second", at(10, 5), at(10, 30))
    let third = event("third", at(10, 8), at(10, 30))
    try expect(CalendarSurface.rowEvent(in: [third, first, second], at: at(10, 2)) == second, "The soonest of those to come, over the one under way")
    try expect(CalendarSurface.rowEvent(in: [first], at: at(10, 2)) == first, "Alone, the one under way keeps its row")
    let close = event("close", at(10, 1), at(10, 30))
    try expect(CalendarSurface.rowEvent(in: [first, close], at: at(10, 3)) == close, "Of two started, the later")
}

func anAllDayEventNeverTakesTheRowButLeadsTheDay() throws {
    let holiday = event("holiday", at(0, 0), at(0, 0, day: 8), allDay: true)
    let review = event("review", at(15, 0), at(16, 0))
    try expect(CalendarSurface.rowEvent(in: [holiday], at: at(0, 0)) == nil, "An all-day event does not start at a moment worth a row")

    let day = CalendarDay(events: [review, holiday], at: at(9, 0), calendar: moscow)
    try expect(day.featured == review, "The coming event is the timed one, got \(String(describing: day.featured?.id))")
    try expect(day.rest == [holiday], "The all-day event is listed with the rest of today")
}

func declinedAndCancelledEventsAreNotComing() throws {
    let declined = event("declined", at(10, 25), at(11, 0), declined: true)
    let cancelled = event("cancelled", at(10, 25), at(11, 0), cancelled: true)
    try expect(CalendarSurface.rowEvent(in: [declined, cancelled], at: at(10, 20)) == nil, "Neither takes the row")
    try expect(CalendarDay(events: [declined, cancelled], at: at(10, 20), calendar: moscow).isEmpty, "Nor the day")
}

// MARK: - The day page

func theDayFeaturesTheNextEventAndListsTheRestOfToday() throws {
    let over = event("over", at(8, 0), at(9, 0))
    let running = event("running", at(9, 30), at(12, 0))
    let next = event("next", at(11, 0), at(11, 30))
    let later = event("later", at(14, 0), at(15, 0))
    let tomorrow = event("tomorrow", at(9, 0, day: 8), at(10, 0, day: 8))

    let day = CalendarDay(events: [later, tomorrow, over, next, running], at: at(10, 0), calendar: moscow)
    try expect(day.featured == next, "The next to start is the coming event, got \(String(describing: day.featured?.id))")
    try expect(day.rest.map(\.id) == ["running", "later"], "The rest of today, in order, without the one over or tomorrow's: \(day.rest.map(\.id))")

    let evening = CalendarDay(events: [running], at: at(10, 0), calendar: moscow)
    try expect(evening.featured == running, "With nothing still to come, the one under way is featured")

    let done = CalendarDay(events: [over], at: at(10, 0), calendar: moscow)
    try expect(done.isEmpty, "Nothing left today is an empty day")
}

func anEventCrossingMidnightBelongsToBothDays() throws {
    let lateCall = event("late", at(23, 30, day: 6), at(0, 30))
    try expect(
        CalendarDay(events: [lateCall], at: at(0, 10), calendar: moscow).featured == lateCall,
        "Begun yesterday and still running, it is today's"
    )
    try expect(CalendarDay(events: [lateCall], at: at(0, 40), calendar: moscow).isEmpty, "Once over, it is gone")

    let release = event("release", at(23, 55), at(1, 0, day: 8))
    try expect(CalendarSurface.rowEvent(in: [release], at: at(23, 50)) == release, "Starting before midnight, its row comes before it")
    try expect(CalendarDay(events: [release], at: at(23, 50), calendar: moscow).featured == release, "And it is tonight's coming event")

    let justAfter = event("after", at(0, 5, day: 8), at(0, 30, day: 8))
    let read = CalendarDay.readInterval(containing: at(23, 58), calendar: moscow)
    try expect(read.contains(justAfter.start), "What is read reaches past midnight as far as the row does")
    try expect(CalendarSurface.rowEvent(in: [justAfter], at: at(23, 58)) == justAfter, "So an event at 00:05 still has its row at 23:58")
    try expect(CalendarDay(events: [justAfter], at: at(23, 58), calendar: moscow).isEmpty, "But it is tomorrow's, not today's")
}

func theApplicationWakesWhenTheRowCouldChange() throws {
    let standUp = event("stand-up", at(10, 30), at(11, 0))
    try expect(CalendarSurface.nextChange(in: [standUp], after: at(9, 0), calendar: moscow) == at(10, 20), "Ten minutes before")
    try expect(CalendarSurface.nextChange(in: [standUp], after: at(10, 20), calendar: moscow) == at(10, 30), "Then as it starts")
    try expect(CalendarSurface.nextChange(in: [standUp], after: at(10, 30), calendar: moscow) == at(10, 35), "Then as its grace ends")
    try expect(CalendarSurface.nextChange(in: [], after: at(10, 0), calendar: moscow) == at(0, 0, day: 8), "With nothing, at midnight")
}

// MARK: - Call links

func aCallLinkIsFoundWhereverTheCalendarPutsIt() throws {
    let zoom = URL(string: "https://us02web.zoom.us/j/123456789?pwd=abc")!
    try expect(CallLink.find(url: zoom, location: nil, notes: nil) == zoom, "Zoom in the event's URL")

    let meet = CallLink.find(url: nil, location: nil, notes: "Join with Google Meet: https://meet.google.com/abc-defg-hij\nOr dial: +1 555")
    try expect(meet?.absoluteString == "https://meet.google.com/abc-defg-hij", "Meet in the notes, got \(String(describing: meet))")

    let telemost = CallLink.find(url: nil, location: "https://telemost.yandex.ru/j/12345678901234", notes: nil)
    try expect(telemost?.host == "telemost.yandex.ru", "Telemost in the location")

    let facetime = CallLink.find(url: nil, location: nil, notes: "FaceTime: https://facetime.apple.com/join#v=1&p=abc")
    try expect(facetime?.host == "facetime.apple.com", "FaceTime")

    let teams = "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0"
    let wrapped = "https://eur01.safelinks.protection.outlook.com/?url=\(teams.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)&data=x"
    let unwrapped = CallLink.find(url: nil, location: nil, notes: "Join the meeting now <\(wrapped)>")
    try expect(unwrapped?.host == "teams.microsoft.com", "A Teams link wrapped by Outlook is unwrapped, got \(String(describing: unwrapped))")

    let document = URL(string: "https://docs.google.com/document/d/abc")!
    let behind = CallLink.find(url: document, location: "Room 4", notes: "Agenda: https://docs.google.com/x then https://meet.google.com/xyz-abcd-efg")
    try expect(behind?.host == "meet.google.com", "A document is passed over for the call after it")

    try expect(CallLink.find(url: document, location: "Room 4", notes: "https://maps.apple.com/?q=office") == nil, "No call, no Join")
    try expect(CallLink.find(url: nil, location: nil, notes: "https://vk.com/feed") == nil, "VK is a call only at its call links")
    try expect(CallLink.find(url: nil, location: nil, notes: "https://vk.com/call/join/abc") != nil, "And is one there")
    try expect(CallLink.find(url: URL(string: "zoommtg://zoom.us/join?confno=1"), location: nil, notes: nil) != nil, "Zoom's own scheme")

    let withLink = CalendarEvent(id: "a", title: "Sync", start: at(10, 0), end: at(11, 0), url: nil, location: zoom.absoluteString, notes: "secret notes")
    try expect(withLink.callLink == zoom, "The event keeps the link it found, and nothing else of where it was")
}

// MARK: - Off until turned on

@MainActor
private final class StandInCalendar: CalendarSource {
    var answer: CalendarAccess
    var granted: CalendarAccess
    var stored: [CalendarEvent]
    private(set) var asked = 0
    private(set) var reads = 0
    private(set) var statusChecks = 0

    init(answer: CalendarAccess = .notAsked, granted: CalendarAccess = .granted, events: [CalendarEvent] = []) {
        self.answer = answer
        self.granted = granted
        stored = events
    }

    func access() -> CalendarAccess { statusChecks += 1; return answer }
    func requestAccess() async -> CalendarAccess { asked += 1; answer = granted; return granted }
    func events(in interval: DateInterval) -> [CalendarEvent] {
        reads += 1
        return stored.filter { $0.start < interval.end && $0.end > interval.start }
    }
}

@MainActor
func whileOffNothingIsAskedOrRead() async throws {
    let source = StandInCalendar(events: [event("stand-up", at(10, 30), at(11, 0))])
    let reader = CalendarReader(source: source, enabled: false, calendar: moscow, clock: { at(10, 25) })
    reader.resume()
    reader.reload()
    reader.tick()
    try expect(source.asked == 0 && source.reads == 0 && source.statusChecks == 0, "Off, macOS is not even asked what it decided")
    try expect(reader.events.isEmpty && reader.rowEvent == nil && !reader.showsPage, "And nothing is shown")

    await reader.setEnabled(true)
    try expect(source.asked == 1, "Turned on, macOS is asked, once")
    try expect(reader.showsPage && reader.events.count == 1, "Allowed, the day is read")
    try expect(reader.rowEvent?.id == "stand-up", "And an event five minutes off takes the row")

    await reader.setEnabled(false)
    try expect(reader.events.isEmpty && reader.rowEvent == nil && !reader.showsPage, "Off again, every event is forgotten")
    let reads = source.reads
    reader.reload()
    try expect(source.reads == reads, "And no more is read")

    await reader.setEnabled(true)
    try expect(source.asked == 1, "Once answered, turning on does not ask again")
}

@MainActor
func aRefusalShowsNothingOnTheSurface() async throws {
    let source = StandInCalendar(granted: .refused, events: [event("stand-up", at(10, 30), at(11, 0))])
    let reader = CalendarReader(source: source, enabled: false, calendar: moscow, clock: { at(10, 25) })
    await reader.setEnabled(true)
    try expect(reader.isEnabled && reader.access == .refused, "The switch stays on and says it was refused, for Settings")
    try expect(!reader.showsPage && reader.rowEvent == nil && source.reads == 0, "Refused, nothing is read and the surface shows nothing")

    // Allowed later in System Settings: the next reload finds it.
    source.answer = .granted
    reader.reload()
    try expect(reader.showsPage && reader.rowEvent != nil, "Allowed afterwards, the day comes")

    // And taken back again.
    source.answer = .refused
    reader.reload()
    try expect(!reader.showsPage && reader.events.isEmpty, "Taken back, the events go")
}

@MainActor
func atLaunchTheModuleNeverPrompts() async throws {
    let source = StandInCalendar(answer: .notAsked)
    let reader = CalendarReader(source: source, enabled: true, calendar: moscow, clock: { at(10, 0) })
    reader.resume()
    try expect(source.asked == 0 && reader.access == .notAsked && !reader.showsPage, "The prompt belongs to turning the Module on, not to a launch")
    await reader.requestAccess()
    try expect(source.asked == 1 && reader.showsPage, "Settings can ask for it")
}

// MARK: - The rest of the surface

func calendarComesLastAmongThePages() throws {
    let all = SurfacePageOrder.pages(music: true, teleprompter: true, shelf: true, calendar: true)
    try expect(all == [.capacity, .music, .teleprompter, .shelf, .calendar], "The Calendar arrived last, got \(all)")
    try expect(SurfacePageOrder.pages(music: false, teleprompter: false) == [.capacity], "Off, it has no page")
}

func anEventAboutToStartOutranksMusicButNotTheTeleprompter() throws {
    try expect(TeleprompterSurface.compactRow(teleprompterShowing: false, musicShown: true, fullscreen: false, calendarShown: true) == .calendar, "Over music")
    try expect(TeleprompterSurface.compactRow(teleprompterShowing: true, musicShown: false, fullscreen: false, calendarShown: true) == .teleprompter, "Under a Script being read")
    try expect(TeleprompterSurface.compactRow(teleprompterShowing: false, musicShown: false, fullscreen: true, calendarShown: true) == .calendar, "Over a fullscreen application too")
    try expect(TeleprompterSurface.compactRow(teleprompterShowing: false, musicShown: true, fullscreen: false) == .music, "Without it, music as before")
}

func diagnosticsSayHowManyEventsAndNeverWhich() throws {
    try expect(CalendarModule.observation(enabled: false, access: .granted, eventsToday: 3) == "calendar-off", "Off says only that")
    try expect(CalendarModule.observation(enabled: true, access: .refused, eventsToday: 0) == "calendar-on-refused", "A refusal is visible")
    try expect(CalendarModule.observation(enabled: true, access: .notAsked, eventsToday: 0) == "calendar-on-not-asked", "As is a prompt never answered")
    let note = CalendarModule.observation(enabled: true, access: .granted, eventsToday: 4)
    try expect(note == "calendar-on-4-events", "On, a count: \(note)")
    let report = DiagnosticReport(
        applicationVersion: "0.3.1", systemVersion: "26.6", generatedAt: Date(timeIntervalSince1970: 0),
        providers: [], observations: [note]
    ).text()
    try expect(report.contains("note \(note)"), "The note survives Redaction")
    try expect(!report.contains("Title"), "And no title can be in it")
}

func theCalendarSpeaksRussian() throws {
    for english in ["Calendar", "Join", "Today", "Now", "All day", "Nothing else today", "In %d min", "Now · %d min left"] {
        try expect(Localization.text(english, in: .russian) != english, "“\(english)” must be translated")
    }
    try expect(Localization.format("In %d min", 8, in: .russian) == "Через 8 мин", "Numbers reach the translation")
}

@MainActor
func theRowsCrossHidesThatOccurrenceAndNotTheNext() async throws {
    let standUp = event("stand-up", at(10, 30), at(11, 0))
    let review = event("review", at(10, 35), at(11, 0))
    let tomorrow = event("stand-up", at(10, 30, day: 8), at(11, 0, day: 8))
    try expect(CalendarSurface.rowEvent(in: [standUp, review], at: at(10, 25), hidden: [standUp.rowKey]) == review, "Hidden, the next event takes the row")
    try expect(CalendarSurface.rowEvent(in: [tomorrow], at: at(10, 25, day: 8), hidden: [standUp.rowKey]) == tomorrow, "Another occurrence of a repeating event is not hidden with it")

    var now = at(10, 25)
    let source = StandInCalendar(events: [standUp])
    let reader = CalendarReader(source: source, enabled: false, calendar: moscow, clock: { now })
    await reader.setEnabled(true)
    try expect(reader.rowEvent == standUp, "The event about to start takes the row")
    reader.hideFromRow(standUp)
    try expect(reader.rowEvent == nil, "✕ takes it off the row")
    try expect(reader.events.contains(standUp), "The day page keeps it")
    now = at(10, 31)
    reader.tick()
    try expect(reader.rowEvent == nil, "It stays hidden as it starts")
}
