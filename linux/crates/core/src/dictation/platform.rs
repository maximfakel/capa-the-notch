//! What Dictation asks of the system, and nothing else: four traits, one per
//! thing the Swift app does through macOS (CoreAudio queues, the Carbon hot
//! key, Accessibility and Quartz events, sherpa-onnx). Each platform
//! implements them; the logic above them is the same everywhere and is tested
//! without any of them.
//!
//! None of these traits is `async`: the platform decides how it waits, and
//! tells the state machine what happened by calling its methods.

use super::messages::DictationFailure;
use crate::prefs::KeyShortcut;
use serde::{Deserialize, Serialize};

// MARK: - The microphone

/// What the system lets this application do with the microphone. The words are
/// the ones a bug report carries (`mic-not-determined`, …).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum MicrophonePermission {
    #[default]
    NotDetermined,
    Restricted,
    Denied,
    Authorized,
}

impl MicrophonePermission {
    pub fn raw(self) -> &'static str {
        match self {
            Self::NotDetermined => "not-determined",
            Self::Restricted => "restricted",
            Self::Denied => "denied",
            Self::Authorized => "authorized",
        }
    }
}

/// What the input was when capture (re)started, for the diagnostic log.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MicrophoneInput {
    pub sample_rate: u32,
    pub channels: u32,
}

impl MicrophoneInput {
    /// `16000Hz 1ch`, the way the log writes it.
    pub fn code(&self) -> String {
        format!("{}Hz {}ch", self.sample_rate, self.channels)
    }
}

/// What a recording tells whoever is listening. Called from the audio thread:
/// implementations must be quick and must not block.
pub trait MicrophoneSink: Send + Sync {
    /// How loud it is now, 0 to 1 (`audio::level_of`).
    fn level(&self, level: f32);
    /// The recording filled its sixty seconds.
    fn limit_reached(&self);
    /// The default input changed during the recording — a headset connecting
    /// or leaving: the new input, or `None` when capture could not start
    /// again on it.
    fn input_changed(&self, input: Option<MicrophoneInput>);
}

/// An input-only capture of 16 kHz mono `f32`, bounded at
/// `DictationSession::LIMIT_SAMPLES`. Raw audio never reaches disk. It keeps
/// capturing across an input change, keeping what was already heard, and does
/// not open an output beside the input (on a Mac that is what hung the app on
/// a Bluetooth headset).
pub trait Microphone {
    fn permission(&self) -> MicrophonePermission;

    /// Asks the system for access, where it asks at all; the answer is read
    /// back with `permission`. Where there is no question (most Linux
    /// desktops), does nothing.
    fn request_permission(&mut self);

    /// Opens the system's own place to change the answer.
    fn open_privacy_settings(&mut self);

    fn start(&mut self, sink: Box<dyn MicrophoneSink>) -> Result<MicrophoneInput, DictationFailure>;

    /// Stops, and hands over what was captured.
    fn stop(&mut self) -> Vec<f32>;
}

// MARK: - Recognition

/// Speech to text, entirely on this machine: sherpa-onnx with the model in
/// `model.rs`, configured as `model::engine` says. The model is loaded on
/// first use and let go `model::engine::UNLOAD_AFTER_SECONDS` after the last.
pub trait Recogniser {
    /// `samples` are 16 kHz mono. Empty samples fail with
    /// `NO_SPEECH_RECORDED`. `cancelled` is looked at between steps.
    fn recognise(&mut self, samples: &[f32], cancelled: &dyn Fn() -> bool) -> Result<String, RecognitionError>;

    fn unload(&mut self);
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RecognitionError {
    /// Dictation's own failure: a sentence with a translation.
    Dictation(DictationFailure),
    /// Anything else: the system's wording, which the log keeps and the
    /// capsule does not repeat.
    Other(String),
}

// MARK: - Delivery

/// What was in front when recording began, and how to put the text there.
pub trait TextInserter {
    /// Captures the application in front, and its focus, before the capsule
    /// appears. `Err` carries the sentence for the capsule, and the text is
    /// left for the clipboard. A password field is never a target.
    fn capture(&mut self) -> Result<(), String>;

    /// Puts the text where the cursor was. `None` when it went in; otherwise
    /// the sentence saying why it did not (see the `messages` module), and the
    /// text stays on the clipboard. Must check the same application and field
    /// are still in front, and never insert twice.
    fn insert(&mut self, text: &str) -> Option<String>;

    /// Whether the system lets this application insert text into others
    /// (Accessibility on a Mac; on Wayland usually only through the clipboard).
    fn insertion_allowed(&self) -> bool;

