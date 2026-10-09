use crate::snapshot::{CapacitySnapshot, CapacityStatusReason, ConnectionState, Provider, QuotaWindow};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

pub const SCHEMA_VERSION: u32 = 1;

/// Keeps the last Capacity each Provider reported, so a restart opens on the
/// numbers the person last saw rather than on nothing. What comes back is
/// Stale Capacity by definition, and says so.
#[derive(Debug, Clone)]
pub struct CapacityArchive {
    pub path: PathBuf,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct StoredArchive {
    schema_version: u32,
    /// Read one by one, so an entry this build cannot read — a Provider it does
    /// not know — is skipped rather than costing every other one.
    snapshots: Vec<serde_json::Value>,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct StoredSnapshot {
    provider: Provider,
    captured_at: DateTime<Utc>,
    windows: Vec<QuotaWindow>,
}

impl CapacityArchive {
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self { path: path.into() }
    }

    /// `capacity-archive.json` in the state directory (`dirs::state`).
    pub fn default_path(home: &Path) -> PathBuf {
        crate::dirs::state(home).join("capacity-archive.json")
    }

    /// Writes the Providers worth remembering. A Provider with no Quota Window
    /// would come back as a Stale nothing, so it is not.
    pub fn save(&self, snapshots: &[CapacitySnapshot]) {
        let stored: Vec<_> = snapshots
            .iter()
            .filter(|s| !s.windows.is_empty())
            .filter_map(|s| {
                serde_json::to_value(StoredSnapshot { provider: s.provider, captured_at: s.captured_at, windows: s.windows.clone() }).ok()
            })
            .collect();
        if stored.is_empty() {
            return;
        }
        let Ok(data) = serde_json::to_vec(&StoredArchive { schema_version: SCHEMA_VERSION, snapshots: stored }) else {
            return;
        };
        if let Some(dir) = self.path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        // Atomic: written beside, then renamed over.
        let tmp = self.path.with_extension("json.tmp");
        if std::fs::write(&tmp, data).is_ok() {
            let _ = std::fs::rename(&tmp, &self.path);
        }
    }

    /// Everything remembered, as Stale Capacity. Empty when there is nothing,
    /// when the file cannot be read, or when its version no longer applies.
    pub fn load(&self) -> Vec<CapacitySnapshot> {
        let Ok(data) = std::fs::read(&self.path) else { return vec![] };
        let Ok(archive) = serde_json::from_slice::<StoredArchive>(&data) else { return vec![] };
        if archive.schema_version != SCHEMA_VERSION {
            return vec![];
        }
        archive
            .snapshots
            .into_iter()
            .filter_map(|s| serde_json::from_value::<StoredSnapshot>(s).ok())
            .map(|s| CapacitySnapshot {
                provider: s.provider,
                captured_at: s.captured_at,
                windows: s.windows,
                connection_state: ConnectionState::Stale,
                status_reason: Some(CapacityStatusReason::StaleFromArchive),
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("capa-archive-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        dir.join("archive.json")
    }

    fn snap(provider: Provider, windows: Vec<QuotaWindow>) -> CapacitySnapshot {
        CapacitySnapshot { provider, captured_at: Utc::now(), windows, connection_state: ConnectionState::Fresh, status_reason: None }
    }

    #[test]
    fn what_was_saved_comes_back_stale() {
        let archive = CapacityArchive::new(temp("roundtrip"));
        let w = QuotaWindow::new("a", "5 hour", Some(300), 0.4, None);
        archive.save(&[snap(Provider::Codex, vec![w.clone()])]);
        let loaded = archive.load();
        assert_eq!(loaded.len(), 1);
        assert_eq!(loaded[0].windows, vec![w]);
        assert_eq!(loaded[0].connection_state, ConnectionState::Stale);
        assert_eq!(loaded[0].status_reason, Some(CapacityStatusReason::StaleFromArchive));
    }

    #[test]
    fn a_provider_without_windows_is_not_remembered() {
        let archive = CapacityArchive::new(temp("empty"));
        archive.save(&[snap(Provider::Codex, vec![])]);
        assert!(archive.load().is_empty());
        assert!(!archive.path.exists());
    }

    #[test]
    fn an_entry_for_a_provider_not_known_is_skipped_and_the_rest_come_back() {
        let archive = CapacityArchive::new(temp("unknown"));
        let w = QuotaWindow::new("a", "5 hour", Some(300), 0.4, None);
        archive.save(&[snap(Provider::Codex, vec![w])]);
        let text = std::fs::read_to_string(&archive.path).unwrap();
        let mut json: serde_json::Value = serde_json::from_str(&text).unwrap();
        let mut stranger = json["snapshots"][0].clone();
        stranger["provider"] = "gemini".into();
        json["snapshots"].as_array_mut().unwrap().insert(0, stranger);
        std::fs::write(&archive.path, json.to_string()).unwrap();
        let loaded = archive.load();
        assert_eq!(loaded.len(), 1);
        assert_eq!(loaded[0].provider, Provider::Codex);
    }

    #[test]
    fn a_missing_broken_or_foreign_file_is_nothing() {
        let archive = CapacityArchive::new(temp("bad"));
        assert!(archive.load().is_empty());
        std::fs::create_dir_all(archive.path.parent().unwrap()).unwrap();
        std::fs::write(&archive.path, "not json").unwrap();
        assert!(archive.load().is_empty());
        std::fs::write(&archive.path, r#"{"schemaVersion":99,"snapshots":[]}"#).unwrap();
        assert!(archive.load().is_empty());
    }
}
