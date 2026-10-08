//! Where choices are kept. The Swift original keeps them in `UserDefaults`;
//! here the same keys live behind a small trait, so the hub can back them with
//! a JSON file and the tests with memory.

use serde_json::{Map, Value};
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::Mutex;

pub trait KeyValueStore: Send + Sync {
    fn get(&self, key: &str) -> Option<Value>;
    fn set(&self, key: &str, value: Value);
    fn remove(&self, key: &str);
}

/// In memory: for tests, and for a surface that keeps nothing.
#[derive(Default)]
pub struct MemoryStore {
    values: Mutex<BTreeMap<String, Value>>,
}

impl MemoryStore {
    pub fn new() -> Self {
        Self::default()
    }
}

impl KeyValueStore for MemoryStore {
    fn get(&self, key: &str) -> Option<Value> {
        self.values.lock().unwrap().get(key).cloned()
    }
    fn set(&self, key: &str, value: Value) {
        self.values.lock().unwrap().insert(key.to_owned(), value);
    }
    fn remove(&self, key: &str) {
        self.values.lock().unwrap().remove(key);
    }
}

/// One JSON object in one file, written atomically on every change: a file
/// another process finds half written is a choice lost.
pub struct JsonFileStore {
    path: PathBuf,
    values: Mutex<Map<String, Value>>,
}

impl JsonFileStore {
    /// Reads the file if there is one; anything unreadable is an empty store.
    pub fn open(path: impl Into<PathBuf>) -> Self {
        let path = path.into();
        let values = std::fs::read(&path)
            .ok()
            .and_then(|data| serde_json::from_slice::<Value>(&data).ok())
            .and_then(|value| match value {
                Value::Object(map) => Some(map),
                _ => None,
            })
            .unwrap_or_default();
        Self { path, values: Mutex::new(values) }
    }

    fn save(&self, values: &Map<String, Value>) {
        if let Some(dir) = self.path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        if let Ok(data) = serde_json::to_vec_pretty(values) {
            let tmp = self.path.with_extension("json.tmp");
            if std::fs::write(&tmp, data).is_ok() {
                let _ = std::fs::rename(&tmp, &self.path);
            }
        }
    }
}

impl KeyValueStore for JsonFileStore {
    fn get(&self, key: &str) -> Option<Value> {
        self.values.lock().unwrap().get(key).cloned()
    }
    fn set(&self, key: &str, value: Value) {
        let mut values = self.values.lock().unwrap();
        values.insert(key.to_owned(), value);
        self.save(&values);
    }
    fn remove(&self, key: &str) {
        let mut values = self.values.lock().unwrap();
        if values.remove(key).is_some() {
            self.save(&values);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn a_file_store_keeps_what_it_is_given_across_a_reopen() {
        let dir = std::env::temp_dir().join(format!("capa-prefs-store-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let path = dir.join("prefs.json");
        let store = JsonFileStore::open(&path);
        store.set("a", json!(1));
        store.set("b", json!("two"));
        store.remove("a");
        let again = JsonFileStore::open(&path);
        assert_eq!(again.get("a"), None);
        assert_eq!(again.get("b"), Some(json!("two")));
    }

    #[test]
    fn a_missing_or_broken_file_is_an_empty_store() {
        let dir = std::env::temp_dir().join(format!("capa-prefs-broken-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("prefs.json");
        assert_eq!(JsonFileStore::open(&path).get("x"), None);
        std::fs::write(&path, "[1,2]").unwrap();
        assert_eq!(JsonFileStore::open(&path).get("x"), None);
        std::fs::write(&path, "garbage").unwrap();
        assert_eq!(JsonFileStore::open(&path).get("x"), None);
    }
}
