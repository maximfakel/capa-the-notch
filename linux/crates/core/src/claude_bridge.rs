//! Claude Code's status-line bridge (`ClaudeStatusLineBridge.swift`): Claude
//! Code hands a status-line command its own JSON on stdin, rate limits
//! included; the bridge keeps only the Capacity fields of it in a file of its
//! own, and the Claude service reads that file beside `/usage`.
//!
//! Session identity, transcript paths, prompts and credentials are
//! deliberately absent from the persisted format. The file is written the way
//! the Swift bridge writes it — snake_case keys, sorted, numbers as
//! `JSONEncoder` prints them — so either application reads the other's.

use crate::claude::ClaudeCapacityReading;
use crate::snapshot::QuotaWindow;
use chrono::{DateTime, TimeZone, Utc};
use serde_json::Value;
use std::path::{Path, PathBuf};

pub const SCHEMA_VERSION: i64 = 1;
pub const SNAPSHOT_FILE: &str = "claude-capacity.json";
/// The trace a reading that could not be taken leaves: the names of the
/// top-level fields it was given, never a value.
pub const UNREADABLE_FILE: &str = "claude-bridge-last-unreadable.json";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BridgeError {
    MissingSnapshot,
    MissingRateLimits,
    MalformedInput,
    UnsupportedSchema,
}

impl BridgeError {
    /// The case's name, as Swift's `"\(error)"` prints it.
    pub fn name(self) -> &'static str {
        match self {
            BridgeError::MissingSnapshot => "missingSnapshot",
            BridgeError::MissingRateLimits => "missingRateLimits",
            BridgeError::MalformedInput => "malformedInput",
            BridgeError::UnsupportedSchema => "unsupportedSchema",
        }
    }
}

impl std::fmt::Display for BridgeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.name())
    }
}

/// Where the bridge writes and the service reads: the application's data folder.
pub fn default_snapshot_path(home: &Path) -> PathBuf {
    crate::dirs::data(home).join(SNAPSHOT_FILE)
}

/// The trace beside the snapshot.
pub fn unreadable_path(snapshot: &Path) -> PathBuf {
    snapshot.parent().map_or_else(|| PathBuf::from(UNREADABLE_FILE), |dir| dir.join(UNREADABLE_FILE))
}

// MARK: - Reading the file

/// The file the bridge wrote, as Capacity: `five_hour` and `seven_day` become
/// Claude's two windows, anything else is left out.
pub fn read_file(path: &Path) -> Result<ClaudeCapacityReading, BridgeError> {
    let data = std::fs::read(path).map_err(|_| BridgeError::MissingSnapshot)?;
    read_snapshot(&data)
}

pub fn read_snapshot(data: &[u8]) -> Result<ClaudeCapacityReading, BridgeError> {
    let value: Value = serde_json::from_slice(data).map_err(|_| BridgeError::MalformedInput)?;
    let object = value.as_object().ok_or(BridgeError::MalformedInput)?;
    // Decoded whole before the version is looked at, as `JSONDecoder` does.
    let schema = object.get("schema_version").and_then(Value::as_i64).ok_or(BridgeError::MalformedInput)?;
    let captured_at = number(object.get("captured_at")).ok_or(BridgeError::MalformedInput)?;
    let stored = object.get("windows").and_then(Value::as_array).ok_or(BridgeError::MalformedInput)?;
    let mut decoded = Vec::with_capacity(stored.len());
    for window in stored {
        let window = window.as_object().ok_or(BridgeError::MalformedInput)?;
        let id = window.get("id").and_then(Value::as_str).ok_or(BridgeError::MalformedInput)?;
        let used = number(window.get("used_percentage")).ok_or(BridgeError::MalformedInput)?;
        let resets = number(window.get("resets_at")).ok_or(BridgeError::MalformedInput)?;
        decoded.push((id.to_owned(), used, resets));
    }
    if schema != SCHEMA_VERSION {
        return Err(BridgeError::UnsupportedSchema);
    }

    let windows: Vec<QuotaWindow> = decoded
        .into_iter()
        .filter_map(|(id, used, resets)| {
            let (label, minutes) = match id.as_str() {
                "five_hour" => ("5 hour", 300),
                "seven_day" => ("Weekly", 10_080),
                _ => return None,
            };
            Some(QuotaWindow::new(
                format!("claude-{}", id.replace('_', "-")),
                label,
                Some(minutes),
                (used / 100.0).clamp(0.0, 1.0),
                date(resets),
            ))
        })
        .collect();
    if windows.is_empty() {
        return Err(BridgeError::MissingRateLimits);
    }
    Ok(ClaudeCapacityReading { captured_at: date(captured_at).ok_or(BridgeError::MalformedInput)?, windows })
}

