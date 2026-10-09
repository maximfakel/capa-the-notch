use super::redaction::Redaction;
use super::report::timestamp;
use chrono::{DateTime, Utc};

/// A line the application writes to its own diagnostic log.
///
/// Held to the report's rule: a closed vocabulary of states, counts and codes.
/// An error is kept as its domain and code, never its description, and nothing
/// dictated — no audio, no recognised text — has a case here.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DiagnosticEvent {
    Launched { version: String, system: String },
    Dictation(DictationObservation),
    DictationDownloadStarted,
    DictationDownloadAnswered { status: i64, bytes: i64 },
    DictationDownloadProgress { percent: i64 },
    DictationDownloadFailed(DiagnosticError),
    DictationDownloadCancelled,
    DictationInstallFailed(DiagnosticError),
    DictationModelInstalled,
    MicrophoneRequested(MicrophoneAuthorization),
    MicrophoneAnswered { granted: bool, now: MicrophoneAuthorization },
    MicrophoneSettingsOpened(MicrophoneAuthorization),
    MicrophoneStartFailed(DiagnosticError),
    RecordingStarted(AudioInput),
    MicrophoneInputChanged(Option<AudioInput>),
    RecordingStopped { samples: i64 },
    RecordingRefused { reason: String },
    RecognitionFinished { samples: i64, empty: bool },
    RecognitionFailed(DiagnosticError),
    Delivered { inserted: bool },
}

impl DiagnosticEvent {
    /// The event in words. `system_name` is the platform's name as the report
    /// writes it ("macOS", "Linux").
    pub fn line_for(&self, system_name: &str) -> String {
        use DiagnosticEvent::*;
        match self {
            Launched { version, system } => format!("launched {version} {system_name} {system}"),
            Dictation(state) => format!("dictation {}", state.codes().join(" ")),
            DictationDownloadStarted => "dictation download started".into(),
            DictationDownloadAnswered { status, bytes } => format!("dictation download answered {status} bytes {bytes}"),
            DictationDownloadProgress { percent } => format!("dictation download {percent}%"),
            DictationDownloadFailed(error) => format!("dictation download failed {}", error.code()),
            DictationDownloadCancelled => "dictation download cancelled".into(),
            DictationInstallFailed(error) => format!("dictation install failed {}", error.code()),
            DictationModelInstalled => "dictation model installed".into(),
            MicrophoneRequested(status) => format!("microphone requested from {}", status.raw_value()),
            MicrophoneAnswered { granted, now } => {
                format!("microphone answered {} now {}", if *granted { "granted" } else { "refused" }, now.raw_value())
            }
            MicrophoneSettingsOpened(status) => format!("microphone settings opened at {}", status.raw_value()),
            MicrophoneStartFailed(error) => format!("microphone start failed {}", error.code()),
            RecordingStarted(input) => format!("recording started {}", input.code()),
            MicrophoneInputChanged(input) => {
                format!("microphone input changed {}", input.as_ref().map(AudioInput::code).unwrap_or_else(|| "and could not restart".into()))
            }
            RecordingStopped { samples } => format!("recording stopped samples {samples}"),
            RecordingRefused { reason } => format!("recording refused {reason}"),
            RecognitionFinished { samples, empty } => {
                format!("recognition finished samples {samples}{}", if *empty { " empty" } else { "" })
            }
            RecognitionFailed(error) => format!("recognition failed {}", error.code()),
            Delivered { inserted } => format!("delivered {}", if *inserted { "inserted" } else { "copied" }),
        }
    }

    /// The line as the macOS app writes it.
    pub fn line(&self) -> String {
        self.line_for("macOS")
    }

    /// One log line: the time, then the event, scrubbed like a report.
    pub fn entry(&self, at: DateTime<Utc>) -> String {
        self.entry_for(at, "macOS")
    }

    pub fn entry_for(&self, at: DateTime<Utc>, system_name: &str) -> String {
        Redaction::scrub(&format!("{} capacity-notch {}", timestamp(at), self.line_for(system_name)))
    }
}

