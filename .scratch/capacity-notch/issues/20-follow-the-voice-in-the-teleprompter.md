# 20: Follow the voice in the teleprompter

**What to build:** The Teleprompter listens as the Script is read aloud and
follows the reader — the word being said lit, like karaoke, and the Script
moving at the reader's pace rather than at a set speed.

**Blocked by:** 12/Spike local Speech Dictation on M1 Pro; 16/Build the
Teleprompter Module.

**Status:** resolved

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

- [x] Whether GigaAM can stream on this M1 Pro with word timings and about 0.3 s
  latency (ticket 12 measures it). *Measured 2026-10-07: go, see below.*
- [x] How the recognised words are matched to the Script when the reader skips,
  repeats, stumbles or talks off script — and what the row does then.
- [~] What is lit: the word, the line, or both; and what the Paper row looks like.
  *Both, decided by the author; no Paper drawing was made — the light is
  built from the existing row and wants the author's eye.*
- [x] What happens when the voice stops — hold, or fall back to the set speed.
  *Hold, decided by the author.*
- [~] How it behaves during a call, when the call app is using the microphone
  too, and whether another voice on the call can move the Script. *Written
  up below; not tried.*

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

**2026-10-07 — the author's decisions.**

- When the voice stops or leaves the Script: **wait.** The Script holds
  still until the voice comes back to it; it does not fall back to the set
  speed.
- What is lit: **the word being said, and its line.**
- The engine: **the GigaAM model Dictation already ships**, measured first;
  if it cannot keep up (about 0.3 s from word spoken to word lit, sustained,
  with acceptable CPU and heat), T-One instead. Record which, and why.
- Something the person **turns on**, in addition to the automatic scroll,
  never instead of it. The microphone is asked for only then (ADR 0003).
  Recognition stays on this Mac; no audio or text is kept, uploaded or logged.

**2026-10-07 — measured: go for GigaAM.** Full write-up:
`docs/research/teleprompter-voice-follow.md`; harness:
`Spikes/TeleprompterVoice/`. Synthetic Russian speech (`say -v Milena`, a
Script written for the harness, five scenarios: straight, pauses, a skipped
line, off-script talk, a repeat), played in real time through the app's own
libraries and the app's own follower.

