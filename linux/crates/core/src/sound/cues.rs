//! The few moments CapaTheNotch says with a sound (ADR 0007), each drawn once
//! from its recipe and played as a buffer: the surface pinned or let go, a
//! file taken by the Shelf, a Clipping copied, Kapa tapped or saying hello,
//! dictated text kept, dictation failing, its model ready, onboarding
//! finished, a Provider that stopped answering, and a Capacity Alert and the
//! window's recovery after it. Nothing plays while the switch in Settings is
//! off, while the system's own interface sounds are off, or while the
//! Teleprompter runs — someone reading a Script aloud is on a call or a
//! recording.

use super::patch::SoundPatch;
use super::{file, recipes, synth};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SoundCue {
    SurfacePinned,
    ShelfTook,
    ClippingCopied,
    KapaTapped,
    DictationInserted,
    DictationCopied,
    DictationFailed,
    DictationModelReady,
    ProviderStopped,
    CapacityAlert,
    CapacityRecovered,
    KapaHello,
    OnboardingFinished,
}

/// Which of the five recipes a cue is, by name.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Recipe {
    Tap,
    Success,
    Error,
    Warning,
    Notification,
}

impl Recipe {
    pub fn name(self) -> &'static str {
        match self {
            Recipe::Tap => "tap",
            Recipe::Success => "success",
            Recipe::Error => "error",
            Recipe::Warning => "warning",
            Recipe::Notification => "notification",
        }
    }

    pub fn patch(self) -> SoundPatch {
        match self {
            Recipe::Tap => recipes::tap(),
            Recipe::Success => recipes::success(),
            Recipe::Error => recipes::error(),
            Recipe::Warning => recipes::warning(),
            Recipe::Notification => recipes::notification(),
        }
    }
}

impl SoundCue {
    pub const ALL: [SoundCue; 13] = [
        SoundCue::SurfacePinned,
        SoundCue::ShelfTook,
        SoundCue::ClippingCopied,
        SoundCue::KapaTapped,
        SoundCue::DictationInserted,
        SoundCue::DictationCopied,
        SoundCue::DictationFailed,
        SoundCue::DictationModelReady,
        SoundCue::ProviderStopped,
        SoundCue::CapacityAlert,
        SoundCue::CapacityRecovered,
        SoundCue::KapaHello,
        SoundCue::OnboardingFinished,
    ];

    pub fn recipe(self) -> Recipe {
        match self {
            SoundCue::SurfacePinned | SoundCue::ShelfTook | SoundCue::ClippingCopied => Recipe::Tap,
            SoundCue::KapaTapped | SoundCue::DictationModelReady => Recipe::Success,
            SoundCue::DictationInserted => Recipe::Success,
            // Copied only is still the text the person said, kept for them.
            SoundCue::DictationCopied => Recipe::Success,
            SoundCue::DictationFailed => Recipe::Error,
            SoundCue::ProviderStopped | SoundCue::CapacityAlert => Recipe::Warning,
            SoundCue::CapacityRecovered | SoundCue::KapaHello | SoundCue::OnboardingFinished => Recipe::Notification,
        }
    }

    pub fn patch(self) -> SoundPatch {
        self.recipe().patch()
    }
}

/// What decides whether a cue is heard.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SoundPolicy {
    /// The switch in Settings ▸ General (`SoundPreference.isOn`).
    pub enabled: bool,
    /// The system's "play interface sound effects", where it has one; true
    /// where the system has no such switch.
    pub interface_sounds_on: bool,
    /// Something on the surface wants quiet: the Teleprompter running.
    pub quiet: bool,
}

impl SoundPolicy {
    pub fn allows(&self) -> bool {
        self.enabled && self.interface_sounds_on && !self.quiet
    }
}

impl Default for SoundPolicy {
    fn default() -> Self {
        Self { enabled: true, interface_sounds_on: true, quiet: false }
    }
}

/// One sound, drawn: the samples a player takes as a buffer, and the same cut
/// and faded as a WAV for one that wants a file.
#[derive(Debug, Clone, PartialEq)]
pub struct SoundBuffer {
    pub sample_rate: u32,
    /// Mono 16-bit PCM, trimmed and faded as the WAV is.
    pub pcm: Vec<i16>,
    pub wav: Vec<u8>,
}

impl SoundBuffer {
    pub fn render(patch: &SoundPatch) -> Self {
        let samples = synth::render(patch);
        let sample_rate = synth::SAMPLE_RATE as u32;
        Self { sample_rate, pcm: file::pcm16(&samples, sample_rate), wav: file::wav(&samples) }
    }
}

/// Platform: plays a buffer. Playing a cue that is already sounding restarts
/// it (the Swift side calls `stop()` then `play()`).
pub trait SoundOut: Send + Sync {
    fn play(&self, cue: SoundCue, buffer: &SoundBuffer);
}

/// Every sound, drawn once each when first wanted (or ahead of time by
/// `prepare`, away from the thread that is busy), and played through a
/// `SoundOut` when the policy allows.
#[derive(Default)]
pub struct SoundBank {
    drawn: Mutex<HashMap<Recipe, Arc<SoundBuffer>>>,
}

impl SoundBank {
    pub fn new() -> Self {
        Self::default()
    }

    /// Draws every sound ahead of the first that plays. A few milliseconds
    /// each, but not in the middle of a drop.
    pub fn prepare(&self) {
        for cue in SoundCue::ALL {
            self.buffer(cue);
        }
    }

    pub fn buffer(&self, cue: SoundCue) -> Arc<SoundBuffer> {
        let recipe = cue.recipe();
        if let Some(buffer) = self.drawn.lock().unwrap().get(&recipe) {
            return buffer.clone();
        }
        // Drawn outside the lock: it is the slow part.
        let buffer = Arc::new(SoundBuffer::render(&recipe.patch()));
        self.drawn.lock().unwrap().entry(recipe).or_insert(buffer).clone()
    }

    /// Plays the cue unless the policy says to keep quiet. Returns whether it played.
    pub fn play(&self, cue: SoundCue, policy: &SoundPolicy, out: &dyn SoundOut) -> bool {
        if !policy.allows() {
            return false;
        }
        out.play(cue, &self.buffer(cue));
        true
    }
}
