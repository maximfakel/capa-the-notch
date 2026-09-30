# 12: Spike local Speech Dictation on M1 Pro

**What to build:** After the Capacity MVP is released, create an isolated prototype that tests whether local push-to-talk Dictation is valuable and feasible on the target M1 Pro. This is evidence for a later roadmap decision, not a commitment to ship Dictation in Capacity Notch.

**Blocked by:** 11/Publish a free GitHub beta release; 16/Build the Teleprompter Module.

**Status:** resolved

- [ ] Holding a configurable global key records a phrase of up to 25 seconds, performs recognition locally, and stops listening immediately when released.
- [ ] The prototype evaluates Russian speech containing English developer terms and code-like vocabulary using a representative corpus and records correction effort.
- [ ] Recognized text inserts into Terminal, Xcode, VS Code, a browser, and a chat application, with a clipboard fallback that restores the user's prior clipboard contents.
- [ ] Microphone and Accessibility access are requested only while configuring or using the prototype, and the prototype remains understandable when either permission is denied.
- [ ] Audio and recognized text are never uploaded, retained as history, or written to logs; temporary audio is removed after inference.
- [ ] Measurements capture end-to-end latency, accuracy, memory, CPU/GPU use, battery impact, thermal behavior, model download size, and cold-start cost on M1 Pro.
- [ ] The result ends with an explicit go/no-go recommendation and does not enter the product roadmap automatically.

## Comments

**2026-09-24 — what this spike is evidence for now.**

Ticket 15 decided that Capacity Notch hosts Modules (ADR 0003), so this is no
longer evidence for whether Dictation belongs "in Capacity Notch" at all; it
is the feasibility check for a Dictation Module, second in the order after the
teleprompter (ticket 16), hence the new block. The go/no-go it ends with still
does not enter the roadmap on its own.

The target stands: this machine is an M1 Pro with 16 GB. A friend's MacBook
Pro 14 with an M5 is a second point, if he agrees to it. What ADR 0003 adds:
Dictation is off until turned on, asks for microphone and Accessibility access
only then, and may take the compact strip while it records.

**2026-09-26 — the engine is GigaAM; the spike proves it here.**

The author tried gigatype.app, which dictates Russian well, and chose GigaAM
(Sber's open Russian speech recognition) outright rather than comparing
engines. So the spike is no longer "which engine" but "does GigaAM work in
Capacity Notch on this M1 Pro", with the measurements above unchanged. What
it has to settle, besides them:

- **How it runs without Python** — sherpa-onnx (C and Swift APIs, and, as far
  as I recall, GigaAM already converted) is the first path to try; ONNX
  Runtime or Core ML directly if not.
- **Its licence** — the code's and, separately, the weights', against ADR
  0002 (an MIT application; the model is a separate download).
- **English developer terms inside Russian speech** — the one place a
  Russian model may be weak, and a requirement above; the corpus must
  measure it, and the go/no-go must say how much correcting it costs.
- **Streaming** — also measure recognition on short chunks as speech
  arrives, with word timings and its latency: ticket 20, a teleprompter that
  follows the voice, wants the same engine and cannot wait for a phrase to
  end. If GigaAM cannot stream well enough, say so; ticket 20 then needs its
  own answer, and this one does not change.

Checked against primary sources in `docs/research/gigaam.md` (2026-09-26):
the code and the v3 weights are MIT (avoid v1's archives, which still carry
its old non-commercial licence); sherpa-onnx ships GigaAM v3 as int8 ONNX,
offline only, through its C API and Swift package — no Python, no Core ML.
The plain v3 models can only write Cyrillic, so English terms come out
transliterated; the v3 punctuated (e2e) models can write Latin, which makes
`sherpa-onnx-nemo-transducer-punct-giga-am-v3-russian-2025-12-16` the first
model to try. The note lists seven things this spike still has to measure,
among them whether sherpa-onnx's audio framing matches the reference output.

**2026-09-26 — done: go, with English terms as the condition.**

Findings: `docs/research/dictation-spike.md`; prototype: `Spikes/Dictation/`
(its libraries, the model and the author's recordings stay out of git).
GigaAM v3 punctuated RNN-T through sherpa-onnx, CPU, from Swift:

- Speed: cold start 0.5–0.6 s, 400 MB with the model loaded; phrases up to
  25 s recognised in 0.09–0.37 s; live, text at the cursor 0.1–0.5 s after
  the key is released. The author confirmed the hot key, the recording and
  pasting into the applications he tried.
- Accuracy on the author's 33-phrase corpus: WER 21.8 %, CER 14.4 %. Every
  phrase without English terms came back word for word; only 5 of 69
  English terms came back in Latin. A personal vocabulary (hotwords, cut as
  BPE) at weight 1.0 gives 20.5 % and 15 of 69; higher weights add errors.
- Streaming, for ticket 20: a 4 s window re-decoded every 0.2 s keeps up,
  with token timings, at about 1.3 cores for as long as it listens.
- Not measured: battery and thermals (need the author's password for
  `powermetrics`); the key is not configurable; the 25 s cutoff was fixed
  after review and not tried again live.

Recommendation: go for a Dictation Module on GigaAM, deciding first how
English terms are corrected (a vocabulary, a replacement list, or both).
It does not enter the roadmap by itself.

**2026-09-30 — resolved.** The go above was acted on: Dictation shipped
(ticket 21). Battery and thermals were never measured; they are not a
condition for leaving the beta.
