//! The sentences Dictation says, word for word as the Swift app has them.
//! They are the keys of the translations (`L(...)`), so they stay English
//! here and are translated where they are shown.

/// A failure Dictation names itself, as against one the system names.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DictationFailure(pub String);

impl DictationFailure {
    pub fn new(message: &str) -> Self {
        Self(message.to_owned())
    }
    pub fn message(&self) -> &str {
        &self.0
    }
}

impl std::fmt::Display for DictationFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for DictationFailure {}

// Refusals before recording.
pub const MODEL_MISSING: &str = "Download the speech model in Dictation settings before recording.";
/// macOS's wording. Other systems say where their own privacy settings are;
/// see `MicrophoneHelp`.
pub const MICROPHONE_REQUIRED_MAC: &str =
    "Microphone access is required. Allow CapaTheNotch in System Settings → Privacy & Security → Microphone.";
pub const MICROPHONE_REQUIRED_LINUX: &str =
    "Microphone access is required. Allow CapaTheNotch to use the microphone in your system's privacy settings.";
pub const MICROPHONE_COULD_NOT_START: &str =
    "The microphone could not start. Check microphone access and your input device in System Settings.";
pub const MICROPHONE_CHANGED: &str = "The microphone changed. Select your input device and try again.";
pub const NO_MICROPHONE: &str = "No microphone is available. Connect one and try again.";

// Recognition.
pub const NO_SPEECH_RECORDED: &str = "No speech was recorded. Hold the shortcut while speaking.";
pub const NO_SPEECH_RECOGNISED: &str = "No speech was recognised. Check your microphone and try again.";
pub const RECOGNITION_FAILED: &str = "Recognition failed. Try again.";
pub const RECOGNITION_COULD_NOT_START: &str = "Recognition could not start. Try again.";
pub const MODEL_COULD_NOT_LOAD: &str = "The speech model could not load. Download it again in Dictation settings.";
pub const MODEL_MISSING_OR_DAMAGED: &str =
    "The speech model is missing or damaged. Download it again in Dictation settings.";

// The model download.
pub const DOWNLOAD_FAILED_STATUS: &str = "Download failed. Check your connection and try again.";
pub const DOWNLOAD_FAILED: &str = "Download failed. Check your connection and free disk space, then try again.";
pub const UNPACK_FAILED: &str = "The download could not be unpacked. Check free disk space and try again.";

// Delivery.
pub const NO_EXTERNAL_APPLICATION: &str = "No external application was captured when recording began.";
pub const TARGET_NOT_ACTIVE: &str = "The target application stopped being active before insertion.";
pub const FIELD_CHANGED_DURING_INSERTION: &str =
    "The field changed during Accessibility insertion; paste was skipped to avoid duplicating text.";
pub const FIELD_LOST_FOCUS: &str = "The captured field lost focus before insertion.";
pub const TARGET_OR_FIELD_CHANGED: &str = "The target application or text field changed before insertion.";
pub const PASTE_FAILED: &str = "The text could not be pasted. It is still in the clipboard.";
/// What the details popover says when it has nothing more specific.
pub const INSERTION_UNAVAILABLE: &str = "Insertion was unavailable.";
pub const TRY_AGAIN: &str = "Try again.";

/// Which system's privacy words to use for the microphone refusal.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MicrophoneHelp {
    Mac,
    Linux,
}

impl MicrophoneHelp {
    pub fn required(self) -> &'static str {
        match self {
            Self::Mac => MICROPHONE_REQUIRED_MAC,
            Self::Linux => MICROPHONE_REQUIRED_LINUX,
        }
    }
}
