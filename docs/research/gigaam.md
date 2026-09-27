# GigaAM for Capacity Notch: licence, variants, native runtime, streaming

Research note for tickets 12 (Dictation spike) and 20 (the Teleprompter
follows the voice). Every source was read on **2026-09-26** unless marked
otherwise. **Source:** marks what a source says. **Inference:** marks my own
reasoning. Don't read an inference as a fact.

## Summary

- **Licence.** The GigaAM code is MIT. The v3 and Multilingual weights on
  Hugging Face are also tagged MIT. v1 was first released under a
  non-commercial licence, and was moved to MIT in December 2024. An MIT app
  that downloads the weights separately and runs them is fine. The
  obligation is to keep the MIT notice ("Copyright (c) 2024 GigaChat Team").
  sherpa-onnx is Apache-2.0 and ONNX Runtime is MIT; both are compatible.
- **Runtime.** sherpa-onnx already ships GigaAM v1, v2 and v3 as int8 ONNX
  archives (~163–205 MB each), including the v3 punctuated models (e2e).
  They are **offline (non-streaming) only**, through the C API and a SwiftPM
  package with prebuilt macOS xcframeworks. No Python is needed. There is no
  Core ML model.
- **Streaming.** No released GigaAM checkpoint can stream: they were all
  trained with full-context attention, and the maintainers say that turning
  on local attention only at inference "may noticeably degrade quality". The
  paper's own 200 ms streaming experiments reach 10–12 % WER, against 3.3 %
  for full context, and those models were never released. What is left is
  *simulated* streaming: re-decoding a growing or sliding window every
  ~0.2 s, which sherpa-onnx demonstrates for other models. Token
  timestamps are available, at 40 ms resolution.
- **English terms.** The plain `v3_ctc` / `v3_rnnt` vocabularies hold **only
  the 33 Cyrillic letters and a space**, so they cannot write an English word
  in Latin letters. The `v3_e2e_*` tokenizers do contain Latin pieces, and
  Sber says e2e outputs "English domain terms". There is no published
  evaluation of Russian–English code-switching.
- **Bottom line for ticket 12:** go ahead with sherpa-onnx +
  `sherpa-onnx-nemo-transducer-punct-giga-am-v3-russian-2025-12-16` (e2e RNN-T)
  or its CTC twin. 25 s phrases match GigaAM's own `transcribe` limit. The
  spike still has to measure accuracy on English terms and latency on the
  M1 Pro.
- **Bottom line for ticket 20:** GigaAM cannot meet "streaming with ~0.3 s
  latency" natively. It is only possible with simulated streaming (window
  re-decoding), and its cost and accuracy at the window edge are unmeasured.
  The spike must measure it. If it falls short, ticket 20 needs another
  answer: either a real streaming model, or aligning CTC output against the
  known Script (see §4).

## 1. Licences

