# 23: Build the Calendar Module

**What to build:** A Module that shows what is next in the person's calendar
on the Notch Surface — the coming event, and when it starts — and a page of
the day in the expanded surface.

**Blocked by:** none.

**Status:** resolved

**Why:** Next in ticket 15's order of Modules, where it was paired with music.
The notch is where the eye already goes; the next meeting is the other thing
people glance up for.

- [x] Off until turned on in Settings; calendar access is asked for only then,
      and nothing is read while off (ADR 0003).
- [x] Read through EventKit, the public calendar interface, so no private one
      is needed (ADR 0004).
- [x] The compact strip stays Capacity's; an event about to start may add a
      row beneath it, never replace it (ADR 0003, amended).
- [x] Refused access says so in Settings and shows nothing on the surface.
- [x] Event titles never reach Copy Diagnostics or the log.

## What has to be answered first

- The mockup, in Paper beside the other Modules: the compact row, if any,
  and the expanded page.
- Which calendars: all, or chosen in Settings.
- When a coming event takes a row beneath Capacity — how long before it
  starts, and whether joining a call from it is in scope.
- Whether the Module shows only events, or reminders too.

## Comments

**2026-10-07 — the author's answers to the questions above.**

- Which calendars: all of them. No per-calendar picker in Settings.
- Events only, not reminders.
- The row beneath Capacity appears ten minutes before an event starts; how
  long it stays once the event is running was left to the build, kept
  minimal.
- Joining a call is in scope: when an event carries a call link — Zoom,
  Google Meet, Teams, FaceTime, Telemost and the like, in its URL, location
  or notes — the row and the day page show Join, which opens it.
- The expanded page shows the day: the coming event and the rest of today.
- No Paper mockup yet. The surface is built from the other Modules' look —
  their sizes, type and spacing, the 210-point open surface, Kapa (ADR 0006)
  — and the author reviews it on screen afterwards.

## Done

**2026-10-07 — built.** Waiting on the author's look at the surface and on a
first real calendar prompt; see "Not verified".

### What it does

- Off by default (`Preferences.calendarEnabled`). While off no `EKEventStore`
  exists, macOS is not asked even what it decided, and no observer or timer
  runs. Turning it on in Settings ▸ Modules ▸ Calendar asks for full access
  (`requestFullAccessToEvents`, macOS 14) — only then, and only if macOS has
  not answered; a launch never prompts.
- Every calendar is read (`predicateForEvents(…, calendars: nil)`), events
  only: today, and ten minutes past midnight so an event at 00:05 still gets
  its row at 23:55. Declined and cancelled events are left out.
- **The row** — 54 points under an unchanged Capacity strip, as the music
  row, so the closed surface is 92 with an event, measured: the calendar's
  colour on a 34-point tile, the title, "In 8 min · 10:30–11:00", and Join
  when there is a call. It appears ten minutes before an event starts and,
  chosen here, stays five minutes after it starts — for whoever joins late —
  or until the event ends if sooner. One still to come outranks one already
  started. All-day events never take the row. In the one row beneath the
  strip it ranks under the Teleprompter Row and over music (ADR 0003,
  amended), and like music it keeps off a fullscreen application. Silent
  (ADR 0007).
- **The day page** — last in the page order, there only while the Module is
  on and allowed. The coming event large on the left (its colour, "In 8 min"
  or "Now · 25 min left", the title on up to two lines, the time, Join, and
  Kapa — attentive within ten minutes or while it runs, at rest otherwise,
  ADR 0006 amended); the rest of today on the right, all-day first, one line
  each with its time ("Now" for one under way) and a call icon that joins,
  five lines at most with "+N more". Events already over are gone. With
  nothing left: Kapa at rest and "Nothing else today".
- **Call links** (`CallLink`): the event's URL, then its location, then its
  notes; only links to calls count — Zoom (and `zoommtg:`), Google Meet,
  Teams (also unwrapped from Outlook Safe Links), FaceTime, Telemost, Webex,
  Jitsi, Whereby, Skype, Chime, SaluteJazz, VK calls, Slack huddles. A
  document or a map is not a call and gets no Join. Join opens the link with
  whatever owns it.
- **Refused** (or restricted, or write-only): the switch stays on and
  Settings says, in red, that macOS does not let CapaTheNotch read the
  calendars and where to allow it, with Open Privacy Settings; the surface
  shows no row and no page. Allowed later, the next look finds it; taken
  back, the events go.
- Looks again when a calendar changes (`EKEventStoreChanged`), on wake, when
  the day, clock or time zone changes, and otherwise only at the next moment
  the row could come or go (`CalendarSurface.nextChange`) — one timer, no
  beat.
