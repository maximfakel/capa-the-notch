# Following the voice in the Teleprompter: GigaAM on a sliding window

Ticket 20's evidence, measured 2026-10-07 on the author's MacBook Pro (M1 Pro,
16 GB, macOS 27.0), on mains power. The harness is `Spikes/TeleprompterVoice/`
(see its README); it links the app's own sherpa-onnx 1.13.8 and ONNX Runtime
(`Vendor/Dictation`) and measures the app's own `ScriptFollower`
(`Sources/CapacityNotchCore/Teleprompter/ScriptFollower.swift`), not a copy.
The engine is the model the Dictation Module already downloads: GigaAM v3
punctuated RNN-T, int8, CPU, greedy search
(`sherpa-onnx-nemo-transducer-punct-giga-am-v3-russian-2025-12-16`).
Background: `docs/research/gigaam.md`, `docs/research/dictation-spike.md`.

## Verdict

**Go for GigaAM.** No switch to T-One: T-One costs a fifth of the CPU but
lights each word about 0.8 s later, and would be a second model to download.

- Re-decoding the last **2 s every 0.2 s with 2 threads** takes **70 ms**
  (p95 74 ms), keeps up with room to spare, and costs **0.85 of a core** while
  the voice is heard, about 360 MB with the model loaded. The thermal state
  stayed nominal over five minutes (below).
- Matched against the known Script, the word being said is lit at the
  **median 0.0 s after the word ends** (it is often lit as the word finishes,
  because a half-heard newest word counts), **0.45 s after it starts**;
  **p90 0.45–0.55 s after it ends**. The tail is short words ("и", "а", "в"),
  which wait for the next word to be sure, and the first word after a pause.
- In every scenario every Script word was lit, nothing was lit before it was
  said, the Script did not move while the voice was silent or off the Script,
  and it never went back.

Against the target of "about 0.3 s from word spoken to word lit": met at the
median, and missed by about 0.2 s for the slowest tenth of words. The floor
is structural — a 0.1 s microphone buffer, a 0.2 s step and a 70 ms decode,
so 0.15–0.35 s once the model can tell the word — and a streaming model does
not remove the step (see T-One below). I judge that acceptable for lighting a
word; the line, which is what moves the Script, changes on the last word of a
line and so follows within the same time.

## What was measured

### Speech

macOS's own Russian voice (`say -v Milena -r 150`, about 130 words a minute
once punctuation pauses are counted) reading a 105-word Script written for the
harness, wrapped into 56-character lines like the Teleprompter Row's. No one's
recordings were used; the earlier spike's personal Russian recordings stay
excluded. Five scenarios, 46–59 s each:

| Scenario | What happens |
|---|---|
| straight | read through, 0.5 s between paragraphs |
| pauses | the voice stops twice for 5 s |
| skip | the second line of the third paragraph is left out |
| offscript | 7 s of talk that is not the Script ("секунду, налью воды…") |
| repeat | the last four words of a line said again |

Each run plays the audio at real speed in 0.1 s buffers, as the microphone
delivers it, and runs the recogniser and follower as the app does: every 0.2
s, the last N seconds, skipped if the previous decode is still running.
Reference word timings come from a full-context decode of each spoken segment;
the model's first word sits 73 ms after the first sound (median), so "after
the word ends" is measured from the model's own timing of the word.

Synthetic speech is clean, evenly paced and has no room noise; a person's
voice in a room will be harder. That is the main thing not measured (below).

### Window and threads (straight reading)

| Window | Threads | Decode p50 / p95 | Lit after word end p50 / p90 | CPU (cores) |
|---|---|---|---|---|
| 2 s | 1 | 114 / 139 ms | 0.04 / 0.56 s | 0.56 |
| 2 s | 2 | 72 / 133 ms | 0.00 / 0.52 s | 0.89 |
| 2 s | 4 | 55 / 64 ms | 0.00 / 0.47 s | 1.61 |
| 3 s | 1 | 172 / 249 ms | 0.14 / 0.61 s | 0.73 |
| 3 s | 2 | 104 / 112 ms | 0.02 / 0.51 s | 1.18 |
| 3 s | 4 | 75 / 84 ms | −0.01 / 0.48 s | 1.98 |
| 4 s | 1 | 216 / 225 ms (falls behind) | 0.18 / 0.74 s | 0.54 |
| 4 s | 2 | 130 / 135 ms | −0.01 / 0.48 s | 1.43 |
| 4 s | 4 | 95 / 125 ms | −0.02 / 0.48 s | 2.35 |

A longer window lights no sooner and costs more; with the first version of the
follower the 4 s window also lit a word four ahead once and stepped back
three times (fixed below). 2 s holds 4–6 words, enough to place the voice.
Two threads instead of one buy headroom (70 ms against 115 ms, which matters
when a call is using the CPU too) for 0.3 of a core more; one thread is the
fallback if battery matters more.

### Every scenario, at 2 s and 2 threads

