# 30: Sign with the author's own certificate

**What to build:** Every build of CapaTheNotch — `Scripts/build-app.sh` and
`Scripts/build-release.sh` — signed with a self-signed code-signing
certificate the author holds, and a designated requirement that names that
certificate, so only a build the author signed inherits what macOS granted.
Still free, still no Developer ID and no notarization (ticket 22).

**Blocked by:** none.

**Status:** resolved

**Why:** Raised publicly on Threads on 2026-10-07 (andreev_lens), and it is
right. Both scripts sign ad-hoc with

```
designated => identifier "app.capacitynotch.CapacityNotch"
```

macOS stores that requirement with each grant — microphone, Accessibility,
Automation of System Events — and checks a later process against it alone.
Anyone can sign anything ad-hoc with that bundle identifier, so a swapped or
tampered build (a fake zip, or code already running as the user that drops
its own app beside ours) gets those grants without a single prompt. It needs
code running on the Mac first, but it turns that into Accessibility and the
microphone silently.

The requirement was named on purpose (see the comment in `build-app.sh`):
left to `codesign`, an ad-hoc requirement is the build's own hash, and every
update lost every grant. A certificate keeps that and closes the hole:

```
designated => identifier "app.capacitynotch.CapacityNotch" and certificate leaf = H"<SHA-1 of the author's certificate>"
```

Developer ID would do the same with Apple's anchor; it was declined for cost
(ticket 22), and notarization has no bearing on this — it is Gatekeeper's,
not the grants'.

- [x] A self-signed code-signing certificate, created once by the author in
      the login keychain (a `/wizard` script walks it: Keychain Access →
      Certificate Assistant, or `security`/`openssl`, with the Code Signing
      extended key usage), and its private key backed up outside this Mac.
      The agent never creates, reads, exports or commits the key.
- [x] Both scripts sign the app and the bridge helper with it, by the
      certificate's name or SHA-1 from an environment variable or a local,
      git-ignored file; they fail plainly when it is missing rather than
      falling back to ad-hoc.
- [x] The designated requirement names the certificate (`certificate leaf =
      H"…"`) as well as the identifier; `codesign -d -r-` on the result shows
      it, and a copy re-signed ad-hoc with the same identifier is refused by
      `codesign --verify -R='<that requirement>'`.
- [x] Grants survive an update: a build signed with the certificate keeps
      microphone, Accessibility and System Events after replacing the
      previous certificate-signed build — checked on this Mac.
- [x] A build signed ad-hoc with the same identifier does **not** receive
      them — checked on this Mac, after the migration below.
- [x] Release reproducibility still holds, or the release notes say why not:
      ticket 11 checks the archive byte for byte across two builds, and a
      certificate signature may carry a signing time (`--timestamp=none` and
      what `codesign` still writes need checking).
- [x] README and the release notes say what the signature is: the author's
      own certificate, not Apple's; why macOS still warns on first open; and
      the certificate's SHA-1 so anyone can compare it with
      `codesign -dvv`.

## What has to be answered first

- **The grants already given.** Existing users granted under the weak
  requirement, and a new signature does not replace what macOS stored: an
  ad-hoc impostor still satisfies the old stored requirement. Measure on this
  Mac whether the stored requirement is updated when a stricter build is
  approved, and whether `tccutil reset <service>
  app.capacitynotch.CapacityNotch` works for Microphone, Accessibility and
  AppleEvents without an administrator — and so whether the app can do it
  once itself on first launch of the new version, or the release notes must
  ask people to remove and re-add it in Privacy & Security.
- **Losing the key.** If the private key is lost, the next build is a new
  application to macOS and everyone grants again. Where the backup lives is
  the author's call; the ticket only needs it to exist.

## Not this

- Apple Developer ID, notarization, Sparkle — declined in ticket 22.
- Changing the bundle identifier — it would reset preferences (ticket 15)
  and is not needed once the requirement names the certificate.

## Comments

**2026-10-07 — raised on Threads.** Question from andreev_lens: whether a
swapped or compromised build with the same bundle ID inherits the
microphone, Accessibility and System Events grants, and whether Developer
ID or a stricter tie to the developer is planned. Confirmed against
`.build/CapaTheNotch.app`: `codesign -d -r-` prints
`designated => identifier "app.capacitynotch.CapacityNotch"`.

