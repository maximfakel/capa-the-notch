//! The subset of the Codex App Server protocol CapaTheNotch speaks, and how
//! its answers become Capacity Snapshots. CapaTheNotch only reads: it never
//! calls a login, logout or token method.

use crate::snapshot::{CapacitySnapshot, CapacityStatusReason, ConnectionState, Provider, QuotaWindow};
use chrono::{DateTime, TimeZone, Utc};
use serde::Deserialize;
use serde_json::{json, Value};
use std::path::PathBuf;

pub mod method {
    pub const INITIALIZE: &str = "initialize";
    pub const INITIALIZED: &str = "initialized";
    pub const READ_ACCOUNT: &str = "account/read";
    pub const READ_RATE_LIMITS: &str = "account/rateLimits/read";
    pub const RATE_LIMITS_UPDATED: &str = "account/rateLimits/updated";

    /// Every method this client may send. Anything outside would move
    /// CapaTheNotch beyond reading Capacity.
    pub const PERMITTED_OUTBOUND: [&str; 4] = [INITIALIZE, INITIALIZED, READ_ACCOUNT, READ_RATE_LIMITS];
}

pub fn initialize_params(name: &str, version: &str) -> Value {
    json!({ "clientInfo": { "name": name, "version": version } })
}

/// `requiresOpenaiAuth` is required by the App Server's own schema, so an
/// answer without it is not one this build understands — not a signed-out Codex.
#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountResponse {
    pub account: Option<Value>,
    #[allow(dead_code)]
    pub requires_openai_auth: bool,
}

impl AccountResponse {
    pub fn is_authenticated(&self) -> bool {
        self.account.is_some()
    }
}

/// `usedPercent` is whole percent, `resetsAt` unix seconds.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RateLimitWindow {
    pub used_percent: i64,
    pub window_duration_mins: Option<i64>,
    pub resets_at: Option<i64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Deserialize)]
