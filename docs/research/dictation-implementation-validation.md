# Dictation implementation validation — 2026-09-27

Local M1 Pro, macOS 27, CLT 27, native SwiftPM build system. Source baseline
630bf11; the implementation is uncommitted. No audio was recorded or uploaded
for these checks. Existing corpus recordings were read without modification.

## Automated and build checks

- 137 executable Core checks pass, including new lifecycle cancellation / stale
  result rejection, single completion, literal whole-word replacements without
  cascading, negative Russian cases, off-by-default and bounded persistent history.
- `swift run --build-system native CapacityNotchTests`.
- `./Scripts/build-app.sh`; `codesign --verify --deep --strict .build/CapacityNotch.app`.
- Signed with the audio-input hardened-runtime entitlement and an explicit
  microphone usage description. The entitlement allows asking; it grants no
  user consent. Apple reference:
  https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.audio-input
- Model hashes are verified before loading and after downloading; installed
  static runtime and model licences are bundled with the app.

## Engine feasibility

Concatenated existing WAVs in filename order, converted to mono 16 kHz, cropped
to exactly 30 / 45 / 60 seconds. These are **not new continuous-speech recordings**.
No recognised text was written to a log by this harness.

| Audio | Recognition incl. first cold load | Process peak RSS |
|---|---|---|
| 30 s | 1.582 s | 435 MiB |
| 45 s | 1.124 s | 533 MiB |
| 60 s | 1.599 s | 689 MiB |

The latter rows use the warm model. Peak RSS is cumulative process high-water,
not retained memory after unloading. No engine length failure occurred. This
supports using the full 60-second buffer without an arbitrary cut at 25 seconds;
it does not establish omission/repetition quality for uninterrupted speech.

## Replacements

Applied the nine default rules to the current retained `Recordings/score.md`:
33 phrases, 409 reference words, 94 word edits both before and after (23.0%).
None of these nine phrases matched that particular output. No improvement is
claimed. The older research report describes other decoder experiments; its
WER must not be substituted for this saved score file. Whole-word and ambiguous
name negatives pass, but an empirically useful vocabulary still needs tuning.

## Visual and geometry checks

Paper was re-exported after the author’s edits. Settings dumps in light/dark
cover all three accordion states, history, replacements and setup. Capsule
fixtures cover recording/countdown, processing, both completions and error.
The final history icon controls are 24 × 24, radius 6, glyph 14, gap 6.
The capsule is 112 × 52 and anchored 12 points under the target surface edge.

Measured existing layouts:
- strip 38, card 174, detail 194, column 252, width 560;
- music row 54, page 127, open 185, closed 92;
- teleprompter row 94, closed 132, open 209.

Reproduce synthetic visual fixtures without microphone/permission prompts:
`CAPACITY_NOTCH_DUMP_DICTATION=/tmp/dictation-ui <app executable>`.
Motion fixture: `CAPACITY_NOTCH_PREVIEW_DICTATION=recording` (or `recognizing`,
`idle`) exits after 20 seconds, uses isolated preferences and synthetic levels,
and does not start providers, hotkeys, microphone or inference.

## Delivery and outstanding acceptance

Insertion uses a verified writable AX selected-text attribute. Clipboard is
always retained after successful recognition. Unsupported AX editors and any
change of app, focused field, selection or original value cause clipboard
fallback. Already-running C inference cannot be preempted; cancellation rejects
its output, while queued canceled work is skipped before loading/decoding.

Still unverified: actual microphone permission grant/denial on this app bundle;
actual hotkey cap/release and Escape through macOS; AX delivery in the author’s
apps; 60 seconds of uninterrupted live speech; runtime fullscreen and screen
capture exclusion; VoiceOver; five-minute memory release observed externally;
real-network download interruption/retry. There was no network model download.

The capsule declares capture exclusion using the public NSWindow sharing type;
that declaration is not evidence that every macOS 27 capture route honours it.


## Capsule CPU and local install

Release executable, synthetic fixture, sampled process CPU time between seconds
3 and 17 (14-second window; excludes inference and WindowServer CPU): idle
0.21%, recording initially 2.00%, processing 0.14%. Moving level updates from
SwiftUI publication directly to the existing Core Animation layers reduced the
retested recording state to **0.43%**. This is a short local measurement, not a
battery or thermal endurance test. Reduce Motion keeps the waveform static.

Installed the signed build at `/Applications/CapacityNotch.app` and verified
its strict deep signature. Reused the existing spike model in Application
Support without downloading or changing the Dictation/history enable flags.
The app was reopened; microphone and Accessibility permissions were not granted
programmatically. No commit or publish was performed.

## Crash on hold-to-dictate — 2026-09-27

Two fresh user-run `CapacityNotch` crash reports (01:12:01 and 01:12:36 local)
showed the same `EXC_BREAKPOINT` / `SIGTRAP` stack: Swift's executor-isolation
assertion from `DictationMicrophone.start`'s Core Audio tap callback on the
Audio tap delivery queue. The tap directly invoked a callback created in the
main-actor controller. Recording never reached recognition.

The audio-level and 60-second-limit callbacks are now queued asynchronously
onto the main dispatch queue before invoking their controller closures. The
release build compiles, passes strict deep signature verification, and has
been installed and reopened. Manual hold/release on the author's microphone is
still needed to confirm the fix in the original scenario.
