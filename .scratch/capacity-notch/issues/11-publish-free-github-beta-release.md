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
