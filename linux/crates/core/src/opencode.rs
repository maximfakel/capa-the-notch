//! OpenCode's Go plan: the one Provider read with its own key (ADR 0001,
//! amended). The key is read at each request and kept nowhere.

use crate::snapshot::QuotaWindow;
use chrono::{DateTime, Utc};
use serde_json::Value;
use std::path::{Path, PathBuf};

/// The only address the key is ever sent to. Undocumented: OpenCode's own
/// console reads it.
pub const USAGE_URL: &str = "https://opencode.ai/zen/go/v1/usage";

/// Where OpenCode keeps its sign-in: `auth.json` in its data directory.
pub fn default_auth_file(home: &Path) -> PathBuf {
    crate::dirs::opencode_data(home).join("auth.json")
}

/// The Go plan's key in OpenCode's file, and nothing else: the ADR lets
/// CapaTheNotch take that one key, not another of OpenCode's entries.
pub fn key_in(file: &[u8]) -> Option<String> {
    let entries: Value = serde_json::from_slice(file).ok()?;
    let key = entries.get("opencode-go")?.get("key")?.as_str()?;
    (!key.is_empty()).then(|| key.to_owned())
}

pub fn read_key(file: &Path) -> Option<String> {
    std::fs::read(file).ok().as_deref().and_then(key_in)
}

/// OpenCode 2 keeps its sign-ins in its database instead of `auth.json`.
pub fn default_db_file(home: &Path) -> PathBuf {
    crate::dirs::opencode_data(home).join("opencode.db")
}

/// The Go plan's key in OpenCode 2's database: the one row of its
/// `credential` table for the `opencode-go` integration, and nothing else —
/// the table holds other sign-ins too, and the ADR lets CapaTheNotch take
/// only this one. Opened read-only, so OpenCode's own file is never written.
pub fn read_key_from_db(db: &Path) -> Option<String> {
    use rusqlite::{Connection, OpenFlags};
    let connection = Connection::open_with_flags(db, OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX).ok()?;
    // OpenCode may be writing; a moment's wait is better than no answer.
    connection.busy_timeout(std::time::Duration::from_secs(1)).ok()?;
    let value: String = connection
        .query_row(
            "SELECT value FROM credential WHERE integration_id = 'opencode-go' \
             ORDER BY active DESC, time_updated DESC LIMIT 1",
            [],
            |row| row.get(0),
        )
        .ok()?;
    let entry: Value = serde_json::from_str(&value).ok()?;
    let key = entry.get("key")?.as_str()?;
    (!key.is_empty()).then(|| key.to_owned())
}

/// The key wherever this version of OpenCode keeps it: its sign-in file, or
/// its database.
pub fn read_key_anywhere(home: &Path) -> Option<String> {
    read_key(&default_auth_file(home)).or_else(|| read_key_from_db(&default_db_file(home)))
}

#[derive(Debug, Clone, PartialEq)]
pub enum Month {
    Available,
    UsedUp { until: Option<DateTime<Utc>> },
}

#[derive(Debug, Clone, PartialEq)]
pub struct UsageReading {
    pub windows: Vec<QuotaWindow>,
    pub month: Month,
}

struct Window {
    used_fraction: f64,
    resets_at: Option<DateTime<Utc>>,
}

impl Window {
    fn parse(value: Option<&Value>) -> Option<Self> {
        let window = value?.as_object()?;
        let status = window.get("status")?.as_str()?;
        let percent = window.get("percent")?.as_f64()?;
        let rate_limited = status == "rate-limited";
        Some(Self {
            used_fraction: if rate_limited { 1.0 } else { (percent / 100.0).clamp(0.0, 1.0) },
            resets_at: window
                .get("resetsAt")
                .and_then(Value::as_str)
                .and_then(|s| DateTime::parse_from_rfc3339(s).ok())
                .map(|d| d.with_timezone(&Utc)),
        })
    }

    fn quota(&self, id: &str, label: &str, minutes: i64) -> QuotaWindow {
        QuotaWindow::new(id, label, Some(minutes), self.used_fraction, self.resets_at)
    }
}

