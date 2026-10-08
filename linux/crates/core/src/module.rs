//! What a Module is to the hub: a thing that has state surfaces draw and
//! commands surfaces send. The hub knows nothing else about Music, the
//! Teleprompter, the Shelf or Dictation — each lives in a crate of its own and
//! hands the hub one of these.

use crate::prefs::Preferences;
use crate::sound::SoundCue;
use crate::surface::SurfacePage;
use chrono::{DateTime, Utc};
use serde_json::Value;
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;

pub type BoxFuture<T> = Pin<Box<dyn Future<Output = T> + Send>>;

/// Tells surfaces something happened that is not state: `(module, name, data)`.
pub type Emit = Arc<dyn Fn(&str, &str, Value) + Send + Sync>;

/// What a Module is given when it is made.
#[derive(Clone)]
pub struct ModuleContext {
    pub prefs: Arc<Preferences>,
    pub clock: Arc<dyn Fn() -> DateTime<Utc> + Send + Sync>,
    /// Asks the hub to publish the state again: something a surface draws changed.
    /// It publishes and nothing more — in particular it does not tell Modules
    /// to read their preferences, which would send a Module that calls `notify`
    /// from `preferences_changed` round in a circle, thousands of times a second.
    pub notify: Arc<dyn Fn() + Send + Sync>,
    /// A preference was written (by the Settings Module): every Module reads
    /// its preferences again, the state is published, and the Provider readers look now.
    pub prefs_changed: Arc<dyn Fn() + Send + Sync>,
    /// Tells surfaces something happened that is not state: `(module, name, data)`.
    pub emit: Emit,
    /// Plays one of the app's sounds, when sounds are on.
    pub sound: Arc<dyn Fn(SoundCue) + Send + Sync>,
}

pub trait SurfaceModule: Send + Sync {
    /// The key its state is published under, and the name commands address it by.
    fn id(&self) -> &'static str;

    /// What surfaces draw, as JSON.
    fn state(&self) -> Value;

    /// The page it has on the open surface, while it has one.
    fn page(&self) -> Option<SurfacePage> {
        None
    }

    /// A command from a surface.
    fn call(&self, method: &str, args: Value) -> BoxFuture<Result<Value, String>>;

    /// The surface opened or closed.
    fn presentation_changed(&self, _expanded: bool) {}

    /// A preference changed somewhere: read the ones you care about again.
    fn preferences_changed(&self) {}

    /// Something on the surface wants quiet, so no sound plays: the
    /// Teleprompter running — someone reading a Script aloud is on a call or a
    /// recording.
    fn wants_quiet(&self) -> bool {
        false
    }

    /// What a bug report notes about this Module: codes, never text
    /// (`TeleprompterModule.observation`, `ShelfModule.observation`).
    fn observations(&self) -> Vec<String> {
        Vec::new()
    }

    /// The lines it puts in the diagnostic log at launch, once the hub has
    /// attached it: Dictation's `DiagnosticEvent::Dictation(observation)`,
    /// as `AppDelegate` records it after `launched`.
    fn launch_events(&self) -> Vec<crate::diagnostics::DiagnosticEvent> {
        Vec::new()
    }

    /// The application is quitting: stop whatever runs — a reader, a
    /// recording, a process — so nothing is left behind.
    fn stop(&self) {}
}
