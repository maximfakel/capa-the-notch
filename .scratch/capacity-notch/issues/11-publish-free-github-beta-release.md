# 11: Publish a free GitHub beta release

**What to build:** Give friends a transparent, reproducible, no-cost way to download and run Capacity Notch on Apple Silicon without claiming Developer ID signing or notarization. The release must provide a safe first-launch path and a verified update path.

**Blocked by:** 08/Send deduplicated Capacity Alerts; 09/Finish the accessible visual experience; 10/Copy safe diagnostics.

**Status:** ready-for-agent

- [ ] A reproducible Apple Silicon release build is published as a GitHub Release with source, release notes, and a SHA-256 checksum.
- [ ] Installation guidance uses only standard macOS per-application approval and never asks users to disable Gatekeeper globally.
- [ ] The release clearly states that it is not Developer ID signed or notarized and explains the resulting first-launch warning.
- [ ] An EdDSA-signed Sparkle update is tested end to end on a clean Mac; if ad-hoc signing prevents a reliable update, the menu instead exposes a tested manual path to the latest GitHub Release.
- [ ] A clean-Mac smoke test covers installation, onboarding, both Providers, offline behavior, Capacity Alerts, Launch at Login, diagnostics, and the selected update path.
- [ ] No paid Apple Developer Program capability is required by the build or release process.

## Comments

**2026-09-21 — ad-hoc signing makes macOS forget every permission.**

The application is signed ad-hoc (`codesign --sign -`), and an ad-hoc signature
changes with every build. macOS records a permission grant against the
signature, so each rebuild is a different application to it: the Documents
prompt, and any other permission Capacity Notch ever needs, comes back after
every install.

That is invisible while a release is a download that nobody rebuilds, and it is
loud during development, where it asks on every iteration. A stable signing
identity fixes it for both. This ticket already covers not claiming Developer ID
or notarization; it should also say plainly that without a stable identity,
permissions do not persist across updates.

**2026-09-21 — what `notchy.dev` does, read off its own page.**

A free, closed-source notch application covering the same ground, including AI
rate-limit tracking across Claude Code, Copilot, Cursor and others. Studied
from its published description only: ADR 0002 uses closed and GPL projects as
behavioural references, and inspecting a binary would end that standing.

Three things worth taking for this ticket:

- **Sparkle** for updates, with an optional beta channel. That is the standard
  answer and it fits the preference this project already stores.
- **Homebrew** alongside a direct download. Worth having from the first
  release; it is the difference between a link and an install anyone can
  script.
- **Hiding from screen capture** is offered and optional there too, which is
  independent agreement with what ticket 06 settled.

A performance baseline to hold, measured here on 2026-09-21: idle, with the
pointer watched ten times a second and Codex connected, Capacity Notch used
0.05 seconds of CPU across 30 seconds — 0.17% of one core — at 68 MB resident.
`notchy.dev` advertises about 0.9% of one core under load. A release should not
be shipped above that.

What its page does not say, and what matters most to us: how it reads Claude
Code's limits. That is the question ticket 03 is stuck on, and a closed binary
cannot answer it without the kind of inspection this project has ruled out.

**2026-09-23 — built, and what the author decided.**

Decided by the author: updates by hand, a fresh history for the published
repository, the repository private for now (`maximfakel/capacity-notch`),
Homebrew later. Ticket 03's open question about Anthropic's terms was put to
the author and left open by them; this release goes ahead without an answer.

*Reproducible build.* `build-app.sh` was not reproducible: two clean builds
differed in 946 bytes. The cause was the linker's debug map, which records
every object file's modification time — and its absolute path, so the binary
also carried `/Users/<author>`; SwiftPM's `Bundle.module` fallback carried the
build directory too. `Scripts/build-release.sh` builds with a fixed scratch
path and no debug info, stamps every file with the commit's own time, zips in
sorted order without extra fields, and refuses to release a binary with a home
directory in it. Two clean runs, and runs in three time zones, gave the same
archive byte for byte (`8495c94d…` at the commit it was tested on).

