use super::unread::ordered_snapshots;
use crate::loc;
use crate::snapshot::{CapacitySnapshot, Provider, QuotaWindow};
use serde::{Deserialize, Serialize};

/// Which window each Provider shows in the closed strip while both are on.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CompactWindowChoice {
    #[default]
    FiveHour,
    Weekly,
    LeastLeft,
}

impl CompactWindowChoice {
    pub const ALL: [CompactWindowChoice; 3] = [Self::FiveHour, Self::Weekly, Self::LeastLeft];

    /// The words in Settings, as drawn.
    pub fn title(self) -> String {
        match self {
            Self::FiveHour => loc::text("Five-hour"),
            Self::Weekly => loc::text("Weekly"),
            Self::LeastLeft => loc::text("Least left"),
        }
    }
}

/// One side of the closed strip.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Side {
    /// A Provider's Headline Window, or a dash while it has none.
    Provider { snapshot: CapacitySnapshot },
    /// One window of the only Provider on.
    Window { provider: Provider, window: QuotaWindow },
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Sides {
    pub left: Option<Side>,
    pub right: Option<Side>,
}

/// What the closed strip shows either side of the notch.
///
/// Two Providers on: each the window chosen in Settings — its five hours
/// unless asked otherwise — the first in order left and the second right. One
/// on: that Provider alone, its shortest window left and its longest right
/// ("5 ч" and "Неделя"). None on: nothing, as the surface is open anyway.
pub struct CompactStrip;

impl CompactStrip {
    pub fn sides(snapshots: &[CapacitySnapshot], showing: CompactWindowChoice) -> Sides {
        let on = ordered_snapshots(&snapshots.iter().filter(|s| !s.is_switched_off()).cloned().collect::<Vec<_>>());
        let [only] = on.as_slice() else {
            if on.is_empty() {
                return Sides::default();
            }
            return Sides { left: chosen(on.first(), showing), right: chosen(on.get(1), showing) };
        };

        let windows = by_duration(&only.windows);
        let Some(shortest) = windows.first() else {
            // Nothing read yet: a dash on the left, where its five hours will
            // stand once read.
            return Sides { left: Some(Side::Provider { snapshot: only.clone() }), right: None };
        };
        let longest = windows.last().filter(|_| windows.len() > 1);
        let window = |w: &QuotaWindow| Side::Window { provider: only.provider, window: w.clone() };
        Sides { left: Some(window(shortest)), right: longest.map(window) }
    }
}

fn chosen(snapshot: Option<&CapacitySnapshot>, choice: CompactWindowChoice) -> Option<Side> {
    let snapshot = snapshot?;
    let windows = by_duration(&snapshot.windows);
    // The window of that length, and only without one the nearest end: a
    // Provider's shortest is not always five hours.
    let window = match choice {
        CompactWindowChoice::FiveHour => windows.iter().find(|w| w.duration_minutes == Some(5 * 60)).or(windows.first()).cloned(),
        CompactWindowChoice::Weekly => windows.iter().find(|w| w.duration_minutes == Some(7 * 24 * 60)).or(windows.last()).cloned(),
        CompactWindowChoice::LeastLeft => snapshot.headline_window().cloned(),
    };
    Some(match window {
        Some(window) => Side::Window { provider: snapshot.provider, window },
        None => Side::Provider { snapshot: snapshot.clone() },
    })
}

/// Shortest first; a window with no length is the longest.
fn by_duration(windows: &[QuotaWindow]) -> Vec<QuotaWindow> {
    let mut sorted = windows.to_vec();
    sorted.sort_by_key(|w| w.duration_minutes.unwrap_or(i64::MAX));
    sorted
}

#[cfg(test)]
mod tests {
    use super::super::unread::{SurfaceCards, UnreadCapacity};
    use super::*;
    use crate::snapshot::ConnectionState;
    use crate::selection;
    use chrono::{DateTime, TimeZone, Utc};

    fn read_at() -> DateTime<Utc> {
        Utc.timestamp_opt(1_700_000_000, 0).unwrap()
    }

    fn window(id: &str, label: &str, minutes: i64, used: f64) -> QuotaWindow {
        QuotaWindow::new(id, label, Some(minutes), used, Some(read_at()))
    }

    fn reading(provider: Provider) -> CapacitySnapshot {
        CapacitySnapshot {
            provider,
            captured_at: read_at(),
            windows: vec![window("week", "Weekly", 10_080, 0.89), window("five", "5 hour", 300, 0.24)],
            connection_state: ConnectionState::Fresh,
            status_reason: None,
        }
    }