/// The bridge file's state as a word a bug report can carry, or nothing when
/// it reads. On the surface a bridge that cannot be read is simply outranked
/// by `/usage`; only a report needs to know which way it failed.
pub fn observation(path: &Path) -> Option<&'static str> {
    match read_file(path) {
        Ok(_) => None,
        Err(BridgeError::MissingSnapshot) => Some("claude-bridge-snapshot-missing"),
        Err(BridgeError::UnsupportedSchema) => Some("claude-bridge-schema-unknown"),
        Err(BridgeError::MissingRateLimits) => Some("claude-bridge-no-windows"),
        Err(BridgeError::MalformedInput) => Some("claude-bridge-unreadable"),
    }
}

fn number(value: Option<&Value>) -> Option<f64> {
    value.and_then(Value::as_f64)
}

fn date(seconds: f64) -> Option<DateTime<Utc>> {
    if !seconds.is_finite() {
        return None;
    }
    let whole = seconds.floor();
    let nanos = ((seconds - whole) * 1e9).round().min(999_999_999.0) as u32;
    Utc.timestamp_opt(whole as i64, nanos).single()
}

// MARK: - Writing it

/// What the bridge writes for Claude Code's status-line JSON, read at
/// `captured_at` (Unix seconds): the two windows, or the reason there is nothing.
pub fn published(status_line_json: &[u8], captured_at: f64) -> Result<String, BridgeError> {
    let input: Value = serde_json::from_slice(status_line_json).map_err(|_| BridgeError::MalformedInput)?;
    let input = input.as_object().ok_or(BridgeError::MalformedInput)?;
    let limits = match input.get("rate_limits") {
        None | Some(Value::Null) => None,
        Some(Value::Object(limits)) => Some(limits),
        Some(_) => return Err(BridgeError::MalformedInput),
    };

    let mut windows = Vec::new();
    if let Some(limits) = limits {
        for id in ["five_hour", "seven_day"] {
            match limits.get(id) {
                None | Some(Value::Null) => {}
                Some(Value::Object(window)) => {
                    let used = number(window.get("used_percentage")).ok_or(BridgeError::MalformedInput)?;
                    let resets = number(window.get("resets_at")).ok_or(BridgeError::MalformedInput)?;
                    windows.push(format!(
                        "{{\"id\":{},\"resets_at\":{},\"used_percentage\":{}}}",
                        json_string(id),
                        swift_number(resets),
                        swift_number(used)
                    ));
                }
                Some(_) => return Err(BridgeError::MalformedInput),
            }
        }
    }
    if windows.is_empty() {
        return Err(BridgeError::MissingRateLimits);
    }
    Ok(format!(
        "{{\"captured_at\":{},\"schema_version\":{SCHEMA_VERSION},\"windows\":[{}]}}",
        swift_number(captured_at),
        windows.join(",")
    ))
}

/// Why publishing did not happen: nothing to publish, or the file could not be written.
#[derive(Debug)]
pub enum PublishError {
    Bridge(BridgeError),
    Io(std::io::Error),
}

impl std::fmt::Display for PublishError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PublishError::Bridge(error) => write!(f, "{error}"),
            PublishError::Io(error) => write!(f, "{error}"),
        }
    }
}

/// Publishes the reading to `destination`, atomically: written beside, then renamed over.
pub fn publish(status_line_json: &[u8], captured_at: f64, destination: &Path) -> Result<(), PublishError> {
    let text = published(status_line_json, captured_at).map_err(PublishError::Bridge)?;
    write_atomically(destination, text.as_bytes()).map_err(PublishError::Io)
}

/// The trace of a reading that could not be taken: the reason, and only the
/// names of the top-level fields — no session data, prompt or path.
pub fn unreadable_note(reason: &str, input: &[u8], at: f64) -> String {
    let names: Vec<String> = match serde_json::from_slice::<Value>(input) {
        Ok(Value::Object(object)) => {
            let mut names: Vec<String> = object.keys().cloned().collect();
            names.sort();
            names
        }
        _ => Vec::new(),
    };
    let names = if names.is_empty() {
        "[\n\n  ]".to_owned()
    } else {
        format!("[\n    {}\n  ]", names.iter().map(|n| json_string(n)).collect::<Vec<_>>().join(",\n    "))
    };
    format!(
        "{{\n  \"at\" : {},\n  \"input_bytes\" : {},\n  \"reason\" : {},\n  \"top_level_field_names\" : {}\n}}",
        swift_number(at),
        input.len(),
        json_string(reason),
        names
    )
}

/// Records why a reading could not be taken, beside the snapshot.
pub fn record_unreadable(snapshot: &Path, reason: &str, input: &[u8], at: f64) {
    let _ = write_atomically(&unreadable_path(snapshot), unreadable_note(reason, input, at).as_bytes());
}

pub fn write_atomically(destination: &Path, data: &[u8]) -> std::io::Result<()> {
    if let Some(dir) = destination.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let name = destination.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let temporary = destination.with_file_name(format!(".{name}.{}.tmp", std::process::id()));
    std::fs::write(&temporary, data)?;
    std::fs::rename(&temporary, destination).inspect_err(|_| {
        let _ = std::fs::remove_file(&temporary);
    })
}

