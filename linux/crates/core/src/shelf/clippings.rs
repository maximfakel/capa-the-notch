//! The Clipboard tab's Clippings, newest first, in memory only (ADR 0005,
//! amended 2026-10-02): for pasting again what was copied a little while ago,
//! not an archive.

use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct ClippingId(pub u64);

/// One copied text the Shelf keeps: what was copied, and when (CONTEXT: Clipping).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Clipping {
    pub id: ClippingId,
    pub text: String,
    pub copied_at: DateTime<Utc>,
}

impl Clipping {
    /// The most of a Clipping's text a surface is sent: far more than four lines of a card hold.
    pub const PREVIEW_LENGTH: usize = 1_000;

    /// The Clipping as a surface shows it: its text cut at `PREVIEW_LENGTH` characters.
    pub fn preview(&self) -> Self {
        match self.text.char_indices().nth(Self::PREVIEW_LENGTH) {
            Some((end, _)) => Self { text: self.text[..end].to_owned(), ..self.clone() },
            None => self.clone(),
        }
    }
}

/// How many Clippings the Clipboard tab keeps, as chosen in Settings.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "u32", into = "u32")]
pub enum ClippingLimit {
    Twenty,
    Fifty,
    Hundred,
}

impl ClippingLimit {
    pub const ALL: [ClippingLimit; 3] = [ClippingLimit::Twenty, ClippingLimit::Fifty, ClippingLimit::Hundred];
    pub const DEFAULT: ClippingLimit = ClippingLimit::Twenty;

    pub fn raw(self) -> usize {
        match self {
            ClippingLimit::Twenty => 20,
            ClippingLimit::Fifty => 50,
            ClippingLimit::Hundred => 100,
        }
    }

    pub fn from_raw(raw: i64) -> Option<ClippingLimit> {
        match raw {
            20 => Some(ClippingLimit::Twenty),
            50 => Some(ClippingLimit::Fifty),
            100 => Some(ClippingLimit::Hundred),
            _ => None,
        }
    }
}

impl Default for ClippingLimit {
    fn default() -> Self {
        Self::DEFAULT
    }
}

impl TryFrom<u32> for ClippingLimit {
    type Error = String;
    fn try_from(raw: u32) -> Result<Self, String> {
        Self::from_raw(raw as i64).ok_or_else(|| format!("{raw} is not a Clipping limit"))
    }
}

impl From<ClippingLimit> for u32 {
    fn from(limit: ClippingLimit) -> u32 {
        limit.raw() as u32
    }
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct Clippings {
    items: Vec<Clipping>,
    next_id: u64,
}

impl Clippings {
    /// A text longer than this is not kept at all: cut short, it would paste
    /// without its end and no one would notice. (Counted in `char`s; Swift
    /// counts grapheme clusters, which can only be fewer.)
    pub const MAXIMUM_LENGTH: usize = 100_000;

    /// How long each is kept, unless that is switched off.
    pub fn lifetime() -> Duration {
        Duration::hours(24)
    }

    pub fn new() -> Self {
        Self::default()
    }

    pub fn items(&self) -> &[Clipping] {
        &self.items
    }

    /// Kept in front. A text copied again rises, with a new day, rather than
    /// appearing twice; past the limit the oldest give way.
    pub fn keep(&mut self, text: &str, at: DateTime<Utc>, limit: ClippingLimit) -> bool {
        if text.chars().count() > Self::MAXIMUM_LENGTH || text.trim().is_empty() {
            return false;
        }
        self.items.retain(|c| c.text != text);
        self.next_id += 1;
        self.items.insert(0, Clipping { id: ClippingId(self.next_id), text: text.to_owned(), copied_at: at });
        self.trim(limit);
        true
    }

    /// Fewer chosen: the oldest give way now, not at the next copy; the rest
    /// stay as they were.
    pub fn trim(&mut self, limit: ClippingLimit) {
        self.items.truncate(limit.raw());
    }

    /// Those a day old go, when expiry is on.
    pub fn forget_old(&mut self, now: DateTime<Utc>, expiring: bool) {
        if !expiring {
            return;
        }
        let lifetime = Self::lifetime();
        self.items.retain(|c| now - c.copied_at < lifetime);
    }

    pub fn remove(&mut self, id: ClippingId) {
        self.items.retain(|c| c.id != id);
    }

    pub fn clear(&mut self) {
        self.items.clear();
    }
}
