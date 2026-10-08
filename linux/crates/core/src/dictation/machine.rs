//! Dictation's decisions — what the Swift `DictationController` decides, with
//! its hands taken off the operating system.
//!
//! The machine owns state and nothing else. Every call is an event (a key, a
//! tick, a result arriving) and returns the `Effect`s the platform must carry
//! out; the platform reports what happened by calling the next method. So the
//! whole flow — refusal, recording, cutting off at sixty seconds, a cancelled
//! recognition that must never deliver, a failure that hides itself, a copy
//! that could not insert — is tested here with no microphone and no window.

use super::capsule::{Presentation, QUIET_ERROR_SECONDS, SUCCESS_SECONDS};
use super::history::DictationHistory;
use super::messages::*;
use super::model::DownloadProgress;
use super::observation::DictationObservation;
use super::platform::{MicrophoneInput, MicrophonePermission, RecognitionError};
use super::replacement::DictationReplacement;
use super::session::{DictationSession, Phase, SessionId};
use crate::prefs::KeyShortcut;
use chrono::{DateTime, Utc};
use serde::Serialize;
use std::time::Duration;

/// The moments Dictation sounds (ADR 0007); the words are `SoundCue`'s.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Cue {
    DictationModelReady,
    DictationInserted,
    DictationCopied,
    DictationFailed,
}

/// What the diagnostic log hears about Dictation: codes, counts and states,
/// never the audio and never what was said.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LogEvent {
    RecordingRefused { reason: String },
    RecordingStarted(MicrophoneInput),
    RecordingStopped { samples: usize },
    MicrophoneStartFailed,
    MicrophoneInputChanged(Option<MicrophoneInput>),
    RecognitionFinished { samples: usize, empty: bool },
    RecognitionFailed,
    Delivered { inserted: bool },
    DownloadStarted,
    DownloadProgress { percent: u32 },
    DownloadAnswered { status: u16, bytes: u64 },
    DownloadCancelled,
    DownloadFailed,
    InstallFailed,
    ModelInstalled,
}

/// What the platform must do.
#[derive(Debug, Clone, PartialEq)]
pub enum Effect {
    /// Capture the application in front, before anything appears.
    CaptureTarget,
    /// Open the microphone; answer with `microphone_started` or `microphone_failed`.
    StartMicrophone(SessionId),
    /// Tick once a second while recording, with the seconds elapsed, to
    /// `clock_tick`.
    StartClock(SessionId),
    StopClock,
    /// Stop the microphone and take its samples; then recognise them and
    /// answer with `recognition_finished`.
    StopAndRecognise(SessionId),
    /// A recognition under way is of no use any more: give it up.
    CancelRecognition,
    /// Stop the microphone and drop the samples.
    StopMicrophone,
    /// Put the text on the clipboard, as the application's own.
    CopyToClipboard(String),
    /// Insert the text where the cursor was; answer with `delivery_finished`.
    Deliver(String),
    /// Escape cancels, while it is registered.
    CaptureEscape(bool),
    /// Register the shortcut (`None`: unregister); answer with `shortcut_registered`.
    RegisterShortcut(Option<KeyShortcut>),
    /// Call `dismiss_elapsed(token)` after this long. A new schedule or a
    /// `CancelDismiss` makes an earlier token stale.
    ScheduleDismiss { token: u64, after: Duration },
    CancelDismiss,
    PlaySound(Cue),
    Log(LogEvent),
    /// Keep these (the Preferences' `dictation.*` keys).
    PersistEnabled(bool),
    PersistShortcut,
    PersistHistory,
    PersistReplacements,
    PersistKeepsHistory,
    /// Start the model download (`model::source_url`).
    StartDownload,
    CancelDownload,
    /// Let the loaded model go.
    UnloadRecogniser,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum DismissKind {
    /// After a delivery: simply hide.
    AfterDelivery,
    /// After a failure that needs nothing from the person: hide, if it is
    /// still the failure on show.
    QuietError,
}

pub struct Dictation {
    registers_shortcuts: bool,
    enabled: bool,
    presentation: Presentation,
    level: f32,
    remaining: u32,
    error: Option<String>,
    delivery_message: Option<String>,
    model_ready: bool,
    microphone: MicrophonePermission,
    microphone_entitled: bool,
    insertion_allowed: bool,
    shortcut_unavailable: bool,
    keeps_history: bool,
    replacements: Vec<DictationReplacement>,
    history: DictationHistory,
    shortcut: KeyShortcut,
    shortcut_suspended: bool,
    key_held: bool,
    session: DictationSession,
    /// The rules as they were when the recording began: a rule edited while
    /// speaking applies to the next dictation.
    session_replacements: Vec<DictationReplacement>,
    /// Whether an application was captured to deliver to, and if not why.
    target: Option<()>,
    capture_failure: Option<String>,
    /// The text on its way to the cursor.
    delivering: Option<String>,
    help: MicrophoneHelp,
    download: Option<DownloadProgress>,
    dismiss: Option<(u64, DismissKind)>,
    dismiss_serial: u64,
}

/// What a person has chosen, loaded from the Preferences when the machine is made.
pub struct Settings {
    pub enabled: bool,
    pub keeps_history: bool,
    pub replacements: Vec<DictationReplacement>,
    pub history: DictationHistory,
    pub shortcut: KeyShortcut,
    pub model_ready: bool,
    pub microphone: MicrophonePermission,
    pub microphone_entitled: bool,
    pub insertion_allowed: bool,
    pub help: MicrophoneHelp,
    /// False for the screenshot fixture, which shows states without recording.
    pub registers_shortcuts: bool,
}

impl Dictation {
    pub fn new(settings: Settings) -> Self {
        Self {
            registers_shortcuts: settings.registers_shortcuts,
            enabled: settings.enabled,
            presentation: Presentation::Hidden,
            level: 0.0,
            remaining: DictationSession::MAXIMUM_DURATION_SECONDS,
            error: None,
            delivery_message: None,
            model_ready: settings.model_ready,
            microphone: settings.microphone,
            microphone_entitled: settings.microphone_entitled,
            insertion_allowed: settings.insertion_allowed,
            shortcut_unavailable: false,
            keeps_history: settings.keeps_history,
            replacements: settings.replacements,
            history: settings.history,
            shortcut: settings.shortcut,
            shortcut_suspended: false,
            key_held: false,
            session: DictationSession::new(),
            session_replacements: Vec::new(),
            target: None,
            capture_failure: None,
            delivering: None,
            help: settings.help,
            download: None,
            dismiss: None,
            dismiss_serial: 0,
        }
    }

