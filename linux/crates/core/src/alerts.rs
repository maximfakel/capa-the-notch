use crate::loc::{self, AppLanguage};
use crate::pace::CapacityPace;
use crate::snapshot::{CapacitySnapshot, ConnectionState, Provider, QuotaWindow};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// One thing worth interrupting someone for.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CapacityAlert {
    pub provider: Provider,
    pub window_id: String,
    pub title: String,
    pub body: String,
}

#[derive(Debug, Clone, Default)]
struct Spoken {
    was_critical: bool,
    alerted_for_reset_at: Option<DateTime<Utc>>,
    /// An alert was actually sent, not only decided while alerts were off.
    alerted: bool,
}

/// Decides when a Quota Window is worth interrupting someone for, and — far
/// more of the work — when it is not.
///
/// Only a Fresh reading speaks, only the moment a window *becomes* critical
/// speaks, and a window that has already spoken stays quiet until it either
/// recovers or turns over.
#[derive(Debug)]
pub struct CapacityAlertDecider {
    /// The language alerts are worded in; set when the person changes it.
    pub language: AppLanguage,
    history: HashMap<(Provider, String), Spoken>,
    /// Windows the last reading found recovered after an alert was sent about
    /// them: the good news after the bad (ADR 0007).
    pub recovered: Vec<(Provider, String)>,
}

impl Default for CapacityAlertDecider {
    fn default() -> Self {
        Self { language: AppLanguage::English, history: HashMap::new(), recovered: Vec::new() }
    }
}

impl CapacityAlertDecider {
    pub fn new() -> Self {
        Self::default()
    }

    /// `is_enabled` is asked per Provider, so turning one off silences it
    /// immediately.
    pub fn alerts(
        &mut self,
        snapshot: &CapacitySnapshot,
        now: DateTime<Utc>,
        is_enabled: impl Fn(Provider) -> bool,
    ) -> Vec<CapacityAlert> {
        self.recovered.clear();
        if snapshot.connection_state != ConnectionState::Fresh {
            return vec![];
        }

        let mut raised = vec![];
        for window in &snapshot.windows {
            let spoken = self.history.entry((snapshot.provider, window.id.clone())).or_default();

            if window.pace() != CapacityPace::Unsustainable {
                // Recovered. The next fall is news again.
                if spoken.was_critical && spoken.alerted {
                    self.recovered.push((snapshot.provider, window.id.clone()));
                }
                *spoken = Spoken::default();
                continue;
            }

            // A window that has turned over since it last spoke is a new
            // window, whatever its id says.
            let turned_over = match (spoken.alerted_for_reset_at, window.resets_at) {
                (Some(previous), Some(now_resets)) => now_resets > previous,
                _ => false,
            };
            if spoken.was_critical && !turned_over {
                continue;
            }

            spoken.was_critical = true;
            spoken.alerted_for_reset_at = window.resets_at;

            // Asked last, so a silenced Provider still has its history kept:
            // switching alerts back on does not replay what happened.
            if !is_enabled(snapshot.provider) {
                continue;
            }
            spoken.alerted = true;
            raised.push(CapacityAlert {
                provider: snapshot.provider,
                window_id: window.id.clone(),
                title: loc::format_in("%@ is running out", self.language, &[snapshot.provider.spoken_name().into()]),
                body: body(window, now, self.language),
            });
        }
        raised
    }

    /// Forgets everything said, for a Provider disconnected on purpose.
    pub fn forget(&mut self, provider: Provider) {
        self.history.retain(|(p, _), _| *p != provider);
    }
}

