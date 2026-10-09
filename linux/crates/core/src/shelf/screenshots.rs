//! The folder screenshots are saved to, which the Shelf watches while it takes
//! from the clipboard (ADR 0005, amended 2026-10-02): each new screenshot
//! there goes under Screenshots, as a reference to its file.
//!
//! macOS marks a screenshot nowhere a program can read — no attribute, nothing
//! Spotlight is sure to have yet — so one is known as macOS names it: the name
//! it was told to use, or its own in the Mac's language, and the type it was
//! told to save. Other systems name theirs in other ways (`Naming`).

use super::model::{file_name, path_extension, standardize};
use chrono::{DateTime, Utc};
use serde_json::{Map, Value};
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

/// What `com.apple.screencapture` says, where it says anything.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Settings {
    /// The name given in place of "Screenshot", if any (`name`).
    pub name: Option<String>,
    /// The file type, "png" unless told otherwise (`type`).
    pub kind: Option<String>,
}

impl Settings {
    pub fn new(name: Option<String>, kind: Option<String>) -> Self {
        Self { name, kind: kind.map(|k| normalised(&k)) }
    }

    /// From the `com.apple.screencapture` domain; anything unusable is as if
    /// unsaid.
    pub fn from_domain(domain: &Map<String, Value>) -> Self {
        let text = |key: &str| {
            domain
                .get(key)
                .and_then(Value::as_str)
                .filter(|s| !s.trim().is_empty())
                .map(str::to_owned)
        };
        Self::new(text("name"), text("type"))
    }
}

/// One thing in the folder, as the file system describes it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    pub path: PathBuf,
    pub created: DateTime<Utc>,
    pub is_regular_file: bool,
}

/// How screenshots are named, so a file in the folder can be told from any
/// other. macOS's own scheme is the reference; the others are what the
/// platform's own tools write.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Naming {
    /// macOS, as `com.apple.screencapture` was told.
    MacOs(Settings),
    /// GNOME Shell and its screenshot tool: "Screenshot from 2026-10-02
    /// 10-00-01.png", and "(2)" for a second in the same second.
    Gnome,
    /// KDE's Spectacle: "Screenshot_20261002_100001.png".
    Spectacle,
}

impl Naming {
    pub fn for_platform(platform: super::take::Platform, desktop: Option<&str>) -> Naming {
        use super::take::Platform::*;
        match platform {
            MacOs => Naming::MacOs(Settings::default()),
            Linux => {
                if desktop.is_some_and(|d| d.to_uppercase().contains("KDE")) {
                    Naming::Spectacle
                } else {
                    Naming::Gnome
                }
            }
        }
    }

    pub fn is_screenshot(&self, name: &str) -> bool {
        match self {
            Naming::MacOs(settings) => is_screenshot(name, settings),
            Naming::Gnome => gnome_named(name),
            Naming::Spectacle => spectacle_named(name),
        }
    }
}

/// Whether macOS saves screenshots to a file at all, rather than to the
/// clipboard, Preview, Mail or Messages. Newer macOS keeps a target for
/// screenshots apart from screen recordings; older keeps one for both.
pub fn saves_to_folder(domain: &Map<String, Value>) -> bool {
    let target = domain
        .get("target-screenshot")
        .and_then(Value::as_str)
        .or_else(|| domain.get("target").and_then(Value::as_str))
        .unwrap_or("file");
    target == "file"
}

/// Where macOS saves screenshots, from the `com.apple.screencapture` domain.
/// `location-last` is only the last folder the menu offers, not where
/// screenshots go.
pub fn location_from_domain(domain: &Map<String, Value>, home: &Path) -> PathBuf {
    location(domain.get("location").and_then(Value::as_str), home)
}

