import AppKit
import CapacityNotchCore
import SwiftUI

/// The Calendar Module on the surface: a row beneath Capacity while an event
/// is about to start, and a page in the open surface with three views — the
/// Day, the Week and the Month.
///
/// The row is "Notch — Compact — Event soon"; the page "Notch — Expanded —
/// Calendar" and its week and month, measured from Paper as the author edited
/// them on 2026-10-08, on the 152-point page every Module has.
enum CalendarType {
    static let title = SurfaceType.geist(15, .medium)
    static let featuredTitle = SurfaceType.geist(17, .semibold)
    static let listTitle = SurfaceType.geist(13, .medium)
    /// The row's line and the Week's small print.
    static let detail = SurfaceType.geist(11)
    /// The page's times and dates.
    static let pageDetail = SurfaceType.geist(12)
    static let label = SurfaceType.geist(12, .medium)
    static let headerTitle = SurfaceType.geist(15, .semibold)
    static let headerDetail = SurfaceType.geist(12)
    static let tab = SurfaceType.geist(13, .medium)
    static let weekday = SurfaceType.geist(11, .medium)
    static let weekNumber = SurfaceType.geist(13, .semibold)
    static let secondary = SurfaceType.captionColour
    /// "свободно", and the neighbouring months' days.
    static let faint = Color.white.opacity(0x59 / 255)
    /// The free day's, the free week's and the empty day's box: #FFFFFF14.
    static let box = Color.white.opacity(0x14 / 255)
    /// Today, weekends and holidays: #FF4539.
    static let red = Color(red: 1, green: 0x45 / 255, blue: 0x39 / 255)

    /// As the music row: six under the strip, 34 of content, 14 to the edge.
    static let rowHeight: CGFloat = 54
    static let rowTile: CGFloat = 34

    /// The page, as the Shelf's (`CalendarPageLayout`): 10 above, an
    /// 18-point header, 8 under it, 112 for the view, 4 below.
    static let pageTop = CGFloat(CalendarPageLayout.top)
    static let headerHeight = CGFloat(CalendarPageLayout.header)
    static let belowHeader = CGFloat(CalendarPageLayout.belowHeader)
    static let viewHeight = CGFloat(CalendarPageLayout.content)
    static let pageBottom = CGFloat(CalendarPageLayout.bottom)
    /// The tabs: 16 high, a point inside the header's 18.
    static let tabHeight: CGFloat = 16
    /// The heading's room on the left, clear of the centred tabs.
    static let headerTitleWidth: CGFloat = 184

    /// The Day: the coming event's card — "Через 8 мин · 17:57–18:27" and
    /// the title each on one line — and the list beside it, equal halves
    /// with 12 between: 256, 12, 256.
    static let dayGap: CGFloat = 12
    static let listRow: CGFloat = 18
    static let listRows = 5
    static let listTime: CGFloat = 66

    /// The Week: the day's weekday and number over its chips.
    static let weekDayHeader: CGFloat = 24
    static let chipSpacing = CGFloat(CalendarChips.spacing)

    /// The Month: the grid's width and the gap to the list. Its rows fill
    /// the view's height for the weeks the month has (`CalendarMonthMetrics`).
    static let monthWidth: CGFloat = 236
    static let monthGap: CGFloat = 20

    static func colour(_ colour: CalendarColour?) -> Color {
        guard let colour else { return Color.white.opacity(0.6) }
        return Color(red: colour.red, green: colour.green, blue: colour.blue)
    }
}

/// The words the Module uses for times, in the language Settings speak and
/// the clock the Mac keeps (12 or 24 hours).
enum CalendarWords {
    static func title(_ event: CalendarEvent) -> String {
        CalendarTitles.eventTitle(event)
    }

    static func time(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(.autoupdatingCurrent))
    }

    static func range(_ event: CalendarEvent) -> String {
        event.isAllDay ? L("All day") : "\(time(event.start))–\(time(event.end))"
    }

    /// "In 8 min", "In 1 h 20 min", "Now · 25 min left".
    static func relative(_ event: CalendarEvent, at now: Date) -> String {
        if event.isAllDay { return L("All day") }
        if event.start > now {
            let minutes = Int((event.start.timeIntervalSince(now) / 60).rounded(.up))
            if minutes < 60 { return L("In %d min", max(minutes, 1)) }
            let hours = minutes / 60, rest = minutes % 60
            return rest == 0 ? L("In %d h", hours) : L("In %d h %d min", hours, rest)
        }
        let left = Int((event.end.timeIntervalSince(now) / 60).rounded(.up))
        return L("Now · %d min left", max(left, 1))
    }

    static func spoken(_ event: CalendarEvent, at now: Date) -> String {
        [L("Calendar"), title(event), relative(event, at: now), range(event)].joined(separator: ", ")
    }

    /// The coming event's card, spoken: the drawing no longer shows what the
    /// call is on (2026-10-08), VoiceOver still says it.
    static func spokenWithService(_ event: CalendarEvent, at now: Date) -> String {
        guard let service = event.callLink.flatMap(CallLink.service(of:)) else { return spoken(event, at: now) }
        return "\(spoken(event, at: now)), \(L(service))"
    }
}

