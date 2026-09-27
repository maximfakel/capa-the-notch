# Dictation Module — design specification

Status: implementation authorised after the author’s Paper edits on 2026-09-27. Runtime insertion in Codex was confirmed on 2026-09-27; remaining manual acceptance checks are tracked in issue 21. The author explicitly authorised a commit on 2026-09-27; publication still requires separate approval.

## Purpose

Hold a shortcut, speak Russian with IT terminology, release to recognise locally and insert text into the application being used. No automatic message sending or command execution. GigaAM is the chosen engine; the Module is off by default.

## Capture and processing

- Configurable global shortcut, default ⌃⌥D. Hold to record; release stops recording and starts recognition.
- Maximum recording duration: 60 seconds. At the limit, stop the microphone and start recognition without waiting for key release; subsequent release must not process twice.
- Esc cancels recording or recognition. Cancellation and errors do not change the clipboard.
- Load the model on first use; unload after five minutes of inactivity. About 0.6 seconds cold loading and about 400 MB are prototype measurements, not measured minute-long recognition performance.
- No audio history, uploads or text in diagnostic logs. An explicitly enabled text history is the agreed exception to the original no-history policy.

## Delivery

- Insert immediately into the original input target when insertion is available; never send or execute the text.
- If insertion is unavailable or the user switched applications, leave the result on the clipboard.
- The author said “Хранить в буфере”; the consolidated interpretation is to leave the result there after successful insertion too. This interpretation was stated in the interview and is included in the final confirmation summary.
- Show a brief green completion state: checkmark for inserted, clipboard symbol for clipboard-only completion; then disappear.
- Do not claim a verified insertion merely because a synthetic paste was sent. Determine a defensible delivery/fallback strategy during implementation and surface any limitation before finalising those states.

## Dictation Capsule

- Separate from the Notch Surface, centred with a small gap beneath its current lower edge, following expansion. Exact dimensions and transitions are to be designed in Paper.
- Dark translucent capsule, organic luminous green/cyan wave from the second recording; first recording also references organic changing light and form.
- During recording, the wave responds to voice level. Recognition uses a distinguishable motion. No persistent text; remaining time appears during the final ten seconds.
- Success: green plus checkmark/clipboard symbol, not colour alone.
- Failure: red with an angular/spiky wave. Click to inspect the reason and, for permission failures, reach Settings. Error timeout/retry details belong in the recovery-state mockup.
- Esc dismisses/cancels without changing the clipboard.
- Music and Teleprompter continue unchanged. No automatic Teleprompter pause or row replacement.
- Visible over fullscreen applications, excluded from screen capture, without stealing typing focus. Verify exclusion on target macOS.
- Accessibility and Reduce Motion requirements from the application still apply. The animation is an implementation/measurement task, not permission to exceed the project’s performance budget.

## Replacements

- Settings → Modules → Dictation contains editable “Recognised → Replace with” rules with add, edit, disable and delete.
- Whole-word/phrase matching, case-insensitive; retain the replacement’s specified spelling/case.
- Seed with IT terminology; candidate examples are in issue 21. Validate replacements on the retained corpus and ordinary Russian negative cases.
- Ambiguous replacements such as Джейсон → JSON are separate, disabled by default. No arbitrary substitutions inside other words.

## History

- Optional, local, off by default; final text only, last 50 entries, no audio.
- Copy and delete an entry; separate Clear History action.
- Disabling history stops new entries being saved but preserves existing entries until deleted.

## First use

- Explain and separately download the model with size shown; then request microphone access and offer permission for automatic insertion.
- Without insertion permission, clipboard-only mode remains usable.
- Ready when model availability and microphone permission permit dictation.
- Model download licensing/notice, integrity, interruption and retry states need implementation and mockup coverage. Do not download anything during design; follow the project’s explicit-download-approval rule.

## Validation before completion

- Real 30/45/60-second recordings: continuous speech, pauses, English terms; omissions, repetitions, quality, latency and peak memory. Current prototype evidence stops at 23.5 seconds. Determine whether silence-aware segmentation is needed; the Python long-form path does not prove a hard limit in the sherpa-onnx export.
- Automatic stop/recognition at the cap, later hotkey release, cancellation during capture/processing, repeated invocation and no double insertion.
- Insertion/fallback on actual target applications, focus changes and clipboard behavior.
- Capsule placement across open/closed surface, fullscreen, active Teleprompter, capture exclusion, keyboard focus, Reduce Motion and accessibility.
- Core TDD for meaningful state and replacement/history boundaries; measure animation CPU rather than assume it is cheap.

## Work sequence

Confirm this shared understanding → Paper mockup (author-editable source of truth) → implementation and verification. Keep tickets 12 and 16 open as requested. Dictation precedes ticket 20. Confirm each commit/publish separately; the author explicitly requested the implementation commit on 2026-09-27. Never include the personal `docs/research/dictation-spike.ru.md` in a commit.

## Paper mockup — 2026-09-26

