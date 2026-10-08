use super::now_playing::{seconds_between, NowPlaying, NowPlayingReading};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

/// The last track loaded, after it has gone.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RememberedTrack {
    pub track: NowPlaying,
    /// When it stopped being loaded.
    pub ended_at: DateTime<Utc>,
}

/// Whether the compact strip shows its music row, and with what.
///
/// Playing, it shows. Paused, it stays ten seconds — long enough to press play
/// again — and the ten seconds run from the moment of the pause, not from the
/// last time the pause was reported. A track found already paused was never
/// seen playing, so there is no pause to linger on. Nothing loaded, or a
/// reader that failed, shows nothing: a stale track is worse than none.
///
/// Nothing loaded is believed only once it has lasted two seconds. Some
/// players — Yandex Music, between tracks — report nothing and then the next
/// track within the same second; taken at its word, that nothing would close
/// the expanded surface's page and send it back to Capacity.
///
/// Once a track has gone — its player quit, its tab closed — the last one is
/// remembered, with when it went, for the music page to show until another
/// plays. Only switching the Module off forgets it.
///
/// A new track arrives without its artwork, which follows a moment later. For
/// up to the same two seconds the last cover stays in its place, so the
/// player's icon does not blink in between.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct MusicPresence {
    current: Option<NowPlaying>,
    paused_at: Option<DateTime<Utc>>,
    /// When nothing was reported, while the track before it is still held.
    vanished_at: Option<DateTime<Utc>>,
    /// The last track's cover, held for a new one that has none yet.
    held_artwork: Option<Vec<u8>>,
    held_since: Option<DateTime<Utc>>,
    /// The last track loaded, and when it stopped being loaded.
    memory: Option<NowPlaying>,
    memory_ended_at: Option<DateTime<Utc>>,
}

impl MusicPresence {
    pub const PAUSE_LINGER: f64 = 10.0;
    pub const VANISH_GRACE: f64 = 2.0;

    pub fn new() -> Self {
        Self::default()
    }

    pub fn observe(&mut self, reading: &NowPlayingReading, moment: DateTime<Utc>) {
        // A nothing that outlasted its grace was believed: what came before it
        // is gone, and lends nothing to what comes next.
        if let Some(vanished) = self.vanished_at {
            if seconds_between(vanished, moment) >= Self::VANISH_GRACE {
                self.lose(moment);
            }
        }
        match reading {
            NowPlayingReading::Item(item) => {
                self.hold_artwork(item, moment);
                self.remember(item);
            }
            NowPlayingReading::Nothing => {
                if self.memory.is_some() && self.memory_ended_at.is_none() {
                    self.memory_ended_at = Some(moment);
                }
            }
        }
        match reading {
            NowPlayingReading::Nothing => {
                if self.current.is_some() && self.vanished_at.is_none() {
                    self.vanished_at = Some(moment);
                }
            }
            NowPlayingReading::Item(item) if item.is_playing => {
                self.current = Some(item.clone());
                self.paused_at = None;
                self.vanished_at = None;
            }
            NowPlayingReading::Item(item) => {
                let was_playing = self.current.as_ref().is_some_and(|c| c.is_playing) && self.vanished_at.is_none();
                let pause_started = if was_playing { moment } else { self.paused_at.unwrap_or(DateTime::<Utc>::MIN_UTC) };
                self.current = Some(item.clone());
                self.paused_at = Some(pause_started);
                self.vanished_at = None;
            }
        }
    }

    /// The track loaded, playing or paused, however long ago it paused. The
    /// strip's row lingers only ten seconds; the expanded surface's page stays
    /// as long as there is a track.
    pub fn loaded(&self, now: DateTime<Utc>) -> Option<NowPlaying> {
        if let Some(vanished) = self.vanished_at {
            if seconds_between(vanished, now) >= Self::VANISH_GRACE {
                return None;
            }
        }
        let current = self.current.as_ref()?;
        if let (Some(artwork), Some(since)) = (&self.held_artwork, self.held_since) {
            if seconds_between(since, now) < Self::VANISH_GRACE {
                return Some(current.with_artwork(Some(artwork.clone())));
            }
        }
        Some(current.clone())
    }

