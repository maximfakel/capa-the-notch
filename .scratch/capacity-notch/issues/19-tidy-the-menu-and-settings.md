# 19: Tidy the menu and Settings

**What to build:** The menu bar menu keeps three things — Refresh, Settings,
Quit — and everything else it offered either lives in Settings or goes. Settings
becomes a window with a sidebar of five sections — General, Providers, Alerts,
Modules, Diagnostics — drawn after Fluid Functionalism (fluidfunctionalism.com)
on native SwiftUI controls.

**Blocked by:** 07/Build onboarding and Settings.

**Status:** resolved

**Why:** Twelve menu items, half of them duplicating Settings, and a single
seven-section Settings page read as clutter. The author wants the menu to do
the few things it is for, and Settings to be organised and to look like the
reference.

## The menu

- [x] Refresh Now (⌘R) · divider · Settings… (⌘,) · divider · Quit Capacity
      Notch (⌘Q). Nothing else.
- [x] Gone for good: Open Capacity Details (the surface opens itself; ⌘O on a
      menu bar menu only works while the menu is open), Show / Hide Capacity
      Notch (quitting hides it), Hide for 1 Hour and its "Hidden — back in…"
      line. `SurfaceHide` and its code go with them.
- [x] Gone because Settings already does them: Check for Updates…, Connect /
      Disconnect Codex, Connect / Disconnect Claude Code. The Claude Code
      toggle in Settings already goes through the one-time consent dialog
      (`connect(.claudeCode)` → `requestClaudeCodeConnection()`), so nothing
      is lost.
- [x] No other way into Settings is added — no right-click on the surface.

## Settings

- [x] A sidebar with five sections, content on the right:
  - **General** — Launch at login, Show on (display), Appear in screen sharing
    and recordings, Check for Updates…, the version.
  - **Providers** — a card per Provider: its toggle, its state (Fresh / Stale /
    Disconnected), when it was last read, why it is not being read when it is
    not (e.g. "Install the Codex CLI"), and Refresh. How often a closed
    surface is read.
  - **Alerts** — as today: the master toggle and one per Provider.
  - **Modules** — one card per Module that can be switched on (CONTEXT.md:
    every Module but the Capacity Module is off until turned on): its tile,
    name, one line of what it does, its switch, and any note it needs. Music
    is the first; the Teleprompter (16) and those after it join here.
  - **Diagnostics** — as today: the log, Copy Diagnostics, Reveal Log, Run
    Onboarding Again.
- [x] The look of Fluid Functionalism, built from native SwiftUI controls with
      their own styles, so VoiceOver and the keyboard behave as they do for
      system controls. The library itself is React and is not used.
- [x] Follows the system's light or dark appearance.
- [x] Motion, each with a purpose: the row under the pointer highlights before
      the click; switches move on a spring and can be flipped back mid-way;
      the sidebar's selection moves on a spring; switching sections fades the
      content with a short shift. Reduce Motion keeps the change and drops the
      travel.
- [x] Keyboard: ⌘1–⌘5 switch sections, arrows move through the sidebar, Tab
      through a section's controls.

## Words

- [x] Rewritten, with wording proposed alongside the mockup and approved by
      the author:
  - Claude Code's subtitle in Settings, "Experimental. Reads only the Capacity
    its status line publishes" — it is read through `/usage` now (ticket 13).
  - The guidance "Connect Claude Code from the menu bar to read its Capacity."
    (`CapacitySnapshot.swift`) — the menu no longer connects.
  - The consent dialog's "reads only the local Capacity snapshot written by
    its Claude Code status-line bridge … never … calls Anthropic".

## How it is built

1. Claude draws the mockup in Paper, file "Pairtask", on a new page: the five
   sections in light appearance, the Providers card in Fresh, Stale and
   Disconnected-with-a-reason, the three-item menu, one section in dark
   appearance to settle the palette, and a board of the proposed words.