    // MARK: - What a surface reads

    pub fn is_enabled(&self) -> bool {
        self.enabled
    }
    pub fn presentation(&self) -> Presentation {
        self.presentation
    }
    /// 0 to 1; nothing but a recording has any.
    pub fn level(&self) -> f32 {
        self.level
    }
    /// Seconds left of the sixty.
    pub fn remaining(&self) -> u32 {
        self.remaining
    }
    pub fn error(&self) -> Option<&str> {
        self.error.as_deref()
    }
    pub fn delivery_message(&self) -> Option<&str> {
        self.delivery_message.as_deref()
    }
    pub fn model_ready(&self) -> bool {
        self.model_ready
    }
    pub fn download_progress(&self) -> Option<&DownloadProgress> {
        self.download.as_ref()
    }
    pub fn microphone_allowed(&self) -> bool {
        self.microphone == MicrophonePermission::Authorized
    }
    pub fn insertion_allowed(&self) -> bool {
        self.insertion_allowed
    }
    pub fn shortcut_unavailable(&self) -> bool {
        self.shortcut_unavailable
    }
    pub fn keeps_history(&self) -> bool {
        self.keeps_history
    }
    pub fn replacements(&self) -> &[DictationReplacement] {
        &self.replacements
    }
    pub fn history(&self) -> &DictationHistory {
        &self.history
    }
    pub fn shortcut(&self) -> &KeyShortcut {
        &self.shortcut
    }
    pub fn phase(&self) -> Phase {
        self.session.phase()
    }

    /// What a bug report and the log say about Dictation.
    pub fn observation(&self) -> DictationObservation {
        DictationObservation {
            enabled: self.enabled,
            model_ready: self.model_ready,
            microphone: self.microphone,
            microphone_entitled: self.microphone_entitled,
            insertion_allowed: self.insertion_allowed,
        }
    }

    // MARK: - What the system says

    /// Read again when the application becomes active, and before a recording.
    pub fn set_permissions(&mut self, microphone: MicrophonePermission, insertion_allowed: bool) {
        self.microphone = microphone;
        self.insertion_allowed = insertion_allowed;
    }

    /// Only the screenshot fixture can set a display state without recording.
    pub fn preview(&mut self, state: Presentation, level: f32) {
        if self.registers_shortcuts {
            return;
        }
        self.model_ready = true;
        self.microphone = MicrophonePermission::Authorized;
        self.insertion_allowed = true;
        self.presentation = state;
        self.level = level;
        self.remaining = 8;
    }

    /// The system is going to sleep: nothing held survives it.
    pub fn system_will_sleep(&mut self) -> Vec<Effect> {
        self.key_held = false;
        self.cancel()
    }

    /// The model is on disk (or is not), as found when the application starts.
    pub fn set_model_ready(&mut self, ready: bool) {
        self.model_ready = ready;
    }

    // MARK: - Switching on and off

    pub fn set_enabled(&mut self, enabled: bool) -> Vec<Effect> {
        self.enabled = enabled;
        let mut effects = vec![Effect::PersistEnabled(enabled)];
        if !enabled {
            self.key_held = false;
            effects.extend(self.cancel());
            effects.extend(self.cancel_download());
            effects.push(Effect::UnloadRecogniser);
        }
        effects.extend(self.register());
        effects
    }

    pub fn set_keeps_history(&mut self, keeps: bool) -> Vec<Effect> {
        self.keeps_history = keeps;
        vec![Effect::PersistKeepsHistory]
    }

    pub fn set_replacements(&mut self, replacements: Vec<DictationReplacement>) -> Vec<Effect> {
        self.replacements = replacements;
        vec![Effect::PersistReplacements]
    }

    pub fn set_shortcut(&mut self, shortcut: KeyShortcut) -> Vec<Effect> {
        self.shortcut = shortcut;
        let mut effects = vec![Effect::PersistShortcut];
        effects.extend(self.register());
        effects
    }

    /// While the shortcut is being recorded in Settings it must not fire.
    pub fn suspend_shortcut(&mut self, suspend: bool) -> Vec<Effect> {
        self.shortcut_suspended = suspend;
        if suspend { vec![Effect::RegisterShortcut(None)] } else { self.register() }
    }

    fn register(&mut self) -> Vec<Effect> {
        if !self.registers_shortcuts {
            return vec![];
        }
        if !self.enabled || self.shortcut_suspended {
            return vec![Effect::RegisterShortcut(None)];
        }
        vec![Effect::RegisterShortcut(Some(self.shortcut.clone()))]
    }

    /// The system's answer to `RegisterShortcut(Some(_))`.
    pub fn shortcut_registered(&mut self, ok: bool) {
        self.shortcut_unavailable = !ok;
    }

    // MARK: - The key