*Update path.* The ticket's own fallback: an ad-hoc signature is new with each
build, so no updater could keep macOS's permissions, and a private repository
cannot be asked about without a token the application will not hold. **Check
for Updates…**, in the menu and in Settings, opens the latest release; the
Settings toggle that did nothing is gone, and `checksForUpdates` stays stored,
off, for a public repository later.

*Guidance.* The README's Install section says plainly that the application is
not Developer ID signed or notarized, why macOS warns on first open, and that
permissions are forgotten at every update. The first-open steps are Apple's
own, from support.apple.com/102445 — System Settings → Privacy & Security →
Open Anyway, then Open — and nothing asks for Gatekeeper to be turned off. The
page says nothing of right-click opening, of how long Open Anyway stays, or of
an administrator password, so neither does the README.

*Performance.* Idle for 30 s on this machine, both Providers connected: 0.05 s
of CPU (0.17% of one core) at 39 MB resident, against the 0.9% ceiling.

*No paid capability* is used: ad-hoc signing, no entitlements, GitHub only.

### Verified

96 checks pass. The archive was unpacked: its checksum matches, its ad-hoc
signature verifies with `codesign --verify --deep --strict`, and `spctl`
rejects it — as it will for anyone who downloads it, which is what the
guidance is for. The installed application carries the new menu item. Metrics
read `38 / 174 / 228 / 266`.

### Not done — needs the author

- Publishing: the repository, the fresh-history snapshot, the tag and the
  release. Asked for separately, because it is an action on the author's
  account.
- The clean-Mac smoke test, `docs/release-smoke-test.md`. It needs a Mac, or
  a macOS account, that has never had Capacity Notch, and a download from the
  release rather than a local build. The ticket closes on it.
- Reproducibility across machines: shown on one machine and toolchain only.

**2026-09-23 — two things publishing found before anything was published.**

*The author's identity was still in the tree, not only in old history.* The
redaction tests' secret-shaped fixtures carried the author's home directory
name and email address, and an organization id of unknown origin. The first
sweep for personal data had excluded `Tests`; the sweep of the snapshot about
to be pushed did not, and caught it. They are invented now, in the same
shapes. Nothing had left the machine.

*Reproducible only from one directory.* Built from the snapshot, the archive
differed from the one built here, by four bytes of code: in release the
compiler drops a source file's path from `swift_isEscapingClosureAtFileLocation`
— the pointer is to an empty string, so the path is not in the binary — but
keeps the path's length, which differs with every clone. `-file-prefix-map`
does not reach it. `build-release.sh` now builds `git archive HEAD` unpacked
into a fixed directory; the source checkout and the snapshot, in different
directories, then gave the same archive.

**2026-09-23 — published.**

`https://github.com/maximfakel/capacity-notch`, private. Its history is one
commit, `12858c2`, authored by `190096705+maximfakel@users.noreply.github.com`
with the date of local `c5a8d45`, whose tree it is exactly. Release `v0.1.0`,
"Capacity Notch 0.1.0 (beta)", carries `CapacityNotch-0.1.0.zip` and its
`.sha256`:

`91fb9ddb8d8cea3e37b5ddbcd62bab6a1c8a40fcba7e71bdbe36b1f228658763`

The same archive came out of the local checkout and out of the snapshot's, in
different directories, and the assets downloaded back from the release pass
`shasum -c`.

Published first as a pre-release, then made an ordinary release: GitHub never
counts a pre-release as latest, so `/releases/latest` — what Check for
Updates… opens — answered 404 while it was the only one. "Beta" is in the
title and the notes instead. Signed out, that URL still answers 404, because
the repository is private; a friend signed in to GitHub, with access, gets
the release.

