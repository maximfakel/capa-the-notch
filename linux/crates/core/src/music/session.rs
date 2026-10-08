use super::now_playing::{NowPlaying, NowPlayingReading};
use super::presence::{MusicPresence, RememberedTrack};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

/// Everything a surface draws of the Music Module, at one moment.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MusicView {
    /// The Module is on: its page is there, whether or not anything plays.
    pub on: bool,
    /// The system stopped telling the application what is playing.
    pub unreadable: bool,
    /// What the compact strip's row shows: playing, or paused for less than
    /// ten seconds.
    pub shown: Option<NowPlaying>,
    /// What is loaded, however long it has been paused: the expanded surface's
    /// page exists while this does.
    pub loaded: Option<NowPlaying>,
    /// The last track, once nothing is loaded: the page shows it dimmed.
    pub remembered: Option<RememberedTrack>,
}

impl MusicView {
    /// Whether the music page is among the expanded surface's pages: the
    /// Module on, or a track loaded.
    pub fn has_page(&self) -> bool {
        self.on || self.loaded.is_some()
    }

    /// The track for the compact row. Over a fullscreen application the closed
    /// surface is the strip alone: a music row would sit on the tabs or the
    /// toolbar of the application the person asked to have the whole screen.
    /// Opening it still works.
    pub fn compact_track(&self, fullscreen: bool) -> Option<&NowPlaying> {
        if fullscreen { None } else { self.shown.as_ref() }
    }

    /// Whether the music row is in the compact strip.
    pub fn row_shown(&self, fullscreen: bool) -> bool {
        self.compact_track(fullscreen).is_some()
    }
}

/// The Music Module's state: what the reader has reported, and what it means.
/// Off, it holds nothing and shows nothing (ADR 0003).
#[derive(Debug, Clone, Default)]
pub struct MusicSession {
    presence: MusicPresence,
    on: bool,
    unreadable: bool,
}

impl MusicSession {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn is_on(&self) -> bool {
        self.on
    }

    pub fn start(&mut self) {
        self.on = true;
    }

    /// Switched off: nothing is kept.
    pub fn stop(&mut self, now: DateTime<Utc>) {
        self.on = false;
        self.unreadable = false;
        self.presence.forget(now);
    }

    pub fn observe(&mut self, reading: &NowPlayingReading, now: DateTime<Utc>) {
        if self.on {
            self.presence.observe(reading, now);
        }
    }

    /// The reader failed or stopped.
    pub fn lose(&mut self, now: DateTime<Utc>) {
        self.presence.lose(now);
    }

    pub fn set_unreadable(&mut self, unreadable: bool, now: DateTime<Utc>) {
        self.unreadable = unreadable;
        if unreadable {
            self.presence.lose(now);
        }
    }

    pub fn view(&self, now: DateTime<Utc>) -> MusicView {
        MusicView {
            on: self.on,
            unreadable: self.unreadable,
            shown: self.presence.shown(now),
            loaded: self.presence.loaded(now),
            remembered: self.presence.remembered(now),
        }
    }

    /// A paused row goes away ten seconds after the pause, and a track reported
    /// gone goes once the grace is over, whether or not the source says
    /// anything more in between (`next_change` says when).
    pub fn is_lingering(&self, now: DateTime<Utc>) -> bool {
        self.presence.shown(now).is_some_and(|t| !t.is_playing) || self.presence.is_holding(now)
    }

