import Combine
import Foundation

/// One event as the Calendar Module shows it: from any calendar on this Mac,
/// read through EventKit (ADR 0004). Reminders are not events and never
/// arrive here.
///
/// The title is the person's own words. It is drawn on the surface and goes
/// nowhere else — never into Copy Diagnostics or the log, which carry only
/// counts and states (`CalendarModule.observation`).
public struct CalendarEvent: Equatable, Identifiable, Sendable {
    /// Which occurrence was hidden from the row: a repeating event shares
    /// its identifier across occurrences, so the start goes with it.
    public var rowKey: String { "\(id)@\(Int(start.timeIntervalSince1970))" }

    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    /// The call to join, found in the event's URL, location or notes.
    public let callLink: URL?
    /// The calendar's colour, as red, green and blue from 0 to 1.
    public let colour: CalendarColour?
    /// Declined by the person, or cancelled by its organiser: neither is
    /// coming, so neither is shown.
    public let isDeclined: Bool
    public let isCancelled: Bool
    /// From a holiday calendar the person has in Calendar
    /// (`HolidayCalendar`): an all-day one marks its days as holidays, red in
    /// the Week and the Month.
    public let isHoliday: Bool

    public init(
        id: String,
        title: String,
        start: Date,
        end: Date,
        isAllDay: Bool = false,
        callLink: URL? = nil,
        colour: CalendarColour? = nil,
        isDeclined: Bool = false,
        isCancelled: Bool = false,
        isHoliday: Bool = false
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = max(end, start)
        self.isAllDay = isAllDay
        self.callLink = callLink
        self.colour = colour
        self.isDeclined = isDeclined
        self.isCancelled = isCancelled
        self.isHoliday = isHoliday
    }

    /// Finds the call link in what the calendar gives — the event's URL,
    /// then its location, then its notes — and keeps none of it but the link.
    public init(
        id: String,
        title: String,
        start: Date,
        end: Date,
        isAllDay: Bool = false,
        url: URL?,
        location: String?,
        notes: String?,
        colour: CalendarColour? = nil,
        isDeclined: Bool = false,
        isCancelled: Bool = false,
        isHoliday: Bool = false
    ) {
        self.init(
            id: id, title: title, start: start, end: end, isAllDay: isAllDay,
            callLink: CallLink.find(url: url, location: location, notes: notes),
            colour: colour, isDeclined: isDeclined, isCancelled: isCancelled, isHoliday: isHoliday
        )
    }

    /// Whether it is under way at this moment.
    public func isRunning(at now: Date) -> Bool {
        start <= now && now < end
    }

    /// Shown at all: neither declined nor cancelled.
    var counts: Bool { !isDeclined && !isCancelled }
}

public struct CalendarColour: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

// MARK: - Access

/// What macOS lets the Module do with the calendars.
public enum CalendarAccess: String, Sendable {
    /// Not asked yet: asking shows macOS's own prompt.
    case notAsked
    /// Full access: events can be read.
    case granted
    /// Refused, restricted, or write-only — nothing can be read, and only
    /// System Settings can change that now.
    case refused
}

// MARK: - The surface

/// When an event takes the row beneath Capacity, and what the day page shows.
public enum CalendarSurface {
    /// The row appears this long before an event starts (the author's choice,
    /// 2026-10-07)...
    public static let lead: TimeInterval = 10 * 60
    /// ...and stays this long after it has started, for whoever joins late,
    /// or until the event ends if that is sooner. Then the strip is
    /// Capacity's alone again.
    public static let grace: TimeInterval = 5 * 60

    /// The event the row beneath Capacity shows, if any.
    ///
    /// Only timed events: an all-day event does not start at a moment worth
    /// looking up for. One still to come outranks one already started — a
    /// person in the first meeting is not looking at the notch for it — the
    /// soonest first; among those started, the latest.
    ///
    /// An event the person hid from the row (`hidden`, by `rowKey`) is
    /// passed over; the next one shows as usual.
    public static func rowEvent(in events: [CalendarEvent], at now: Date, hidden: Set<String> = []) -> CalendarEvent? {
        let candidates = events.filter { event in
            guard event.counts, !event.isAllDay, event.end > now, !hidden.contains(event.rowKey) else { return false }
            return event.start - lead <= now && now < event.start + grace
        }
        let coming = candidates.filter { $0.start > now }.sorted(by: earlierFirst)
        if let first = coming.first { return first }
        return candidates.sorted { $0.start > $1.start || ($0.start == $1.start && $0.id < $1.id) }.first
    }