/// Where macOS saves screenshots: the folder chosen (`location`), with ~ for
/// home, or the Desktop.
pub fn location(setting: Option<&str>, home: &Path) -> PathBuf {
    let Some(setting) = setting.map(str::trim).filter(|s| !s.is_empty()) else {
        return home.join("Desktop");
    };
    let path = match setting.strip_prefix('~') {
        Some(rest) => PathBuf::from(format!("{}{}", home.display(), rest)),
        None => PathBuf::from(setting),
    };
    standardize(&path)
}

/// The screenshots saved since `since` and not taken yet, oldest first, so that
/// the newest lands in front of the Shelf.
pub fn new_screenshots(entries: &[Entry], since: DateTime<Utc>, already_taken: &BTreeSet<PathBuf>, naming: &Naming) -> Vec<PathBuf> {
    let mut found: Vec<&Entry> = entries
        .iter()
        .filter(|e| {
            e.is_regular_file && e.created >= since && !already_taken.contains(&e.path) && naming.is_screenshot(&file_name(&e.path))
        })
        .collect();
    found.sort_by_key(|e| e.created);
    found.into_iter().map(|e| e.path.clone()).collect()
}

/// macOS writes a screenshot as a hidden file first and names it once it is
/// whole, so a hidden file is one still being written.
///
/// After its name macOS writes nothing, a number, or the day and time:
/// "Screenshot", "Screenshot 2", "Screenshot 2026-10-02 at 10.00.01 (2)".
/// Without a name of one's own, any name before the day and time will do, for
/// the languages other than these — at the cost of taking a file someone else
/// named the same way.
pub fn is_screenshot(name: &str, settings: &Settings) -> bool {
    if name.starts_with('.') {
        return false;
    }
    if normalised(path_extension(name)) != settings.kind.as_deref().unwrap_or("png") {
        return false;
    }
    let stem = strip_extension(name);
    // macOS 27 writes no-break spaces round its dash and before the time, and
    // a narrow one before AM or PM; any space is a space here.
    let base: String = stem.chars().map(|c| if c.is_whitespace() { ' ' } else { c }).collect();
    let own: Vec<&str> = match &settings.name {
        Some(name) => vec![name.as_str()],
        None => OWN_NAMES.to_vec(),
    };
    let named = own.iter().any(|own| base.strip_prefix(*own).is_some_and(after_name));
    named || (settings.name.is_none() && any_name_dated(&base))
}

/// The names macOS gives in English, before and since Mojave, and in Russian.
const OWN_NAMES: [&str; 3] = ["Screenshot", "Screen Shot", "Снимок экрана"];

/// What follows the name: nothing, " 2", or " " then an optional dash and the
/// day and time — `^( \d+| (— )?DATED)?$`. Since macOS 27 a dash stands between
/// the name and the day: "Снимок экрана — 2026-10-02 в 18.03.21".
fn after_name(rest: &str) -> bool {
    if rest.is_empty() {
        return true;
    }
    let Some(rest) = rest.strip_prefix(' ') else { return false };
    if !rest.is_empty() && rest.chars().all(|c| c.is_ascii_digit()) {
        return true;
    }
    dated(rest.strip_prefix("— ").unwrap_or(rest))
}

/// `^.+ DATED$`: any name, a space, then the day and time.
fn any_name_dated(base: &str) -> bool {
    let tokens: Vec<&str> = base.split(' ').collect();
    (1..tokens.len()).any(|start| {
        let prefix = tokens[..start].join(" ");
        !prefix.is_empty()
            && !prefix.contains(['\n', '\r', '\u{2028}', '\u{2029}', '\u{85}'])
            && dated(&tokens[start..].join(" "))
    })
}

