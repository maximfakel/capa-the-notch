# 15: Decide whether Capacity Notch becomes a notch platform

**What to build:** Nothing yet. A decision, and the evidence for it.

**Blocked by:** 11/Publish a free GitHub beta release.

**Status:** resolved

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

## Comments

**2026-09-24 — the whole deferred list, from the spec.**

The question above was framed around three features. The spec the author
confirmed before ticket 01 — saved on this date as `.scratch/capacity-notch/spec.md`
— already deferred more, "until the MVP is finished", and the beta is now out
(ticket 11: released, one friend installed it; the clean-Mac smoke test is
still open). So the decision covers all of it, in two groups that should be
settled separately, because they are different questions:

*About Capacity — does the product grow within its own sentence?*

- **Cost and active AI sessions.** Closest to the product; the glossary has
  no word for either yet.
- **History and charts.** Ticket 07 promises Settings "without introducing a
  dashboard or historical analytics", and the product is defined as
  glanceable. A decision, not an addition.
- **New AI Providers.** `CONTEXT.md` scopes Codex and Claude Code as the
  *initial* ones; `notchy.dev` covers Copilot and Cursor too. Each would need
  a Provider-owned interface under ADR 0001.

*Not about Capacity — does the product become a platform?*

- music;
- Shelf and clipboard (clipboard history is one of the three above);
- calendar;
- Face Unlock and a teleprompter, from above;
- Speech Dictation — ticket 12's spike. The spec calls it "a deferred
  hypothesis, not a roadmap promise", and ticket 12 matches it nearly point
  for point. Whatever this ticket decides for the second group decides
  whether that spike is worth running.

Never, per the spec, and not part of this question: Intel, the Mac App Store,
the surface on several displays at once.

`CONTEXT.md`'s `_Avoid_` for Capacity Notch — "Universal notch hub, Dynamic
Island clone" — is the one line that already leans on the second group.
Deciding for a platform means changing that line on purpose.

## Answer

Decided with the author on 2026-09-24, in a grilling session.

**Capacity Notch becomes a platform** (ADR 0003). The Notch Surface hosts
Modules; the Capacity Module is the first. `CONTEXT.md` now says so, with
**Notch Surface**, **Module** and **Capacity Module** as terms, and "notch hub"
is no longer something it avoids.

- **Name:** kept. Renaming changes the bundle id — every stored preference —
  the repository and the update link, so it waits until the second Module
  ships, if it happens at all.
- **The compact strip:** belongs to Capacity, except while a Module is doing
  something that needs attention now — recording, a running teleprompter.
  Music does not take it.
- **Where Modules come from:** built in, never third-party.
- **Defaults:** every Module but Capacity off until turned on; permissions
  asked for then; nothing runs while off.
- **Architecture:** no Module host ahead of need; the teleprompter is the
  second thing the surface shows, and the shared shape comes out of two
  Modules when the third arrives.
- **Moving between Modules** in the expanded surface is designed from the
  project's references; where a mockup is needed, Claude builds it in Figma or
  Paper, the author adjusts it by hand, and it comes back as the source of
  truth.
- **Order:** teleprompter (ticket 16); dictation (ticket 12's spike, then the
  Module); music and calendar; Shelf and clipboard, which need an ADR for the
  data they hold; Face Unlock.

**The Capacity group, all declined for now:**

- **Cost** — everyone here is on a subscription, so there is no balance to
  show; an API-equivalent estimate would need session transcripts, which ADR
  0001 keeps out. Not doing.
- **Active AI sessions** — activity rather than Capacity, or transcripts
  again. Not doing.
- **History and charts** — nothing was missed in the beta. No history now; a
  dashboard never, per ticket 07.
- **New Providers** — only Codex and Claude Code are used here. On first
  request, and each through a Provider-owned interface under ADR 0001.
