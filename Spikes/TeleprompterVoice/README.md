# Teleprompter voice-following measurement (ticket 20)

A throwaway harness, kept apart from CapaTheNotch, that answers one question:
can GigaAM, re-decoding a sliding window every 0.2 s, follow a voice reading
the Script closely enough — about 0.3 s from word spoken to word lit — at an
acceptable cost on this M1 Pro? Findings:
`docs/research/teleprompter-voice-follow.md`.

It measures the app's own code, not a copy: `Sources/FollowCore/ScriptFollower.swift`
is a link to `Sources/CapacityNotchCore/Teleprompter/ScriptFollower.swift`, and
`Vendor` is a link to the app's `Vendor/Dictation` (sherpa-onnx 1.13.8 and ONNX
Runtime, the same static frameworks the app links).

## What it needs, and where

- **GigaAM**: the model the Dictation Module downloads, read from
  `~/Library/Application Support/CapacityNotch/Dictation/sherpa-onnx-nemo-transducer-punct-giga-am-v3-russian-2025-12-16`
  (or `GIGAAM_MODEL=<folder>`).
- **T-One** (only if wanted, for comparison): into `Models/`, never committed:

  ```sh
  mkdir -p Models && cd Models
  curl -L https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-streaming-t-one-russian-2025-09-08.tar.bz2 | tar xj   # 128.5 MB
  ```

- **Speech**: synthesised with macOS's own Russian voice (`say -v Milena`),
  from a Script written for this harness — no one's own recordings. It goes to
  `Audio/`, never committed.

## Running it

```sh
cd Spikes/TeleprompterVoice
swift build -c release
.build/release/voice-follow-spike synth                    # five scenarios into Audio/, with word timings
WINDOW=3 THREADS=2 .build/release/voice-follow-spike follow # all five, in real time
WINDOW=2 THREADS=1 .build/release/voice-follow-spike follow straight
LOOPS=6 .build/release/voice-follow-spike follow straight  # five minutes, for heat
.build/release/voice-follow-spike follow-tone              # T-One, streaming
```

Scenarios: `straight` (read through), `pauses` (the voice stops twice for
5 s), `skip` (a line left out), `offscript` (a few sentences that are not the
Script), `repeat` (a phrase said twice). Each run plays the audio at real
speed in 0.1 s buffers, as the microphone would, so the CPU, memory and
thermal figures are those of a person reading.

Word timings for scoring come from a full-context GigaAM decode of each
segment (the best the model gives); "lit after word end" is the time from
that word's last token to the moment the follower first reaches it. The
harness prints no recognised text.
