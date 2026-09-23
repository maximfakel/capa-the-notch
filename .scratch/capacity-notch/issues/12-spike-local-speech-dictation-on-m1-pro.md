# 12: Spike local Speech Dictation on M1 Pro

**What to build:** After the Capacity MVP is released, create an isolated prototype that tests whether local push-to-talk Dictation is valuable and feasible on the target M1 Pro. This is evidence for a later roadmap decision, not a commitment to ship Dictation in Capacity Notch.

**Blocked by:** 11/Publish a free GitHub beta release; 16/Build the Teleprompter Module.

**Status:** ready-for-agent

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
