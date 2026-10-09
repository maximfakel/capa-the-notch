//! What surfaces and the Settings read: the machine's state as JSON, camelCase.
//! Nothing here is drawn; the capsule's look is `capa_core::dictation::Presentation`'s.

use crate::bridge::Bridge;
use crate::driver::Platform;
use capa_core::dictation::{model, Dictation, LogEvent};
use capa_core::prefs::{KeyShortcut, Platform as KeyPlatform};
use serde_json::{json, Value};
use std::collections::VecDeque;

pub const KEY_PLATFORM: KeyPlatform = KeyPlatform::Linux;

/// A log line: codes, counts and states, never the audio and never what was said.
pub fn log_line(event: &LogEvent) -> String {
    match event {
        LogEvent::RecordingRefused { reason } => format!("recording-refused {reason}"),
        LogEvent::RecordingStarted(input) => format!("recording-started {}", input.code()),
        LogEvent::RecordingStopped { samples } => format!("recording-stopped samples={samples}"),
        LogEvent::MicrophoneStartFailed => "microphone-start-failed".into(),
        LogEvent::MicrophoneInputChanged(input) => {
            format!("microphone-input-changed {}", input.map_or("none".into(), |i| i.code()))
        }
        LogEvent::RecognitionFinished { samples, empty } => format!("recognition-finished samples={samples} empty={empty}"),
        LogEvent::RecognitionFailed => "recognition-failed".into(),
        LogEvent::Delivered { inserted } => format!("delivered inserted={inserted}"),
        LogEvent::DownloadStarted => "download-started".into(),
        LogEvent::DownloadProgress { percent } => format!("download-progress {percent}%"),
        LogEvent::DownloadAnswered { status, bytes } => format!("download-answered status={status} bytes={bytes}"),
        LogEvent::DownloadCancelled => "download-cancelled".into(),
        LogEvent::DownloadFailed => "download-failed".into(),
        LogEvent::InstallFailed => "install-failed".into(),
        LogEvent::ModelInstalled => "model-installed".into(),
    }
}

fn rgb(c: (f64, f64, f64)) -> Value {
    json!([c.0, c.1, c.2])
}

/// The shortcut as GTK and Mutter write an accelerator: `<Control><Alt>d`. For a
/// host that grabs it (the GNOME extension). The key is found by its code, as
/// the Swift registers it, whatever the label says (`KeyShortcut::accelerator`).
pub fn accelerator(shortcut: &KeyShortcut) -> Option<String> {
    shortcut.accelerator()
}

pub fn state_json(machine: &Dictation, bridge: &Bridge, platform: &Platform, log: &VecDeque<String>) -> Value {
    let presentation = machine.presentation();
    let tones = presentation.tones();
    let details = presentation.details(machine.error(), machine.delivery_message());
    let (registered, escape) = bridge.registration();
    let shortcut = machine.shortcut();
    json!({
        "enabled": machine.is_enabled(),
        "presentation": presentation,
        "isDrawn": presentation.is_drawn(),
        "followsVoice": presentation.follows_voice(),
        "hasDetails": presentation.has_details(),
        "orb": {"state": presentation.orb_state(), "tone": rgb(tones.tone), "tone2": rgb(tones.tone2)},
        "kapa": presentation.kapa_expression(),
        "accessibilityLabel": presentation.accessibility_label(),
        "level": machine.level(),
        "remaining": machine.remaining(),
        "error": machine.error(),
        "deliveryMessage": machine.delivery_message(),
        "details": details,
        "modelReady": machine.model_ready(),
        "model": {
            "name": model::NAME,
            "downloadMegabytes": model::DOWNLOAD_MEGABYTES,
            "diskMegabytes": model::DISK_MEGABYTES,
            "ready": platform.downloader.is_ready(),
        },
        "download": machine.download_progress().map(|d| json!({
            "fraction": d.fraction(),
            "label": d.label().map(|l| match l {
                model::ProgressLabel::Downloading(p) => json!({"kind": "downloading", "percent": p}),
                model::ProgressLabel::Checking => json!({"kind": "checking"}),
            }),
        })),
        "microphoneAllowed": machine.microphone_allowed(),
        "insertionAllowed": machine.insertion_allowed(),
        "shortcutUnavailable": machine.shortcut_unavailable(),
        "keepsHistory": machine.keeps_history(),
        "replacements": machine.replacements(),
        "history": machine.history().entries(),
        "shortcut": {
            "shortcut": shortcut,
            "display": shortcut.display_for(KEY_PLATFORM),
            "keycaps": shortcut.keycaps(),
        },
        // What a host is being asked to grab, so one that connects late knows.
        "registration": {
            "shortcut": registered,
            "accelerator": registered.as_ref().and_then(accelerator),
            "evdev": registered.as_ref().and_then(KeyShortcut::linux_evdev),
            "escape": escape,
        },
        "log": log,
        "observation": machine.observation().codes(),
    })
}


#[cfg(test)]
mod tests {
    use super::*;
    use capa_core::prefs::{default_dictation_shortcut, Modifiers};

    #[test]
    fn a_shortcut_is_an_accelerator_a_compositor_can_grab() {
        assert_eq!(accelerator(&default_dictation_shortcut()).as_deref(), Some("<Control><Alt>d"));
        let space = KeyShortcut::new(49, Modifiers::CONTROL.union(Modifiers::SHIFT), "Space");
        assert_eq!(accelerator(&space).as_deref(), Some("<Control><Shift>space"));
        let escape = KeyShortcut::new(53, Modifiers(0), "Esc");
        assert_eq!(accelerator(&escape).as_deref(), Some("Escape"));
        assert_eq!(accelerator(&KeyShortcut::new(126, Modifiers::OPTION, "↑")).as_deref(), Some("<Alt>Up"));
        assert_eq!(accelerator(&KeyShortcut::new(122, Modifiers::COMMAND, "F1")).as_deref(), Some("<Super>F1"));
        assert_eq!(accelerator(&KeyShortcut::new(999, Modifiers(0), "Key 999")), None);
        // By the key, not the label.
        let ctrl_alt = Modifiers::CONTROL.union(Modifiers::OPTION);
        assert_eq!(accelerator(&KeyShortcut::new(2, ctrl_alt, "В")).as_deref(), Some("<Control><Alt>d"), "D under a Russian layout");
        assert_eq!(accelerator(&KeyShortcut::new(43, ctrl_alt, ",")).as_deref(), Some("<Control><Alt>comma"));
        assert_eq!(accelerator(&KeyShortcut::new(96, ctrl_alt, "Key 96")).as_deref(), Some("<Control><Alt>F5"));
        assert_eq!(accelerator(&KeyShortcut::new(1, Modifiers(0), "Key 1")).as_deref(), Some("s"), "the S key, whatever it was called");
    }

    #[test]
    fn the_log_says_codes_and_counts_never_words() {
        assert_eq!(log_line(&LogEvent::RecordingStopped { samples: 16000 }), "recording-stopped samples=16000");
        assert_eq!(log_line(&LogEvent::Delivered { inserted: false }), "delivered inserted=false");
    }
}
