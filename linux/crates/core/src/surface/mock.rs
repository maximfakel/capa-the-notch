use crate::snapshot::{CapacitySnapshot, ConnectionState, Provider, QuotaWindow};
use chrono::{DateTime, Duration, Utc};

/// Capacity drawn for pictures and tests, and marked as made up: every
/// snapshot says `Mock`, so nothing can mistake it for a Provider's own.
pub struct MockCapacityCatalog;

impl MockCapacityCatalog {
    pub fn snapshots(captured_at: DateTime<Utc>) -> Vec<CapacitySnapshot> {
        let five_hour = |id: &str, used: f64, hours: i64| {
            QuotaWindow::new(id, "5 hour", Some(300), used, Some(captured_at + Duration::hours(hours)))
        };
        vec![
            CapacitySnapshot {
                provider: Provider::Codex,
                captured_at,
                windows: vec![five_hour("codex-five-hour", 0.70, 2)],
                connection_state: ConnectionState::Mock,
                status_reason: None,
            },
            CapacitySnapshot {
                provider: Provider::ClaudeCode,
                captured_at,
                windows: vec![five_hour("claude-five-hour", 0.45, 3)],
                connection_state: ConnectionState::Mock,
                status_reason: None,
            },
        ]
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn captured() -> DateTime<Utc> {
        Utc.timestamp_opt(10_000, 0).unwrap()
    }

    #[test]
    fn mock_catalog_provides_both_initial_providers() {
        let snapshots = MockCapacityCatalog::snapshots(captured());
        let providers: Vec<_> = snapshots.iter().map(|s| s.provider).collect();
        assert_eq!(providers, [Provider::Codex, Provider::ClaudeCode], "Mock catalog should provide Codex and Claude Code in display order");
        assert!(snapshots.iter().all(|s| !s.windows.is_empty()), "Every mock Provider should include at least one Quota Window");
        assert!(snapshots.iter().all(|s| s.captured_at == captured()), "Every mock snapshot should use the requested capture time");
    }

    #[test]
    fn mock_catalog_marks_capacity_as_mock() {
        let snapshots = MockCapacityCatalog::snapshots(captured());
        assert!(snapshots.iter().all(|s| s.connection_state == ConnectionState::Mock), "Every mock Capacity Snapshot should explicitly identify mock provenance");
    }

    #[test]
    fn the_mock_windows_reset_ahead_of_the_capture() {
        for s in MockCapacityCatalog::snapshots(captured()) {
            assert!(s.windows[0].resets_at.unwrap() > captured());
        }
    }
}