// MARK: - Pieces

/// Join: the event's call, opened in whatever application owns the link.
struct CalendarJoinButton: View {
    let link: URL
    var compact = false
    let join: (URL) -> Void

    var body: some View {
        Button { join(link) } label: {
            HStack(spacing: compact ? 5 : 6) {
                Image(systemName: "video.fill")
                    .font(.system(size: compact ? 10 : 12, weight: .semibold))
                Text(L("Join"))
                    .font(SurfaceType.geist(compact ? 12 : 13, .semibold))
            }
            .foregroundStyle(Color.black)
            .padding(.horizontal, compact ? 10 : 12)
            // The page's is "Notch — Expanded — Calendar"'s 30.
            .frame(height: compact ? 24 : 30)
            .background(Capsule().fill(SurfaceType.green))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel(L("Join call"))
    }
}

/// The row's ✕, as in "Notch — Compact — Event soon": a quiet circle beside
/// Join.
struct CalendarHideButton: View {
    let hide: () -> Void

    var body: some View {
        Button(action: hide) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.7))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0x1F / 255)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(L("Hide this event"))
        .accessibilityLabel(L("Hide this event"))
    }
}

/// The calendar's colour on a quiet square, with a calendar in it: where the
/// music row has its artwork.
private struct CalendarTile: View {
    let start: Date

    var body: some View {
        // As in "Notch — Compact — Event soon": the weekday small and red over
        // the day of the month, like the Calendar app's own icon.
        VStack(spacing: 0) {
            Text(Self.weekday(start))
                .font(SurfaceType.geist(8, .semibold))
                .tracking(0.32)
                .foregroundStyle(Color(red: 1, green: 0x45 / 255, blue: 0x39 / 255))
                .frame(height: 10)
            Text(Self.day(start))
                .font(SurfaceType.geist(15, .semibold))
                .foregroundStyle(.white)
                .frame(height: 16)
        }
        .frame(width: CalendarType.rowTile, height: CalendarType.rowTile)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0x1F / 255)))
        .accessibilityHidden(true)
    }

    private static func weekday(_ date: Date) -> String {
        let format = DateFormatter()
        format.locale = Localization.current.locale
        format.setLocalizedDateFormatFromTemplate("EEE")
        return format.string(from: date).replacingOccurrences(of: ".", with: "").uppercased()
    }

    private static func day(_ date: Date) -> String {
        String(Calendar.current.component(.day, from: date))
    }
}

// MARK: - The row beneath Capacity

/// An event about to start, beneath an unchanged Capacity strip (ADR 0003,
/// amended): from ten minutes before it until five after, with Join when it
/// carries a call. Silent: it arrives by itself (ADR 0007).
struct CompactCalendarRow: View {
    let event: CalendarEvent
    let now: Date
    let width: CGFloat
    let join: (URL) -> Void
    /// The ✕: hides this occurrence from the row, over a fullscreen
    /// application or not (the author's rule, 2026-10-07).
    var hide: () -> Void = {}

    var body: some View {
        // The surface's beat is thirty seconds; the minutes are counted from
        // the clock, so the row never opens on a minute too many.
        let clock = max(now, Date())
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                CalendarTile(start: event.start)
                VStack(alignment: .leading, spacing: 0) {
                    Text(CalendarWords.title(event))
                        .font(CalendarType.title)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .frame(height: 18)
                    Text("\(CalendarWords.relative(event, at: clock)) · \(CalendarWords.range(event))")
                        .font(CalendarType.detail)
                        .foregroundStyle(CalendarType.secondary)
                        .lineLimit(1)
                        .frame(height: 14)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let link = event.callLink {
                CalendarJoinButton(link: link, compact: true, join: join)
            }
            CalendarHideButton(hide: hide)
        }
        .frame(height: CalendarType.rowTile)
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .padding(.bottom, 14)
        .frame(width: width, height: CalendarType.rowHeight, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(CalendarWords.spoken(event, at: clock))
    }
}

// MARK: - The page

/// The Calendar page: a header — what the view shows on the left, the tabs
/// Day, Week and Month centred — over the view chosen ("Notch — Expanded —
/// Calendar", "… week", "… month", "… month of six weeks", and their states
/// with nothing in them). It opens on the tab last used
/// (`CalendarReader.tab`).
///
/// Laid out as the Shelf page is, as the author's edits of 2026-10-08 draw
/// it: 10 above, the 18-point header, 8 under it, 112 for the view and 4
/// below — the 152 every page has (`CalendarPageLayout`).
struct CalendarPage: View {
    let events: [CalendarEvent]
    let now: Date
    /// The surface's beat is thirty seconds; on the running surface the page
    /// counts from the clock. The pictures draw a moment of their own.
    var liveClock = true
    var tab: CalendarTab = .standard
    /// The Month's day clicked; nil is today.
    var selectedDay: Date? = nil
    var selectTab: (CalendarTab) -> Void = { _ in }
    var selectDay: (Date) -> Void = { _ in }
    let join: (URL) -> Void

