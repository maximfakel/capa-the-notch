use serde::{Deserialize, Serialize};

/// Seven bars, as drawn. Decorative: while the track plays each one moves to a
/// new height of its own every 0.3 seconds, so the bars never fall into a
/// rhythm; paused they sink to four-point dashes, and under Reduce Motion they
/// hold still. No audio is captured.
///
/// Heights are scales of the full bar (`height`: 30 under the strip, 34 on the
/// music page), from 0.3 to 1 — the drawing's shortest playing bar stands 10
/// of 30. A bar is scaled about its centre.
pub struct Equalizer;

impl Equalizer {
    pub const COUNT: usize = 7;
    /// Each bar 2 wide, 3 apart.
    pub const BAR_WIDTH: f64 = 2.0;
    pub const BAR_GAP: f64 = 3.0;
    pub const WIDTH: f64 = Self::COUNT as f64 * Self::BAR_WIDTH + (Self::COUNT as f64 - 1.0) * Self::BAR_GAP;
    /// A paused bar: a four-point dash.
    pub const REST: f64 = 4.0;
    pub const BEAT: f64 = 0.3;
    pub const MIN_SCALE: f64 = 0.3;
    pub const CORNER_RADIUS: f64 = 1.0;
    /// White at 0x8C / 255.
    pub const ALPHA: f64 = 0x8C as f64 / 255.0;
    pub const HEIGHT_UNDER_STRIP: f64 = 30.0;
    pub const HEIGHT_ON_PAGE: f64 = 34.0;

    /// The scale of a resting bar for a bar `height` tall.
    pub fn rest_scale(height: f64) -> f64 {
        Self::REST / height
    }

    /// The rectangle of bar `index` at `scale`, in a box `height` tall.
    pub fn bar(index: usize, scale: f64, height: f64) -> Bar {
        let h = height * scale;
        Bar { x: index as f64 * (Self::BAR_WIDTH + Self::BAR_GAP), y: (height - h) / 2.0, width: Self::BAR_WIDTH, height: h }
    }

    /// Where a bar is part-way through a beat from `from` to `to` scale,
    /// `progress` 0 to 1 through `BEAT`, on the ease-in-ease-out curve the
    /// drawing uses.
    pub fn scale_at(from: f64, to: f64, progress: f64) -> f64 {
        from + (to - from) * ease_in_out(progress)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Bar {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

/// A small deterministic generator for the bars' heights: the bars are
/// decoration, but a test can still pin them, and surfaces on every platform
/// choose from the same stream for the same seed.
#[derive(Debug, Clone)]
pub struct BarRandom(u64);

impl BarRandom {
    pub fn new(seed: u64) -> Self {
        Self(seed.max(1))
    }

    fn next_unit(&mut self) -> f64 {
        // xorshift64*
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        let v = self.0.wrapping_mul(0x2545_F491_4F6C_DD1D);
        (v >> 11) as f64 / (1u64 << 53) as f64
    }

    /// A new height for every bar, from a third of the way up to the top.
    pub fn step(&mut self) -> [f64; Equalizer::COUNT] {
        let mut scales = [0.0; Equalizer::COUNT];
        for s in &mut scales {
            *s = Equalizer::MIN_SCALE + (1.0 - Equalizer::MIN_SCALE) * self.next_unit();
        }
        scales
    }
}

/// `CAMediaTimingFunction(name: .easeInEaseOut)`: the cubic Bézier (0.42, 0,
/// 0.58, 1).
pub fn ease_in_out(t: f64) -> f64 {
    cubic_bezier(0.42, 0.0, 0.58, 1.0, t)
}

/// The y of a CSS-style cubic Bézier timing curve at time `x`.
pub fn cubic_bezier(x1: f64, y1: f64, x2: f64, y2: f64, x: f64) -> f64 {
    let x = x.clamp(0.0, 1.0);
    let coord = |a: f64, b: f64, t: f64| {
        let u = 1.0 - t;
        3.0 * u * u * t * a + 3.0 * u * t * t * b + t * t * t
    };
    // Solve coord(x1, x2, t) = x by bisection: monotonic for these curves.
    let (mut lo, mut hi) = (0.0, 1.0);
    for _ in 0..40 {
        let mid = (lo + hi) / 2.0;
        if coord(x1, x2, mid) < x { lo = mid } else { hi = mid }
    }
    coord(y1, y2, (lo + hi) / 2.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn seven_bars_two_wide_three_apart() {
        assert_eq!(Equalizer::COUNT, 7);
        assert_eq!(Equalizer::WIDTH, 32.0);
        assert_eq!(Equalizer::bar(6, 1.0, 34.0).x, 30.0);
        assert_eq!(Equalizer::bar(0, 1.0, 34.0), Bar { x: 0.0, y: 0.0, width: 2.0, height: 34.0 });
    }

    #[test]
    fn a_resting_bar_is_a_four_point_dash_centred() {
        let rest = Equalizer::rest_scale(30.0);
        let bar = Equalizer::bar(0, rest, 30.0);
        assert!((bar.height - 4.0).abs() < 1e-9);
        assert!((bar.y - 13.0).abs() < 1e-9, "centred in the 30");
    }

    #[test]
    fn heights_stay_between_a_third_and_the_top_and_never_settle_into_a_rhythm() {
        let mut random = BarRandom::new(7);
        let mut seen = std::collections::HashSet::new();
        for _ in 0..200 {
            let step = random.step();
            for s in step {
                assert!((Equalizer::MIN_SCALE..=1.0).contains(&s), "{s}");
                seen.insert((s * 1e6) as i64);
            }
            assert!(step.iter().any(|s| (s - step[0]).abs() > 1e-9), "the bars differ within a step");
        }
        assert!(seen.len() > 1000, "and from step to step");
    }

    #[test]
    fn the_same_seed_gives_the_same_bars() {
        assert_eq!(BarRandom::new(3).step(), BarRandom::new(3).step());
        assert_ne!(BarRandom::new(3).step(), BarRandom::new(4).step());
    }

    #[test]
    fn the_ease_runs_slow_fast_slow_from_zero_to_one() {
        assert!(ease_in_out(0.0).abs() < 1e-6 && (ease_in_out(1.0) - 1.0).abs() < 1e-6);
        assert!((ease_in_out(0.5) - 0.5).abs() < 1e-6, "symmetric about the middle");
        assert!(ease_in_out(0.1) < 0.1, "slow to start");
        assert!(ease_in_out(0.9) > 0.9, "slow to finish");
        let mut last = -1.0;
        for i in 0..=100 {
            let v = ease_in_out(i as f64 / 100.0);
            assert!(v >= last, "monotonic");
            last = v;
        }
        assert!((Equalizer::scale_at(0.4, 1.0, 1.0) - 1.0).abs() < 1e-6);
    }
}
