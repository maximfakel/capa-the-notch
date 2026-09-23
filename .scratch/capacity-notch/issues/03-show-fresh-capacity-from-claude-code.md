# 03: Show Fresh Capacity from Claude Code

**What to build:** Let a user explicitly connect Claude Code and see its personal Quota Windows without exposing Claude credentials to Capacity Notch.

**Blocked by:** 01/Create the clean-room Capacity Notch shell.

**Status:** resolved

- [x] Claude Code publishes five-hour and seven-day usage through its official status-line JSON.
- [x] The bridge persists only capture time, used percentages, and reset times.
- [x] Credentials, session IDs, prompts, and transcript paths never cross the bridge.
- [x] A recent snapshot replaces mock Claude Code values with Fresh Capacity.
- [x] A snapshot older than five minutes is visibly Stale Capacity.
- [x] Missing or malformed data is actionable and never appears as zero Capacity.
- [x] Existing status-line output can be preserved through bridge passthrough.

## Implemented

`CapacityNotchClaudeBridge` is bundled beside the app executable. Claude Code
runs it as a status-line command and supplies the official `rate_limits` JSON
on stdin. The bridge decodes only `five_hour` and `seven_day`, writes a small
versioned snapshot atomically under Application Support, and ignores every
other field. It performs no network request and has no authentication API.

`ClaudeFileCapacitySource` maps the snapshot into domain Quota Windows.
`ClaudeCapacityService` classifies readings newer than five minutes as Fresh,
older readings as Stale, and missing initial data as disconnected. A failed
refresh retains the last known windows as actionable Stale Capacity.

The previous OAuth endpoint, Keychain/file credential discovery, in-memory
access token, and related live test have been removed. Setup and passthrough
examples are documented in the README and link to Anthropic's official
status-line reference.

**2026-09-20 — verified against a live Claude Code, with one limitation found.**

The bridge works. A terminal `claude` session ran it, and the surface showed
what Claude Code published:

```
five_hour: 81% left, resets 19:00
seven_day: 13% left, resets 18:00
```

The first invocation of that session also behaved as designed. Before the
session's first API response Claude Code sent 939 bytes carrying fourteen
top-level fields and no `rate_limits`; the bridge kept the previous snapshot
and left a note naming only those fields. Three minutes later `rate_limits`
arrived and the snapshot was written.

**The limitation: the status line appears not to run in the Claude desktop
app.** Two restarts of the desktop app, each followed by a conversation, left
no snapshot and no note — and the note is written before any parsing, for any
payload at all, so its absence means the bridge was never invoked. A terminal
session produced both files within a minute. This is strong evidence rather
than proof, but it is consistent with a feature built for a terminal: ANSI
colours, `COLUMNS` and `LINES`, a bar at the bottom of the screen.

Hooks do not rescue it. They fire in every surface, the desktop app included,
but their payload carries no `rate_limits`
(https://code.claude.com/docs/en/hooks). There is no official route to Claude
Capacity from the desktop app.

So Claude Capacity refreshes only while Claude Code runs in a terminal, and
goes visibly Stale otherwise. The guidance now says "in a terminal" rather
than leaving someone to discover that. Codex is unaffected: its App Server is
Capacity Notch's own.

**2026-09-20 — why the status line is terminal-only, and what covers the rest.**

The earlier note guessed that the desktop app does not run a status line. The
reason is now known and it is not about the desktop app. Both the desktop app
and the VS Code extension run the same `claude` binary with
`--output-format stream-json --input-format stream-json`. That mode has no text
interface, so there is no bar for a status line to fill and the command is
never invoked. The extension's own settings schema carries `statusLine`, but
only because it shares the schema with the CLI.

So the bridge covers one surface out of three, and no arrangement of it will
cover the others.

Two further routes exist, both read from `vinzdg/codenotch` (MIT, so adaptable
with attribution under `docs/adr/0002`):

- **Claude Desktop's HTTP cache.** Claude Desktop is Chromium, so the
  `GET /api/organizations/<id>/usage` its own usage panel draws lands in a
  Simple Cache entry. No credential, no request, no subprocess. Checked here:
  the cache holds both `/usage` and `/usage?skip_spend=1`, alternating, the
  newest three minutes old. It covers the desktop app and nothing else, and
  costs a vendored zstd plus a private Chromium format.
- **`claude --print --no-session-persistence --strict-mcp-config /usage`.**
  `/usage` is a local command that sends no prompt to the model. Measured here
  at 2.3 seconds, printing `Current session: 24% used · resets Sep 20 at 7pm`
  and `Current week (all models): 89% used`, which agreed with the bridge's
  figures. It is the only route that does not care where the person works,
  because Capacity Notch runs it itself.

**Recommended:** make `/usage` the Provider's own source, polled and throttled,
and keep the status-line bridge as a free live update where it happens to run —
its JSON is structured, while `/usage` output is prose that a wording change
could silently break. The desktop cache is not worth its cost once `/usage`
covers the same surface.
