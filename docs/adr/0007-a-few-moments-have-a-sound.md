# A Few Moments Have a Sound

CapaTheNotch was silent; the author chose sounds in procedural-sounds (https://github.com/m1ckc3s/procedural-sounds) for it, and which moment has which. Each says, by ear, what the surface already says on screen, at a moment that is an outcome of something done, or something gone wrong that wants a look:

- **"tap"** — the surface pinned or let go with a click; a file taken by the Shelf, as the drop is accepted; a Clipping copied.
- **"success"** — dictated text inserted, or copied where it could not be inserted (either way the text is the person's, kept for them); the speech model downloaded and ready; Kapa tapped, as it giggles.
- **"notification"** — a window that had a Capacity Alert recovering, the good news after the bad (only where the alert was sent); Kapa saying hello, once a launch, when it first waves on the open surface; onboarding finished.
- **"error"** — dictation failed.
- **"warning"** — a Capacity Alert, in place of a banner sound (the banner itself stays silent); a Provider that was answering and stopped — disconnected, or failing for a reason that is not retried. A blip that is retried does not sound, nor a Provider not connected at launch, which would sound at every start, nor a Disconnect in Settings.

Silent on purpose: recording starting and stopping (the microphone is open, and a sound would be dictated); the music and Teleprompter controls (a sound over music, or on a call); Settings' switches and buttons (macOS settings do not click); consent questions; and whatever arrives by itself — screenshots and copied images on the Shelf.

Sounds are on, with one switch to turn them off (Settings ▸ General), as Kapa is (ADR 0006); they also follow macOS's "Play user interface sound effects". Nothing plays while the Teleprompter runs: someone reading a Script aloud is on a call or a recording, and that is the worst moment to be heard.

The sounds are kept as procedural-sounds' recipes, not as audio files, and drawn once each when the application starts by `SoundSynth`, a Swift translation of its player trimmed to what the recipes use — oscillators at a fixed pitch, noise, its two envelopes, biquad filters and the feedback echo. A recipe asking for more does not decode rather than playing wrong. Exported WAVs were the alternative: simpler, but five binaries to keep in step with recipes nobody could read. Rendered, each layer matches procedural-sounds' own export to a correlation of 0.999 or better. Its code is MIT, adapted in turn from @web-kits/audio and cuelume (MIT); all three are credited in `THIRD_PARTY_NOTICES.md`.
