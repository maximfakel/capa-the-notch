use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Provider {
    Codex,
    ClaudeCode,
    /// OpenCode's Go plan, read with its own key (ADR 0001, amended).
    OpenCode,
}

impl Provider {
    /// The fixed order Providers take on the surface.
    pub const ALL: [Provider; 3] = [Provider::Codex, Provider::ClaudeCode, Provider::OpenCode];

    pub fn spoken_name(self) -> &'static str {
        match self {
            Provider::Codex => "Codex",
            Provider::ClaudeCode => "Claude Code",
            Provider::OpenCode => "OpenCode",
        }
    }
}

/// Why a Provider has no Capacity to show, together with the one action that
/// would fix it. A disconnected Provider is never drawn as zero Capacity.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "code", content = "detail", rename_all = "kebab-case")]
pub enum CapacityStatusReason {
    ProviderNotInstalled,
    ProviderIncompatible(String),
    ProviderNotAuthenticated,
    ProviderUnavailable(String),
    ProviderAnswerNotUnderstood,
    ProviderCouldNotRead(String),
    CodexDisconnected,
    ClaudeDisconnected,
    ClaudeStatusLineStale,
    ClaudeStatusLineUnavailable,
    ClaudeCodeNotInstalled,
    ClaudeUsageFailed,
    ClaudeUsageNotUnderstood,
    OpenCodeDisconnected,
    OpenCodeNotSignedIn,
    OpenCodeKeyRefused,
    OpenCodeUnreachable,
    OpenCodeAnswerNotUnderstood,
    /// Not a failure: the windows are read, but the plan's month is used up.
    OpenCodeMonthlyLimitReached(Option<DateTime<Utc>>),
    StaleFromArchive,
}

impl CapacityStatusReason {
    pub fn guidance(&self) -> String {
        use CapacityStatusReason::*;
        match self {
            ProviderNotInstalled => "Install the Codex CLI, then try again.".into(),
            ProviderIncompatible(d) => format!("Update the Codex CLI — {d}"),
            ProviderNotAuthenticated => "Sign in with `codex login`, then try again.".into(),
            ProviderUnavailable(d) => format!("Codex is not answering — {d}"),
            ProviderAnswerNotUnderstood => {
                "Codex answered in a form CapaTheNotch cannot read. Update CapaTheNotch.".into()
            }
            ProviderCouldNotRead(d) => {
                let d = if d.ends_with('.') { d.clone() } else { format!("{d}.") };
                format!("Codex could not read its Capacity — {d} Retrying.")
            }
            CodexDisconnected => "Turn on Codex in Settings to read its Capacity.".into(),
            ClaudeDisconnected => "Turn on Claude Code in Settings to read its Capacity.".into(),
            ClaudeStatusLineStale => {
                "Run Claude Code in a terminal to update its last published Capacity.".into()
            }
            ClaudeStatusLineUnavailable => "Claude Code has not published Capacity yet. Configure the CapaTheNotch status-line bridge, then run Claude Code in a terminal.".into(),
            ClaudeCodeNotInstalled => "Install Claude Code, then try again.".into(),
            ClaudeUsageFailed => {
                "Claude Code did not answer. Check that it is signed in, then refresh.".into()
            }
            ClaudeUsageNotUnderstood => "Claude Code's usage report has changed and CapaTheNotch cannot read it. Update CapaTheNotch.".into(),
            OpenCodeDisconnected => "Turn on OpenCode in Settings to read its Capacity.".into(),
            OpenCodeNotSignedIn => {
                "Sign in to OpenCode with `opencode auth login`, then try again.".into()
            }
            OpenCodeKeyRefused => {
                "OpenCode refused its key. Sign in again with `opencode auth login`.".into()
            }
            OpenCodeUnreachable => "opencode.ai is not answering. Retrying.".into(),
            OpenCodeAnswerNotUnderstood => {
                "OpenCode's answer was not understood. Update CapaTheNotch.".into()
            }
            OpenCodeMonthlyLimitReached(_) => "Monthly limit reached".into(),
            StaleFromArchive => "Last seen before CapaTheNotch restarted. Refreshing.".into(),
        }
    }

    /// Whether the card's chip already carries this.
    pub fn repeats_the_chip(&self) -> bool {
        matches!(self, Self::StaleFromArchive | Self::OpenCodeMonthlyLimitReached(_))
    }