    var body: some View {
        let clock = liveClock ? max(now, Date()) : now
        Group {
            switch tab {
            case .day:
                CalendarDayView(events: events, now: clock, selectTab: selectTab, join: join)
            case .week:
                CalendarWeekView(events: events, now: clock, selectTab: selectTab)
            case .month:
                CalendarMonthView(
                    events: events, now: clock, selectedDay: selectedDay,
                    selectTab: selectTab, selectDay: selectDay, join: join
                )
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, CalendarType.pageTop)
        .padding(.bottom, CalendarType.pageBottom)
        .frame(height: NotchGeometry.pageHeight, alignment: .top)
    }
}

/// The header over the view, and the 112 points of the view under it.
private struct CalendarFrame<Content: View>: View {
    let title: String
    let detail: String
    let tab: CalendarTab
    let select: (CalendarTab) -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: CalendarType.belowHeader) {
            CalendarHeader(title: title, detail: detail, tab: tab, select: select)
            content
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: CalendarType.viewHeight, alignment: .top)
        }
    }
}

/// What the view shows, on the left, and the tabs, centred on the surface.
private struct CalendarHeader: View {
    let title: String
    let detail: String
    let tab: CalendarTab
    let select: (CalendarTab) -> Void

    var body: some View {
        ZStack {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(CalendarType.headerTitle)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(detail)
                    .font(CalendarType.headerDetail)
                    .foregroundStyle(CalendarType.secondary)
                    .lineLimit(1)
            }
            // Clear of the tabs, whatever the language makes of the heading.
            .frame(width: CalendarType.headerTitleWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            CalendarTabs(selected: tab, select: select)
        }
        .frame(height: CalendarType.headerHeight)
    }
}

/// День · Неделя · Месяц: buttons, the chosen one white.
private struct CalendarTabs: View {
    let selected: CalendarTab
    let select: (CalendarTab) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(CalendarTab.allCases, id: \.self) { tab in
                Button { select(tab) } label: {
                    Text(L(tab.title))
                        .font(CalendarType.tab)
                        .foregroundStyle(tab == selected ? Color.white : CalendarType.secondary)
                        .frame(height: CalendarType.tabHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L(tab.title))
                .accessibilityAddTraits(tab == selected ? [.isButton, .isSelected] : [.isButton])
            }
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Calendar view"))
    }
}

/// A rounded box saying a view has nothing in it, and what comes next: the
/// Day with nothing left ("… nothing left today"), the Week with nothing in
/// it ("… week with nothing"). It fills the room it is given.
///
/// Kapa stands in it, large, at the right, sitting on the box's bottom edge
/// and cut by it, as drawn — the one place on the Calendar page Kapa is
/// (the author's decision of 2026-10-08, ADR 0006): free time, in
/// sunglasses (`KapaMood.calendar`).
private struct CalendarNothingBox: View {
    let title: String
    let detail: String
    let pose: KapaExpression?
    let kapa: CalendarFreeKapa

    var body: some View {
        if let pose {
            WithKapa {
                words(clearing: kapa.size + kapa.right)
                    .overlay(alignment: .bottomTrailing) {
                        KapaView(expression: pose, size: kapa.size)
                            .padding(.trailing, kapa.right)
                            .offset(y: kapa.below)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } otherwise: {
                words(clearing: 0)
            }
        } else {
            words(clearing: 0)
        }
    }

    private func words(clearing kapaRoom: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(CalendarType.featuredTitle)
                .tracking(-0.17)
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(height: 22)
            Text(detail)
                .font(CalendarType.pageDetail)
                .foregroundStyle(CalendarType.secondary)
                .lineLimit(1)
                .frame(height: 16)
        }
        .padding(.leading, 14)
        // The words keep clear of Kapa when it is there.
        .padding(.trailing, kapaRoom > 0 ? kapaRoom + 8 : 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(CalendarType.box))
        .accessibilityElement(children: .combine)
    }
}

/// Where Kapa sits in a free box, from the drawings: "Kapa — free C" in the
/// Day's (116, 22 from the right, 8 below the edge), "Kapa — free A" in the
/// Week's (92, 18 from the right, 6 below).
private struct CalendarFreeKapa {
    let size: CGFloat
    let right: CGFloat
    let below: CGFloat

    static let day = CalendarFreeKapa(size: 116, right: 22, below: 8)
    static let week = CalendarFreeKapa(size: 92, right: 18, below: 6)
}

// MARK: - Day

/// The day: the coming event on a card on the left, with Join; the rest of
/// today beside it, one line each. Events already over are gone. With
/// nothing left, one box says so and what comes next.
private struct CalendarDayView: View {
    let events: [CalendarEvent]
    let now: Date
    let selectTab: (CalendarTab) -> Void
    let join: (URL) -> Void

