use super::face::Eyes;

/// When Kapa blinks: every 2.2 to 5.4 seconds, and about one time in five
/// twice. Coucou's rhythm, which reads as alive without reading as busy.
pub struct KapaBlink;

impl KapaBlink {
    pub const SHORTEST: f64 = 2.2;
    pub const SPREAD: f64 = 3.2;
    pub const DOUBLE_CHANCE: f64 = 0.22;
    pub const DOUBLE_GAP: f64 = 0.23;
    /// Shut quickly, open a little slower.
    pub const CLOSING: f64 = 0.07;
    pub const OPENING: f64 = 0.13;

    /// The wait before the next blink, in seconds, from a uniform draw in 0...1.
    pub fn delay(draw: f64) -> f64 {
        Self::SHORTEST + Self::SPREAD * draw.clamp(0.0, 1.0)
    }

    pub fn is_double(draw: f64) -> bool {
        draw < Self::DOUBLE_CHANCE
    }

    /// Eyes that are already shut, or arcs, have no lids to drop.
    pub fn blinks(eyes: Eyes) -> bool {
        match eyes {
            Eyes::Open | Eyes::Wide | Eyes::Lidded | Eyes::Narrowed | Eyes::Uneven => true,
            Eyes::Happy | Eyes::Closed => false,
        }
    }
}
