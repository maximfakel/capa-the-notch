# 01: Capacity in gauges

**What to build:** Provider cards on the open surface show each Quota Window as a gauge (variant C) instead of a bar, in every state, so that the Capacity page fits the page area of a 210-point surface (210 = 38 strip + 152 page + 20 page dots). See spec `.scratch/surface-210/spec.md`, stories 6–13; Paper frames "Limits — C · Gauges", "· One provider", "· Stale + Connecting", "· Exhausted + No data".

**Blocked by:** None (can start immediately).

**Status:** done

- [x] Each window is a 270° arc opening downwards, share left in the middle, its label under it, the reset in the gap; coloured by Capacity Pace (≥60% green, ≥10% yellow, below red).
- [x] One Provider on: its card spans the width, each arc with its name, "N% used" and "resets in …" beside it.
- [x] Stale: the card's content dimmed, "Stale" in yellow. Connecting: empty arcs as placeholders.
- [x] Exhausted window: "0%" and the reset in red, its track tinted red. No data: "No data" in red and one sentence of guidance.
- [x] The Capacity page's content fits 152 points in every state (metrics dump), and the picture dump matches the Paper frames.
- [x] Russian and English strings for anything new; existing tests stay green.

## Comments

- 2026-10-02: Done. Colours follow Capacity Pace (60/10) rather than the frames' guessed 30%, as the ticket's own reason asks. The "Read at …" line above the cards is gone — the frames have none, and it would not leave the gauges their 152; each card's chip says Fresh or Stale. A Provider that needs a person first shows its sentence without a Connect button; the header's refresh connects it once done. Every card state measures 148 (the page 206 open until ticket 02 fixes it at 210).