    /// The next moment the row could change: an event coming within reach,
    /// starting, passing its grace or ending, or the day turning. The
    /// application wakes then, rather than checking on a timer.
    public static func nextChange(in events: [CalendarEvent], after now: Date, calendar: Calendar = .current) -> Date {
        var moments = events.filter { $0.counts && !$0.isAllDay }.flatMap { event in
            [event.start - lead, event.start, event.start + grace, event.end]
        }
        moments.append(CalendarDay.interval(containing: now, calendar: calendar).end)
        return moments.filter { $0 > now }.min() ?? now.addingTimeInterval(3600)
    }

    static func earlierFirst(_ a: CalendarEvent, _ b: CalendarEvent) -> Bool {
        a.start != b.start ? a.start < b.start : a.id < b.id
    }
}

/// The day page: the coming event, and the rest of today.
public struct CalendarDay: Equatable, Sendable {
    /// The event the page puts first and large: the row's, if one is in it;
    /// otherwise the next to start today; otherwise the one under way.
    public let featured: CalendarEvent?
    /// Everything else still to come or under way today, all-day events
    /// first, then by when they start. Events already over are gone.
    public let rest: [CalendarEvent]

    public init(events: [CalendarEvent], at now: Date, calendar: Calendar = .current) {
        let today = Self.interval(containing: now, calendar: calendar)
        let remaining = events.filter { event in
            // Today's: not over yet, and begun before today ends. An event
            // crossing midnight belongs to both days.
            event.counts && event.end > now && event.start < today.end
        }
        let timed = remaining.filter { !$0.isAllDay }
        let featured = CalendarSurface.rowEvent(in: timed, at: now)
            ?? timed.filter { $0.start > now }.sorted(by: CalendarSurface.earlierFirst).first
            ?? timed.filter { $0.isRunning(at: now) }.sorted { $0.start > $1.start }.first
        self.featured = featured
        rest = remaining
            .filter { $0.id != featured?.id }
            .sorted { a, b in
                a.isAllDay != b.isAllDay ? a.isAllDay : CalendarSurface.earlierFirst(a, b)
            }
    }

    /// Nothing left on the calendar today.
    public var isEmpty: Bool { featured == nil && rest.isEmpty }

    /// How many are left today, for Copy Diagnostics.
    public var eventCount: Int { rest.count + (featured == nil ? 0 : 1) }

    /// Today, midnight to midnight, in the Mac's calendar and time zone.
    public static func interval(containing now: Date, calendar: Calendar = .current) -> DateInterval {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return DateInterval(start: start, end: end)
    }

    /// With nothing left today, what the page says comes next ("… Calendar,
    /// nothing left today", 2026-10-08): tomorrow's first event — timed
    /// before all-day — or, with nothing tomorrow, the next one read, or
    /// that nothing lies ahead.
    public static func next(in events: [CalendarEvent], at now: Date, calendar: Calendar = .current) -> CalendarNext {
        guard let first = CalendarAhead.first(after: now, in: events, calendar: calendar) else { return .nothing }
        let tomorrow = CalendarGrid.day(containing: interval(containing: now, calendar: calendar).end, calendar: calendar)
        return tomorrow.contains(first.start) ? .tomorrow(first) : .later(first)
    }

    /// The row's and the Day's part of what is read from the calendars
    /// (`CalendarReading` adds the Week's and the Month's): today, and past
    /// midnight as far as the row reaches, so an event just after midnight still shows its row
    /// the ten minutes before.
    public static func readInterval(containing now: Date, calendar: Calendar = .current) -> DateInterval {
        let today = interval(containing: now, calendar: calendar)
        return DateInterval(start: today.start, end: today.end.addingTimeInterval(CalendarSurface.lead))
    }
}

// MARK: - Call links

/// The video call an event carries, wherever the calendar put it: Zoom,
/// Google Meet, Microsoft Teams, FaceTime, Yandex Telemost and the like.
/// Only a link to a call is taken; a document or a map in the notes is not
/// a call, and gets no Join button.
public enum CallLink {
    /// Hosts whose links are calls, with the path that marks a call where the
    /// host has other pages too (nil: any path).
    private static let services: [(host: String, path: String?)] = [
        ("zoom.us", nil),
        ("zoomgov.com", nil),
        ("meet.google.com", nil),
        ("teams.microsoft.com", "/l/meetup-join"),
        ("teams.microsoft.com", "/meet"),
        ("teams.live.com", "/meet"),
        ("facetime.apple.com", nil),
        ("telemost.yandex.ru", nil),
        ("telemost.yandex.com", nil),
        ("telemost.360.yandex.ru", nil),
        ("webex.com", nil),
        ("meet.jit.si", nil),
        ("whereby.com", nil),
        ("join.skype.com", nil),
        ("chime.aws", nil),
        ("salutejazz.ru", nil),
        ("jazz.sber.ru", nil),
        ("vk.com", "/call/join"),
        ("calls.vk.com", nil),
        ("app.slack.com", "/huddle"),
    ]