pub struct RateLimitSnapshot {
    pub primary: Option<RateLimitWindow>,
    pub secondary: Option<RateLimitWindow>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RateLimitsResponse {
    pub rate_limits: RateLimitSnapshot,
}

pub type RateLimitsUpdated = RateLimitsResponse;

/// A rolling update is sparse: a window it omits keeps its last value.
pub fn merge(update: RateLimitSnapshot, previous: RateLimitSnapshot) -> RateLimitSnapshot {
    RateLimitSnapshot {
        primary: update.primary.or(previous.primary),
        secondary: update.secondary.or(previous.secondary),
    }
}

pub fn snapshot(
    payload: &RateLimitSnapshot,
    captured_at: DateTime<Utc>,
    connection_state: ConnectionState,
    status_reason: Option<CapacityStatusReason>,
) -> CapacitySnapshot {
    let windows = [
        payload.primary.as_ref().map(|w| window(w, "codex-primary")),
        payload.secondary.as_ref().map(|w| window(w, "codex-secondary")),
    ]
    .into_iter()
    .flatten()
    .collect();

    CapacitySnapshot { provider: Provider::Codex, captured_at, windows, connection_state, status_reason }
}

pub fn fresh_snapshot(payload: &RateLimitSnapshot, captured_at: DateTime<Utc>) -> CapacitySnapshot {
    snapshot(payload, captured_at, ConnectionState::Fresh, None)
}

fn window(w: &RateLimitWindow, id: &str) -> QuotaWindow {
    QuotaWindow::new(
        id,
        label_for_window_duration(w.window_duration_mins),
        w.window_duration_mins,
        (w.used_percent as f64 / 100.0).clamp(0.0, 1.0),
        w.resets_at.and_then(|s| Utc.timestamp_opt(s, 0).single()),
    )
}

pub fn label_for_window_duration(minutes: Option<i64>) -> String {
    let Some(minutes) = minutes.filter(|m| *m > 0) else { return "Quota".into() };
    if minutes == 10_080 {
        return "Weekly".into();
    }
    if minutes < 60 {
        return format!("{minutes} minute");
    }
    if minutes % 1440 == 0 {
        let days = minutes / 1440;
        return if days == 1 { "Daily".into() } else { format!("{days} day") };
    }
    if minutes % 60 == 0 {
        return format!("{} hour", minutes / 60);
    }
    format!("{minutes} minute")
}

/// Where an installed Codex runtime may live. CapaTheNotch reads no Codex file
/// other than this binary.
pub fn search_paths(home: &std::path::Path) -> Vec<PathBuf> {
    vec![
        home.join(".local/bin/codex"),
        home.join(".codex/bin/codex"),
        home.join(".npm-global/bin/codex"),
        PathBuf::from("/usr/local/bin/codex"),
        PathBuf::from("/usr/bin/codex"),
    ]
}

/// The first Codex binary on `PATH` or in the usual places.
pub fn locate(home: &std::path::Path) -> Option<PathBuf> {
    let on_path = std::env::var_os("PATH").into_iter().flat_map(|p| std::env::split_paths(&p).collect::<Vec<_>>());
    on_path
        .map(|d| d.join("codex"))
        .chain(search_paths(home))
        .find(|p| is_executable(p))
}

pub fn is_executable(path: &std::path::Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    path.metadata().map(|m| m.is_file() && m.permissions().mode() & 0o111 != 0).unwrap_or(false)
}

/// One inbound JSON-RPC line from an App Server.
#[derive(Debug, Clone, PartialEq)]
pub enum Inbound {
    Response { id: i64, result: Value },
    Failure { id: i64, error: RpcFailure },
    Notification { method: String, params: Value },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RpcFailure {
    pub code: i64,
    pub message: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TransportError {
    MalformedMessage(String),
    ConnectionClosed,
}

/// Parses one newline-delimited message. `Ok(None)` for blank lines and for
/// messages this client has no use for, such as server-to-client requests.
pub fn parse_line(line: &str) -> Result<Option<Inbound>, TransportError> {
    let line = line.trim();
    if line.is_empty() {
        return Ok(None);
    }
    let object: Value = serde_json::from_str(line).map_err(|_| TransportError::MalformedMessage(line.into()))?;
    let Some(object) = object.as_object() else {
        return Err(TransportError::MalformedMessage(line.into()));
    };
    let id = object.get("id").and_then(Value::as_i64);

    if let Some(method) = object.get("method").and_then(Value::as_str) {
        if id.is_some() {
            return Ok(None);
        }
        let params = object.get("params").cloned().unwrap_or_else(|| json!({}));
        return Ok(Some(Inbound::Notification { method: method.into(), params }));
    }

    let id = id.ok_or_else(|| TransportError::MalformedMessage(line.into()))?;
    if let Some(error) = object.get("error").and_then(Value::as_object) {
        return Ok(Some(Inbound::Failure {
            id,
            error: RpcFailure {
                code: error.get("code").and_then(Value::as_i64).unwrap_or(0),
                message: error
                    .get("message")
                    .and_then(Value::as_str)
                    .unwrap_or("Unknown App Server error")
                    .into(),
            },
        }));
    }
    let result = object.get("result").cloned().unwrap_or_else(|| json!({}));
    Ok(Some(Inbound::Response { id, result }))
}

pub fn request_line(id: i64, method: &str, params: Option<Value>) -> String {
    let mut object = json!({ "method": method, "id": id });
    if let Some(params) = params {
        object["params"] = params;
    }
    // `serde_json` sorts keys without `preserve_order`, as the Swift side does.
    object.to_string()
}

pub fn notification_line(method: &str, params: Option<Value>) -> String {
    let mut object = json!({ "method": method });
    if let Some(params) = params {
        object["params"] = params;
    }
    object.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn w(used: i64, mins: Option<i64>, resets: Option<i64>) -> RateLimitWindow {
        RateLimitWindow { used_percent: used, window_duration_mins: mins, resets_at: resets }
    }

    #[test]
    fn labels_follow_the_window_length() {
        let l = label_for_window_duration;
        assert_eq!(l(None), "Quota");
        assert_eq!(l(Some(0)), "Quota");
        assert_eq!(l(Some(10_080)), "Weekly");
        assert_eq!(l(Some(30)), "30 minute");
        assert_eq!(l(Some(300)), "5 hour");
        assert_eq!(l(Some(1440)), "Daily");
        assert_eq!(l(Some(2880)), "2 day");
        assert_eq!(l(Some(90)), "90 minute");
    }

    #[test]
    fn a_payload_becomes_two_windows() {
        let p = RateLimitSnapshot { primary: Some(w(24, Some(300), Some(1_000))), secondary: Some(w(150, Some(10_080), None)) };
        let s = fresh_snapshot(&p, Utc.timestamp_opt(0, 0).unwrap());
        assert_eq!(s.provider, Provider::Codex);
        assert_eq!(s.windows[0].id, "codex-primary");
        assert_eq!(s.windows[0].used_fraction, 0.24);
        assert_eq!(s.windows[0].resets_at, Utc.timestamp_opt(1_000, 0).single());
        assert_eq!(s.windows[1].used_fraction, 1.0, "over 100% is clamped");
        assert_eq!(s.windows[1].resets_at, None);
    }

    #[test]
    fn a_sparse_update_keeps_what_it_omits() {
        let prev = RateLimitSnapshot { primary: Some(w(10, Some(300), None)), secondary: Some(w(20, Some(10_080), None)) };
        let update = RateLimitSnapshot { primary: Some(w(15, Some(300), None)), secondary: None };
        let merged = merge(update, prev);
        assert_eq!(merged.primary.unwrap().used_percent, 15);
        assert_eq!(merged.secondary.unwrap().used_percent, 20);
    }

    #[test]
    fn only_reading_methods_are_permitted() {
        for m in ["account/login/start", "account/logout", "getAuthStatus"] {
            assert!(!method::PERMITTED_OUTBOUND.contains(&m));
        }
    }

    #[test]
    fn json_rpc_lines_are_told_apart() {
        assert_eq!(parse_line("  ").unwrap(), None);
        assert!(matches!(
            parse_line(r#"{"id":3,"result":{"a":1}}"#).unwrap(),
            Some(Inbound::Response { id: 3, .. })
        ));
        assert_eq!(
            parse_line(r#"{"id":4,"error":{"code":-1,"message":"no"}}"#).unwrap(),
            Some(Inbound::Failure { id: 4, error: RpcFailure { code: -1, message: "no".into() } })
        );
        assert!(matches!(
            parse_line(r#"{"method":"account/rateLimits/updated","params":{}}"#).unwrap(),
            Some(Inbound::Notification { .. })
        ));
        assert_eq!(parse_line(r#"{"method":"ask","id":1}"#).unwrap(), None, "server requests are ignored");
        assert!(parse_line("[1]").is_err());
        assert!(parse_line("not json").is_err());
        assert!(parse_line(r#"{"result":{}}"#).is_err(), "no id and no method");
    }

    #[test]
    fn an_account_answer_needs_the_field_the_schema_requires() {
        let ok: AccountResponse = serde_json::from_str(r#"{"account":{"type":"chatgpt"},"requiresOpenaiAuth":true}"#).unwrap();
        assert!(ok.is_authenticated());
        let out: AccountResponse = serde_json::from_str(r#"{"account":null,"requiresOpenaiAuth":true}"#).unwrap();
        assert!(!out.is_authenticated());
        assert!(serde_json::from_str::<AccountResponse>(r#"{"account":null}"#).is_err());
    }

    #[test]
    fn request_lines_carry_params_only_when_given() {
        assert_eq!(request_line(1, "account/read", Some(json!({}))), r#"{"id":1,"method":"account/read","params":{}}"#);
        assert_eq!(request_line(2, "account/rateLimits/read", None), r#"{"id":2,"method":"account/rateLimits/read"}"#);
        assert_eq!(notification_line("initialized", None), r#"{"method":"initialized"}"#);
    }
}