    /// Something is held for its grace — a track reported gone, or a cover
    /// waiting for its replacement: whoever shows this must look again once the
    /// grace is over.
    pub fn is_holding(&self, now: DateTime<Utc>) -> bool {
        if self.current.is_none() {
            return false;
        }
        [self.vanished_at, self.held_since]
            .into_iter()
            .flatten()
            .any(|since| seconds_between(since, now) < Self::VANISH_GRACE)
    }

    /// The next moment `shown` or `loaded` changes by itself, the source saying
    /// nothing more: a pause's ten seconds over, a track gone or a cover held
    /// past its grace. None while nothing is timed.
    pub fn next_change(&self, now: DateTime<Utc>) -> Option<DateTime<Utc>> {
        let current = self.current.as_ref()?;
        let after = |since: Option<DateTime<Utc>>, seconds: f64| {
            since.and_then(|s| s.checked_add_signed(chrono::Duration::milliseconds((seconds * 1000.0) as i64)))
        };
        let pause_over = if current.is_playing { None } else { after(self.paused_at, Self::PAUSE_LINGER) };
        [pause_over, after(self.vanished_at, Self::VANISH_GRACE), after(self.held_since, Self::VANISH_GRACE)]
            .into_iter()
            .flatten()
            .filter(|at| *at > now)
            .min()
    }

    fn hold_artwork(&mut self, item: &NowPlaying, moment: DateTime<Utc>) {
        if let Some(since) = self.held_since {
            if seconds_between(since, moment) >= Self::VANISH_GRACE {
                self.held_artwork = None;
                self.held_since = None;
            }
        }
        if item.artwork.is_some() {
            self.held_artwork = None;
            self.held_since = None;
        } else if self.held_since.is_none() {
            let last = self.current.as_ref().and_then(|c| {
                let changed = c.title != item.title || c.artist != item.artist;
                changed.then(|| c.artwork.clone()).flatten()
            });
            match last {
                Some(last) => {
                    self.held_artwork = Some(last);
                    self.held_since = Some(moment);
                }
                None => self.held_artwork = None,
            }
        }
    }

    /// The reader failed or stopped: nothing is known to be loaded any more.
    pub fn lose(&mut self, moment: DateTime<Utc>) {
        if self.memory.is_some() && self.memory_ended_at.is_none() {
            self.memory_ended_at = Some(moment);
        }
        self.current = None;
        self.paused_at = None;
        self.vanished_at = None;
        self.held_artwork = None;
        self.held_since = None;
    }

    /// The Module switched off: nothing is kept.
    pub fn forget(&mut self, moment: DateTime<Utc>) {
        self.lose(moment);
        self.memory = None;
        self.memory_ended_at = None;
    }

    /// The last track, while nothing is loaded.
    pub fn remembered(&self, now: DateTime<Utc>) -> Option<RememberedTrack> {
        if self.loaded(now).is_some() {
            return None;
        }
        Some(RememberedTrack { track: self.memory.as_ref()?.with_playing(false), ended_at: self.memory_ended_at? })
    }

    fn remember(&mut self, item: &NowPlaying) {
        let artwork = item
            .artwork
            .clone()
            .or_else(|| self.memory.as_ref().filter(|m| m.title == item.title).and_then(|m| m.artwork.clone()));
        self.memory = Some(item.with_artwork(artwork));
        self.memory_ended_at = None;
    }