- The last **2 s re-decoded every 0.2 s on 2 threads**: decode 70 ms (p95
  74 ms), **0.85 of a core** while the voice is heard, about 360 MB with the
  model. Five minutes without a break: 0.86 of a core throughout, 401 MB
  peak, thermal state nominal, no thermal or performance warning from
  `pmset`. Watts not measured (needs the author's password).
- Word lit at the **median 0.0 s after it ends** (0.45 s after it starts);
  **p90 0.45–0.55 s** after it ends — short words ("и", "в") wait for the
  next word, and so does the first word after a pause. The 0.3 s target is
  met at the median, missed by about 0.2 s for the slowest tenth.
- In all five scenarios: every Script word lit, none lit before it was
  said, no movement while the voice was silent or off the Script, never back.
- 3 s and 4 s windows light no sooner and cost more (1.2–2.4 cores).
- **T-One**, measured the same way for comparison: 0.16 of a core, but
  words lit 0.8 s after they end (p90 1.3 s, a quarter over a second late),
  620 MB, and a second model to download. **Chosen: GigaAM**, because it
  lights the word about 0.8 s sooner and is already on the Mac; T-One stays
  the fallback if a core proves too much on battery.
- Two follower rules came out of the measurement's trace: going back needs
  the newest word heard to be the earlier one; a one- or two-letter word
  lights away from the place only right after the word before it.

**2026-10-07 — during a call (a note, not built).** Not tried. What the code
does: it opens its own input-only AudioQueue on the default input, beside
whatever the call app has open — macOS lets both capture. It hears the raw
microphone, without the call app's echo cancellation, so with speakers the
other side's voice reaches it. Another voice moves the Script only if it says
the Script's own next words in order: anything else is off-script and is
ignored, and a jump needs three words in a row (four to go back). No cheap
guard beyond that was obvious: voice processing (Apple's echo cancellation)
would mean AVAudioEngine, which the Dictation Module left because of
Bluetooth headsets switching profiles. Also unknown: whether opening the
microphone moves AirPods-style headsets to their call profile mid-call, and
what a call app's own mute means here (nothing — this capture is separate).
A headset avoids the echo question entirely.

## Done

Built on 2026-10-07, by Claude, from the decisions above. Status stays
`needs-info`: the author's hands are needed for what is listed last.

- [x] **Settings → Modules → Teleprompter → Follow my voice**, off by
  default, beside the speed — the set speed stays, and is what runs when this
  is off. Turning it on asks macOS for the microphone then and only then. A
  refused microphone leaves the switch off and says, in red, where to allow
  it, with an **Open Microphone Settings** button; without Dictation's model
  it says to download it under Dictation. The macOS prompt's own sentence now
  names the Teleprompter too (`Packaging/Info.plist`).
- [x] **Listening only while the Script runs**: the microphone opens on
  start or resume and closes on pause, stop, the end, or the switch going
  off. The model (Dictation's own, loaded a second time with 2 threads) is let
  go a minute after. While the reader is quiet, nothing is decoded.
- [x] **The voice moves the Script; silence holds it.** The row puts the
  line being read on top, by the camera, easing to it in 0.32 s (a jump under
  Reduce Motion), and lights the word being said with a soft cyan pill that
  slides from word to word. The last word read finishes the Script; its row
  leaves three seconds later, as at the set speed. Two fingers or the
  progress drag pause it, and the voice is then expected where the Script
  was put.
- [x] **Alignment** in `ScriptFollower` (Core, pure): skips, repeats,
  stumbles, off-script talk, silence, a line skipped, reading back — covered
  by 11 checks, plus 3 for the playback's voice mode
  (`Tests/CapacityNotchTests/ScriptFollowerTests.swift`).
- [x] **Russian and English** for every new sentence; VoiceOver hears
  "Teleprompter, following your voice" on the row, and the page shows a
  waveform labelled "Following your voice".
- [x] **Nothing kept**: audio stays in a 2 s ring in memory; recognised text
  goes to the follower and is dropped; nothing is logged or written.
- [x] `swift build`, `swift run CapacityNotchTests` (236 pass),
  `./Scripts/build-app.sh` pass.
- [x] If the microphone or model fails as the Script starts, following turns
  itself off and Settings says why, rather than leaving a Script waiting for
  a voice it cannot hear. *(My call — the author's "wait" was about a voice
  that stops, not a microphone that cannot start.)*

**Not verified by hand — needs the author:**

- Reading aloud through a real microphone, in a room, with the author's own
  voice and pace; the measurement used synthetic speech only. The quiet
  threshold that stops decoding in a pause (about −48 dBFS) is a guess.
- The microphone prompt, a refusal, and the red sentence in Settings.
- The feel of the motion: the 0.32 s ease between lines, the word light's
  colour and slide. No Paper drawing was made for the light.
- VoiceOver.
- During a call (note above), Bluetooth headsets, and battery — watts were
  not measured.

**2026-10-07 — first check by the author, own voice, real microphone.** The
word being said is lit, and when the voice stops the Script waits. Not yet
reported: a skipped line (the Script should catch up), talk off the Script
(it should not move), a call or a Bluetooth headset, VoiceOver.

**2026-10-07 — the rest of the check.** A skipped line: the Script catches
up. Talk off the Script: it stays put. With the earlier two, all four cases
behave as decided, on the author's own voice. Resolved. Still open as notes,
not as conditions: a call or a Bluetooth headset sharing the microphone, and
VoiceOver (the last is on ticket 22's list).