/// An error as a log may carry it: where it came from and its number.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiagnosticError {
    pub domain: String,
    pub number: i64,
}

impl DiagnosticError {
    pub fn new(domain: impl Into<String>, number: i64) -> Self {
        Self { domain: domain.into(), number }
    }

    pub fn code(&self) -> String {
        format!("{} {}", self.domain, self.number)
    }
}

/// The input's shape, which tells a Bluetooth headset (16 kHz, one channel)
/// from the computer's microphones without naming any device.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AudioInput {
    pub sample_rate: u32,
    pub channels: u32,
}

impl AudioInput {
    pub fn new(sample_rate: u32, channels: u32) -> Self {
        Self { sample_rate, channels }
    }

    pub fn code(&self) -> String {
        format!("{}Hz {}ch", self.sample_rate, self.channels)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MicrophoneAuthorization {
    NotDetermined,
    Restricted,
    Denied,
    Authorized,
}

impl MicrophoneAuthorization {
    /// The words a log carries; Swift's raw values.
    pub fn raw_value(self) -> &'static str {
        match self {
            MicrophoneAuthorization::NotDetermined => "not-determined",
            MicrophoneAuthorization::Restricted => "restricted",
            MicrophoneAuthorization::Denied => "denied",
            MicrophoneAuthorization::Authorized => "authorized",
        }
    }
}

/// What a report says about the Dictation Module: whether it is on, has its
/// model, may hear and may insert — and whether the build it runs in could
/// ever be allowed the microphone.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DictationObservation {
    pub enabled: bool,
    pub model_ready: bool,
    pub microphone: MicrophoneAuthorization,
    pub microphone_entitled: bool,
    pub insertion_allowed: bool,
}

impl DictationObservation {
    pub fn codes(&self) -> Vec<String> {
        if !self.enabled {
            return vec!["off".into()];
        }
        let mut codes = vec![
            if self.model_ready { "model-ready" } else { "model-missing" }.to_owned(),
            format!("mic-{}", self.microphone.raw_value()),
            if self.insertion_allowed { "insertion-allowed" } else { "insertion-not-allowed" }.to_owned(),
        ];
        if !self.microphone_entitled {
            codes.push("mic-not-entitled".into());
        }
        codes
    }

