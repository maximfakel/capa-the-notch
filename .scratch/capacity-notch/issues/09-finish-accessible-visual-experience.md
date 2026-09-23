# 09: Finish the accessible visual experience

**What to build:** Deliver a restrained black surface that visually continues the physical notch while remaining understandable and operable for keyboard, VoiceOver, high-contrast, and reduced-motion users.

**Blocked by:** 05/Select the Headline Window by Capacity Pace; 06/Complete window interactions and display behavior; 07/Build onboarding and Settings.

**Status:** resolved

- [x] The compact and expanded surfaces have a consistent notch-integrated visual hierarchy and preserve legibility at supported display scales.
- [x] Keyboard users can open, inspect, switch focus, invoke actions, and close the surface without using a pointer.
- [x] VoiceOver announces Provider, remaining Capacity, Quota Window, reset time, freshness, and actionable connection state.
- [x] Capacity Pace and errors remain distinguishable without color alone and meet appropriate contrast targets.
- [x] Normal motion uses the agreed short spring transition and Reduce Motion replaces it with restrained size or opacity changes.

## Done

### Told apart without colour

The surface writes no word for Capacity Pace and draws no shape for it, and
needs neither.

Shapes were tried first — a dot, a triangle and a square at the same six-point
footprint — and were wrong. At that size a triangle keeps under half a dot's
area and a square reads heavier than either, so telling the three apart cost
more visibility than it bought.

A word in the caption was tried next and was also wrong, for a better reason.
Since ticket 05, Capacity Pace is read off the remainder and nothing else. The
colour therefore restates the figure already on the row, and a word restates it
a third time. The thing that distinguishes the states without colour is the
figure: 4% and 69% are not the same to anyone who can read either of them.

So the mark is a dot in all three states, the colour is the quick read, and the
figure beside it is the one that does not depend on colour at all.

### What a screen reader is told

Each Quota Window announces which window it is, what is left, how that is
going, how much has gone, and when it turns over — and says "reset time not
reported" rather than skipping a reset it does not know. Each card announces
the Provider, how its reading stands, and, when it is not Fresh, the one thing
that would fix it: a state with no action is no help. The closed strip names
which window its figure belongs to, which the surface itself cannot show.

### Keyboard

**Open Capacity Details** in the status menu pins the surface open. The status
menu is reachable with the system's own shortcut, pinning makes the panel key,
Tab moves between the refresh and Connect buttons, and Escape closes it. No
pointer is involved at any step.

### Motion

Reduce Motion keeps the change and drops the travel: the surface still resizes
and the pieces still fade in, in the same order, but nothing slides and nothing
is held back. The window's half-second unfold becomes a 0.15-second resize.

### Contrast, measured

Against the card at `#141414`:

| | ratio | target |
| --- | --- | --- |
| Provider name, 17pt white | 18.42:1 | 3.0 |
| Window label, 15pt white | 18.42:1 | 4.5 |
| Caption, 11pt at 55% white | 6.15:1 | 4.5 |
| Figure, green | 9.11:1 | 4.5 |
| Figure, yellow | 13.05:1 | 4.5 |
| Figure, red | 5.41:1 | 4.5 |

The tightest is red at 5.41:1, comfortably above the 4.5:1 that small text asks
for. Nothing on the surface is below target.

## Verified

68 checks pass, six of them new and covering the wording: that a window says
everything its card shows, that an unknown reset is said rather than skipped,
that a Provider leads with who and how, that an unreadable one says the action
as well as the state, that the strip names its window, and that the three
states are tellable apart without colour.

## Not verified here

VoiceOver itself, Full Keyboard Access, and Increase Contrast were not driven
on this machine — each needs a system permission or setting this session could
not grant. The labels, focus and motion paths are in place and their wording is
tested; someone should sit with VoiceOver once and listen to a card.

**2026-09-21 — a global shortcut was considered and declined.**

`notchy.dev` opens its command palette with a global key, which raised the
question of whether the surface should have one. The author declined it in
favour of a trackpad gesture, now ticket 14.

The keyboard path this ticket closed does not depend on one. The status menu is
reachable with the system's own key, **Open Capacity Details** pins the surface
from there, Tab moves between its buttons and Escape closes it. The shortcuts
on the menu items are scoped to the menu and take nothing from anybody else.
