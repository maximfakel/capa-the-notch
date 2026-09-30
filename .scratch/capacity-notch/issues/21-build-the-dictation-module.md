# 21: Build the Dictation Module

**What to build:** Local push-to-talk dictation in Capacity Notch, using the GigaAM engine evaluated in ticket 12. Implemented from the author-approved Paper mockup; awaiting hands-on runtime acceptance.

**Blocked by:** none (the author requested continuation after ticket 12’s completed feasibility work; tickets 12 and 16 remain open by the author’s choice).

**Status:** resolved

## Comments

**2026-09-26 — design interview, round 1.**

The author confirmed:

- Start with editable replacements for English developer terms after recognition, such as “диплой” → “deploy”. Ambiguous replacements apply only through an explicit personal rule. Replacement quality still needs measurement on the retained corpus; hotword biasing is not the initial remedy.
- Hold a configurable global shortcut, default ⌃⌥D; release ends recording, Esc cancels. The author requested a **60-second** limit instead of the prototype’s 25 seconds; feasibility and long-phrase quality need checking before promising measured performance.
- Insert recognised text immediately, without sending the message or executing a command. If there is nowhere to insert it, keep the result on the clipboard. Target-change and clipboard-restoration details remain to settle.
- Load the model on first use and unload after five minutes of inactivity. The measured cold-load cost is about 0.6 seconds, with about 400 MB used while loaded.

Still open: the author suggested possibly keeping recognition history in Settings. This is not yet approved retention: the earlier no-history rule remains pending an explicit decision on whether history exists, its default, contents and lifetime. Audio retention is not requested.

Next design branches: history, insertion/fallback behavior, recording and recognition states beneath the Capacity strip, interaction with other Modules, permission and model-download setup, replacements editing, cancellation and recovery.

The author explicitly said `docs/research/dictation-spike.ru.md` is personal and **must not be committed**. Do not include it in this feature’s commits.

**2026-09-26 — design interview, round 2.**

- History approved: optional, local, off by default; final recognised text only, no audio, last 50 entries, copy and delete. This supersedes the earlier blanket no-history rule for Dictation only when explicitly enabled. History-disable/delete-all behavior remains to settle.
- On the clipboard question the author said “Хранить в буфере”. Keep the result on the clipboard for fallback; whether this also overrides restoration after successful insertion remains to clarify.
- The author rejected displaying Dictation inside the Notch Surface. Instead show a separate capsule directly below the surface; two supplied screen recordings (2026-09-26 at 16.07.38 and 16.09.41) are the visual reference. Music replacement and automatic Teleprompter pause from the earlier proposal were not approved.
- First-use setup approved: separate model download with size shown, microphone permission, then offer automatic-insertion permission. Without insertion permission, clipboard mode remains usable. Ready after the model is available and microphone access granted.

**60-second investigation (read-only).** The prototype has a 25-second capture cap but only triggers recognition on key release, so automatic completion at the cap needs a state/event change. Local research records a 25-second threshold in the original GigaAM Python API with a long-form/VAD route; this does not prove a hard limit in the sherpa-onnx export. Single-pass minute-long decoding is unverified. Validate 30/45/60-second utterances, pauses and English terms, omissions/repetitions, peak memory, completion latency, cancel and release after auto-stop. Raw mono 16 kHz Float32 audio for 60 seconds is 3.84 MB, excluding inference allocations.

**Visual references inspected.** Extracted 12 evenly spaced frames from each supplied clip with AVFoundation. The first (10.87 s) shows a floating multicolour luminous orb changing shape/size, later accompanied by a weather response. The second (8.30 s) shows a separate dark translucent rounded capsule with a flowing green/cyan luminous wave, then a dark closing state. Neither cropped recording establishes placement relative to this app’s Notch Surface; “directly below the surface” comes from the author’s instruction. Exact geometry, voice-reactive behavior and transition timing are not established by these sampled frames. Proposed direction: second clip for shape, first for organic motion; confirmation pending.

**2026-09-26 — design interview, round 3.**

