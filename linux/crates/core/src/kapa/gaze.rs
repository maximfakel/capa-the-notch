use super::face::KapaLook;
use serde::{Deserialize, Serialize};

/// One eye, drawn as if on a sphere: where it sits, how foreshortened it is,
/// and whether it has gone round the side of the head.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Eye {
    pub x: f64,
    pub y: f64,
    /// Foreshortening: 1 facing, narrower turned away.
    pub scale_x: f64,
    pub scale_y: f64,
    /// Gone round the side of the head.
    pub is_hidden: bool,
}

/// How far the mouth and brows move with the head.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Features {
    pub dx: f64,
    pub dy: f64,
}

/// The eyes are drawn as if on a sphere, so a turn of the head moves them
/// round the body and narrows the one turning away. The idea is Coucou's
/// (MIT); the numbers are this drawing's.
///
/// Everything is in the drawing's own units: a 100-unit square, y down, the
/// face centred at (52, 60) with the eyes 11 either side.
pub struct KapaGaze;

impl KapaGaze {
    pub const FACE_X: f64 = 52.0;
    pub const FACE_Y: f64 = 60.0;
    /// Half the body's width at the eyes, and half its height about them.
    pub const RADIUS_X: f64 = 40.0;
    pub const RADIUS_Y: f64 = 30.0;
    /// Each eye's own turn from the middle: sin(0.28) × 40 ≈ 11 units.
    pub const SPREAD: f64 = 0.28;

    /// One eye: `side` is −1 for the left, 1 for the right.
    pub fn eye(side: f64, look: KapaLook) -> Eye {
        let turn = side * Self::SPREAD + look.yaw;
        let facing = turn.cos() * look.pitch.cos();
        Eye {
            x: Self::FACE_X + turn.sin() * look.pitch.cos() * Self::RADIUS_X,
            y: Self::FACE_Y - look.pitch.sin() * Self::RADIUS_Y,
            // Measured against the eye's own resting turn, so looking ahead
            // draws the eye at exactly the size it was drawn.
            scale_x: turn.cos().max(0.18) / Self::SPREAD.cos(),
            scale_y: look.pitch.cos().max(0.18),
            is_hidden: facing < 0.04,
        }
    }

    /// How far the mouth and brows move with the head: less than the eyes,
    /// since they sit lower on the curve.
    pub fn features(look: KapaLook) -> Features {
        Features {
            dx: look.yaw.sin() * Self::RADIUS_X * 0.8,
            dy: -look.pitch.sin() * Self::RADIUS_Y * 0.6,
        }
    }
}