    /// A held key owns one recording; a repeated key-down does not start another.
    pub fn key_pressed(&mut self) -> Vec<Effect> {
        if self.key_held {
            return vec![];
        }
        self.key_held = true;
        self.begin()
    }

    pub fn key_released(&mut self) -> Vec<Effect> {
        self.key_held = false;
        self.finish_recording()
    }

    /// Escape, while it is registered.
    pub fn escape_pressed(&mut self) -> Vec<Effect> {
        self.cancel()
    }

    // MARK: - Recording

    pub fn begin(&mut self) -> Vec<Effect> {
        if !self.enabled || self.session.phase() != Phase::Idle {
            return vec![];
        }
        // The platform has read the permissions again just before (`set_permissions`).
        if !self.model_ready {
            let mut effects = vec![Effect::Log(LogEvent::RecordingRefused { reason: "model-missing".into() })];
            effects.extend(self.fail(MODEL_MISSING, None));
            return effects;
        }
        if !self.microphone_allowed() {
            let mut effects = vec![Effect::Log(LogEvent::RecordingRefused { reason: format!("mic-{}", self.microphone.raw()) })];
            effects.extend(self.fail(self.help.required(), None));
            return effects;
        }
        let Some(id) = self.session.begin() else { return vec![] };
        self.session_replacements = self.replacements.clone();
        self.target = None;
        self.capture_failure = None;
        self.error = None;
        self.delivery_message = None;
        self.remaining = DictationSession::MAXIMUM_DURATION_SECONDS;
        self.dismiss = None;
        vec![Effect::CancelDismiss, Effect::CaptureTarget, Effect::StartMicrophone(id)]
    }

    /// What `CaptureTarget` found.
    pub fn target_captured(&mut self, captured: Result<(), String>) {
        match captured {
            Ok(()) => {
                self.target = Some(());
                self.capture_failure = None;
            }
            Err(why) => {
                self.target = None;
                self.capture_failure = Some(why);
            }
        }
    }

    /// The microphone opened: the capsule appears.
    pub fn microphone_started(&mut self, id: SessionId, input: MicrophoneInput) -> Vec<Effect> {
        if self.session.phase() != Phase::Recording(id) {
            // Cancelled while it was opening: it is of no use.
            return vec![Effect::StopMicrophone];
        }
        self.presentation = Presentation::Recording;
        vec![Effect::CaptureEscape(true), Effect::Log(LogEvent::RecordingStarted(input)), Effect::StartClock(id)]
    }

    /// The microphone would not open.
    pub fn microphone_failed(&mut self, id: SessionId) -> Vec<Effect> {
        if self.session.phase() != Phase::Recording(id) {
            return vec![];
        }
        let mut effects = vec![Effect::Log(LogEvent::MicrophoneStartFailed)];
        self.session.cancel();
        effects.extend(self.fail(MICROPHONE_COULD_NOT_START, None));
        effects
    }

    /// The level of the recording `id`, from the audio thread.
    pub fn level_changed(&mut self, id: SessionId, level: f32) {
        if self.session.phase() == Phase::Recording(id) {
            self.level = level;
        }
    }

    /// A second has passed; `elapsed` is how many, by the platform's own clock.
    pub fn clock_tick(&mut self, id: SessionId, elapsed: u32) -> Vec<Effect> {
        if self.session.phase() != Phase::Recording(id) {
            return vec![];
        }
        self.remaining = DictationSession::MAXIMUM_DURATION_SECONDS.saturating_sub(elapsed);
        if self.remaining == 0 { self.finish_recording() } else { vec![] }
    }

    /// The buffer filled its sixty seconds.
    pub fn recording_limit_reached(&mut self, id: SessionId) -> Vec<Effect> {
        if self.session.phase() != Phase::Recording(id) {
            return vec![];
        }
        self.finish_recording()
    }

    /// The default input changed during a recording. A new input is followed
    /// by the platform with what was heard kept; none at all ends the
    /// recording.
    pub fn microphone_input_changed(&mut self, input: Option<MicrophoneInput>) -> Vec<Effect> {
        if self.presentation != Presentation::Recording {
            return vec![];
        }
        let mut effects = vec![Effect::Log(LogEvent::MicrophoneInputChanged(input))];
        if input.is_none() {
            effects.extend(self.cancel());
            effects.extend(self.fail(MICROPHONE_CHANGED, None));
        }
        effects
    }

    pub fn finish_recording(&mut self) -> Vec<Effect> {
        let Some(id) = self.session.stop() else { return vec![] };
        self.presentation = Presentation::Recognizing;
        self.level = 0.0;
        vec![Effect::StopClock, Effect::StopAndRecognise(id)]
    }

    /// `StopAndRecognise` took `samples` off the microphone: the log hears it
    /// then, at the stop, whatever recognition later makes of them (Swift's
    /// `finishRecording`).
    pub fn recording_stopped(&self, samples: usize) -> Vec<Effect> {
        vec![Effect::Log(LogEvent::RecordingStopped { samples })]
    }

    // MARK: - Recognition and delivery

