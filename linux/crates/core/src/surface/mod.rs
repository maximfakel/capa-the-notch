//! The state of the Notch Surface that is not drawing: which Providers have
//! cards, what the closed strip shows, which pages exist, which display holds
//! the surface, whether the screen is fullscreen, and whether the surface is
//! pinned open. Ports of `UnreadCapacity.swift`, `SurfacePageOrder.swift`,
//! `SurfacePlacement.swift`, `FullscreenDetection.swift`, `Releases.swift`,
//! `MockCapacityCatalog.swift` and the pin/presentation half of
//! `CapacityNotchStore.swift`.
//!
//! The types a surface needs to draw derive serde with camelCase, so the hub
//! can put them in the state it sends.

mod compact;
mod fullscreen;
mod mock;
mod pages;
mod placement;
mod store;
mod unread;

pub use compact::{CompactStrip, CompactWindowChoice, Side, Sides};
pub use fullscreen::{FullscreenDetection, FullscreenQuery, Rect, ScreenWindow};
pub use mock::MockCapacityCatalog;
pub use pages::{SurfacePage, SurfacePageOrder};
pub use placement::{DisplayDescriptor, DisplaySelection};
pub use store::{HighlightedWindow, Presentation, SurfaceStore};
pub use unread::{ordered_snapshots, SurfaceCards, UnreadCapacity};

/// Where a newer CapaTheNotch is found.
///
/// Updates are fetched by hand: an ad-hoc signature is new with every build,
/// so an updater could not keep the permissions the system granted the last
/// one, and the application will not hold a token to ask GitHub about a
/// private repository. The person opens the page, signed in as they already are.
pub struct Releases;

impl Releases {
    pub const LATEST: &'static str = "https://github.com/maximfakel/capa-the-notch/releases/latest";
}
