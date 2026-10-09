//! Port of `CapacitySpeech.swift`: what a screen reader says about the surface.
//!
//! Kept out of the views so the wording can be read, argued with, and tested
//! without rendering anything.
//!
//! The surface writes no word for the state, and needs none. Capacity Pace is
//! read off the remainder and nothing else, so the colour restates the figure
//! already on the row — what carries the meaning without colour is the
//! figure itself. The words below are for a screen reader.

use crate::loc::{self, format, text};
use crate::pace::CapacityPace;
use crate::snapshot::{CapacitySnapshot, ConnectionState, Provider, QuotaWindow};
use chrono::{DateTime, Local, Utc};

impl CapacityPace {
    /// The state said in words, for a screen reader and for anyone who cannot
    /// tell the three colours apart.
    pub fn spoken(self) -> String {
        match self {
            CapacityPace::Sustainable => text("on pace"),
            CapacityPace::Tightening => text("tightening"),
            CapacityPace::Unsustainable => text("running out"),
        }
    }
}

impl ConnectionState {
    pub fn spoken(&self) -> String {
        match self {
            ConnectionState::Mock => text("mock Capacity"),
            ConnectionState::Connecting => text("connecting"),
            ConnectionState::Fresh => text("Fresh Capacity"),
            ConnectionState::Stale => text("Stale Capacity"),
            ConnectionState::Disconnected(_) => text("disconnected"),
        }
    }
}

/// The time of day in the person's own clock, short: "2:30 PM" for English,
/// "14:30" for Russian.
pub fn local_clock(at: DateTime<Utc>) -> String {
    let local = at.with_timezone(&Local);
    match loc::current() {
        loc::AppLanguage::Russian => local.format("%H:%M").to_string(),
        _ => local.format("%-I:%M %p").to_string(),
    }
}

/// One Quota Window: which window, what is left, how it is going, how much has
/// gone, and when it turns over.
pub fn window(window: &QuotaWindow, now: DateTime<Utc>) -> String {
    window_with_clock(window, now, &local_clock)
}

pub fn window_with_clock(window: &QuotaWindow, now: DateTime<Utc>, clock: &dyn Fn(DateTime<Utc>) -> String) -> String {
    let mut parts = vec![
        format("%@ window", &[loc::window_label(&window.label).into()]),
        format("%d percent left", &[(window.remaining_percentage() as i64).into()]),
        window.pace().spoken(),
        format("%d percent used", &[((window.used_fraction * 100.0).round() as i64).into()]),
    ];
    match window.resets_at {
        Some(resets_at) => parts.push(format(
            "resets in %@, at %@",
            &[loc::reset_countdown(resets_at, now).into(), clock(resets_at).into()],
        )),
        None => parts.push(text("reset time not reported")),
    }
    parts.join(", ")
}

/// One Provider: who it is, how its reading stands, and either its windows or
/// the one thing that would fix it.
pub fn provider(snapshot: &CapacitySnapshot, now: DateTime<Utc>) -> String {
    provider_with_clock(snapshot, now, &local_clock)
}

pub fn provider_with_clock(snapshot: &CapacitySnapshot, now: DateTime<Utc>, clock: &dyn Fn(DateTime<Utc>) -> String) -> String {
    let mut parts = vec![snapshot.provider.spoken_name().to_owned(), snapshot.connection_state.spoken()];
    if let Some(reason) = &snapshot.status_reason {
        if snapshot.connection_state != ConnectionState::Fresh {
            parts.push(loc::localized_guidance(reason));
        }
    }
    parts.extend(snapshot.windows.iter().map(|w| window_with_clock(w, now, clock)));
    parts.join(". ")
}

/// The closed strip's figure for one Provider.
pub fn compact(snapshot: &CapacitySnapshot, _now: DateTime<Utc>) -> String {
    let Some(headline) = snapshot.headline_window() else {
        let reason = snapshot
            .status_reason
            .as_ref()
            .map(loc::localized_guidance)
            .unwrap_or_else(|| text("no Capacity read"));
        return format!("{}, {reason}", snapshot.provider.spoken_name());
    };
    compact_window(snapshot.provider, headline)
}

