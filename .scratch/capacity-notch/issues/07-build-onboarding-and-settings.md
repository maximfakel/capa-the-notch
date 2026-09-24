# 07: Build onboarding and Settings

**What to build:** Give a first-time user a short path from launch to useful Capacity, then provide one dependable place to manage Providers, display selection, refresh behavior, Alerts, startup, updates, and diagnostics.

**Blocked by:** 02/Show Fresh Capacity from Codex; 03/Show Fresh Capacity from Claude Code; 06/Complete window interactions and display behavior.

**Status:** resolved

- [x] First run presents Connect Codex and Connect Claude Code, clearly marking Claude Code as Experimental.
- [x] After the first successful Provider connection, the user is separately asked whether to enable Capacity Alerts and Launch at Login; neither is enabled silently.
- [x] Finishing onboarding opens the Capacity Notch and every onboarding choice remains editable in Settings.
- [x] Settings cover Provider connections, selected display, Launch at Login, Alerts, refresh, update behavior, and diagnostics without introducing a dashboard or historical analytics.
- [x] Re-running or abandoning onboarding does not duplicate background processes, prompts, or stored preferences.

## Comments

**2026-09-20, while closing ticket 02.** Capacity Notch now connects Codex at
launch rather than waiting to be asked. A Provider the person has already
installed should not need consenting to on every start, and a machine without
Codex gets the install sentence instead of mock numbers — which is better first
contact than a placeholder.

The menu keeps Connect and Disconnect for doing it by hand. What this ticket
still owns: remembering a deliberate Disconnect across launches, and letting a
person choose which Providers connect at all. Right now a disconnect lasts only
until the next launch.

## Done

### One place for every choice

`Preferences` holds them all, and Settings and onboarding both write through
it, so a switch flicked in either is the same switch. Every default is the
quiet one — no alerts, no launching at login, no screen sharing, no log —
except reading a Provider the person already installed, which is what the
surface is for.

Settings covers Provider connections, the display, screen sharing, the
background reading pace, launch at login, updates, alerts, and diagnostics. It
is deliberately not a dashboard: no history, no charts, no numbers. The surface
shows Capacity; Settings decides how the surface behaves.

### The debt this ticket recorded is paid

A deliberate Disconnect now outlives the launch it was made in. Connecting and
disconnecting write the choice, and launch starts whatever was left connected
rather than starting Codex unconditionally.

### Onboarding

Two steps. The first offers both Providers, with Claude Code marked
Experimental and explained before anything is read. Continue is only available
once a Provider has actually answered — there is no point asking someone
whether to be warned about Capacity before they have seen any.

The second asks about alerts and launch at login separately, and neither is
pre-set. Finishing starts what was chosen and opens the surface on it.

Re-running it opens the same window rather than a second one, and changes
nothing until Finish. Starting a Provider that is already running is a no-op,
so neither path doubles a process or a prompt. Settings can re-run it.

Launch at login goes through `SMAppService`, and the system has the last word:
if macOS declines — which it does for an application outside `/Applications` —
the switch returns to what the system actually reports rather than sitting on
and doing nothing.

## Verified

62 checks pass, five of them new and covering what a preference store can get
wrong: that nothing is enabled on anybody's behalf, that Codex starts connected
and Claude Code does not, that a deliberate disconnect survives into the next
launch, that a choice made anywhere is the same choice, and that the background
pace falls back to the schedule it came from.

On a first run the application opens two windows: the surface at 422×38 and
onboarding at 440×301.

## Two choices are stored and not yet acted on

Alerts and update checking are remembered, and nothing reads them. Ticket 08
sends the alerts; ticket 11 ships the updater. Both toggles say so in their own
caption rather than pretending to work — a switch that silently does nothing is
worse than no switch.

**2026-09-23 — the welcome came back at every launch.**

Reported by the author: "Welcome to Capacity Notch" opened on every restart.
On this machine `hasFinishedOnboarding` did not exist at all, while
`connectsAtLaunch.codex` and `connectsAtLaunch.claudeCode` were both stored as
true. The flag is set only by Continue on onboarding's last step; connecting
from the menu or a card, or closing the window, never set it. And the launch
path returned *before* `connectChosenProviders()` while onboarding was
unfinished, so every launch also read nothing until the window was answered —
which is why this machine's report showed both Providers `stale-from-archive`.

"Abandoning onboarding does not duplicate …" was true and not enough.

Launch now asks `Preferences.needsOnboarding`: onboarding is offered only when
it was never finished *and* the person has never deliberately connected a
Provider. A stored Connect counts; Codex's unstored default does not, so a true
first run is still welcomed. Someone who connected something and closed the
window has been through the first run; Alerts and Launch at Login stay off for
them — the quiet defaults — and remain in Settings. With everything
deliberately disconnected and onboarding never finished, it is offered again,
since the surface would otherwise read nothing.

### Verified

96 checks pass; one is new and covers the rule in all four states. The app
was reinstalled and relaunched on this machine: the only window it owns is
the 422×38 strip (listed with `CGWindowListCopyWindowInfo` by the app's pid —
a first attempt filtered on "CapacityNotch" and matched nothing, which proved
nothing, so the listing was redone by pid), and the Codex App Server was
started by the app at launch. Metrics read `38 / 174 / 228 / 266`.

### Not verified

Claude Code's connection at launch was not observed directly; it has no
long-running process to look for. A true first run was not replayed on this
machine.

**2026-09-23 — "Check for updates" is off by default.**

The comment above says every default is the quiet one; `checksForUpdates`
defaulted to true. Nothing reads it yet — ticket 11 owns the updater — but
when something does, a true default would make checking the application's
first network request of its own, made without asking. It now defaults to
false, and `nothingIsEnabledOnAnybodysBehalf` pins it. A choice already stored
is kept. On this machine nothing was stored, so Settings now shows it off.

**2026-09-24 — quitting switched both Providers off.**

Found while building ticket 17. `quit()` and `applicationWillTerminate` both
went through `disconnectCodex()` and `disconnectClaudeCode()`, which record a
*deliberate* Disconnect (`connectsAtLaunch = false`). So every ordinary quit —
the menu's Quit, a logout, a restart — left both Providers switched off: the
next launch read nothing and, since `needsOnboarding` then found no Provider
connected, opened the welcome window. The 2026-09-23 fix above did not cover
this path; it may be part of what the author saw. It surfaced when SIGTERM was
made to quit properly (ticket 17), which put `pkill` through the same path.

Quitting now stops everything and records nothing; only Disconnect, from the
menu or Settings, is remembered.

### Verified

On the installed application, twice over: launched with both Providers
connected, the only window is the strip, and Codex, Claude Code and the
adapter run; after `pkill`, both `connectsAtLaunch` flags are still true and
no adapter process is left; the relaunch shows no welcome window.

### Not verified

The menu's Quit, clicked: it now reaches the same `terminate` path as SIGTERM,
which was exercised.
