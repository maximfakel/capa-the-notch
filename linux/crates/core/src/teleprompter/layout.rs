//! The row's type and rhythm, from Paper "Notch — Compact — Teleprompter":
//! Geist Medium, 17 on 22 at the mockup's size, lines two points apart, a
//! little tighter tracked, set in after the controls' column. Points.
//!
//! Line breaking needs the type's real widths, so each surface supplies a
//! `TextMeasure` (CoreText on the Mac, Pango in GNOME).

use super::playback::PlaybackState;
use super::script::{TeleprompterScript, TeleprompterTextSize};
use serde::{Deserialize, Serialize};

/// The room every open page has under the strip, and the dots under it.
pub const PAGE_HEIGHT: f64 = 152.0;
pub const PAGE_SWITCHER_HEIGHT: f64 = 20.0;
/// What a reading Teleprompter adds under the strip while closed: as tall as an
/// open page and its dots.
pub const COMPACT_TELEPROMPTER_ROW: f64 = PAGE_HEIGHT + PAGE_SWITCHER_HEIGHT;

pub const ROW_WIDTH: f64 = 560.0;
/// The controls' column on the left, 15 points and 12 to the text.
pub const CONTROLS_WIDTH: f64 = 15.0;
pub const CONTROLS_GAP: f64 = 12.0;
pub const TEXT_INSET: f64 = 18.0 + CONTROLS_WIDTH + CONTROLS_GAP;
pub const TEXT_WIDTH: f64 = ROW_WIDTH - TEXT_INSET - 18.0;
pub const LINE_GAP: f64 = 2.0;
pub const TOP_INSET: f64 = 2.0;
pub const BOTTOM_INSET: f64 = 16.0;
/// Between the strip and the first line, as in the music row.
pub const STRIP_GAP: f64 = 6.0;
/// The open page's lines: under them stand the progress and controls.
pub const VISIBLE_LINES: usize = 3;

/// The width of text in the row's type at a size, kerning included. A surface
/// implements this with its own text engine.
pub trait TextMeasure {
    fn width(&self, text: &str, size: TeleprompterTextSize) -> f64;
}

/// A stand-in for tests and for a surface that has not measured yet: every
/// character `0.52` em wide, less the kerning.
pub struct ApproximateMeasure;

impl TextMeasure for ApproximateMeasure {
    fn width(&self, text: &str, size: TeleprompterTextSize) -> f64 {
        text.chars().count() as f64 * (0.52 * size.points() + TeleprompterLayout::kern(size))
    }
}

pub struct TeleprompterLayout;

impl TeleprompterLayout {
    /// The Teleprompter Row's lines: as many as its room holds. The row was
    /// made as tall as an open page so the surface keeps its height opening and
    /// closing, and three lines left the lower half of it dark; it now shows
    /// what comes next there — six lines at the smaller sizes, five at the
    /// largest. The line read is still the top one, by the camera.
    pub fn row_lines(size: TeleprompterTextSize) -> usize {
        let room = COMPACT_TELEPROMPTER_ROW - STRIP_GAP - TOP_INSET - BOTTOM_INSET + LINE_GAP;
        VISIBLE_LINES.max((room / Self::pitch(size)) as usize)
    }

    /// How bright each line in view is, from the one read down: the drawing's
    /// three — #FFF, #FFFFFF8C, #FFFFFF40 — then quieter still, so the eye
    /// stays at the top.
    pub fn line_opacity(row: usize) -> f64 {
        match row {
            0 => 1.0,
            1 => 0x8C as f64 / 255.0,
            2 => 0x40 as f64 / 255.0,
            _ => (0x40 as f64 / 255.0 * 0.82f64.powi(row as i32 - 2)).max(0.1),
        }
    }

    pub fn line_height(size: TeleprompterTextSize) -> f64 {
        (size.points() * 1.3).round()
    }

    pub fn pitch(size: TeleprompterTextSize) -> f64 {
        Self::line_height(size) + LINE_GAP
    }

    pub fn kern(size: TeleprompterTextSize) -> f64 {
        -0.01 * size.points()
    }