    /// Asks for it, where it can be asked for.
    fn request_insertion(&mut self);
}

/// The clipboard, written by this application. Text it puts there is marked as
/// its own, so the Shelf's clipboard tab does not keep a dictation.
pub trait ClipboardWriter {
    fn copy(&mut self, text: &str);
}

// MARK: - The shortcut

/// What the held shortcut does. Called on the main thread.
pub trait HotKeyHandler: Send + Sync {
    fn pressed(&self);
    fn released(&self);
    /// Escape, while a session needs it.
    fn cancelled(&self);
}

/// A global shortcut that tells hold from release, without the Accessibility
/// permission where the system allows (Carbon on a Mac, the GlobalShortcuts
/// portal or evdev on Linux — which on GNOME Wayland means the extension).
pub trait GlobalHotKey {
    /// Registers the shortcut (`None` unregisters). `false` when the system
    /// refuses: it is in use.
    fn register(&mut self, shortcut: Option<&KeyShortcut>) -> bool;

    /// Escape is registered only for an active session, never while the
    /// module is idle.
    fn capture_escape(&mut self, active: bool);

    fn set_handler(&mut self, handler: Box<dyn HotKeyHandler>);
}

// MARK: - Audio, the parts that need no device

pub mod audio {
    use super::DictationSession;

    /// How loud a chunk is, 0 to 1: its RMS in decibels, with −55 dB as silence
    /// and −20 dB as full.
    pub fn level_of(chunk: &[f32]) -> f32 {
        if chunk.is_empty() {
            return 0.0;
        }
        let rms = (chunk.iter().map(|s| s * s).sum::<f32>() / chunk.len() as f32).sqrt();
        let decibels = 20.0 * rms.max(0.000_01).log10();
        ((decibels + 55.0) / 35.0).clamp(0.0, 1.0)
    }

    /// The samples a recording keeps, bounded: what no longer fits is dropped
    /// and the recording is told it is full.
    #[derive(Debug, Default)]
    pub struct SampleBuffer {
        samples: Vec<f32>,
        accepting: bool,
    }

    impl SampleBuffer {
        pub fn new() -> Self {
            Self::default()
        }

        /// Starts empty and listening.
        pub fn start(&mut self) {
            self.samples.clear();
            self.accepting = true;
        }

        /// Returns whether this chunk filled the buffer. After that nothing is
        /// accepted until `start`.
        pub fn push(&mut self, chunk: &[f32]) -> bool {
            if !self.accepting || chunk.is_empty() {
                return false;
            }
            let room = DictationSession::LIMIT_SAMPLES.saturating_sub(self.samples.len());
            self.samples.extend_from_slice(&chunk[..chunk.len().min(room)]);
            if chunk.len() >= room {
                self.accepting = false;
                return true;
            }
            false
        }

        pub fn is_accepting(&self) -> bool {
            self.accepting
        }

        /// Stops, and hands over what was kept.
        pub fn take(&mut self) -> Vec<f32> {
            self.accepting = false;
            std::mem::take(&mut self.samples)
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn silence_is_zero_and_a_loud_chunk_is_one() {
            assert_eq!(level_of(&[]), 0.0);
            assert_eq!(level_of(&[0.0; 1600]), 0.0);
            assert_eq!(level_of(&[1.0; 1600]), 1.0, "0 dB is past −20 dB");
            let mid = level_of(&[0.03; 1600]); // about −30 dB
            assert!(mid > 0.5 && mid < 0.9, "{mid}");
        }

        #[test]
        fn the_level_follows_the_loudness() {
            let quiet = level_of(&[0.002; 800]);
            let louder = level_of(&[0.02; 800]);
            assert!(quiet < louder);
        }

        #[test]
        fn a_buffer_keeps_sixty_seconds_and_says_when_it_is_full() {
            let mut buffer = SampleBuffer::new();
            assert!(!buffer.push(&[0.1; 10]), "nothing is accepted before start");
            buffer.start();
            let chunk = vec![0.1f32; 1600];
            let mut full = false;
            let mut chunks = 0;
            while !full {
                full = buffer.push(&chunk);
                chunks += 1;
            }
            assert_eq!(chunks, 600, "a tenth of a second a chunk, sixty seconds");
            assert!(!buffer.is_accepting());
            assert!(!buffer.push(&chunk), "a full buffer takes no more");
            assert_eq!(buffer.take().len(), DictationSession::LIMIT_SAMPLES);
        }

        #[test]
        fn a_chunk_that_overflows_is_cut_to_fit() {
            let mut buffer = SampleBuffer::new();
            buffer.start();
            assert!(!buffer.push(&vec![0.0; DictationSession::LIMIT_SAMPLES - 5]));
            assert!(buffer.push(&[0.0; 100]));
            assert_eq!(buffer.take().len(), DictationSession::LIMIT_SAMPLES);
            assert!(buffer.take().is_empty());
        }
    }
}

use super::session::DictationSession;
