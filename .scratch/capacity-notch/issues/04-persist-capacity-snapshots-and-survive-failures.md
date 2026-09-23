# 04: Persist Capacity Snapshots and survive failures

**What to build:** Keep useful Capacity visible across restarts, network loss, throttling, and Provider failures. Users should always be able to distinguish Fresh Capacity from a previously successful but now Stale Capacity Snapshot.

**Blocked by:** 02/Show Fresh Capacity from Codex; 03/Show Fresh Capacity from Claude Code.

**Status:** resolved

- [x] The latest successful Capacity Snapshot for each Provider survives an application restart and initially appears as Stale Capacity.
- [x] A successful refresh replaces Stale Capacity with Fresh Capacity without disrupting the surface.
- [x] Refresh runs approximately every 60 seconds while expanded and every 5 minutes in the background, with an immediate manual Refresh action.
- [x] Offline failures, throttling, authentication failures, and schema failures use bounded exponential backoff and never turn unknown Capacity into `0%` or `100%`.
- [x] Connection states distinguish connecting, fresh, stale, disconnected, transient failure, and terminal failure with deterministic test coverage.

## Done

### What a restart opens on

`CapacityArchive` keeps the last reading each Provider gave, under Application
Support, written whenever a Fresh reading arrives and again on quit. At launch
it comes back as Stale Capacity — true when written, unconfirmed since — and
says so: "Last seen before Capacity Notch restarted. Refreshing."

A Provider with no Quota Window is not written down. Remembering it would bring
back a Stale nothing, which is worse than saying it has not been read. A
Provider with nothing archived still opens as unread, so a restart never shows
a number that no Provider gave.

### How often a Provider is asked

`RefreshSchedule` decides. An open surface is being watched, so it is read every
minute; a closed one is glanced at, so every five. **Refresh Now** in the menu
reads every connected Provider at once and clears the backoff.

A run of failures worth retrying doubles the wait each time, to a ceiling of
fifteen minutes. The doubling is bounded before it is computed, so a long run
cannot overflow its way back to a short wait.

### Which failures are worth retrying

A failure the next attempt could clear is transient: a Provider that stopped
answering, a reading that has aged, an archive being refreshed. One that waits
for a person is terminal: an install, a sign-in, an update, a deliberate
connect. Only transient failures back off — stretching the wait on a Provider
that needs a person helps nobody, and it would still be waiting when they
finally acted.

`.connecting` joins the connection states: asked and not yet answered, which is
neither disconnected (nothing is wrong) nor stale (there is nothing to keep
showing).

## Verified

53 checks pass and `swift build` is clean. Six are new: the round trip keeping
the capture time and the window's shape, a windowless Provider not being
remembered, a missing and a damaged archive costing nothing, a restart that
restores one Provider and still asks for the other, the backoff at both paces
and its ceiling, and every reason sorted into transient or terminal.

Live: the running application wrote its Codex reading, and the real loader read
that file back.

```
codex: 5 hour 0% left, Weekly 54% left
```

That check is one of the 53 and skips itself unless
`CAPACITY_NOTCH_LIVE_ARCHIVE=1`.

## Not done

Claude Code is not archived yet on this machine, because it is still connected
by hand and this run was not. Nothing about the archive treats it differently;
it simply had no Fresh reading to write.
