//! Port of `CapacityNotchCore`: the Capacity Module's logic, with no UI and
//! no platform code. The Swift sources and their tests are the reference.

pub mod loc;
pub mod module;
pub mod speech;
pub mod diagnostics;
pub mod surface;
pub mod kapa;
pub mod music;
pub mod teleprompter;
pub mod shelf;
pub mod sound;
pub mod dictation;
pub mod prefs;
pub mod alerts;
pub mod archive;
pub mod claude;
pub mod claude_bridge;
pub mod codex;
pub mod dirs;
pub mod opencode;
pub mod pace;
pub mod schedule;
pub mod selection;
pub mod snapshot;
pub mod view;

pub use pace::{CapacityPace, GaugeReset};
pub use schedule::RefreshSchedule;
pub use snapshot::{
    CapacitySnapshot, CapacityStatusReason, ConnectionState, Provider, QuotaWindow,
};
