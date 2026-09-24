# 14: Open the surface with a trackpad tap

**What to build:** Two taps of one finger on the trackpad open the Capacity
Notch, anywhere on screen, without a pointer journey to the notch and without a
keyboard shortcut.

**Blocked by:** 06/Complete window interactions and display behavior.

**Status:** needs-info

**Why:** Hovering the notch means travelling to the notch. A tap where the hand
already rests is the shortest path there is, and it is the gesture the author
asked for in place of a global hotkey.

- [ ] Two taps of one finger open the surface, from anywhere, with no pointer
      travel.
- [ ] An ordinary double-click keeps working everywhere it worked before.
- [ ] The gesture costs no macOS permission the surface does not already hold,
      or the cost is stated and agreed before it is built.
- [ ] It can be turned off in Settings, and is off for anyone who has not asked
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
