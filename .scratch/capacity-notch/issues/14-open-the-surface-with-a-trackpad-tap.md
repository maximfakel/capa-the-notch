# 14: Open the surface with a trackpad tap

**What to build:** Two taps of one finger on the trackpad open the Capacity
Notch, anywhere on screen, without a pointer journey to the notch and without a
keyboard shortcut.

**Blocked by:** 06/Complete window interactions and display behavior.

**Status:** resolved

**Why:** Hovering the notch means travelling to the notch. A tap where the hand
already rests is the shortest path there is, and it is the gesture the author
asked for in place of a global hotkey.

- [x] Two taps of one finger open the surface, from anywhere, with no pointer
      travel.
- [x] An ordinary double-click keeps working everywhere it worked before.
- [x] The gesture costs no macOS permission the surface does not already hold,
      or the cost is stated and agreed before it is built.
- [x] It can be turned off in Settings, and is off for anyone who has not asked
      for it.

## What has to be answered first

A one-finger tap on a trackpad *is* a click when tap-to-click is on. Watching
globally for double-clicks and opening on them would fire while someone selects
a word or opens a file, so the gesture has to be read from the touch itself and
not from the click it produces.

Three routes, in the order they should be tried:

1. **Public `NSEvent` touches.** `NSEvent.touches(matching:in:)` reports
   individual fingers, but only on events the application already receives.
   Whether a global monitor sees enough of them to time two taps is the first
   thing to measure.
2. **Pressure and gesture events.** `.pressure` and `.gesture` arrive globally
   on a Force Touch trackpad. Whether a tap that is not a click produces either
   is the second thing to measure.
3. **`MultitouchSupport`.** The private framework third-party knock detectors
   use. It works and it is private: it can break in any macOS release, and it
   is not a thing to adopt quietly.

Route 3 is a decision, not an implementation detail, which is why this ticket
is `needs-info` rather than ready. If 1 and 2 both come up short, the choice is
the author's: a private framework, or no gesture.

## Not this

A global keyboard shortcut. The author declined one. The menu's own shortcuts
stay — they are scoped to the menu, and the status menu is reachable with the
system's own key, which is what keeps the surface operable from the keyboard
for ticket 09.

**2026-09-24 — ADR 0004 answers the policy question.**

A private interface is allowed where no public one exists, inside a Module or
feature that is off until asked for, with a visible failure state. So the
question this ticket waited on is settled as policy; what it still needs is
the fact of whether a private path for a one-finger double tap exists at all,
and what permission it would cost — which its own checklist says must be
stated and agreed before building.

## Comments

**2026-10-07 — the author's decision.** If neither public route can tell a
one-finger double tap from a click, use `MultitouchSupport`, under ADR 0004's
conditions: off by default, a switch in Settings, and when the framework
stops answering, the Settings row and Copy Diagnostics say so rather than
going quietly silent. The permission it costs is stated here and in Settings
next to the switch.

**2026-10-07 — the routes, measured.** Spike: `Spikes/TrackpadTap`
(`Spikes/TrackpadTap/run.sh`); findings in full:
`docs/research/trackpad-double-tap.md`. On macOS 27.0.1, M1 Pro, built-in
trackpad:

- Route 1 (public `NSEvent` touches, global monitor): touches exist only on
  gesture events, which the system makes from two or more fingers. One
  finger tapping is a pointer and, with Tap to click, a click. Cannot time
  two one-finger taps.
- Route 2 (`.pressure` / `.gesture`): `.pressure` is the physical press, so a
  light tap makes none — useful the other way round, to tell a pressed click
  from a tap, which is how the build uses it. A listen-only `CGEventTap` for
  these events costs Input Monitoring: creating one sent a real
  `kTCCServiceListenEvent` request, denied to a never-granted application.
- Route 3 (`MultitouchSupport`): opened with `dlopen`, all symbols present,
  one device, `MTDeviceStart` → 0. Run as an application of its own that has
  never been granted anything, TCC logged no request from opening, listing or
  starting the device. **Permission cost: none** — not Input Monitoring, not
  Accessibility. The one thing not yet seen: a frame. Two probes listened ten
  minutes side by side (never-granted application, and a shell holding Input
  Monitoring and Accessibility); neither got a frame because nobody touched
  the trackpad. The author's run below settles it.