    /// The row's text area under the strip: its lines and their insets.
    pub fn text_area_height(size: TeleprompterTextSize) -> f64 {
        let lines = Self::row_lines(size) as f64;
        TOP_INSET + lines * Self::line_height(size) + (lines - 1.0) * LINE_GAP + BOTTOM_INSET
    }

    /// Everything the row adds under the strip: as tall as an open page and its
    /// dots, whatever the size.
    pub fn row_height(_size: TeleprompterTextSize) -> f64 {
        COMPACT_TELEPROMPTER_ROW
    }

    /// The Script broken into the lines the row shows: its own line breaks
    /// kept, blank lines kept as gaps, long lines wrapped where the type does.
    pub fn lines(script: &str, size: TeleprompterTextSize, width: f64, measure: &dyn TextMeasure) -> Vec<String> {
        TeleprompterScript::lines(script, |paragraph| wrap_paragraph(paragraph, size, width, measure))
    }

    /// The Script's vertical offset in the row at a place in it: lines move up
    /// as the place moves down.
    pub fn offset(position: f64, size: TeleprompterTextSize) -> f64 {
        TOP_INSET - position * Self::pitch(size)
    }

    /// The lines worth having drawn at a place: one before for the one leaving
    /// and a few after for those arriving; the rest are let go, so a long
    /// Script costs no more than a short one.
    pub fn lines_to_draw(position: f64, size: TeleprompterTextSize, line_count: usize) -> Option<std::ops::RangeInclusive<usize>> {
        if line_count == 0 {
            return None;
        }
        let current = position.floor().max(0.0) as usize;
        let first = current.saturating_sub(1);
        let last = (current + Self::row_lines(size) + 3).min(line_count - 1);
        (first <= last).then_some(first..=last)
    }

    /// The row's fade: one band per line in view, as `(from, to, opacity)` in
    /// fractions of the row's text-area height. The current line is full white,
    /// the next at 55%, the one after at 25%, and quieter below. Each changes
    /// to the next within the two points between lines, so a line at rest is one
    /// colour and a moving one passes from band to band.
    pub fn fade_bands(size: TeleprompterTextSize) -> Vec<FadeBand> {
        let height = Self::text_area_height(size).max(1.0);
        let line_height = Self::line_height(size);
        let pitch = Self::pitch(size);
        let lines = Self::row_lines(size);
        (0..lines)
            .map(|line| {
                let top = TOP_INSET + line as f64 * pitch;
                FadeBand {
                    from: if line == 0 { 0.0 } else { top / height },
                    to: if line == lines - 1 { 1.0 } else { (top + line_height) / height },
                    opacity: Self::line_opacity(line),
                }
            })
            .collect()
    }

    /// The page's preview: the current line and the next two, at the three
    /// brightnesses; a line the Script does not have is a blank.
    pub fn preview(lines: &[String], position: f64) -> [PreviewLine; VISIBLE_LINES] {
        let current = (position.floor().max(0.0) as usize).min(lines.len().saturating_sub(1));
        std::array::from_fn(|i| PreviewLine {
            text: lines.get(current + i).cloned().unwrap_or_else(|| " ".into()),
            opacity: Self::line_opacity(i),
        })
    }

    /// The page's text area height: three lines and their gaps.
    pub fn preview_height(size: TeleprompterTextSize) -> f64 {
        VISIBLE_LINES as f64 * Self::line_height(size) + (VISIBLE_LINES as f64 - 1.0) * LINE_GAP
    }

    /// How far along the progress bar's white capsule goes: where the Script
    /// is, with four points at the start even before it moves.
    pub fn progress_fill_width(bar_width: f64, fraction: f64) -> f64 {
        (bar_width * fraction.clamp(0.0, 1.0)).max(4.0)
    }