    var body: some View {
        let day = CalendarDay(events: events, at: now)
        CalendarFrame(title: L("Today"), detail: CalendarTitles.dayDate(now), tab: .day, select: selectTab) {
            if day.isEmpty {
                CalendarNothingBox(
                    title: L("That's all for today"),
                    detail: CalendarTitles.dayHint(CalendarDay.next(in: events, at: now), time: CalendarWords.time),
                    pose: KapaMood.calendar(day),
                    kapa: .day
                )
            } else if day.featured != nil {
                // Equal halves, 12 between: 256 each, whatever the title —
                // it truncates within the card. The card is the view's 112;
                // the list's five rows of 18 and gaps of 6 come to 116 and
                // run four into the room below, as drawn.
                HStack(alignment: .top, spacing: CalendarType.dayGap) {
                    CalendarFeatured(day: day, now: now, join: join)
                        .frame(minWidth: 0, maxWidth: .infinity)
                        .frame(height: CalendarType.viewHeight)
                    CalendarList(events: day.rest, now: now, empty: L("Nothing else today"), join: join)
                        .frame(minWidth: 0, maxWidth: .infinity)
                }
            } else {
                // Only all-day events left: the list has the room.
                CalendarList(events: day.rest, now: now, empty: L("Nothing else today"), join: join)
            }
        }
    }
}

/// The coming event, as the author's edit draws it: "Через 8 мин ·
/// 17:57–18:27" on one line, the title on one, Join at the bottom. No Kapa:
/// on the Calendar page it stands only in free time (ADR 0006, 2026-10-08).
private struct CalendarFeatured: View {
    let day: CalendarDay
    let now: Date
    let join: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let event = day.featured {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(CalendarType.colour(event.colour))
                            .frame(width: 6, height: 6)
                        Text("\(CalendarWords.relative(event, at: now)) · \(CalendarWords.range(event))")
                            .font(CalendarType.label)
                            .foregroundStyle(CalendarType.secondary)
                            .lineLimit(1)
                    }
                    .frame(height: 16)
                    Text(CalendarWords.title(event))
                        .font(CalendarType.featuredTitle)
                        .tracking(-0.17)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .frame(height: 20)
                }

                Spacer(minLength: 0)

                if let link = event.callLink {
                    CalendarJoinButton(link: link, join: join)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(SurfaceType.cardColour))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(day.featured.map { CalendarWords.spokenWithService($0, at: now) } ?? "")
    }
}

/// A day's events, one line each, as the Day lists the rest of today and the
/// Month the day chosen: five lines at most, the last "и ещё N".
private struct CalendarList: View {
    let events: [CalendarEvent]
    let now: Date
    let empty: String
    let join: (URL) -> Void

    var body: some View {
        let overflow = events.count > CalendarType.listRows
        let shown = overflow ? Array(events.prefix(CalendarType.listRows - 1)) : events

        VStack(alignment: .leading, spacing: 6) {
            if events.isEmpty {
                Text(empty)
                    .font(CalendarType.pageDetail)
                    .foregroundStyle(CalendarType.secondary)
                    .frame(height: CalendarType.listRow, alignment: .leading)
            }
            ForEach(shown) { event in
                CalendarListRow(event: event, now: now, join: join)
            }
            if overflow {
                Text(L("+%d more", events.count - shown.count))
                    .font(CalendarType.listTitle)
                    .foregroundStyle(CalendarType.secondary)
                    .padding(.leading, CalendarType.listTime + 8 + 6 + 8)
                    .frame(height: CalendarType.listRow, alignment: .leading)
            }
        }
        .padding(.top, 2)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct CalendarListRow: View {
    let event: CalendarEvent
    let now: Date
    let join: (URL) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(CalendarType.pageDetail)
                .monospacedDigit()
                .foregroundStyle(event.isRunning(at: now) && !event.isAllDay ? Color.white : CalendarType.secondary)
                .lineLimit(1)
                .frame(width: CalendarType.listTime, alignment: .leading)
            Circle()
                .fill(CalendarType.colour(event.colour))
                .frame(width: 6, height: 6)
            Text(CalendarWords.title(event))
                .font(CalendarType.listTitle)
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            // The call's slot is kept whether or not there is a call, so the
            // titles end in one lane.
            Group {
                if let link = event.callLink {
                    Button { join(link) } label: {
                        Image(systemName: "video.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(SurfaceType.green)
                            .frame(width: 14, height: CalendarType.listRow)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("Join call"))
                } else {
                    Color.clear
                }
            }
            .frame(width: 14)
        }
        .frame(height: CalendarType.listRow)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(CalendarWords.title(event)), \(CalendarWords.range(event))")
    }

    private var label: String {
        if event.isAllDay { return L("All day") }
        if event.isRunning(at: now) { return L("Now") }
        return CalendarWords.time(event.start)
    }
}

// MARK: - Week

/// Seven days from today, in seven equal columns; each day's events as
/// chips, two at most, then "ещё N"; a day with nothing is a free box. A
/// week with nothing at all keeps its dates and has one box across it.
private struct CalendarWeekView: View {
    let events: [CalendarEvent]
    let now: Date
    let selectTab: (CalendarTab) -> Void

