# 23: Build the Calendar Module

**What to build:** A Module that shows what is next in the person's calendar
on the Notch Surface — the coming event, and when it starts — and a page of
the day in the expanded surface.

**Blocked by:** none.

**Status:** needs-info

**Why:** Next in ticket 15's order of Modules, where it was paired with music.
The notch is where the eye already goes; the next meeting is the other thing
people glance up for.

- [ ] Off until turned on in Settings; calendar access is asked for only then,
      and nothing is read while off (ADR 0003).
- [ ] Read through EventKit, the public calendar interface, so no private one
      is needed (ADR 0004).
- [ ] The compact strip stays Capacity's; an event about to start may add a
      row beneath it, never replace it (ADR 0003, amended).
- [ ] Refused access says so in Settings and shows nothing on the surface.
- [ ] Event titles never reach Copy Diagnostics or the log.

## What has to be answered first

- The mockup, in Paper beside the other Modules: the compact row, if any,
  and the expanded page.
- Which calendars: all, or chosen in Settings.
- When a coming event takes a row beneath Capacity — how long before it
  starts, and whether joining a call from it is in scope.
- Whether the Module shows only events, or reminders too.