    /// The speed as the page shows it: "1.25x".
    pub fn speed_text(multiplier: f64) -> String {
        format!("{multiplier:.2}x")
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct FadeBand {
    pub from: f64,
    pub to: f64,
    pub opacity: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PreviewLine {
    pub text: String,
    pub opacity: f64,
}

/// What a click on the row's first control would do, drawn as it is in Music:
/// pause while it runs, play otherwise.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ActionGlyph {
    Pause,
    Play,
}

impl PlaybackState {
    pub fn action_glyph(self) -> ActionGlyph {
        if self == Self::Running { ActionGlyph::Pause } else { ActionGlyph::Play }
    }

    /// What VoiceOver — or any screen reader — hears: the state, never the Script.
    pub fn spoken(self) -> &'static str {
        match self {
            Self::Running => "Teleprompter, running",
            Self::Paused => "Teleprompter, paused",
            Self::Finished => "Teleprompter, finished",
            Self::Stopped => "Teleprompter, stopped",
        }
    }
}

/// `CTTypesetterSuggestLineBreak` in one function, by the Unicode line
/// breaking rules as ICU (and so CoreText) applies them to the characters a
/// Script holds: lines break between words; after a hyphen inside a word
/// (`well-|known`) but not before a figure (`10-20`, `-5`); on either side of
/// an em dash (`word|—|word`); and after a slash (`and/|or`, but `1/2` whole).
/// A no-break space (U+00A0, U+202F, U+2007) is part of its word. Trailing
/// spaces hang off the end of a line and are not measured, and a word wider
/// than the row is broken where it no longer fits (at least one letter to a
/// line, so it always ends).
pub fn wrap_paragraph(paragraph: &str, size: TeleprompterTextSize, width: f64, measure: &dyn TextMeasure) -> Vec<String> {
    let chars: Vec<char> = paragraph.chars().collect();
    let fits = |from: usize, to: usize| {
        let text: String = chars[from..to].iter().collect();
        measure.width(text.trim_end_matches(is_break_space), size) <= width
    };
    let mut lines = vec![];
    let mut start = 0;
    while start < chars.len() {
        // Candidate line ends: just after each run of spaces following a word,
        // and at each place inside a word where it may break.
        let mut best = None;
        let mut i = start;
        while i < chars.len() {
            let word = i;
            while i < chars.len() && !is_break_space(chars[i]) {
                i += 1;
                if i < chars.len() && !is_break_space(chars[i]) && breaks_inside(&chars, word, i) {
                    break;
                }
            }
            while i < chars.len() && is_break_space(chars[i]) {
                i += 1;
            }
            if fits(start, i) {
                best = Some(i);
            } else {
                break;
            }
        }
        let end = match best {
            Some(end) => end,
            None => {
                // One word wider than the row: break inside it.
                let mut end = start + 1;
                while end < chars.len() && fits(start, end + 1) {
                    end += 1;
                }
                end
            }
        };
        let line: String = chars[start..end].iter().collect();
        lines.push(line.trim_matches(|c: char| c.is_whitespace()).to_owned());
        start = end;
    }
    lines
}

/// A space a line may break at: any but the no-break ones, which hold the
/// words either side of them together.
fn is_break_space(c: char) -> bool {
    c.is_whitespace() && !matches!(c, '\u{A0}' | '\u{202F}' | '\u{2007}')
}

const EM_DASH: char = '\u{2014}';

/// Whether a line may end between `chars[i - 1]` and `chars[i]`, inside the
/// word that began at `word`.
fn breaks_inside(chars: &[char], word: usize, i: usize) -> bool {
    let (prev, next) = (chars[i - 1], chars[i]);
    // Nothing opens a line with closing punctuation or a hyphen, and nothing
    // breaks next to a quotation mark or after an opening bracket.
    if matches!(next, ')' | ']' | '}' | '!' | '?' | ',' | '.' | ':' | ';' | '/' | '-' | '\u{2010}' | '\u{2026}')
        || is_quote(prev)
        || is_quote(next)
        || matches!(prev, '(' | '[' | '{')
    {
        return false;
    }
    let leading = i - 1 == word;
    match prev {
        // A minus before a figure, or one opening a word, is not a break.
        '-' => !leading && !next.is_ascii_digit(),
        '\u{2010}' => !leading,
        EM_DASH => next != EM_DASH,
        // A fraction stays whole.
        '/' => !(next.is_ascii_digit() && i >= 2 && chars[i - 2].is_ascii_digit()),
        _ => next == EM_DASH,
    }
}

fn is_quote(c: char) -> bool {
    matches!(c, '"' | '\'' | '\u{AB}' | '\u{BB}' | '\u{2018}' | '\u{2019}' | '\u{201A}' | '\u{201C}' | '\u{201D}' | '\u{201E}' | '\u{2039}' | '\u{203A}')
}

#[cfg(test)]
mod tests {
    use super::*;
    use TeleprompterTextSize::*;