    /// What the call is held on, for the Day's coming event ("17:57–18:27 ·
    /// Zoom"), by the same hosts; in English, as the surface translates it.
    public static func service(of url: URL) -> String? {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme.hasPrefix("zoom") { return "Zoom" }
        if scheme == "msteams" { return "Teams" }
        if scheme == "facetime" { return "FaceTime" }
        guard let host = url.host?.lowercased() else { return nil }
        let names: [(String, String)] = [
            ("zoom.us", "Zoom"), ("zoomgov.com", "Zoom"), ("meet.google.com", "Google Meet"),
            ("teams.microsoft.com", "Teams"), ("teams.live.com", "Teams"), ("facetime.apple.com", "FaceTime"),
            ("telemost.yandex.ru", "Telemost"), ("telemost.yandex.com", "Telemost"), ("telemost.360.yandex.ru", "Telemost"),
            ("webex.com", "Webex"), ("meet.jit.si", "Jitsi"), ("whereby.com", "Whereby"), ("join.skype.com", "Skype"),
            ("chime.aws", "Chime"), ("salutejazz.ru", "SaluteJazz"), ("jazz.sber.ru", "SaluteJazz"),
            ("vk.com", "VK Calls"), ("calls.vk.com", "VK Calls"), ("app.slack.com", "Slack"),
        ]
        return names.first { host == $0.0 || host.hasSuffix("." + $0.0) }?.1
    }

    /// Schemes that open a call application directly.
    private static let schemes: Set<String> = ["zoommtg", "zoomus", "msteams", "facetime"]

    public static func find(url: URL?, location: String?, notes: String?) -> URL? {
        if let url, let call = call(url) { return call }
        for text in [location, notes] {
            guard let text, !text.isEmpty else { continue }
            if let call = links(in: text).lazy.compactMap(call).first { return call }
        }
        return nil
    }

    /// The link as a call, or nil when it is not one. An Outlook Safe Links
    /// wrapper is opened to the link it carries.
    static func call(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased() else { return nil }
        if schemes.contains(scheme) { return url }
        guard scheme == "https" || scheme == "http", let host = url.host?.lowercased() else { return nil }
        if host.hasSuffix("safelinks.protection.outlook.com"),
           let inner = URLComponents(url: url, resolvingAgainstBaseURL: false)?
               .queryItems?.first(where: { $0.name == "url" })?.value,
           let unwrapped = URL(string: inner) {
            return call(unwrapped)
        }
        let path = url.path.lowercased()
        let isCall = services.contains { service in
            (host == service.host || host.hasSuffix("." + service.host))
                && (service.path.map { path.hasPrefix($0) } ?? true)
        }
        return isCall ? url : nil
    }

    /// Every link in a piece of text, in the order written.
    static func links(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url)
    }
}

// MARK: - Reading

/// Where events come from: EventKit in the application, a stand-in in the
/// checks. Kept this small so everything the Module decides can be checked
/// without a calendar.
@MainActor
public protocol CalendarSource: AnyObject {
    /// What macOS has decided, without asking.
    func access() -> CalendarAccess
    /// Shows macOS's prompt, when it has not been answered, and returns the
    /// answer.
    func requestAccess() async -> CalendarAccess
    /// Every event overlapping the interval, from every calendar.
    func events(in interval: DateInterval) -> [CalendarEvent]
}

/// The Calendar Module's state. Off until turned on (ADR 0003): while off it
/// asks macOS nothing and reads nothing, and holds no event.
@MainActor
public final class CalendarReader: ObservableObject {
    @Published public private(set) var isEnabled: Bool
    @Published public private(set) var access: CalendarAccess = .notAsked
    /// Every event the page can show: today and just past midnight, the
    /// seven days from today, the Month's grid, and thirty days past today
    /// for what comes next (`CalendarReading`).
    @Published public private(set) var events: [CalendarEvent] = []
    /// The event in the row beneath Capacity, if one is about to start.
    @Published public private(set) var rowEvent: CalendarEvent?
    /// The page's view: Day, Week or Month. It opens on the one last used,
    /// remembered across launches (`Preferences.calendarTab`).
    @Published public private(set) var tab: CalendarTab
    /// The Month's day clicked, as its midnight; nil is today, the default.
    @Published public private(set) var selectedDay: Date?
    /// Occurrences the person hid from the row with its ✕, until they are
    /// over; in memory only. The day page still shows them.
    private var hidden: Set<String> = []

    private let source: CalendarSource
    private let clock: () -> Date
    private let calendar: Calendar
    private let rememberTab: (CalendarTab) -> Void

    public init(
        source: CalendarSource,
        enabled: Bool,
        calendar: Calendar = .current,
        tab: CalendarTab = .standard,
        rememberTab: @escaping (CalendarTab) -> Void = { _ in },
        clock: @escaping () -> Date = Date.init
    ) {
        self.source = source
        isEnabled = enabled
        self.calendar = calendar
        self.tab = tab
        self.rememberTab = rememberTab
        self.clock = clock
    }