    fn id_of(side: &Option<Side>) -> Option<(Provider, String)> {
        match side {
            Some(Side::Window { provider, window }) => Some((*provider, window.id.clone())),
            _ => None,
        }
    }

    #[test]
    fn the_strip_shows_the_only_providers_short_window_left_and_long_right() {
        let sides = CompactStrip::sides(&[UnreadCapacity::snapshot(Provider::Codex, read_at()), reading(Provider::ClaudeCode)], CompactWindowChoice::FiveHour);
        assert_eq!(id_of(&sides.left), Some((Provider::ClaudeCode, "five".into())), "Five hours left");
        assert_eq!(id_of(&sides.right), Some((Provider::ClaudeCode, "week".into())), "the week right, both the Provider that is on");
    }

    #[test]
    fn the_strip_shows_each_providers_five_hours_when_both_are_on() {
        let sides = CompactStrip::sides(&[reading(Provider::Codex), reading(Provider::ClaudeCode)], CompactWindowChoice::FiveHour);
        // The week has less left here, and still the five hours are shown.
        assert_eq!(id_of(&sides.left), Some((Provider::Codex, "five".into())));
        assert_eq!(id_of(&sides.right), Some((Provider::ClaudeCode, "five".into())));
        let unread = CapacitySnapshot { provider: Provider::Codex, captured_at: read_at(), windows: vec![], connection_state: ConnectionState::Connecting, status_reason: None };
        let sides = CompactStrip::sides(&[unread, reading(Provider::ClaudeCode)], CompactWindowChoice::FiveHour);
        assert!(matches!(sides.left, Some(Side::Provider { .. })), "A Provider not read yet keeps its dash");
    }

    #[test]
    fn nothing_connected_leaves_the_strip_empty() {
        let off = UnreadCapacity::snapshots(read_at());
        let sides = CompactStrip::sides(&off, CompactWindowChoice::FiveHour);
        assert!(sides.left.is_none() && sides.right.is_none(), "Nothing on, nothing in the strip");
        assert!(SurfaceCards::nothing_connected(&off), "Nothing on is nothing connected");
        assert!(!SurfaceCards::nothing_connected(&[UnreadCapacity::snapshot(Provider::Codex, read_at()), reading(Provider::ClaudeCode)]), "One on is not");
    }

    #[test]
    fn the_strip_shows_the_window_chosen_in_settings() {
        let both = [reading(Provider::Codex), reading(Provider::ClaudeCode)];
        let ids = |choice| {
            let sides = CompactStrip::sides(&both, choice);
            [sides.left, sides.right].iter().filter_map(|s| id_of(s).map(|(_, id)| id)).collect::<Vec<_>>()
        };
        assert_eq!(ids(CompactWindowChoice::FiveHour), ["five", "five"], "Five hours by default");
        assert_eq!(ids(CompactWindowChoice::Weekly), ["week", "week"], "The week when asked");
        // Weekly has 11% left against five hours' 76%.
        assert_eq!(ids(CompactWindowChoice::LeastLeft), ["week", "week"], "The one with least left when asked");
        assert_eq!(CompactWindowChoice::default(), CompactWindowChoice::FiveHour, "Five hours until chosen");
    }

    #[test]
    fn the_chosen_window_is_the_one_of_that_length_not_the_shortest_or_longest() {
        // A Provider with an hour, five hours, a week and a month.
        let many = CapacitySnapshot {
            provider: Provider::Codex,
            captured_at: read_at(),
            windows: vec![window("month", "Monthly", 43_200, 0.1), window("hour", "1 hour", 60, 0.1), window("week", "Weekly", 10_080, 0.1), window("five", "5 hour", 300, 0.1)],
            connection_state: ConnectionState::Fresh,
            status_reason: None,
        };
        let left = |snapshot: &CapacitySnapshot, choice| id_of(&CompactStrip::sides(&[snapshot.clone(), reading(Provider::ClaudeCode)], choice).left).map(|(_, id)| id);
        assert_eq!(left(&many, CompactWindowChoice::FiveHour).as_deref(), Some("five"), "Five hours is the five-hour window, not the hour");
        assert_eq!(left(&many, CompactWindowChoice::Weekly).as_deref(), Some("week"), "The week is the weekly window, not the month");
        // Without a window of that length, the nearest end stands in.
        let other = CapacitySnapshot { windows: vec![window("day", "Daily", 1_440, 0.1), window("month", "Monthly", 43_200, 0.1)], ..many };
        assert_eq!(left(&other, CompactWindowChoice::FiveHour).as_deref(), Some("day"), "No five hours: the shortest");
        assert_eq!(left(&other, CompactWindowChoice::Weekly).as_deref(), Some("month"), "No week: the longest");
    }