/// `rolling` is the five hours, `weekly` the week. `monthly` is no window —
/// only whether it is used up, and until when.
pub fn parse_usage(body: &[u8]) -> Option<UsageReading> {
    let object: Value = serde_json::from_slice(body).ok()?;
    let usage = object.get("usage")?;
    let rolling = Window::parse(usage.get("rolling"))?;
    let weekly = Window::parse(usage.get("weekly"))?;
    let month = Window::parse(usage.get("monthly"));

    Some(UsageReading {
        windows: vec![
            rolling.quota("opencode-five-hour", "5 hour", 300),
            weekly.quota("opencode-weekly", "Weekly", 10_080),
        ],
        month: match month {
            Some(m) if m.used_fraction >= 1.0 => Month::UsedUp { until: m.resets_at },
            _ => Month::Available,
        },
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    #[test]
    fn only_the_go_key_is_taken() {
        let file = br#"{"anthropic":{"key":"nope"},"opencode-go":{"type":"api","key":"sk-go"}}"#;
        assert_eq!(key_in(file).as_deref(), Some("sk-go"));
        assert_eq!(key_in(br#"{"anthropic":{"key":"nope"}}"#), None);
        assert_eq!(key_in(br#"{"opencode-go":{"key":""}}"#), None);
        assert_eq!(key_in(b"garbage"), None);
    }

    fn database(name: &str, rows: &[(&str, &str, i64, i64)]) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("capa-opencode-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("opencode.db");
        let c = rusqlite::Connection::open(&path).unwrap();
        c.execute_batch(
            "CREATE TABLE credential (id text PRIMARY KEY, integration_id text, label text NOT NULL, value text NOT NULL, \
             connector_id text, method_id text, active integer, time_created integer NOT NULL, time_updated integer NOT NULL);",
        )
        .unwrap();
        for (i, (integration, value, active, updated)) in rows.iter().enumerate() {
            c.execute(
                "INSERT INTO credential (id, integration_id, label, value, active, time_created, time_updated) VALUES (?1, ?2, 'x', ?3, ?4, 0, ?5)",
                rusqlite::params![i.to_string(), integration, value, active, updated],
            )
            .unwrap();
        }
        path
    }

    #[test]
    fn opencode_2_keeps_the_go_key_in_its_database_and_only_that_row_is_taken() {
        let db = database("go", &[
            ("openai", r#"{"type":"oauth","access":"not-this","refresh":"nor-this"}"#, 1, 5),
            ("opencode-go", r#"{"type":"api","key":"sk-old"}"#, 0, 1),
            ("opencode-go", r#"{"type":"api","key":"sk-new"}"#, 1, 2),
        ]);
        assert_eq!(read_key_from_db(&db).as_deref(), Some("sk-new"), "the active one");
    }

    #[test]
    fn no_go_row_a_bad_value_or_no_database_is_no_key() {
        let only_openai = database("openai", &[("openai", r#"{"type":"oauth","access":"a"}"#, 1, 1)]);
        assert_eq!(read_key_from_db(&only_openai), None, "other sign-ins are not ours to take");
        let bad = database("bad", &[("opencode-go", "not json", 1, 1)]);
        assert_eq!(read_key_from_db(&bad), None);
        let no_key = database("nokey", &[("opencode-go", r#"{"type":"oauth","access":"a"}"#, 1, 1)]);
        assert_eq!(read_key_from_db(&no_key), None);
        assert_eq!(read_key_from_db(Path::new("/nonexistent/opencode.db")), None);
    }

    #[test]
    fn the_database_is_never_written() {
        let db = database("readonly", &[("opencode-go", r#"{"type":"api","key":"k"}"#, 1, 1)]);
        let before = std::fs::read(&db).unwrap();
        read_key_from_db(&db);
        assert_eq!(std::fs::read(&db).unwrap(), before);
    }

    #[test]
    fn the_usage_answer_becomes_two_windows() {
        let body = br#"{"usage":{
            "rolling":{"status":"ok","percent":30,"resetsAt":"2026-10-05T12:00:00Z"},
            "weekly":{"status":"ok","percent":55.5},
            "monthly":{"status":"ok","percent":10}}}"#;
        let r = parse_usage(body).unwrap();
        assert_eq!(r.windows[0].id, "opencode-five-hour");
        assert_eq!(r.windows[0].used_fraction, 0.3);
        assert_eq!(r.windows[0].resets_at, Utc.with_ymd_and_hms(2026, 10, 5, 12, 0, 0).single());
        assert_eq!(r.windows[1].id, "opencode-weekly");
        assert_eq!(r.month, Month::Available);
    }

    #[test]
    fn a_rate_limited_window_has_nothing_left() {
        let body = br#"{"usage":{"rolling":{"status":"rate-limited","percent":40},"weekly":{"status":"ok","percent":1}}}"#;
        assert_eq!(parse_usage(body).unwrap().windows[0].used_fraction, 1.0);
    }

    #[test]
    fn a_used_up_month_is_no_window_but_is_said() {
        let body = br#"{"usage":{
            "rolling":{"status":"ok","percent":1},"weekly":{"status":"ok","percent":1},
            "monthly":{"status":"rate-limited","percent":100,"resetsAt":"2026-11-01T00:00:00Z"}}}"#;
        let r = parse_usage(body).unwrap();
        assert_eq!(r.windows.len(), 2);
        assert_eq!(r.month, Month::UsedUp { until: Utc.with_ymd_and_hms(2026, 11, 1, 0, 0, 0).single() });
    }

    #[test]
    fn an_answer_without_both_windows_is_not_understood() {
        assert!(parse_usage(br#"{"usage":{"rolling":{"status":"ok","percent":1}}}"#).is_none());
        assert!(parse_usage(b"{}").is_none());
    }
}