    /// A tab clicked: the page shows it, and opens on it next time.
    public func select(_ tab: CalendarTab) {
        guard tab != self.tab else { return }
        self.tab = tab
        rememberTab(tab)
    }

    /// A day clicked in the Month: the list beside the grid shows it.
    /// Today is the default, so choosing it is choosing nothing.
    public func selectDay(_ date: Date) {
        let day = calendar.startOfDay(for: date)
        let chosen: Date? = day == calendar.startOfDay(for: clock()) ? nil : day
        if chosen != selectedDay { selectedDay = chosen }
    }

    /// The day page is there only while the Module is on and may read: a
    /// refusal shows nothing on the surface.
    public var showsPage: Bool { isEnabled && access == .granted }

    /// At launch, with the Module already on: reads what macOS decided and,
    /// if allowed, the day. It never prompts — the prompt belongs to the
    /// moment the Module is turned on.
    public func resume() {
        guard isEnabled else { return }
        access = source.access()
        reload()
    }

    /// Turning on asks macOS — only now, and only if it has not answered —
    /// and reads the day if allowed. Turning off forgets every event.
    public func setEnabled(_ enabled: Bool) async {
        isEnabled = enabled
        guard enabled else {
            events = []
            rowEvent = nil
            return
        }
        access = source.access()
        if access == .notAsked {
            access = await source.requestAccess()
        }
        guard isEnabled else { return }
        reload()
    }

    /// Asks again from Settings, when the person turned the Module on and the
    /// prompt was never answered.
    public func requestAccess() async {
        guard isEnabled else { return }
        access = await source.requestAccess()
        reload()
    }

    /// Reads the day again: a calendar changed, the Mac woke, the day turned.
    public func reload() {
        guard isEnabled else { return }
        // Asked each time, never prompting: access can be taken back in
        // System Settings while the Module runs.
        let allowed = source.access()
        if allowed != access { access = allowed }
        guard access == .granted else {
            events = []
            rowEvent = nil
            return
        }
        // The Week's seven days, the Month's whole grid and thirty days on
        // as well as today: still only while on and allowed.
        let read = source.events(in: CalendarReading.interval(containing: clock(), calendar: calendar))
        if read != events { events = read }
        tick()
    }

    /// The clock moved: the row may come or go, without reading anything.
    public func tick() {
        // An occurrence no longer read — over, or a new day — need not be
        // remembered as hidden.
        hidden.formIntersection(events.map(\.rowKey))
        let row = showsPage ? CalendarSurface.rowEvent(in: events, at: clock(), hidden: hidden) : nil
        if row != rowEvent { rowEvent = row }
    }

    /// The ✕ on the row: this occurrence leaves the row until it is over;
    /// the next event shows as usual, and the day page keeps it.
    public func hideFromRow(_ event: CalendarEvent) {
        hidden.insert(event.rowKey)
        tick()
    }

    /// When `tick` next has something to do.
    public func nextChange() -> Date? {
        guard showsPage else { return nil }
        return CalendarSurface.nextChange(in: events, after: clock(), calendar: calendar)
    }

    /// The day page as of now.
    public func day(at now: Date) -> CalendarDay {
        CalendarDay(events: events, at: now, calendar: calendar)
    }

    /// The Week as of now: seven days from today.
    public func week(at now: Date) -> CalendarWeek {
        CalendarWeek(events: events, at: now, calendar: calendar)
    }

    /// The Month as of now, and the day its list shows.
    public func month(at now: Date) -> (month: CalendarMonth, selected: CalendarGridDay?) {
        let month = CalendarMonth(events: events, at: now, calendar: calendar)
        return (month, month.selected(selectedDay))
    }
}

/// What a bug report may say about the Module: whether it is on, what macOS
/// allows, and how many events are left today — never a title.
public enum CalendarModule {
    public static func observation(enabled: Bool, access: CalendarAccess, eventsToday: Int) -> String {
        guard enabled else { return "calendar-off" }
        switch access {
        case .notAsked: return "calendar-on-not-asked"
        case .refused: return "calendar-on-refused"
        case .granted: return "calendar-on-\(eventsToday)-events"
        }
    }
}

public extension KapaMood {
    /// Kapa on the Calendar's Day (ADR 0006, amended 2026-10-08): only with
    /// nothing left today, in sunglasses, large in the box that says so; nil
    /// — no Kapa — while anything is left.
    static func calendar(_ day: CalendarDay) -> KapaExpression? {
        day.isEmpty ? .free : nil
    }

    /// Kapa on the Calendar's Week: only a week with nothing in it, in
    /// sunglasses; nil otherwise. The Month never has one.
    static func calendar(_ week: CalendarWeek) -> KapaExpression? {
        week.isFree ? .free : nil
    }
}
