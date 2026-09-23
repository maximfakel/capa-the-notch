# 05: Select the Headline Window by Capacity Pace

**What to build:** Make the compact surface answer the user's immediate question: how much Capacity remains, and which Quota Window is most urgent relative to its reset time. The two initial Providers remain visible without switching.

**Blocked by:** 04/Persist Capacity Snapshots and survive failures.

**Status:** resolved

- [x] The compact surface shows `% left` for connected Codex and Claude Code Providers, with Provider identity and a compact visual indicator.
- [x] The Headline Window is selected using remaining Capacity relative to remaining window time, not merely the lowest raw percentage.
- [x] Green, yellow, and red Capacity Pace states have documented deterministic boundaries and sensible static fallbacks when window duration is unknown.
- [x] The expanded card shows every Quota Window, both used and remaining Capacity, reset countdown, and freshness.
- [x] Boundary cases around reset time, missing duration, clock changes, and exhausted Capacity are covered by automated tests.

## Done

### The rule

Capacity Pace compares what is left with the time left. For a window, the share
of the allowance still unspent divided by the share of the window still to run:
spend evenly and that ratio is 1.

| Ratio | Pace | Meaning |
| --- | --- | --- |
| ≥ 1.0 | sustainable | the remainder outlasts the clock |
| ≥ 0.5 | tightening | behind an even spend, but not badly |
| < 0.5 | unsustainable | the allowance runs out before the window turns over |

Nothing left is unsustainable whatever the clock says. A boundary belongs to the
better state.

When a window's time cannot be known — no duration, no reset, or a reset
already past — there is nothing to reason about and the raw percentage decides:
50% and above is sustainable, 20% and above tightening, below that
unsustainable. The numbers live in `CapacityPaceRule` so they can be quoted.

### Why it matters, in one real case

Codex on this machine: `5 hour 71% left` and `Weekly 11% left`. The old rule
showed 11%, the alarming number. But the weekly window resets in twenty minutes
and eleven percent will comfortably see it out, while the five-hour window has
four hours to run. The Pace rule puts the five-hour window in the strip, which
is the one that can actually run out.

### The surface

The compact strip shows the Headline Window's `% left` beside the Provider's
mark and a dot in the Pace colour. The expanded card colours each window's
number and bar by its own Pace and now says both sides of it — `24% used ·
resets in 2h 14m · 19:00` — so the card answers how much is gone, how much is
left, and how long it has to last.

Both depend on the time, so the surface redraws on a thirty-second beat rather
than only when a Provider answers.

The interim rule is gone: `CapacitySnapshot.compactWindow`, which preferred
Codex's five-hour window and otherwise took the smallest number, and the test
that pinned it.

### A boundary that binary fractions would not land on

`1 - 0.8` is 0.19999999999999996, which against 40% of a window is
0.4999999999999999 — a hair below the boundary it is meant to sit on, and
therefore the worse state. The comparison carries a tolerance of 1e-9, far
below anything a rounded percentage can express. Found by the test that asserts
the boundary, not by reasoning about it afterwards.

## Verified

47 checks pass and `swift build` is clean. Five are new and cover the rule
itself: an even pace, both boundaries, the case where a small percentage is not
the urgent one, the static fallback in all three states, and the edges —
exhausted Capacity, a reset already past, a reset further off than the window
is long, a second before reset, and the countdown's wording.

## Not done

The per-model weekly window Claude Code prints as `Current week (Fable)` still
parses to nothing. The Pace rule would rank it correctly, so what remains is
the surface question: three windows in a card built for two. Worth its own
ticket rather than a silent widening of this one.

## Comments

**2026-09-21 — the rule now reads what is left, and nothing else.**

The ratio rule shipped above weighed the remainder against the time still to
run. It is defensible and it was wrong for this surface: it painted eleven
percent green because that window happened to reset in two hours. A person
glancing at a strip reads eleven percent as nearly gone whatever the clock
says, and the surface has to agree with them.

Capacity Pace is now bands of remaining Capacity: sustainable at 60% and above,
tightening at 10% and above, unsustainable below. `CONTEXT.md` carries the same
definition, because a glossary that describes something the code no longer does
is worse than no glossary.

The Headline Window follows: the scarcest window, with an earlier reset
breaking a tie. There is no longer a separate ranking to do, because the state
now follows the remainder.

**What this gives up, stated plainly:** a window minutes from its reset reads
the same as one with days to run. The reset time is still on the card, so the
information is not lost — it is just no longer folded into the colour.

**2026-09-23 — which boxes above the reversal overturned.**

A whole-body review of 01–10 read the ticked list above against the code and
found three items that describe the ratio rule, not the one that shipped. They
stay ticked because they were true when ticked; this is the record that they
are no longer the specification:

- "relative to remaining window time, not merely the lowest raw percentage" —
  overturned. The Headline Window is the scarcest window, an earlier reset
  breaking a tie (`CapacitySnapshot.headlineWindow`), and the test that pins it
  is `theHeadlineIsTheScarcestWindow`.
- "sensible static fallbacks when window duration is unknown" — moot. The
  bands that were the fallback are now the whole rule, so there is nothing to
  fall back from; `durationMinutes` enters no decision.
- "missing duration, clock changes" in the boundary cases — moot for the same
  reason. Exhausted Capacity and the boundaries themselves are still covered.

`CONTEXT.md` now defines the Headline Window the same way, and the Interim
Compact Rule section, which this ticket had already retired in code, is gone
from it too. The spoken state no longer claims "running out before it resets",
a claim about time the rule does not make.

**Not done:** `pace(at:)` and `headlineWindow(at:)` still take a `now` they do
not read. Removing it touches every caller, so it is left for its own change.