2. The author approves it; until then this ticket is `needs-info`.
3. The code is taken from the mockup through the Paper MCP — exact values,
   never screenshots — and measured against it, as the surface was.

Order: before ticket 16.

## Comments

2026-09-24 — Opened from a design interview with the author. Decisions, in
the order they were taken: drop ⌘O, Show / Hide and Hide for 1 Hour outright;
a sidebar, native controls styled after the reference, system appearance, a
mockup drawn by Claude first; five sections; Provider cards with state; menu
order Refresh · Settings · Quit; the stale words rewritten here; all four
motions; mockup scope as above; ⌘1–⌘5; no right-click entry; before 16. Wave
(jtrivedi/Wave, MIT) was looked at and not needed: SwiftUI's springs already
retarget with velocity on macOS 14, and Settings has no gesture whose velocity
matters.

2026-09-24 — Mockup drawn in Paper, "Pairtask" / "Settings": General,
Providers (Fresh + Stale), Alerts, Modules, Diagnostics; Providers with a
Disconnected card; Providers in dark; the menu; "Words — for approval". The
author renamed the Music section to Modules while reviewing it, because more
Modules will join it.

2026-09-24 — Approved by the author as drawn: the blue switch (`#6b97ff`, the
reference's) rather than the system accent, the words on "Words — for
approval" including "Turn On" for the consent button, and the one-line
subtitles under each section's title.

2026-09-24 — Built and installed; the author checked it and said it is fine.

- The menu is Refresh Now · Settings… · Quit. `SurfaceHide`, hiding for an
  hour, the visibility toggle and their test are gone.
- Settings (`SettingsView.swift`, `SettingsIcons.swift`): a 760×560 window
  with a transparent title bar and the sidebar to the top; the five sections
  as drawn; Provider cards from the live store with Refresh; the Modules card;
  light and dark. Motion: row hover, spring switches, the sidebar highlight
  moved with `matchedGeometryEffect`, section changes faded and risen (faded
  only under Reduce Motion). ⌘1–⌘5, arrows in the sidebar, space on a
  focused switch; switches read as toggles to VoiceOver.
- The icons are the mockup's own outlines, drawn in a `Canvas` — the author
  preferred them to SF Symbols after seeing both.
- Added at the author's request while checking: an Appearance choice
  (System / Light / Dark) as General's first row, drawn into the mockup first;
  `Preferences.appearance`, tested; it sets `NSApp.appearance`, so Settings
  and onboarding follow it and the surface stays black.
- Words as approved: "Turn on … in Settings", "… then try again", the new
  consent text with Turn On; Claude Code has no subtitle.
- Measured: `CAPACITY_NOTCH_DUMP_SETTINGS=<dir>` renders every section in
  both appearances; the first card starts at 127 pt, as drawn (52 + 28 + 4 +
  18 + 24, plus its 1-point border). The surface's numbers are unchanged
  (38 / 92 / 252 / 185).
- Fixed on the way: a strip under the content (a fixed 560-point view in a
  window whose content includes the title bar), a double fade on disabled
  rows, the Provider name repeated beside a stand-alone switch, and the Codex
  mark invisible in light mode (now a template image).
- Not verified: VoiceOver end to end, and the new consent dialog on screen —
  this Mac has already consented, so it is asked no more.

2026-09-24 — Two follow-ups the author asked for after checking, both drawn
into the mockup first:

- Keycaps: ⌘1–⌘5 beside each sidebar item, in the style of Fluid
  Functionalism's command menu (20-point caps, 5-point corners, 2 apart, 11-point
  muted glyph, a 4% ground — white 6% in dark). Only shortcuts that work in
  this window are shown; ⌘R is not, because it works only while the menu bar
  menu is open.
- Focus: a click on a switch left the system's focus rectangle round the whole
  row. Switches now take focus as buttons do on the Mac — from the keyboard
  (Tab, with Full Keyboard Access), never from a click — and show the
  reference's ring round the switch alone.
