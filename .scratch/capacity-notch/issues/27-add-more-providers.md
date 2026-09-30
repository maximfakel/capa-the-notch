# 27: Add more Providers

**What to build:** Capacity from more AI services than Codex and Claude Code,
once it is settled which ones.

**Blocked by:** none.

**Status:** needs-info

**Why:** Ticket 15 declined new Providers "for now; on first request". This
is the request: the author wants the list widened and has not yet chosen
which to add.

- [ ] Each new Provider is read through an interface the Provider itself
      owns — its own CLI, app or published status — and never with its
      credentials read by Capacity Notch (ADR 0001).
- [ ] Each is off until turned on, like Codex and Claude Code, and says why
      when it cannot be read.
- [ ] The strip and the open surface still work with more than two Providers
      on; how they show three or four is drawn first.

## What has to be answered first

- **Which services.** Candidates to weigh: Cursor, GitHub Copilot, Gemini
  CLI, and whatever else the author uses. For each: does the person using
  it here actually hit its limits, and does it publish them anywhere a
  Provider-owned interface can reach?
- **What each exposes.** A research pass per candidate, as
  `docs/research/` did for GigaAM: whether its usage and reset times are
  available without reading a token, and how stable that route is.
- **The layout.** The compact strip has two sides; with three Providers on,
  what does it show?
