use super::blink::KapaBlink;
use super::face::Reaction;
use serde::{Deserialize, Serialize};
use std::f64::consts::PI;

/// A squash, stretch or lift, added to whatever else is moving.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Kick {
    pub sx: f64,
    pub sy: f64,
    /// Downward, in the sheet's units.
    pub dy: f64,
    /// Sideways, in the sheet's units.
    pub dx: f64,
}

impl Default for Kick {
    fn default() -> Self {
        Self { sx: 1.0, sy: 1.0, dy: 0.0, dx: 0.0 }
    }
}

impl Kick {
    pub fn new(sx: f64, sy: f64, dy: f64, dx: f64) -> Self {
        Self { sx, sy, dy, dx }
    }
}

/// Kapa eating a dropped file at one moment.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Gulp {
    /// How open the mouth is, 0 to 1.
    pub mouth: f64,
    /// How far the file has travelled to the mouth, 0 to 1; `None` once it
    /// is inside.
    pub file: Option<f64>,
    pub kick: Kick,
    /// Eyes shut in a happy squint: chewing and after.
    pub pleased: bool,
}

/// How Kapa moves, as plain functions of time: each movement is a pose at a
/// moment, so it can be tested at that moment, and an interrupted one picks
/// up from wherever it was. Coucou writes its greeting and its drop scene the
/// same way; the numbers are Kapa's.
pub struct KapaMotion;

impl KapaMotion {
    // MARK: Following a target

    /// Moves `value` toward `target` the same distance per second at any frame
    /// rate: after one second, `base` of the gap is left. A base of 0.0025
    /// settles in about a sixth of a second.
    pub fn approach(value: f64, target: f64, base: f64, dt: f64) -> f64 {
        value + (target - value) * (1.0 - base.powf(dt.max(0.0)))
    }

    /// One step of a damped spring: the mouth, which overshoots a little as
    /// it snaps open and shut. ω₀ = 2π / 0.25 s, ζ = 0.6, as Coucou's.
    /// Returns `(value, velocity)`.
    pub fn spring(value: f64, velocity: f64, target: f64, dt: f64, omega: f64, damping: f64) -> (f64, f64) {
        let step = dt.clamp(0.0, 0.05);
        let acceleration = omega * omega * (target - value) - 2.0 * damping * omega * velocity;
        let velocity = velocity + acceleration * step;
        (value + velocity * step, velocity)
    }

    /// `spring` with the mouth's own constants.
    pub fn mouth_spring(value: f64, velocity: f64, target: f64, dt: f64) -> (f64, f64) {
        Self::spring(value, velocity, target, dt, 2.0 * PI / 0.25, 0.6)
    }

    // MARK: Living

    /// Breathing at rest: a slow rise and fall, too small to read as motion
    /// and enough to read as alive. Returns `(sx, sy)`.
    pub fn breath(time: f64) -> (f64, f64) {
        let wave = (time * 1.8).sin();
        (1.0 - wave * 0.012, 1.0 + wave * 0.022)
    }

    /// The tempo Kapa nods at while music plays. Nothing measures the music's
    /// own beat (ADR 0006), so this is a moderate one, near most pop.
    pub const MUSIC_TEMPO: f64 = 104.0;

    /// Nodding along: a dip on every beat that eases back up, and a sway from
    /// side to side every two. Returns `(dy, tilt, sy)`.
    pub fn bob(time: f64) -> (f64, f64, f64) {
        // A hair added, so a moment that is a beat lands on it rather than a
        // binary fraction short of it, with the dip all spent.
        let beats = time * Self::MUSIC_TEMPO / 60.0 + 1e-9;
        let phase = beats - beats.floor();
        let dip = (-phase * 7.0).exp();
        (dip * 3.2, (beats * PI).sin() * 4.0, 1.0 - dip * 0.05)
    }

    // MARK: Blinking

    /// The lids over a blink begun `elapsed` seconds ago: shut in 70 ms, open
    /// in 130, and fully open outside it.
    pub fn lid(since_blink: f64) -> f64 {
        let closed = 0.08;
        if since_blink < 0.0 {
            return 1.0;
        }
        if since_blink < KapaBlink::CLOSING {
            return 1.0 - (1.0 - closed) * Self::ease_in(since_blink / KapaBlink::CLOSING);
        }
        let opening = since_blink - KapaBlink::CLOSING;
        if opening < KapaBlink::OPENING {
            return closed + (1.0 - closed) * Self::ease_out(opening / KapaBlink::OPENING);
        }
        1.0
    }

    // MARK: One-off movements

    /// How long each reaction runs, in seconds.
    pub fn duration(reaction: Reaction) -> f64 {
        match reaction {
            Reaction::None => 0.0,
            Reaction::Nod => 0.35,
            Reaction::Gulp => 0.5,
            Reaction::Hop => 0.45,
        }
    }

