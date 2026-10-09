//! What was dictated, kept only if the person said so.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HistoryEntry {
    pub id: u64,
    pub date: DateTime<Utc>,
    pub text: String,
}

/// The newest fifty results. Opt-in: nothing is kept unless `enabled` is said
/// at the moment of keeping; opting out later leaves what was kept.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DictationHistory {
    entries: Vec<HistoryEntry>,
    /// How many entries have ever been made: the next id, so an id is never
    /// given twice even across a restart.
    serial: u64,
}

impl DictationHistory {
    pub const LIMIT: usize = 50;

    pub fn new() -> Self {
        Self::default()
    }

    /// Newest first.
    pub fn entries(&self) -> &[HistoryEntry] {
        &self.entries
    }

    pub fn append(&mut self, text: &str, enabled: bool, date: DateTime<Utc>) {
        if !enabled || text.trim().is_empty() {
            return;
        }
        self.serial += 1;
        self.entries.insert(0, HistoryEntry { id: self.serial, date, text: text.to_owned() });
        self.entries.truncate(Self::LIMIT);
    }

    pub fn delete(&mut self, id: u64) {
        self.entries.retain(|e| e.id != id);
    }

    pub fn clear(&mut self) {
        self.entries.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn at(n: i64) -> DateTime<Utc> {
        Utc.timestamp_opt(1_700_000_000 + n, 0).unwrap()
    }

    #[test]
    fn dictation_history_is_opt_in_bounded_and_persistent() {
        let mut history = DictationHistory::new();
        history.append("private", false, at(0));
        assert!(history.entries().is_empty(), "No implicit retention");
        for i in 0..55 {
            history.append(&format!("Result {i}"), true, at(i));
        }
        assert_eq!(history.entries().len(), 50, "Newest fifty");
        assert_eq!(history.entries()[0].text, "Result 54");

        let restored: DictationHistory = serde_json::from_str(&serde_json::to_string(&history).unwrap()).unwrap();
        assert_eq!(restored, history, "History survives reopening");

        history.append("not saved", false, at(99));
        assert_eq!(history, restored, "Opting out preserves old records");

        let id = history.entries()[0].id;
        history.delete(id);
        assert_eq!(history.entries().len(), 49, "Individual deletion");
        history.clear();
        assert!(history.entries().is_empty(), "Clear all");
    }

    #[test]
    fn blank_results_are_not_kept_and_ids_are_never_reused() {
        let mut history = DictationHistory::new();
        history.append("   \n", true, at(0));
        assert!(history.entries().is_empty());
        history.append("one", true, at(1));
        let first = history.entries()[0].id;
        history.clear();
        history.append("two", true, at(2));
        assert_ne!(history.entries()[0].id, first, "even after a clear");
    }
}