    pub fn shown(&self, now: DateTime<Utc>) -> Option<NowPlaying> {
        let current = self.loaded(now)?;
        if current.is_playing {
            return Some(current);
        }
        let paused = self.paused_at?;
        (seconds_between(paused, now) < Self::PAUSE_LINGER).then_some(current)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{Duration, TimeZone};

    fn heard() -> DateTime<Utc> {
        Utc.timestamp_opt(1_800_000_000, 0).unwrap()
    }

    fn at(secs: f64) -> DateTime<Utc> {
        heard() + Duration::microseconds((secs * 1e6).round() as i64)
    }

    fn track() -> NowPlaying {
        NowPlaying::new("Mad Technology", Some("CZARFACE"), Some("com.google.Chrome"), true)
    }

    fn paused() -> NowPlaying {
        NowPlaying::new("Mad Technology", Some("CZARFACE"), Some("com.google.Chrome"), false)
    }

    fn item(n: &NowPlaying) -> NowPlayingReading {
        NowPlayingReading::Item(n.clone())
    }

    #[test]
    fn the_row_shows_while_playing_and_lingers_briefly_on_pause() {
        let mut presence = MusicPresence::new();
        presence.observe(&item(&track()), heard());
        assert_eq!(presence.shown(heard()), Some(track()), "playing is shown");

        presence.observe(&item(&paused()), at(60.0));
        assert_eq!(presence.shown(at(69.0)), Some(paused()), "paused, it stays long enough to press play again");
        assert_eq!(presence.shown(at(71.0)), None, "then the strip collapses");
        assert_eq!(presence.loaded(at(71.0)), Some(paused()), "but the track is still loaded, so the expanded surface keeps its page");

        presence.observe(&item(&track()), at(80.0));
        assert_eq!(presence.shown(at(80.0)), Some(track()), "playing again brings it back");

        presence.observe(&item(&paused()), at(90.0));
        presence.observe(&item(&paused()), at(95.0));
        assert_eq!(presence.shown(at(101.0)), None, "the ten seconds run from the pause, not from the last time the pause was reported");
    }

    #[test]
    fn nothing_playing_or_unreadable_shows_no_row() {
        let mut presence = MusicPresence::new();
        presence.observe(&item(&paused()), heard());
        assert_eq!(presence.shown(heard()), None, "a track found already paused was never seen playing, so there is no pause to linger on");

        presence.observe(&item(&track()), heard());
        presence.observe(&NowPlayingReading::Nothing, at(1.0));
        let settled = at(1.0 + MusicPresence::VANISH_GRACE);
        assert_eq!(presence.shown(settled), None, "nothing loaded shows nothing");
        assert_eq!(presence.loaded(settled), None, "and has no page");

        presence.observe(&item(&track()), at(20.0));
        presence.lose(at(20.0));
        assert_eq!(presence.shown(at(20.0)), None, "a reader that failed shows nothing rather than the last track it saw");
    }

    /// Yandex Music, between one track and the next, reports nothing at all
    /// and then the next track, within the same second. The page must not go —
    /// its going sends the expanded surface back to Capacity.
    #[test]
    fn a_track_change_through_nothing_keeps_the_page() {
        let next = NowPlaying::new("Historia Morbi", Some("Mgła"), Some("ru.yandex.desktop.music"), true);
        let mut presence = MusicPresence::new();
        presence.observe(&item(&track()), heard());
        presence.observe(&NowPlayingReading::Nothing, at(1.0));
        assert_eq!(presence.loaded(at(1.2)), Some(track()), "nothing for a moment is not a track gone");
        assert_eq!(presence.shown(at(1.2)), Some(track()), "nor does the strip's row blink out");

        presence.observe(&item(&next), at(1.3));
        assert_eq!(presence.loaded(at(1.3)), Some(next.clone()), "the next track takes its place");
        assert_eq!(
            presence.loaded(at(1.3 + MusicPresence::VANISH_GRACE + 1.0)),
            Some(next),
            "and stays: the nothing before it is forgotten"
        );
    }

    /// The next track arrives without its artwork, which follows on its own a
    /// moment later. Until it does, the last cover stays, rather than the
    /// player's icon blinking in between; a track that never sends one gets
    /// the icon.
    #[test]
    fn a_track_change_keeps_the_last_cover_until_its_own_arrives() {
        let player = Some("ru.yandex.desktop.music");
        let cover = vec![1, 2, 3];
        let next_cover = vec![4, 5, 6];
        let mut first = NowPlaying::new("Zima", Some("annushkaa"), player, true);
        first.artwork = Some(cover.clone());
        let next = NowPlaying::new("Historia Morbi", Some("Mgła"), player, true);
        let mut next_with_cover = next.clone();
        next_with_cover.artwork = Some(next_cover.clone());

        let mut presence = MusicPresence::new();
        presence.observe(&item(&first), heard());
        presence.observe(&item(&next), at(1.0));
        let between = presence.loaded(at(1.5)).unwrap();
        assert_eq!(between.title, "Historia Morbi", "the new title is shown at once");
        assert_eq!(between.artwork.as_ref(), Some(&cover), "the last cover stays while the new one is on its way");
        assert_eq!(presence.shown(at(1.5)).unwrap().artwork.as_ref(), Some(&cover), "in the strip's row too");

        presence.observe(&item(&next_with_cover), at(1.8));
        assert_eq!(presence.loaded(at(1.8)).unwrap().artwork.as_ref(), Some(&next_cover), "its own cover replaces it");

        presence.observe(&item(&first), at(10.0));
        presence.observe(&item(&next), at(11.0));
        assert_eq!(
            presence.loaded(at(11.0 + MusicPresence::VANISH_GRACE)).unwrap().artwork,
            None,
            "a track that sends no cover does not keep someone else's"
        );
        assert!(!presence.is_holding(at(11.0 + MusicPresence::VANISH_GRACE)), "nor is anything held after the grace");

        presence.observe(&NowPlayingReading::Nothing, at(20.0));
        presence.observe(&item(&next), at(30.0));
        assert_eq!(presence.loaded(at(30.0)).unwrap().artwork, None, "nor one from before a nothing that was believed");
    }

    /// The music page stays while the Module is on, and once a track has gone
    /// it shows the last one, dimmed, with when it went — until another plays.
    #[test]
    fn the_last_track_is_remembered_after_it_goes() {
        let mut presence = MusicPresence::new();
        assert_eq!(presence.remembered(heard()), None, "nothing has played yet");

        presence.observe(&item(&track()), heard());
        assert_eq!(presence.remembered(heard()), None, "while it is loaded it is not a memory");

        presence.observe(&NowPlayingReading::Nothing, at(60.0));
        let gone = at(60.0 + MusicPresence::VANISH_GRACE);
        assert_eq!(presence.loaded(gone), None, "the track has gone");
        let memory = presence.remembered(gone).unwrap();
        assert_eq!(memory.track.title, "Mad Technology", "but it is remembered");
        assert!(!memory.track.is_playing, "as not playing");
        assert_eq!(memory.ended_at, at(60.0), "since the moment nothing was first reported");

        presence.observe(&item(&paused()), at(120.0));
        assert_eq!(presence.remembered(at(120.0)), None, "a track loaded again is no memory");

        presence.lose(at(130.0));
        assert_eq!(presence.remembered(at(130.0)).unwrap().ended_at, at(130.0), "a reader that failed remembers too");

        presence.forget(at(135.0));
        assert_eq!(presence.remembered(at(140.0)), None, "switched off, it forgets");
    }

    #[test]
    fn a_remembered_track_keeps_its_cover_across_a_coverless_report_of_the_same_track() {
        let mut with_cover = track();
        with_cover.artwork = Some(vec![9]);
        let mut presence = MusicPresence::new();
        presence.observe(&item(&with_cover), heard());
        presence.observe(&item(&track()), at(1.0));
        presence.observe(&NowPlayingReading::Nothing, at(2.0));
        let memory = presence.remembered(at(10.0)).unwrap();
        assert_eq!(memory.track.artwork, Some(vec![9]));
    }
}
