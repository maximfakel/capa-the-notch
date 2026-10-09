# Two taps on the trackpad: which route, and what it costs

Ticket 14. Measured on 2026-10-07 on the author's MacBook Pro (M1 Pro),
macOS 27.0.1 (26A434), built-in trackpad (family 105, 157.8 × 97.8 mm), Tap to
click off, double-click interval 0.5 s. The spike is `Spikes/TrackpadTap`.

The question: can CapaTheNotch tell a one-finger double tap from a click,
from anywhere on screen, and what permission does that cost?

## What was observed here, without a finger

The agent that built this cannot touch the trackpad. What it could observe:

- **MultitouchSupport loads and starts with no permission asked.** Opened with
  `dlopen`, every symbol the reader needs is exported (`MTDeviceCreateList`,
  `MTRegisterContactFrameCallback`, `MTUnregisterContactFrameCallback`,
  `MTDeviceStart`, `MTDeviceStop`, `MTDeviceGetSensorSurfaceDimensions`).
  One device is listed; `MTDeviceStart` returns 0. Run as an application of its
  own (`tech.capathenotch.spike.trackpad-tap-probe`, never granted anything,
  launched through `open` so it is its own responsible process), TCC's log
  shows only the spike's own *preflight* queries (`IOHIDCheckAccess`,
  `AXIsProcessTrusted`) — no request at all from opening, listing or starting
  the device. Input Monitoring stayed "not asked", Accessibility "not granted",
  before and after.
- The same probe inside the built CapaTheNotch.app, switched on through the
  argument domain, reports `trackpad-tap-on` in Copy Diagnostics: the reader
  started under the Hardened Runtime with the application's entitlements
  unchanged.
- **A listen-only `CGEventTap` does ask.** Even with a mask of mouse, gesture
  and pressure events only, creating it sent a real (`preflight=no`)
  `kTCCServiceListenEvent` request — Input Monitoring — which a never-granted
  application got as *denied*, with a notification. So the event-tap variant
  of routes 1 and 2 costs Input Monitoring; the spike tries it only when
  `SPIKE_EVENT_TAP=1` is set.
- `NSEvent.addGlobalMonitorForEvents` for mouse, pressure, gesture and scroll
  events installs without a request.
- Two probes listened side by side for ten minutes — the never-granted
  application, and the spike run from this shell, whose responsible process
  holds Input Monitoring and Accessibility. **Neither received a single
  frame**: nobody touched the trackpad in that time. So no frame has been
  seen yet by either; that frames reach a process with no permission is the
  one thing still to be seen with a finger (below).

## The three routes, as far as they can be judged before a finger

1. **Public `NSEvent` touches through a global monitor.** `touches(matching:in:)`
   is only meaningful on gesture events, and the system makes gesture events
   from two or more fingers (scroll, pinch, rotate, swipe). One finger resting
   or tapping is pointer movement and, with Tap to click, a click. A global
   monitor is therefore not expected to see any one-finger touch. The guided
   run counts touches on every gesture-family event in the tap phase; any
   number above zero would overturn this.
2. **`.pressure` and `.gesture` globally.** `.pressure` is the Force Touch
   sensor reporting a *physical* press (stage 1 at the click, 2 at a force
   click). A tap that does not press produces none — that is what makes it
   useful as the other half: it tells a pressed click from a tap. `.gesture`
   is route 1's events. Neither times two light taps.
3. **MultitouchSupport.** Delivers every contact on every frame (about 8 ms
   apart): identifier, state (hovering / making touch / touching / breaking /
   lingering), normalised position, size, axes, pressure. That is enough to
   time two taps, measure how far each moved, count fingers, and reject a
   palm by its size. It is the only route that can.

So the author's decision of 2026-10-07 applies: neither public route can
tell a one-finger double tap from a click, and the gesture is built on
MultitouchSupport, under ADR 0004.

## The permission it costs

**None, as far as could be seen on macOS 27.0.1:** opening, listing and
starting the device asked TCC for nothing, and the application's own
helpers — global monitors for pressure, mouse-down and scroll — ask for
nothing either. Not Input Monitoring, not Accessibility. A listen-only event
tap *would* cost Input Monitoring, which is why the build uses global monitors
and not a tap.

The caveat, said plainly in the ticket: no frame has yet been received here
by any process, because nobody touched the trackpad during the probes. If the
author's run shows frames arriving in the never-granted spike application,
the cost is settled as nothing. If it shows none there but some from the
terminal, the cost is Input Monitoring and Settings must say so.

## Tap to click

With Tap to click on, one light tap *is* a click, and two are a double-click
delivered wherever the pointer is. The detector only watches; it never
swallows an event. So with Tap to click on, two taps both open the surface
and double-click under the pointer — selecting a word, opening a file. That
cannot be separated without swallowing the click, which the ticket rules out,
so Settings says it next to the switch. With Tap to click off, a light tap
produces no click at all, and two of them only open the surface.

A *pressed* double-click must not open the surface. A touch is called a click
when, during it, a Force Touch trackpad reports pressure stage 1 or higher,
or — with Tap to click off — any left mouse-down arrives. The surface opens
0.2 s after the second lift, so a press reported a little late still calls it
off, and the click a tap produces has landed before the surface takes the
keyboard (a pinned surface closes when it loses the keyboard).

## Thresholds

| What | Value | Why |
| --- | --- | --- |
| Longest tap | 0.3 s | A deliberate tap is 50–150 ms; longer is a press-and-hold |
| Furthest drift during a tap | 2.5 mm | Anything more is the start of a drag |
| First lift to second touch | the Mac's double-click interval (`NSEvent.doubleClickInterval`, 0.5 s here) | Two taps as quick as a double-click is, and as slow as the person set it |
| Second tap from the first | 12 mm | A finger lands near, not on, the same spot |
| Largest contact | 20 (MultitouchSupport's major-axis units) | A fingertip is well under; a palm or a hand's side is well over |
| Fingers | exactly one throughout | A resting thumb, two fingers, or a second finger between the taps ends it |

The contact-size threshold is the one guess: the units are the framework's
own and no frame has been seen yet. The guided run prints every touch's axes,
so one run with fingertips and palms settles it.

## When it stops answering

ADR 0004 asks that a private interface failing says so. What the reader
watches:

- **Missing or changed framework**: `dlopen` or a symbol fails, or no device
  starts → `trackpad-tap-unreadable`, with a sentence in Settings.
- **A layout that no longer fits**: frames whose states or positions no
  contact could have (ten of them) → the same.
- **No trackpad**: an empty device list → `trackpad-tap-no-trackpad`; a
  multitouch scroll arriving later restarts the reader.
- **Silence**: a scroll beginning on a multitouch surface proves fingers are
  on it. Three in a row with no frame within a second of any → restart the
  devices once; three more → `trackpad-tap-silent`. The reader also restarts
  on wake.

## The check that needs a finger

```sh
Spikes/TrackpadTap/run.sh
```

Once with Tap to click off, once with it on. What to read in the table:

- the **tap** phase: six one-finger touches under 300 ms, moved under
  2.5 mm, from MultitouchSupport; the gaps between taps; no `pressure` events;
- the **press** phase: the same touches, with `pressure` stage 1 events and
  mouse-downs — the evidence that a pressed click can be told apart;
- the **two**, **hold** and **palm** phases: the fingers, durations and axes
  the thresholds reject;
- "Before" and "After": Input Monitoring "not asked" throughout while frames
  arrived — the permission answer.