    /// The same codes as a report's notes, each under the 32 characters
    /// `Redaction` would rub out as an opaque secret.
    pub fn observations(&self) -> Vec<String> {
        self.codes().into_iter().map(|c| format!("dictation-{c}")).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::super::report::{DiagnosticReport, ProviderDiagnostic};
    use super::*;
    use chrono::TimeZone;

    fn epoch() -> DateTime<Utc> {
        Utc.timestamp_opt(0, 0).unwrap()
    }

    #[test]
    fn dictation_states_reach_the_report_whole() {
        let state = DictationObservation {
            enabled: true,
            model_ready: false,
            microphone: MicrophoneAuthorization::NotDetermined,
            microphone_entitled: false,
            insertion_allowed: false,
        };
        let report = DiagnosticReport::new("0.2.1", "26.4", epoch(), Vec::<ProviderDiagnostic>::new(), state.observations()).text();
        for note in state.observations() {
            assert!(report.contains(&format!("note {note}")), "{note} must survive Redaction, which rubs out runs of 32 characters");
        }
        assert!(state.observations().contains(&"dictation-mic-not-entitled".to_owned()), "A build that can never ask for the microphone says so");
        let off = DictationObservation {
            enabled: false,
            model_ready: true,
            microphone: MicrophoneAuthorization::Authorized,
            microphone_entitled: true,
            insertion_allowed: true,
        };
        assert_eq!(off.observations(), ["dictation-off"], "An off Module says only that");
    }

    #[test]
    fn every_dictation_note_is_under_the_redaction_line() {
        for microphone in [MicrophoneAuthorization::NotDetermined, MicrophoneAuthorization::Restricted, MicrophoneAuthorization::Denied, MicrophoneAuthorization::Authorized] {
            let state = DictationObservation { enabled: true, model_ready: true, microphone, microphone_entitled: false, insertion_allowed: false };
            for note in state.observations() {
                assert!(note.len() < 32, "{note}");
                assert_eq!(Redaction::scrub(&note), note);
            }
        }
    }

    #[test]
    fn a_log_line_carries_codes_and_never_descriptions() {
        // An error is its domain and code, whatever the failing request carried.
        let timeout = DiagnosticError::new("NSURLErrorDomain", -1001);
        let line = DiagnosticEvent::DictationDownloadFailed(timeout).entry(epoch());
        assert_eq!(line, "1970-01-01T00:00:00Z capacity-notch dictation download failed NSURLErrorDomain -1001", "An error is its domain and code: {line}");
        let answered = DiagnosticEvent::MicrophoneAnswered { granted: false, now: MicrophoneAuthorization::NotDetermined }.line();
        assert_eq!(answered, "microphone answered refused now not-determined", "A refusal without a prompt is visible: {answered}");
        let headset = AudioInput::new(16_000, 1);
        assert_eq!(DiagnosticEvent::RecordingStarted(headset).line(), "recording started 16000Hz 1ch", "The input's shape, not its name");
        assert_eq!(DiagnosticEvent::MicrophoneInputChanged(None).line(), "microphone input changed and could not restart", "A lost input says so");
        assert_eq!(DiagnosticEvent::RecordingStopped { samples: 0 }.line(), "recording stopped samples 0", "Silence is visible before recognition");
    }

    #[test]
    fn every_event_has_its_words() {
        use DiagnosticEvent::*;
        let error = DiagnosticError::new("D", 7);
        let cases: Vec<(DiagnosticEvent, &str)> = vec![
            (Launched { version: "0.3.1".into(), system: "26.6".into() }, "launched 0.3.1 macOS 26.6"),
            (DictationDownloadStarted, "dictation download started"),
            (DictationDownloadAnswered { status: 200, bytes: 170_000_000 }, "dictation download answered 200 bytes 170000000"),
            (DictationDownloadProgress { percent: 42 }, "dictation download 42%"),
            (DictationDownloadCancelled, "dictation download cancelled"),
            (DictationInstallFailed(error.clone()), "dictation install failed D 7"),
            (DictationModelInstalled, "dictation model installed"),
            (MicrophoneRequested(MicrophoneAuthorization::Denied), "microphone requested from denied"),
            (MicrophoneSettingsOpened(MicrophoneAuthorization::Restricted), "microphone settings opened at restricted"),
            (MicrophoneStartFailed(error.clone()), "microphone start failed D 7"),
            (MicrophoneInputChanged(Some(AudioInput::new(48_000, 2))), "microphone input changed 48000Hz 2ch"),
            (RecordingRefused { reason: "no-model".into() }, "recording refused no-model"),
            (RecognitionFinished { samples: 100, empty: true }, "recognition finished samples 100 empty"),
            (RecognitionFinished { samples: 100, empty: false }, "recognition finished samples 100"),
            (RecognitionFailed(error), "recognition failed D 7"),
            (Delivered { inserted: true }, "delivered inserted"),
            (Delivered { inserted: false }, "delivered copied"),
        ];
        for (event, expected) in cases {
            assert_eq!(event.line(), expected);
        }
        let observation = DictationObservation { enabled: true, model_ready: true, microphone: MicrophoneAuthorization::Authorized, microphone_entitled: true, insertion_allowed: true };
        assert_eq!(Dictation(observation).line(), "dictation model-ready mic-authorized insertion-allowed");
    }

    #[test]
    fn a_log_line_names_the_system_it_came_from_and_is_scrubbed() {
        let launched = DiagnosticEvent::Launched { version: "0.3.1".into(), system: "6.12".into() };
        assert_eq!(launched.line_for("Linux"), "launched 0.3.1 Linux 6.12");
        let leaky = DiagnosticEvent::RecordingRefused { reason: "/Users/jordanlee/x".into() };
        assert_eq!(leaky.entry(epoch()), "1970-01-01T00:00:00Z capacity-notch recording refused ~/x");
    }
}
