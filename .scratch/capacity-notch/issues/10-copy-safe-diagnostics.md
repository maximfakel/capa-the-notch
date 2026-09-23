# 10: Copy safe diagnostics

**What to build:** Let a user copy enough diagnostic context to report Provider and lifecycle failures without exposing credentials, account identity, request authorization, private response data, or dictated content.

**Blocked by:** 04/Persist Capacity Snapshots and survive failures; 07/Build onboarding and Settings.

**Status:** resolved

- [x] Copy Diagnostics includes application and macOS versions, Adapter and connection states, relevant timestamps, HTTP status classes, and decode-error types.
- [x] Diagnostics exclude access and refresh tokens, authorization headers, account IDs, credential locations, response bodies, clipboard contents, audio, and recognized text.
- [x] Diagnostic output remains useful for missing CLI, process lifecycle, stale refresh, throttling, authentication, and schema-change failures.
- [x] Automated redaction tests use representative secret-bearing errors and prove that forbidden values cannot enter copied diagnostics.

## Done

### The safety is structural, not a blocklist

A list of forbidden shapes can only catch the shapes somebody thought of. So
the report is assembled from closed vocabularies — enumerations, counts, dates,
two version strings — and a Provider's own words never reach it at all.

The one place a Provider's text enters the domain is
`CapacityStatusReason`'s `detail`, which carries whatever the App Server or the
CLI said. The report takes `diagnosticCode` instead: a word from a fixed list,
`provider-unavailable` rather than the sentence that produced it. A report that
cannot hold free text cannot leak one.

`Redaction` runs over the finished text as a second line, for the version
strings and paths that do come from outside, and for whatever a future careless
addition might carry. It rubs out tokens beginning `eyJ` or `sk-`, bearer
headers, addresses, identifiers, long opaque runs, and turns `/Users/<name>`
into `~` — a home directory is a person's name.

### What it says

From this machine, verbatim:

```
Capacity Notch 0.1.0
macOS Version 26.6.2 (Build 25G83)
generated 2026-09-21T12:35:31Z

codex:
  state stale
  reason stale-from-archive
  windows 2
  read 2026-09-21T12:24:23Z
claudeCode:
  state stale
  reason stale-from-archive
  windows 2
  read 2026-09-21T12:31:49Z

note launch-at-login-off
```

The notes are the closed observations the application can make about itself: a
missing bridge snapshot, a Provider binary it cannot find, launch at login off.

Settings shows the text it just copied, so nobody has to paste it somewhere to
find out what they are about to send.

### The log switch now writes a log

`Keep a log for bug reports` was a switch that did nothing. The Codex App
Server's own output is now sent to it when the switch is on and discarded when
it is off, read at the moment a connection is made. Reveal Log opens it in the
Finder.

## Verified

79 checks pass, four of them new. The important one takes six errors shaped
like the ones these Providers really produce — a JWT behind a bearer header, an
`sk-ant-` key, a credentials path under a home directory, an address, an
organization UUID, and a long opaque token — puts each through the whole
builder, and asserts that no fragment of eight characters or more survives
while the report still says `reason provider-unavailable`.

The others prove scrubbing catches each shape on its own, that every failure
worth reporting has a code, and that the report still carries the versions,
states, counts, timings and retries a maintainer needs.

## Not in scope, and not present

Dictated content and clipboard contents are named in the criterion. Neither
exists in this application — ticket 12 is a spike and ticket 15 is a question —
so there is nothing to exclude yet. When either arrives, the closed vocabulary
is what keeps it out: it can only leak if somebody adds a free-text field, and
that is the thing to refuse in review.

## Comments

**2026-09-23 — two ticked boxes, read against the code.**

A whole-body review of 01–10 found the first box ticked for two things the
report did not carry.

*HTTP status classes* do not apply, and that is checked, not assumed: nothing
under `Sources` makes a network request. Codex is read over the App Server's
stdio, Claude Code through its own `/usage` and a file the bridge writes.
There is no status to classify.

*Decode-error types*, and with them the third box's "schema-change failures",
were missing for Codex, and reproducing one showed it was worse than a
missing line. With one field of `account/rateLimits/read` renamed — what a
newer Codex looks like — the `DecodingError` fell into the catch-all, so the
Provider was disconnected and its App Server torn down, its Capacity gone from
the surface until the person pressed Connect — and then the same again. The
surface said "Codex is not answering — the connection closed." Codex had
answered. Copy Diagnostics said `reason provider-unavailable`, the same as a
process that crashed.

Now a Codex answer in a shape this build cannot read keeps the last reading
as Stale Capacity, leaves the App Server running, and says
`providerAnswerNotUnderstood`: "Codex answered in a form Capacity Notch cannot
read. Update Capacity Notch." — a person's job, not retried with backoff. With
nothing read yet it is the same reason, disconnected. Claude already had its
equivalent, `claude-usage-not-understood`.