    /// When the view next changes by itself (`MusicPresence::next_change`): the
    /// moment to look again, rather than every so often while it lingers.
    pub fn next_change(&self, now: DateTime<Utc>) -> Option<DateTime<Utc>> {
        if !self.on {
            return None;
        }
        self.presence.next_change(now)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{Duration, TimeZone};

    fn t0() -> DateTime<Utc> {
        Utc.timestamp_opt(1_800_000_000, 0).unwrap()
    }

    fn playing() -> NowPlayingReading {
        NowPlayingReading::Item(NowPlaying::new("Zima", Some("annushkaa"), None, true))
    }

    fn paused() -> NowPlayingReading {
        NowPlayingReading::Item(NowPlaying::new("Zima", Some("annushkaa"), None, false))
    }

    #[test]
    fn off_it_holds_and_shows_nothing_and_has_no_page() {
        let mut s = MusicSession::new();
        s.observe(&playing(), t0());
        let v = s.view(t0());
        assert!(!v.on && v.shown.is_none() && v.loaded.is_none() && !v.has_page());
    }

    #[test]
    fn on_with_nothing_playing_the_page_stands_and_the_row_does_not() {
        let mut s = MusicSession::new();
        s.start();
        let v = s.view(t0());
        assert!(v.on && v.has_page() && !v.row_shown(false));
    }

    #[test]
    fn a_playing_track_is_in_the_row_except_over_a_fullscreen_application() {
        let mut s = MusicSession::new();
        s.start();
        s.observe(&playing(), t0());
        let v = s.view(t0());
        assert!(v.row_shown(false));
        assert!(!v.row_shown(true), "music does not show over a fullscreen application");
        assert!(v.loaded.is_some(), "though the page has it");
    }

    #[test]
    fn a_loaded_track_gives_a_page_even_after_the_module_is_switched_off_until_it_goes() {
        let mut s = MusicSession::new();
        s.start();
        s.observe(&playing(), t0());
        s.stop(t0() + Duration::seconds(1));
        let v = s.view(t0() + Duration::seconds(1));
        assert!(!v.on && !v.has_page() && v.remembered.is_none(), "switched off, it forgets");
    }

    #[test]
    fn the_pause_lingers_and_says_so_until_it_is_over() {
        let mut s = MusicSession::new();
        s.start();
        s.observe(&playing(), t0());
        s.observe(&paused(), t0() + Duration::seconds(5));
        assert!(s.is_lingering(t0() + Duration::seconds(6)));
        assert!(s.is_lingering(t0() + Duration::seconds(14)));
        assert!(!s.is_lingering(t0() + Duration::seconds(16)), "ten seconds from the pause");
        assert_eq!(s.next_change(t0() + Duration::seconds(6)), Some(t0() + Duration::seconds(15)), "the moment the row goes");
        assert_eq!(s.next_change(t0() + Duration::seconds(15)), None, "and nothing after it");
    }

    #[test]
    fn a_vanishing_track_is_a_holding_that_ends() {
        let mut s = MusicSession::new();
        s.start();
        s.observe(&playing(), t0());
        s.observe(&NowPlayingReading::Nothing, t0() + Duration::seconds(1));
        assert!(s.is_lingering(t0() + Duration::milliseconds(1500)));
        assert!(!s.is_lingering(t0() + Duration::seconds(4)));
        assert_eq!(s.next_change(t0() + Duration::milliseconds(1500)), Some(t0() + Duration::seconds(3)), "the grace over");
    }

    #[test]
    fn a_playing_track_changes_nothing_by_itself() {
        let mut s = MusicSession::new();
        s.start();
        s.observe(&playing(), t0());
        assert_eq!(s.next_change(t0() + Duration::seconds(1)), None);
        s.stop(t0() + Duration::seconds(2));
        assert_eq!(s.next_change(t0() + Duration::seconds(2)), None, "off, nothing at all");
    }

    #[test]
    fn an_unreadable_source_loses_what_it_had_and_says_so() {
        let mut s = MusicSession::new();
        s.start();
        s.observe(&playing(), t0());
        s.set_unreadable(true, t0() + Duration::seconds(2));
        let v = s.view(t0() + Duration::seconds(2));
        assert!(v.unreadable && v.shown.is_none() && v.loaded.is_none());
        assert!(v.remembered.is_some(), "the last track is still remembered for the page");
        s.set_unreadable(false, t0() + Duration::seconds(3));
        assert!(!s.view(t0() + Duration::seconds(3)).unreadable);
    }

    #[test]
    fn the_view_is_json_for_surfaces() {
        let mut s = MusicSession::new();
        s.start();
        s.observe(&playing(), t0());
        let json = serde_json::to_value(s.view(t0())).unwrap();
        assert_eq!(json["on"], true);
        assert_eq!(json["shown"]["title"], "Zima");
        assert_eq!(json["shown"]["isPlaying"], true);
        assert!(json["remembered"].is_null());
    }
}
