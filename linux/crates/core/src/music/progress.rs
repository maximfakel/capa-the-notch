use super::command::MusicCommand;
use super::now_playing::{seconds_between, NowPlaying};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

/// A seek sent and not yet reported back. Until the stream says the track is
/// there, the bar stays where it was let go, rather than springing back to the
/// old reading and then jumping forward.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Sought {
    pub target: f64,
    pub at: DateTime<Utc>,
}

/// Where the progress bar stands, for one frame.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProgressView {
    /// Seconds into the track.
    pub position: f64,
    /// 0 to 1.
    pub fraction: f64,
    pub duration: f64,
    /// "00:46" for the left label, "03:44" for the right.
    pub position_text: String,
    pub duration_text: String,
}

/// Where the track is, and — where the source allows it — the place to drag
/// it to: the music page's progress bar as a state machine, so every surface
/// seeks the same way.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct MusicProgress {
    dragged: Option<f64>,
    sought: Option<Sought>,
}

impl MusicProgress {
    /// The reading that lands near the target settles it.
    pub const SETTLE_WITHIN: f64 = 2.0;
    /// One that never comes gives the bar back after this long.
    pub const GIVE_UP_AFTER: f64 = 3.0;

    pub fn new() -> Self {
        Self::default()
    }

    pub fn sought(&self) -> Option<Sought> {
        self.sought
    }

    pub fn is_dragging(&self) -> bool {
        self.dragged.is_some()
    }

    /// Where a sought track should be by now, moving at the rate it plays.
    fn expected(sought: &Sought, track: &NowPlaying, clock: DateTime<Utc>) -> f64 {
        let rate = if track.is_playing { track.rate.unwrap_or(1.0) } else { 0.0 };
        sought.target + seconds_between(sought.at, clock) * rate
    }

    pub fn view(&self, track: &NowPlaying, clock: DateTime<Utc>) -> ProgressView {
        let duration = track.duration.unwrap_or(0.0);
        let position = self
            .dragged
            .map(|d| d * duration)
            .or_else(|| self.sought.as_ref().map(|s| Self::expected(s, track, clock).min(duration)))
            .or_else(|| track.position(clock))
            .unwrap_or(0.0);
        let fraction = if duration > 0.0 { (position / duration).clamp(0.0, 1.0) } else { 0.0 };
        ProgressView {
            position,
            fraction,
            duration,
            position_text: clock_text(position),
            duration_text: clock_text(duration),
        }
    }

    /// A finger or pointer on the bar, as a fraction of its width. The whole
    /// width answers, not only what has been played — seeking forward is the
    /// common case. A track with no duration cannot be sought.
    pub fn drag(&mut self, fraction: f64, track: &NowPlaying) {
        if track.duration.unwrap_or(0.0) > 0.0 {
            self.dragged = Some(fraction.clamp(0.0, 1.0));
        }
    }

    /// Let go: the seek to send, if any.
    pub fn end_drag(&mut self, track: &NowPlaying, now: DateTime<Utc>) -> Option<MusicCommand> {
        let dragged = self.dragged.take()?;
        let duration = track.duration.unwrap_or(0.0);
        if duration <= 0.0 {
            return None;
        }
        let target = dragged * duration;
        self.sought = Some(Sought { target, at: now });
        Some(MusicCommand::Seek { to: target })
    }

    /// A new reading of the track arrived.
    pub fn track_changed(&mut self, track: &NowPlaying, now: DateTime<Utc>) {
        let (Some(sought), Some(reported)) = (self.sought, track.position(now)) else { return };
        if (reported - Self::expected(&sought, track, now)).abs() < Self::SETTLE_WITHIN {
            self.sought = None;
        }
    }

    /// Call as time passes: gives the bar back once a seek has gone
    /// unanswered for three seconds.
    pub fn expire(&mut self, now: DateTime<Utc>) {
        if self.sought.is_some_and(|s| seconds_between(s.at, now) >= Self::GIVE_UP_AFTER) {
            self.sought = None;
        }
    }

    /// A different track: nothing sought or dragged belongs to it.
    pub fn reset(&mut self) {
        *self = Self::default();
    }
}