    var body: some View {
        let week = CalendarWeek(events: events, at: now)
        CalendarFrame(
            title: CalendarTitles.weekRange(week.interval),
            detail: CalendarTitles.weekCount(week),
            tab: .week, select: selectTab
        ) {
            if week.isFree {
                VStack(spacing: CalendarType.chipSpacing) {
                    HStack(spacing: 6) {
                        ForEach(week.days) { day in
                            CalendarWeekDate(day: day)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    CalendarNothingBox(
                        title: L("A free week"),
                        detail: CalendarTitles.weekHint(week.next, time: CalendarWords.time),
                        pose: KapaMood.calendar(week),
                        kapa: .week
                    )
                }
            } else {
                HStack(alignment: .top, spacing: 6) {
                    ForEach(week.days) { day in
                        CalendarWeekColumn(day: day)
                    }
                }
            }
        }
    }
}

/// A day's weekday and number: today's in its red circle, weekends and
/// holidays red.
private struct CalendarWeekDate: View {
    let day: CalendarGridDay

    var body: some View {
        HStack(spacing: 5) {
            Text(CalendarNames.weekdayShort(day.weekdayIndex))
                .font(CalendarType.weekday)
                .foregroundStyle(day.isToday || day.isRed ? CalendarType.red : CalendarType.secondary)
            Text("\(day.number)")
                .font(CalendarType.weekNumber)
                .foregroundStyle(day.isToday ? Color.white : day.isRed ? CalendarType.red : Color.white)
                .frame(width: 22, height: 22)
                .background { if day.isToday { Circle().fill(CalendarType.red) } }
        }
        .frame(height: CalendarType.weekDayHeader)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(CalendarTitles.spokenDate(day.start) + (day.isHoliday ? ", \(L("Holiday"))" : ""))
    }
}

private struct CalendarWeekColumn: View {
    let day: CalendarGridDay

    var body: some View {
        let fit = CalendarChips.fit(day.events)
        VStack(alignment: .leading, spacing: CalendarType.chipSpacing) {
            CalendarWeekDate(day: day)

            if day.events.isEmpty {
                // A free day: a quiet box filling the column under the date.
                Text(L("Free"))
                    .font(CalendarType.detail)
                    .foregroundStyle(CalendarType.faint)
                    .frame(height: 14)
                    .padding(.leading, 7)
                    .padding(.top, 4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(CalendarType.box))
            } else {
                ForEach(fit.shown) { event in
                    CalendarChip(event: event)
                }
                if fit.more > 0 {
                    Text(L("%d more", fit.more))
                        .font(CalendarType.detail)
                        .foregroundStyle(CalendarType.secondary)
                        .padding(.leading, 7)
                        .frame(height: 14)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }
}

/// One event in the Week: a bar of its calendar's colour on a wash of it,
/// the time over the title.
private struct CalendarChip: View {
    let event: CalendarEvent

    var body: some View {
        let colour = CalendarType.colour(event.colour)
        VStack(alignment: .leading, spacing: 0) {
            Text(event.isAllDay ? L("All day") : CalendarWords.time(event.start))
                .font(SurfaceType.geist(10))
                .monospacedDigit()
                .foregroundStyle(CalendarType.secondary)
                .lineLimit(1)
                .frame(height: 12)
            Text(CalendarWords.title(event))
                .font(SurfaceType.geist(11, .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(height: 13)
        }
        .padding(.vertical, 2)
        .padding(.leading, 7)
        .padding(.trailing, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colour.opacity(0x38 / 255))
        .overlay(alignment: .leading) { colour.frame(width: 2) }
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(CalendarWords.title(event)), \(CalendarWords.range(event))")
    }
}

// MARK: - Month

/// The month's grid on the left, Monday first, five rows of 20 or six of 17
/// filling the view; the
/// chosen day's events beside it, or, with none, the day, "Свободный день"
/// and what comes after it. A number clicked chooses its day; today is the
/// default.
private struct CalendarMonthView: View {
    let events: [CalendarEvent]
    let now: Date
    let selectedDay: Date?
    let selectTab: (CalendarTab) -> Void
    let selectDay: (Date) -> Void
    let join: (URL) -> Void

    var body: some View {
        let month = CalendarMonth(events: events, at: now)
        let selected = month.selected(selectedDay)
        let heading = CalendarTitles.month(month)
        CalendarFrame(title: heading.name, detail: heading.year, tab: .month, select: selectTab) {
            HStack(alignment: .top, spacing: CalendarType.monthGap) {
                CalendarMonthGrid(month: month, selected: selected?.start, select: selectDay)
                    .frame(width: CalendarType.monthWidth)
                if let selected, selected.events.isEmpty {
                    CalendarFreeDay(day: selected, next: CalendarAhead.after(selected, in: events, at: now))
                } else {
                    CalendarList(events: selected?.events ?? [], now: now, empty: L("Nothing else today"), join: join)
                }
            }
        }
    }
}

/// A chosen day with nothing on it ("… month of six weeks", 7 March): its
/// date — red for a weekend or a holiday — "Свободный день", and the next
/// event after it. Today with nothing left says "На сегодня всё".
private struct CalendarFreeDay: View {
    let day: CalendarGridDay
    let next: CalendarEvent?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(CalendarTitles.dayDate(day.start))
                .font(CalendarType.label)
                .foregroundStyle(day.isRed ? CalendarType.red : CalendarType.secondary)
                .lineLimit(1)
                .frame(height: 16)
            Text(day.isToday ? L("That's all for today") : L("A free day"))
                .font(CalendarType.featuredTitle)
                .tracking(-0.17)
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(height: 22)
            Text(CalendarTitles.freeDayHint(next, time: CalendarWords.time))
                .font(CalendarType.pageDetail)
                .foregroundStyle(CalendarType.secondary)
                .lineLimit(1)
                .frame(height: 16)
        }
        // The list's two, and the drawing's twelve above the date.
        .padding(.top, 2 + 12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }
}

private struct CalendarMonthGrid: View {
    let month: CalendarMonth
    let selected: Date?
    let select: (Date) -> Void

    var body: some View {
        // The grid fills the view: 12 + 5 × 20, or 10 + 6 × 17.
        let metrics = month.metrics
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { index in
                    Text(CalendarNames.weekdayShort(index))
                        .font(SurfaceType.geist(10, .medium))
                        .foregroundStyle(index >= 5 ? CalendarType.red : CalendarType.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: CGFloat(metrics.weekdayHeight))
                        .accessibilityHidden(true)
                }
            }
            ForEach(month.weeks.indices, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(month.weeks[row]) { day in
                        CalendarMonthCell(day: day, isSelected: day.start == selected, metrics: metrics, select: select)
                    }
                }
                .frame(height: CGFloat(metrics.rowHeight))
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct CalendarMonthCell: View {
    let day: CalendarGridDay
    let isSelected: Bool
    let metrics: CalendarMonthMetrics
    let select: (Date) -> Void

    var body: some View {
        let frame = CGFloat(metrics.numberFrame)
        let size = CGFloat(metrics.numberSize)
        let circle = CGFloat(metrics.circle(for: day.number))
        Button { select(day.start) } label: {
            VStack(spacing: CGFloat(metrics.dotGap)) {
                // The number in its square frame; today in a red circle, the
                // day chosen in a faint one, both drawn 600. A circle, never
                // an ellipse: too small for two digits, it grows over the
                // dots' row.
                Text("\(day.number)")
                    .font(SurfaceType.geist(size, day.isToday || isSelected ? .semibold : .medium))
                    .tracking(size * CGFloat(metrics.numberTracking))
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(numberColour)
                    .frame(width: frame, height: frame)
                    .background {
                        if day.isToday {
                            Circle().fill(CalendarType.red).frame(width: circle, height: circle)
                        } else if isSelected {
                            // Solid white with a black number (the author,
                            // 2026-10-08): a faint fill, then a ring, read too weakly.
                            Circle().fill(Color.white).frame(width: circle, height: circle)
                        }
                    }
                // Up to three dots under it.
                HStack(spacing: 2) {
                    ForEach(Array(day.dots.enumerated()), id: \.offset) { _, colour in
                        Circle()
                            .fill(CalendarType.colour(colour))
                            .frame(width: 3, height: 3)
                    }
                }
                .frame(height: CGFloat(CalendarMonthMetrics.dotSize))
            }
            .frame(maxWidth: .infinity)
            .frame(height: CGFloat(metrics.rowHeight))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spoken)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
    }

    /// Red for weekends and holidays, white otherwise, past or not; fainter
    /// for the months either side.
    private var numberColour: Color {
        if day.isToday { return .white }
        if isSelected { return .black }
        let base = day.isRed ? CalendarType.red : Color.white
        switch day.tone {
        case .today, .current: return base
        case .otherMonth: return base.opacity(0x59 / 255)
        }
    }

    private var spoken: String {
        var parts = [CalendarTitles.spokenDate(day.start)]
        if day.isToday { parts.append(L("Today")) }
        if day.isHoliday { parts.append(L("Holiday")) }
        parts.append(day.events.isEmpty ? L("No events") : Localization.eventCount(day.events.count))
        return parts.joined(separator: ", ")
    }
}

// MARK: - Pictures

/// The row and the page drawn from made-up events, never the person's own,
/// with `CAPACITY_NOTCH_DUMP_METRICS=1 CAPACITY_NOTCH_DUMP_PICTURES=<dir>`,
/// for the author to hold against a drawing once there is one.
@MainActor
enum CalendarPictures {
    static func draw(into folder: String, geometry: NotchGeometry, snapshots: [CapacitySnapshot]) {
        let now = Date()
        let colours = [
            CalendarColour(red: 0.20, green: 0.60, blue: 1.00),
            CalendarColour(red: 1.00, green: 0.62, blue: 0.04),
            CalendarColour(red: 0.69, green: 0.32, blue: 0.87),
        ]
        func event(_ id: String, _ title: String, in minutes: Double, for length: Double, colour: Int = 0, link: String? = nil, allDay: Bool = false) -> CalendarEvent {
            let start = now.addingTimeInterval(minutes * 60)
            return CalendarEvent(
                id: id, title: title, start: start, end: start.addingTimeInterval(length * 60), isAllDay: allDay,
                callLink: link.flatMap(URL.init(string:)), colour: colours[colour]
            )
        }
        let standUp = event("a", "Design review: notch Modules", in: 8, for: 30, link: "https://meet.google.com/abc-defg-hij")
        let day = [
            standUp,
            event("b", "Lunch with Anna", in: 95, for: 60, colour: 1),
            event("c", "1:1 with Pavel", in: 180, for: 30, link: "https://telemost.yandex.ru/j/123"),
            event("d", "Release 0.4 checklist", in: 260, for: 45, colour: 2),
            event("e", "Planning", in: 320, for: 60),
            event("f", "Gym", in: 400, for: 90, colour: 1),
            event("g", "Moscow Marathon", in: -600, for: 1440, colour: 2, allDay: true),
        ]
        let quiet = [event("h", "Read the spec", in: 150, for: 60, colour: 2)]
        let running = [event("i", "Weekly sync with a very long title that will not fit", in: -12, for: 60, link: "https://zoom.us/j/1")]

        func picture(_ view: some View, width: CGFloat, named name: String) {
            let host = NSHostingView(rootView: view.background(Color.black))
            host.frame = NSRect(x: 0, y: 0, width: width, height: 0)
            host.layoutSubtreeIfNeeded()
            host.frame.size = host.fittingSize
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent(name))
        }
        picture(
            SurfaceColumn(snapshots: snapshots, geometry: geometry, now: now, isExpanded: false, upcoming: standUp,
                          connect: { _ in }, refresh: { _ in }, toggle: {})
                .frame(height: geometry.menuBarHeight + CalendarType.rowHeight, alignment: .top)
                .clipped(),
            width: geometry.surfaceWidth(), named: "compact-calendar.png"
        )
        let tomorrowOnly = [event("t", "Стендап", in: (Calendar.current.startOfDay(for: now).addingTimeInterval(86_400 + 10 * 3600).timeIntervalSince(now)) / 60, for: 15)]
        for (events, name) in [(day, "expanded-calendar.png"), (quiet, "expanded-calendar-later.png"),
                               (running, "expanded-calendar-running.png"), ([], "expanded-calendar-empty.png"),
                               (tomorrowOnly, "expanded-calendar-empty-tomorrow.png")] {
            picture(
                SurfaceColumn(snapshots: snapshots, geometry: geometry, now: now, isExpanded: true, calendarEvents: events,
                              page: .calendar, connect: { _ in }, refresh: { _ in }, toggle: {}),
                width: geometry.surfaceWidth(), named: name
            )
        }
        drawViews(picture: { view, name in picture(view, width: geometry.surfaceWidth(), named: name) },
                  geometry: geometry, snapshots: snapshots)
        let row = NSHostingView(rootView: CompactCalendarRow(event: standUp, now: now, width: geometry.compactWidth(), join: { _ in }))
        row.layoutSubtreeIfNeeded()
        FileHandle.standardError.write(Data("calendar: row=\(row.fittingSize.height) closed=\(geometry.menuBarHeight + row.fittingSize.height)\n".utf8))
        let page = NSHostingView(rootView: SurfaceColumn(
            snapshots: snapshots, geometry: geometry, now: now, isExpanded: true, calendarEvents: day,
            calendarTab: .month, page: .calendar, connect: { _ in }, refresh: { _ in }, toggle: {}
        ))
        page.layoutSubtreeIfNeeded()
        FileHandle.standardError.write(Data("calendar: open=\(page.fittingSize.height)\n".utf8))
    }

    /// The Day, the Week and the Month at the drawings' own moments — Sunday
    /// 4 October 2026, a five-week month, and Wednesday 4 March 2026, a
    /// six-week one with 23 February, 8 and 9 March marked by a holiday
    /// calendar — full and with nothing in them, in Russian and in English.
    private static func drawViews(picture: (AnyView, String) -> Void, geometry: NotchGeometry, snapshots: [CapacitySnapshot]) {
        let calendar = Calendar.current
        let blue = CalendarColour(red: 0x0A / 255, green: 0x84 / 255, blue: 1)
        let orange = CalendarColour(red: 1, green: 0x9F / 255, blue: 0x0A / 255)
        let purple = CalendarColour(red: 0xBF / 255, green: 0x5A / 255, blue: 0xF2 / 255)
        let holidayRed = CalendarColour(red: 1, green: 0x45 / 255, blue: 0x39 / 255)
        func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)) ?? Date()
        }
        var serial = 0
        func timed(_ title: String, _ start: Date, minutes: Double = 30, _ colour: CalendarColour = blue, link: String? = nil) -> CalendarEvent {
            serial += 1
            return CalendarEvent(id: "p\(serial)", title: title, start: start, end: start.addingTimeInterval(minutes * 60),
                                 callLink: link.flatMap(URL.init(string:)), colour: colour)
        }
        func allDay(_ title: String, _ start: Date, days: Int = 1, _ colour: CalendarColour = purple, holiday: Bool = false) -> CalendarEvent {
            serial += 1
            return CalendarEvent(id: "p\(serial)", title: title, start: start, end: start.addingTimeInterval(Double(days) * 86_400),
                                 isAllDay: true, colour: colour, isHoliday: holiday)
        }

        let october = at(2026, 10, 4, 17, 49)
        var autumn: [CalendarEvent] = [
            allDay("Московский марафон", at(2026, 10, 4)),
            timed("Design review: notch Modules", at(2026, 10, 4, 17, 57), link: "https://zoom.us/j/1"),
            timed("Ужин с Анной", at(2026, 10, 4, 19, 30), minutes: 90, orange),
            timed("1:1 с Павлом", at(2026, 10, 4, 20, 45), link: "https://telemost.yandex.ru/j/1"),
            timed("Созвон с командой", at(2026, 10, 4, 21, 30)),
            timed("Почитать спеку", at(2026, 10, 4, 22, 15), purple),
            timed("Ревью PR", at(2026, 10, 5, 14)),
            timed("Обед с Олей", at(2026, 10, 7, 12, 30), orange),
            timed("Демо 0.4", at(2026, 10, 7, 16), purple),
            timed("Релиз 0.4", at(2026, 10, 9, 18), purple),
            timed("Планёрка", at(2026, 10, 1, 11)),
            timed("Стоматолог", at(2026, 10, 2, 9), orange),
            timed("Кино", at(2026, 10, 14, 20), orange),
            timed("Ретро", at(2026, 10, 15, 16)), timed("Ретро", at(2026, 10, 22, 16)), timed("Ретро", at(2026, 10, 29, 16)),
            timed("Йога", at(2026, 10, 21, 8), purple),
        ]
        for day in [5, 6, 7, 8, 9, 12, 19, 26] {
            autumn.append(timed("Стендап", at(2026, 10, day, 10), minutes: 15))
        }

        let march = at(2026, 3, 4, 15)
        var spring: [CalendarEvent] = [
            allDay("День защитника Отечества", at(2026, 2, 23), holidayRed, holiday: true),
            allDay("Международный женский день", at(2026, 3, 8), holidayRed, holiday: true),
            allDay("Выходной (перенос)", at(2026, 3, 9), holidayRed, holiday: true),
            timed("Обед", at(2026, 3, 4, 15, 30), orange),
            timed("Ужин с Анной", at(2026, 3, 4, 19, 30), minutes: 90, orange),
            timed("1:1 с Павлом", at(2026, 3, 4, 20, 45), link: "https://meet.google.com/abc-defg-hij"),
            timed("Демо", at(2026, 3, 17, 16), orange), timed("Йога", at(2026, 3, 18, 8), purple),
            timed("Ретро", at(2026, 3, 25, 16), purple), timed("Кино", at(2026, 3, 31, 20), orange),
        ]
        for day in [2, 3, 4, 5, 6, 10, 11, 12, 13, 16, 17, 19, 20, 23, 24, 25, 26, 27, 30] {
            spring.append(timed("Стендап", at(2026, 3, day, 10), minutes: 15))
        }

        // Nothing until tomorrow's stand-up ("… nothing left today"); nothing
        // until Monday the 12th ("… week with nothing"); nothing at all.
        let tomorrow = [timed("Стендап", at(2026, 10, 5, 10), minutes: 15)]
        let nextWeek = [timed("Стендап", at(2026, 10, 12, 10), minutes: 15), timed("Ретро", at(2026, 10, 15, 16))]

        let language = Localization.current
        defer { Localization.current = language }
        for (spoken, suffix) in [(AppLanguage.russian, ""), (.english, "-en")] {
            Localization.current = spoken
            for (events, moment, tab, chosen, name) in [
                (autumn, october, CalendarTab.day, nil as Date?, "expanded-calendar-day-tabs"),
                (tomorrow, october, .day, nil, "expanded-calendar-day-empty-tomorrow"),
                (nextWeek, october, .day, nil, "expanded-calendar-day-empty-later"),
                ([], october, .day, nil, "expanded-calendar-day-empty-nothing"),
                (autumn, october, .week, nil, "expanded-calendar-week"),
                (nextWeek, october, .week, nil, "expanded-calendar-week-free"),
                ([], october, .week, nil, "expanded-calendar-week-free-nothing"),
                (autumn, october, .month, nil, "expanded-calendar-month"),
                (autumn, october, .month, at(2026, 10, 7), "expanded-calendar-month-chosen"),
                (spring, march, .month, nil, "expanded-calendar-month-six"),
                (spring, march, .month, at(2026, 3, 7), "expanded-calendar-month-six-free"),
                (spring, march, .month, at(2026, 3, 17), "expanded-calendar-month-six-chosen"),
                ([], march, .month, at(2026, 3, 7), "expanded-calendar-month-free-nothing"),
                (spring, march, .week, nil, "expanded-calendar-week-holiday"),
            ] {
                picture(AnyView(
                    SurfaceColumn(snapshots: snapshots, geometry: geometry, now: moment, isExpanded: true, calendarEvents: events,
                                  calendarTab: tab, calendarSelectedDay: chosen, calendarLiveClock: false,
                                  page: .calendar, connect: { _ in }, refresh: { _ in }, toggle: {})
                ), "\(name)\(suffix).png")
            }
        }
    }
}