| Scenario | Lit after word end p50 / p90 / p95 | Words lit | Lit ahead | Moved while waiting | Went back |
|---|---|---|---|---|---|
| straight | −0.01 / 0.48 / 0.60 s | 105 / 105 | 0 | 0 | 0 |
| pauses | −0.01 / 0.51 / 0.59 s | 105 / 105 | 0 | 0 | 0 |
| skip | −0.06 / 0.26 / 0.44 s | 97 / 97 | 0 | 0 | 0 |
| offscript | −0.01 / 0.47 / 0.54 s | 105 / 105 | 0 | 0 | 0 |
| repeat | 0.01 / 0.46 / 0.54 s | 105 / 105 | 0 | 0 | 0 |

The same at 2 s / 1 thread and 3 s / 2 threads: all words lit, nothing ahead,
nothing moved while waiting, nothing back; one word in two of the 1-thread
runs lit more than a second late. "Moved while waiting" counts any move from
a second into a silence or off-script span longer than 1.5 s to its end. The
skipped line was jumped as soon as three words of the next line had been
heard.

### Word timings

sherpa-onnx gives token timings at 40 ms. In the 2 s window, a word's start
agrees with the full-context decode to within one 40 ms frame (p50 and p90)
during continuous reading, the newest word in the window included. Right after
a long silence or off-script talk it is 0.1–0.25 s off. The follower does not
use the timings — it matches the order of the words — so this does not delay
lighting; it would matter only to an aligner that used time.

### Sustained, heat and memory

Five minutes without a break (the straight scenario six times over, 298 s),
2 s window, 2 threads: **0.86 of a core** throughout, decode p50 70 / p95
74 / max 155 ms, the same lighting (p50 −0.01 / p90 0.45 s after the word
ends), peak memory **401 MB** for the whole process, model included. macOS's
thermal state stayed **nominal**, and `pmset -g therm` recorded no thermal,
performance or CPU-power warning before or after. This is CPU time, not
watts or fan speed (below).

The app does a little less than the harness: once the newest 0.6 s has been
quiet for two steps it stops decoding until a voice comes back, so a reader
who pauses costs nothing; and the model is let go a minute after the Script
stops or pauses.

### T-One, for comparison

T-One (`sherpa-onnx-streaming-t-one-russian-2025-09-08`, 128.5 MB download,
a 144 MB ONNX model; 8 kHz, resampled by sherpa-onnx from 16 kHz) through
sherpa-onnx's streaming API, fed the same 0.1 s buffers, the same follower:

| Scenario | Lit after word end p50 / p90 | Later than 1 s | Never lit | CPU | Memory |
|---|---|---|---|---|---|
| straight | 0.81 / 1.32 s | 28 of 105 | 0 | 0.16 cores | 614 MB |
| pauses | 0.82 / 1.28 s | 27 | 1 | 0.16 | 623 MB |
| skip | 0.74 / 1.17 s | 22 of 97 | 0 | 0.16 | 623 MB |
| offscript | 0.81 / 1.27 s | 29 | 1 | 0.16 | 623 MB |
| repeat | 0.82 / 1.31 s | 31 | 0 | 0.16 | 623 MB |

A fifth of the CPU, but its words arrive about 0.8 s later than GigaAM's,
and a second model to download and hold beside Dictation's. Nothing was lit
ahead and nothing moved while waiting, so the follower works with it too;
it is the fallback if GigaAM's core proves too much on battery, at the cost
of a word lit about a second late.

## The follower, and what the measurement changed

`ScriptFollower` aligns the newest words heard (at most 12) against the whole
Script by local alignment (Smith–Waterman over folded words: lower case, ё as
е, letters and digits only; a fuzzy match for misheard long words, a prefix
match for the newest word cut off by the window). Of the alignments ending on
a matched pair it takes the one ending on the newest word heard, nearest the
place, if there is enough evidence for the distance: the next word or two on
one match, a few words on, two, a skipped line, three, anywhere else or back,
four. Silence and off-script talk match nothing new, so the place holds — the
author's decision that the Script waits for the voice.

Two rules came from the measurement's trace: a step back now needs the newest
word heard to be the earlier one (a reader starting a sentence again), never
an older word while the newest is still unclear (it flicked "работает" →
"система" → "работает"); and a one- or two-letter word ("и", "в", "не") lights
away from the place only straight after the word before it was heard (the
fragment "не" of "несколько" had lit a "не" four words on).

## Not measured

- **A real voice through a real microphone**, in a room, with a laptop or a
  headset microphone, and with the author's own reading. Synthetic speech is
  the best case. The quiet threshold the app uses to stop decoding while the
  reader is silent (about −48 dBFS over the last 0.6 s) is unmeasured too.
- **Battery and package power**: `powermetrics` needs the author's password.
  CPU time and the thermal state are measured; watts are not.
- **A call**: another app using the microphone, echo from speakers.
- **Other Macs**; the friend's M5 would be faster.