    #[test]
    fn the_row_holds_six_lines_at_the_smaller_sizes_and_five_at_the_largest() {
        assert_eq!(TeleprompterLayout::row_lines(Small), 6);
        assert_eq!(TeleprompterLayout::row_lines(Medium), 6);
        assert_eq!(TeleprompterLayout::row_lines(Large), 5);
    }

    #[test]
    fn line_heights_and_pitch_follow_the_type() {
        assert_eq!(TeleprompterLayout::line_height(Medium), 22.0, "17 on 22");
        assert_eq!(TeleprompterLayout::pitch(Medium), 24.0, "two apart");
        assert_eq!(TeleprompterLayout::line_height(Small), 20.0, "19.5 rounds up");
        assert_eq!(TeleprompterLayout::line_height(Large), 26.0);
        assert!((TeleprompterLayout::kern(Large) + 0.2).abs() < 1e-9, "a little tighter tracked");
    }

    #[test]
    fn the_text_area_is_the_lines_and_their_insets() {
        // 2 + 6 × 22 + 5 × 2 + 16
        assert_eq!(TeleprompterLayout::text_area_height(Medium), 160.0);
        assert_eq!(TeleprompterLayout::row_height(Medium), 172.0, "as tall as an open page and its dots");
        assert_eq!(TEXT_INSET, 45.0);
        assert_eq!(TEXT_WIDTH, 497.0);
    }

    #[test]
    fn lines_get_quieter_down_the_row_and_never_vanish() {
        assert_eq!(TeleprompterLayout::line_opacity(0), 1.0);
        assert!((TeleprompterLayout::line_opacity(1) - 0x8C as f64 / 255.0).abs() < 1e-12);
        assert!((TeleprompterLayout::line_opacity(2) - 0x40 as f64 / 255.0).abs() < 1e-12);
        let mut last = 1.0;
        for row in 1..12 {
            let o = TeleprompterLayout::line_opacity(row);
            assert!(o <= last && o >= 0.1, "{row}: {o}");
            last = o;
        }
        assert_eq!(TeleprompterLayout::line_opacity(40), 0.1);
    }

    #[test]
    fn the_fade_has_a_band_per_line_that_runs_from_top_to_bottom() {
        let bands = TeleprompterLayout::fade_bands(Medium);
        assert_eq!(bands.len(), 6);
        assert_eq!(bands[0].from, 0.0);
        assert_eq!(bands[5].to, 1.0);
        for pair in bands.windows(2) {
            let gap = pair[1].from - pair[0].to;
            assert!(gap >= 0.0 && gap <= (LINE_GAP + 0.01) / TeleprompterLayout::text_area_height(Medium), "one band ends and the next begins within the two points between lines");
            assert!(pair[1].opacity < pair[0].opacity);
        }
    }

    #[test]
    fn what_to_draw_is_one_line_before_and_a_few_after() {
        assert_eq!(TeleprompterLayout::lines_to_draw(0.0, Medium, 100), Some(0..=9));
        assert_eq!(TeleprompterLayout::lines_to_draw(10.7, Medium, 100), Some(9..=19));
        assert_eq!(TeleprompterLayout::lines_to_draw(98.0, Medium, 100), Some(97..=99));
        assert_eq!(TeleprompterLayout::lines_to_draw(0.0, Medium, 0), None);
        assert_eq!(TeleprompterLayout::lines_to_draw(0.0, Medium, 1), Some(0..=0));
    }

    #[test]
    fn the_script_moves_up_by_a_pitch_a_line() {
        assert_eq!(TeleprompterLayout::offset(0.0, Medium), 2.0);
        assert_eq!(TeleprompterLayout::offset(2.5, Medium), 2.0 - 60.0);
    }

