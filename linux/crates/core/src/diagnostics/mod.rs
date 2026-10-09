//! Port of `Diagnostics.swift` and `DiagnosticEvent.swift`: what a bug report
//! and the diagnostic log may contain.
//!
//! The safety here is structural, not textual. A report is assembled from
//! closed vocabularies — enumerations, counts, dates, version strings — and no
//! Provider's own words ever reach it. A blocklist can only catch the shapes
//! somebody thought of; a report that cannot hold free text cannot leak one.
//!
//! [`redaction::scrub`] runs over the finished text as a second line, for the
//! version strings and paths that do come from outside.

mod event;
pub mod redaction;
mod report;

pub use event::{AudioInput, DiagnosticError, DiagnosticEvent, DictationObservation, MicrophoneAuthorization};
pub use redaction::Redaction;
pub use report::{timestamp, DiagnosticReport, ProviderDiagnostic};

/// Where `record` writes: the application's diagnostic log, set once by the
/// hub at launch. Unset — a test, a tool — a line goes nowhere.
type Recorder = std::sync::Arc<dyn Fn(&DiagnosticEvent) + Send + Sync>;

static RECORDER: std::sync::RwLock<Option<Recorder>> =
    std::sync::RwLock::new(None);

/// Puts a line in the diagnostic log, from anywhere — a Module's driver
/// included — as Swift's `DiagnosticLog.record(_:)` does. Written only while
/// the person keeps the log; the hub decides that.
pub fn record(event: &DiagnosticEvent) {
    let recorder = RECORDER.read().unwrap_or_else(|e| e.into_inner()).clone();
    if let Some(recorder) = recorder {
        recorder(event);
    }
}

/// The hub's: where `record` goes from now on.
pub fn set_recorder(recorder: std::sync::Arc<dyn Fn(&DiagnosticEvent) + Send + Sync>) {
    *RECORDER.write().unwrap_or_else(|e| e.into_inner()) = Some(recorder);
}
