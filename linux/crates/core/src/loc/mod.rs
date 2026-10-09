//! Port of `Localization.swift`: the language CapaTheNotch speaks.
//!
//! English is the key: a sentence missing from the Russian table is shown as
//! written. The table is generated from the Swift one (`gen_ru.py`), so the
//! two cannot drift apart while the macOS app is the reference.
//!
//! The current language is a process-wide setting, like Swift's
//! `Localization.current`, so core code can speak without being handed a
//! language; every function that takes one has an `_in` twin that does.

mod ru;

use crate::snapshot::CapacityStatusReason;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap};
use std::sync::atomic::{AtomicU8, Ordering};
use std::sync::{OnceLock, RwLock};

/// The language CapaTheNotch speaks: onboarding, Settings, the menu, the
/// notch and its notifications.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AppLanguage {
    System,
    English,
    Russian,
}

impl AppLanguage {
    pub const ALL: [AppLanguage; 3] = [AppLanguage::System, AppLanguage::English, AppLanguage::Russian];

    /// Each language names itself, so it can be found by someone who cannot
    /// read the other; System is the one word that is translated.
    pub fn title(self) -> String {
        match self {
            AppLanguage::System => text("System"),
            AppLanguage::English => "English".into(),
            AppLanguage::Russian => "Русский".into(),
        }
    }

    /// System becomes Russian when Russian is the first language the system
    /// prefers, and English otherwise.
    pub fn resolved_with(self, preferred: &[String]) -> AppLanguage {
        if self != AppLanguage::System {
            return self;
        }
        if preferred.first().is_some_and(|p| p.starts_with("ru")) {
            AppLanguage::Russian
        } else {
            AppLanguage::English
        }
    }

    /// `resolved_with` the languages this system prefers.
    pub fn resolved(self) -> AppLanguage {
        if self != AppLanguage::System {
            return self;
        }
        self.resolved_with(&system_preferred_languages())
    }

    /// The locale's identifier, for number and date formatting.
    pub fn locale_identifier(self) -> &'static str {
        if self.resolved() == AppLanguage::Russian { "ru_RU" } else { "en_US" }
    }

    fn decimal_separator(self) -> char {
        if self.resolved() == AppLanguage::Russian { ',' } else { '.' }
    }
}

static SYSTEM_LANGUAGES: RwLock<Option<Vec<String>>> = RwLock::new(None);

/// A platform that knows the user's languages better than the environment
/// does says so here.
pub fn set_system_preferred_languages(languages: Vec<String>) {
    *SYSTEM_LANGUAGES.write().unwrap() = Some(languages);
}

/// The languages the user prefers, first first, as BCP 47 tags (`ru-RU`).
/// Without a platform's answer, read from the locale environment variables.
pub fn system_preferred_languages() -> Vec<String> {
    if let Some(languages) = SYSTEM_LANGUAGES.read().unwrap().clone() {
        return languages;
    }
    let mut tags = Vec::new();
    // `LANGUAGE` is a colon-separated preference list and outranks the rest.
    if let Ok(list) = std::env::var("LANGUAGE") {
        tags.extend(list.split(':').map(str::to_owned));
    }
    for variable in ["LC_ALL", "LC_MESSAGES", "LANG"] {
        if let Ok(value) = std::env::var(variable) {
            tags.push(value);
        }
    }
    tags.into_iter().filter_map(|t| normalise_tag(&t)).collect()
}

/// `ru_RU.UTF-8@x` → `ru-RU`; `C` and `POSIX` say nothing.
fn normalise_tag(raw: &str) -> Option<String> {
    let base = raw.split(['.', '@']).next().unwrap_or("");
    if base.is_empty() || base == "C" || base == "POSIX" {
        return None;
    }
    Some(base.replace('_', "-"))
}

static CURRENT: AtomicU8 = AtomicU8::new(0);

/// The resolved language, set at launch and whenever the choice changes.
pub fn current() -> AppLanguage {
    if CURRENT.load(Ordering::SeqCst) == 1 { AppLanguage::Russian } else { AppLanguage::English }
}

/// Sets the language; a choice of System is resolved first.
pub fn set_current(language: AppLanguage) {
    let resolved = language.resolved();
    CURRENT.store(if resolved == AppLanguage::Russian { 1 } else { 0 }, Ordering::SeqCst);
}

/// The Russian table, English to Russian.
pub fn russian_table() -> &'static [(&'static str, &'static str)] {
    ru::RUSSIAN
}