- Capsule appearance approved: dark translucent capsule based on the second video, organic luminous wave responding to voice level while recording, distinct motion while recognising; no persistent text, remaining time appears only for the final ten seconds.
- Capsule position approved: centred below the current lower edge of the Notch Surface, following expansion with a small gap. Visible during capture/recognition and briefly on completion, then disappears. Exact geometry belongs in the mockup.
- The author overrides completion text: communicate success through colour, for example green, rather than “Inserted”/“Copied” text. A non-colour cue is still needed to satisfy the project’s accessibility requirement; its design is pending.
- Music and Teleprompter remain unchanged; dictation does not pause Teleprompter automatically.
- Turning history off stops saving new entries; existing entries remain until individually deleted or cleared with a separate Clear History action.
- Clipboard interpretation stated to the author before this round: final result remains on the clipboard even after successful insertion; no restoration of the old clipboard. The author did not explicitly address this interpretation, so distinguish it from the directly confirmed fallback rule if a conflict arises.

**2026-09-26 — design interview, round 4.**

- Completion approved: green for both successful insertion and clipboard-only completion, with a checkmark for inserted and a clipboard symbol for copied. No completion text; colour is not the only cue.
- Error presentation overrides the prior text-first proposal: red colour plus an angular/spiky wave rather than the smooth recording wave. A discoverable way to inspect the reason and resolve permission errors still needs agreement. Do not treat the whole previous error/cancellation proposal as approved by this answer.
- The author wants a prepopulated set of IT terminology replacements rather than an empty list. Candidate rules must be editable and checked against ordinary Russian as well as the retained speech corpus. Ambiguous substitutions such as “Джейсон” → JSON must not be enabled indiscriminately. Exact initial set and rule-editing details remain to confirm.
- Capsule visible over fullscreen apps, excluded from screen capture, and does not take keyboard focus from the input field: approved as the desired behavior. Capture exclusion must be verified on this macOS version rather than assumed from an API flag.

**2026-09-26 — design interview, round 5.**

- Replacement management approved: editable initial IT rules, add/edit/disable/delete in Settings, matching whole words or phrases rather than substrings. Candidate initial examples: пул реквест → pull request, коммит → commit, диплой → deploy, гитхаб → GitHub, тайпскрипт → TypeScript, докер → Docker, кубернетес → Kubernetes, фронтенд → frontend, бэкенд → backend. Validate against the corpus before shipping. Ambiguous examples Джейсон → JSON and реакт → React are offered separately, disabled by default.
- Error explanation on clicking the red/spiky capsule approved, with a Settings path for permission problems. Esc cancels recording or recognition without changing the clipboard. Errors do not write to the clipboard.
- Interview consolidated in `../dictation-spec.md`. Awaiting confirmation of shared understanding and then a Paper mockup; this is not implementation approval of unmeasured behavior.

**2026-09-26 — shared understanding confirmed; Paper mockup ready for review.**

The author answered “Да” to the consolidated specification and asked to proceed with the mockup. Eight new editable artboards were created in Pairtask, on Notch and Settings. Exact pointers and visual decisions are in `../dictation-spec.md` under Paper mockup. The original artboards were preserved. The mockup is static and awaits the author’s visual review/edits before code; do not treat screenshot review as runtime validation. No application source changes, model downloads, commits or releases were made. The personal Russian spike report remains excluded from commits.

**2026-09-27 — author’s revision, icon actions and Modules accordion.**

The author adjusted Paper and requested Icon Only Buttons for Copy/Delete in History; replaced the four controls in place and verified the rendered result. Reference: Fluid Functionalism Button, inspected live (the indexed page was older). The author also requested hover expansion for Module cards, referring to Music/Teleprompter/Dictation artboards. Recorded the hover-accordion requirement and proposed focus/editing safeguards in `../dictation-spec.md`; this turn changes the design and specification only, not app behavior. Preserve and re-read the author’s current compact layouts before coding. No commits.


**2026-09-27 — implementation after final Paper approval.**

Built the local GigaAM controller, bounded 60-second microphone capture, hold /
release / Escape lifecycle, lazy model loading and five-minute unload, model
setup with integrity checks, verified AX delivery and clipboard fallback,
opt-in 50-result history, editable replacement rules and separate capsule.
The three Modules cards now share one disclosure header; only one is expanded,
hover does not enable anything, and text/shortcut editing suppresses incidental
hover. Icon-only history actions follow the author’s final 24-point revision.

Core tests went red before implementation and then green (137 checks total).
Release build and strict deep codesign verification passed. Geometry of the
Capacity/Music/Teleprompter surfaces stayed unchanged. Screenshot fixtures use
only synthetic content and isolated preferences. Engine trials at 30/45/60
seconds succeeded; details and limitations are in
`docs/research/dictation-implementation-validation.md`.

