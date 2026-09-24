# Release smoke test

In Russian: [release-smoke-test.ru.md](release-smoke-test.ru.md).

Run on a Mac that has never had Capacity Notch — a spare machine, or a
separate macOS user account — with the archive downloaded from the release,
not built locally. Ticket 11 closes on this, not on the development machine.

Record the macOS version, the release version, and a pass or fail for each
line. A fail is a finding, with what was seen.

## Install

- [ ] First open shows macOS's "could not verify" warning, and nothing else.
- [ ] System Settings → Privacy & Security shows **Open Anyway** for Capacity
      Notch; after it and **Open**, the application starts.
- [ ] A second open needs no approval.
- [ ] Nothing in the process asked to change a system-wide security setting.

## Onboarding

- [ ] The welcome window opens on first launch.
- [ ] Connect Codex reads Capacity; Connect Claude Code explains itself
      before anything is read, then reads Capacity.
- [ ] Alerts and Launch at Login are asked about separately, and are off
      unless switched on.
- [ ] After quitting and reopening, the welcome window does not come back.

## Both Providers

- [ ] The strip shows each Provider's Headline Window; the card shows every
      Quota Window, used and left, reset countdown and freshness.
- [ ] Claude Code reads with no terminal session open.
- [ ] Without Codex installed (or on a second account without it), Codex says
      how to install it rather than showing numbers.

## Offline

- [ ] With Wi-Fi off, both Providers keep their last numbers marked Stale,
      each with a reason; "Last read at" is the time they were read.
- [ ] With Wi-Fi back, both return to Fresh without a restart.

## Capacity Alerts

- [ ] With Alerts on, a window falling below 10% left sends one notification,
      and no second one while it stays there. (If no window is that low,
      record it as not exercised.)

## Launch at Login

- [ ] Switched on in Settings, the application starts after logging out and
      in again; switched off, it does not.

## Diagnostics

- [ ] Copy Diagnostics puts a report on the clipboard that Settings also shows.
- [ ] It contains no email address, no user name, no path under `/Users/`,
      and no token.

## Updating

- [ ] **Check for Updates…**, in Settings → General, opens the
      latest release in the browser.
- [ ] Installing a newer archive over this one follows the same steps, and
      the README's warning about forgotten permissions matches what happens.