    #[test]
    fn the_page_previews_the_current_line_and_the_next_two() {
        let lines: Vec<String> = ["a", "b", "c", "d"].iter().map(|s| s.to_string()).collect();
        let p = TeleprompterLayout::preview(&lines, 1.4);
        assert_eq!(p.iter().map(|l| l.text.as_str()).collect::<Vec<_>>(), ["b", "c", "d"]);
        assert_eq!(p[0].opacity, 1.0);
        let end = TeleprompterLayout::preview(&lines, 3.0);
        assert_eq!(end.iter().map(|l| l.text.as_str()).collect::<Vec<_>>(), ["d", " ", " "], "a line the Script lacks is a blank");
        assert_eq!(TeleprompterLayout::preview(&[], 0.0)[0].text, " ");
        assert_eq!(TeleprompterLayout::preview_height(Medium), 70.0);
    }

    #[test]
    fn the_progress_capsule_is_four_points_at_the_start() {
        assert_eq!(TeleprompterLayout::progress_fill_width(400.0, 0.0), 4.0);
        assert_eq!(TeleprompterLayout::progress_fill_width(400.0, 0.5), 200.0);
        assert_eq!(TeleprompterLayout::progress_fill_width(400.0, 3.0), 400.0);
        assert_eq!(TeleprompterLayout::speed_text(1.25), "1.25x");
        assert_eq!(TeleprompterLayout::speed_text(1.0), "1.00x");
    }

    #[test]
    fn the_first_control_pauses_while_running_and_plays_otherwise() {
        assert_eq!(PlaybackState::Running.action_glyph(), ActionGlyph::Pause);
        for s in [PlaybackState::Paused, PlaybackState::Stopped, PlaybackState::Finished] {
            assert_eq!(s.action_glyph(), ActionGlyph::Play);
        }
        assert_eq!(PlaybackState::Paused.spoken(), "Teleprompter, paused");
    }

    /// Each character 10 wide: a row of `n` characters is `10 n`.
    struct Tens;
    impl TextMeasure for Tens {
        fn width(&self, text: &str, _: TeleprompterTextSize) -> f64 {
            text.chars().count() as f64 * 10.0
        }
    }

    #[test]
    fn long_paragraphs_wrap_between_words() {
        let lines = wrap_paragraph("the quick brown fox jumps", Medium, 100.0, &Tens);
        assert_eq!(lines, ["the quick", "brown fox", "jumps"]);
    }

    #[test]
    fn trailing_spaces_hang_and_are_not_measured() {
        // "abcd efgh" is 90 wide; with the space after "abcd" it would be 50, fine either way,
        // but "abcdefghij " is 10 characters plus a hanging space: it fits in 100.
        let lines = wrap_paragraph("abcdefghij klm", Medium, 100.0, &Tens);
        assert_eq!(lines, ["abcdefghij", "klm"]);
    }

    #[test]
    fn a_word_wider_than_the_row_is_broken_where_it_stops_fitting() {
        let lines = wrap_paragraph("abcdefghijklmnopqrstuvwxyz", Medium, 100.0, &Tens);
        assert_eq!(lines, ["abcdefghij", "klmnopqrst", "uvwxyz"]);
        let tiny = wrap_paragraph("abc", Medium, 1.0, &Tens);
        assert_eq!(tiny, ["a", "b", "c"], "always ends, a letter at least to a line");
    }

    #[test]
    fn a_short_paragraph_is_one_line_and_the_script_keeps_its_gaps() {
        let lines = TeleprompterLayout::lines("one two\n\nthree four five six seven", Medium, 100.0, &Tens);
        assert_eq!(lines, ["one two", "", "three four", "five six", "seven"]);
        assert!(TeleprompterLayout::lines("", Medium, 100.0, &Tens).is_empty());
    }

    #[test]
    fn a_hyphenated_word_may_break_after_its_hyphen() {
        let lines = wrap_paragraph("aaaa well-known", Medium, 100.0, &Tens);
        assert_eq!(lines, ["aaaa well-", "known"]);
        let proper = wrap_paragraph("aaaa well\u{2010}known", Medium, 100.0, &Tens);
        assert_eq!(proper, ["aaaa well\u{2010}", "known"]);
        assert_eq!(wrap_paragraph("aa -5 b", Medium, 40.0, &Tens), ["aa", "-5 b"], "a leading minus is not a break");
        assert_eq!(wrap_paragraph("one-two", Medium, 100.0, &Tens), ["one-two"], "what fits stays whole");
    }

