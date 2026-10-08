//! The Music Module's measures, from Paper "Notch — Compact — Playing" and
//! "Notch — Expanded — Playing". Points; surfaces draw at these sizes.

/// The room every open page has under the strip.
pub const PAGE_HEIGHT: f64 = 152.0;

/// Six points under the strip, the artwork's 34, and 14 to the rounded edge:
/// the closed surface is 92 with a track, as drawn.
pub const ROW_HEIGHT: f64 = 54.0;
pub const ROW_ARTWORK: f64 = 34.0;
/// The page's height less the six points between the strip and it, so the
/// artwork stands the whole page tall: 146.
pub const PAGE_ARTWORK: f64 = PAGE_HEIGHT - 6.0;

/// Type: Geist, sizes and weights.
pub const TITLE_SIZE: f64 = 15.0; // medium
pub const ARTIST_SIZE: f64 = 11.0;
pub const TIME_SIZE: f64 = 11.0;

/// The artwork's corner radius on the page and in the row.
pub const PAGE_ARTWORK_RADIUS: f64 = 20.0;
pub const ROW_ARTWORK_RADIUS: f64 = 10.0;

/// The volume bar: a 88 × 4 capsule, a speaker button 18 × 22 at its left,
/// eight apart; the bar answers a drag over 8 points beyond its edges.
pub const VOLUME_BAR_WIDTH: f64 = 88.0;
pub const VOLUME_BAR_HEIGHT: f64 = 4.0;
pub const VOLUME_BUTTON: (f64, f64) = (18.0, 22.0);
pub const VOLUME_SPACING: f64 = 8.0;
pub const VOLUME_HIT_SLOP: f64 = 8.0;
/// The progress bar: 4 tall, answering a drag 6 points beyond its edges.
pub const PROGRESS_BAR_HEIGHT: f64 = 4.0;
pub const PROGRESS_HIT_SLOP: f64 = 6.0;

/// The music page's idle layout: artwork, 20 apart from the text column, which
/// is 121 tall; the page has 18 either side and 6 above.
pub const IDLE_SPACING: f64 = 20.0;
pub const IDLE_COLUMN_HEIGHT: f64 = 121.0;
pub const IDLE_ARTWORK_OPACITY: f64 = 0.35;
