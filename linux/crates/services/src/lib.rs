//! The Providers' services: each reads one Provider and publishes Capacity
//! Snapshots on a channel. Process, file and network access sit behind small
//! seams so tests answer without any of them.

pub mod claude;
pub mod codex;
pub mod opencode;

use capa_core::CapacitySnapshot;
use chrono::{DateTime, Utc};
use std::sync::Arc;
use tokio::sync::mpsc::UnboundedSender;

pub type SnapshotSink = UnboundedSender<CapacitySnapshot>;
pub type Clock = Arc<dyn Fn() -> DateTime<Utc> + Send + Sync>;

pub fn system_clock() -> Clock {
    Arc::new(Utc::now)
}
