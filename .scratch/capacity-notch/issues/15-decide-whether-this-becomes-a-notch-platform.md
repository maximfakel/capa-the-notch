# 15: Decide whether Capacity Notch becomes a notch platform

**What to build:** Nothing yet. A decision, and the evidence for it.

**Blocked by:** 11/Publish a free GitHub beta release.

**Status:** needs-info

**Why:** Three features have been asked for that have nothing to do with
Capacity — Face Unlock, a teleprompter, and clipboard history. Each is
plausible on a notch surface and none of them is about how much allowance is
left. Taken together they are not three features; they are one question about
what this product is.

`CONTEXT.md` says it plainly: *a glanceable macOS surface that keeps
AI-service capacity visible*. Every term in the glossary is about Capacity.
Adding the three would make that sentence false, and the honest move is to
change the sentence deliberately or to leave the features out — not to drift.

## The question

Does Capacity Notch stay one thing done well, or become a surface that hosts
unrelated things?

Both are respectable. The first keeps the product explainable in a line and
keeps every ticket here pointed the same way. The second is what the notch
affords, it is what `notchy.dev` chose with 74 features, and it is where the
author's interest has gone.

## What each candidate costs, briefly

- **Clipboard history.** The cheapest of the three and the furthest from
  Capacity. It means holding everything the person copies, which is the most
  sensitive data this application would ever touch, and a reason for an ADR of
  its own.
- **Teleprompter.** Self-contained and harmless. Mostly a scrolling text view
  in an expanded surface; it needs a way in and a way to load text.
- **Face Unlock.** The largest by far. On-device Vision, a liveness check, and
  a security claim the project would then have to stand behind. `notchy.dev`
  states its own limitation openly: no infrared depth sensor, so it is not Face
  ID. Any version here inherits that caveat.

## What would settle it

Ship the beta first (ticket 11) and find out whether anyone wants the thing it
already does. A platform decision taken before the first release is taken
without evidence.

## Not a commitment

Like ticket 12, this records interest and the shape of the decision. It is not
a promise to build any of the three.
