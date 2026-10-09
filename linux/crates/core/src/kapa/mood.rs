use super::face::KapaExpression;
use crate::pace::CapacityPace;
use crate::snapshot::{CapacitySnapshot, ConnectionState, Provider};
use serde::{Deserialize, Serialize};

/// The card that has Kapa on a page, and the pose it shows.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KapaFocus {
    pub provider: Provider,
    pub expression: KapaExpression,
}

/// The signals, read into poses. Pure, so each rule can be tested where it
/// is written.
pub struct KapaMood;

impl KapaMood {
    /// One Provider's pose, from its connection and the window with the least
    /// left. Old numbers get no judgement: stale and connecting look the same.
    pub fn capacity(snapshot: &CapacitySnapshot) -> KapaExpression {
        match snapshot.connection_state {
            ConnectionState::Disconnected(_) => KapaExpression::Puzzled,
            ConnectionState::Connecting | ConnectionState::Stale => KapaExpression::Stale,
            ConnectionState::Fresh | ConnectionState::Mock => {
                let Some(window) = snapshot.headline_window() else {
                    return KapaExpression::Rest;
                };
                if window.remaining_fraction() <= 0.0 {
                    return KapaExpression::Waiting;
                }
                match window.pace() {
                    CapacityPace::Sustainable => KapaExpression::Rest,
                    CapacityPace::Tightening => KapaExpression::Focused,
                    CapacityPace::Unsustainable => KapaExpression::Worried,
                }
            }
        }
    }

    /// One Kapa a page: on the card that explains the pose, which is the one
    /// needing the most attention. A tie goes to the card that comes first,
    /// so the choice does not wander between equal cards.
    pub fn capacity_focus(snapshots: &[CapacitySnapshot]) -> Option<KapaFocus> {
        let mut best: Option<(KapaFocus, u8)> = None;
        for snapshot in snapshots {
            let expression = Self::capacity(snapshot);
            let urgency = Self::urgency(expression);
            if best.is_none_or(|(_, b)| urgency < b) {
                best = Some((KapaFocus { provider: snapshot.provider, expression }, urgency));
            }
        }
        best.map(|(focus, _)| focus)
    }

    /// Lower first: what most wants a look.
    pub fn urgency(expression: KapaExpression) -> u8 {
        match expression {
            KapaExpression::Worried => 0,
            KapaExpression::Waiting => 1,
            KapaExpression::Puzzled => 2,
            KapaExpression::Stale => 3,
            KapaExpression::Focused => 4,
            _ => 5,
        }
    }

    pub fn music(is_playing: bool) -> KapaExpression {
        if is_playing {
            KapaExpression::Music
        } else {
            KapaExpression::Paused
        }
    }
}

/// Whether Kapa is drawn. On unless a person turns it off: it asks for no
/// permission, reads nothing new and never takes the compact strip, so it is
/// part of how Modules already on look rather than a Module of its own
/// (ADR 0006).
pub struct KapaPreference;

impl KapaPreference {
    pub const KEY: &'static str = "showsKapa";
    pub const DEFAULT_VALUE: bool = true;
}