    /// The reason as a word a bug report can carry: never the guidance and
    /// never the detail, which can hold a token, a path or an address.
    pub fn diagnostic_code(&self) -> &'static str {
        use CapacityStatusReason::*;
        match self {
            ProviderNotInstalled => "provider-not-installed",
            ProviderIncompatible(_) => "provider-incompatible",
            ProviderNotAuthenticated => "provider-not-authenticated",
            ProviderUnavailable(_) => "provider-unavailable",
            ProviderAnswerNotUnderstood => "provider-answer-not-understood",
            ProviderCouldNotRead(_) => "provider-could-not-read",
            CodexDisconnected => "codex-disconnected",
            ClaudeDisconnected => "claude-disconnected",
            ClaudeStatusLineStale => "claude-status-line-stale",
            ClaudeStatusLineUnavailable => "claude-status-line-unavailable",
            ClaudeCodeNotInstalled => "claude-code-not-installed",
            ClaudeUsageFailed => "claude-usage-failed",
            ClaudeUsageNotUnderstood => "claude-usage-not-understood",
            OpenCodeDisconnected => "opencode-disconnected",
            OpenCodeNotSignedIn => "opencode-not-signed-in",
            OpenCodeKeyRefused => "opencode-key-refused",
            OpenCodeUnreachable => "opencode-unreachable",
            OpenCodeAnswerNotUnderstood => "opencode-not-understood",
            OpenCodeMonthlyLimitReached(_) => "opencode-month-used-up",
            StaleFromArchive => "stale-from-archive",
        }
    }

    /// Whether a person has to do something before any button can help.
    pub fn needs_a_person_first(&self) -> bool {
        use CapacityStatusReason::*;
        matches!(
            self,
            ProviderNotInstalled
                | ProviderIncompatible(_)
                | ProviderNotAuthenticated
                | ProviderAnswerNotUnderstood
                | ClaudeStatusLineUnavailable
                | ClaudeCodeNotInstalled
                | ClaudeUsageNotUnderstood
                | OpenCodeNotSignedIn
                | OpenCodeKeyRefused
                | OpenCodeAnswerNotUnderstood
        )
    }

    /// Whether trying again could clear this on its own.
    pub fn is_transient(&self) -> bool {
        use CapacityStatusReason::*;
        matches!(
            self,
            ProviderUnavailable(_)
                | ProviderCouldNotRead(_)
                | ClaudeStatusLineStale
                | ClaudeUsageFailed
                | OpenCodeUnreachable
                | StaleFromArchive
        )
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "state", content = "reason", rename_all = "camelCase")]
pub enum ConnectionState {
    Mock,
    /// Asked, not yet answered: nothing is wrong yet, and nothing to keep showing.
    Connecting,
    Fresh,
    Stale,
    Disconnected(CapacityStatusReason),
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QuotaWindow {
    pub id: String,
    pub label: String,
    pub duration_minutes: Option<i64>,
    pub used_fraction: f64,
    pub resets_at: Option<DateTime<Utc>>,
}

impl QuotaWindow {
    pub fn new(
        id: impl Into<String>,
        label: impl Into<String>,
        duration_minutes: Option<i64>,
        used_fraction: f64,
        resets_at: Option<DateTime<Utc>>,
    ) -> Self {
        Self {
            id: id.into(),
            label: label.into(),
            duration_minutes,
            used_fraction,
            resets_at,
        }
    }

    /// Rounded half away from zero, as Swift's `rounded()` does.
    pub fn remaining_percentage(&self) -> f64 {
        ((1.0 - self.used_fraction) * 100.0).round()
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CapacitySnapshot {
    pub provider: Provider,
    pub captured_at: DateTime<Utc>,
    pub windows: Vec<QuotaWindow>,
    pub connection_state: ConnectionState,
    pub status_reason: Option<CapacityStatusReason>,
}

impl CapacitySnapshot {
    /// A Provider that cannot be read carries no Quota Windows, so no surface
    /// can mistake an unreadable Provider for an exhausted one.
    pub fn disconnected(
        provider: Provider,
        captured_at: DateTime<Utc>,
        reason: CapacityStatusReason,
    ) -> Self {
        Self {
            provider,
            captured_at,
            windows: vec![],
            connection_state: ConnectionState::Disconnected(reason.clone()),
            status_reason: Some(reason),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_disconnected_provider_has_no_windows() {
        let s = CapacitySnapshot::disconnected(
            Provider::Codex,
            Utc::now(),
            CapacityStatusReason::ProviderNotInstalled,
        );
        assert!(s.windows.is_empty());
        assert_eq!(s.status_reason, Some(CapacityStatusReason::ProviderNotInstalled));
    }

    #[test]
    fn a_reason_is_exactly_one_of_transient_or_waiting_on_a_person_or_neither() {
        use CapacityStatusReason::*;
        let all = [
            ProviderNotInstalled,
            ProviderIncompatible("x".into()),
            ProviderNotAuthenticated,
            ProviderUnavailable("x".into()),
            ProviderAnswerNotUnderstood,
            ProviderCouldNotRead("x".into()),
            CodexDisconnected,
            ClaudeDisconnected,
            ClaudeStatusLineStale,
            ClaudeStatusLineUnavailable,
            ClaudeCodeNotInstalled,
            ClaudeUsageFailed,
            ClaudeUsageNotUnderstood,
            OpenCodeDisconnected,
            OpenCodeNotSignedIn,
            OpenCodeKeyRefused,
            OpenCodeUnreachable,
            OpenCodeAnswerNotUnderstood,
            OpenCodeMonthlyLimitReached(None),
            StaleFromArchive,
        ];
        for r in &all {
            assert!(!(r.is_transient() && r.needs_a_person_first()), "{r:?}");
            // Diagnostic codes stay under the redaction threshold.
            assert!(r.diagnostic_code().len() < 32, "{r:?}");
        }
    }

    #[test]
    fn guidance_ends_the_detail_with_a_full_stop_once() {
        let r = CapacityStatusReason::ProviderCouldNotRead("no network".into());
        assert_eq!(r.guidance(), "Codex could not read its Capacity — no network. Retrying.");
        let r = CapacityStatusReason::ProviderCouldNotRead("no network.".into());
        assert_eq!(r.guidance(), "Codex could not read its Capacity — no network. Retrying.");
    }

    #[test]
    fn a_snapshot_survives_json() {
        let s = CapacitySnapshot {
            provider: Provider::ClaudeCode,
            captured_at: Utc::now(),
            windows: vec![QuotaWindow::new("w", "5 hour", Some(300), 0.25, None)],
            connection_state: ConnectionState::Disconnected(
                CapacityStatusReason::ProviderIncompatible("old".into()),
            ),
            status_reason: None,
        };
        let json = serde_json::to_string(&s).unwrap();
        assert_eq!(serde_json::from_str::<CapacitySnapshot>(&json).unwrap(), s);
    }
}
