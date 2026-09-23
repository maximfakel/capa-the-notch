# 13: Read Claude Capacity wherever the person works

**What to build:** Claude Code's own `/usage` becomes the Provider's source, so
Capacity arrives whether the person works in a terminal, in the desktop app, or
in VS Code. The status-line bridge stays as a free live update where it runs.

**Blocked by:** 03/Show Fresh Capacity from Claude Code.

**Status:** resolved

**Why:** The bridge covers one surface of three. Both the desktop app and the
VS Code extension run the same `claude` binary with `--output-format
stream-json`, a mode with no text interface and therefore no status line to
invoke. See ticket 03's comments for the evidence.

- [x] Capacity Notch reads Claude Capacity with no Claude Code session open, in
      any surface.
- [x] `/usage` is run no more often than its own interval, and a run does not
      hold up a status-line reading.
- [x] The newest reading wins when both sources have one.
- [x] Output that no longer parses is an actionable state, never zero Capacity
      and never a silently frozen number.
- [x] No credential is read, and no request is made to Anthropic.

## Notes

`/usage` is a local command: it sends no prompt to the model. Measured on this
machine at 2.3 seconds, printing

```
Current session: 24% used · resets Sep 20 at 7pm (Europe/Moscow)
Current week (all models): 89% used · resets Sep 20 at 6pm (Europe/Moscow)
```

which agreed with what the bridge had published.

The flags matter and are taken from `vinzdg/codenotch` (MIT, attributed under
`docs/adr/0002`): `--print` avoids the workspace-trust prompt,
`--no-session-persistence` writes no transcript, and `--strict-mcp-config` with
no config starts no MCP server, which otherwise means a dozen Node processes
per poll.

The risk to carry openly: this parses prose, not JSON. A wording change in
Claude Code breaks it, so the failure has to be loud in the domain — Stale or
disconnected with a reason — rather than a number that quietly stops moving.

## Done

`ClaudeUsageCommandSource` runs `claude /usage` and `ClaudeUsageOutput` reads
what it prints. `NewestClaudeCapacity` puts it beside the status-line bridge
and takes whichever saw the windows last, so neither source has to be the one
that works. `ThrottledCapacitySource` holds the command's answer for five
minutes, because the surface refreshes every minute and Capacity does not move
that fast.

The prose is treated as prose. A line whose wording is not recognised yields no
window; a report with no recognised line yields no reading at all, which the
service turns into Stale Capacity or a disconnected Provider. Nothing about a
wording change can produce a number, and nothing can leave an old number
standing as though it were current.

A reset printed without a year — `resets Jan 2 at 3am` read in December —
belongs to the year ahead, and is read that way.

## Verified

`swift build` is clean and 42 checks pass, five of them new: the real report
this machine printed, prose that no longer parses, the turn of the year, the
newer source winning, and the throttle.

Live, against the installed Claude Code:

```
(asking /usr/local/bin/claude)
5 hour: 71% left
Weekly: 11% left
(2.5s)
```

That live check is one of the 42 and skips itself unless
`CAPACITY_NOTCH_LIVE_CLAUDE=1`, so the suite stays honest on a machine without
Claude Code.

## Not done

The per-model weekly line — `Current week (Fable)` — parses to nothing on
purpose. It is a real Quota Window, but a third window needs a decision about
what the compact surface does with it. That belongs with ticket 05, which picks
the Headline Window.

## Comments

**2026-09-23 — two boxes above were ticked and not true.**

A whole-body review of 01–10 and 13 found both.

"Output that no longer parses is an actionable state" was only half true.
Every `/usage` failure became `claudeStatusLineUnavailable`, whose one action
is to configure the status-line bridge — the source this ticket stopped
depending on. Worse, `NewestClaudeCapacity` passed on the *first* failure, and
the bridge comes first: outside a terminal, where there is no bridge, the
surface said "configure the bridge" whatever `/usage` had actually said.

Now each way `/usage` fails has its own reason and its own fix:

| Failure | Reason | Guidance | Needs a person | Retried with backoff |
| --- | --- | --- | --- | --- |
| no `claude` binary | `claudeCodeNotInstalled` | Install Claude Code, then connect again. | yes | no |
| ran and did not answer | `claudeUsageFailed` | Claude Code did not answer. Check that it is signed in, then refresh. | no | yes |
| report not understood | `claudeUsageNotUnderstood` | Claude Code's usage report has changed and Capacity Notch cannot read it. Update Capacity Notch. | yes | no |

and a bridge that has published nothing answers only when no other source has
anything to say.

"never a silently frozen number" had a gap: a report whose weekly line alone
changed wording read as a success with one window, and the surface simply
stopped showing Weekly. A line with a window's form — a name, a colon, a
percentage used — that Capacity Notch cannot name now refuses the whole
report, so the Provider goes Stale with the reason above rather than losing a
window without a word. Two things deliberately do not trip it: the per-model
week, which is left out on purpose, and a report that prints no weekly line at
all, because the bridge treats each window as optional too and a plan without
a weekly allowance would otherwise alarm forever.

### Verified

