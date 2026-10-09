use crate::selection;
use crate::snapshot::{CapacitySnapshot, CapacityStatusReason, Provider};
use chrono::{DateTime, Utc};
use std::collections::HashSet;

impl Provider {
    /// What a Provider says while the person has it switched off.
    pub fn switched_off_reason(self) -> CapacityStatusReason {
        match self {
            Provider::Codex => CapacityStatusReason::CodexDisconnected,
            Provider::ClaudeCode => CapacityStatusReason::ClaudeDisconnected,
            Provider::OpenCode => CapacityStatusReason::OpenCodeDisconnected,
        }
    }
}

impl CapacitySnapshot {
    /// Not being read because the person has it switched off, as opposed to
    /// switched on and failing.
    pub fn is_switched_off(&self) -> bool {
        self.status_reason.as_ref() == Some(&self.provider.switched_off_reason())
    }
}

/// What the surface shows before a Provider has been read.
///
/// Each Provider states that it has nothing yet and how to change that. There
/// are no invented numbers: a surface that shows a figure is showing a figure
/// that came from a Provider.
pub struct UnreadCapacity;

impl UnreadCapacity {
    pub fn snapshots(captured_at: DateTime<Utc>) -> Vec<CapacitySnapshot> {
        Provider::ALL.into_iter().map(|p| Self::snapshot(p, captured_at)).collect()
    }

    /// The same, with anything remembered from a previous run put back in
    /// place. A Provider with nothing archived still says it has not been
    /// read; one with a reading shows it, marked Stale.
    ///
    /// A Provider the person switched off is not put back: its last reading
    /// would sit on the surface, never to be refreshed.
    pub fn snapshots_restoring(
        archived: &[CapacitySnapshot],
        switched_off: &HashSet<Provider>,
        captured_at: DateTime<Utc>,
    ) -> Vec<CapacitySnapshot> {
        Self::snapshots(captured_at)
            .into_iter()
            .map(|unread| {
                if switched_off.contains(&unread.provider) {
                    return unread;
                }
                archived.iter().find(|a| a.provider == unread.provider).cloned().unwrap_or(unread)
            })
            .collect()
    }

    /// One Provider, unread: what it shows once switched off.
    pub fn snapshot(provider: Provider, captured_at: DateTime<Utc>) -> CapacitySnapshot {
        CapacitySnapshot::disconnected(provider, captured_at, provider.switched_off_reason())
    }
}

/// Snapshots in the one order Providers stand in everywhere: Codex, Claude
/// Code, then any later one.
pub fn ordered_snapshots(snapshots: &[CapacitySnapshot]) -> Vec<CapacitySnapshot> {
    let mut ordered = snapshots.to_vec();
    ordered.sort_by_key(|s| s.provider);
    ordered
}

/// Which Providers have a card on the open surface.
///
/// A Provider switched off has none, and the other takes the width. With every
/// Provider off, none has a card: the surface offers them all at once instead.
pub struct SurfaceCards;

impl SurfaceCards {
    pub fn shown(snapshots: &[CapacitySnapshot]) -> Vec<CapacitySnapshot> {
        ordered_snapshots(&snapshots.iter().filter(|s| !s.is_switched_off()).cloned().collect::<Vec<_>>())
    }

    /// The Providers whose marks stand over the one button to Settings ▸
    /// Providers: every one, in order, while nothing is connected, and none
    /// otherwise. Connecting, and its consent, happens in Settings.
    pub fn offered(snapshots: &[CapacitySnapshot]) -> Vec<Provider> {
        if Self::nothing_connected(snapshots) { selection::ordered(Provider::ALL) } else { vec![] }
    }

