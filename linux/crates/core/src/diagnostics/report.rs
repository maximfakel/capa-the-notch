use super::redaction::Redaction;
use crate::snapshot::{CapacitySnapshot, ConnectionState, Provider};
use chrono::{DateTime, Utc};

/// One Provider as a report may describe it: closed words and counts.
#[derive(Debug, Clone, PartialEq)]
pub struct ProviderDiagnostic {
    pub provider: Provider,
    pub connection_state: ConnectionState,
    pub reason_code: Option<String>,
    pub window_count: usize,
    pub captured_at: Option<DateTime<Utc>>,
    pub consecutive_transient_failures: u32,
}

impl ProviderDiagnostic {
    pub fn from_snapshot(snapshot: &CapacitySnapshot, consecutive_transient_failures: u32) -> Self {
        Self {
            provider: snapshot.provider,
            connection_state: snapshot.connection_state.clone(),
            reason_code: snapshot.status_reason.as_ref().map(|r| r.diagnostic_code().to_owned()),
            window_count: snapshot.windows.len(),
            captured_at: Some(snapshot.captured_at),
            consecutive_transient_failures,
        }
    }
}

impl ConnectionState {
    /// The state as a word a bug report can carry.
    pub fn diagnostic_code(&self) -> &'static str {
        match self {
            ConnectionState::Mock => "mock",
            ConnectionState::Connecting => "connecting",
            ConnectionState::Fresh => "fresh",
            ConnectionState::Stale => "stale",
            ConnectionState::Disconnected(_) => "disconnected",
        }
    }
}

/// `2023-11-14T22:13:20Z`: the internet date-time of Swift's `ISO8601DateFormatter`.
pub fn timestamp(at: DateTime<Utc>) -> String {
    at.format("%Y-%m-%dT%H:%M:%SZ").to_string()
}

#[derive(Debug, Clone, PartialEq)]
pub struct DiagnosticReport {
    pub application_version: String,
    /// "macOS", "Linux": the report says which system it came from.
    pub system_name: String,
    pub system_version: String,
    pub generated_at: DateTime<Utc>,
    pub providers: Vec<ProviderDiagnostic>,
    /// Closed observations the application can make about itself, such as
    /// whether a bridge snapshot exists. Never a message from anywhere else.
    pub observations: Vec<String>,
}

impl DiagnosticReport {
    /// A report from a Mac, as the Swift one always is; `with_system_name`
    /// says otherwise.
    pub fn new(
        application_version: impl Into<String>,
        system_version: impl Into<String>,
        generated_at: DateTime<Utc>,
        providers: Vec<ProviderDiagnostic>,
        observations: Vec<String>,
    ) -> Self {
        Self {
            application_version: application_version.into(),
            system_name: "macOS".into(),
            system_version: system_version.into(),
            generated_at,
            providers,
            observations,
        }
    }

    pub fn with_system_name(mut self, name: impl Into<String>) -> Self {
        self.system_name = name.into();
        self
    }

    pub fn text(&self) -> String {
        let mut lines = vec![
            format!("CapaTheNotch {}", self.application_version),
            format!("{} {}", self.system_name, self.system_version),
            format!("generated {}", timestamp(self.generated_at)),
            String::new(),
        ];

        for provider in &self.providers {
            lines.push(format!("{}:", provider_raw_value(provider.provider)));
            lines.push(format!("  state {}", provider.connection_state.diagnostic_code()));
            if let Some(reason) = &provider.reason_code {
                lines.push(format!("  reason {reason}"));
            }
            lines.push(format!("  windows {}", provider.window_count));
            if let Some(captured_at) = provider.captured_at {
                lines.push(format!("  read {}", timestamp(captured_at)));
            }
            if provider.consecutive_transient_failures > 0 {
                lines.push(format!("  retries {}", provider.consecutive_transient_failures));
            }
        }

        if !self.observations.is_empty() {
            lines.push(String::new());
            lines.extend(self.observations.iter().map(|o| format!("note {o}")));
        }

        Redaction::scrub(&lines.join("\n"))
    }
}

