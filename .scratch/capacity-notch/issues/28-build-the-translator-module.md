# 28: Build the translator Module

**What to build:** Russian to English and English to Russian, on this Mac:
text in, translation out, from the notch — ideally with nothing sent
anywhere.

**Blocked by:** none.

**Status:** resolved

**Why:** Asked for by the author on 2026-09-30. Local, like Dictation, so
what is translated stays on the Mac.

- [ ] Off until turned on in Settings; any model or language download is
      asked for then, and says its size first, as Dictation's does.
      *Off until turned on, and the download is asked for only then and by
      macOS: done. Stating the size: not yet. Apple's API does not report
      it, so it is to be measured on the first download (see Done).*
- [x] Translation runs on this Mac; no text leaves it. *Apple documents
      on-device processing. A check with the network off is still to do.*
- [x] Russian → English and English → Russian, the direction detected or
      chosen.
- [x] Nothing translated reaches Copy Diagnostics or the log.

## What has to be answered first

- **The engine.** Two routes to measure, as ticket 12 measured speech:
  Apple's own on-device translation (to check: which macOS version it needs
  — Capacity Notch supports macOS 14 — and whether it works fully offline
  once the languages are downloaded), or an open model run locally, with its
  size, speed and quality on the M1 Pro. → *Answered below:
  `docs/research/translator-engine.md`.*
- **How text gets in.** Typed on the surface, the current selection, the
  clipboard, or a shortcut that translates the selection in place, as
  Dictation inserts its text. → *Both, 2026-10-07.*
- **The mockup,** in Paper beside the other Modules. → *None. The page was
  built from the other pages' look, for the author to review.*
- **With Dictation:** whether speaking Russian and getting English text is in
  scope, or a later step. → *A later step.*

## Comments

**2026-10-07 — the author's decisions.**

- How text gets in: both.
  1. A global shortcut that translates the selection in the application in
     front and replaces it in place, as Dictation inserts its text.
  2. A field on the translator's page in the open surface, for typing or
     pasting, with the translation shown and copyable.
- Direction detected automatically (Cyrillic → English, Latin → Russian),
  with a way to flip it on the page.
- The engine is to be chosen from measurement.
- Speech-to-translation with Dictation is a later step, not this ticket.
- No Paper mockup. The page follows the existing Modules' look (210 points
  open), and the author reviews the visuals afterwards.

**2026-10-07 — engine verdict** (`docs/research/translator-engine.md`).

Apple's Translation framework, on macOS 26 and later. On macOS 14–15 the
Module stays off and says why.

- Apple's sessions can be made in code without a window only from macOS 26
  (`TranslationSession(installedSource:target:)`), and only for languages
  already installed. Downloads go through a SwiftUI `translationTask`
  session's `prepareTranslation()`, which macOS asks about. The size is not
  reported.
- Measured here: making a session takes 0.34 ms, checking both ways 42 ms, and `isReady` 24 ms. Before installation, `translate` throws `notInstalled` in 34 ms, without a prompt. Russian and English are `supported`, not installed, on this Mac. The framework is weak-linked, so the app still launches on macOS 14.
- The alternative, Opus-MT int8 through the vendored ONNX Runtime, is
  ≈ 110 MB a direction (≈ 220 MB both), with BLEU 31.4 ru→en / 27.1 en→ru on
  newstest2019. It would also need a Swift SentencePiece tokenizer and a
  Marian decoder written here.
- Not measured: either engine's speed and quality on developer sentences.
  Both need a download that the author approves first. Apple's is measured
  first; Opus-MT only if Apple's disappoints.

**2026-10-07 — the shortcut brings the selection to the notch.** The author
tried ⌃⌥T and expected the selection to go to the notch, not to be replaced
silently where it was. Decided (variant "a", mockups "Notch — Expanded —
Translator, selection in a field" and "… selection to read"):

- ⌃⌥T reads the selection as before (Accessibility, else ⌘C with the
  clipboard put back), translates it, and opens the surface pinned on the
  Translator page: the selection on the left, read-only and muted, the
  translation on the right.
- The header shows the direction with its flip (which translates the
  selection again) and where it came from: "из Telegram".
- Selected in a field (a text field or area whose selected text
  Accessibility lets be set, or one Dictation's delivery can write into in
  place): "Скопировать" beside a white pill, "Вставить вместо выделенного ⏎".
  The pill (or Return) brings the application back in front and puts the
  translation in place of the selection by the old path, clipboard put back,
  and the surface closes.
- Selected elsewhere (page text in a browser, a chat message): "из Safari ·
  не поле ввода", and the only action is the pill "Скопировать ⏎".
- Escape or a click elsewhere closes it; nothing is replaced unless asked
  (logged as `translator selection dismissed`).
- Nothing selected, a password field, languages missing: the same messages,
  now on the opened page, with the beep.
- Typing on the page by hand works as before.
- The log no longer writes `translator languages requested` / `answered
  needs-languages` for every press that gets the same answer: only changes.

Done on branch `translator-selection-to-surface` (off `modules-2026-10-07`).
The page's look follows "Notch — Expanded — Translator" too (15-point
direction, 14-point text in 12-point-cornered boxes). Six new tests; the run
is now `read` (never writes into the application) and `choose`. Not tried
by hand yet: the surface taking the keyboard over Telegram and Safari, Return
reaching the pill, and the field getting its focus back before the paste.