The first name chosen for the code, `provider-response-not-understood`, came
out of the report as `[redacted-opaque]`: `Redaction` treats any run of 32 or
more letters, digits and hyphens as a secret. The scrubber is the second line
of defence and was left alone; the code is shorter, and `diagnosticCode`
records the limit. The existing test that every failure is reportable is what
caught it.

### Verified

89 checks pass; two are new and drive the service through the fake App
Server: a renamed field on a later read holds Stale with the new reason and
ends no process, and on the first read disconnects with it. The reproduction
above was rerun and now reports `reason provider-answer-not-understood`.
`CAPACITY_NOTCH_LIVE_CODEX=1` still reads Fresh Capacity from the real App
Server (5 hour 98%, Weekly 24%), so the new branch does not catch a normal
answer. Metrics read `38 / 174 / 228 / 266`.

### Not verified, and not done

- A real Codex has not been seen to change shape; only the fake did.
- `account/read` decodes too, and a change there still reads as
  `provider-unavailable`. Left for its own change.
- The bridge's `malformedInput` and `unsupportedSchema` both report as
  `claude-status-line-unavailable`; the report cannot tell them apart.
- Two things in `holdLastCapacityAsStale` predate this and were noticed, not
  changed: a backend failure (`JSONRPCFailure`) holds Stale with no reason at
  all, and the held snapshot is stamped `now()` rather than the moment it was
  read, so "read" in the report is the moment it went stale.

**2026-09-23 — the two `holdLastCapacityAsStale` defects above, fixed.**

*The reading time.* A held Codex snapshot was stamped `now()`, and the surface
header builds "Last read at HH:MM" from it — so ten minutes after the last
good read it said the Capacity had just been read. The report's `read` line
said the same. The service now remembers when its last reading arrived, from
a read or a rolling update, and a held snapshot carries that moment, as the
Claude service's already did.

*The reason.* A backend failure — the App Server answering a rate-limits read
with an error, "error sending request" when it cannot reach its service — held
Stale with no reason at all, and with nothing held yet disconnected as "Codex
is not answering — its Capacity could not be read", when Codex had answered.
Both now say `providerCouldNotRead`, in Codex's own words on the surface and
as `provider-could-not-read` in the report: "Codex could not read its Capacity
— error sending request. Retrying." Transient, so it backs off as before; no
person needed. Every path into `holdLastCapacityAsStale` now has to name its
reason.

### Verified

91 checks pass; two are new: a held snapshot keeps the moment it was read
across ten minutes of a moved clock (seen to fail first, 600 s late), and a
backend error holds Stale with the new reason. The first-read test now
expects the new reason instead of `provider-unavailable`. Both guidance forms
— a message with and without its own full stop — read cleanly.
`CAPACITY_NOTCH_LIVE_CODEX=1` still reads Fresh Capacity (5 hour 97%,
Weekly 24%). Metrics read `38 / 174 / 228 / 266`.

### Not verified

A real App Server was not seen to return a backend error in this session, and
the header's "Last read at" was not watched on the running surface; both rest
on the fake App Server and the tests.

**2026-09-23 — the rest of "Not verified, and not done" above.**

*`account/read` changing shape.* Worse than listed: `account` is optional
and decodes from any object, so renaming it did not throw at all — it read as
signed out, and the surface told a signed-in person to run `codex login`.
Codex's own schema (`codex app-server generate-json-schema`,
`v2/GetAccountResponse.json`) settles what can be told apart: `account` is
*not* required — a signed-out App Server may leave it out — and
`requiresOpenaiAuth` is the one field that is. So `requiresOpenaiAuth` is now
decoded as required, and an answer without it disconnects as
`providerAnswerNotUnderstood` instead of asking for a sign-in. A missing
`account` alone still reads as signed out, because the schema allows exactly
that; a rename of `account` that keeps `requiresOpenaiAuth` cannot be told from
it, and is not claimed to be.

*The bridge's failures.* The report now notes the bridge file's state from a
closed list, built in Core by `ClaudeStatusLineBridge.observation(of:)`:
`claude-bridge-snapshot-missing`, `claude-bridge-unreadable`,
`claude-bridge-schema-unknown`, `claude-bridge-no-windows` — each under the
32 characters `Redaction` would take. On the surface nothing changes: a bridge
that cannot be read is outranked by `/usage`. And it now always is — a broken
bridge file had been a "telling" failure that, with `/usage` failing too,
spoke over it and brought back "configure the bridge". `/usage`'s failure now
ranks first.

### Verified

95 checks pass; four are new. An account answer outside the schema is not
read as signed out (seen to fail first: it asked for a sign-in); an answer
without `account` is signed out, as the schema allows; a broken bridge file no
longer speaks over `/usage` (seen to fail first); each bridge state gives its
note, and every note survives scrubbing. `CAPACITY_NOTCH_LIVE_CODEX=1` still
reads Fresh Capacity through the stricter account decode, so the real App
Server does send `requiresOpenaiAuth`. `CAPACITY_NOTCH_DUMP_REPORT=1` on this
machine, whose bridge file reads, carries no bridge note.

### Not verified

No real Codex was seen signed out, and no real bridge file was seen broken.