**Source:**
- The repository `LICENSE` is MIT, "Copyright (c) 2024 GigaChat Team"
  ([LICENSE](https://github.com/salute-developers/GigaAM/blob/main/LICENSE)).
  GitHub's API reports `spdx_id: MIT`.
- The only commit to `LICENSE` is `42436bfb` (2024-12-13), titled "GigaAM-v2:
  MIT license, updated weights, ONNX". It removed `GigaAM License_NC.pdf`
  ([commit](https://github.com/salute-developers/GigaAM/commit/42436bfb)).
  Before that, the README linked "License" to that NC PDF
  ([README at 8d707a89](https://github.com/salute-developers/GigaAM/blob/8d707a8904480e6acaa6b52f6890d21a02e6d252/README.md)).
  The README's news list says: "2024/12 — MIT License, GigaAM-v2"
  ([README](https://github.com/salute-developers/GigaAM#latest-news)).
- The Hugging Face model cards `ai-sage/GigaAM-v3`
  ([card](https://huggingface.co/ai-sage/GigaAM-v3)) and
  `ai-sage/GigaAM-Multilingual`
  ([card](https://huggingface.co/ai-sage/GigaAM-Multilingual)) both carry
  `license: mit` and are not gated.
- Checkpoints for every variant (`emo`, `v1_*`, `v2_*`, `v3_*`,
  `multilingual_*`) are downloaded from
  `https://cdn.chatwm.opensmodel.sberdevices.ru/GigaAM/<name>.ckpt`
  ([gigaam/\_\_init\_\_.py](https://github.com/salute-developers/GigaAM/blob/main/gigaam/__init__.py)).
  That CDN has no licence file of its own.
- The paper says they released "foundation and ASR models, along with the
  inference code, under the MIT license"
  ([arXiv 2506.01192](https://arxiv.org/html/2506.01192)).
- sherpa-onnx is Apache-2.0 (GitHub API). Its GigaAM export README
  points to GigaAM's `LICENSE`
  ([scripts/nemo/GigaAM/README.md](https://github.com/k2-fsa/sherpa-onnx/blob/master/scripts/nemo/GigaAM/README.md)).
  The v2 and v3 archives bundle GigaAM's MIT `LICENSE`
  ([run-ctc-v2.sh](https://github.com/k2-fsa/sherpa-onnx/blob/master/scripts/nemo/GigaAM/run-ctc-v2.sh),
  [run-ctc-v3-punct.sh](https://github.com/k2-fsa/sherpa-onnx/blob/master/scripts/nemo/GigaAM/run-ctc-v3-punct.sh)).
  The **v1 archives (`…giga-am-russian-2024-10-24`) bundle
  `GigaAM License_NC.pdf`**, and their doc pages still warn "It is for
  non-commercial use only"
  ([run-ctc.sh](https://github.com/k2-fsa/sherpa-onnx/blob/master/scripts/nemo/GigaAM/run-ctc.sh),
  [NeMo CTC Russian docs](https://k2-fsa.github.io/sherpa/onnx/pretrained_models/offline-ctc/nemo/russian.html),
  [NeMo transducer docs](https://k2-fsa.github.io/sherpa/onnx/pretrained_models/offline-transducer/nemo-transducer-models.html)).
- ONNX Runtime is MIT (GitHub API, `microsoft/onnxruntime`).

**Inference:**
- v2, v3 and Multilingual weights are MIT with no use restrictions. The only
  obligation is to keep the copyright notice and licence text: ship them with
  the model download and list them in the app's acknowledgements.
- MIT has no field-of-use limits, so an MIT app downloading the model
  separately is compatible with ADR 0002. Apache-2.0 sherpa-onnx is also
  compatible, provided its licence text (and any NOTICE) goes into the
  acknowledgements. I found no NOTICE file in the sherpa-onnx tree, only
  `LICENSE`.
- v1 is the one ambiguous case. The sherpa-onnx v1 archive was made from the
  pre-MIT weights and carries the NC licence, and nothing says the relicence
  covered that exact artefact. **Avoid v1 entirely.** v3 is better anyway.

## 2. Versions and variants

**Source** (README, [evaluation.md](https://github.com/salute-developers/GigaAM/blob/main/evaluation.md),
HF cards, configs):

| Line | Pretrain / ASR hours | Variants | Params | Output alphabet |
|---|---|---|---|---|
| v1 (2024-04/05) | 50k / 2k | `v1_ssl`, `v1_ctc`, `v1_rnnt`, `emo` | 240M (paper) | Cyrillic |
| v2 (2024-12) | 50k / 2k | `v2_ssl`, `v2_ctc`, `v2_rnnt` | 240M | Cyrillic |
| v3 (2025-11) | 700k / 4k | `v3_ssl`, `v3_ctc`, `v3_rnnt`, `v3_e2e_ctc`, `v3_e2e_rnnt` | "220–240M" (HF card) | `ctc`/`rnnt`: 33 Cyrillic letters + space; `e2e_*`: SentencePiece 256 (CTC) / 1024 (RNN-T) with punctuation, capitals, digits and Latin |
| Multilingual (2026-06/07) | 2M / 50k, 70+ languages | `multilingual_ssl`, `multilingual_ctc` (220M), `multilingual_large_ssl`, `multilingual_large_ctc` (600M) | 220M / 600M | charwise CTC, 70 classes including Latin a–z and Cyrillic |

- The v3 encoder is a 16-layer Conformer (d_model 768, 16 heads) with
  4× conv1d subsampling. Features are 64 log-mels at 16 kHz with 10 ms hop,
  and `win_length`/`n_fft` of 320
  ([v3 ctc config](https://huggingface.co/ai-sage/GigaAM-v3/blob/ctc/config.json)).
  In the `v3_ctc` and `v3_rnnt` configs the vocabulary is exactly `" "` plus
  а–я without ё. I checked the e2e tokenizers by parsing `tokenizer.model`:
  e2e_rnnt has 84 pieces containing Latin (e.g. `▁YouTube`, `▁HD`, `▁TV`),
  and e2e_ctc has 53.
- `v3_e2e_ctc`/`v3_e2e_rnnt` "support punctuation and text normalization"
  (README).
- **File sizes.** PyTorch checkpoints on the CDN (HTTP Content-Length):
  v1_ctc 484 MB, v1_rnnt 490 MB, v2_ctc 466 MB, v2_rnnt 470 MB, v3_ctc
  442 MB, v3_rnnt 446 MB, v3_e2e_ctc 442 MB, v3_e2e_rnnt 449 MB, emo 484 MB,
  multilingual_ctc 883 MB, multilingual_large_ctc 2.34 GB. The HF v3
  `pytorch_model.bin` files match: 442–449 MB. For the sherpa-onnx int8
  archives, see §3.
- **WER, average across 10 Russian sets** (evaluation.md): V3 CTC 9.1,
  V3 RNNT 8.3, E2E CTC 12.0\*, E2E RNNT 11.2\*, V2 CTC 11.1, V2 RNNT 10.6,
  V1 CTC 14.2, V1 RNNT 13.8, Whisper-large-v3 21.0\*. (\* means scored after
  stripping punctuation and case and replacing numerals.) Per-set figures:
  Golos Crowd V3 RNNT 2.4, Natural Speech 6.9, Callcenter 9.5, OpenSTT
  YouTube 10.6.
- **e2e side by side.** In LLM-as-judge side-by-side comparisons, e2e beats
  Whisper 70:30. Punctuation F1 for e2e-rnnt: comma 84.5, period 86.7,
  question mark 79.8 (evaluation.md).
- **Multilingual WER.** Russian CV 7.1 / 5.1 (220M / 600M). English CV
  26.0 / 21.5 and FLEURS 12.2 / 9.4. The card itself calls English
  "moderate quality"
  ([HF card](https://huggingface.co/ai-sage/GigaAM-Multilingual)).
- **Emotion.** `emo` gets 0.84 / 0.67 macro-F1 on Dusha crowd / podcast.
- **Phrase length.** `.transcribe` works "only up to 25 seconds". Longer
  audio uses `transcribe_longform` with pyannote VAD
  (README; `LONGFORM_THRESHOLD = 25 * SAMPLE_RATE` in
  [model.py](https://github.com/salute-developers/GigaAM/blob/main/gigaam/model.py)).

**Inference:** A 442 MB checkpoint for about 220M parameters means the
checkpoint is stored in fp16. The 25 s limit is the same as ticket 12's
phrase limit, so push-to-talk needs no VAD segmentation.

## 3. Running natively without Python on Apple Silicon

**Source: GigaAM's own ONNX export.** GigaAM ships `model.to_onnx(...)`
(fp32 by default, fp16 optional) and a Python `onnx_utils` runner (README
"ONNX Export and Inference"; since 2024-12). Sber publishes no pre-exported
ONNX files and no Core ML model. Its other deployment target is
Triton/TensorRT
([triton_scripts](https://github.com/salute-developers/GigaAM/tree/main/triton_scripts)).

**Source: sherpa-onnx support.**
- Export scripts exist for v1, v2 and v3 CTC/RNNT and for the v3 "punct"
  (= `v3_e2e_ctc` / `v3_e2e_rnnt`) models
  ([scripts/nemo/GigaAM](https://github.com/k2-fsa/sherpa-onnx/tree/master/scripts/nemo/GigaAM);
  v3 added by [PR #2901](https://github.com/k2-fsa/sherpa-onnx/pull/2901),
  merged 2025-12-16). The export writes `is_giga_am=1` into the metadata and
  quantizes to int8 with dynamic quantization (QUInt8)
  ([export-onnx-ctc-v3-punct.py](https://github.com/k2-fsa/sherpa-onnx/blob/master/scripts/nemo/GigaAM/export-onnx-ctc-v3-punct.py)).
  The CI keeps only the `*.int8.onnx` files
  ([workflow](https://github.com/k2-fsa/sherpa-onnx/blob/master/.github/workflows/export-nemo-giga-am-to-onnx.yaml)).
- The GigaAM archives are GitHub release assets under tag `asr-models`. Sizes
  are compressed `.tar.bz2`, from the release API:

  | Archive | Size |
  |---|---|
  | `sherpa-onnx-nemo-ctc-giga-am-v3-russian-2025-12-16` | 163.3 MB |
  | `sherpa-onnx-nemo-ctc-punct-giga-am-v3-russian-2025-12-16` | 163.3 MB |
  | `sherpa-onnx-nemo-transducer-giga-am-v3-russian-2025-12-16` | 167.4 MB |
  | `sherpa-onnx-nemo-transducer-punct-giga-am-v3-russian-2025-12-16` | 170.2 MB |
  | `…-ctc-giga-am-v2-russian-2025-04-19` / `…-transducer-giga-am-v2-…` | 166.9 / 172.4 MB |
  | `…-ctc-giga-am-russian-2024-10-24` / `…-transducer-…` (v1, NC licence) | 200.5 / 205.4 MB |

  Download URL pattern:
  `https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/<name>.tar.bz2`.
  The docs show the v2 CTC `model.int8.onnx` unpacked at 226 MB
  ([docs](https://k2-fsa.github.io/sherpa/onnx/pretrained_models/offline-ctc/nemo/russian.html)).
  The docs pages list only v1 and v2. v3 exists as release assets
  ([issue #3619](https://github.com/k2-fsa/sherpa-onnx/issues/3619)).
- **Offline only.** GigaAM runs through
  `OfflineNemoEncDecCtcModel` (`nemo_ctc`) and `OfflineTransducerNeMoModel`
  (`model_type = "nemo_transducer"`). Both read `is_giga_am` and switch to a
  GigaAM feature front end
  ([offline-nemo-enc-dec-ctc-model.cc](https://github.com/k2-fsa/sherpa-onnx/blob/master/sherpa-onnx/csrc/offline-nemo-enc-dec-ctc-model.cc),
  [offline-transducer-nemo-model.cc](https://github.com/k2-fsa/sherpa-onnx/blob/master/sherpa-onnx/csrc/offline-transducer-nemo-model.cc)).
  Transducer models fail with "'vocab_size' does not exist" unless
  `nemo_transducer` is set
  ([issue #3619](https://github.com/k2-fsa/sherpa-onnx/issues/3619)).
- **APIs.** There is a C API example for GigaAM v2
  ([c-api-examples/nemo-giga-am-v2-c-api.c](https://github.com/k2-fsa/sherpa-onnx/blob/master/c-api-examples/nemo-giga-am-v2-c-api.c))
  and a C++ one. The Swift wrapper
  ([SherpaOnnx.swift](https://github.com/k2-fsa/sherpa-onnx/blob/master/swift-api-examples/SherpaOnnx.swift))
  exposes `sherpaOnnxOfflineNemoEncDecCtcModelConfig`, `modelType`, and
  offline results with `timestamps` / `durations`. A root
  [Package.swift](https://github.com/k2-fsa/sherpa-onnx/blob/master/Package.swift)
  (v1.13.8, 2026-09-10; macOS ≥ 10.15) pulls prebuilt
  `sherpa-onnx-v1.13.8-macos-{static,shared}.xcframework.zip` and ONNX Runtime
  1.28.2 from `csukuangfj/onnxruntime-libs`. The release also has
  `osx-arm64` / `universal2` C libraries
  ([v1.13.8 release](https://github.com/k2-fsa/sherpa-onnx/releases/tag/v1.13.8)).
- **Hotwords.** The NeMo transducer path supports `modified_beam_search` with
  a hotwords file
  ([offline-recognizer-transducer-nemo-impl.h](https://github.com/k2-fsa/sherpa-onnx/blob/master/sherpa-onnx/csrc/offline-recognizer-transducer-nemo-impl.h)).
- **Core ML.** sherpa-onnx can select ONNX Runtime's Core ML execution
  provider (`provider = "coreml"`) on Apple
  ([session.cc](https://github.com/k2-fsa/sherpa-onnx/blob/master/sherpa-onnx/csrc/session.cc)).
  ONNX Runtime's Core ML EP operator tables do not list `MatMulInteger` /
  `DynamicQuantizeLinear`, the ops dynamic int8 quantization produces. Dynamic
  shapes are allowed, "however performance may be negatively impacted"
  ([CoreML EP docs](https://onnxruntime.ai/docs/execution-providers/CoreML-ExecutionProvider.html)).

**Inference:**
- The shortest path for the spike is SwiftPM `sherpa-onnx` + the v3 int8
  archive, on CPU. Core ML via ONNX Runtime would probably run the int8 graph
  mostly on CPU anyway, because the quantized ops are unsupported. Trying the
  ANE/GPU would mean an fp32/fp16 export of our own through GigaAM's
  `to_onnx`, or converting to Core ML directly with coremltools. Neither
  path is documented by GigaAM or sherpa-onnx.
- **Unverified front-end mismatch.** sherpa-onnx's GigaAM front end uses its
  default 25 ms window: `frame_length_ms = 25`, and the code comment says
  "GigaAM uses n_fft 400"
  ([offline-recognizer-ctc-impl.h](https://github.com/k2-fsa/sherpa-onnx/blob/master/sherpa-onnx/csrc/offline-recognizer-ctc-impl.h),
  [features.h](https://github.com/k2-fsa/sherpa-onnx/blob/master/sherpa-onnx/csrc/features.h)).
  The v3 config specifies `win_length = n_fft = 320` (20 ms). I did not find
  an accuracy comparison. The spike should compare sherpa-onnx output against
  the reference Python `transcribe` on the same clips.

## 4. Streaming and word timestamps

**Source:**
- **No streaming checkpoint.** The encoder applies full self-attention with
  only a padding mask, and there is no chunk or cache API
  ([encoder.py](https://github.com/salute-developers/GigaAM/blob/main/gigaam/encoder.py)).
  A maintainer (2026-05-04) said local/chunkwise attention is not an
  inference option: the "published checkpoints were trained in full-context
  mode", and switching to local attention only at inference "may noticeably
  degrade quality"
  ([issue #70](https://github.com/salute-developers/GigaAM/issues/70#issuecomment-4372753044),
  my translation). In 2025-03 the team said streaming was "being considered"
  ([issue #18](https://github.com/salute-developers/GigaAM/issues/18#issuecomment-2697921476)).
  Nothing has shipped since.
- **Paper, Table 4** ([arXiv 2506.01192](https://arxiv.org/html/2506.01192)).
  With chunkwise attention and chunkwise-causal convolutions, WER is
  3.35 (full context), 5.49–6.37 (1 s chunks, streaming) and
  **10.35–12.3 (200 ms chunks, streaming)**. These are research models, not
  the released ones. The paper reports no latency or speed figures.
- **Timestamps.** Word-level timestamps were added in 2026-04:
  `transcribe(..., word_timestamps=True)` for CTC and RNNT. Words are grouped
  from token frame indices × frame shift
  ([timestamps_utils.py](https://github.com/salute-developers/GigaAM/blob/main/gigaam/timestamps_utils.py)).
  sherpa-onnx returns token timestamps at `10 ms × subsampling 4` =
  **40 ms** resolution for NeMo CTC and transducer, not word timestamps
  ([offline-recognizer-ctc-impl.h](https://github.com/k2-fsa/sherpa-onnx/blob/master/sherpa-onnx/csrc/offline-recognizer-ctc-impl.h)).
- **Simulated streaming.** sherpa-onnx's "simulate-streaming" examples
  combine Silero VAD with re-running `Decode` on the current speech segment
  every 0.2 s
  ([parakeet-tdt-ctc-simulate-streaming-microphone-cxx-api.cc](https://github.com/k2-fsa/sherpa-onnx/blob/master/cxx-api-examples/parakeet-tdt-ctc-simulate-streaming-microphone-cxx-api.cc)).
  There is no GigaAM-specific variant, but the same offline API applies.
- **Speed figures.** On CUDA, the full encoder takes ~10 ms for 10 s of
  audio at batch 1; the GPU is not named (evaluation.md "Attention type").
  gigatype.app cites 2.5 s per minute of speech on an M3 with PyTorch MPS
  (§6). There are no published M1 Pro or CPU figures.

**Inference (what chunking would cost):**
- Latency ≈ re-decode interval + inference time for the window. To stay
  near 0.3 s with a 0.2 s interval, one decode must take ≲ 0.1 s. For a
  5–10 s window that means a real-time factor of ≲ 0.01–0.02 on CPU int8.
  That is plausible but unmeasured. The cost grows with the window (the
  attention part quadratically), so a sliding window capped at a few seconds,
  with overlap, is needed rather than a growing one.
- The last few hundred ms of each window lack right context. The paper shows
  how much limited context hurts (3.35 → 5.5–6.4 WER at 1 s). Expect the
  newest word to flicker until the next pass confirms it.
- CTC suits this better than RNN-T. It gives per-frame posteriors without
  search, and overlapping windows can be merged by time. Ticket 20 also knows
  the text in advance (the Script), so aligning CTC posteriors to the Script
  near the current position is a much easier problem than open transcription,
  and may tolerate the edge errors. This is an idea to test, not a documented
  GigaAM feature.
- If this fails, sherpa-onnx also ships a *native streaming* Russian model,
  `sherpa-onnx-streaming-t-one-russian-2025-09-08`, with a Swift example
  ([run-decode-file-t-one-streaming.sh](https://github.com/k2-fsa/sherpa-onnx/blob/master/swift-api-examples/run-decode-file-t-one-streaming.sh)).
  GigaAM's table lists "T-One + LM" at 16.3 average WER against 9.1 for
  v3 CTC. I did not check its licence.

## 5. Russian speech with English technical terms

**Source:**
- The `v3_ctc` / `v3_rnnt` alphabets are Cyrillic only (§2), so they cannot
  produce Latin script.
- The v3 announcement says the e2e models "recognize speech with
  punctuation, capitalization, English domain terms, numbers, and other text
  normalization out of the box"
  ([issue #18, 2025-11-20](https://github.com/salute-developers/GigaAM/issues/18#issuecomment-3559490699)).
- Sber's own v3 article ([Habr, SberDevices blog](https://habr.com/ru/companies/sberdevices/articles/973160/),
  linked from the README) says the e2e output contains "English terms". The
  article gives this as part of why e2e WER exceeds 10 % against plain
  references. Its character inventory covers Russian and English alphabets
  in both cases. One judged example shows both e2e models failing on an
  English song title: "поставь бэк ту ю…" became "Поставь бак, что есть…"
  or "Bach Te Sena Gomez".
- The v3 HF card lists `language: ru, en`, but reports no English metrics.
- **No published evaluation of Russian–English code-switching or developer
  vocabulary exists** in the repo, evaluation.md, the paper or the HF cards.
  The paper does not mention English.

**Inference:** With `v3_ctc` / `v3_rnnt`, "git push" will come out as
Cyrillic transliteration, such as «гит пуш». That is certain from the
alphabet; the exact spelling is not. The e2e models can emit Latin, but how
often they do so for developer jargon is unknown. The Multilingual CTC
also has Latin letters, but its English WER is modest, it is not in
sherpa-onnx, and it has no punctuation. Hotwords (e2e RNN-T + modified
beam search) are one lever; a correction dictionary for common
transliterations is another. The spike's corpus is the only evidence there
will be.

## 6. gigatype.app

**Source** ([home](https://gigatype.app), [about](https://gigatype.app/about),
[privacy](https://gigatype.app/privacy)):
- "Тайп" is a Russian voice keyboard for macOS and Windows. You hold a
  key and speak; the text is inserted at the cursor, or copied to the
  clipboard if no field is focused. It runs locally; voice and text are
  not sent to servers.
- It says it runs on "нейросети GigaAM от Сбера". It does **not** name the
  GigaAM variant or the inference runtime.
- The speed claim is 2.5 s to recognise one minute of speech, against
  Parakeet TDT 0.6B v3 at 3.2 s and Whisper large-v3-turbo at 64.6 s. The
  footnote describes it as one Russian recording, three runs, median, on an
  "Apple M3 / 8 GB RAM / macOS 26.5 / PyTorch MPS", and calls it "a small
  test, not a full benchmark".
- The site says "MIT License. Copyright (c) 2026 Disrupt Builders". It
  collects technical analytics (events, errors, dictation length, character
  count), and the site uses Yandex Metrica with Webvisor.
- The macOS download link in the site's JS points to a Sber cloud bucket
  path `…/gigatype-electron/prod/Type-2.0.0-arm64.dmg`. I did not download
  it.

**Inference:** The URL path suggests an Electron app. The benchmark used
PyTorch MPS, which says how *they measured*, not necessarily what the app
ships. No source repository is linked, so its runtime cannot be confirmed
from primary sources.

## Open questions the spike must measure

1. sherpa-onnx v3 int8 on the M1 Pro, for 5, 15 and 25 s phrases: cold
   start (model load), per-phrase latency, peak RSS, CPU %. Compare CTC with
   RNN-T, and punct (e2e) with plain.
2. Accuracy parity: sherpa-onnx int8 against Python `transcribe` (fp16/fp32)
   on the same clips. Check the 25 ms vs 20 ms window question (§3).
3. English developer terms: on the corpus, the rate of Latin vs Cyrillic
   output for e2e vs plain, correction effort, and whether hotwords help.
4. Simulated streaming: decode time for 2–8 s windows; achievable
   end-to-end latency at a 0.2–0.3 s re-decode interval; word stability at
   the window edge; CPU and thermal load while it runs continuously.
5. Whether aligning CTC to a known Script (ticket 20) is robust with
   40 ms timestamps.
6. Core ML: whether an fp16 export on the Core ML EP (or via coremltools)
   beats int8 CPU on latency and battery. Only worth it if item 1 falls
   short.
7. Licence hygiene: which exact files to ship with the model download
   (GigaAM MIT text, sherpa-onnx Apache-2.0 text, ONNX Runtime MIT text).
   Confirm that nothing from the v1 NC archives is used.
