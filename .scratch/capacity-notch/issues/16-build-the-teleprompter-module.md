# 16: Build the Teleprompter Module

**What to build:** The second Module of the Notch Surface, and the first that is
not Capacity: a teleprompter that scrolls text in the notch, beside the camera,
so the person can read while looking at it.

**Blocked by:** none.

**Status:** needs-info

**Why:** First in the order ticket 15 settled, because it is the most
self-contained: text and scrolling, no sensitive data, and the notch is the one
place on a Mac where reading and looking into the camera are the same thing.

Decided already, by ticket 15 and ADR 0003:

- Off until turned on in Settings, and running nothing while off.
- Built into this repository.
- While it runs it may take the compact strip; otherwise the strip is
  Capacity's.
- No Module host is built ahead of it: it is the second thing the surface
  shows, and the shared shape waits for the third Module.
- The Notch Surface is excluded from screen recording by default (ticket 06),
  which for a teleprompter during a call is the point.

What it needs before building — its own design interview, and a mockup:

- Where the text comes from, and how it gets in.
- How scrolling is controlled, and its speed.
- How it sits against the camera, and how much of it the notch can show.
- How the person moves between Modules in the expanded surface. Designed from
  the project's references; where a mockup is needed, Claude builds it in
  Figma or Paper, the author adjusts it by hand, and that mockup is then the
  source of truth.

## Comments

**2026-09-24 — now after music.** The author chose music first (ticket 17),
so the teleprompter is the third thing the surface shows, and the shared
Module shape is drawn out of Capacity and music when it arrives.

**2026-09-26 — the design interview, settled with the author.**

Decided, question by question; the author took every recommendation except
where noted. Terms are in `CONTEXT.md` (Teleprompter Module, Script,
Teleprompter Row, Running / Paused / Stopped).

The text:

- Continuous text, read word for word on an automatic scroll; talking points
  are the same thing in short lines, paused as needed.
- One Script, kept in Settings. **Paste from Clipboard** replaces it, and
  **Restore Previous Script** brings back the one before — one step, no more.
  The clipboard is read only on that press.
- Plain text: line breaks and blank lines kept, Markdown shown as written.
- Stored on this Mac; never in Copy Diagnostics (which says only on/off and
  the length in words) and never in logs — with a Core test.

Where it shows:

- The Teleprompter Row is beneath the Capacity strip (ADR 0003 as amended by
  ticket 17 — beneath, never replacing; this ticket's "may take the compact
  strip" is superseded): three lines, the current one on top, nearest the
  camera, 560 points wide.
- Text size from the Paper mockup by default; Settings offers small, medium
  (the mockup's) and large. *(The author chose both options here.)*
- While it runs the music row gives way, and the row shows over a fullscreen
  application too — calls are often fullscreen.
- While it runs the surface is always kept out of screen capture, whatever
  "Appear in screen sharing and recordings" says.

Control:

- Click on the row: pause and resume. Global shortcuts, set in Settings and
  registered only while the Module is on: start/pause, stop, faster, slower
  (`RegisterEventHotKey`, no Accessibility needed).
- Speed in words per minute, about 130 by default; smooth scroll, line by
  line under Reduce Motion. Two fingers on the row in the closed surface move
  the Script by hand and pause it; in the open surface two fingers still turn
  pages.
- Pause keeps the place; Stop clears the row and starts over. The progress
  on the page can be dragged, like a track's.
- On start the first line holds about a second. At the end it stops on the
  last line and the row leaves after about three seconds; the next start is
  from the top.
- While it runs, hovering does not open the surface; a click does.

The open surface and Settings:

- Pages Capacity → Music → Teleprompter; the Teleprompter page exists while
  the Module is on: start/pause, speed, progress, Paste from Clipboard, Edit
  Script (opens Settings). This is the answer to moving between Modules: one
  more page on the same strip. *(ADR 0003 as amended by ticket 17 drew the
  shared Module shape at the third Module; the review caught the mismatch,
  and the author chose to amend the ADR — the shape waits for the fourth.)*
- Started from its page or by shortcut — not from the menu bar menu.
  *(The author chose these two of the three offered.)*
- Settings → Modules → Teleprompter: the Module switch, the Script field with
  Paste and Restore, speed, text size, the four shortcuts.

Defaults taken without a question, stated so nothing is silent: switching the
Module off while running stops it and unregisters the shortcuts; a shortcut
already taken says so on the Settings card; VoiceOver hears "Teleprompter,
running/paused", not the Script; the row is on the surface's display.

Next: Claude draws in Paper — on "Notch", Compact — Teleprompter running,
Compact — Teleprompter paused, Expanded — Teleprompter, and the row over a
fullscreen application; on "Settings", the Teleprompter card under Modules.
The author adjusts; code starts when the author says the mockup is ready.

**2026-09-26 — the mockup, accepted.** Drawn in Paper and adjusted by the
author: on "Notch", Compact — Teleprompter running / paused, Expanded —
Teleprompter, Teleprompter over fullscreen; on "Settings", Settings — Modules
— Teleprompter. Two changes from the author: the glyph beside the current
line is the action, as in Music — pause while running, play while paused;
and the row is 560 points wide, so the closed surface widens to the open
surface's width while the Teleprompter runs (the first draft kept the
compact 422).

**2026-09-26 — the author's second pass on the mockup.** Read from Paper:
the row's controls moved to a column on the left that stays put while the
Script moves — pause or play beside the current line, a red Stop under it —
and the text starts 45 points in; the page shows three lines, pause and
Stop side by side, the time read and the whole Script's length
("00:00 … 03:05"), and the speed as a multiplier ("1.00x"). Then the author made
it one speed everywhere: Settings shows and turns the same multiplier as
the page, 0.25x a step from 0.50x to 2.00x, remembered; 1.00x is 130 words a
minute. Words a minute are no longer a setting (the interview's "speed in
words per minute, about 130 by default" is superseded).
Closed 132 points, open 209, both as drawn.

**2026-09-27 — runtime check on the installed 0.2.0 build, by Claude.**

Driven with synthetic keys and clicks, read back from the window server
(the row itself is kept out of capture while it runs, so it cannot be
photographed):

- ⌃⌥Space starts it: the row appears and the surface widens, and both the
  surface and the Dictation capsule turn out of capture. ⌃⌥Esc stops it and
  both are shared again without a relaunch (the macOS 27 fix, 917e990).
- ⌃⌥↑ / ⌃⌥↓ change the speed a quarter at a time, remembered (1.00x → 1.25x
  → 1.00x). Synthetic arrows needed the Fn and keypad flags a real arrow key
  carries; without them the shortcut does not fire.
- The pause button pauses. A click on the Script did not — the surface is
  never key and the first click never reached the row's tap gesture; fixed
  (acceptsFirstMouse). After the fix a click pauses (row still up after 20 s)
  and a second click resumes.
- At the end the row leaves on its own: the author's Script took about 15 s
  and the surface was shared again at 18 s.
- Over a fullscreen application (TextEdit) the strip shows and is shared;
  the row shows over it while running and leaves on Stop.

Not checked: two-finger scrolling on the row, the progress drag on the page,
Reduce Motion, VoiceOver. A focus ring on the Codex refresh button when the
surface is opened by a click was seen in a fresh launch too — older than
this work, not a Teleprompter matter.
