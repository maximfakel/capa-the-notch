//! The hub: Providers' services in, one state out. The Linux daemon runs it,
//! and knows no more about Capacity than how to carry its state to a surface.

mod hub;
mod modules;

pub use hub::{Event, Hub};
pub use tokio::sync::broadcast::error::RecvError;

use capa_core::archive::CapacityArchive;
use std::sync::Arc;

/// The hub with the real services, reading and writing where this user's
/// settings and archive live. Needs a running Tokio runtime.
pub fn start_default() -> Arc<Hub> {
    let home = capa_core::dirs::home();
    Hub::start(capa_core::dirs::config(&home), CapacityArchive::new(CapacityArchive::default_path(&home)))
}