/// `\d{4}-\d{2}-\d{2} \S+ \d{1,2}[.:]\d{2}[.:]\d{2}( [AP]M)?( \(\d+\)| \d+)?`
/// over the whole string: a day, a word, and a time, as every language macOS
/// speaks writes them, then "AM"/"PM", then "(2)" or "2" when there were two in
/// one second.
fn dated(text: &str) -> bool {
    let tokens: Vec<&str> = text.split(' ').collect();
    if tokens.len() < 3 {
        return false;
    }
    let (day, word, time) = (tokens[0], tokens[1], tokens[2]);
    if !is_day(day) || word.is_empty() || !is_time(time) {
        return false;
    }
    let mut rest = &tokens[3..];
    if let Some((first, tail)) = rest.split_first() {
        if *first == "AM" || *first == "PM" {
            rest = tail;
        }
    }
    match rest {
        [] => true,
        [one] => {
            let counted = one.strip_prefix('(').and_then(|s| s.strip_suffix(')')).is_some_and(all_digits);
            counted || all_digits(one)
        }
        _ => false,
    }
}

fn all_digits(s: &str) -> bool {
    !s.is_empty() && s.chars().all(|c| c.is_ascii_digit())
}

fn is_day(s: &str) -> bool {
    let b = s.as_bytes();
    b.len() == 10
        && b[4] == b'-'
        && b[7] == b'-'
        && b.iter().enumerate().all(|(i, c)| i == 4 || i == 7 || c.is_ascii_digit())
}

/// `\d{1,2}[.:]\d{2}[.:]\d{2}`.
fn is_time(s: &str) -> bool {
    let parts: Vec<&str> = s.split(['.', ':']).collect();
    if parts.len() != 3 || s.matches(['.', ':']).count() != 2 {
        return false;
    }
    (1..=2).contains(&parts[0].len())
        && parts[1].len() == 2
        && parts[2].len() == 2
        && parts.iter().all(|p| p.chars().all(|c| c.is_ascii_digit()))
}

pub(crate) fn normalised(kind: &str) -> String {
    let kind = kind.to_lowercase();
    if kind == "jpeg" {
        "jpg".into()
    } else {
        kind
    }
}

// MARK: - Other systems' names

/// `Screenshot from 2026-10-02 10-00-01`, and `… (2)` for a second in the same
/// second. GNOME translates the whole stem, so any words before the day and
/// the dashed time will do.
fn gnome_named(name: &str) -> bool {
    if name.starts_with('.') || normalised(path_extension(name)) != "png" {
        return false;
    }
    let tokens: Vec<&str> = strip_extension(name).split(' ').collect();
    (1..tokens.len().saturating_sub(1)).any(|i| {
        is_day(tokens[i])
            && dashed_time(tokens[i + 1])
            && match &tokens[i + 2..] {
                [] => true,
                [one] => one.strip_prefix('(').and_then(|s| s.strip_suffix(')')).is_some_and(all_digits),
                _ => false,
            }
            && tokens[..i].iter().any(|t| !t.is_empty())
    })
}

fn dashed_time(s: &str) -> bool {
    let parts: Vec<&str> = s.split('-').collect();
    parts.len() == 3 && parts.iter().all(|p| p.len() == 2 && p.chars().all(|c| c.is_ascii_digit()))
}

/// `Screenshot_20261002_100001`, with `_1` for a repeat.
fn spectacle_named(name: &str) -> bool {
    if name.starts_with('.') {
        return false;
    }
    if !matches!(normalised(path_extension(name)).as_str(), "png" | "jpg" | "webp") {
        return false;
    }
    let stem = strip_extension(name);
    let Some(rest) = stem.strip_prefix("Screenshot_") else { return false };
    let parts: Vec<&str> = rest.split('_').collect();
    let digits = |s: &str, n: usize| s.len() == n && s.chars().all(|c| c.is_ascii_digit());
    match parts.as_slice() {
        [d, t] => digits(d, 8) && digits(t, 6),
        [d, t, n] => digits(d, 8) && digits(t, 6) && all_digits(n),
        _ => false,
    }
}

fn strip_extension(name: &str) -> &str {
    let ext = path_extension(name);
    if ext.is_empty() {
        name
    } else {
        &name[..name.len() - ext.len() - 1]
    }
}