fn russian() -> &'static HashMap<&'static str, &'static str> {
    static MAP: OnceLock<HashMap<&'static str, &'static str>> = OnceLock::new();
    MAP.get_or_init(|| ru::RUSSIAN.iter().copied().collect())
}

/// The sentence in the current language.
pub fn text(english: &str) -> String {
    text_in(english, current())
}

pub fn text_in(english: &str, language: AppLanguage) -> String {
    match language.resolved() {
        AppLanguage::Russian => russian().get(english).copied().unwrap_or(english).to_owned(),
        _ => english.to_owned(),
    }
}

/// One argument of a format string.
#[derive(Debug, Clone, PartialEq)]
pub enum Arg {
    Str(String),
    Int(i64),
    Float(f64),
}

impl From<&str> for Arg {
    fn from(v: &str) -> Self { Arg::Str(v.to_owned()) }
}
impl From<String> for Arg {
    fn from(v: String) -> Self { Arg::Str(v) }
}
impl From<&String> for Arg {
    fn from(v: &String) -> Self { Arg::Str(v.clone()) }
}
impl From<i32> for Arg {
    fn from(v: i32) -> Self { Arg::Int(v.into()) }
}
impl From<i64> for Arg {
    fn from(v: i64) -> Self { Arg::Int(v) }
}
impl From<u32> for Arg {
    fn from(v: u32) -> Self { Arg::Int(v.into()) }
}
impl From<usize> for Arg {
    fn from(v: usize) -> Self { Arg::Int(v as i64) }
}
impl From<f64> for Arg {
    fn from(v: f64) -> Self { Arg::Float(v) }
}

/// The sentence in the current language, with its arguments put in.
pub fn format(english: &str, args: &[Arg]) -> String {
    format_in(english, current(), args)
}

/// `%@` (a string), `%d` (an integer), `%f` and `%.Nf` (a number, with the
/// language's decimal separator) and `%%` — the specifiers the tables use.
pub fn format_in(english: &str, language: AppLanguage, args: &[Arg]) -> String {
    let template = text_in(english, language);
    let separator = language.decimal_separator();
    let mut out = String::with_capacity(template.len() + 8);
    let mut chars = template.chars().peekable();
    let mut next = args.iter();
    while let Some(c) = chars.next() {
        if c != '%' {
            out.push(c);
            continue;
        }
        // An optional precision, `.N`.
        let mut precision: Option<usize> = None;
        if chars.peek() == Some(&'.') {
            let mut lookahead = chars.clone();
            lookahead.next();
            if let Some(d) = lookahead.peek().and_then(|d| d.to_digit(10)) {
                precision = Some(d as usize);
                chars.next();
                chars.next();
            }
        }
        match chars.next() {
            Some('%') => out.push('%'),
            Some('@') => match next.next() {
                Some(Arg::Str(s)) => out.push_str(s),
                Some(Arg::Int(i)) => out.push_str(&i.to_string()),
                Some(Arg::Float(f)) => out.push_str(&f.to_string()),
                None => {}
            },
            Some('d') => match next.next() {
                Some(Arg::Int(i)) => out.push_str(&i.to_string()),
                Some(Arg::Float(f)) => out.push_str(&(*f as i64).to_string()),
                Some(Arg::Str(s)) => out.push_str(s),
                None => {}
            },
            Some('f') => {
                let value = match next.next() {
                    Some(Arg::Float(f)) => *f,
                    Some(Arg::Int(i)) => *i as f64,
                    _ => 0.0,
                };
                let digits = precision.unwrap_or(6);
                out.push_str(&format!("{value:.digits$}").replace('.', &separator.to_string()));
            }
            Some(other) => {
                out.push('%');
                if let Some(p) = precision {
                    out.push('.');
                    out.push_str(&p.to_string());
                }
                out.push(other);
            }
            None => out.push('%'),
        }
    }
    out
}

/// The specifiers a string takes, in order: what the translation test compares.
/// A literal `%%` is a percent sign either language may write.
pub fn specifiers(text: &str) -> Vec<String> {
    let chars: Vec<char> = text.chars().collect();
    let mut found = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        if chars[i] == '%' {
            let mut j = i + 1;
            if j + 1 < chars.len() && chars[j] == '.' && chars[j + 1].is_ascii_digit() {
                j += 2;
            }
            if j < chars.len() && matches!(chars[j], '@' | 'd' | 'f') {
                found.push(chars[i..=j].iter().collect());
                i = j + 1;
                continue;
            }
        }
        i += 1;
    }
    found
}

