# 25: Build the Shelf Module

**What to build:** The Shelf Module — files dropped on the notch, kept at
hand and dragged out again — as ADR 0005 decides it.

**Blocked by:** none.

**Status:** resolved

**Why:** Next in ticket 15's order after the calendar. Ticket 24 split the
Shelf from clipboard history (ticket 29) so it can ship on its own.

- [x] Off until turned on in Settings; nothing is held while off (ADR 0003).
- [x] Files are held as references, never copied, up to 20 (ADR 0005).
- [x] A file dragged out stays on the Shelf; removing one is a single action.
- [x] A file moved or deleted since shows as unavailable.
- [x] Empty after Capacity Notch quits, and at once when switched off.
- [x] Copy Diagnostics carries the count only, never names or paths.

## The mockup

Drawn in Paper and corrected by the author on 2026-09-30 ("Pairtask" /
"Notch", the row below the Teleprompter's):

- **"Notch — Expanded — Shelf"** — the Shelf as the fourth page: "Полка ·
  N файлов" and "Очистить", files as 76-point tiles with the type on the
  icon, names in two lines cut in the middle, ✕ on the tile under the
  pointer, a moved or deleted file dimmed and dashed with "Файл перемещён".
- **"Notch — Expanded — Shelf empty"** — a dashed drop area and what the
  Shelf keeps.
- **"Notch — Compact — Dropping on the Shelf"** — while a file is dragged
  over the closed notch, a narrower drop area grows beneath the strip, joined
  to it by inverse (concave) corners. **Those corners are part of the
  surface's own outline**, drawn into its path like the shoulders
  (`NotchGeometry`), not separate filled triangles laid beside it.
- **"Notch — Page switcher — States"** — with four pages and more to come,
  the dots become buttons with each page's icon when the pointer comes
  near: rest, near, hover with the page's name, pressed, keyboard focus
  (← → move between them), and a dot on the button of a Module that is
  running. The switcher belongs to the surface, not to the Shelf; it lands
  with this ticket because the Shelf makes the fourth page.

## Done

Built in `5bfdb56` ("the Shelf Module keeps files and images at hand on the
notch"), then widened by `c0fb3b7`, `e421248` and surface-210/06–08 (three
Shelf Tabs, screenshots, Clippings). The ticket file was not updated then;
checked against the code on 2026-10-07:

- Off by default: `Preferences.shelfEnabled` defaults to false and
  `ShelfController.add`/`addInMemory` do nothing while off.
- References, never copies, twenty per tab: `Shelf.add` holds the URL;
  `ShelfTab.limit` is 20. Images with no file are held in memory, as ADR
  0005 was amended to allow.
- Dragging out leaves the item in place (`ShelfDragFiles`); ✕ on the tile
  removes it.
- A moved or deleted file: `refreshAvailability()` on showing the page;
  the tile is dimmed, dashed and says "File moved".
- Memory only, so empty after quitting; `setEnabled(false)` calls
  `clearAll()` at once.
- Copy Diagnostics: `ShelfModule.observation` gives counts per tab only.
- The mockup's drop tab with inverse corners drawn into the outline, and
  the page switcher's icon buttons, landed in the same commit.

`swift run CapacityNotchTests`: 222 passed, the Shelf and Clipping checks
among them.
