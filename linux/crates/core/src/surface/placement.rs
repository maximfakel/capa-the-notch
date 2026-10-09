use serde::{Deserialize, Serialize};

/// One display CapaTheNotch could sit on.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DisplayDescriptor {
    pub id: u32,
    pub name: String,
    pub is_built_in: bool,
}

impl DisplayDescriptor {
    pub fn new(id: u32, name: impl Into<String>, is_built_in: bool) -> Self {
        Self { id, name: name.into(), is_built_in }
    }
}

/// Which display the surface belongs on.
///
/// Exactly one, always. A copy on every screen is not a notch, and a preferred
/// display that has been unplugged must not strand the surface where nobody
/// can see it — the choice is made again from what is actually connected each
/// time the displays change.
pub struct DisplaySelection;

impl DisplaySelection {
    pub fn chosen(preferred: Option<u32>, available: &[DisplayDescriptor]) -> Option<&DisplayDescriptor> {
        if let Some(preferred) = preferred {
            if let Some(found) = available.iter().find(|d| d.id == preferred) {
                return Some(found);
            }
        }
        available.iter().find(|d| d.is_built_in).or_else(|| available.first())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn built_in() -> DisplayDescriptor {
        DisplayDescriptor::new(1, "Built-in Retina", true)
    }
    fn external() -> DisplayDescriptor {
        DisplayDescriptor::new(2, "Studio Display", false)
    }
    fn another() -> DisplayDescriptor {
        DisplayDescriptor::new(3, "Projector", false)
    }

    #[test]
    fn the_built_in_display_is_the_default_and_one_is_always_chosen() {
        assert_eq!(DisplaySelection::chosen(None, &[external(), built_in()]), Some(&built_in()), "With no preference the built-in display holds the surface");
        assert_eq!(DisplaySelection::chosen(Some(external().id), &[built_in(), external()]), Some(&external()), "A preference that is connected is honoured");
        assert_eq!(DisplaySelection::chosen(None, &[external(), another()]), Some(&external()), "With no built-in display, the first connected one holds it");
        assert_eq!(DisplaySelection::chosen(None, &[]), None, "With no display at all there is nowhere to put it");
    }

    #[test]
    fn a_display_that_is_unplugged_does_not_strand_the_surface() {
        let available = [built_in()];
        let chosen = DisplaySelection::chosen(Some(external().id), &available);
        assert_eq!(chosen, Some(&built_in()), "A preferred display that is gone gives way to one that is here, got {:?}", chosen.map(|d| &d.name));
    }

    #[test]
    fn a_surface_reads_a_display_as_json() {
        let json = serde_json::to_value(built_in()).unwrap();
        assert_eq!(json["isBuiltIn"], true);
        assert_eq!(json["id"], 1);
    }
}