Independent standards review found cancellation propagation gaps in model
installation and queued recognition, plus a lost-release latch after sleep;
all corrected. The separate spec-review agent could not run because of the
workspace agent spend cap; requirements were checked locally instead. Recorder
UI duplication remains a nonblocking refactoring observation.

Status remains needs-info for the author’s runtime acceptance: microphone and
AX prompts / actual target applications, real uninterrupted minute-long speech,
fullscreen and capture exclusion on macOS 27, VoiceOver and hover feel. No
claim that those manual checks passed. No commits or publication. Tickets 12
and 16 remain open, and the personal Russian spike report remains excluded.

Motion optimisation: voice-level updates now transform the existing CA layers
instead of publishing through the full SwiftUI capsule. Short release-fixture
CPU sample improved from 2.00% to 0.43%; processing 0.14%, idle 0.21%. Installed
and reopened the signed local build; reused the spike model without downloading.

**Crash fix — 2026-09-27.** The author reported a crash while holding ⌃⌥D.
Two new crash reports showed the same Swift executor-isolation assertion from
the Core Audio tap callback: it synchronously called main-actor level/limit
closures on an audio delivery queue. Both callbacks now dispatch asynchronously
to the main queue. The updated release build and strict signature pass and are
installed. Awaiting the author’s hands-on hold/release confirmation.


**2026-09-27 — runtime insertion confirmed.** The author confirmed that recognised text now inserts into Codex after the capture-target fix and requested a commit. This confirms the previously failing target-application path; remaining manual checks above are still open. The personal Russian spike report remains excluded.

**2026-09-27 — before 0.2.0, two changes from the author.**

- Capture: the author found the capsule missing from a screen recording with
  "Appear in screen sharing and recordings" on, and ruled that the switch
  covers the whole surface and everything belonging to it. This supersedes
  round 4's "excluded from screen capture": the capsule now takes the
  surface's sharing type, including the Teleprompter's rule that a running
  Script keeps the surface out of capture whatever the switch says.
- Word replacements: **Add replacement** puts the new row at the top of the
  list, not the bottom. Order does not affect matching (longest phrase wins).
- Found while checking the capture change: on macOS 27 a window whose
  `sharingType` was once `.none` reads back `.none` whatever it is set to
  after, so the surface stayed out of capture after the switch went off and
  on, or after a Script ran, until the next launch. The surface and the
  capsule now move into a new panel when they must be shared again; checked
  in the running app (shared → off → shared, read back from the window server).
- Word replacements: the "Optional terms" section confused the author and is
  gone. JSON and React stay in the one list, unticked.

**2026-09-27 — runtime check of the Murmur orb.**

The author held ⌃⌥D in silence, released, and the orb stayed as it was until
Escape: "No speech was recognised" is an error, errors wait for a click or
Escape, and the orb's error state looked like listening. Seen live for the
first time (the static dumps cannot draw Metal), recording, recognising and
success were all the same cyan: the approved green completion and its
symbols had been lost with the capsule. Agreed with the author and done:

- "No speech was recognised" hides by itself after 2.5 s; errors that need a
  fix (microphone, model) still wait for a click or Escape.
- Inserted and copied are green with a checkmark or a clipboard; an error is
  red with an exclamation mark.
- `CAPACITY_NOTCH_PREVIEW_DICTATION` now also takes inserted, copied and error.

**2026-09-27 — runtime check, by Claude with the author.**

- The author: ⌃⌥D shows the orb; silence then left it until Escape (fixed
  above). Synthetic ⌃⌥D from Claude never reached the app while Type.app
  (gigatype) was running; the author's own key press did.
- Seen live via the motion preview: recording and recognising cyan, inserted
  and copied green with ✓ / clipboard, error red with "!".
- Capture follows the surface's switch, and the capsule follows the
  Teleprompter's rule (see ticket 16).
- Not checked: insertion beyond Codex, Escape during a live recording by
  Claude, a minute of speech, denied microphone, VoiceOver, unload after five
  minutes.
- The author, on seeing the orb: the colour is right, the symbols go —
  colour is enough. This overrides round 4's "colour is not the only cue"
  for the orb; VoiceOver still hears the outcome from the accessibility label.

**2026-09-30 — resolved.** The author: Dictation works. What the runtime
check above left unchecked, and checking it on a friend's 14″ (microphone
request, model download, Bluetooth headset), moves to ticket 22.
