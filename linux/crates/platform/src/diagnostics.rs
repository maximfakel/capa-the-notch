//! The diagnostic log and the report (`DiagnosticLog.swift`). Off unless asked:
//! a diagnostic nobody requested is a log nobody consented to. When on, the
//! application's own lines go in order to a file in the state folder, one per
//! event, in the closed vocabulary `DiagnosticEvent` allows — states, counts
//! and codes, never text a person wrote or said.

use capa_core::diagnostics::{DiagnosticEvent, DiagnosticReport, ProviderDiagnostic};
use capa_core::CapacitySnapshot;
use chrono::{DateTime, Utc};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

pub struct DiagnosticLog {
    path: PathBuf,
    enabled: Box<dyn Fn() -> bool + Send + Sync>,
    system_name: &'static str,
    /// Written in order, from any thread.
    lock: Mutex<()>,
}

impl DiagnosticLog {
    /// `capacity-notch.log` in the state folder, as the Swift one's name.
    pub fn default_path() -> PathBuf {
        capa_core::dirs::state(&capa_core::dirs::home()).join("capacity-notch.log")
    }

    pub fn new(path: PathBuf, enabled: Box<dyn Fn() -> bool + Send + Sync>) -> Self {
        Self { path, enabled, system_name: crate::system_name(), lock: Mutex::new(()) }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// The file, made if need be: where a Provider's own output may be sent too.
    pub fn prepare(&self) -> Option<&Path> {
        if let Some(dir) = self.path.parent() {
            std::fs::create_dir_all(dir).ok()?;
        }
        if !self.path.exists() {
            std::fs::File::create(&self.path).ok()?;
        }
        Some(&self.path)
    }

    /// The application's own line, and only while the log is on.
    pub fn record(&self, event: &DiagnosticEvent, at: DateTime<Utc>) {
        if !(self.enabled)() {
            return;
        }
        let line = format!("{}\n", event.entry_for(at, self.system_name));
        let _guard = self.lock.lock().unwrap();
        if self.prepare().is_none() {
            return;
        }
        if let Ok(mut file) = std::fs::OpenOptions::new().append(true).open(&self.path) {
            let _ = file.write_all(line.as_bytes());
        }
    }
}

/// The text of a bug report: versions, each Provider's state, and what the
/// Modules observed. Everything in it is a code, and the whole is scrubbed.
pub fn report(
    application_version: &str,
    snapshots: &[(CapacitySnapshot, u32)],
    observations: Vec<String>,
    at: DateTime<Utc>,
) -> String {
    DiagnosticReport::new(
        application_version,
        crate::system_version(),
        at,
        snapshots.iter().map(|(s, failures)| ProviderDiagnostic::from_snapshot(s, *failures)).collect(),
        observations,
    )
    .with_system_name(crate::system_name())
    .text()
}

#[cfg(test)]
mod tests {
    use super::*;
    use capa_core::{CapacityStatusReason, Provider};
    use chrono::TimeZone;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;

    fn at() -> DateTime<Utc> {
        Utc.timestamp_opt(1_700_000_000, 0).unwrap()
    }

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("capa-log-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        dir.join("capacity-notch.log")
    }

    #[test]
    fn nothing_is_written_while_the_log_is_off_and_lines_follow_in_order_once_on() {
        let on = Arc::new(AtomicBool::new(false));
        let flag = on.clone();
        let log = DiagnosticLog::new(scratch("order"), Box::new(move || flag.load(Ordering::SeqCst)));
        let launched = DiagnosticEvent::Launched { version: "0.3.1".into(), system: "x".into() };
        log.record(&launched, at());
        assert!(!log.path().exists(), "a diagnostic nobody requested is a log nobody consented to");

        on.store(true, Ordering::SeqCst);
        log.record(&launched, at());
        log.record(&DiagnosticEvent::DictationDownloadStarted, at());
        let text = std::fs::read_to_string(log.path()).unwrap();
        let lines: Vec<_> = text.lines().collect();
        assert_eq!(lines.len(), 2);
        assert!(lines[0].contains("launched 0.3.1"), "{text}");
        assert!(lines[0].contains(crate::system_name()), "the line names this system, not macOS: {text}");
        assert!(lines[1].contains("dictation download started"));
        assert!(lines[0].starts_with("2023-11-14T22:13:20Z"), "{text}");
    }

    #[test]
    fn prepare_makes_the_file_for_a_providers_own_output() {
        let log = DiagnosticLog::new(scratch("prepare"), Box::new(|| true));
        let path = log.prepare().unwrap().to_path_buf();
        assert!(path.exists());
        assert_eq!(std::fs::metadata(path).unwrap().len(), 0);
    }

    #[test]
    fn a_report_names_the_system_and_carries_codes_not_sentences() {
        let snapshot = CapacitySnapshot::disconnected(
            Provider::Codex,
            at(),
            CapacityStatusReason::ProviderUnavailable("it said token sk-1234567890abcdef1234567890abcdef".into()),
        );
        let text = report("0.3.1", &[(snapshot, 3)], vec!["shelf-clipboard-refused".into()], at());
        assert!(text.starts_with("CapaTheNotch 0.3.1\n"));
        assert!(text.contains(crate::system_name()));
        assert!(text.contains("codex:") && text.contains("reason provider-unavailable") && text.contains("retries 3"), "{text}");
        assert!(text.contains("note shelf-clipboard-refused"));
        assert!(!text.contains("sk-1234"), "a Provider's own words never reach a report: {text}");
    }
}
