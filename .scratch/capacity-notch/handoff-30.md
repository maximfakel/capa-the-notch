# Handoff: ticket 30 — sign with the author's own certificate

Prepared 2026-10-08 for a fresh chat. Read this, then the ticket itself:
`.scratch/capacity-notch/issues/30-sign-with-the-authors-own-certificate.md`
(it is the source of truth for the acceptance criteria). The author writes in
Russian; answer in Russian.

## The project in two lines

CapaTheNotch (formerly Capacity Notch) — a Swift macOS app in the MacBook
notch hosting Modules: Capacity (Codex / Claude Code / OpenCode limits),
Music, Teleprompter, Dictation, Shelf, Calendar, Translator. Free beta,
Apple Silicon, macOS 14+. Version in `Packaging/Info.plist` is 0.3.1; a lot
is merged on `main` and not yet released. Vocabulary is in `CONTEXT.md`,
decisions in `docs/adr/`, tickets in `.scratch/` (see
`docs/agents/issue-tracker.md`).

## The problem

Every build is signed ad-hoc with a named designated requirement:

```
designated => identifier "app.capacitynotch.CapacityNotch"
```

TCC stores that requirement with each grant (microphone, Accessibility,
Automation of System Events, Calendars) and checks later processes against it
alone, so any ad-hoc build with the same bundle id inherits them silently.
Raised publicly on Threads on 2026-10-07. The fix: a self-signed code-signing
certificate the author holds, and a requirement that names it:

```
designated => identifier "app.capacitynotch.CapacityNotch" and certificate leaf = H"<SHA-1>"
```

No Developer ID, no notarization, no bundle id change (ticket 22 declined
them; a new bundle id would reset preferences).

## Where the code is

- `Scripts/build-app.sh:55-62` — install-loop build. Signs
  `Contents/MacOS/CapacityNotchClaudeBridge` first (Claude Code runs it
  directly), then the bundle with `Packaging/CapacityNotch.entitlements` and
  the named requirement. The comment there explains why the requirement is
  named (ad-hoc default = the build's hash = every update lost every grant).
- `Scripts/build-release.sh:97-102` — the same for the release zip. This
  script is built for **byte-for-byte reproducibility** (fixed scratch path,
  no debug info, files stamped with the commit time, sorted zip); read its
  header before touching it. A certificate signature may embed a signing
  time — check `--timestamp=none` and whether two builds still match.
- `Scripts/build-adapter.sh:57,65` — the MediaRemote adapter framework and
  its test client, ad-hoc. Loaded by `/usr/bin/perl`, not by the app, so
  Hardened Runtime is not its to set. Decide whether it changes at all and
  say why in the commit; it holds no TCC grant of ours.
- `Scripts/publish-release.sh` — publishing; release notes live in
  `docs/releases/<version>.md`; README in `README.md` and `README.ru.md`.
- Entitlements: audio-input, automation.apple-events, calendars.
- Accessibility is now also used by the Translator
  (`Sources/CapacityNotch/TranslatorController.swift`, `AXIsProcessTrusted`),
  not only Dictation — include it when checking grants.

## Order of work

1. **Author's step, not yours.** The certificate is created once by the
   author in the login keychain, with the Code Signing EKU, and its private
   key backed up off this Mac. Write a `/wizard` script that walks them
   through it (Keychain Access → Certificate Assistant, or `security` /
   `openssl`). You never create, read, export or commit the key.
2. **Scripts.** Both build scripts sign the bridge and the app with that
   identity, chosen by name or SHA-1 from an environment variable or a
   local git-ignored file (add it to `.gitignore`). Missing identity → fail
   plainly; never fall back to ad-hoc. The requirement adds
   `certificate leaf = H"…"`.
3. **Verify the requirement** with `codesign -d -r-` and show that an ad-hoc
   re-signed copy with the same identifier fails
   `codesign --verify -R='<requirement>'`.
4. **Measure the migration on this Mac** (the ticket's "What has to be
   answered first"): does approving a stricter build replace the stored
   requirement, or does an ad-hoc impostor still match the old one? Does
   `tccutil reset Microphone|Accessibility|AppleEvents app.capacitynotch.CapacityNotch`
   work without admin, so the app could reset once on first launch of the new
   version — or must release notes ask people to remove and re-add it in
   Privacy & Security? Write the findings into the ticket under
   `## Comments`.
5. **Grants survive an update** between two certificate-signed builds, and
   an ad-hoc build does **not** get them — both checked by the author on this
   Mac (they confirm by hand; ask them, don't claim it).
6. **Reproducibility** still holds, or the release notes say why not.
7. **Docs.** README (both languages) and release notes: signed with the
   author's own certificate, not Apple's; why macOS still warns on first
   open; the certificate's SHA-1 to compare with `codesign -dvv`.
8. Ticket 22 (`22-leave-the-beta.md`) lists this as a 1.0 condition — tick
   it there when done.

## House style

- Commits: `feat:` / `fix:` / `chore:` / `docs:` + a lowercase sentence of
  what is now true for the person, e.g. "fix: the bridge believes the
  session whose limits changed last". End with
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Recent work lands on a branch and is merged into `main`. There is no git
  remote; don't push.
- Closing a ticket: tick the boxes, `**Status:** resolved`, and add a
  `## Done` section that points to the commits and how each box was checked.
  Items needing the author's hands get closed only after they confirm.
- Tests: `swift run CapacityNotchTests` (222 passed at last count, before the
  2026-10-07 modules merge).

## Out of scope

Developer ID, notarization, Sparkle, changing the bundle identifier.
