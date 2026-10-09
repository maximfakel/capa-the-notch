//! The row's type measured: Geist Medium's advance widths and pair kerning
//! (generated from the font), less the row's tracking. Pango and the canvas
//! draw the same font, kerned, so a line that fits here fits there — to within
//! the one tracking Pango leaves off the line's last letter.

use crate::geist_widths::{ADVANCES, FALLBACK, KERNING, RIGHT_CLASSES, SPACE};
use capa_core::teleprompter::{TeleprompterLayout, TeleprompterTextSize, TextMeasure};

pub struct GeistMeasure;

/// A character's advance and kerning classes; one the font lacks kerns with nothing.
fn glyph(c: char) -> (f64, u8, u8) {
    let code = c as u32;
    match ADVANCES.binary_search_by_key(&code, |&(cp, ..)| cp) {
        Ok(i) => {
            let (_, advance, left, right) = ADVANCES[i];
            (advance as f64, left, right)
        }
        // The spaces the font lacks are made, as HarfBuzz makes them, from those it has.
        Err(_) => (
            match code {
                0x202F => SPACE as f64 / 2.0,
                0x2009 => 200.0,
                0x2007 => advance('0'),
                _ => FALLBACK as f64,
            },
            0,
            0,
        ),
    }
}

fn advance(c: char) -> f64 {
    glyph(c).0
}

/// What the font's `kern` feature adds between `prev` and `c`, in 1/1000 em.
fn kern(prev: char, c: char) -> f64 {
    let (_, left, _) = glyph(prev);
    let (_, _, right) = glyph(c);
    KERNING[left as usize * RIGHT_CLASSES + right as usize] as f64
}

impl TextMeasure for GeistMeasure {
    fn width(&self, text: &str, size: TeleprompterTextSize) -> f64 {
        let em = size.points();
        let tracking = TeleprompterLayout::kern(size);
        let mut prev = None;
        text.chars()
            .map(|c| {
                let pair = prev.map_or(0.0, |p| kern(p, c));
                prev = Some(c);
                (advance(c) + pair) / 1000.0 * em + tracking
            })
            .sum()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use TeleprompterTextSize::*;

    #[test]
    fn a_line_is_as_wide_as_its_letters_and_a_bigger_size_is_wider() {
        let m = GeistMeasure;
        assert_eq!(m.width("", Medium), 0.0);
        let hello = m.width("Hello", Medium);
        assert!(hello > 30.0 && hello < 60.0, "{hello}");
        assert!(m.width("Hello", Large) > hello);
        assert!(m.width("Hello", Small) < hello);
        assert!(m.width("Hello world", Medium) > hello);
    }

    #[test]
    fn russian_is_measured_too_not_given_the_fallback_for_every_letter() {
        let m = GeistMeasure;
        let w = m.width("Привет", Medium);
        assert!(w > 40.0 && w < 100.0, "{w}");
        assert_ne!(advance('П'), advance(' '));
        assert!(ADVANCES.windows(2).all(|p| p[0].0 < p[1].0), "sorted for the search");
    }

    #[test]
    fn the_tracking_is_taken_off_every_character() {
        let m = GeistMeasure;
        let one = m.width("i", Medium);
        let ten = m.width("iiiiiiiiii", Medium);
        assert!((ten - 10.0 * one - 9.0 * kern('i', 'i') / 1000.0 * 17.0).abs() < 1e-9);
        assert!((one - (advance('i') / 1000.0 * 17.0 - 0.17)).abs() < 1e-9);
    }

    #[test]
    fn pairs_are_kerned_as_the_font_kerns_them() {
        // Geist Medium's own values, as HarfBuzz applies them.
        assert_eq!(kern('A', 'V'), -109.0);
        assert_eq!(kern('T', 'o'), -80.0);
        assert_eq!(kern('H', 'H'), -18.0);
        assert_eq!(kern('A', ' '), 0.0, "{}", kern('A', ' '));
        assert_eq!(kern('\u{1F600}', 'A'), 0.0, "a character the font lacks kerns with nothing");
        let m = GeistMeasure;
        let av = m.width("AV", Medium);
        assert!(av < m.width("A", Medium) + m.width("V", Medium) - 1.5, "{av}");
        assert_eq!(KERNING.len() % RIGHT_CLASSES, 0);
        assert!(KERNING[..RIGHT_CLASSES].iter().all(|&k| k == 0), "class 0 kerns with nothing");
    }

    #[test]
    fn the_spaces_the_font_lacks_are_made_from_those_it_has() {
        assert_eq!(advance('\u{202F}'), SPACE as f64 / 2.0);
        assert_eq!(advance('\u{2007}'), advance('0'));
        assert_eq!(advance('\u{2009}'), 200.0);
        assert_eq!(advance('\u{A0}'), SPACE as f64);
    }
}