- **Copy Diagnostics** carries one note: `calendar-off`,
  `calendar-on-not-asked`, `calendar-on-refused` or `calendar-on-N-events`.
  Nothing is logged. Titles stay on the surface.
- Russian and English throughout; the usage string
  (`NSCalendarsFullAccessUsageDescription`, and the older
  `NSCalendarsUsageDescription`) in `Packaging/Info.plist`, and the Hardened
  Runtime's `com.apple.security.personal-information.calendars` entitlement,
  without which a hardened application is refused without a prompt.

Where it lives: `Sources/CapacityNotchCore/Calendar/CalendarModule.swift`
(the decisions, behind a `CalendarSource` seam), `CalendarController.swift`
(EventKit and the watch), `CalendarViews.swift` (row, page, pictures),
`CalendarSettings.swift` (the card). `CONTEXT.md` gains Calendar Module.

### Verified

- 15 new checks pass with the rest (`swift run CapacityNotchTests`, all
  green): the ten-minute window and the five after; one to come outranking
  one started; all-day events; declined and cancelled; the coming event and
  the rest of today; events crossing midnight both ways and one just after
  it; when to wake; call links in URL, location and notes, Safe Links, and
  links that are not calls; off asks and reads nothing; a refusal shows
  nothing and a later grant is found; a launch never prompts; page order;
  the row's rank; the diagnostics note; Russian.
- `swift build` and `./Scripts/build-app.sh` succeed; the bundle carries the
  usage strings and the calendar entitlement, and `codesign --verify` passes.
- Measured: the row 54, closed 92, open 210, as the music row.
- Pictures from made-up events (`CAPACITY_NOTCH_DUMP_METRICS=1
  CAPACITY_NOTCH_DUMP_PICTURES=<dir>`: `compact-calendar.png`,
  `expanded-calendar.png`, `-later`, `-running`, `-empty`) looked at: nothing
  cut or overlapping, in Russian.

### Not verified

- macOS's calendar prompt, and reading a real calendar: nothing was turned
  on, on this Mac. The first time should be watched — the prompt appearing
  over Settings, Allow, today's events arriving, a refusal saying so.
- The look. No drawing exists; the row, the page and the Settings card in
  each state need the author's eyes, and a Paper frame if they are to be
  measured against one.
- Join clicked on the running surface, and the row coming and going on time.
- VoiceOver on the row and the page.
- Onboarding has no Calendar step, as it has none for the Shelf.


**2026-10-07 — the author's rule after trying it: over fullscreen too, with ✕.**
The row of an event about to start shows over a fullscreen application as
well (it used to keep off it, like music): a meeting matters most while
something else fills the screen. It carries a ✕, in both modes, that hides
that occurrence from the row until it is over; the next event shows as usual
and the day page keeps it. Hidden occurrences are remembered in memory only,
by identifier and start, so another occurrence of a repeating event is not
hidden with it. The tile shows the weekday and the day of the month. Drawn
first in Paper: "Notch — Compact — Event soon" (edited by the author),
"Notch — Calendar over fullscreen", "… — hidden". Checked:
`Calendar.compactRow`, `Calendar.hideFromRow`.


**2026-10-07 — Week and Month, from the author's mockups.** The page has
three views now, chosen by tabs День · Неделя · Месяц centred in a header
row ("Notch — Expanded — Calendar", edited by the author; "… week",
"… month", "… month of six weeks"). It opens on the tab last used,
remembered across launches (`Preferences.calendarTab`; the Day before any).

- **Header.** Day: "Сегодня" and "вс, 4 октября". Week: "4–10 октября"
  ("28 сент. – 4 окт." across months, so it stays clear of the tabs) and
  "N встреч", each event counted once. Month: "Октябрь" and "2026". Month
  and weekday names, both forms of a Russian month and the plural forms
  are explicit tables in the core (`CalendarNames`,
  `Localization.eventCount`), English as well.
- **Day** as the author drew it: the coming event's card 256 wide, its time
  followed by what the call is on ("17:57–18:27 · Zoom", `CallLink.service`),
  the title on one line, Join 30 high; the list beside it in 18-point rows
  with the call's slot kept, "и ещё N" last. Kapa stays at the card's
  bottom right (ADR 0006, amended): the drawing has none, Kapa is drawn in
  code. With nothing left today, "На сегодня всё" and tomorrow's first
  event ("Завтра первое — в 10:00, «Стендап»"), as "… nothing left today"
  draws it, with Kapa at rest beside it.