83 checks pass, four of them new: a reworded window refuses the report; the
per-model week and a session-only report still read (and that check was seen
to fail with the per-model exclusion removed); a missing bridge does not hide
the `/usage` failure; each `/usage` failure publishes its own reason. The new
reasons are in the diagnostics vocabulary and the transient/terminal split.
`CAPACITY_NOTCH_LIVE_CLAUDE=1` against this machine's Claude Code still reads
Fresh Capacity (5 hour 91% left, Weekly 70% left, 2.6 s), so today's real
report does not trip the new rule. Metrics read `38 / 174 / 228 / 266`.

### Not verified

No failure path was seen live. A changed report cannot be produced on demand,
and a missing binary or a signed-out Claude Code was not staged on this
machine; all three are covered by scripted sources only. The guidance
sentences were not read on the running surface.

`claudeStatusLineStale` still says "Run Claude Code in a terminal to update
its last published Capacity", which is the pre-`/usage` advice. It is left for
its own change: with `/usage` every five minutes and Stale after five, when
that reason can appear at all is a question to measure, not to reason about.

**2026-09-23 — "a run does not hold up a status-line reading", measured.**

It does, and it was worse than the review said: the twenty-second timeout
never fired. `run` read the pipe to its end before it started the clock, and
reading a pipe to its end waits for the process to exit. A wedged `claude`
therefore held the refresh for as long as it stayed wedged — and because
nothing but `refresh()` ever turns Fresh into Stale, the surface would have
kept the last Claude numbers marked Fresh the whole time.

Measured with a fake `claude` and the real `NewestClaudeCapacity` and
`ThrottledCapacitySource`:

| Case | Bridge reading waited, before | After |
| --- | --- | --- |
| throttle holding a result | 0.0 s | 0.0 s |
| throttle expired, `claude` answers in 3 s | 3.4 s | 3.0 s |
| `claude` hangs for 45 s | **45.0 s** | 20.0 s, then `claudeUsageFailed` |

The output is now drained on a queue of its own while the wait runs against a
real deadline; past it the process is terminated and the run fails as
`claudeUsageFailed`, which is transient and backs off.

What stays true, by decision: the bridge still waits for `/usage` once every
five minutes — 2–3 s in practice, 20 s at most. Measured, that is invisible
against a reading that is live to the minute, and running `/usage` in the
background would add a thread and a lock for nobody to notice. So the box
above should be read as: *a run holds up a status-line reading by no more
than the timeout.*

### Verified

85 checks pass; two are new and spawn a real executable: one that hangs is
given up on at a one-second timeout, and one that answers before its deadline
is still read. The first was seen to fail before the change — the run waited
the full eight seconds and then reported a changed report, the wrong advice.
`CAPACITY_NOTCH_LIVE_CLAUDE=1` reads this machine's Claude Code through the new
code (5 hour 88%, Weekly 69%, 2.1 s). Metrics read `38 / 174 / 228 / 266`.

### Not verified

A real Claude Code was never seen to hang; only the fake did. If a process
`claude` starts outlives it and keeps the pipe open, the draining thread waits
for that process too — the run itself still returns on time, but that thread
is not reclaimed until the pipe closes. Not seen, and not worth building for
until it is.

**2026-09-23 — when "Run Claude Code in a terminal" appears, measured; and a
roll-back it was hiding.**

The review asked whether `claudeStatusLineStale`'s advice was still right.
Simulated for thirty minutes at a refresh a minute, with the real
`NewestClaudeCapacity`, `ThrottledCapacitySource` and service on a hand-moved
clock:

| Case | Before | After |
| --- | --- | --- |
| no bridge, `/usage` answers | Fresh throughout | Fresh throughout |
| day-old bridge, `/usage` answers | Fresh throughout | Fresh throughout |
| no bridge, `/usage` fails from 10 m | Stale · `claudeUsageFailed` · last reading, 5 m old | same |
| day-old bridge, `/usage` fails from 10 m | Stale · `claudeStatusLineStale` · **the bridge's day-old numbers** | Stale · `claudeUsageFailed` · last reading, 5 m old |

While `/usage` answers, its held reading never outlives the five minutes it is
held for, so the stale reason cannot appear. It appeared only in the last case,
and there the advice was the smaller problem: `NewestClaudeCapacity` handed on
the old bridge file as a successful reading, so the surface rolled back to
yesterday's numbers and the failure that said what to fix was lost. That is
not Stale Capacity as `CONTEXT.md` defines it — the last *successfully
observed* Capacity. This machine has a bridge file from 2026-09-20, so it was
not hypothetical here.

Now an old reading does not stand in for a source that just failed: when every
reading is older than `ClaudeCapacityReading.freshFor` and a source failed
with something telling, that failure is passed on and the service holds its
own last reading. The five minutes live in that one constant, which the
service's own staleness check also uses.

`claudeStatusLineStale`'s wording is unchanged: it can now appear only when an
old bridge reading is all there is to say, and then "Run Claude Code in a
terminal" is the right advice.

### Verified

87 checks pass; two are new. One covers `NewestClaudeCapacity` directly: an
old reading with a failure passes the failure on, a fresh one still wins, and
an old one with nothing telling beside it is still returned. The other runs
the last case above through the service, and was seen to fail — showing the
day-old `0.5` — with the new condition disabled. The simulation above was
rerun on the fix. `CAPACITY_NOTCH_LIVE_CLAUDE=1` still reads Fresh Capacity
(5 hour 85%, Weekly 69%, 2.7 s). Metrics read `38 / 174 / 228 / 266`.

### Not verified

The roll-back was never watched on the running surface: `/usage` did not fail
on this machine during the session.
