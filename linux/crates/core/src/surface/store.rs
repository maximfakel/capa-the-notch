use crate::snapshot::{CapacitySnapshot, Provider};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Presentation {
    Compact,
    Expanded,
}

/// The Quota Window an alert was about, while it is worth pointing at.
/// Opening the surface from a notification and then hunting for the row it
/// meant is not being taken to the window.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HighlightedWindow {
    pub provider: Provider,
    pub window_id: String,
}

/// What the surface holds between readings: each Provider's latest snapshot,
/// whether it is open, and whether it has been pinned open (the pure half of
/// `CapacityNotchStore`; a surface publishes changes itself).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SurfaceStore {
    pub snapshots: Vec<CapacitySnapshot>,
    pub presentation: Presentation,
    /// Pinned open: the surface stays until it is dismissed, rather than
    /// closing when the pointer wanders off.
    pub is_pinned: bool,
    pub highlighted: Option<HighlightedWindow>,
}

impl SurfaceStore {
    pub fn new(snapshots: Vec<CapacitySnapshot>) -> Self {
        Self { snapshots, presentation: Presentation::Compact, is_pinned: false, highlighted: None }
    }

    /// Replaces the Capacity Snapshot for the Provider it describes, keeping
    /// the order Providers already occupy on the surface.
    pub fn apply(&mut self, snapshot: CapacitySnapshot) {
        match self.snapshots.iter().position(|s| s.provider == snapshot.provider) {
            Some(index) => self.snapshots[index] = snapshot,
            None => self.snapshots.push(snapshot),
        }
    }

    pub fn highlight(&mut self, window: Option<HighlightedWindow>) {
        self.highlighted = window;
    }

    pub fn pin(&mut self) {
        self.is_pinned = true;
        self.expand();
    }

    /// Dismisses a pinned surface. Used by a second click, by Escape, and by a
    /// click anywhere else.
    pub fn dismiss(&mut self) {
        self.is_pinned = false;
        self.collapse();
    }

    pub fn toggle_pin(&mut self) {
        if self.is_pinned { self.dismiss() } else { self.pin() }
    }

    pub fn toggle(&mut self) {
        self.presentation = match self.presentation {
            Presentation::Compact => Presentation::Expanded,
            Presentation::Expanded => Presentation::Compact,
        };
    }

    pub fn expand(&mut self) {
        self.presentation = Presentation::Expanded;
    }

    pub fn collapse(&mut self) {
        self.presentation = Presentation::Compact;
    }
}

#[cfg(test)]
mod tests {
    use super::super::unread::UnreadCapacity;
    use super::*;
    use crate::snapshot::{ConnectionState, QuotaWindow};
    use chrono::{TimeZone, Utc};

    fn store() -> SurfaceStore {
        SurfaceStore::new(UnreadCapacity::snapshots(Utc.timestamp_opt(0, 0).unwrap()))
    }

    #[test]
    fn a_pinned_surface_stays_until_it_is_dismissed() {
        let mut store = store();
        assert!(!store.is_pinned, "It starts unpinned");

        store.pin();
        assert!(store.is_pinned, "A click pins it");
        assert_eq!(store.presentation, Presentation::Expanded, "And opens it");

        store.collapse();
        assert_eq!(store.presentation, Presentation::Compact, "A pointer leaving can still close it — the panel is what declines to");

        store.pin();
        store.toggle_pin();
        assert!(!store.is_pinned, "A second click lets it go");
        assert_eq!(store.presentation, Presentation::Compact, "And closes it");

        store.pin();
        store.dismiss();
        assert!(!store.is_pinned, "Escape and a click elsewhere dismiss it the same way");
        assert_eq!(store.presentation, Presentation::Compact, "And close it");
    }

    #[test]
    fn a_snapshot_replaces_its_providers_in_place_and_a_new_one_is_added() {
        let mut store = store();
        let order: Vec<_> = store.snapshots.iter().map(|s| s.provider).collect();
        let fresh = CapacitySnapshot {
            provider: Provider::ClaudeCode,
            captured_at: Utc.timestamp_opt(5, 0).unwrap(),
            windows: vec![QuotaWindow::new("w", "5 hour", Some(300), 0.1, None)],
            connection_state: ConnectionState::Fresh,
            status_reason: None,
        };
        store.apply(fresh.clone());
        assert_eq!(store.snapshots.iter().map(|s| s.provider).collect::<Vec<_>>(), order, "the order Providers occupy is kept");
        assert_eq!(store.snapshots[1], fresh);

        let mut empty = SurfaceStore::new(vec![]);
        empty.apply(fresh.clone());
        assert_eq!(empty.snapshots, [fresh]);
    }

    #[test]
    fn the_surface_toggles_and_remembers_what_an_alert_was_about() {
        let mut store = store();
        store.toggle();
        assert_eq!(store.presentation, Presentation::Expanded);
        store.toggle();
        assert_eq!(store.presentation, Presentation::Compact);
        let window = HighlightedWindow { provider: Provider::Codex, window_id: "codex-primary".into() };
        store.highlight(Some(window.clone()));
        assert_eq!(store.highlighted, Some(window));
        store.highlight(None);
        assert_eq!(store.highlighted, None);
    }
}
