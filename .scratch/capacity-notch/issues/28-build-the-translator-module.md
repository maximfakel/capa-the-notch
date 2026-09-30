# 28: Build the translator Module

**What to build:** Russian to English and English to Russian, on this Mac:
text in, translation out, from the notch — ideally with nothing sent
anywhere.

**Blocked by:** none.

**Status:** needs-info

**Why:** Asked for by the author on 2026-09-30. Local, like Dictation, so
what is translated stays on the Mac.

- [ ] Off until turned on in Settings; any model or language download is
      asked for then, and says its size first, as Dictation's does.
- [ ] Translation runs on this Mac; no text leaves it.
- [ ] Russian → English and English → Russian, the direction detected or
      chosen.
- [ ] Nothing translated reaches Copy Diagnostics or the log.

## What has to be answered first

- **The engine.** Two routes to measure, as ticket 12 measured speech:
  Apple's own on-device translation (to check: which macOS version it needs
  — Capacity Notch supports macOS 14 — and whether it works fully offline
  once the languages are downloaded), or an open model run locally, with its
  size, speed and quality on the M1 Pro.
- **How text gets in.** Typed on the surface, the current selection, the
  clipboard, or a shortcut that translates the selection in place, as
  Dictation inserts its text.
- **The mockup,** in Paper beside the other Modules.
- **With Dictation:** whether speaking Russian and getting English text is in
  scope, or a later step.
