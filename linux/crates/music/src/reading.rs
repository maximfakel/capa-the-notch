//! Comparing readings: a source tells the Module only when something a person
//! would notice changed, not each time a position is sampled.

use capa_core::music::NowPlayingReading;
use chrono::Utc;

/// Two readings that say the same thing, to within the position moving on.
pub fn differs(a: &NowPlayingReading, b: &NowPlayingReading) -> bool {
    match (a, b) {
        (NowPlayingReading::Nothing, NowPlayingReading::Nothing) => false,
        (NowPlayingReading::Item(x), NowPlayingReading::Item(y)) => {
            let near = match (x.position(y.elapsed_at.unwrap_or_else(Utc::now)), y.elapsed) {
                (Some(expected), Some(actual)) => (expected - actual).abs() < 1.5,
                _ => true,
            };
            !(x.title == y.title && x.artist == y.artist && x.album == y.album && x.player == y.player
                && x.player_name == y.player_name && x.icon_id == y.icon_id
                && x.is_playing == y.is_playing && x.duration == y.duration && x.artwork == y.artwork
                && x.rate == y.rate && near)
        }
        _ => true,
    }
}


#[cfg(test)]
mod tests {
    use super::*;
    use capa_core::music::NowPlaying;
    use chrono::{Duration, TimeZone};

    fn track(elapsed: f64, playing: bool, at_s: i64) -> NowPlayingReading {
        let at = Utc.timestamp_opt(1_800_000_000 + at_s, 0).unwrap();
        let mut t = NowPlaying::new("Zima", Some("a"), Some("p"), playing);
        t.duration = Some(200.0);
        t.elapsed = Some(elapsed);
        t.elapsed_at = Some(at);
        t.rate = Some(if playing { 1.0 } else { 0.0 });
        NowPlayingReading::Item(t)
    }

    #[test]
    fn a_position_that_is_only_the_old_one_moved_on_is_not_news() {
        assert!(!differs(&track(10.0, true, 0), &track(15.0, true, 5)));
        assert!(differs(&track(10.0, true, 0), &track(60.0, true, 5)), "a jump is");
        assert!(differs(&track(10.0, true, 0), &track(15.0, false, 5)), "a pause is");
        assert!(!differs(&NowPlayingReading::Nothing, &NowPlayingReading::Nothing));
        assert!(differs(&NowPlayingReading::Nothing, &track(0.0, true, 0)));
        let _ = Duration::seconds(0);
    }
}