/// One window of the only Provider on, as the strip shows it.
pub fn compact_window(provider: Provider, window: &QuotaWindow) -> String {
    [
        provider.spoken_name().to_owned(),
        format("%@ window", &[loc::window_label(&window.label).into()]),
        format("%d percent left", &[(window.remaining_percentage() as i64).into()]),
        window.pace().spoken(),
    ]
    .join(", ")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::loc::{with_language, AppLanguage};
    use crate::snapshot::CapacityStatusReason;
    use chrono::{Duration, TimeZone};

    fn spoken_at() -> DateTime<Utc> {
        Utc.timestamp_opt(1_700_000_000, 0).unwrap()
    }

    /// UTC, so the test does not depend on where it runs.
    fn utc_clock(at: DateTime<Utc>) -> String {
        at.format("%H:%M").to_string()
    }

    fn five_hour() -> QuotaWindow {
        QuotaWindow::new("codex-primary", "5 hour", Some(300), 0.96, Some(spoken_at() + Duration::seconds(2160)))
    }

    fn english<R>(body: impl FnOnce() -> R) -> R {
        with_language(AppLanguage::English, body)
    }

    #[test]
    fn a_window_says_everything_the_card_shows() {
        english(|| {
            let said = window_with_clock(&five_hour(), spoken_at(), &utc_clock);
            for expected in ["5 hour window", "4 percent left", "running out", "96 percent used", "resets in 36m"] {
                assert!(said.contains(expected), "It should say \"{expected}\", said: {said}");
            }
        });
    }

    #[test]
    fn a_window_with_no_reset_says_so_rather_than_inventing_one() {
        english(|| {
            let unknown = QuotaWindow::new("w", "Weekly", None, 0.2, None);
            let said = window(&unknown, spoken_at());
            assert!(said.contains("reset time not reported"), "An unknown reset is said aloud, not skipped, said: {said}");
        });
    }

    #[test]
    fn a_provider_says_who_it_is_and_how_its_reading_stands() {
        english(|| {
            let fresh = CapacitySnapshot {
                provider: Provider::Codex,
                captured_at: spoken_at(),
                windows: vec![five_hour()],
                connection_state: ConnectionState::Fresh,
                status_reason: None,
            };
            let said = provider_with_clock(&fresh, spoken_at(), &utc_clock);
            assert!(said.starts_with("Codex. Fresh Capacity"), "It leads with who and how, said: {said}");
            assert!(said.contains("5 hour window"), "And then the windows");
        });
    }

    #[test]
    fn an_unreadable_provider_says_the_one_thing_that_would_fix_it() {
        english(|| {
            let stuck = CapacitySnapshot::disconnected(Provider::Codex, spoken_at(), CapacityStatusReason::ProviderNotInstalled);
            let said = provider(&stuck, spoken_at());
            assert!(said.contains("disconnected"), "It says the state, said: {said}");
            assert!(said.contains("Install the Codex CLI"), "And the action, because a state with no action is no help, said: {said}");
        });
    }

    #[test]
    fn the_closed_strip_says_the_window_it_is_showing() {
        english(|| {
            let snapshot = CapacitySnapshot {
                provider: Provider::ClaudeCode,
                captured_at: spoken_at(),
                windows: vec![
                    five_hour(),
                    QuotaWindow::new("w", "Weekly", Some(10_080), 0.1, Some(spoken_at() + Duration::seconds(86_400))),
                ],
                connection_state: ConnectionState::Fresh,
                status_reason: None,
            };
            assert_eq!(
                compact(&snapshot, spoken_at()),
                "Claude Code, 5 hour window, 4 percent left, running out",
                "The strip names which window its figure belongs to"
            );
        });
    }

    #[test]
    fn the_states_are_tellable_apart_without_colour() {
        english(|| {
            assert_ne!(CapacityPace::Sustainable.spoken(), CapacityPace::Tightening.spoken(), "Each state has its own words");
            // What tells the states apart on screen is the figure, not the
            // colour and not a word: Capacity Pace is read off the remainder.
            let scarce = QuotaWindow::new("a", "5 hour", Some(300), 0.96, None);
            let ample = QuotaWindow::new("b", "5 hour", Some(300), 0.31, None);
            assert_ne!(scarce.pace(), ample.pace(), "Two states");
            assert_ne!(scarce.remaining_percentage(), ample.remaining_percentage(), "And two figures, the distinction a colourblind reader makes");
            assert_ne!(ConnectionState::Stale.spoken(), ConnectionState::Fresh.spoken(), "And so does each connection state");
        });
    }

    #[test]
    fn a_provider_with_nothing_read_says_why_in_the_strip() {
        english(|| {
            let none = CapacitySnapshot::disconnected(Provider::OpenCode, spoken_at(), CapacityStatusReason::OpenCodeNotSignedIn);
            assert_eq!(compact(&none, spoken_at()), "OpenCode, Sign in to OpenCode with `opencode auth login`, then try again.");
            let silent = CapacitySnapshot { status_reason: None, ..none };
            assert_eq!(compact(&silent, spoken_at()), "OpenCode, no Capacity read");
        });
    }

    #[test]
    fn a_russian_reader_hears_russian_windows_and_countdowns() {
        with_language(AppLanguage::Russian, || {
            let said = window_with_clock(&five_hour(), spoken_at(), &utc_clock);
            assert!(said.starts_with("окно 5 ч, осталось 4%"), "{said}");
            assert!(said.contains("36 мин"), "{said}");
        });
    }
}