/// Russian takes one of three endings by the last digits, which a single
/// format string cannot hold.
fn russian_ending(count: i64, one: &'static str, few: &'static str, many: &'static str) -> &'static str {
    let (tens, ones) = (count % 100, count % 10);
    if (11..=14).contains(&tens) {
        many
    } else if ones == 1 {
        one
    } else if (2..=4).contains(&ones) {
        few
    } else {
        many
    }
}

/// "5 files", "5 файлов".
pub fn file_count(count: i64) -> String {
    file_count_in(count, current())
}

pub fn file_count_in(count: i64, language: AppLanguage) -> String {
    match language.resolved() {
        AppLanguage::Russian => format!("{count} {}", russian_ending(count, "файл", "файла", "файлов")),
        _ if count == 1 => "1 file".into(),
        _ => format!("{count} files"),
    }
}

/// How many Clippings the Clipboard tab holds.
pub fn clipping_count(count: i64) -> String {
    clipping_count_in(count, current())
}

pub fn clipping_count_in(count: i64, language: AppLanguage) -> String {
    match language.resolved() {
        AppLanguage::Russian => format!("{count} {}", russian_ending(count, "текст", "текста", "текстов")),
        _ if count == 1 => "1 clipping".into(),
        _ => format!("{count} clippings"),
    }
}

/// How many screenshots and images the Screenshots tab holds.
pub fn screenshot_count(count: i64) -> String {
    screenshot_count_in(count, current())
}

pub fn screenshot_count_in(count: i64, language: AppLanguage) -> String {
    match language.resolved() {
        AppLanguage::Russian => format!("{count} {}", russian_ending(count, "скрин", "скрина", "скринов")),
        _ if count == 1 => "1 screenshot".into(),
        _ => format!("{count} screenshots"),
    }
}

/// A Provider's window names arrive as English data ("5 hour", "Weekly");
/// Russian says them itself, shortly, as the notch has little room.
pub fn window_label(label: &str) -> String {
    window_label_in(label, current())
}

pub fn window_label_in(label: &str, language: AppLanguage) -> String {
    if language.resolved() != AppLanguage::Russian {
        return label.to_owned();
    }
    match label {
        "Weekly" => return "Неделя".into(),
        "Daily" => return "День".into(),
        "Quota" => return "Лимит".into(),
        _ => {}
    }
    let parts: Vec<&str> = label.split(' ').filter(|p| !p.is_empty()).collect();
    if let [count, unit] = parts.as_slice() {
        if let Ok(count) = count.parse::<i64>() {
            return match *unit {
                "hour" => format!("{count} ч"),
                "minute" => format!("{count} мин"),
                "day" => format!("{count} дн."),
                _ => label.to_owned(),
            };
        }
    }
    label.to_owned()
}

/// How long until a window turns over, in the fewest words that stay honest,
/// in the current language (Swift's `ResetCountdown.text`).
pub fn reset_countdown(resets_at: DateTime<Utc>, now: DateTime<Utc>) -> String {
    reset_countdown_in(resets_at, now, current())
}

pub fn reset_countdown_in(resets_at: DateTime<Utc>, now: DateTime<Utc>, language: AppLanguage) -> String {
    let remaining = ((resets_at - now).num_milliseconds() as f64 / 1000.0).round() as i64;
    if remaining <= 0 {
        return text_in("moments", language);
    }
    let hours = remaining / 3600;
    let minutes = (remaining % 3600) / 60;
    let f = |template: &str, args: &[Arg]| format_in(template, language, args);

    if hours >= 24 {
        let (days, spare) = (hours / 24, hours % 24);
        return if spare > 0 { f("%dd %dh", &[days.into(), spare.into()]) } else { f("%dd", &[days.into()]) };
    }
    if hours > 0 {
        return if minutes > 0 { f("%dh %dm", &[hours.into(), minutes.into()]) } else { f("%dh", &[hours.into()]) };
    }
    if remaining >= 60 { f("%dm", &[minutes.into()]) } else { text_in("under a minute", language) }
}

/// What a status reason says, in the language Settings speak. A Provider's own
/// detail stays as it came: it is the Provider's words, not ours to translate.
pub fn localized_guidance(reason: &CapacityStatusReason) -> String {
    localized_guidance_in(reason, current())
}

pub fn localized_guidance_in(reason: &CapacityStatusReason, language: AppLanguage) -> String {
    use CapacityStatusReason::*;
    match reason {
        ProviderIncompatible(detail) => format_in("Update the Codex CLI — %@", language, &[detail.into()]),
        ProviderUnavailable(detail) => format_in("Codex is not answering — %@", language, &[detail.into()]),
        ProviderCouldNotRead(detail) => {
            let detail = if detail.ends_with('.') { detail.clone() } else { format!("{detail}.") };
            format_in("Codex could not read its Capacity — %@ Retrying.", language, &[detail.into()])
        }
        other => text_in(&other.guidance(), language),
    }
}

/// Sentences the Swift app never says, because it has no need to: a GNOME
/// notification the Shelf posts when a file is put on the clipboard. Kept
/// apart from `ru.rs`, which is generated from the Swift table.
const PORT_RUSSIAN: &[(&str, &str)] = &[
    ("File copied", "Файл скопирован"),
    ("Paste it where you want it.", "Вставьте его, куда нужно."),
];

/// The Russian table as JSON — an object from English sentence to Russian —
/// for surfaces that draw in JavaScript. English is the key, so English is
/// the empty object. Plural words and window labels are rules, not table
/// entries: a surface gets them from the view model, already said.
pub fn dictionary_json(language: AppLanguage) -> String {
    let table: BTreeMap<&str, &str> = match language.resolved() {
        AppLanguage::Russian => ru::RUSSIAN.iter().chain(PORT_RUSSIAN).copied().collect(),
        _ => BTreeMap::new(),
    };
    serde_json::to_string(&table).unwrap_or_else(|_| "{}".into())
}

/// Serialises tests that read or set the process-wide language.
#[cfg(test)]
pub(crate) fn with_language<R>(language: AppLanguage, body: impl FnOnce() -> R) -> R {
    use std::sync::Mutex;
    static LOCK: Mutex<()> = Mutex::new(());
    let _guard = LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let before = current();
    set_current(language);
    let result = body();
    set_current(before);
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{Duration, TimeZone};

    #[test]
    fn every_translation_keeps_its_sentences_numbers_and_names() {
        for (english, russian) in russian_table() {
            assert_eq!(specifiers(english), specifiers(russian), "“{english}” and its translation must take the same arguments");
            assert!(!russian.is_empty(), "“{english}” must not translate to nothing");
        }
    }

    #[test]
    fn the_table_has_every_entry_of_the_swift_one_and_no_repeats() {
        assert_eq!(russian_table().len(), 344);
        assert_eq!(russian().len(), russian_table().len(), "a key repeated would be lost");
    }

    #[test]
    fn system_language_follows_the_systems_first_language() {
        let tags = |t: &[&str]| t.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert_eq!(AppLanguage::System.resolved_with(&tags(&["ru-RU", "en-US"])), AppLanguage::Russian);
        assert_eq!(AppLanguage::System.resolved_with(&tags(&["en-RU", "ru-RU"])), AppLanguage::English, "only the first language decides");
        assert_eq!(AppLanguage::System.resolved_with(&[]), AppLanguage::English, "no preference is English");
        assert_eq!(AppLanguage::English.resolved_with(&tags(&["ru-RU"])), AppLanguage::English, "a choice outranks the system");
    }

    #[test]
    fn a_sentence_without_a_translation_is_shown_as_written() {
        let ru = AppLanguage::Russian;
        assert_eq!(text_in("Not a sentence Settings use", ru), "Not a sentence Settings use");
        assert_eq!(text_in("General", ru), "Основные");
        assert_eq!(text_in("General", AppLanguage::English), "General");
        assert_eq!(format_in("%d words · %d min", ru, &[120.into(), 3.into()]), "Слов: 120 · 3 мин", "numbers reach the translation");
        let unavailable = CapacityStatusReason::ProviderUnavailable("timed out".into());
        assert!(localized_guidance_in(&unavailable, ru).ends_with("timed out"), "a Provider's own detail is kept as it came");
        assert!(localized_guidance_in(&unavailable, ru).starts_with("Codex не отвечает"));
    }

    #[test]
    fn format_knows_percent_strings_and_decimals() {
        let en = AppLanguage::English;
        assert_eq!(format_in("%@: %d%% left", en, &["5 hour".into(), 4.into()]), "5 hour: 4% left");
        assert_eq!(format_in("%.2f", en, &[1.5.into()]), "1.50");
        assert_eq!(format_in("%.2f", AppLanguage::Russian, &[1.5.into()]), "1,50", "the language's decimal separator");
        assert_eq!(format_in("100%%", en, &[]), "100%");
        assert_eq!(specifiers("%d of %.2f and %@ — 100%%"), ["%d", "%.2f", "%@"]);
    }

    #[test]
    fn the_current_language_is_switchable_and_reaches_text() {
        with_language(AppLanguage::Russian, || {
            assert_eq!(text("General"), "Основные");
            assert_eq!(current(), AppLanguage::Russian);
        });
        with_language(AppLanguage::English, || assert_eq!(text("General"), "General"));
    }

    #[test]
    fn counts_take_the_russian_ending_for_their_last_digits() {
        let ru = AppLanguage::Russian;
        let words: Vec<_> = [1, 2, 4, 5, 11, 12, 14, 21, 22, 25, 111, 101].iter().map(|n| file_count_in(*n, ru)).collect();
        assert_eq!(words, ["1 файл", "2 файла", "4 файла", "5 файлов", "11 файлов", "12 файлов", "14 файлов", "21 файл", "22 файла", "25 файлов", "111 файлов", "101 файл"]);
        assert_eq!(clipping_count_in(3, ru), "3 текста");
        assert_eq!(screenshot_count_in(7, ru), "7 скринов");
        let en = AppLanguage::English;
        assert_eq!((file_count_in(1, en), file_count_in(0, en), file_count_in(5, en)), ("1 file".into(), "0 files".into(), "5 files".into()));
        assert_eq!((clipping_count_in(1, en), screenshot_count_in(2, en)), ("1 clipping".into(), "2 screenshots".into()));
    }

    #[test]
    fn window_labels_are_said_shortly_in_russian_and_kept_in_english() {
        let ru = AppLanguage::Russian;
        for (english, russian) in [("Weekly", "Неделя"), ("Daily", "День"), ("Quota", "Лимит"), ("5 hour", "5 ч"), ("30 minute", "30 мин"), ("2 day", "2 дн."), ("Monthly", "Monthly"), ("5 fortnight", "5 fortnight")] {
            assert_eq!(window_label_in(english, ru), russian);
            assert_eq!(window_label_in(english, AppLanguage::English), english);
        }
    }

    #[test]
    fn a_russian_countdown_says_days_and_hours_shortly() {
        let now = Utc.timestamp_opt(1_700_000_000, 0).unwrap();
        let ru = AppLanguage::Russian;
        assert_eq!(reset_countdown_in(now + Duration::seconds(187_200), now, ru), "2 д 4 ч");
        assert_eq!(reset_countdown_in(now + Duration::seconds(30), now, ru), "меньше минуты");
        assert_eq!(reset_countdown_in(now - Duration::seconds(5), now, ru), "мгновение");
        let en = AppLanguage::English;
        assert_eq!(reset_countdown_in(now + Duration::seconds(187_200), now, en), "2d 4h");
        assert_eq!(reset_countdown_in(now + Duration::seconds(3600 + 25 * 60), now, en), "1h 25m");
    }

    #[test]
    fn the_english_countdown_of_the_pace_module_agrees() {
        let now = Utc.timestamp_opt(1_700_000_000, 0).unwrap();
        for s in [-5, 30, 300, 3600, 5100, 86_400, 180_000] {
            assert_eq!(reset_countdown_in(now + Duration::seconds(s), now, AppLanguage::English), crate::pace::reset_countdown(now + Duration::seconds(s), now), "{s}");
        }
    }

    #[test]
    fn the_dictionary_json_is_the_whole_russian_table() {
        let json = dictionary_json(AppLanguage::Russian);
        let parsed: BTreeMap<String, String> = serde_json::from_str(&json).expect("it is an object of strings");
        for (english, russian) in russian_table() {
            assert_eq!(parsed.get(*english).map(String::as_str), Some(*russian), "{english}");
        }
        for (english, russian) in PORT_RUSSIAN {
            assert_eq!(parsed.get(*english).map(String::as_str), Some(*russian), "{english}");
            assert!(!russian_table().iter().any(|(e, _)| e == english), "{english} is in the Swift table now");
        }
        assert_eq!(parsed.len(), russian_table().len() + PORT_RUSSIAN.len());
        assert_eq!(dictionary_json(AppLanguage::English), "{}", "English is the key, so it needs no table");
    }

    #[test]
    fn language_names_are_found_by_someone_who_cannot_read_the_other() {
        assert_eq!(AppLanguage::English.title(), "English");
        assert_eq!(AppLanguage::Russian.title(), "Русский");
        with_language(AppLanguage::Russian, || assert_eq!(AppLanguage::System.title(), "Как в системе"));
    }

    #[test]
    fn locale_tags_are_read_from_the_environment_shapes() {
        assert_eq!(normalise_tag("ru_RU.UTF-8").as_deref(), Some("ru-RU"));
        assert_eq!(normalise_tag("en_US@euro").as_deref(), Some("en-US"));
        assert_eq!(normalise_tag("C"), None);
        assert_eq!(normalise_tag("POSIX"), None);
        assert_eq!(normalise_tag(""), None);
    }
}
