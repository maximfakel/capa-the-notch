use serde::{Deserialize, Serialize};

/// A page of the expanded surface: one per Module that has something to show.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SurfacePage {
    Capacity,
    Music,
    Teleprompter,
    Shelf,
}

/// Which pages the expanded surface has, in which order, and how a turn moves
/// between them. Capacity first — it is the question the product answers —
/// then each Module in the order it arrived (ADR 0003).
pub struct SurfacePageOrder;

impl SurfacePageOrder {
    pub fn pages(music: bool, teleprompter: bool, shelf: bool) -> Vec<SurfacePage> {
        let mut pages = vec![SurfacePage::Capacity];
        if music {
            pages.push(SurfacePage::Music);
        }
        if teleprompter {
            pages.push(SurfacePage::Teleprompter);
        }
        if shelf {
            pages.push(SurfacePage::Shelf);
        }
        pages
    }

    /// One page on or back; the ends hold.
    pub fn step(from: SurfacePage, by: i32, pages: &[SurfacePage]) -> SurfacePage {
        if pages.is_empty() {
            return from;
        }
        let current = pages.iter().position(|p| *p == from).unwrap_or(0) as i64;
        let last = pages.len() as i64 - 1;
        pages[(current + i64::from(by)).clamp(0, last) as usize]
    }

    /// The page to show when the one chosen may have gone — a track ended, a
    /// Module switched off.
    pub fn shown(page: SurfacePage, pages: &[SurfacePage]) -> SurfacePage {
        if pages.contains(&page) { page } else { SurfacePage::Capacity }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use SurfacePage::*;

    #[test]
    fn capacity_is_first_and_each_module_follows_in_the_order_it_arrived() {
        assert_eq!(SurfacePageOrder::pages(false, false, false), [Capacity]);
        assert_eq!(SurfacePageOrder::pages(true, true, true), [Capacity, Music, Teleprompter, Shelf]);
        assert_eq!(SurfacePageOrder::pages(false, true, true), [Capacity, Teleprompter, Shelf]);
        assert_eq!(SurfacePageOrder::pages(true, false, true), [Capacity, Music, Shelf]);
    }

    #[test]
    fn a_turn_moves_one_page_and_the_ends_hold() {
        let pages = SurfacePageOrder::pages(true, true, false);
        assert_eq!(SurfacePageOrder::step(Capacity, 1, &pages), Music);
        assert_eq!(SurfacePageOrder::step(Music, 1, &pages), Teleprompter);
        assert_eq!(SurfacePageOrder::step(Teleprompter, 1, &pages), Teleprompter, "the end holds");
        assert_eq!(SurfacePageOrder::step(Capacity, -1, &pages), Capacity, "so does the start");
        assert_eq!(SurfacePageOrder::step(Teleprompter, -2, &pages), Capacity);
        assert_eq!(SurfacePageOrder::step(Shelf, 1, &pages), Music, "a page that is gone counts from the first");
        assert_eq!(SurfacePageOrder::step(Capacity, 1, &[]), Capacity, "no pages, no turn");
    }

    #[test]
    fn a_page_that_has_gone_gives_way_to_capacity() {
        let pages = SurfacePageOrder::pages(false, true, false);
        assert_eq!(SurfacePageOrder::shown(Teleprompter, &pages), Teleprompter);
        assert_eq!(SurfacePageOrder::shown(Music, &pages), Capacity, "a track ended");
        assert_eq!(SurfacePageOrder::shown(Shelf, &pages), Capacity, "a Module switched off");
    }

    #[test]
    fn pages_are_named_for_a_surface_in_camel_case() {
        assert_eq!(serde_json::to_string(&[Capacity, Teleprompter]).unwrap(), r#"["capacity","teleprompter"]"#);
    }
}