    /// What recognition made of the recording `id`: `samples` is how many were
    /// recognised, for the log.
    pub fn recognition_finished(
        &mut self,
        id: SessionId,
        samples: usize,
        result: Result<String, RecognitionError>,
        now: DateTime<Utc>,
    ) -> Vec<Effect> {
        // A cancelled or superseded recognition delivers nothing.
        if !self.session.complete(id) {
            return vec![];
        }
        let mut effects = Vec::new();
        match result {
            Ok(raw) => {
                let text = DictationReplacement::apply(&self.session_replacements, &raw);
                effects.push(Effect::Log(LogEvent::RecognitionFinished { samples, empty: text.is_empty() }));
                if text.is_empty() {
                    // Nothing to fix, only to try again, so it does not wait for Escape.
                    effects.extend(self.fail(NO_SPEECH_RECOGNISED, Some(QUIET_ERROR_SECONDS)));
                    return effects;
                }
                effects.push(Effect::CopyToClipboard(text.clone()));
                if self.target.take().is_some() {
                    self.delivering = Some(text.clone());
                    effects.push(Effect::Deliver(text));
                } else {
                    // Nothing to deliver to: it is on the clipboard, and the
                    // capsule says why it is not in the field.
                    let why = self.capture_failure.take().unwrap_or_else(|| NO_EXTERNAL_APPLICATION.into());
                    self.delivering = Some(text);
                    effects.extend(self.delivery_finished(Some(why), now));
                }
            }
            Err(error) => {
                effects.push(Effect::Log(LogEvent::RecognitionFailed));
                // Dictation's own failures are sentences with translations;
                // anything else is the system's wording, which the log keeps.
                let message = match &error {
                    RecognitionError::Dictation(failure) => failure.message().to_owned(),
                    RecognitionError::Other(_) => RECOGNITION_FAILED.to_owned(),
                };
                effects.extend(self.fail(&message, None));
            }
        }
        effects
    }

    /// What `Deliver` came to: `None` when the text went in, otherwise why not.
    ///
    /// A deliberate deviation: Swift's `finishRecording` falls through to the
    /// "No external application" sentence even when `insert` succeeds, so a
    /// successful insertion shows as copied there. Here a successful insertion
    /// is `Inserted`, as is evidently meant.
    pub fn delivery_finished(&mut self, message: Option<String>, now: DateTime<Utc>) -> Vec<Effect> {
        let Some(text) = self.delivering.take() else { return vec![] };
        let inserted = message.is_none();
        self.delivery_message = message;
        self.presentation = if inserted { Presentation::Inserted } else { Presentation::Copied };
        self.history.append(&text, self.keeps_history, now);
        let token = self.schedule_dismiss(DismissKind::AfterDelivery);
        vec![
            Effect::PlaySound(if inserted { Cue::DictationInserted } else { Cue::DictationCopied }),
            Effect::Log(LogEvent::Delivered { inserted }),
            Effect::CaptureEscape(false),
            Effect::PersistHistory,
            Effect::ScheduleDismiss { token, after: Duration::from_secs_f64(SUCCESS_SECONDS) },
        ]
    }

    // MARK: - Ending

    /// Escape, the system sleeping, switching off, or the capsule dismissed.
    pub fn cancel(&mut self) -> Vec<Effect> {
        self.session.cancel();
        self.dismiss = None;
        self.target = None;
        self.capture_failure = None;
        self.delivering = None;
        self.presentation = Presentation::Hidden;
        self.level = 0.0;
        vec![Effect::StopClock, Effect::CancelRecognition, Effect::CancelDismiss, Effect::StopMicrophone, Effect::CaptureEscape(false)]
    }

    fn fail(&mut self, message: &str, hides_after: Option<f64>) -> Vec<Effect> {
        // An earlier error's timer would hide this one early.
        self.dismiss = None;
        self.target = None;
        self.capture_failure = None;
        self.delivering = None;
        self.error = Some(message.to_owned());
        self.presentation = Presentation::Error;
        let mut effects = vec![Effect::CancelDismiss, Effect::CaptureEscape(true), Effect::PlaySound(Cue::DictationFailed)];
        if let Some(seconds) = hides_after {
            let token = self.schedule_dismiss(DismissKind::QuietError);
            effects.push(Effect::ScheduleDismiss { token, after: Duration::from_secs_f64(seconds) });
        }
        effects
    }

    fn schedule_dismiss(&mut self, kind: DismissKind) -> u64 {
        self.dismiss_serial += 1;
        self.dismiss = Some((self.dismiss_serial, kind));
        self.dismiss_serial
    }

    /// The time asked of `ScheduleDismiss` has passed.
    pub fn dismiss_elapsed(&mut self, token: u64) -> Vec<Effect> {
        match self.dismiss {
            Some((current, DismissKind::AfterDelivery)) if current == token => {
                self.dismiss = None;
                self.presentation = Presentation::Hidden;
                vec![]
            }
            Some((current, DismissKind::QuietError)) if current == token => {
                self.dismiss = None;
                if self.presentation != Presentation::Error {
                    return vec![];
                }
                self.presentation = Presentation::Hidden;
                vec![Effect::CaptureEscape(false)]
            }
            _ => vec![],
        }
    }

    // MARK: - History

    pub fn delete_history_entry(&mut self, id: u64) -> Vec<Effect> {
        self.history.delete(id);
        vec![Effect::PersistHistory]
    }

    pub fn clear_history(&mut self) -> Vec<Effect> {
        self.history.clear();
        vec![Effect::PersistHistory]
    }

    /// The history as another part of the application left it (Settings
    /// cleared it, or deleted an entry): taken as it is, and not written back,
    /// so what was removed there does not return with the next dictation.
    pub fn set_history(&mut self, history: DictationHistory) {
        self.history = history;
    }

    // MARK: - The model

    /// "Set up": the speech model, downloaded once and checked.
    pub fn start_download(&mut self) -> Vec<Effect> {
        if !self.enabled || self.download.is_some() {
            return vec![];
        }
        self.error = None;
        self.download = Some(DownloadProgress::started());
        vec![Effect::Log(LogEvent::DownloadStarted), Effect::StartDownload]
    }

    pub fn cancel_download(&mut self) -> Vec<Effect> {
        if self.download.is_some() { vec![Effect::CancelDownload] } else { vec![] }
    }