/// A JSON string as Foundation writes one: slashes escaped too.
fn json_string(text: &str) -> String {
    serde_json::to_string(text).unwrap_or_else(|_| "\"\"".into()).replace('/', "\\/")
}

/// A number as `JSONEncoder` prints a `Double`: a whole number without a
/// fraction, anything else in its shortest exact form.
fn swift_number(value: f64) -> String {
    if value.is_finite() && value.fract() == 0.0 && value.abs() < 9_007_199_254_740_992.0 {
        return format!("{}", value as i64);
    }
    serde_json::Number::from_f64(value).map_or_else(|| "0".into(), |n| n.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    const STATUS_LINE: &str = r#"{"session_id":"abc","transcript_path":"/Users/x/t.jsonl","rate_limits":{"five_hour":{"used_percentage":24,"resets_at":1700018000},"seven_day":{"used_percentage":89.5,"resets_at":1700500000}}}"#;

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("capa-bridge-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        dir.join(SNAPSHOT_FILE)
    }

    #[test]
    fn the_bridge_writes_only_the_capacity_fields_sorted_and_snake_case() {
        let text = published(STATUS_LINE.as_bytes(), 1_700_000_000.25).unwrap();
        assert_eq!(
            text,
            r#"{"captured_at":1700000000.25,"schema_version":1,"windows":[{"id":"five_hour","resets_at":1700018000,"used_percentage":24},{"id":"seven_day","resets_at":1700500000,"used_percentage":89.5}]}"#
        );
        assert!(!text.contains("session") && !text.contains("Users"));
    }

    #[test]
    fn nothing_to_publish_is_told_from_input_that_is_not_json() {
        assert_eq!(published(br#"{"model":{}}"#, 0.0), Err(BridgeError::MissingRateLimits));
        assert_eq!(published(br#"{"rate_limits":null}"#, 0.0), Err(BridgeError::MissingRateLimits));
        assert_eq!(published(b"not json", 0.0), Err(BridgeError::MalformedInput));
        assert_eq!(published(br#"{"rate_limits":{"five_hour":{"used_percentage":"24"}}}"#, 0.0), Err(BridgeError::MalformedInput));
    }

    #[test]
    fn what_was_published_reads_back_as_claudes_two_windows() {
        let path = scratch("roundtrip");
        publish(STATUS_LINE.as_bytes(), 1_700_000_000.0, &path).unwrap();
        let reading = read_file(&path).unwrap();
        assert_eq!(reading.captured_at, Utc.timestamp_opt(1_700_000_000, 0).unwrap());
        let ids: Vec<_> = reading.windows.iter().map(|w| (w.id.as_str(), w.label.as_str(), w.duration_minutes)).collect();
        assert_eq!(ids, [("claude-five-hour", "5 hour", Some(300)), ("claude-seven-day", "Weekly", Some(10_080))]);
        assert_eq!(reading.windows[0].used_fraction, 0.24);
        assert_eq!(reading.windows[0].resets_at, Utc.timestamp_opt(1_700_018_000, 0).single());
        assert_eq!(observation(&path), None);
    }

    #[test]
    fn used_is_clamped_and_unknown_windows_are_left_out() {
        let r = read_snapshot(br#"{"captured_at":1,"schema_version":1,"windows":[{"id":"five_hour","used_percentage":140,"resets_at":2},{"id":"opus","used_percentage":1,"resets_at":2},{"id":"seven_day","used_percentage":-4,"resets_at":2}]}"#).unwrap();
        assert_eq!(r.windows.len(), 2);
        assert_eq!(r.windows[0].used_fraction, 1.0);
        assert_eq!(r.windows[1].used_fraction, 0.0);
    }

    #[test]
    fn each_way_the_file_fails_is_its_own_observation() {
        let path = scratch("observations");
        assert_eq!(observation(&path), Some("claude-bridge-snapshot-missing"));
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, r#"{"captured_at":1,"schema_version":2,"windows":[]}"#).unwrap();
        assert_eq!(observation(&path), Some("claude-bridge-schema-unknown"));
        std::fs::write(&path, r#"{"captured_at":1,"schema_version":1,"windows":[{"id":"opus","used_percentage":1,"resets_at":2}]}"#).unwrap();
        assert_eq!(observation(&path), Some("claude-bridge-no-windows"));
        std::fs::write(&path, "{").unwrap();
        assert_eq!(observation(&path), Some("claude-bridge-unreadable"));
    }

    #[test]
    fn the_unreadable_note_names_fields_and_never_values() {
        let note = unreadable_note("missingRateLimits", br#"{"session_id":"secret","model":{"id":"x"}}"#, 1_700_000_000.5);
        assert_eq!(
            note,
            "{\n  \"at\" : 1700000000.5,\n  \"input_bytes\" : 42,\n  \"reason\" : \"missingRateLimits\",\n  \"top_level_field_names\" : [\n    \"model\",\n    \"session_id\"\n  ]\n}"
        );
        assert!(!note.contains("secret"));
    }
}
