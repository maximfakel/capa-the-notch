# 17: Build the Music Module

**What to build:** While something is playing — in Yandex Music, in a browser,
anywhere Control Center sees — the compact strip grows a row beneath Capacity
showing it, with previous, play/pause and next. The design is the author's
mockup: Paper file "Pairtask", page "Notch", artboard "Notch — Compact —
Playing".

**Blocked by:** none.

**Status:** ready-for-agent

**Why:** The author's own choice of first Module (ticket 15's order changed on
2026-09-24), and what the author listens to every day comes through a browser
or Yandex Music, which only the system's own Now Playing sees.

- [ ] Off until turned on in Settings; while off, nothing runs and nothing is
      read.
- [ ] While something plays, the compact strip shows the mockup's second row —
      artwork, title, artists, previous / play-pause / next, and the bars —
      beneath an unchanged Capacity row; 38 points becomes 90, measured, not
      eyeballed.
- [ ] On pause the row stays ten seconds, so play can resume from it, then the
      strip collapses; with nothing playing the strip is exactly as without
      the Module.
- [ ] The controls work on what is playing, whichever application plays it.
- [ ] The bars are decorative: they move while playing, stop on pause, and are
      still under Reduce Motion. No audio is captured.
- [ ] If macOS stops answering, Settings says "macOS no longer lets Capacity
      Notch read what's playing", Copy Diagnostics carries `music-unreadable`,
      and the strip shows nothing rather than a stale track.
- [ ] Idle cost stays under ticket 11's ceiling — 0.9% of one core — with
      music playing, measured.
- [ ] VoiceOver reads the row and its controls.

Not in the first version: anything in the expanded surface (it waits for a
mockup of moving between Modules), volume, seeking, likes.

## Notes

How it reads, verified on this machine (M1 Pro, macOS 26.6.2) on 2026-09-24:

- The private MediaRemote framework, called from an ordinary process, reports
  nothing playing while Chrome is playing audio and Control Center shows it.
- The same framework, called from `osascript -l JavaScript` through
  `MRNowPlayingRequest`, returns the item — Title, Artist, Album, artwork
  dimensions and MIME type, Duration, ElapsedTime, PlaybackRate — and
  `localIsPlaying`, with no permission prompted.
- `MRMediaRemoteSendCommand` from the same place paused and resumed the
  author's music (command 1, then 0), read back as rate 0, then 1.

This is a private interface, allowed by ADR 0004 and only on its terms.

Still to find out while building it: where the artwork's bytes come from (the
item names the artwork but no data was seen), and whether a long-running
`osascript` is needed to stay under the CPU ceiling, rather than one per read.
The behaviour follows ADR 0002: boring.notch's music is a reference for
behaviour only.

## Comments

**2026-09-24 — built.**

The author changed the design mid-way, in Paper: the expanded surface now has
pages — Capacity and music, with dots under the strip — and the music page
has a 120-point artwork, a progress bar with times, the controls and a heart
("Notch — Expanded — Playing"). Decided with the author:

- the heart shows only where the source supports liking — and the adapter has
  no like command, so for now it never shows;
- the progress bar seeks where the source allows it (Chrome does: command 24);
- the page opened is the last one chosen, Capacity the first time;
- pages turn by a two-finger swipe, with the arrow keys while pinned and
  VoiceOver actions as the unseen second way the spec requires;
- the music page exists while a track is loaded, paused or not;
- hovering opens the surface only from the Capacity strip, so the music row's
  controls stay within reach.

How it reads changed too. `osascript` gave everything but the artwork, which
comes only through an asynchronous call taking a block. boring.notch, looked
at for the mechanism only (it is GPL-3.0), uses mediaremote-adapter
(BSD 3-Clause, github.com/ungive/mediaremote-adapter); that is vendored here
unmodified at `73f14ab`, built from source by `Scripts/build-adapter.sh`, and
run as `/usr/bin/perl … stream`. ADR 0004 is amended to match.

Found along the way:

- The adapter sends a full payload without the artwork and the artwork as a
  diff; the stream follower keeps the artwork across a full payload for the
  same content item, and drops it for a new one.
- Animated in SwiftUI, the equalizer cost the application 20.7% of a core:
  8.9% with the bars still but the timeline ticking, 0.40% with no timer at
  all. Drawn with Core Animation it costs 0.23%; WindowServer's share could
  not be told from the noise of a browser playing video (50.0% static against
  50.0% and 53.3% moving).

### Verified

- 106 checks pass; the Music ones cover the adapter's stream (full, diff,
  null, artwork carried over, lines it did not write), the row's rule (ten
  seconds on pause, a track found paused, nothing, a lost reader), the
  commands (seek in microseconds), the position, the default off and the
  report's code.
- The real stream from this machine, replayed through the follower.
- The adapter, built from the vendored sources, reads Chrome with its artwork
  (15–33 KB JPEG); `test` exits 0 from inside the bundle and, with something
  playing, touches nothing; `send` and `seek` move the author's music.
- On the installed application, with the Module on: `test`, then `perl …
  stream`, started a second after launch; the panel is 422×90 while playing.
- Measured sizes match the drawing: row 52, closed 90, page 157, open 213;
  Capacity's 38 / 174 / 228 / 266 unchanged. Rendered pictures of the row and
  the page were held against the mockup.
- Two clean release builds give the same archive, with the framework and the
  test client inside and no home directory in any binary.

### Not verified

- A swipe, the arrow keys, the VoiceOver actions, and the buttons, clicked on
  the running surface — none were exercised by hand; only built and laid out.
- The paused row's ten seconds, and the page appearing and going, on screen.
- A closed MediaRemote: never seen; the failure path is `test` exiting
  non-zero, as the adapter documents.
- The artwork on screen: the pictures used a track without artwork.

**2026-09-24 — a child left behind.** Checking the installed application
found two adapter streams: the old one's parent was launchd. `pkill` — the
install loop's own step — sends SIGTERM, which skipped
`applicationWillTerminate`, so the application died and its `perl` stayed,
reading. SIGTERM now quits the application properly, and the reader stops any
stream of this bundle's that launchd has adopted before starting its own, for
the case of a crash. Seen: after a relaunch one stream remained; after `pkill`
of the new build, none.