## Done

Built on 2026-10-07, on the branch for ticket 28.

- **Settings ▸ Modules ▸ Translator.**
  - Off by default.
  - On macOS older than 26 the switch stays off, and the card says it needs
    macOS 26.
  - On, the card shows:
    - the shortcut, **⌃⌥T** by default and editable. It does not collide with Dictation's ⌃⌥D or the Teleprompter's ⌃⌥Space/Esc/↑/↓.
    - the languages' state, with **Download…**, which has macOS ask its own question.
    - Accessibility, for reading the selection and replacing it when asked.
- **Shortcut.** It reads the selection through Accessibility, or by ⌘C where
  Accessibility does not report it, with the clipboard put back. It
  translates the selection and opens the surface on the Translator page with
  it (since 2026-10-07, see the comment above). Asked to, it puts the
  translation in its place, using Dictation's verified AX insertion with its
  ⌘V fallback. Then it puts the previous clipboard back, unless something
  newer was copied meanwhile.
  - If the translation cannot be put in place, it stays on the clipboard.
  - Password fields are never read.
  - One run at a time.
  - While the translator borrows the clipboard, the Shelf keeps none of
    what passes through it.
- **Page** (last in the page order).
  - Direction: `RU → EN` / `EN → RU` with a flip. The flip holds while
    editing and resets once the field is emptied.
  - Text field on the left, selectable translation on the right, translated
    after a pause in typing.
  - Copy and Clear.
  - Tapping the field keeps the surface open and takes the keyboard.
  - It is 210 points open, like every other page. The dump measures 204 at
    a 32-point menu bar.
- **Privacy.** The log and Copy Diagnostics carry only states and outcomes
  (`translator-needs-languages`, `translator shortcut inserted-ru-en`).
  Nothing translated is stored in Preferences. Turning the Module off
  forgets the page's text.
- **Russian and English UI strings**
  (`CapacityNotchCore/Translator/TranslatorLocalization.swift`).
- **Tests** (14 new, `Tests/CapacityNotchTests/TranslatorTests.swift`,
  through seams for the engine, the clipboard and the application in
  front):
  - direction detection, and the flip;
  - readiness, and one run at a time;
  - in-place replacement through Accessibility with the clipboard restored;
  - the ⌘C fallback, with the clipboard restored;
  - a translation that cannot be put in place stays on the clipboard;
  - a newer copy is never overwritten;
  - nothing selected, password fields, an unready Module and engine
    failures;
  - log and diagnostic lines carry no text;
  - off by default with its own shortcut, nothing translated kept;
  - page order;
  - Russian strings.
- **Pictures.** `CAPACITY_NOTCH_DUMP_TRANSLATOR=<folder>` draws the page in
  each state and the Settings card, with synthetic text.

**Not verified by hand:**

- macOS's download question and the languages actually downloaded, so no
  real translation has run yet;
- the Accessibility prompt;
- replacement in place and the ⌘C/⌘V fallbacks in real applications, among
  them browsers, Electron and Codex — now after the surface has held the
  keyboard, and with "field or not" decided by Accessibility (Electron
  editors that report little may be shown as "not a text field");
- the Shelf skipping the borrowed clipboard;
- typing in the page's field on the live surface;
- offline translation;
- VoiceOver;
- the visuals, for the author.

**Left to close:**

- measure Apple's download size and say it in Settings;
- speed and quality on the author's developer sentences;
- the hands-on checks above.

**2026-10-08 — closed.** The author ran selection → surface → replacement
in Telegram and asked for the ticket to be closed. Merged into `main` with
`modules-2026-10-07`. The rest of "Not verified by hand" and "Left to close"
above was not done before closing — Apple's download size in Settings,
speed and quality on developer sentences, other applications, offline,
VoiceOver — and stays as known gaps for a later ticket.
