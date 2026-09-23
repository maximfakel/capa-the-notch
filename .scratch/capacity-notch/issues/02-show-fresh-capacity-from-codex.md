# 02: Show Fresh Capacity from Codex

**What to build:** Let a user connect an installed Codex runtime and replace mock Codex values with Fresh Capacity obtained through the official Codex App Server. Capacity Notch owns the App Server process lifecycle but never reads or manages Codex credentials.

**Blocked by:** 01/Create the clean-room Capacity Notch shell.

**Status:** resolved

- [x] Connect Codex starts one compatible App Server process and displays its Quota Windows in the compact surface and expanded Provider card.
- [x] Capacity updates received from the App Server appear without restarting Capacity Notch.
- [x] Quitting or disconnecting Capacity Notch terminates only the App Server process that it started.
- [x] Missing, incompatible, or unauthenticated Codex installations produce an actionable disconnected state rather than zero Capacity.
- [x] Capacity Notch does not read, copy, persist, refresh, or log Codex credentials.

## Done

### The protocol, read from the source, then checked against a running one

`codex app-server` speaks JSON-RPC as newline-delimited JSON over stdin and
stdout (`stdio://` is its default `--listen`). The handshake is `initialize`
followed by the `initialized` notification, exactly as Codex's own clients do
it. Capacity comes from `account/rateLimits/read`, whose `rateLimits` carries a
`primary` and a `secondary` window; each window reports `usedPercent` as whole
percent, `windowDurationMins`, and `resetsAt` as unix seconds. Both windows are
nullable, and so is `resetsAt`. Live movement arrives as the
`account/rateLimits/updated` notification, documented as a *sparse* rolling
update: a window it omits keeps its last value rather than disappearing.

None of this was guessed. It was read out of `openai/codex` at
`codex-rs/app-server-protocol/src/protocol/v2/account.rs` and
`.../protocol/common.rs`, which is where the method strings are declared, and
then checked against the App Server actually installed on this machine.

That check earned its keep. `account/read` is rejected outright without a
`params` object — `-32600 Invalid request: missing field 'params'` — even
though every field inside it is optional. Reading the source alone would have
shipped a client that disconnects from every real Codex at the account step.
An empty `{}` now goes with it, and a test pins that.

The runtime also does not have to be the `codex` CLI: on this machine it ships
inside the ChatGPT app, at `/Applications/ChatGPT.app/Contents/Resources/codex`.
That path leads the search.

### What Capacity Notch now does

`Connect Codex` in the menu starts one App Server and nothing more. A second
connect finds a live connection and returns; there is never a second process.
Disconnect and Quit end that one process — Capacity Notch holds the `Process`
it spawned and terminates only that handle, so a Codex the user started
elsewhere is untouched.

Fresh Capacity replaces the mock Codex card as soon as the first read returns.
After that the surface moves on its own: rolling updates are merged into the
last snapshot and published, and a sixty-second refresh re-reads the account for
the stretches when Codex sends nothing. Neither path restarts anything.

### A Provider that cannot be read is not a Provider at zero

`CapacitySnapshot.disconnected` carries no Quota Windows at all, which is what
keeps an unreadable Codex from being drawn as an exhausted one. Each reason
carries the single action that fixes it: install the CLI, update it, run
`codex login`, or — when the App Server dies mid-session — a plain statement
that it stopped. The expanded Provider card prints that sentence where the
windows would have been, and the compact surface reads `—`, not `0%`.

Four causes are told apart: no Codex binary on disk, a Codex whose `initialize`
is rejected, an authenticated-account read that comes back with `account: null`,
and a connection that drops.

### Credentials stay with Codex

`CodexAppServerMethod.permittedOutbound` is an allowlist of four methods —
`initialize`, `initialized`, `account/read`, `account/rateLimits/read`. The
client refuses anything else *before* it reaches the transport, so a future
edit cannot quietly add a login call. Capacity Notch opens no file under
`~/.codex` except the `codex` binary it executes, and the App Server's stderr
goes to `/dev/null` rather than into any log of ours. A test asserts the exact
method sequence on the wire and that a `account/login/start` attempt is blocked
without a byte being sent.

### Reset times that Codex does not report

`resetsAt` is nullable in the protocol, so `QuotaWindow.resetsAt` became
optional and the card says "Reset time not reported" rather than inventing a
date. This changed a type that ticket 01 introduced; the mock catalog and its
tests came along.

### A failed refresh is Stale Capacity, not a vanished Provider

The first run on a real machine caught this. A backend read failed, and the
Codex card threw its numbers away and printed "Codex is not answering". The
glossary already had the right answer: Stale Capacity is "the last successfully
observed Capacity when its expected refresh has failed", and it must stay
distinguishable from Fresh. The implementation produced that state nowhere.

The rule now turns on who failed. If the App Server answered, it is alive and
only the backend was out of reach: the last reading stays on the surface marked
Stale, the connection stays up, and the next refresh tries again. If the
transport itself failed, the Provider really is gone and goes disconnected. A
first read with nothing ever observed has nothing to keep, so it disconnects
too.

The failure that exposed this did not repeat, which is the point — a single
blip used to cost the whole connection.

### The surface says what it is showing

The expanded header read "Mock capacity" while live Codex numbers sat under it.
`CapacityProvenance` now derives that line from the snapshots themselves: mock
until something is read, then the time of the newest reading, "Last read at…"
when anything is Stale, and "No Provider connected" when nothing is readable.

The panel also grew a spine. Its expanded height was fixed at 258 points, which
cut a disconnected Provider's sentence in half and would have clipped Codex's
second Quota Window. It now measures its own content, bounded by the screen.

### One thing borrowed from ticket 05

The compact surface has to pick one window per Provider, and Codex reports two.
Until ticket 05 defines the Headline Window by Capacity Pace, the scarcest
window represents Codex. The code says so at the point where it decides.

## Verified against a live Codex

`codex-cli 0.155.0-alpha.9.2`, signed in, read through the same
`CodexCapacityService` the application uses:

```
5 hour: 0% left
Weekly: 84% left
```

Both numbers match what Codex shows for itself in its own sidebar at the same
moment: 100% used reads as 0% left, and the weekly window agrees to the percent.

**Witnessed in the application.** Connect Codex turned the Codex card from Mock
to Fresh and drew both Quota Windows — `5 hour 0% left`, `Weekly 84% left` —
and the compact surface collapsed to `0%` beside Claude Code's mock `55%`
without clipping. That is the first acceptance criterion seen rather than
inferred.

The process ledger holds. Two `codex app-server` processes belonging to the
ChatGPT app were running before the read and the same two after it. Capacity
Notch started its own, read through it, and ended it on disconnect without
touching either of theirs.

All twenty-six checks pass, `swift build` is clean, and `./Scripts/build-app.sh`
produces a signed bundle. The live read is one of the twenty-six; it skips
itself unless `CAPACITY_NOTCH_LIVE_CODEX=1`, so the suite stays honest on a
machine without Codex.

## Still only replayed

Two behaviours are covered by tests against a scripted App Server and have not
been watched against a live one:

- a real Codex turn moving the numbers through `account/rateLimits/updated`
- `codex logout`, then connect, showing the sign-in sentence

Neither blocks this ticket: both paths are exercised, and the states they
produce were seen in their disconnected and stale forms during this work. They
are worth a glance whenever someone next has a spare Codex session.
