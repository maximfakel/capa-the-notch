//! Kapa, the surface's one character: a cyan bell whose face says what the
//! Module it stands in already says (ADR 0006). Port of
//! `CapacityNotchCore/Kapa/Kapa.swift` and `KapaMotion.swift`.
//!
//! Everything here is a plain function of its inputs and of time passed in:
//! which pose (`mood`), what each pose's face is made of (`face`), where the
//! eyes sit (`gaze`), when it blinks (`blink`), and how it moves (`motion`).
//! The drawing lives in `linux/js/ui/kapa`.

mod blink;
mod face;
mod gaze;
mod mood;
mod motion;

pub use blink::KapaBlink;
pub use face::{Badge, Brows, Eyes, KapaExpression, KapaFace, KapaLook, Mouth, Reaction};
pub use gaze::{Eye, Features, KapaGaze};
pub use mood::{KapaFocus, KapaMood, KapaPreference};
pub use motion::{Gulp, Kick, KapaMotion};

#[cfg(test)]
mod tests;
