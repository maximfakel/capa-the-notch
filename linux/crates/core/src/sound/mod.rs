//! The sounds (ADR 0007): recipes in procedural-sounds' format, a synth that
//! draws them to samples exactly as the Swift `SoundSynth` does, the WAV they
//! are cut into, the cues that say which moment has which sound, and the one
//! platform seam — `SoundOut`, which plays a buffer.

pub mod cues;
pub mod file;
pub mod patch;
pub mod recipes;
pub mod synth;

pub use cues::{Recipe, SoundBank, SoundBuffer, SoundCue, SoundOut, SoundPolicy};
pub use patch::{PatchError, SoundPatch};

#[cfg(test)]
mod tests;