File: Pairtask (`01M2T7VMGXAGTQ95Z7DHV6CZ1T`). Existing designs were cloned as context; the original surface and Settings artboards were not edited.

[Notch page](https://app.paper.design/file/01M2T7VMGXAGTQ95Z7DHV6CZ1T/p-2-0):

- `2UP-0` — Dictation — Capsule states: recording, last ten seconds, recognising, inserted, copied, error. State labels are external annotations, not capsule UI.
- `2WZ-0` — Dictation — Placement: compact, music, running Teleprompter, expanded Capacity surface.
- `3IY-0` — Dictation — Error detail and fullscreen.

[Settings page](https://app.paper.design/file/01M2T7VMGXAGTQ95Z7DHV6CZ1T/p-3-0):

- `2X0-0` — Settings — Modules — Dictation.
- `37T-0` — Settings — Dictation — First use.
- `39S-0` — Settings — Dictation — Replacements: nine active starter rules, two ambiguous examples off by default.
- `3BR-0` — Settings — Dictation — History, with synthetic sample text.
- `3IX-0` — Dictation — Setup and recovery states: download progress/interruption, microphone request/denial, optional insertion permission, clipboard mode, shortcut conflict, empty history.

Proposed geometry verified through computed styles: capsule 112 × 52 pt, radius 26 pt, 12 pt below the current surface bottom. Settings retain the 760 pt window width, 200 pt sidebar and SF Pro Text. The new primary text buttons use #3263CE for contrast; existing module toggles remain #6B97FF. Primary capsule colours are #6DEBD8 (recording), #63E692 (completion), #FF625D (error). Reduce Motion note proposes a still recording wave and static processing symbol.

Screenshots reviewed for spacing, typography, contrast, alignment and clipping. Artboards use content-based height. This is a static, editable design proposal: audio-reactive motion, transition timing, actual keyboard/accessibility behaviour, insertion and capture exclusion have NOT been implemented or verified. Re-read Paper after the author’s edits before coding. No model was downloaded and no application source was changed during mockup creation.

## Author’s Paper revision — 2026-09-27

The author edited the mockup. Re-read History (`3BR-0`) and all three Modules states (`1RB-0`, `2L3-0`, `2X0-0`) from Paper before this update. They now show denser rows, history actions beside the timestamp, and one expanded Module with the other two collapsed. Preserve these edits and fetch their current values before implementation; earlier screenshots/row dimensions are superseded.

History: replaced only the four Copy/Delete controls on `3BR-0` with compact secondary Icon Only Buttons, based on the current live Fluid Functionalism Button playground (https://www.fluidfunctionalism.com/docs/button). 28 × 28 pt hit surface, radius 8 pt, 16 pt copy/trash glyphs, 6 pt inter-button gap, neutral #E5E5E5 background with #585858 glyphs. Preserved the author’s top-right placement, text and spacing. Names for implementation: Copy and Delete, exposed as tooltips and accessibility labels. Paper layer names identify these actions; runtime accessibility is not verified by the static mockup. Screenshot review passed: aligned actions, no clipped text or overflow.

Modules: the author requested accordion expansion on hover. Treat the three linked artboards as states of one Modules view, not separate pages. Implementation behavior proposed alongside that request:

- Open a card on deliberate hover over its header; show only one expanded card at a time.
- Moving the pointer from header into the expanded controls must not close the card. Keep the last opened card open when the pointer leaves the group; open another only on an intentional new header interaction.
- While a text field/shortcut editor/control within a card has keyboard focus, do not collapse it due to incidental hover elsewhere. Preserve edits, selection and scroll position.
- Provide keyboard activation of the disclosure header with Enter/Space and expose expanded/collapsed state to VoiceOver. Clicking the header also provides an explicit alternative to hover.
- Expansion only reveals settings. It must never enable the Module or request permissions; the on/off switch remains a separate action.
- Exact hover delay and animation are not established by these static artboards; tune and test them during implementation, including Reduce Motion and fast pointer movement through stacked headers.

No hover interaction has been implemented in the app in this design-edit turn. The three author-edited Modules artboards were inspected but not visually changed.


## Latest export and implementation — 2026-09-27

The author’s final Paper export supersedes the earlier button proposal:
History actions are white 24 × 24 controls, radius 6, glyphs 14, gap 6,
beside the timestamp. Modules use the shared disclosure header with an
independent enable toggle. Optional ambiguous terms retain their own section.

Delivery uses an editable AX selection captured at recording start, verifies
that app, field, selection and original value are unchanged, writes selected
text, and verifies the resulting full value. Unsupported fields fall back to
the clipboard. No synthetic Return or Send, and no unverified paste checkmark.
Some apps expose no writable AX selection and will therefore be clipboard-only.

The local model and static frameworks already on this Mac were reused; no new
model download was performed. The module and history retain off-by-default
preferences. Permission grants remain the person’s choice.

See `docs/research/dictation-implementation-validation.md` for measurements and
explicitly outstanding runtime checks. A 60-second concatenation validates
engine feasibility, not continuous-speech quality or end-to-end microphone
permission / key-release behavior.
