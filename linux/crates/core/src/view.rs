//! What a surface needs to draw, with every decision already made: the pace,
//! the headline, the countdown, the words. A surface — the GNOME extension —
//! draws this and decides nothing, so no two views can disagree about what a
//! window means.

use crate::loc::{self, AppLanguage};
use crate::pace::{CapacityPace, GaugeReset};
use crate::snapshot::{CapacitySnapshot, ConnectionState, Provider};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WindowView {
    pub id: String,
    pub label: String,
    pub duration_minutes: Option<i64>,
    pub remaining_percentage: f64,
    pub remaining_fraction: f64,
    /// The percentage used, as the Swift card writes it: `Int((usedFraction * 100).rounded())`.
    pub used_percentage: i64,
    pub pace: CapacityPace,
    /// Unix seconds; `None` when the Provider did not say.
    pub resets_at: Option<i64>,
    /// `at` (show the time of day), `in` (show `reset_in`), or `unknown`.
    pub reset_kind: ResetKind,
    pub reset_in: Option<String>,
    /// What a screen reader says about the window (`CapacitySpeech.window`);
    /// filled by `ProviderView::with_speech`, left out until then.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub spoken: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ResetKind {
    At,
    In,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum StateKind {
    Mock,
    Connecting,
    Fresh,
    Stale,
    Disconnected,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderView {
    pub provider: Provider,
    pub name: String,
    pub state: StateKind,
    /// What the status reason says: the one thing that would fix it, or — on
    /// a fresh reading — a note such as a used-up month. Not drawn when the
    /// reason `repeats_the_chip`.
    pub guidance: Option<String>,
    /// Whether the chip already carries the reason, so no sentence repeats it.
    pub reason_repeats_the_chip: bool,
    pub needs_a_person_first: bool,
    /// OpenCode's month is used up: work is refused however green the windows are.
    pub month_used_up: Option<MonthUsedUp>,
    /// Turned off on purpose, as against unreadable.
    pub switched_off: bool,
    pub captured_at: i64,
    pub headline: Option<String>,
    pub windows: Vec<WindowView>,
    /// What a screen reader says about the card (`CapacitySpeech.provider`);
    /// filled by `with_speech`, left out until then.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub spoken: String,
}

/// One side of the closed strip: a Provider's mark beside a figure and its pace.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StripSideView {
    pub provider: Provider,
    /// `76%`, or a dash while there is nothing to say.
    pub figure: String,
    pub pace: Option<CapacityPace>,
    /// What a screen reader says about this side (`CapacitySpeech.compact` / `compactWindow`).
    pub spoken: String,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct StripView {
    pub left: Option<StripSideView>,
    pub right: Option<StripSideView>,
}

impl StripView {
    /// What the closed strip shows either side of the notch (`CompactStrip`).
    /// Its spoken words are in the language in force (`loc::current`).
    pub fn of(snapshots: &[CapacitySnapshot], choice: crate::surface::CompactWindowChoice) -> Self {
        use crate::surface::{CompactStrip, Side};
        let side = |side: Side| match side {
            Side::Provider { snapshot } => {
                let headline = snapshot.headline_window();
                StripSideView {
                    provider: snapshot.provider,
                    figure: headline.map_or_else(|| "—".to_owned(), |w| format!("{}%", w.remaining_percentage() as i64)),
                    pace: headline.map(|w| w.pace()),
                    spoken: crate::speech::compact(&snapshot, Utc::now()),
                }
            }
            Side::Window { provider, window } => StripSideView {
                provider,
                figure: format!("{}%", window.remaining_percentage() as i64),
                pace: Some(window.pace()),
                spoken: crate::speech::compact_window(provider, &window),
            },
        };
        let sides = CompactStrip::sides(snapshots, choice);
        Self { left: sides.left.map(side), right: sides.right.map(side) }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MonthUsedUp {
    /// Unix seconds, when it is known.
    pub until: Option<i64>,
}

impl ProviderView {
    /// The view in English.
    pub fn new(snapshot: &CapacitySnapshot, now: DateTime<Utc>) -> Self {
        Self::localized(snapshot, now, AppLanguage::English)
    }

    /// The view with every word said in `language`: the guidance, the window
    /// labels and the countdowns.
    pub fn localized(snapshot: &CapacitySnapshot, now: DateTime<Utc>, language: AppLanguage) -> Self {
        let reason = snapshot.status_reason.as_ref();
        let state = match &snapshot.connection_state {
            ConnectionState::Mock => StateKind::Mock,
            ConnectionState::Connecting => StateKind::Connecting,
            ConnectionState::Fresh => StateKind::Fresh,
            ConnectionState::Stale => StateKind::Stale,
            ConnectionState::Disconnected(_) => StateKind::Disconnected,
        };
        Self {
            provider: snapshot.provider,
            name: snapshot.provider.spoken_name().into(),
            state,
            guidance: reason.map(|r| loc::localized_guidance_in(r, language)),
            reason_repeats_the_chip: reason.is_some_and(|r| r.repeats_the_chip()),
            needs_a_person_first: reason.is_some_and(|r| r.needs_a_person_first()),
            month_used_up: match reason {
                Some(crate::snapshot::CapacityStatusReason::OpenCodeMonthlyLimitReached(until)) => {
                    Some(MonthUsedUp { until: until.map(|d| d.timestamp()) })
                }
                _ => None,
            },
            // This Provider's own reason, not any Provider's.
            switched_off: snapshot.is_switched_off(),
            captured_at: snapshot.captured_at.timestamp(),
            headline: snapshot.headline_window().map(|w| w.id.clone()),
            windows: snapshot
                .windows
                .iter()
                .map(|w| {
                    let gauge = GaugeReset::new(w.resets_at, now);
                    WindowView {
                        id: w.id.clone(),
                        label: loc::window_label_in(&w.label, language),
                        duration_minutes: w.duration_minutes,
                        remaining_percentage: w.remaining_percentage(),
                        remaining_fraction: w.remaining_fraction(),
                        used_percentage: (w.used_fraction * 100.0).round() as i64,
                        pace: w.pace(),
                        resets_at: w.resets_at.map(|d| d.timestamp()),
                        reset_kind: match gauge {
                            GaugeReset::At(_) => ResetKind::At,
                            GaugeReset::In(_) => ResetKind::In,
                            GaugeReset::Unknown => ResetKind::Unknown,
                        },
                        reset_in: w.resets_at.map(|at| loc::reset_countdown_in(at, now, language)),
                        spoken: String::new(),
                    }
                })
                .collect(),
            spoken: String::new(),
        }
    }

    /// The view with what a screen reader says about the card and each window
    /// (`CapacitySpeech`), in the language in force (`loc::current`) and the
    /// person's own clock — which is why it is a step of its own: a view made
    /// for a test or a fixture stays the same wherever it is made.
    pub fn with_speech(mut self, snapshot: &CapacitySnapshot, now: DateTime<Utc>) -> Self {
        self.spoken = crate::speech::provider(snapshot, now);
        for (view, window) in self.windows.iter_mut().zip(&snapshot.windows) {
            view.spoken = crate::speech::window(window, now);
        }
        self
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::snapshot::{CapacityStatusReason, QuotaWindow};
    use chrono::{Duration, TimeZone};

    fn now() -> DateTime<Utc> {
        Utc.timestamp_opt(1_700_000_000, 0).unwrap()
    }

    #[test]
    fn the_strip_names_a_figure_and_a_pace_for_each_side() {
        use crate::surface::CompactWindowChoice;
        let snap = |provider, five, week| CapacitySnapshot {
            provider,
            captured_at: now(),
            windows: vec![
                QuotaWindow::new("a", "5 hour", Some(300), five, None),
                QuotaWindow::new("b", "Weekly", Some(10_080), week, None),
            ],
            connection_state: ConnectionState::Fresh,
            status_reason: None,
        };
        let both = [snap(Provider::Codex, 0.24, 0.89), snap(Provider::ClaudeCode, 0.5, 0.1)];
        let strip = StripView::of(&both, CompactWindowChoice::FiveHour);
        assert_eq!(strip.left.as_ref().unwrap().figure, "76%");
        assert_eq!(strip.right.as_ref().unwrap().figure, "50%");
        assert_eq!(strip.left.unwrap().pace, Some(CapacityPace::Sustainable));
        let weekly = StripView::of(&both, CompactWindowChoice::Weekly);
        assert_eq!(weekly.left.unwrap().figure, "11%");
        // One on: its shortest left, its longest right.
        let one = StripView::of(&both[..1], CompactWindowChoice::FiveHour);
        assert_eq!((one.left.unwrap().figure.as_str(), one.right.unwrap().figure.as_str()), ("76%", "11%"));
    }

    #[test]
    fn a_view_carries_the_decisions_made() {
        let s = CapacitySnapshot {
            provider: Provider::Codex,
            captured_at: now(),
            windows: vec![
                QuotaWindow::new("a", "5 hour", Some(300), 0.96, Some(now() + Duration::minutes(90))),
                QuotaWindow::new("b", "Weekly", Some(10_080), 0.2, Some(now() + Duration::days(3))),
            ],
            connection_state: ConnectionState::Fresh,
            status_reason: None,
        };
        let v = ProviderView::new(&s, now());
        assert_eq!(v.headline.as_deref(), Some("a"));
        assert_eq!(v.windows[0].pace, CapacityPace::Unsustainable);
        assert_eq!(v.windows[0].reset_kind, ResetKind::At);
        assert_eq!(v.windows[0].reset_in.as_deref(), Some("1h 30m"));
        assert_eq!(v.windows[1].reset_kind, ResetKind::In);
        assert_eq!(v.windows[1].reset_in.as_deref(), Some("3d"));
        assert_eq!(v.guidance, None);
        assert!(!v.switched_off);
    }

    #[test]
    fn a_switched_off_provider_is_told_from_an_unreadable_one() {
        let off = CapacitySnapshot::disconnected(Provider::Codex, now(), CapacityStatusReason::CodexDisconnected);
        let broken = CapacitySnapshot::disconnected(Provider::Codex, now(), CapacityStatusReason::ProviderNotInstalled);
        assert!(ProviderView::new(&off, now()).switched_off);
        let b = ProviderView::new(&broken, now());
        assert!(!b.switched_off);
        assert!(b.needs_a_person_first);
        assert_eq!(b.guidance.as_deref(), Some("Install the Codex CLI, then try again."));
    }

    #[test]
    fn a_used_up_month_on_a_fresh_reading_is_a_note_the_chip_carries() {
        let s = CapacitySnapshot {
            provider: Provider::OpenCode,
            captured_at: now(),
            windows: vec![QuotaWindow::new("a", "5 hour", Some(300), 0.1, None)],
            connection_state: ConnectionState::Fresh,
            status_reason: Some(CapacityStatusReason::OpenCodeMonthlyLimitReached(None)),
        };
        let v = ProviderView::new(&s, now());
        assert_eq!(v.state, StateKind::Fresh);
        assert_eq!(v.month_used_up, Some(MonthUsedUp { until: None }));
        assert_eq!(v.guidance.as_deref(), Some("Monthly limit reached"));
        assert!(v.reason_repeats_the_chip);
    }

    #[test]
    fn another_providers_switched_off_reason_is_not_switched_off() {
        let odd = CapacitySnapshot::disconnected(Provider::Codex, now(), CapacityStatusReason::ClaudeDisconnected);
        assert!(!ProviderView::new(&odd, now()).switched_off);
    }

    #[test]
    fn the_view_carries_the_percentage_used_and_what_is_spoken() {
        crate::loc::with_language(AppLanguage::English, || {
            let s = CapacitySnapshot {
                provider: Provider::Codex,
                captured_at: now(),
                windows: vec![QuotaWindow::new("a", "5 hour", Some(300), 0.246, None)],
                connection_state: ConnectionState::Fresh,
                status_reason: None,
            };
            let v = ProviderView::new(&s, now());
            assert_eq!(v.spoken, "", "no speech until asked for");
            let v = v.with_speech(&s, now());
            assert_eq!(v.windows[0].used_percentage, 25, "rounded, as Swift's rounded()");
            assert!(v.windows[0].spoken.starts_with("5 hour window, "), "{}", v.windows[0].spoken);
            assert!(v.spoken.starts_with("Codex. Fresh Capacity. 5 hour window"), "{}", v.spoken);
            let strip = StripView::of(&[s], crate::surface::CompactWindowChoice::FiveHour);
            assert!(strip.left.unwrap().spoken.starts_with("Codex, 5 hour window"));
        });
    }

    #[test]
    fn stale_capacity_says_why() {
        let s = CapacitySnapshot {
            provider: Provider::Codex,
            captured_at: now(),
            windows: vec![QuotaWindow::new("a", "5 hour", Some(300), 0.1, None)],
            connection_state: ConnectionState::Stale,
            status_reason: Some(CapacityStatusReason::StaleFromArchive),
        };
        let v = ProviderView::new(&s, now());
        assert_eq!(v.state, StateKind::Stale);
        assert!(v.guidance.unwrap().contains("Refreshing"));
    }
}