- **Week**: seven days starting today, seven equal columns; weekday and
  number over chips (the calendar's colour as a bar on its 0x38 wash, time
  over title, "весь день" for all-day); as many as fit — three — and with
  more, two and "ещё N"; "свободно" for a day with nothing. Today keeps
  only what is not over, as the Day does.
- **Month**: the month's grid, Monday first whatever the Mac's first
  weekday, from the week of the 1st to the week of the last: five rows or
  six, every row 18 high so six fit and the grid never jumps. Up to three
  dots of that day's calendars' colours. Past days and the neighbours'
  fainter. Clicking a number chooses its day for the list beside the grid
  (the Day's rows); today is the default, and a day the grid no longer
  holds falls back to it. A chosen day other than today has a faint
  circle — not drawn in Paper, added so the choice shows.
- **Weekends and holidays in red**, in the Week and the Month, at the
  tone's strength (0x8C past, 0x59 the neighbours'). A holiday is a day an
  all-day event in a holiday calendar is on. EventKit has no flag for one:
  a calendar counts when it is subscribed (`EKCalendarType.subscription` or
  a `.subscribed` source) or read-only, and its name holds "holiday" or
  "праздник" — macOS's "Праздники России" / "Russian Holidays", Google's
  "Holidays in Russia". A person's own writable "Holidays" does not. With
  no such calendar only Saturdays and Sundays are red; there is no table
  of holidays.
- **Reading** widens to whatever reaches furthest of today (and the row's
  ten minutes past midnight), the seven days from today and the Month's
  grid — up to six weeks (`CalendarReading`). Still only while on and
  allowed, still EventKit. Diagnostics still say how many today, never
  which.
- **Height.** Every page keeps 152 (open 210). The drawings' header (20)
  and view (8 above, 128) come to 156, so the gap under the header is 4
  rather than 8; nothing else moved.
- VoiceOver: the tabs are buttons with the chosen one selected; each Month
  number is a button speaking its date, "holiday" when it is one, and how
  many events.

Checked (`swift run CapacityNotchTests`, all 293 green; 11 new):
`Calendar.weekFromToday`, `.weekChips`, `.monthOctober` (28 Sep … 1 Nov, five
rows, on a Sunday-first calendar), `.monthMarch` (23 Feb … 5 Apr, six),
`.monthChosenDay`, `.weekendsAndHolidays` (9 March, 23 February, without a
holiday calendar), `.monthDots`, `.rememberedTab`, `.readInterval`,
`.headings` (both languages, plural forms), `.callService`. `swift build` and
`./Scripts/build-app.sh` succeed; measured open 210. Pictures
(`expanded-calendar-day-tabs`, `-week`, `-week-holiday`, `-month`,
`-month-chosen`, `-month-six`, each also `-en`, and `-empty-tomorrow`) held
against the Paper frames.

Not verified: a real holiday calendar read through EventKit — that
macOS's own arrives subscribed or read-only with that name is from how it
shows in Calendar, not from this Mac's events; and Apple's calendars also
carry observances that are not days off, which would be red too. Clicking
the tabs and the Month's days on the running surface, and VoiceOver on
them. The Settings card's description still speaks of "a page for the day".

**2026-10-07 — checked by the author: over fullscreen, and the ✕.** The row
of an event about to start shows over a fullscreen application, and its ✕
hides it.


**2026-10-08 — the page as the author edited it.** The author redrew the
Day, the Week and the Month in Paper ("Notch — Expanded — Calendar", "…
week", "… month", "… month of six weeks") and added the empty states ("…
nothing left today", "… week with nothing"); the page now follows them. Why:
the first build squeezed a 156-point drawing into the 152-point page, and a
six-week month (March 2026) only just fitted, in rows too tight to read.

- **The frame** is the Shelf page's: 10 above, an 18-point header (heading
  and count left, tabs centred), 8 under it, 112 for the view, 4 below —
  152 exactly, nothing squeezed (`CalendarPageLayout`).
