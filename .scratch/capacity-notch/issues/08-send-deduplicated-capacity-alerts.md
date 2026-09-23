# 08: Send deduplicated Capacity Alerts

**What to build:** Notify the user once when a Fresh Quota Window newly becomes critically unsustainable, without turning Capacity Notch into a noisy alerting system. The notification should take the user directly to the relevant context.

**Blocked by:** 05/Select the Headline Window by Capacity Pace; 06/Complete window interactions and display behavior; 07/Build onboarding and Settings.

**Status:** resolved

- [x] A Capacity Alert fires when Fresh Capacity newly enters the agreed critical state: Capacity Pace below `0.5`, or `10% left` when duration is unknown.
- [x] A Provider and Quota Window generate at most one Alert until reset or recovery followed by a new critical transition.
- [x] Stale Capacity, connection failures, and repeated refreshes do not generate false or duplicate Capacity Alerts.
- [x] Clicking an Alert opens and pins Capacity Notch with the triggering Provider and Quota Window visibly identified.
- [x] Alerts can be disabled globally and per Provider, and notification permission is requested only after the user enables them.

## Done

### The criterion's wording predates ticket 05

It asks for "Capacity Pace below `0.5`, or `10% left` when duration is
unknown". Capacity Pace no longer has a ratio: since ticket 05 it is read off
the remainder, and its lowest band is below 10% left. So the two halves of that
sentence have become the same rule, and that is the one implemented — a window
alerts when it newly falls under a tenth left.

### Most of the work is knowing when not to speak

An alerting surface earns its keep once and loses it on the second duplicate.
`CapacityAlertDecider` therefore refuses far more often than it fires:

- Only a **Fresh** reading speaks. Stale describes the past, disconnected knows
  nothing, connecting has nothing yet, and mock is not real.
- Only the **transition** speaks. A window already running out says nothing on
  every refresh after the first.
- **Recovery re-arms it.** A window that climbs back out is news again when it
  falls again.
- **A reset is a new window.** When `resetsAt` moves on, the window has turned
  over whatever its id says, and may speak again.
- A **silenced Provider keeps its history**, so switching alerts back on
  replays nothing that happened while they were off.
- A Provider **disconnected on purpose forgets** what it has said, so
  reconnecting it can tell you the news.

### Permission, and the two switches

Permission is asked at the moment someone switches alerts on, in onboarding or
in Settings, and never before — a permission prompt at launch is a question
nobody asked for. If the system declines, the switch goes back off rather than
sitting on and delivering nothing.

Alerts can be silenced globally or for one Provider. A Provider is heard only
when both allow it.

### Being taken to the window

One notification per window, replaced rather than stacked, so a Provider cannot
fill the notification centre. Opening it pins the surface and rings the row it
was about for six seconds — opening the surface and then hunting for the row it
meant is not being taken to the window.

## Verified

75 checks pass, seven of them new and almost all about silence: the first fall
below a tenth, the silence after it, recovery re-arming, a reset counting as a
new window, every non-Fresh state saying nothing, a silenced Provider staying
caught up, and a disconnected one forgetting.

## Found while building it

`UNUserNotificationCenter.current()` raises rather than failing when there is
no application bundle, which took the whole process down when the surface was
run straight out of the build directory to be measured. It is now only reached
when `Bundle.main.bundleIdentifier` exists.

## Not verified here

No notification was delivered on this machine: that needs someone to switch
alerts on, grant the system prompt, and let a window actually fall below a
tenth. The decision to send is covered by tests; the delivery and the tap are
not.
