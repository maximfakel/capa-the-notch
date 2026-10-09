use crate::snapshot::{CapacitySnapshot, QuotaWindow};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

/// How comfortable a window's remaining Capacity is, read off what is left
/// and nothing else. Ordered worst first, so a sort puts the window that
/// needs attention on top.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CapacityPace {
    Unsustainable,
    Tightening,
    Sustainable,
}

pub const SUSTAINABLE_PERCENTAGE: f64 = 60.0;
pub const TIGHTENING_PERCENTAGE: f64 = 10.0;
/// A boundary belongs to the better state, and binary fractions do not land
/// on it exactly: 90% used leaves 0.09999999999999998.
pub const TOLERANCE: f64 = 1e-9;

impl QuotaWindow {
    /// Share of the allowance still unspent, from 0 to 1.
    pub fn remaining_fraction(&self) -> f64 {
        (1.0 - self.used_fraction).clamp(0.0, 1.0)
    }

    pub fn pace(&self) -> CapacityPace {
        if self.remaining_fraction() <= 0.0 {
            return CapacityPace::Unsustainable;
        }
        let remaining = self.remaining_percentage();
        if remaining >= SUSTAINABLE_PERCENTAGE - TOLERANCE {
            CapacityPace::Sustainable
        } else if remaining >= TIGHTENING_PERCENTAGE - TOLERANCE {
            CapacityPace::Tightening
        } else {
            CapacityPace::Unsustainable
        }
    }
}

impl CapacitySnapshot {
    /// The window that represents this Provider in the compact strip: the one
    /// with the least left, an earlier reset breaking a tie.
    pub fn headline_window(&self) -> Option<&QuotaWindow> {
        self.windows.iter().min_by(|l, r| {
            l.remaining_percentage()
                .partial_cmp(&r.remaining_percentage())
                .unwrap_or(std::cmp::Ordering::Equal)
                .then_with(|| {
                    let far = DateTime::<Utc>::MAX_UTC;
                    l.resets_at.unwrap_or(far).cmp(&r.resets_at.unwrap_or(far))
                })
        })
    }
}

/// How long until a window turns over, in the fewest words that stay honest.
pub fn reset_countdown(resets_at: DateTime<Utc>, now: DateTime<Utc>) -> String {
    let remaining = (resets_at - now).num_milliseconds() as f64 / 1000.0;
    let remaining = remaining.round() as i64;
    if remaining <= 0 {
        return "moments".into();
    }
    let hours = remaining / 3600;
    let minutes = (remaining % 3600) / 60;

    if hours >= 24 {
        let (days, spare) = (hours / 24, hours % 24);
        return if spare > 0 { format!("{days}d {spare}h") } else { format!("{days}d") };
    }
    if hours > 0 {
        return if minutes > 0 { format!("{hours}h {minutes}m") } else { format!("{hours}h") };
    }
    if remaining >= 60 { format!("{minutes}m") } else { "under a minute".into() }
}

/// What a gauge writes in its gap: the time of day the window comes back
/// while that is within a day, how long until it once it is further off, and
/// nothing known when the Provider did not say.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GaugeReset {
    At(DateTime<Utc>),
    In(String),
    Unknown,
}

impl GaugeReset {
    pub fn new(resets_at: Option<DateTime<Utc>>, now: DateTime<Utc>) -> Self {
        let Some(resets_at) = resets_at else { return Self::Unknown };
        let remaining = (resets_at - now).num_milliseconds() as f64 / 1000.0;
        if remaining > 0.0 && remaining < 24.0 * 3600.0 {
            Self::At(resets_at)
        } else {
            Self::In(reset_countdown(resets_at, now))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::snapshot::{ConnectionState, Provider};
    use chrono::{Duration, TimeZone};

    fn now() -> DateTime<Utc> {
        Utc.timestamp_opt(1_000_000, 0).unwrap()
    }

    fn window(id: &str, used: f64, resets_in: Option<i64>) -> QuotaWindow {
        QuotaWindow::new(id, "5 hour", Some(300), used, resets_in.map(|s| now() + Duration::seconds(s)))
    }

    #[test]
    fn the_state_is_read_off_what_is_left() {
        let pace = |used| window("w", used, Some(3600)).pace();
        assert_eq!(pace(0.0), CapacityPace::Sustainable);
        assert_eq!(pace(0.24), CapacityPace::Sustainable);
        assert_eq!(pace(0.31), CapacityPace::Sustainable);
        assert_eq!(pace(0.40), CapacityPace::Sustainable, "60% belongs to the better state");
        assert_eq!(pace(0.46), CapacityPace::Tightening);
        assert_eq!(pace(0.89), CapacityPace::Tightening);
        assert_eq!(pace(0.90), CapacityPace::Tightening, "10% belongs to the better state");
        assert_eq!(pace(0.96), CapacityPace::Unsustainable);
        assert_eq!(pace(1.0), CapacityPace::Unsustainable);
    }

    #[test]
    fn the_clock_does_not_change_the_colour() {
        let nearly = window("w", 0.89, Some(2 * 3600));
        let far = window("w", 0.89, Some(6 * 24 * 3600));
        assert_eq!(nearly.pace(), far.pace());
        assert_eq!(window("w", 0.89, None).pace(), CapacityPace::Tightening);
    }

    #[test]
    fn the_headline_is_the_scarcest_window() {
        let snap = |windows| CapacitySnapshot {
            provider: Provider::Codex,
            captured_at: now(),
            windows,
            connection_state: ConnectionState::Fresh,
            status_reason: None,
        };
        let s = snap(vec![window("five-hour", 0.70, Some(240 * 60)), window("weekly", 0.89, Some(20 * 60))]);
        assert_eq!(s.headline_window().unwrap().id, "weekly");

        let tie = snap(vec![window("late", 0.5, Some(7200)), window("early", 0.5, Some(60))]);
        assert_eq!(tie.headline_window().unwrap().id, "early", "an earlier reset breaks a tie");
        assert!(snap(vec![]).headline_window().is_none());
    }

    #[test]
    fn countdown_uses_the_fewest_words() {
        let t = |s: i64| reset_countdown(now() + Duration::seconds(s), now());
        assert_eq!(t(-5), "moments");
        assert_eq!(t(30), "under a minute");
        assert_eq!(t(5 * 60), "5m");
        assert_eq!(t(3600), "1h");
        assert_eq!(t(3600 + 25 * 60), "1h 25m");
        assert_eq!(t(24 * 3600), "1d");
        assert_eq!(t(50 * 3600), "2d 2h");
    }

    #[test]
    fn a_gauge_gives_a_time_of_day_within_a_day_and_a_countdown_beyond() {
        let g = |s: i64| GaugeReset::new(Some(now() + Duration::seconds(s)), now());
        assert_eq!(g(3600), GaugeReset::At(now() + Duration::seconds(3600)));
        assert_eq!(g(25 * 3600), GaugeReset::In("1d 1h".into()));
        assert_eq!(GaugeReset::new(None, now()), GaugeReset::Unknown);
    }
}