- **Day.** The card and the list take equal halves, 256 · 12 · 256. The card:
  "Через 8 мин · 17:57–18:27" on one line, the title on one (truncated within
  the card), Join. What the call is on is no longer drawn; VoiceOver still
  says it. With nothing left: one box (#FFFFFF14, radius 5) with "На сегодня
  всё" and tomorrow's first ("Завтра первая — 10:00 · Стендап"), or, with
  nothing tomorrow, the next one read ("Ближайшая — пн, 12 октября, 10:00 ·
  Стендап"), or "Впереди пусто".
- **Week.** Heading "4-10.10", across months "28.09-4.10" ("Oct 4–10" in
  English); "N встреч", or "нет встреч". Two chips a day at most, then "ещё
  N". A free day is a box filling its column, "свободно" at its top left. A
  week with nothing keeps its row of dates and has one box across it: "Неделя
  свободна" and "Ближайшая встреча — пн, 12 октября, 10:00 · Стендап", or
  "Впереди пусто".
- **Month.** The grid fills the view's 112 whatever weeks it has
  (`CalendarMonthMetrics`, the author's revision of the same day): five weeks
  — weekdays 12, rows 20, the number in a 16 frame at 11, a point, the dots
  (October 2026); six weeks — weekdays 10, rows 17, a 14 frame at 10.5 drawn
  a little tighter, the dots straight under (March 2026). A four-week month
  keeps rows of 20 and leaves room below. Today and the chosen day are
  circles the size of the frame — red with a white number, or #FFFFFF24 with
  the number in its own colour, both 600; a two-digit number in a six-week
  month grows its circle to 16 over the dots' row rather than stretching it.
  A chosen day with nothing: its date (red for a weekend or holiday),
  "Свободный день" ("На сегодня всё" for today) and "Дальше — вт, 10 марта,
  10:00 · Стендап", or "Впереди пусто". A holiday calendar's day leaves no
  dot: its red number says it, as drawn.
- **What comes next** passes over a holiday calendar's days and prefers a
  day's first timed event to its all-day one (`CalendarAhead`). For it,
  reading reaches thirty days past today (`CalendarReading.daysAhead`) —
  still only while on and allowed, still EventKit; diagnostics still count.
- **Kapa — the author's decision.** Kapa stands on the Calendar page only in
  free time: in the Day's box with nothing left (116, 22 from the right,
  sitting on and cut by the box's bottom edge) and the free Week's (92, 18
  from the right), and nowhere else — not on the card, not in a week with
  meetings, not in the Month. There it wears the pose the author chose for
  free time, sunglasses ("Kapa — 03 Free time", pose A): a new
  `KapaExpression.free`, drawn by the Kapa renderer with lenses in place of
  the eyes (so no blink), the wider smile, no sign (`KapaMood.calendar`).
  ADR 0006 is amended. This settles the question of Kapa on the day card.

Unchanged: weekends and holidays in red, the remembered tab, the row under
Capacity with its ✕ and its fullscreen rule.

Checked (`swift run CapacityNotchTests`, 298 green; 5 new, 5 rewritten):
`Calendar.weekChips` (two, then "ещё N"), `.weekFree` (the free week and its
hint, holidays passed over), `.dayNothingLeft` (tomorrow, later, nothing),
`.kapaFreeTime` (sunglasses only for an empty day or week, no blink),
`.monthRows` (October 20, March 17, both 112; a four-week February; the
circles), `.monthFreeDay` (7 March and "Дальше — вт, 10 марта"),
`.headings` (the compact range within and across months and years),
`.readInterval` (thirty days on), `.monthDots`. `swift build` and
`./Scripts/build-app.sh` succeed; measured open 210, and the Day's card 256
with the list 12 beyond it. Pictures (`expanded-calendar-day-tabs`,
`-day-empty-tomorrow`, `-day-empty-later`, `-day-empty-nothing`, `-week`,
`-week-free`, `-week-free-nothing`, `-month`, `-month-chosen`,
`-month-six`, `-month-six-free`, `-month-six-chosen`,
`-month-free-nothing`, `-week-holiday`, each also `-en`, and Kapa's sheet)
held against the frames.

Differences from the drawings: the date says "вс", not the drawings' "вскр"
(the weekday table's short form, as everywhere else); the made-up events in
the pictures are not the drawings' own.

The picture run (`CAPACITY_NOTCH_DUMP_METRICS=1`) now quits once it has
measured and drawn; it used to stay running, and each run left one more
notch on the author's screen. The normal app is unaffected.

**2026-10-08 — the author's month review.** Days already past in the month
shown are no longer drawn fainter: only the neighbouring months' days are.
The chosen day's circle is stronger (#FFFFFF38 for #FFFFFF24): on a faded
past number it had looked absent. Every "what comes next" line now reads
the same, "Ближайшее — …": "Ближайшее — завтра, 10:00 · Стендап", "Ближайшее
— пн, 12 октября, 10:00 · Стендап" (English "Next — …"); "Завтра первая",
"Ближайшая встреча" and "Дальше" are gone.

**2026-10-08 — the chosen day, third try.** A solid white circle with the
number in black (weekend or not); today keeps its red circle with a white
number. The faint fill and then the white ring both read too weakly.

**2026-10-08 — closed.** The author checked the day, week and month pages,
Kapa in glasses, and the meeting over full-screen applications with ✕, and
asked for the ticket to be closed. Merged into `main` with
`modules-2026-10-07`.
