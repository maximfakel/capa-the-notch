# Translator engine — 2026-10-07

Ticket 28. Which engine translates Russian ↔ English on this Mac: Apple's
on-device Translation framework, or an open model run locally. Measured on
the author's M1 Pro, macOS 27.0.1 (26A434), Xcode 27.0, Swift 6.4.

## Verdict

**Apple's Translation framework, on macOS 26 and later. On macOS 14 and 15
the Module stays off and says it needs macOS 26.** The open-model route
(Opus-MT through the ONNX Runtime already vendored) is the fallback if
Apple's quality or speed disappoints once measured. It is not built.

Two numbers that decide it are still missing, because each needs a download
this project asks the author for first (ADR 0003, the Dictation spec's
explicit-download rule): Apple's Russian/English quality and speed, and
Opus-MT's. What could be measured without downloading is below. The
measurement to finish is under "Still to measure".

## (a) Apple's Translation framework

Read from the macOS 27 SDK's `Translation.swiftinterface` and run on this Mac.

| Question | Answer | Source |
|---|---|---|
| Minimum macOS | `TranslationSession` and `LanguageAvailability` 15.0. Making a session in code (`init(installedSource:target:)`), `isReady`, `canRequestDownloads`, `cancel()` and `TranslationError.notInstalled`: **26.0**. `Strategy` (`.lowLatency`, `.highFidelity`): 26.4. | SDK interface |
| Without SwiftUI's `translationTask`? | On macOS 26+, yes, for **languages already installed**. A session made that way cannot ask for downloads: `canRequestDownloads == false`, measured. On macOS 15 a session comes only from `translationTask` / `translationPresentation`, so a view must be on screen. That rules out the shortcut with the surface closed. | SDK; Apple docs, `TranslationSession` |
| Downloads | Only through a session from `translationTask`: `prepareTranslation()` "asks the person for permission to download". The API does not report the size. | Apple docs, `prepareTranslation()` |
| Offline | Apple: "All translations using the `TranslationSession` class are processed on the user's device." Apple may collect usage metrics, such as bundle ID and language pair, "but this data does not include the original or translated content." Translating with the network off was **not** run, because the languages are not installed (see below). | Apple docs, `TranslationSession` |
| Supported here | 47 languages, `ru` and `en` among them. | measured, `LanguageAvailability().supportedLanguages` |
| Status on this Mac | ru→en `supported`, en→ru `supported` — i.e. **not installed**. On disk, only Apple's language-ID, endpointer and config assets (33 MB in `/System/Library/AssetsV2/com_apple_MobileAsset_UAF_Translation_Assets`). | measured |
| Cost of asking | `LanguageAvailability.status` for both ways: 42 ms. `TranslationSession(installedSource:target:)`: 0.34 ms. `isReady`: 24 ms. `translate` before installation throws `TranslationError.notInstalled` in 34 ms, without a prompt or download. | measured |
| Size added to CapaTheNotch | 0 bytes. The framework is weak-linked (`LC_LOAD_WEAK_DYLIB` for `Translation` and `_Translation_SwiftUI`, checked with `otool -l`), so the app still launches on macOS 14. | measured |
| Download size of ru + en | Unknown. Apple does not publish it, and the API does not report it. | — |
| Apple Intelligence (FoundationModels) instead? | No. `SystemLanguageModel` is `modelNotReady` here, and its languages do not include Russian. | measured |

## (b) An open model run locally

Helsinki-NLP Opus-MT, Marian transformer-align, one model per direction
(`opus-mt-ru-en` CC-BY-4.0, `opus-mt-en-ru` Apache-2.0). It would run
through ONNX Runtime, already in `Vendor/Dictation/onnxruntime.xcframework`
with its C API headers. CTranslate2 is not vendored. It would add a C++
library build on top.

| | ru→en | Source |
|---|---|---|
| ONNX int8 (`Xenova/opus-mt-ru-en`) | encoder 51.6 MB + merged decoder 58.9 MB ≈ **110 MB a direction, ≈ 220 MB both** | Hugging Face file listing |
| ONNX fp32 | 204.9 + 230.7 MB ≈ 435 MB a direction | same |
| Tokenizer | `source.spm` 1.1 MB, `target.spm` 0.8 MB, `vocab.json` 2.6 MB | same |
| BLEU, newstest2019 | ru→en 31.4, en→ru 27.1. Tatoeba 61.1 / 48.4. | model cards |
| Load time, speed, quality on M1 Pro | **not measured**. Needs ≈ 220 MB downloaded. | — |
| Code it would need | A SentencePiece unigram tokenizer in Swift (no tokenizer is vendored), Marian encoder–decoder with a KV cache over the ORT C API, beam or greedy search, a download with hashes, as Dictation's has, and licence notices. Estimated at several hundred lines plus a second model-download flow. | estimate |

Opus-MT dates from 2020 and was trained on news-like data. Its BLEU says
nothing about developer prose: "смержить", "pull request", code identifiers.
That is the case the author cares about, and the reason quality has to be
measured on his own sentences, not read off a card.

## Why Apple, provisionally

- The author's Mac is on macOS 27. Apple's route costs CapaTheNotch no
  download of its own, no model files, and no tokenizer or decoder code. The
  languages are macOS's own and shared with other apps, and macOS asks before
  downloading them.
- Making a session costs a third of a millisecond, and checking readiness
  tens of milliseconds. The shortcut can work with the surface closed.
- The open-model route would be ≈ 220 MB from Hugging Face plus a tokenizer
  and decoder written here. That is the "too heavy" case the ticket
  anticipated, unless Apple's output proves poor on developer text.
- The cost is macOS 14–15 support. Below macOS 26 the Module's switch stays
  off, and its card says "Translation on this Mac needs macOS 26 or later."

## Still to measure

These need the author's go-ahead, because each downloads something.

1. **Apple.** Turn the Translator on in Settings, press "Download…" and
   accept macOS's question. Then record:
   - the size macOS installed: compare `/System/Library/AssetsV2` before and after, or check System Settings › General › Language & Region › Translation Languages. Write it into the Settings text, which now says Apple does not tell apps the size in advance.
   - first and warm translation time on a dozen developer sentences each way, for example:

     ```swift
     let s = TranslationSession(installedSource: .init(identifier: "ru"), target: .init(identifier: "en"))
     let t0 = ContinuousClock.now
     let r = try await s.translate("Перед релизом надо смержить pull request и прогнать тесты на CI.")
     print(t0.duration(to: .now), r.targetText)
     ```
   - the same with Wi-Fi off, to confirm offline.
2. **Opus-MT, only if (1) disappoints.** Download the four int8 ONNX files
   (≈ 220 MB) and time them through ONNX Runtime. Compare their output with
   Apple's on the same sentences.
