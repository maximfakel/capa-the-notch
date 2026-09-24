# 18: Like the playing track

**What to build:** The heart on the Music Module's expanded page (Paper
"Pairtask", page "Notch", "Notch — Expanded — Playing") likes and unlikes the
track, in players that keep likes.

**Blocked by:** 17/Build the Music Module.

**Status:** wontfix

**Why:** The author drew the heart and asked for it to work. Today it is drawn
and cannot be pressed: it appears only where the player reports
`supportsIsLiked`, filled when `isLiked` is true.

- [ ] Pressing the heart likes the track, and pressing it again takes the like
      away, in a player that keeps likes.
- [ ] The heart follows what the player reports, so a like made in the player
      itself shows here too.
- [ ] Where the player keeps no likes (a browser), there is no heart — as now.
- [ ] VoiceOver says whether the track is liked and what pressing does.

## What has to be answered first

mediaremote-adapter sends only MediaRemote's transport commands (ids 0–13 in
its `send`); `src/adapter/send.m` carries
`TODO like/unlike tracks by reading now playing information first, getting the track ID, station ID and station hash`.
So liking needs a change to the vendored adapter, which is copied unmodified
today (`Vendor/mediaremote-adapter/VENDORED.md`).

1. **Which command, with which options.** MediaRemote's like command id, and
   whether it needs the content item or station identifiers the TODO names.
   Measure against Music with an Apple Music track, not from memory.
2. **Which players answer.** Chrome reported neither `supportsIsLiked` nor
   `isLiked` on 2026-09-24. Music, Spotify and others each need a look.
3. **Patch or upstream.** A local patch recorded in `VENDORED.md`, or a change
   offered to ungive/mediaremote-adapter first. ADR 0004 governs the private
   interface either way.

## Comments

2026-09-24 — Opened after the Paper layout pass. `NowPlaying.supportsLiking`
and `isLiked` are read from the adapter's stream and tested
(`MusicTests.aPlayerThatTakesLikesSaysSo`); `LikeMark` in `MusicViews.swift`
draws the heart without an action.

2026-09-24 — What each player answers, measured on macOS 26.6 with an
experimental copy of the adapter (in the session's scratchpad, not vendored)
that lists supported commands (`MRMediaRemoteGetSupportedCommands`) and sends
with a reply (`MRMediaRemoteSendCommandWithReply`); signatures read from the
disassembly, command names from `MRMediaRemoteCopyCommandDescription`.

- **The vendored header's numbers are wrong for this macOS.** LikeTrack is 21,
  DislikeTrack 22, BookmarkTrack 23; `0x6A`–`0x6D` are BanTrack,
  AddTrackToWishList, RemoveTrackFromWishList, NextInContext. One BanTrack
  (106) went to Music by mistake before this was checked; Music ignored it
  (`disliked` stayed false).
- **Music** advertises 30 commands. LikeTrack is there but disabled
  (`enabled=0`), titled "Нравится / Чаще воспроизводить похожие" — the radio
  "suggest more like this", not Favourite; DislikeTrack likewise. No enabled
  command sets Favourite (149 is ToggleTransitions). Sending 21 returns true
  and changes nothing. Music's own AppleScript does it: `favorited of current
  track` reads and sets it — set true, read true, set false, verified.
  Music reports a `UniqueIdentifier`, no `supportsIsLiked`/`isLiked`.
- **Yandex Music** (`ru.yandex.desktop.music`, Electron) advertises only 0–5
  and 24; LikeTrack answers with a reply of `404`; no track identifier; no
  AppleScript dictionary. The heart in the app did not light.
- **Chrome**: no track identifier, no like.
- **Yandex's API** (ym.marshal.dev, `users_likes_tracks_add(track_id)`) is
  unofficial and reverse-engineered, LGPL-3 Python, and needs the person's
  OAuth token; the desktop app gives no `track_id`, so it would be guessed from
  title and artist, or read over the undocumented Ynison protocol. A private
  interface under ADR 0004 and Yandex's terms — the author's decision.

2026-09-24 — Closed, the author's decision: not worth the work for a like.
MediaRemote likes none of the three players used here, and the only paths
left are per player — AppleScript for Music, an unofficial API and an account
token for Yandex Music. The heart is removed from the code with it —
`LikeMark` and `NowPlaying.supportsLiking`/`isLiked` and their test — and
from the Paper drawing.
