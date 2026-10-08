//! Which display holds the surface (`SurfaceMetrics`): exactly one, always.
//! The displays are known to the surface host — the shell's monitors on
//! GNOME — which reports them here; the choice is made again from what is
//! connected each time they change, with the person's preferred display (a
//! preference) winning while it is there.

use capa_core::surface::{DisplayDescriptor, DisplaySelection};
use serde::Serialize;
use std::sync::Mutex;

#[derive(Default)]
pub struct DisplayRegistry {
    available: Mutex<Vec<DisplayDescriptor>>,
}

/// What a surface and Settings read.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DisplaysView {
    pub displays: Vec<DisplayDescriptor>,
    /// The display actually in use, which is not always the one preferred: a
    /// screen that has been unplugged cannot hold the surface.
    pub chosen_id: Option<u32>,
    pub preferred_id: Option<u32>,
}

impl DisplayRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    /// The host says which displays there are now.
    pub fn set(&self, displays: Vec<DisplayDescriptor>) {
        *self.available.lock().unwrap() = displays;
    }

    pub fn list(&self) -> Vec<DisplayDescriptor> {
        self.available.lock().unwrap().clone()
    }

    pub fn chosen(&self, preferred: Option<u32>) -> Option<DisplayDescriptor> {
        let available = self.available.lock().unwrap();
        DisplaySelection::chosen(preferred, &available).cloned()
    }

    pub fn view(&self, preferred: Option<u32>) -> DisplaysView {
        DisplaysView { displays: self.list(), chosen_id: self.chosen(preferred).map(|d| d.id), preferred_id: preferred }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn d(id: u32, name: &str, built_in: bool) -> DisplayDescriptor {
        DisplayDescriptor::new(id, name, built_in)
    }

    #[test]
    fn the_preferred_display_wins_while_it_is_there_else_the_built_in_else_the_first() {
        let r = DisplayRegistry::new();
        assert_eq!(r.view(None).chosen_id, None, "no displays, no choice");
        r.set(vec![d(7, "Dell", false), d(2, "Built-in", true)]);
        assert_eq!(r.view(Some(7)).chosen_id, Some(7));
        assert_eq!(r.view(Some(99)).chosen_id, Some(2), "an unplugged preference does not strand the surface");
        assert_eq!(r.view(None).chosen_id, Some(2));
        r.set(vec![d(7, "Dell", false), d(8, "LG", false)]);
        assert_eq!(r.view(None).chosen_id, Some(7));
    }

    #[test]
    fn the_view_is_json_a_surface_reads() {
        let r = DisplayRegistry::new();
        r.set(vec![d(1, "A", true)]);
        let json = serde_json::to_value(r.view(Some(1))).unwrap();
        assert_eq!(json["chosenId"], 1);
        assert_eq!(json["preferredId"], 1);
        assert_eq!(json["displays"][0]["isBuiltIn"], true);
    }
}