fn body(window: &QuotaWindow, now: DateTime<Utc>, language: AppLanguage) -> String {
    let left = loc::format_in(
        "%@: %d%% left",
        language,
        &[loc::window_label_in(&window.label, language).into(), (window.remaining_percentage() as i64).into()],
    );
    match window.resets_at {
        Some(at) => loc::format_in(
            "%@, resets in %@",
            language,
            &[left.into(), loc::reset_countdown_in(at, now, language).into()],
        ),
        None => left,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{Duration, TimeZone};

    fn t0() -> DateTime<Utc> {
        Utc.timestamp_opt(1_700_000_000, 0).unwrap()
    }

    fn snap(used: f64, state: ConnectionState, resets_in: i64, provider: Provider) -> CapacitySnapshot {
        CapacitySnapshot {
            provider,
            captured_at: t0(),
            windows: vec![QuotaWindow::new("five-hour", "5 hour", Some(300), used, Some(t0() + Duration::seconds(resets_in)))],
            connection_state: state,
            status_reason: None,
        }
    }

    fn fresh(used: f64) -> CapacitySnapshot {
        snap(used, ConnectionState::Fresh, 3600, Provider::Codex)
    }

    fn always(_: Provider) -> bool {
        true
    }

    #[test]
    fn a_russian_alert_says_it_all_in_russian() {
        let mut d = CapacityAlertDecider::new();
        d.language = AppLanguage::Russian;
        let raised = d.alerts(&fresh(0.96), t0(), always);
        assert_eq!(raised[0].title, "У Codex заканчиваются лимиты");
        assert!(raised[0].body.contains("осталось 4%"), "{}", raised[0].body);
        assert!(raised[0].body.contains("сброс через"), "{}", raised[0].body);
        assert!(!raised[0].body.contains("hour"), "{}", raised[0].body);
    }

    #[test]
    fn a_window_falling_below_ten_percent_is_worth_saying() {
        let mut d = CapacityAlertDecider::new();
        assert!(d.alerts(&fresh(0.85), t0(), always).is_empty());
        let raised = d.alerts(&fresh(0.96), t0(), always);
        assert_eq!(raised.len(), 1);
        assert!(raised[0].title.contains("Codex"));
        assert!(raised[0].body.contains("4% left"), "{}", raised[0].body);
        assert!(raised[0].body.contains("resets in"));
    }

    #[test]
    fn a_window_says_it_once_and_then_keeps_quiet() {
        let mut d = CapacityAlertDecider::new();
        d.alerts(&fresh(0.96), t0(), always);
        for used in [0.96, 0.97, 0.99, 1.0] {
            assert!(d.alerts(&fresh(used), t0(), always).is_empty(), "{used}");
        }
    }

    #[test]
    fn a_window_that_recovers_is_news_when_it_falls_again() {
        let mut d = CapacityAlertDecider::new();
        d.alerts(&fresh(0.96), t0(), always);
        d.alerts(&fresh(0.40), t0(), always);
        assert_eq!(d.alerts(&fresh(0.98), t0(), always).len(), 1);
    }

    #[test]
    fn a_window_that_turns_over_is_a_new_window() {
        let mut d = CapacityAlertDecider::new();
        let at = |resets_in| snap(0.96, ConnectionState::Fresh, resets_in, Provider::Codex);
        d.alerts(&at(600), t0(), always);
        assert!(d.alerts(&at(600), t0(), always).is_empty());
        assert_eq!(d.alerts(&at(18_600), t0(), always).len(), 1);
    }

    #[test]
    fn only_a_fresh_reading_speaks() {
        use crate::snapshot::CapacityStatusReason::ProviderNotInstalled;
        for state in [ConnectionState::Stale, ConnectionState::Connecting, ConnectionState::Mock, ConnectionState::Disconnected(ProviderNotInstalled)] {
            let mut d = CapacityAlertDecider::new();
            assert!(d.alerts(&snap(0.99, state.clone(), 3600, Provider::Codex), t0(), always).is_empty(), "{state:?}");
        }
    }

    #[test]
    fn a_silenced_provider_is_silent_and_stays_caught_up() {
        let mut d = CapacityAlertDecider::new();
        assert!(d.alerts(&fresh(0.96), t0(), |_| false).is_empty());
        assert!(d.alerts(&fresh(0.97), t0(), always).is_empty(), "no replay once switched on");
        assert!(d.alerts(&fresh(0.40), t0(), always).is_empty());
        assert!(d.recovered.is_empty(), "recovering from a silence is never news");
        assert_eq!(d.alerts(&fresh(0.96), t0(), always).len(), 1);
    }

    #[test]
    fn a_recovery_after_a_sent_alert_is_reported() {
        let mut d = CapacityAlertDecider::new();
        d.alerts(&fresh(0.96), t0(), always);
        d.alerts(&fresh(0.40), t0(), always);
        assert_eq!(d.recovered, vec![(Provider::Codex, "five-hour".to_string())]);
    }

    #[test]
    fn disconnecting_a_provider_forgets_what_was_said() {
        let mut d = CapacityAlertDecider::new();
        d.alerts(&fresh(0.96), t0(), always);
        d.forget(Provider::Codex);
        assert_eq!(d.alerts(&fresh(0.96), t0(), always).len(), 1);

        let claude = || snap(0.96, ConnectionState::Fresh, 3600, Provider::ClaudeCode);
        d.alerts(&claude(), t0(), always);
        d.forget(Provider::Codex);
        assert!(d.alerts(&claude(), t0(), always).is_empty(), "forgetting Codex keeps what Claude Code said");
    }
}