    /// Where a line may end, as `|`: every break the wrap would take at any width.
    fn breaks(text: &str) -> String {
        let chars: Vec<char> = text.chars().collect();
        let mut out = String::new();
        let mut word = 0;
        for (i, &c) in chars.iter().enumerate() {
            // A word begins after a space, or breaks inside where the wrap would.
            if i > 0 && !is_break_space(c) && (is_break_space(chars[i - 1]) || breaks_inside(&chars, word, i)) {
                out.push('|');
                word = i;
            }
            out.push(c);
        }
        out
    }

    #[test]
    fn a_no_break_space_holds_its_words_together() {
        for space in ['\u{A0}', '\u{202F}', '\u{2007}'] {
            let text = format!("aaaa 10{space}000 bb");
            assert_eq!(wrap_paragraph(&text, Medium, 80.0, &Tens), ["aaaa".to_string(), format!("10{space}000"), "bb".into()], "{space:?}");
            let text = format!("aa{space}bbbbbbbbbbbb");
            assert_eq!(wrap_paragraph(&text, Medium, 100.0, &Tens).len(), 2, "too long, it breaks only where it no longer fits");
        }
        assert_eq!(wrap_paragraph("aa bbb\u{A0}c dd", Medium, 60.0, &Tens), ["aa", "bbb\u{A0}c", "dd"], "the space is no place to end \"aa bbb\"");
    }

    /// The breaks ICU's line iterator (CoreText's rules) finds in the same strings.
    #[test]
    fn lines_break_where_the_unicode_rules_allow() {
        assert_eq!(breaks("well-known"), "well-|known");
        assert_eq!(breaks("pages 10-20"), "pages |10-20", "no break before a figure");
        assert_eq!(breaks("a-5 5-a"), "a-5 |5-|a");
        assert_eq!(breaks("aa -5 b"), "aa |-5 |b", "a leading minus is not a break");
        assert_eq!(breaks("one-two-three"), "one-|two-|three");
        assert_eq!(breaks("a--b x-) a-(b)"), "a--|b |x-) |a-|(b)");
        assert_eq!(breaks("a\u{2010}b a\u{2010}1"), "a\u{2010}|b |a\u{2010}|1");
        assert_eq!(breaks("word\u{2014}word"), "word|\u{2014}|word", "either side of an em dash");
        assert_eq!(breaks("a \u{2014} b"), "a |\u{2014} |b");
        assert_eq!(breaks("\u{2014}\u{2014}x"), "\u{2014}\u{2014}|x", "not between two");
        assert_eq!(breaks("x\u{2014}\"y\""), "x|\u{2014}\"y\"", "nor next to a quote");
        assert_eq!(breaks("and/or"), "and/|or");
        assert_eq!(breaks("1/2 a/1 /usr"), "1/2 |a/|1 |/|usr", "a fraction stays whole");
        assert_eq!(breaks("http://x.com/a/b"), "http://|x.com/|a/|b");
        assert_eq!(breaks("a/-b a/\"b\""), "a/-|b |a/\"b\"");
        assert_eq!(breaks("a.b, c:d"), "a.b, |c:d");
        assert_eq!(breaks("\u{AB}a-b\u{BB}"), "\u{AB}a-|b\u{BB}");
    }

    #[test]
    fn an_em_dash_or_a_slash_lets_a_long_line_break() {
        assert_eq!(wrap_paragraph("aaaaaa\u{2014}bbbbbb", Medium, 100.0, &Tens), ["aaaaaa\u{2014}", "bbbbbb"]);
        assert_eq!(wrap_paragraph("aaaaa/bbbbbbb", Medium, 100.0, &Tens), ["aaaaa/", "bbbbbbb"]);
        assert_eq!(wrap_paragraph("aaaa 12345-6789", Medium, 100.0, &Tens), ["aaaa", "12345-6789"], "a range of figures stays whole");
    }

    #[test]
    fn cyrillic_wraps_by_characters_not_bytes() {
        let lines = wrap_paragraph("Добрый день всем", Medium, 100.0, &Tens);
        assert_eq!(lines, ["Добрый", "день всем"]);
    }

    #[test]
    fn the_approximate_measure_widens_with_the_size() {
        let a = ApproximateMeasure.width("hello", Small);
        let b = ApproximateMeasure.width("hello", Large);
        assert!(b > a && a > 0.0);
    }
}
