use serde::{Deserialize, Serialize};

/// What the Music Module says when the system stops telling it what is
/// playing.
///
/// On macOS it reads through a private interface (ADR 0004), which Apple can
/// close in any update. When that happens the strip shows nothing — there is
/// no track to show — so the failure is said where the person will look for it.
/// The other platforms use the same words if their source stops answering.
pub struct MusicModule;

impl MusicModule {
    /// Under 32 characters, so `Redaction` leaves it in the report.
    pub const UNREADABLE_CODE: &'static str = "music-unreadable";
    pub const UNREADABLE_GUIDANCE: &'static str = "macOS no longer lets CapaTheNotch read what's playing.";
    /// The same sentence for the platforms that never had a private door.
    pub const UNREADABLE_GUIDANCE_OTHER: &'static str = "CapaTheNotch can no longer read what's playing.";
}

/// A control. `arguments` is the form mediaremote-adapter takes (macOS); the
/// other platforms translate the command themselves.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(tag = "command", rename_all = "camelCase")]
pub enum MusicCommand {
    Previous,
    TogglePlayPause,
    Next,
    /// A position in seconds.
    #[serde(rename_all = "camelCase")]
    Seek { to: f64 },
}

impl MusicCommand {
    /// `send` with MediaRemote's command id, `seek` with microseconds.
    pub fn arguments(&self) -> Vec<String> {
        match self {
            Self::Previous => vec!["send".into(), "5".into()],
            Self::TogglePlayPause => vec!["send".into(), "2".into()],
            Self::Next => vec!["send".into(), "4".into()],
            Self::Seek { to } => vec!["seek".into(), ((to.max(0.0) * 1_000_000.0).round() as i64).to_string()],
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_music_module_that_cannot_read_says_so_in_the_report() {
        assert_eq!(MusicModule::UNREADABLE_CODE, "music-unreadable");
        // `Redaction` treats a longer run of letters and hyphens as a secret.
        assert!(MusicModule::UNREADABLE_CODE.len() < 32);
        assert!(!MusicModule::UNREADABLE_GUIDANCE.is_empty());
    }

    #[test]
    fn each_control_is_the_command_the_adapter_expects() {
        // From the adapter's README: send takes MediaRemote's command ids, seek
        // a position in microseconds.
        assert_eq!(MusicCommand::Previous.arguments(), ["send", "5"]);
        assert_eq!(MusicCommand::TogglePlayPause.arguments(), ["send", "2"]);
        assert_eq!(MusicCommand::Next.arguments(), ["send", "4"]);
        assert_eq!(MusicCommand::Seek { to: 46.5 }.arguments(), ["seek", "46500000"]);
        assert_eq!(MusicCommand::Seek { to: -3.0 }.arguments(), ["seek", "0"], "never before the start");
    }

    #[test]
    fn commands_cross_the_wire_as_tagged_json() {
        assert_eq!(serde_json::to_string(&MusicCommand::Next).unwrap(), r#"{"command":"next"}"#);
        assert_eq!(serde_json::to_string(&MusicCommand::Seek { to: 12.5 }).unwrap(), r#"{"command":"seek","to":12.5}"#);
        let back: MusicCommand = serde_json::from_str(r#"{"command":"togglePlayPause"}"#).unwrap();
        assert_eq!(back, MusicCommand::TogglePlayPause);
    }
}