**2026-10-08 — the migration, measured on this Mac.** macOS 27.0.1. The
TCC databases cannot be read without Full Disk Access, which was not given,
so each build was installed in Applications, opened with `open` (so it is
its own responsible process) and `CAPACITY_NOTCH_DUMP_REPORT=1`, and its own
report read: `dictation-mic-*`, `dictation-insertion-*` and
`translator-ax-*` (Accessibility), `calendar-on-*`. System Events is not in
the report; the author checked it by hand at the end.

| Step | In Applications | Microphone | Accessibility | Calendars |
|---|---|---|---|---|
| 0 | the old ad-hoc build, granted | granted | granted | granted |
| 1 | certificate build over it | granted | granted | granted |
| 2 | ad-hoc impostor over the old grants | **granted** | **granted** | **granted** |
| 3 | `tccutil reset`, then granted again to the certificate build | reset → granted | reset → granted | reset → granted |
| 4 | ad-hoc impostor after that | not determined | not allowed | not asked |
| 5 | a second certificate build (release, other bytes) over the first | granted | granted | granted |

- **A stricter build does not replace the stored requirement.** At step 1
  nothing was asked, so nothing was stored anew, and the impostor at step 2
  got everything without a prompt. Existing users stay open until their
  grants are reset.
- **`tccutil reset Microphone|Accessibility|AppleEvents|Calendar
  app.capacitynotch.CapacityNotch` works without an administrator**: exit 0
  and "Successfully reset" for each, Accessibility included, as the user.
  So the application can do it itself, once, on the first launch of the
  version signed this way. The author chose that (2026-10-08): ticket 33.
- After the reset the grants are stored against the certificate's
  requirement: the impostor at step 4 got none and showed no prompt (the
  author saw none), and step 5 kept them all.

The builds' certificate: `CapaTheNotch`, SHA-1
`96F745C0374EDF111DD823B633B23C9477EFBBA5`, self-signed, Code Signing
extended key usage, valid to 2046-10-03. The private key is in the login
keychain and, exported as a password-protected .p12, on the author's Yandex
Disk, with the password in Passwords; the local copy was deleted.

## Done

- **The certificate:** `Scripts/create-signing-certificate.sh` (c516bb5,
  fixed in 4f92d0e and c7dd95a), a /wizard the author ran on 2026-10-08:
  created in Keychain Access, test signature, SHA-1 written to the
  git-ignored `.signing.env`, the key backed up off this Mac. The agent never
  saw the key.
- **The scripts:** `Scripts/signing.sh`, sourced by `build-app.sh` and
  `build-release.sh`; `publish-release.sh` names the certificate once for
  both of its builds. No certificate, no build: checked with nothing
  configured, `build-app.sh` stops before compiling with
  "No signing certificate is configured…".
- **The requirement:** `codesign -d -r-` on `.build/CapaTheNotch.app` prints
  `designated => identifier "app.capacitynotch.CapacityNotch" and
  certificate leaf = H"96f745c0374edf111dd823b633b23c9477efbba5"`; the
  bridge shows `Authority=CapaTheNotch`; `codesign --verify --deep --strict`
  passes. A copy re-signed ad-hoc with the same identifier is refused by
  `codesign --verify -R='identifier "app.capacitynotch.CapacityNotch" and
  certificate leaf = H"96f7…bba5"'` (exit 3); the real build satisfies it.
  `Scripts/test-signing.sh` checks the same against a throwaway certificate.
- **Grants survive an update / an ad-hoc build gets none:** steps 4 and 5
  above, and by the author's hand on the release build: dictation into
  Claude's field (microphone and Accessibility), System Events on in
  Privacy & Security → Automation; no prompt while the impostor ran.
- **Reproducibility:** `codesign --signing-time none` (accepted, not in its
  manual); two `build-release.sh` runs gave the same SHA-256, with the throwaway
  certificate (`80dc2fdb…67fe`) and again with the author's (`30e05e32…ce30`,
  at c7dd95a). Only the author can reproduce
  the published archive byte for byte now; README and the 0.4.0 notes say so.
- **The MediaRemote adapter stays ad-hoc:** /usr/bin/perl loads it, it holds
  no grant of ours, and the app's signature seals its hash — a re-signed
  adapter fails `codesign --verify --deep` on the app.
- **Docs:** README and README.ru (Install, Building from source),
  `docs/releases/0.4.0.md` (the signature, the one-time reset, the SHA-1).
- `swift run CapacityNotchTests`: 318 passed.

