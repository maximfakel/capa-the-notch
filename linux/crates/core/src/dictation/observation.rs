use super::platform::MicrophonePermission;

/// What a bug report says about the Dictation Module: whether it is on, has
/// its model, may hear and may insert — and whether the build it runs in could
/// ever be allowed the microphone (a Mac entitlement; true elsewhere).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DictationObservation {
    pub enabled: bool,
    pub model_ready: bool,
    pub microphone: MicrophonePermission,
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
            format!("mic-{}", self.microphone.raw()),
            if self.insertion_allowed { "insertion-allowed" } else { "insertion-not-allowed" }.to_owned(),
        ];
        if !self.microphone_entitled {
            codes.push("mic-not-entitled".into());
        }
        codes
    }

    /// The same codes as a report's notes, each under the 32 characters a
    /// redaction would rub out as an opaque secret.
    pub fn observations(&self) -> Vec<String> {
        self.codes().into_iter().map(|c| format!("dictation-{c}")).collect()
    }

    /// The same, as the diagnostic log's event (`DiagnosticEvent::Dictation`),
    /// which `AppDelegate` records at launch after `launched`.
    pub fn diagnostic(&self) -> crate::diagnostics::DictationObservation {
        use crate::diagnostics::MicrophoneAuthorization as Authorization;
        crate::diagnostics::DictationObservation {
            enabled: self.enabled,
            model_ready: self.model_ready,
            microphone: match self.microphone {
                MicrophonePermission::NotDetermined => Authorization::NotDetermined,
                MicrophonePermission::Restricted => Authorization::Restricted,
                MicrophonePermission::Denied => Authorization::Denied,
                MicrophonePermission::Authorized => Authorization::Authorized,
            },
            microphone_entitled: self.microphone_entitled,
            insertion_allowed: self.insertion_allowed,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn on() -> DictationObservation {
        DictationObservation {
            enabled: true,
            model_ready: true,
            microphone: MicrophonePermission::Authorized,
            microphone_entitled: true,
            insertion_allowed: false,
        }
    }

    #[test]
    fn a_report_says_off_or_what_is_missing() {
        assert_eq!(DictationObservation { enabled: false, ..on() }.codes(), ["off"]);
        assert_eq!(on().codes(), ["model-ready", "mic-authorized", "insertion-not-allowed"]);
        let blocked = DictationObservation {
            model_ready: false,
            microphone: MicrophonePermission::NotDetermined,
            microphone_entitled: false,
            ..on()
        };
        assert_eq!(blocked.codes(), ["model-missing", "mic-not-determined", "insertion-not-allowed", "mic-not-entitled"]);
    }

    #[test]
    fn the_log_says_what_the_report_says() {
        for o in [
            on(),
            DictationObservation { enabled: false, ..on() },
            DictationObservation { microphone: MicrophonePermission::NotDetermined, microphone_entitled: false, model_ready: false, ..on() },
            DictationObservation { microphone: MicrophonePermission::Denied, insertion_allowed: true, ..on() },
            DictationObservation { microphone: MicrophonePermission::Restricted, ..on() },
        ] {
            assert_eq!(o.diagnostic().codes(), o.codes());
            assert_eq!(o.diagnostic().observations(), o.observations());
        }
        // Swift's `DictationObservation.codes`, word for word.
        assert_eq!(
            crate::diagnostics::DiagnosticEvent::Dictation(on().diagnostic()).line(),
            "dictation model-ready mic-authorized insertion-not-allowed"
        );
    }

    #[test]
    fn every_note_is_under_the_redaction_length() {
        for o in [
            on(),
            DictationObservation { microphone: MicrophonePermission::NotDetermined, microphone_entitled: false, model_ready: false, ..on() },
        ] {
            for note in o.observations() {
                assert!(note.len() < 32, "{note}");
                assert!(note.starts_with("dictation-"));
            }
        }
    }
}
