# Dictation spike (ticket 12)

A throwaway prototype, kept apart from Capacity Notch, that proves GigaAM v3
(punctuated RNN-T) through sherpa-onnx on this Mac. Evidence for a go/no-go,
not product code. Findings: `docs/research/dictation-spike.md`.

## What it downloads, and where

Nothing here is committed (`.gitignore`); fetch it once:

```sh
cd Spikes/Dictation
mkdir -p Vendor Models && cd Vendor
curl -LO https://github.com/k2-fsa/sherpa-onnx/releases/download/xcframework/sherpa-onnx-v1.13.8-macos-static.xcframework.zip   # 11.6 MB, sha256 93f7a064…e7e5
curl -LO https://github.com/csukuangfj/onnxruntime-libs/releases/download/v1.28.2/onnxruntime-macos-static-xcframework-1.28.2.xcframework.zip   # 23.7 MB, sha256 cb0b0bec…3da0
unzip -q '*.zip' && rm *.zip
curl -L -o SHERPA-ONNX-LICENSE https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v1.13.8/LICENSE
cd ../Models
curl -L https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-transducer-punct-giga-am-v3-russian-2025-12-16.tar.bz2 | tar xj   # 170.2 MB
```

`Sources/SherpaOnnx/SherpaOnnx.swift` is sherpa-onnx's own Swift wrapper at
v1.13.8, unmodified (Apache-2.0, Copyright (c) 2023 Xiaomi Corporation); its
licence is beside it in `Sources/SherpaOnnx/LICENSE`. The model is MIT
(Copyright (c) 2024 GigaChat Team); its `LICENSE` comes in the archive. The
spike is not part of Capacity Notch and ships with nothing, so none of this
is in `THIRD_PARTY_NOTICES.md`; a Dictation Module would have to add both.

## Running it

```sh
swift build --build-system native -c release --product dictation-spike
.build/release/dictation-spike decode Models/*/test_wavs/example.wav
.build/release/dictation-spike record-corpus   # read the corpus aloud; recordings stay in Recordings/
.build/release/dictation-spike score           # scores into Recordings/score.md
.build/release/dictation-spike window Recordings/l01.wav
.build/release/dictation-spike ptt             # hold ⌃⌥D, speak, release
swift run --build-system native SpikeCoreTests
```

Microphone access is asked for by `record-corpus` and `ptt` only; `ptt`
asks for Accessibility to paste, and without it leaves the text on the
clipboard. Both permissions belong to whichever terminal runs the spike.
Audio is held in memory and dropped after recognition. What is kept, all in
`Recordings/` and never committed: the corpus recordings, `score.md` (each
phrase and what was recognised), and the hotwords files. The spike also
prints recognised text to its terminal. Delete `Recordings/` when the spike
is closed.