**Releasing the next version.** The published history is not this one, so a
push from here does not apply. For each release: bump `Packaging/Info.plist`,
commit, `git archive HEAD` into a clone of the published repository as one new
commit with the source commit's date and the noreply author, sweep it for
personal data, run `build-release.sh` there and check it matches the local
archive, push, tag, and release as an ordinary release.

### Still open

- The clean-Mac smoke test, `docs/release-smoke-test.md` — the ticket closes
  on it.
- Friends need access to the private repository to download.
- Homebrew, later, by decision.
- Ticket 03's question about Anthropic's terms, left open by the author.

**2026-09-23 — the next release is one script.**

`Scripts/publish-release.sh` does what the steps above describe, and asks
before anything is pushed; `--dry-run` does everything but push and release.
It holds nothing personal itself — it is published too — so what it sweeps
for is read at run time: the home directory's name, `git config` name and
address, any email address outside an allowlist, any `/Users/` path. The
repository comes from `Releases.swift`, the one place it is named, and the
noreply author from `gh api user`.

### Verified

A dry run from a throwaway clone built the archive, committed the snapshot
onto the published `12858c2`, swept it clean, and built the same archive from
it. With a file naming the home directory and the git address planted in the
clone, the sweep named both and stopped before anything was pushed.

### Not verified

The pushing half — push, tag, release, download-back and the latest check —
has not run through the script; it is the sequence that published 0.1.0 by
hand. Nor has the refusal when the two archives differ, since they did not.

**2026-09-24 — Hardened Runtime on, and what checking it turned up.**

The spec asked for Hardened Runtime with minimal entitlements; the release was
signed without it. Both executables are now signed with `--options runtime`
and no entitlements, the bridge on its own and first, since signing the bundle
marks only its main executable and Claude Code runs the bridge directly. The
release archive stays reproducible (two clean runs, the same bytes).

Checked on the installed application: the Codex App Server starts and reads
within seconds of launch; the bridge, fed `{}`, records its note, forwards to
the command after `--`, and leaves the snapshot alone; `/usage` reads Fresh
Capacity.

*A finding along the way, not caused by it.* The first `/usage` after
installing a **new build** hangs: its `claude` child spawns `security` —
Claude Code reaching for its own credential in the Keychain — which does not
return, and the run is cut off at the twenty-second timeout. The same happened
with and without Hardened Runtime. The throttle then holds that failure for
five minutes, so after every update Claude shows "Claude Code did not answer"
for up to five minutes before its next run reads normally, without `security`.
Relaunching the *same* build read Claude two seconds after launch. Seen three
times with a new build, once with the same one.

Ruled out: the environment (the app's full environment, replayed from a shell,
read in 2.3 s) and a visible Keychain dialog (`SecurityAgent` never ran). Not
yet known: what `security` waits for. It matches the ad-hoc problem this ticket
already names — each build is a new signature — but through Claude Code's own
Keychain access rather than a permission of Capacity Notch's.

**2026-09-24 — the window after an update, shortened.**

The finding above was worse in the background than it looked. A closed
surface reads a Provider every five minutes and doubled the wait after a
failure worth retrying, so a first `/usage` that hung after an update left
Claude unread for about ten minutes; the throttle, holding the failure as
long as an answer, would have kept a sooner refresh from asking anyway.

Now a first consecutive failure is tried again after 30 seconds, whichever
pace the surface is at, and doubling starts from the second
(`RefreshSchedule.firstRetry`); and `ThrottledCapacitySource` holds a failure
for 30 seconds, an answer still for five minutes. Codex's transient failures
get the same quick second chance.

### Verified

97 checks pass; the schedule test now expects 30 s for a first failure and
the doubling from the second, and a new test has a failure held 30 seconds,
not the interval. Both were seen to fail first.

### Not verified

The path this is for was not seen live. On the next new build, installed to
watch it, the first `/usage` called `security` and read in five seconds — so
the hang happens on some new builds, not all (three of four today), for a
reason still unknown. The two parts are tested; the refresh loop in
`AppDelegate` that joins them is not.
