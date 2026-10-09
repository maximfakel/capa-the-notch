# 33: Reset the grants kept under the old signature, once

**What to build:** On the first launch of the first version signed with the
author's certificate (0.4.0), CapaTheNotch clears what macOS kept for it
under the old ad-hoc signature — microphone, Accessibility, System Events,
Calendars — once, says why, and asks for them again.

**Blocked by:** none.

**Status:** resolved

**Why:** Ticket 30 measured it (see its Comments): a build signed with the
certificate does not replace the requirement macOS stored with each old
grant, and an ad-hoc impostor still gets every one of them without a
prompt until the grant is reset. `tccutil reset <service>
app.capacitynotch.CapacityNotch` works as the user, without an
administrator, for all four. The author chose on 2026-10-08 to have the
application do it itself rather than ask people in the release notes, so
the hole closes for those who never read them. The 0.4.0 release notes
already promise it; 0.4.0 does not ship without this.

- [x] Drawn in Paper first — what the person sees and reads before and
      after the reset — the author settles it, and it is built from the
      measured drawing (no blue buttons).
- [x] Runs once: only when the previous version that ran was signed
      ad-hoc (or is unknown and grants exist), never again after it
      succeeded, and never on a fresh install.
- [x] Resets exactly Microphone, Accessibility, AppleEvents and Calendar
      for `app.capacitynotch.CapacityNotch`, nothing else, and says so if
      `tccutil` fails rather than pretending.
- [x] Afterwards the person is taken to the permissions step of onboarding
      (or its equivalent), with the reason in plain words, in English and
      Russian.
- [x] Checked on this Mac: from a 0.3.1 install with grants, the update
      resets once and re-asks; an ad-hoc impostor afterwards gets nothing.

## Not this

- Anything about the signature itself — ticket 30.

## Comments

**2026-10-08 — drawn in Paper, for the author's pass.** File CapaTheNotch,
page Settings, at the end of the Onboarding row: "Permissions again — after
the reset" and "Permissions again — the reset failed". A window of its own,
560 wide, made from "Onboarding — 2 Permissions" without the step sidebar:
the heading says why it is asking again; the card lists the four that were
reset (Calendars only with the Calendar on; Notifications are not reset, so
not there); Allow All; footer Not Now / Done. The failed one says so
plainly, opens each pane of Privacy & Security and offers Try Again. Not
built until the author has settled the drawings.

**2026-10-09 — the author's decisions.** Shown inside onboarding, at the
permissions step, not in a window of its own; closing the window or
skipping the step is allowed with not everything granted.

**2026-10-09 — what the hands-on check found.** The first run of the
update showed the step with Microphone, Accessibility and Calendars as
Granted although tccutil had reset them: the microphone, Accessibility and
Calendars answer the first question for the life of the process, and the
reset came after it. Fixed by resetting in AppDelegate's init, before any
of them is read (259e1eb); Try Again and Already Removed, which happen in
a running process, open CapaTheNotch again and the relaunch asks, once.
Measured too: an installed application with nothing granted still gets
exit 0 from `tccutil reset`; only one macOS does not know gets 64.

## Done

- **Paper:** "Permissions again — after the reset" and "… — the reset
  failed" (Settings page, end of the Onboarding row), the second with
  Already Removed added after review. Built as onboarding's permissions
  step in those two modes; the pictures from `CAPACITY_NOTCH_DUMP_ONBOARDING`
  (`onboarding-2-permissionsAgain`, `-permissionsNotReset`, light and dark)
  match their text, rows and buttons.
- **Once, and never on a fresh install:** `OldGrantReset.runOnce` — only in
  a copy signed with a certificate, a first run settled at once without a
  reset, the mark set only when all four were reset (by tccutil, or by the
  person with Already Removed). Tests `OldGrantReset.onceUnderTheCertificate`,
  `.firstRunResetsNothing`, `.failureTriedAgain`, `.removedByHand`. The
  "previous version ad-hoc" is read as "the mark is absent on a launch
  that is not a first run": every build before 0.4.0 was ad-hoc.
- **Exactly the four:** `OldGrantReset.services`, test `.exactlyTheFour`;
  `/usr/bin/tccutil reset <service> app.capacitynotch.CapacityNotch`, five
  seconds at most each, without turning the run loop.
- **Afterwards:** `OldGrantReset.opening` — onboarding as ever on a first
  run, "Permissions, Once More" for someone who used an older build, "The
  Earlier Permissions Were Not Reset" with Open Settings per pane, Try
  Again, Already Removed and "macOS refused again." when it fails; English
  and Russian. Tests `.whatOpens`, `.askedAtTheRelaunch`. Calendars join
  the permissions while the Calendar Module is on, and are always listed on
  the failed step. Notifications are not reset, so not asked again.
- **Checked on this Mac, 2026-10-09, with the author:** the ad-hoc 0.3.1
  build given the microphone and Accessibility; the update over it reset
  once (mark set) and asked; after the fix, with the grants given and the
  mark cleared, the update's step showed Allow on all four, the author
  granted them, the relaunch opened nothing and kept them all, and an
  ad-hoc impostor got none (microphone not determined, Accessibility not
  allowed, Calendars not asked). Not exercised by hand: the failed path,
  which needs tccutil to refuse — its screen is checked by picture and its
  logic by tests.
- `swift run CapacityNotchTests`: 325 passed.