/// `mm:ss`, minutes not capped at 59.
pub fn clock_text(seconds: f64) -> String {
    let whole = seconds.max(0.0).floor() as i64;
    format!("{:02}:{:02}", whole / 60, whole % 60)
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{Duration, TimeZone};

    fn t0() -> DateTime<Utc> {
        Utc.timestamp_opt(1_800_000_000, 0).unwrap()
    }

    fn after(s: f64) -> DateTime<Utc> {
        t0() + Duration::microseconds((s * 1e6).round() as i64)
    }

    fn playing() -> NowPlaying {
        let mut t = NowPlaying::new("Mad Technology", None, None, true);
        t.duration = Some(224.0);
        t.elapsed = Some(46.0);
        t.elapsed_at = Some(t0());
        t.rate = Some(1.0);
        t
    }

    #[test]
    fn the_clock_is_minutes_and_seconds() {
        assert_eq!(clock_text(0.0), "00:00");
        assert_eq!(clock_text(46.9), "00:46");
        assert_eq!(clock_text(224.0), "03:44");
        assert_eq!(clock_text(3725.0), "62:05");
        assert_eq!(clock_text(-4.0), "00:00");
    }

    #[test]
    fn the_bar_follows_the_reported_position() {
        let p = MusicProgress::new();
        let v = p.view(&playing(), after(10.0));
        assert_eq!(v.position, 56.0);
        assert!((v.fraction - 56.0 / 224.0).abs() < 1e-9);
        assert_eq!((v.position_text.as_str(), v.duration_text.as_str()), ("00:56", "03:44"));
    }

    #[test]
    fn a_track_with_no_duration_has_an_empty_bar_and_cannot_be_dragged() {
        let live = NowPlaying::new("Live", None, None, true);
        let mut p = MusicProgress::new();
        assert_eq!(p.view(&live, t0()).fraction, 0.0);
        p.drag(0.5, &live);
        assert!(!p.is_dragging());
        assert_eq!(p.end_drag(&live, t0()), None);
    }

    #[test]
    fn dragging_shows_the_finger_and_letting_go_sends_a_seek() {
        let mut p = MusicProgress::new();
        let track = playing();
        p.drag(0.5, &track);
        assert_eq!(p.view(&track, after(1.0)).position, 112.0, "the bar is where the finger is");
        p.drag(1.7, &track);
        assert_eq!(p.view(&track, after(1.0)).fraction, 1.0, "never outside the bar");

        p.drag(0.25, &track);
        let sent = p.end_drag(&track, after(2.0));
        assert_eq!(sent, Some(MusicCommand::Seek { to: 56.0 }));
        assert!(!p.is_dragging());
    }

    #[test]
    fn after_a_seek_the_bar_stays_where_it_was_let_go_and_moves_on_at_the_rate() {
        let mut p = MusicProgress::new();
        let track = playing();
        p.drag(0.5, &track);
        p.end_drag(&track, after(2.0));
        // The stream still says 46 + 3 = 49; the bar holds the seek.
        let v = p.view(&track, after(5.0));
        assert!((v.position - (112.0 + 3.0)).abs() < 1e-9, "target plus the time since: {}", v.position);

        let mut paused = track.with_playing(false);
        paused.rate = Some(0.0);
        assert_eq!(p.view(&paused, after(5.0)).position, 112.0, "a paused track does not move on");
    }

    #[test]
    fn a_reading_near_the_target_settles_the_seek_and_a_far_one_does_not() {
        let mut p = MusicProgress::new();
        let track = playing();
        p.drag(0.5, &track);
        p.end_drag(&track, after(2.0));

        p.track_changed(&track, after(2.5)); // reports ~48.5, target ~112.5
        assert!(p.sought().is_some(), "the old position does not settle it");

        let mut there = playing();
        there.elapsed = Some(113.0);
        there.elapsed_at = Some(after(3.0));
        p.track_changed(&there, after(3.0));
        assert!(p.sought().is_none(), "the track is where it was sent");
    }

    #[test]
    fn a_seek_that_is_never_answered_is_given_up_after_three_seconds() {
        let mut p = MusicProgress::new();
        let track = playing();
        p.drag(0.5, &track);
        p.end_drag(&track, after(2.0));
        p.expire(after(4.9));
        assert!(p.sought().is_some());
        p.expire(after(5.0));
        assert!(p.sought().is_none());
        assert_eq!(p.view(&track, after(5.0)).position, 51.0, "the bar goes back to the reading");
    }
}
