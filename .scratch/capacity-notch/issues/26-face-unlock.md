# 26: Face Unlock

**What to build:** Undecided. Ticket 15 listed Face Unlock last among the
Modules; this ticket holds the question of whether to build it at all.

**Blocked by:** none.

**Status:** needs-triage

**Why:** Asked for among the first three non-Capacity features (ticket 15).

## What has to be answered first

- **The security claim.** A Mac camera has no infrared depth sensor, so this
  is not Face ID: a photo or a video may pass a camera-only check. Anything
  built here makes a security claim the project would have to stand behind,
  or state plainly that it is a convenience, not protection.
- **What it unlocks.** The Mac's login screen is macOS's own and not
  something an application can replace; what an application could lock and
  unlock is its own content. What is it meant to unlock?
- **Cost.** Camera access, on-device Vision, a liveness check, and the
  largest Module by far (ticket 15).

The honest outcomes are a narrow, clearly labelled convenience, or `wontfix`.