    /// The reaction's kick `elapsed` seconds in; `None` once it is over.
    pub fn kick(reaction: Reaction, elapsed: f64) -> Option<Kick> {
        let length = Self::duration(reaction);
        if !(elapsed >= 0.0 && elapsed < length) {
            return None;
        }
        let p = elapsed / length;
        let wave = (p * PI).sin();
        match reaction {
            Reaction::None => None,
            Reaction::Nod => Some(Kick::new(1.0, 1.0 - wave * 0.07, wave * 1.5, 0.0)),
            Reaction::Gulp => {
                // Squash as it swallows, overshoot, settle.
                let squash = (p * 2.0 * PI).sin() * (1.0 - p);
                Some(Kick::new(1.0 + squash * 0.08, 1.0 - squash * 0.1, 0.0, 0.0))
            }
            Reaction::Hop => {
                let up = (p * PI).sin();
                let land = if p > 0.75 { ((p - 0.75) / 0.25 * PI).sin() } else { 0.0 };
                Some(Kick::new(1.0 + land * 0.06, 1.0 + up * 0.04 - land * 0.08, -up * 9.0, 0.0))
            }
        }
    }

    /// A tap on Kapa: squashed flat, and back with a bounce.
    pub const BOOP_LENGTH: f64 = 0.42;

    pub fn boop(elapsed: f64) -> Option<Kick> {
        if !(0.0..Self::BOOP_LENGTH).contains(&elapsed) {
            return None;
        }
        let p = elapsed / Self::BOOP_LENGTH;
        let squash = (p * 3.0 * PI).sin() * (1.0 - p).powf(1.5);
        Some(Kick::new(1.0 + squash * 0.16, 1.0 - squash * 0.2, 0.0, 0.0))
    }

    /// A shake of the head, for a dictation that failed: Coucou's error
    /// shake, side to side and settling.
    pub const SHAKE_LENGTH: f64 = 0.45;

    pub fn shake(elapsed: f64) -> Option<Kick> {
        if !(0.0..Self::SHAKE_LENGTH).contains(&elapsed) {
            return None;
        }
        let p = elapsed / Self::SHAKE_LENGTH;
        Some(Kick::new(1.0, 1.0, 0.0, (p * 4.0 * PI).sin() * 3.0 * (1.0 - p)))
    }

    // MARK: Eating a file

    /// How far Kapa opens its mouth for a file held over the Shelf: wider the
    /// nearer it is, never quite shut while one is held. `distance` and
    /// `reach` in the same units.
    pub fn appetite(distance: f64, reach: f64) -> f64 {
        let near = 1.0 - (distance / reach.max(1.0)).clamp(0.0, 1.0);
        0.35 + 0.65 * near * near
    }

    pub const GULP_LENGTH: f64 = 1.3;

    /// Kapa eating a dropped file, `elapsed` seconds after the drop: the file
    /// is drawn from above into a wide mouth, the mouth snaps shut, Kapa
    /// chews three times and settles, pleased. `None` once it is over.
    pub fn gulp(elapsed: f64) -> Option<Gulp> {
        if !(0.0..Self::GULP_LENGTH).contains(&elapsed) {
            return None;
        }
        Some(if elapsed < 0.28 {
            // The file sinks into the mouth, which opens to meet it.
            let p = elapsed / 0.28;
            Gulp {
                mouth: 0.6 + 0.4 * Self::ease_out(p),
                file: Some(Self::ease_in(p)),
                kick: Kick::new(1.0, 1.0 + 0.04 * p, 0.0, 0.0),
                pleased: false,
            }
        } else if elapsed < 0.38 {
            // Shut: a squash as it goes down.
            let p = (elapsed - 0.28) / 0.1;
            Gulp {
                mouth: 1.0 - Self::ease_in(p),
                file: None,
                kick: Kick::new(1.0 + 0.1 * p, 1.0 - 0.12 * p, 0.0, 0.0),
                pleased: false,
            }
        } else if elapsed < 1.0 {
            // Three chews.
            let p = (elapsed - 0.38) / 0.62;
            let chew = (p * 3.0 * PI).sin().abs();
            Gulp {
                mouth: chew * 0.25,
                file: None,
                kick: Kick::new(1.0 + chew * 0.05, 1.0 - chew * 0.07, 0.0, 0.0),
                pleased: true,
            }
        } else {
            let p = (elapsed - 1.0) / (Self::GULP_LENGTH - 1.0);
            Gulp { mouth: 0.0, file: None, kick: Kick::new(1.0, 1.0 + (p * PI).sin() * 0.03, 0.0, 0.0), pleased: true }
        })
    }

    // MARK: Easing

    pub fn ease_in(t: f64) -> f64 {
        t * t * t
    }

    pub fn ease_out(t: f64) -> f64 {
        1.0 - (1.0 - t.clamp(0.0, 1.0)).powi(3)
    }
}