/// Swift's `Provider.rawValue`, which is what a report names a Provider by.
fn provider_raw_value(provider: Provider) -> &'static str {
    match provider {
        Provider::Codex => "codex",
        Provider::ClaudeCode => "claudeCode",
        Provider::OpenCode => "openCode",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::snapshot::{CapacityStatusReason, QuotaWindow};
    use chrono::TimeZone;

    fn reported_at() -> DateTime<Utc> {
        Utc.timestamp_opt(1_700_000_000, 0).unwrap()
    }

    /// Errors shaped like the ones these Providers really produce, each
    /// carrying something that must never leave the machine.
    const SECRET_BEARING_ERRORS: [&str; 6] = [
        "error sending request: Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk",
        "failed to read sk-ant-oat01-7Qv3mK9xR2wL5nB8tY4cE6uH1sJ0aD",
        "no credential at /Users/jordanlee/.claude/.credentials.json",
        "account jordan.lee@example.com is not authorised",
        "organization 3f9d1bdc-5671-44be-bc29-0825e2fb372e has no access",
        "token=AbCdEfGhIjKlMnOpQrStUvWxYz0123456789AbCdEf",
    ];

    fn report_carrying(detail: &str) -> String {
        let snapshot = CapacitySnapshot::disconnected(
            Provider::Codex,
            reported_at(),
            // The one place a Provider's own words reach the domain.
            CapacityStatusReason::ProviderUnavailable(detail.into()),
        );
        DiagnosticReport::new("0.1.0", "26.6.2", reported_at(), vec![ProviderDiagnostic::from_snapshot(&snapshot, 3)], vec![]).text()
    }

    #[test]
    fn a_providers_own_words_never_reach_the_report() {
        for error in SECRET_BEARING_ERRORS {
            let report = report_carrying(error);
            for fragment in error.split(' ').filter(|f| f.chars().count() >= 8) {
                assert!(!report.contains(fragment), "\"{fragment}\" reached the report:\n{report}");
            }
            assert!(report.contains("reason provider-unavailable"), "The report still says what went wrong, in a word:\n{report}");
        }
    }

    #[test]
    fn the_report_stays_useful_for_every_failure_worth_reporting() {
        use CapacityStatusReason::*;
        let failures = [
            (ProviderNotInstalled, "provider-not-installed"),
            (ProviderIncompatible("too old".into()), "provider-incompatible"),
            (ProviderNotAuthenticated, "provider-not-authenticated"),
            (ProviderUnavailable("closed".into()), "provider-unavailable"),
            (ProviderAnswerNotUnderstood, "provider-answer-not-understood"),
            (ProviderCouldNotRead("error sending request".into()), "provider-could-not-read"),
            (ClaudeStatusLineStale, "claude-status-line-stale"),
            (ClaudeStatusLineUnavailable, "claude-status-line-unavailable"),
            (ClaudeCodeNotInstalled, "claude-code-not-installed"),
            (ClaudeUsageFailed, "claude-usage-failed"),
            (ClaudeUsageNotUnderstood, "claude-usage-not-understood"),
            (StaleFromArchive, "stale-from-archive"),
        ];
        for (reason, code) in failures {
            let snapshot = CapacitySnapshot::disconnected(Provider::ClaudeCode, reported_at(), reason);
            let report = DiagnosticReport::new("0.1.0", "26.6.2", reported_at(), vec![ProviderDiagnostic::from_snapshot(&snapshot, 0)], vec![]).text();
            assert!(report.contains(&format!("reason {code}")), "{code} should be reportable:\n{report}");
        }
    }

    #[test]
    fn the_report_says_what_a_maintainer_needs_to_know() {
        let snapshot = CapacitySnapshot {
            provider: Provider::Codex,
            captured_at: reported_at(),
            windows: vec![QuotaWindow::new("a", "5 hour", Some(300), 0.5, None)],
            connection_state: ConnectionState::Fresh,
            status_reason: None,
        };
        let report = DiagnosticReport::new(
            "0.1.0",
            "26.6.2",
            reported_at(),
            vec![ProviderDiagnostic::from_snapshot(&snapshot, 2)],
            vec!["claude-bridge-snapshot-missing".into()],
        )
        .text();
        for expected in ["CapaTheNotch 0.1.0", "macOS 26.6.2", "generated 2023-11-14", "codex:", "state fresh", "windows 1", "retries 2", "note claude-bridge-snapshot-missing"] {
            assert!(report.contains(expected), "It should carry \"{expected}\":\n{report}");
        }
    }

    #[test]
    fn a_report_from_another_system_says_which() {
        let report = DiagnosticReport::new("0.3.1", "6.12", reported_at(), vec![], vec![]).with_system_name("Linux").text();
        assert!(report.starts_with("CapaTheNotch 0.3.1\nLinux 6.12\ngenerated 2023-11-14T22:13:20Z"), "{report}");
    }

    #[test]
    fn a_report_lays_out_each_provider_in_the_order_given() {
        let a = CapacitySnapshot::disconnected(Provider::OpenCode, reported_at(), CapacityStatusReason::OpenCodeNotSignedIn);
        let b = CapacitySnapshot::disconnected(Provider::Codex, reported_at(), CapacityStatusReason::ProviderNotInstalled);
        let report = DiagnosticReport::new("1", "2", reported_at(), vec![ProviderDiagnostic::from_snapshot(&a, 0), ProviderDiagnostic::from_snapshot(&b, 0)], vec![]).text();
        assert!(report.find("openCode:").unwrap() < report.find("codex:").unwrap());
        assert!(!report.contains("retries"), "no retries, no line");
    }

    #[test]
    fn the_states_have_words() {
        use ConnectionState::*;
        let all = [Mock, Connecting, Fresh, Stale, Disconnected(CapacityStatusReason::ProviderNotInstalled)];
        let words: Vec<_> = all.iter().map(ConnectionState::diagnostic_code).collect();
        assert_eq!(words, ["mock", "connecting", "fresh", "stale", "disconnected"]);
    }
}
