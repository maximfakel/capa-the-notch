# 20: Follow the voice in the teleprompter

**What to build:** The Teleprompter listens as the Script is read aloud and
follows the reader — the word being said lit, like karaoke, and the Script
moving at the reader's pace rather than at a set speed.

**Blocked by:** 12/Spike local Speech Dictation on M1 Pro; 16/Build the
Teleprompter Module.

**Status:** needs-info

**Why:** A set speed is always a little wrong: the reader slows down on a
hard sentence, stops for a question, skips a line. Following the voice keeps
the line being said where the eyes are, which is what a teleprompter is for.

What is decided already:

- It extends the Teleprompter Module (ticket 16); it does not replace the
  automatic scroll. The interview chose scroll without a microphone on
  purpose (question 1), so following the voice is something a person turns
  on, and asks for microphone access only then (ADR 0003).
- Recognition runs on this Mac, with the engine ticket 12 chose — GigaAM —
  nothing uploaded, nothing kept (as ticket 12 requires for dictation).
- It comes after the Dictation Module: that builds the engine once, in the
  easier case, where waiting for the end of a phrase is fine.

What it needs before building — its own design interview, and a mockup:

- Whether GigaAM can stream on this M1 Pro with word timings and about 0.3 s
  latency (ticket 12 measures it).
- How the recognised words are matched to the Script when the reader skips,
  repeats, stumbles or talks off script — and what the row does then.
- What is lit: the word, the line, or both; and what the Paper row looks like.
- What happens when the voice stops — hold, or fall back to the set speed.
- How it behaves during a call, when the call app is using the microphone
  too, and whether another voice on the call can move the Script.

## Comments

**2026-09-26 — what the research says about streaming.** From
`docs/research/gigaam.md`: no released GigaAM model streams; all were
trained on whole phrases, and the paper's own streaming experiments (never
released) lost much of the accuracy. What remains is re-decoding a sliding
window every ~0.2 s, with 40 ms token timings — unmeasured on this Mac. The
note suggests that following a known Script is easier than open dictation
(align the audio against the words already expected), and names T-One, a
streaming Russian model already in sherpa-onnx, as the fallback if GigaAM
cannot keep up. Ticket 12 measures the sliding window first.
