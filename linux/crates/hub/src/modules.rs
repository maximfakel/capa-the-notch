//! The Modules the hub hosts. Each is a crate of its own that hands back a
//! `SurfaceModule`; this is the one place that lists them.

use capa_core::module::{ModuleContext, SurfaceModule};
use std::sync::Arc;

pub fn all(context: ModuleContext) -> Vec<Arc<dyn SurfaceModule>> {
    vec![
        capa_settings::module(context.clone()),
        capa_music::module(context.clone()),
        capa_teleprompter::module(context.clone()),
        capa_shelf::module(context.clone()),
        capa_dictation::module(context),
    ]
}