    /// Providers stand in one order everywhere — Codex, Claude Code, then any
    /// later one — whatever order their readings arrive in, so each keeps its
    /// side of the strip and its place among the cards.
    #[test]
    fn providers_stand_in_one_order_whatever_order_they_arrive() {
        let sides = CompactStrip::sides(&[reading(Provider::ClaudeCode), reading(Provider::Codex)], CompactWindowChoice::FiveHour);
        assert_eq!(id_of(&sides.left).map(|(p, _)| p), Some(Provider::Codex), "The first in order left");
        assert_eq!(id_of(&sides.right).map(|(p, _)| p), Some(Provider::ClaudeCode), "the second right");
        let shown: Vec<_> = SurfaceCards::shown(&[reading(Provider::ClaudeCode), reading(Provider::Codex)]).iter().map(|s| s.provider).collect();
        assert_eq!(shown, [Provider::Codex, Provider::ClaudeCode], "The cards in the same order");
        assert_eq!(selection::ordered([Provider::ClaudeCode, Provider::Codex]), [Provider::Codex, Provider::ClaudeCode], "One order, from the Provider list");
    }

    /// At most two Providers can be on: the surface has two sides and room for
    /// two cards. One already on can always stay on.
    #[test]
    fn at_most_two_providers_can_be_on() {
        use std::collections::HashSet;
        assert_eq!(selection::VISIBLE_LIMIT, 2, "Two");
        assert!(selection::can_turn_on(Provider::ClaudeCode, &[Provider::Codex].into(), selection::VISIBLE_LIMIT), "A second joins the first");
        let two: HashSet<_> = [Provider::Codex, Provider::ClaudeCode].into();
        assert!(selection::can_turn_on(Provider::Codex, &two, selection::VISIBLE_LIMIT), "One already on stays on");
        assert!(!selection::can_turn_on(Provider::ClaudeCode, &[Provider::Codex].into(), 1), "Past the limit, refused");
        assert_eq!(selection::to_connect([Provider::ClaudeCode, Provider::Codex], 1), [Provider::Codex], "More chosen than allowed connects the first in order only");
    }

    /// One Provider on and not read yet: its dash stands on the left, where its
    /// five hours will stand once read, whichever Provider it is.
    #[test]
    fn the_only_provider_not_read_yet_has_its_dash_on_the_left() {
        let unread = CapacitySnapshot { provider: Provider::ClaudeCode, captured_at: read_at(), windows: vec![], connection_state: ConnectionState::Connecting, status_reason: None };
        let sides = CompactStrip::sides(&[UnreadCapacity::snapshot(Provider::Codex, read_at()), unread], CompactWindowChoice::FiveHour);
        match sides.left {
            Some(Side::Provider { snapshot }) => assert_eq!(snapshot.provider, Provider::ClaudeCode),
            other => panic!("A dash on the left, got {other:?}"),
        }
        assert!(sides.right.is_none(), "Claude Code's dash, and nothing on the right");
    }

    #[test]
    fn one_window_alone_stands_on_the_left_with_nothing_on_the_right() {
        let single = CapacitySnapshot { windows: vec![window("five", "5 hour", 300, 0.2)], ..reading(Provider::Codex) };
        let sides = CompactStrip::sides(&[single], CompactWindowChoice::FiveHour);
        assert_eq!(id_of(&sides.left), Some((Provider::Codex, "five".into())));
        assert!(sides.right.is_none());
    }

    #[test]
    fn a_surface_gets_the_strip_as_json_it_can_read() {
        let sides = CompactStrip::sides(&[reading(Provider::Codex), reading(Provider::ClaudeCode)], CompactWindowChoice::Weekly);
        let json = serde_json::to_value(&sides).unwrap();
        assert_eq!(json["left"]["kind"], "window");
        assert_eq!(json["left"]["provider"], "codex");
        assert_eq!(json["right"]["window"]["id"], "week");
        assert_eq!(serde_json::to_value(CompactWindowChoice::LeastLeft).unwrap(), "leastLeft");
        let back: Sides = serde_json::from_value(json).unwrap();
        assert_eq!(back, sides);
    }

    #[test]
    fn the_choices_are_titled_in_the_language_of_settings() {
        crate::loc::with_language(crate::loc::AppLanguage::Russian, || {
            let titles: Vec<_> = CompactWindowChoice::ALL.iter().map(|c| c.title()).collect();
            assert_eq!(titles, ["5-ти часовые", "Недельные", "Меньший остаток"]);
        });
    }
}
