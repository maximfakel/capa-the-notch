# Dictation spike: GigaAM v3 on this M1 Pro

Ticket 12's evidence, measured 2026-09-26 on the author's MacBook Pro (M1 Pro,
16 GB, macOS 27.0). The prototype is `Spikes/Dictation/` (see its README);
the engine is GigaAM v3 punctuated RNN-T
(`sherpa-onnx-nemo-transducer-punct-giga-am-v3-russian-2025-12-16`, int8)
through sherpa-onnx 1.13.8 on the CPU, 4 threads, from Swift — no Python.
Background on the model and its licence: `docs/research/gigaam.md`.

## Recommendation

**Go**, for a Dictation Module on GigaAM, on one condition: English
developer terms need a remedy before it is pleasant to use, because they
are where every error is.

- Speed is not the problem. Text arrives 0.1–0.5 s after the key is
  released, for phrases up to 25 s.
- Russian is not the problem. Every corpus phrase without English terms came
  back word for word.
- English terms are the problem: 5 of 69 came back in Latin; the rest as
  Cyrillic transliteration ("диплой", "Джейсон") or wrong Latin ("Paul
  Recvest", "Excode"). A personal vocabulary (hotwords) helps a little and
  not reliably (below).

For ticket 20 (the teleprompter following the voice): GigaAM can keep up
with a 4 s window re-decoded every 0.2 s, but only by keeping about 1.3
cores busy for as long as it listens. That is a cost to weigh in ticket 20's
interview, against aligning to the known Script or a streaming model.

This recommendation does not enter the roadmap by itself (ticket 12).

## What was measured

### Speed and memory

| | |
|---|---|
| Model download | 170.2 MB (232 MB unpacked; encoder 225 MB int8) |
| Libraries | sherpa-onnx xcframework 11.6 MB, ONNX Runtime 23.7 MB (static; the spike binary is 40 MB) |
| Cold start (model load) | 0.47–0.60 s |
| Peak memory, model loaded | 363 MB after load, 390–407 MB while recognising |
| Recognition, 11.3 s example | 0.25 s (real-time factor 0.022) |
| Recognition, corpus | short phrases mean 0.09 s (max 0.18), medium 0.15 s (max 0.37), long 0.22 s (max 0.29); RTF 0.023 overall |
| Push-to-talk, live | text at the cursor 0.11 s after release for a 4 s phrase, 0.26–0.29 s for 11 s, 0.54 s for 23.5 s |

CPU is used only while recognising: an 11 s phrase takes about 2.8 s of CPU
time across the 4 threads. Nothing runs between phrases. The GPU and the
Neural Engine are not used (CPU provider; sherpa-onnx offers no Core ML
model for GigaAM, see `gigaam.md`).

### Accuracy on the author's voice

Corpus: 33 phrases the author read once (`Spikes/Dictation/Sources/SpikeCore/Corpus.swift`)
— 11 short, 11 medium, 11 long, 29 of them with English developer terms.
Scored by word and character error rate after lowercasing and dropping
punctuation; correction effort is the number of word edits.

| | Words | WER | CER | English terms in Latin |
|---|---|---|---|---|
| Short | 46 | 34.8 % | 25.2 % | 2 / 14 |
| Medium | 120 | 26.7 % | 20.7 % | 1 / 25 |
| Long | 243 | 16.9 % | 9.5 % | 2 / 30 |
| **All** | **409** | **21.8 %** (89 edits) | **14.4 %** | **5 / 69** |

- The four phrases without English terms (s02, s09, m06, l09) scored 0 %.
- Short phrases score worst because terms are a larger share of their words.
- One phrase (m04) came back with its first half repeated; it may be how it
  was read.
- Punctuation and capitals come with the text; numbers are written as
  figures ("в 3:00", "30 секунд").

### A personal vocabulary (hotwords)

sherpa-onnx can bias the transducer's beam search towards listed phrases.
Given the corpus's own 47 English terms — an upper bound, since a real list
would not know the phrases in advance:

| Setting | WER | English terms in Latin |
|---|---|---|
| none (greedy) | 21.8 % | 5 / 69 |
| hotwords cut as characters (sherpa-onnx's default) | 22.5 % | 6 / 69 |
| hotwords cut as BPE, weight 1.0 | **20.5 %** | 15 / 69 |
| BPE, weight 1.5 | 23.0 % | 19 / 69 |
| BPE, weight 2.0 | 24.7 % | 25 / 69 |
| BPE, weight 3.0 | 57.2 % | 24 / 69 |

The archive ships no `bpe.vocab`, which sherpa-onnx needs to cut hotwords
into the model's pieces; the spike made one from `tokens.txt` with every
score 0, which is a guess at the format. More Latin comes at the price of
new errors ("Открой pul.", "Package.swift" → "fetch"), so the weight has to
stay low and the gain is small. A plain replacement list applied after
recognition ("диплой" → "deploy") was not measured and is the other remedy
to try.

### Streaming, for ticket 20

Re-decoding the last N seconds every 0.2 s, on a 10 s recording:

| Window | 4 threads, median / p95 | 2 threads | 1 thread |
|---|---|---|---|
| 2 s | 64 / 160 ms | 72 / 73 ms | 114 / 128 ms |
| 4 s | 106 / 120 ms | 131 / 133 ms | 214 ms (falls behind) |
| 6 s | 137 / 221 ms | — | — |
| 8 s | 185 / 204 ms (falls behind) | — | — |

CPU while doing it: about 4.5 cores busy at 4 threads, about 2 at 2 threads
(1.3 when the decodes are spread over the 0.2 s step). Each decode also
returns token timings (16 in a 2 s window, 23 in a 4 s one), which is what
lighting a word would use; their accuracy against the audio was not checked.

### Push-to-talk and insertion

`dictation-spike ptt`: hold ⌃⌥D (a Carbon hot key, no Accessibility needed
to hear it), speak, release. Recording stops on release, or at 25 s, when
the microphone goes off; audio stays in memory and is dropped after
recognition. The text is pasted with ⌘V through the clipboard, and 0.4 s
later the clipboard's previous contents are put back — unless something
else was copied in between. Types an application only promises, rather
than writes, cannot be read back and are not restored. The author confirmed, on 2026-09-26, that the hot
key, the recording and the insertion worked in the applications he tried.
Without Accessibility access ⌘V cannot be sent, and the text is left on the
clipboard to paste by hand.

## Against the ticket's checklist

- [~] Hold a global key, up to 25 s, local recognition, stops on release.
  The key is fixed at ⌃⌥D, not configurable. The microphone going off at
  25 s was fixed after the review and not tried again live.
- [x] Russian with English terms, on a representative corpus, with
  correction effort — above.
- [x] Insertion into applications, with a clipboard fallback that restores
  the clipboard — confirmed by the author across applications; which of
  Terminal, Xcode, VS Code, a browser and a chat application were tried one
  by one was not recorded.
- [~] Permissions only when used: the microphone is asked for only by
  `record-corpus` and `ptt`, Accessibility only by `ptt`. What a person sees
  when either is denied was reached only as terminal text; the Module will
  need its own words for it.
- [~] Nothing uploaded; audio held in memory only. Kept on purpose, in
  `Spikes/Dictation/Recordings/` and never committed: the corpus recordings
  and `score.md` with each phrase's recognised text, until the spike is
  closed. The spike also prints recognised text to its terminal — fine for
  a measurement, not for a Module, which must print nothing.
- [~] Measurements: latency, accuracy, memory, CPU, download size and cold
  start measured. **Not measured:** battery and thermals (`powermetrics`
  needs the author's password), and the GPU, which is not used.
- [x] A go/no-go: go, with English terms as the condition.

## What the Module would still have to decide

- How to treat English terms: a personal vocabulary, a replacement list
  after recognition, or both — and where the person edits them.
- When the 400 MB model is loaded: always while the Module is on, or on the
  first press (0.5–0.6 s added to that one phrase) and let go after a while
  idle.
- Its own shortcut: ⌃⌥D here; ⌃⌥Space belongs to the teleprompter.
- The words for a denied microphone or Accessibility, in Settings and in
  Copy Diagnostics (ADR 0003, ADR 0004's rule for saying so).
- The model download itself: from the sherpa-onnx release, with its MIT
  licence kept beside it (`gigaam.md`).
