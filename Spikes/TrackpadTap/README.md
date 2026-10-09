# Trackpad tap spike (ticket 14)

A throwaway measurement, kept apart from CapaTheNotch: which route sees a
one-finger tap on the trackpad from anywhere, and what it costs in
permissions. Evidence for a decision, not product code. Findings:
`docs/research/trackpad-double-tap.md`.

Nothing is downloaded. MultitouchSupport is opened at run time with
`dlopen`/`dlsym`, so a framework that is missing or changed prints a sentence
instead of crashing.

## Running it

One command, from the repository root, about a minute, with a finger:

```sh
Spikes/TrackpadTap/run.sh
```

It builds the spike, wraps it in an application of its own
(`tech.capathenotch.spike.trackpad-tap`, never granted anything) and launches
it through `open`, so what it sees is what an application with no permission
sees — not what the terminal, which may hold Input Monitoring, sees. It then
asks, in the terminal, for seven things in turn: hands off; three light
one-finger double taps; three pressed double-clicks; three two-finger double
taps; three one-finger holds; three palms; a two-finger scroll. Keep the
pointer over the empty desktop. Run it twice: once with System Settings ›
Trackpad › Tap to click off, once with it on.

The table is printed and written to `Spikes/TrackpadTap/Results/<time>.txt`
(never committed). Paste it into ticket 14.

Other ways:

```sh
Spikes/TrackpadTap/run.sh probe 30                                      # 30 s listening, nobody asked to touch
SPIKE_EVENT_TAP=1 Spikes/TrackpadTap/run.sh                             # also a listen-only CGEventTap (asks for Input Monitoring)
swift run --package-path Spikes/TrackpadTap trackpad-tap-spike          # from the terminal, with the terminal's permissions
```

## What it reads, and keeps

Per touch: how many fingers, how long, how far it moved, the contact's axes
and the framework's size and pressure values. Per phase: counts of global
events (clicks, pressure stages, gestures, scrolls) and how many touches
`NSEvent.touches(matching:in:)` gave. No position on screen, no key, nothing
about any application. It only listens; nothing is swallowed.