    /// Every Provider switched off: opened, the surface shows the Providers'
    /// marks; closed, the strip is empty. It is not held open.
    pub fn nothing_connected(snapshots: &[CapacitySnapshot]) -> bool {
        !snapshots.is_empty() && snapshots.iter().all(CapacitySnapshot::is_switched_off)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::snapshot::{ConnectionState, QuotaWindow};
    use chrono::TimeZone;

    fn now() -> DateTime<Utc> {
        Utc.timestamp_opt(2_000_000, 0).unwrap()
    }

    fn read(provider: Provider) -> CapacitySnapshot {
        CapacitySnapshot {
            provider,
            captured_at: now(),
            windows: vec![QuotaWindow::new("five", "5 hour", Some(300), 0.2, None)],
            connection_state: ConnectionState::Fresh,
            status_reason: None,
        }
    }

    #[test]
    fn a_provider_switched_off_is_not_restored_from_the_archive() {
        let switched_off: HashSet<_> = [Provider::Codex].into();
        let restored = UnreadCapacity::snapshots_restoring(&[read(Provider::Codex), read(Provider::ClaudeCode)], &switched_off, now());
        let codex = restored.iter().find(|s| s.provider == Provider::Codex).unwrap();
        let claude = restored.iter().find(|s| s.provider == Provider::ClaudeCode).unwrap();

        assert!(codex.is_switched_off(), "Codex was switched off, so its last reading does not come back");
        assert!(codex.windows.is_empty(), "and it shows no numbers, got {}", codex.windows.len());
        assert!(claude.windows.len() == 1 && !claude.is_switched_off(), "Claude Code, still on, keeps its reading");
    }

    #[test]
    fn only_the_providers_switched_on_have_cards() {
        let codex_off = UnreadCapacity::snapshot(Provider::Codex, now());
        let shown = SurfaceCards::shown(&[codex_off, read(Provider::ClaudeCode)]);
        let providers: Vec<_> = shown.iter().map(|s| s.provider).collect();
        assert_eq!(providers, [Provider::ClaudeCode], "With Codex switched off, Claude Code's card has the width to itself");

        let all_off = UnreadCapacity::snapshots(now());
        assert!(SurfaceCards::shown(&all_off).is_empty(), "With nothing switched on, no Provider has a card of its own");

        let failing = CapacitySnapshot::disconnected(Provider::Codex, now(), CapacityStatusReason::ProviderNotInstalled);
        assert_eq!(SurfaceCards::shown(&[failing, read(Provider::ClaudeCode)]).len(), 2, "A Provider that is on but failing keeps its card, to say why");
    }

    #[test]
    fn nothing_connected_offers_every_providers_mark_in_order() {
        let all_off = UnreadCapacity::snapshots(now());
        let order = vec![Provider::Codex, Provider::ClaudeCode, Provider::OpenCode];
        assert_eq!(SurfaceCards::offered(&all_off), order, "Nothing on: the marks of Codex, Claude Code and OpenCode, in that order");
        let reversed: Vec<_> = all_off.iter().rev().cloned().collect();
        assert_eq!(SurfaceCards::offered(&reversed), order, "in that order whatever order the snapshots come in");

        let one_on: Vec<_> = all_off.iter().map(|s| if s.provider == Provider::OpenCode { read(Provider::OpenCode) } else { s.clone() }).collect();
        assert!(SurfaceCards::offered(&one_on).is_empty(), "One on: no marks");
        let shown: Vec<_> = SurfaceCards::shown(&one_on).iter().map(|s| s.provider).collect();
        assert_eq!(shown, [Provider::OpenCode], "and its card alone, across the width");
        assert!(SurfaceCards::offered(&[]).is_empty(), "Nothing known yet is not nothing connected");
    }

    #[test]
    fn unread_capacity_has_no_invented_numbers() {
        for s in UnreadCapacity::snapshots(now()) {
            assert!(s.windows.is_empty());
            assert!(s.is_switched_off());
            assert_eq!(s.captured_at, now());
        }
        assert_eq!(UnreadCapacity::snapshots(now()).len(), 3);
    }

    #[test]
    fn a_failing_provider_is_not_mistaken_for_one_switched_off() {
        let failing = CapacitySnapshot::disconnected(Provider::Codex, now(), CapacityStatusReason::ProviderNotInstalled);
        assert!(!failing.is_switched_off());
        // A reason belongs to its own Provider: Claude Code's "off" does not switch Codex off.
        let wrong = CapacitySnapshot::disconnected(Provider::Codex, now(), CapacityStatusReason::ClaudeDisconnected);
        assert!(!wrong.is_switched_off());
    }
}
