# 22: Leave the beta

**What to build:** Capacity Notch 1.0, still free and still without a
Developer ID: the release that stops calling itself a beta, and the list of
what has to be true before it does.

**Blocked by:** none.

**Status:** needs-triage

**Why:** Every release since 0.1.0 calls itself a beta, and nothing written
down says what would end that. Without a list, "beta" means "not sure yet"
forever.

Decided already, by the author on 2026-09-30:

- **Free, ad-hoc signed, not notarized.** No paid Apple Developer Program.
  1.0 is not a signing change; the README and release notes keep saying
  plainly that it is not Developer ID signed or notarized, and why macOS
  warns on first open (as ticket 11 requires).
- **Updates stay manual.** "Check for Updates…" opens the latest GitHub
  Release. Sparkle is not a condition of 1.0.

## What has to be true

- [ ] **Onboarding redone.** The first-launch window is designed again in
      Paper, the author settles its sizes, and it is built and translated
      into Russian like the rest of the interface.
- [ ] **Checked on a Mac that is not the author's.** A 14″ Mac, from a
      fresh install of the published zip: the first-launch warning and its
      approval, onboarding, both Providers, working offline, a Capacity
      Alert, Launch at Login, copying diagnostics, and "Check for
      Updates…". This is ticket 11's clean-Mac test, minus Sparkle.
- [ ] **Dictation on that Mac.** The microphone request, the model
      download, a Bluetooth headset, and a denied microphone that says what
      to do.
- [ ] **What tickets 16 and 21 left unchecked.** Teleprompter: two-finger
      scrolling on the row, dragging the progress, Reduce Motion, VoiceOver.
      Dictation: insertion outside Codex, Escape during a recording, a
      minute of speech, unloading after five minutes, VoiceOver.
- [ ] **The word "beta" goes.** README, release notes template and the
      release title say 1.0, and nothing else about the install changes.

## Not this

- Developer ID signing, notarization, Sparkle — decided above.
- Tickets 14 (trackpad tap) and 20 (following the voice): new features, not
  conditions for leaving the beta.
- The compact expanded surface for 14″ and 13″: the author saw both display
  modes on a 14″ M5 Pro and nothing needs changing.
