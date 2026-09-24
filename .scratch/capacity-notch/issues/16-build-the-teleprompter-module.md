# 16: Build the Teleprompter Module

**What to build:** The second Module of the Notch Surface, and the first that is
not Capacity: a teleprompter that scrolls text in the notch, beside the camera,
so the person can read while looking at it.

**Blocked by:** none.

**Status:** needs-info

**Why:** First in the order ticket 15 settled, because it is the most
self-contained: text and scrolling, no sensitive data, and the notch is the one
place on a Mac where reading and looking into the camera are the same thing.

Decided already, by ticket 15 and ADR 0003:

- Off until turned on in Settings, and running nothing while off.
- Built into this repository.
- While it runs it may take the compact strip; otherwise the strip is
  Capacity's.
- No Module host is built ahead of it: it is the second thing the surface
  shows, and the shared shape waits for the third Module.
- The Notch Surface is excluded from screen recording by default (ticket 06),
  which for a teleprompter during a call is the point.

What it needs before building — its own design interview, and a mockup:

- Where the text comes from, and how it gets in.
- How scrolling is controlled, and its speed.
- How it sits against the camera, and how much of it the notch can show.
- How the person moves between Modules in the expanded surface. Designed from
  the project's references; where a mockup is needed, Claude builds it in
  Figma or Paper, the author adjusts it by hand, and that mockup is then the
  source of truth.

## Comments

**2026-09-24 — now after music.** The author chose music first (ticket 17),
so the teleprompter is the third thing the surface shows, and the shared
Module shape is drawn out of Capacity and music when it arrives.