    /// Bytes arrived: a fraction from 0 to 1.
    pub fn download_progress_changed(&mut self, fraction: f64) -> Vec<Effect> {
        match self.download.as_mut().and_then(|d| d.advance(fraction)) {
            Some(percent) => vec![Effect::Log(LogEvent::DownloadProgress { percent })],
            None => vec![],
        }
    }

    /// The server answered. Anything but 200 is a failed download; see
    /// `download_failed`.
    pub fn download_answered(&mut self, status: u16, bytes: u64) -> Vec<Effect> {
        vec![Effect::Log(LogEvent::DownloadAnswered { status, bytes })]
    }

    /// Unpacked, hashed and in place.
    pub fn download_installed(&mut self) -> Vec<Effect> {
        self.download = None;
        self.model_ready = true;
        vec![Effect::PlaySound(Cue::DictationModelReady), Effect::Log(LogEvent::ModelInstalled)]
    }

    pub fn download_cancelled(&mut self) -> Vec<Effect> {
        self.download = None;
        vec![Effect::Log(LogEvent::DownloadCancelled)]
    }

    /// It failed — in the download itself, or (`installing`) once it was here.
    /// Whatever the reason, the person is told the same thing.
    pub fn download_failed(&mut self, installing: bool) -> Vec<Effect> {
        self.download = None;
        self.error = Some(DOWNLOAD_FAILED.into());
        vec![Effect::Log(if installing { LogEvent::InstallFailed } else { LogEvent::DownloadFailed })]
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::prefs::{default_dictation_shortcut, KeyShortcut};
    use chrono::TimeZone;

    fn now() -> DateTime<Utc> {
        Utc.timestamp_opt(1_700_000_000, 0).unwrap()
    }

    fn input() -> MicrophoneInput {
        MicrophoneInput { sample_rate: 16_000, channels: 1 }
    }

    fn settings() -> Settings {
        Settings {
            enabled: true,
            keeps_history: false,
            replacements: DictationReplacement::defaults(),
            history: DictationHistory::new(),
            shortcut: default_dictation_shortcut(),
            model_ready: true,
            microphone: MicrophonePermission::Authorized,
            microphone_entitled: true,
            insertion_allowed: true,
            help: MicrophoneHelp::Linux,
            registers_shortcuts: true,
        }
    }

    fn machine() -> Dictation {
        Dictation::new(settings())
    }

    /// Starts a recording the way the platform would, and returns its id.
    fn recording(d: &mut Dictation) -> SessionId {
        let effects = d.key_pressed();
        let Some(Effect::StartMicrophone(id)) = effects.iter().find(|e| matches!(e, Effect::StartMicrophone(_))).cloned() else {
            panic!("a recording should have started: {effects:?}");
        };
        d.target_captured(Ok(()));
        d.microphone_started(id, input());
        id
    }

    fn has(effects: &[Effect], wanted: &Effect) -> bool {
        effects.contains(wanted)
    }

    #[test]
    fn a_held_key_records_and_a_release_recognises() {
        let mut d = machine();
        assert_eq!(d.presentation(), Presentation::Hidden);
        let id = recording(&mut d);
        assert_eq!(d.presentation(), Presentation::Recording);
        assert_eq!(d.remaining(), 60);
        assert!(d.key_pressed().is_empty(), "a repeated key down does not start another recording");

        let effects = d.key_released();
        assert_eq!(effects, [Effect::StopClock, Effect::StopAndRecognise(id)]);
        assert_eq!(d.presentation(), Presentation::Recognizing);
        assert!(d.key_released().is_empty(), "a second release does not decode twice");
    }

    #[test]
    fn a_result_is_replaced_copied_delivered_and_the_capsule_leaves() {
        let mut d = machine();
        let id = recording(&mut d);
        d.key_released();
        let effects = d.recognition_finished(id, 16_000, Ok("сделай коммит".into()), now());
        assert!(has(&effects, &Effect::CopyToClipboard("сделай commit".into())), "replacements apply: {effects:?}");
        assert!(has(&effects, &Effect::Deliver("сделай commit".into())));

        let effects = d.delivery_finished(None, now());
        assert_eq!(d.presentation(), Presentation::Inserted);
        assert!(has(&effects, &Effect::PlaySound(Cue::DictationInserted)));
        assert!(has(&effects, &Effect::Log(LogEvent::Delivered { inserted: true })));
        assert!(has(&effects, &Effect::CaptureEscape(false)));
        let token = effects.iter().find_map(|e| match e {
            Effect::ScheduleDismiss { token, after } => {
                assert_eq!(*after, Duration::from_millis(1400));
                Some(*token)
            }
            _ => None,
        });
        d.dismiss_elapsed(token.unwrap());
        assert_eq!(d.presentation(), Presentation::Hidden);
        assert_eq!(d.delivery_message(), None);
    }

    #[test]
    fn text_that_could_not_go_in_is_copied_and_says_why() {
        let mut d = machine();
        let id = recording(&mut d);
        d.key_released();
        d.recognition_finished(id, 1, Ok("привет".into()), now());
        let effects = d.delivery_finished(Some(PASTE_FAILED.into()), now());
        assert_eq!(d.presentation(), Presentation::Copied);
        assert_eq!(d.delivery_message(), Some(PASTE_FAILED));
        assert!(has(&effects, &Effect::PlaySound(Cue::DictationCopied)));
    }

    #[test]
    fn with_no_application_captured_the_text_waits_on_the_clipboard() {
        let mut d = machine();
        let effects = d.key_pressed();
        let Some(Effect::StartMicrophone(id)) = effects.last().cloned() else { panic!() };
        d.target_captured(Err("Nothing in front".into()));
        d.microphone_started(id, input());
        d.key_released();
        let effects = d.recognition_finished(id, 1, Ok("привет".into()), now());
        assert!(has(&effects, &Effect::CopyToClipboard("привет".into())));
        assert!(!effects.iter().any(|e| matches!(e, Effect::Deliver(_))), "nowhere to deliver to");
        assert_eq!(d.presentation(), Presentation::Copied);
        assert_eq!(d.delivery_message(), Some("Nothing in front"));
    }

    #[test]
    fn with_no_reason_given_the_default_sentence_is_used() {
        let mut d = machine();
        let effects = d.key_pressed();
        let Some(Effect::StartMicrophone(id)) = effects.last().cloned() else { panic!() };
        d.microphone_started(id, input()); // never told whether a target was captured
        d.key_released();
        d.recognition_finished(id, 1, Ok("привет".into()), now());
        assert_eq!(d.delivery_message(), Some(NO_EXTERNAL_APPLICATION));
    }

    #[test]
    fn a_cancelled_recognition_never_delivers_and_an_old_one_cannot_complete_a_new_recording() {
        let mut d = machine();
        let first = recording(&mut d);
        d.key_released();
        let effects = d.escape_pressed();
        assert!(has(&effects, &Effect::CancelRecognition));
        assert_eq!(d.presentation(), Presentation::Hidden);
        assert!(d.recognition_finished(first, 1, Ok("поздно".into()), now()).is_empty(), "a cancelled decode must never deliver");

        let second = recording(&mut d);
        d.key_released();
        assert!(d.recognition_finished(first, 1, Ok("старый".into()), now()).is_empty(), "an old result cannot complete a new recording");
        assert!(!d.recognition_finished(second, 1, Ok("новый".into()), now()).is_empty());
        assert!(d.recognition_finished(second, 1, Ok("новый".into()), now()).is_empty(), "nor can it deliver twice");
    }

    #[test]
    fn silence_is_a_quiet_error_that_hides_itself_without_waiting_for_escape() {
        let mut d = machine();
        let id = recording(&mut d);
        d.key_released();
        let effects = d.recognition_finished(id, 100, Ok("".into()), now());
        assert_eq!(d.presentation(), Presentation::Error);
        assert_eq!(d.error(), Some(NO_SPEECH_RECOGNISED));
        assert!(has(&effects, &Effect::Log(LogEvent::RecognitionFinished { samples: 100, empty: true })));
        assert!(has(&effects, &Effect::PlaySound(Cue::DictationFailed)));
        let token = effects.iter().find_map(|e| match e {
            Effect::ScheduleDismiss { token, after } => {
                assert_eq!(*after, Duration::from_millis(2500));
                Some(*token)
            }
            _ => None,
        });
        let after = d.dismiss_elapsed(token.unwrap());
        assert_eq!(d.presentation(), Presentation::Hidden);
        assert_eq!(after, [Effect::CaptureEscape(false)]);
    }

    #[test]
    fn an_earlier_errors_timer_does_not_hide_a_later_one() {
        let mut d = machine();
        let id = recording(&mut d);
        d.key_released();
        let effects = d.recognition_finished(id, 1, Ok("".into()), now());
        let stale = effects.iter().find_map(|e| if let Effect::ScheduleDismiss { token, .. } = e { Some(*token) } else { None }).unwrap();

        // Another failure arrives before the timer: one that waits for Escape.
        let id = recording(&mut d);
        d.key_released();
        d.recognition_finished(id, 1, Err(RecognitionError::Other("boom".into())), now());
        assert_eq!(d.presentation(), Presentation::Error);
        d.dismiss_elapsed(stale);
        assert_eq!(d.presentation(), Presentation::Error, "the first timer is stale");
    }

    #[test]
    fn a_failure_of_dictations_own_is_said_and_any_other_is_a_general_one() {
        let mut d = machine();
        let id = recording(&mut d);
        d.key_released();
        d.recognition_finished(id, 0, Err(RecognitionError::Dictation(DictationFailure::new(MODEL_COULD_NOT_LOAD))), now());
        assert_eq!(d.error(), Some(MODEL_COULD_NOT_LOAD));

        let id = recording(&mut d);
        d.key_released();
        d.recognition_finished(id, 0, Err(RecognitionError::Other("ort: 0x7 broken".into())), now());
        assert_eq!(d.error(), Some(RECOGNITION_FAILED), "the system's wording stays in the log");
    }

    #[test]
    fn recording_is_refused_without_the_model_or_the_microphone_and_says_so() {
        let mut d = Dictation::new(Settings { model_ready: false, ..settings() });
        let effects = d.key_pressed();
        assert_eq!(d.presentation(), Presentation::Error);
        assert_eq!(d.error(), Some(MODEL_MISSING));
        assert!(has(&effects, &Effect::Log(LogEvent::RecordingRefused { reason: "model-missing".into() })));
        assert!(!effects.iter().any(|e| matches!(e, Effect::StartMicrophone(_))));

        let mut d = Dictation::new(Settings { microphone: MicrophonePermission::Denied, help: MicrophoneHelp::Mac, ..settings() });
        let effects = d.key_pressed();
        assert_eq!(d.error(), Some(MICROPHONE_REQUIRED_MAC));
        assert!(has(&effects, &Effect::Log(LogEvent::RecordingRefused { reason: "mic-denied".into() })));

        let mut d = Dictation::new(Settings { microphone: MicrophonePermission::NotDetermined, ..settings() });
        d.key_pressed();
        assert_eq!(d.error(), Some(MICROPHONE_REQUIRED_LINUX));
    }

    #[test]
    fn nothing_records_while_dictation_is_off() {
        let mut d = Dictation::new(Settings { enabled: false, ..settings() });
        assert!(d.key_pressed().is_empty());
        assert_eq!(d.presentation(), Presentation::Hidden);
    }

    #[test]
    fn a_microphone_that_will_not_open_is_an_error_and_frees_the_session() {
        let mut d = machine();
        let effects = d.key_pressed();
        let Some(Effect::StartMicrophone(id)) = effects.last().cloned() else { panic!() };
        let effects = d.microphone_failed(id);
        assert_eq!(d.error(), Some(MICROPHONE_COULD_NOT_START));
        assert!(has(&effects, &Effect::Log(LogEvent::MicrophoneStartFailed)));
        assert_eq!(d.phase(), Phase::Idle);
        assert!(d.key_released().is_empty(), "releasing the key after the failure decodes nothing");
        d.cancel();
        recording(&mut d); // and a new recording can begin
    }

    #[test]
    fn a_microphone_that_opens_after_a_cancel_is_closed_again() {
        let mut d = machine();
        let effects = d.key_pressed();
        let Some(Effect::StartMicrophone(id)) = effects.last().cloned() else { panic!() };
        d.escape_pressed();
        assert_eq!(d.microphone_started(id, input()), [Effect::StopMicrophone]);
        assert_eq!(d.presentation(), Presentation::Hidden);
    }

    #[test]
    fn the_clock_counts_down_and_the_sixtieth_second_ends_the_recording() {
        let mut d = machine();
        let id = recording(&mut d);
        assert!(d.clock_tick(id, 1).is_empty());
        assert_eq!(d.remaining(), 59);
        d.clock_tick(id, 52);
        assert_eq!(d.remaining(), 8);
        let effects = d.clock_tick(id, 60);
        assert_eq!(effects, [Effect::StopClock, Effect::StopAndRecognise(id)]);
        assert_eq!(d.remaining(), 0);
        assert!(d.clock_tick(id, 61).is_empty(), "no longer recording");
    }

    #[test]
    fn a_full_buffer_ends_the_recording_once() {
        let mut d = machine();
        let id = recording(&mut d);
        assert!(!d.recording_limit_reached(id).is_empty());
        assert!(d.recording_limit_reached(id).is_empty(), "key release after the limit must not decode twice");
        assert!(d.key_released().is_empty());
    }

    #[test]
    fn the_level_is_only_heard_from_the_current_recording() {
        let mut d = machine();
        let id = recording(&mut d);
        d.level_changed(id, 0.6);
        assert_eq!(d.level(), 0.6);
        d.level_changed(SessionId(id.0 + 7), 0.9);
        assert_eq!(d.level(), 0.6);
        d.key_released();
        assert_eq!(d.level(), 0.0, "recognising is not listening");
    }

    #[test]
    fn rules_edited_while_speaking_apply_to_the_next_dictation() {
        let mut d = machine();
        let id = recording(&mut d);
        d.set_replacements(vec![DictationReplacement::new(1, "привет", "HELLO")]);
        d.key_released();
        let effects = d.recognition_finished(id, 1, Ok("привет".into()), now());
        assert!(has(&effects, &Effect::CopyToClipboard("привет".into())), "{effects:?}");
    }

    #[test]
    fn a_headset_leaving_mid_recording_ends_it_with_a_sentence_and_one_arriving_does_not() {
        let mut d = machine();
        recording(&mut d);
        let effects = d.microphone_input_changed(Some(MicrophoneInput { sample_rate: 44_100, channels: 2 }));
        assert_eq!(effects.len(), 1, "followed, nothing else");
        assert_eq!(d.presentation(), Presentation::Recording);
        d.microphone_input_changed(None);
        assert_eq!(d.presentation(), Presentation::Error);
        assert_eq!(d.error(), Some(MICROPHONE_CHANGED));
        assert!(d.microphone_input_changed(None).is_empty(), "not recording any more");
    }

    #[test]
    fn sleep_lets_go_of_a_held_key_and_a_recording() {
        let mut d = machine();
        recording(&mut d);
        d.system_will_sleep();
        assert_eq!(d.presentation(), Presentation::Hidden);
        assert_eq!(d.phase(), Phase::Idle);
        assert!(!d.key_pressed().is_empty(), "the key is no longer considered held");
    }

    #[test]
    fn switching_off_stops_everything_and_unloads_the_model() {
        let mut d = machine();
        recording(&mut d);
        d.start_download();
        let effects = d.set_enabled(false);
        assert!(has(&effects, &Effect::PersistEnabled(false)));
        assert!(has(&effects, &Effect::CancelDownload));
        assert!(has(&effects, &Effect::UnloadRecogniser));
        assert!(has(&effects, &Effect::RegisterShortcut(None)));
        assert_eq!(d.presentation(), Presentation::Hidden);
        let effects = d.set_enabled(true);
        assert!(has(&effects, &Effect::RegisterShortcut(Some(default_dictation_shortcut()))));
    }

    #[test]
    fn the_shortcut_is_registered_unless_suspended_and_a_refusal_is_remembered() {
        let mut d = machine();
        let chosen = KeyShortcut::new(49, default_dictation_shortcut().modifiers, "Space");
        let effects = d.set_shortcut(chosen.clone());
        assert_eq!(effects, [Effect::PersistShortcut, Effect::RegisterShortcut(Some(chosen.clone()))]);
        d.shortcut_registered(false);
        assert!(d.shortcut_unavailable());
        assert_eq!(d.suspend_shortcut(true), [Effect::RegisterShortcut(None)]);
        assert_eq!(d.suspend_shortcut(false), [Effect::RegisterShortcut(Some(chosen))]);
        d.shortcut_registered(true);
        assert!(!d.shortcut_unavailable());

        let mut fixture = Dictation::new(Settings { registers_shortcuts: false, ..settings() });
        assert!(fixture.set_shortcut(default_dictation_shortcut()).iter().all(|e| !matches!(e, Effect::RegisterShortcut(_))));
    }

    #[test]
    fn the_stop_is_logged_when_the_samples_are_taken_and_recognition_does_not_log_it_again() {
        let mut d = machine();
        let id = recording(&mut d);
        d.key_released();
        assert_eq!(d.recording_stopped(16_000), [Effect::Log(LogEvent::RecordingStopped { samples: 16_000 })]);
        let effects = d.recognition_finished(id, 16_000, Ok("привет".into()), now());
        assert!(!effects.iter().any(|e| matches!(e, Effect::Log(LogEvent::RecordingStopped { .. }))));
    }

    #[test]
    fn a_history_changed_elsewhere_replaces_the_one_held_and_is_not_written_back() {
        let mut d = Dictation::new(Settings { keeps_history: true, ..settings() });
        let id = recording(&mut d);
        d.key_released();
        d.recognition_finished(id, 1, Ok("первый".into()), now());
        d.delivery_finished(None, now());
        assert_eq!(d.history().entries().len(), 1);
        // Settings cleared it.
        d.set_history(DictationHistory::new());
        assert!(d.history().entries().is_empty());
        let id = recording(&mut d);
        d.key_released();
        d.recognition_finished(id, 1, Ok("второй".into()), now());
        d.delivery_finished(None, now());
        assert_eq!(d.history().entries().len(), 1, "what was cleared does not come back");
        assert_eq!(d.history().entries()[0].text, "второй");
    }

    #[test]
    fn history_is_kept_only_when_asked_and_deleting_or_clearing_is_persisted() {
        let mut d = machine();
        let id = recording(&mut d);
        d.key_released();
        d.recognition_finished(id, 1, Ok("первый".into()), now());
        d.delivery_finished(None, now());
        assert!(d.history().entries().is_empty(), "off by default");

        d.set_keeps_history(true);
        for text in ["второй", "третий"] {
            let id = recording(&mut d);
            d.key_released();
            d.recognition_finished(id, 1, Ok(text.into()), now());
            let effects = d.delivery_finished(None, now());
            assert!(has(&effects, &Effect::PersistHistory));
        }
        assert_eq!(d.history().entries().len(), 2);
        assert_eq!(d.history().entries()[0].text, "третий");
        let id = d.history().entries()[0].id;
        assert_eq!(d.delete_history_entry(id), [Effect::PersistHistory]);
        assert_eq!(d.history().entries().len(), 1);
        d.clear_history();
        assert!(d.history().entries().is_empty());
    }

    #[test]
    fn the_download_logs_a_quarter_at_a_time_and_a_failure_always_says_the_same_thing() {
        let mut d = machine();
        let effects = d.start_download();
        assert_eq!(effects, [Effect::Log(LogEvent::DownloadStarted), Effect::StartDownload]);
        assert!(d.start_download().is_empty(), "one download at a time");
        assert_eq!(d.download_progress_changed(0.3), [Effect::Log(LogEvent::DownloadProgress { percent: 25 })]);
        assert!(d.download_progress_changed(0.4).is_empty());
        d.download_answered(404, 12);
        let effects = d.download_failed(false);
        assert_eq!(d.error(), Some(DOWNLOAD_FAILED));
        assert_eq!(effects, [Effect::Log(LogEvent::DownloadFailed)]);
        assert!(d.download_progress().is_none());

        d.start_download();
        assert_eq!(d.error(), None, "a new attempt clears the old error");
        assert_eq!(d.download_failed(true), [Effect::Log(LogEvent::InstallFailed)]);
    }

    #[test]
    fn a_finished_download_makes_the_model_ready_and_sounds() {
        let mut d = Dictation::new(Settings { model_ready: false, ..settings() });
        d.start_download();
        let effects = d.download_installed();
        assert!(d.model_ready());
        assert!(has(&effects, &Effect::PlaySound(Cue::DictationModelReady)));
        assert!(d.download_progress().is_none());
        // Nothing to cancel any more.
        assert!(d.cancel_download().is_empty());
        d.start_download();
        assert_eq!(d.cancel_download(), [Effect::CancelDownload]);
        assert_eq!(d.download_cancelled(), [Effect::Log(LogEvent::DownloadCancelled)]);
    }

    #[test]
    fn a_download_needs_dictation_to_be_on() {
        let mut d = Dictation::new(Settings { enabled: false, ..settings() });
        assert!(d.start_download().is_empty());
    }

    #[test]
    fn the_observation_follows_the_state() {
        let mut d = machine();
        assert_eq!(d.observation().codes(), ["model-ready", "mic-authorized", "insertion-allowed"]);
        d.set_permissions(MicrophonePermission::Denied, false);
        assert_eq!(d.observation().codes(), ["model-ready", "mic-denied", "insertion-not-allowed"]);
        d.set_enabled(false);
        assert_eq!(d.observation().codes(), ["off"]);
    }

    #[test]
    fn the_fixture_shows_states_without_recording_and_a_real_machine_ignores_it() {
        let mut fixture = Dictation::new(Settings { registers_shortcuts: false, model_ready: false, ..settings() });
        fixture.preview(Presentation::Recording, 0.35);
        assert_eq!(fixture.presentation(), Presentation::Recording);
        assert_eq!((fixture.level(), fixture.remaining()), (0.35, 8));
        assert!(fixture.model_ready());

        let mut real = machine();
        real.preview(Presentation::Recording, 0.35);
        assert_eq!(real.presentation(), Presentation::Hidden);
    }
}
