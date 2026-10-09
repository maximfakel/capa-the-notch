//! Port of the Dictation Module's logic: the session, the word replacements,
//! the history, the speech model and its checks, the capsule's look, the
//! state machine that was the controller, and the traits the system fills in.

mod capsule;
mod history;
mod machine;
mod messages;
pub mod model;
mod observation;
pub mod platform;
mod replacement;
mod session;
pub mod sha256;

pub use capsule::{
    Details, OrbState, Presentation, Rect, Tones, BELOW_SURFACE, GAP, KAPA_LOOK_PITCH, KAPA_LOOK_YAW, KAPA_SIZE, MARGIN,
    ORB, ORB_INK, QUIET_ERROR_SECONDS, SHADOW_OFFSET_Y, SHADOW_OPACITY, SHADOW_RADIUS, SUCCESS_SECONDS,
};
pub use history::{DictationHistory, HistoryEntry};
pub use machine::{Cue, Dictation, Effect, LogEvent, Settings};
pub use messages::*;
pub use observation::DictationObservation;
pub use platform::{
    audio, ClipboardWriter, GlobalHotKey, HotKeyHandler, Microphone, MicrophoneInput, MicrophonePermission,
    MicrophoneSink, RecognitionError, Recogniser, TextInserter,
};
pub use replacement::DictationReplacement;
pub use session::{DictationSession, Phase, SessionId};
pub use sha256::{hex_of as sha256_hex_of, Sha256};
