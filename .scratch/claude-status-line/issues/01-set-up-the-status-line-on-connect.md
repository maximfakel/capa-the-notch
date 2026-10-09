# 01: Claude Code's status line set up on connect, `/usage` dropped

**What to build:** Connecting Claude Code (onboarding or Settings ▸ Providers) asks once, then adds the status-line bridge to `~/.claude/settings.json` itself, keeping a status line the person already has by running it after the bridge (`-- <command>`). Turning Claude Code off puts back what was there. The background `claude --print /usage` is removed: since Claude Code 2.1.263 it prints the session's cost, not the plan's limits, and each run is one more Claude Code process able to refresh, and so invalidate, the person's sign-in. ADR 0001, amended 2026-10-06.

**Blocked by:** None.

**Status:** done

- [x] Connecting asks once, saying exactly what changes in `~/.claude/settings.json` and that it is undone on Turn Off; a person who connected before is asked once at launch, never silently.
- [x] The edit touches only the top-level `statusLine` value, keeps the rest of the file byte for byte, its link and its permissions; an existing status line runs after the bridge; a bridge already there is left as it is.
- [x] Turn Off restores the earlier `statusLine` (or removes the one added), and only one CapaTheNotch added.
- [x] A file that is not valid JSON is not touched; the person is told why.
- [x] `/usage` polling, its source, its parser and their reasons are gone; Claude Code's card, with nothing published yet, says Capacity appears after the next message in Claude Code in a terminal.
- [x] Core tests cover install, wrapping, already-installed, restore, malformed input.

## Comments

- 2026-10-06: Done.
  - **Consent.** The first Turn On asks once and covers the edit. A person who connected before is asked once at launch. That question replaces the 2026-10-03 move question; setting up points an old bundle's bridge at this copy too. "Not Now" is kept apart from a yes, and the next Turn On asks again rather than editing.
  - **What counts as already set up.** Only this copy's bridge counts. A bridge from another copy has its path changed and keeps what it passes on. A bridge set up by hand at this path is left alone and is not removed on Turn Off.
  - **Refused files.** A file with `statusLine` twice is refused, like one that is not JSON.
  - **Removed.** The `/usage` source, its parser, the throttle, `NewestClaudeCapacity` and the three `/usage` reasons, with their tests; the archive never stored reasons.
  - **Diagnostics.** Copy Diagnostics says `claude-status-line-not-set-up` in place of `claude-binary-not-found`.
  - **Not handled.** A `statusLine` in a project's `.claude/settings.json` or in `settings.local.json` overrides the person's file and is not detected. A build outside Applications sets nothing up.
