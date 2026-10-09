import AppKit
import CapacityNotchCore
import EventKit

/// The Calendar Module (ticket 23): what is next in the person's calendars,
/// read through EventKit, the public interface (ADR 0004).
///
/// Off until turned on (ADR 0003). While off no event store exists, macOS is
/// not asked anything, and nothing wakes the application: the watch below is
/// started only while the Module is on. The decisions — what takes the row,
/// what the day page shows, when to look again — are `CalendarReader`'s, in
/// the core, where they are checked without a calendar.
@MainActor
final class CalendarController {
    let reader: CalendarReader
    private let preferences: Preferences
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var timer: Timer?

    init(preferences: Preferences) {
        self.preferences = preferences
        reader = CalendarReader(
            source: EventKitCalendarSource(),
            enabled: preferences.calendarEnabled,
            tab: preferences.calendarTab,
            rememberTab: { [preferences] in preferences.calendarTab = $0 }
        )
    }

    /// At launch: reads the day if the Module is on and allowed. Never
    /// prompts; that is for the moment it is turned on.
    func resume() {
        guard reader.isEnabled else { return }
        reader.resume()
        watch()
    }

    func setEnabled(_ enabled: Bool) {
        preferences.calendarEnabled = enabled
        if !enabled { stopWatching() }
        Task { [weak self] in
            guard let self else { return }
            // The prompt is macOS's own; it shows over whatever is in front,
            // which for a switch flicked in Settings is Settings.
            await self.reader.setEnabled(enabled)
            if self.reader.isEnabled { self.watch() }
        }
    }

    /// From Settings, when the prompt was never answered.
    func requestAccess() {
        Task { [weak self] in await self?.askForAccess() }
    }

    /// The same, waited on: onboarding asks one thing at a time.
    func askForAccess() async {
        await reader.requestAccess()
        reschedule()
    }

    /// Privacy & Security → Calendars, where a refusal is undone.
    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    func join(_ link: URL) {
        NSWorkspace.shared.open(link)
    }

    // MARK: - Looking again

    /// A calendar changing, the Mac waking, the clock or time zone changing,
    /// the day turning: each reads the day again. Between them a single
    /// timer wakes at the next moment the row could come or go — never on a
    /// beat.
    private func watch() {
        guard observers.isEmpty else { reschedule(); return }
        let center = NotificationCenter.default
        for name in [
            Notification.Name.EKEventStoreChanged,
            .NSCalendarDayChanged,
            .NSSystemClockDidChange,
            .NSSystemTimeZoneDidChange,
        ] {
            observers.append((center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            }))
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }))
        reschedule()
    }

    private func stopWatching() {
        for (center, observer) in observers { center.removeObserver(observer) }
        observers = []
        timer?.invalidate()
        timer = nil
    }

    private func reload() {
        reader.reload()
        reschedule()
    }

    private func reschedule() {
        timer?.invalidate()
        timer = nil
        guard reader.isEnabled, let next = reader.nextChange() else { return }
        let day = CalendarDay.interval(containing: Date())
        let timer = Timer(fire: next.addingTimeInterval(0.5), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Past midnight the day is another one, to be read; before
                // it, only the row may change.
                if day.contains(Date()) { self.reader.tick() } else { self.reader.reload() }
                self.reschedule()
            }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}

/// EventKit, behind the core's `CalendarSource`. The store is made only when
/// first needed — which is only while the Module is on — and made again once
/// access is granted, since a store made before then keeps seeing nothing.
@MainActor
final class EventKitCalendarSource: CalendarSource {
    private var store: EKEventStore?

    func access() -> CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return .granted
        case .notDetermined:
            store = nil
            return .notAsked
        default:
            // Denied, restricted, or write-only: nothing can be read.
            store = nil
            return .refused
        }
    }

    func requestAccess() async -> CalendarAccess {
        let store = store ?? EKEventStore()
        self.store = store
        NSApp.activate()
        _ = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            store.requestFullAccessToEvents { granted, _ in done.resume(returning: granted) }
        }
        return access()
    }

    func events(in interval: DateInterval) -> [CalendarEvent] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        let store = store ?? EKEventStore()
        self.store = store
        // Every calendar: the author chose no picker (2026-10-07). Reminders
        // are another entity type and are not asked for.
        let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: nil)
        return store.events(matching: predicate).map(Self.event)
    }

    private static func event(_ event: EKEvent) -> CalendarEvent {
        let identity = event.eventIdentifier ?? event.calendarItemIdentifier
        return CalendarEvent(
            // A repeating event shares its identifier across occurrences.
            id: "\(identity)@\(Int(event.startDate.timeIntervalSince1970))",
            title: event.title ?? "",
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            url: event.url,
            location: event.location,
            notes: event.notes,
            colour: event.calendar.flatMap { colour(of: $0) },
            isDeclined: event.attendees?.first(where: \.isCurrentUser)?.participantStatus == .declined,
            isCancelled: event.status == .canceled,
            isHoliday: event.calendar.map(isHolidayCalendar) ?? false
        )
    }

    /// macOS's own holiday calendar ("Праздники России") is a subscribed,
    /// read-only calendar, Google's a read-only one; EventKit says no more
    /// than that and the name (`HolidayCalendar`).
    private static func isHolidayCalendar(_ calendar: EKCalendar) -> Bool {
        HolidayCalendar.recognises(
            title: calendar.title,
            isSubscribed: calendar.type == .subscription || calendar.source?.sourceType == .subscribed,
            isReadOnly: !calendar.allowsContentModifications
        )
    }

    private static func colour(of calendar: EKCalendar) -> CalendarColour? {
        guard let colour = calendar.color?.usingColorSpace(.sRGB) else { return nil }
        return CalendarColour(red: colour.redComponent, green: colour.greenComponent, blue: colour.blueComponent)
    }
}