Neither public route can, so the decision above applies.

## Done

- `TrackpadDoubleTap` (`Sources/CapacityNotchCore/TrackpadTap/`): a pure state
  machine over touch frames. Two taps of exactly one finger, each at most
  0.3 s and 2.5 mm of drift, the second touching down within the Mac's
  double-click interval of the first lift and within 12 mm of it. Rejects two
  fingers (a resting thumb too), a drag, a press-and-hold, a palm (contact
  size over 20 in the framework's units), taps too far apart in time or
  place, and a touch that physically clicked. A third tap starts over.
- `TrackpadTapController` (`Sources/CapacityNotch/`): reads MultitouchSupport
  through `dlopen`/`dlsym`, only while switched on. It only watches: global
  and local monitors for pressure, mouse-down and scroll, each returning the
  event untouched; nothing is swallowed. A press — pressure stage 1, or with
  Tap to click off any mouse-down — calls a touch a click. The surface opens,
  pinned, 0.2 s after the second lift.
- ADR 0004's failure state: `trackpad-tap-unreadable` (framework or symbol
  missing, no device starts, or frames that no longer fit the layout),
  `trackpad-tap-no-trackpad`, `trackpad-tap-silent` (three multitouch scrolls
  with no frame near any, after one restart). Each has a sentence under the
  switch in Settings and a line in Copy Diagnostics; `trackpad-tap-on` when it
  works. The reader restarts on wake.
- Settings › General: "Open with two taps on the trackpad", off by default,
  with the cost beside it: no permission; a private part of macOS; with Tap
  to click on, the two taps also double-click under the pointer. Russian and
  English.
- 9 new checks (`TrackpadTap.*`); `swift run CapacityNotchTests` passes 231.
  `swift build` and `./Scripts/build-app.sh` pass. The built application,
  switched on, reports `trackpad-tap-on`.

### Not verified

No finger has touched it. Two taps opening the surface, the thresholds, the
palm size, and pressure arriving globally for a press are all untested by
hand.

### The check that needs a finger

1. `Spikes/TrackpadTap/run.sh` from the repository root, with System Settings ›
   Trackpad › Tap to click **off**; follow the prompts (about a minute).
   Then again with it **on**. Paste both tables here. Look for: six
   one-finger touches in the tap phase; `pressure` stage 1 in the press
   phase and none in the tap phase; Input Monitoring "not asked" before and
   after while frames arrived; the axes of fingertips against palms.
2. Install the build, turn on Settings › General › "Open with two taps on the
   trackpad". Grant nothing new. Then, with the pointer anywhere:
   - two light taps of one finger → the surface opens;
   - a pressed double-click on a word in a text editor → the word is selected
     and the surface stays shut, with Tap to click on or off;
   - with Tap to click on, two light taps on a word → the word is selected
     *and* the surface opens (said in Settings; it cannot be otherwise
     without swallowing the click);
   - two fingers tapping twice, a thumb resting while one finger taps, a
     press-and-hold, a palm, two taps a second apart → nothing;
   - Copy Diagnostics → `note trackpad-tap-on`.

If frames arrive only from the terminal and not from the never-granted
spike, the cost is Input Monitoring after all: the Settings sentence and this
ticket must change before it ships.

**2026-10-07 — checked by the author on this Mac.** Two light taps of one
finger open the surface; a pressed double-click on a word selects it and
the surface stays shut; two fingers, taps a second apart and a long press do
nothing. Two things the first build got wrong, both fixed in `03e5490`:
the surface opened pinned and stayed open — now it opens for a glance, four
seconds, and closes like one the pointer left unless the pointer comes onto
it (two taps on an open surface close it); and typing set it off — a palm or
thumb brushing the trackpad — so two taps within a second of a key going
down do not count (`TrackpadTyping`), read without any permission. After
that, the author confirmed: taps open it, and typing does not.

Not done: `Spikes/TrackpadTap/run.sh` was not run, so the palm size (20) is
still the guess, and no table records which permission state the frames
arrived under; the app itself asked for nothing new.
