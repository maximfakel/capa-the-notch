//! The Shelf Module's core (ADR 0005): what it holds and what it never keeps,
//! in memory only; the Clippings; what it takes from the clipboard and from the
//! screenshot folder; the controller that carries the rules; and the platform
//! traits it needs (`platform`).

mod clippings;
mod controller;
mod drag;
mod model;
pub mod platform;
pub mod screenshots;
pub mod take;

pub use clippings::{Clipping, ClippingId, ClippingLimit, Clippings};
pub use controller::{
    EmptyDetail, EmptyTitle, FolderScan, ItemView, NameContext, ShelfController, ShelfEvent, ShelfSettings, ShelfView, TabView,
    ThumbnailJob, COPIED_FOR, SAME_SCREENSHOT_WITHIN,
};
pub use drag::TempDragFiles;
pub use model::{
    file_name, fitted_tile_name, path_extension, standardize, Content, ItemId, Shelf, ShelfFileKind, ShelfItem, ShelfTab,
};
pub use platform::{
    ClipboardSource, DragFileStore, FileMeta, FileThumbnailer, FolderListing, ImageCodec, ScreenshotFolderWatcher, ShelfFiles, StdFiles,
    Thumbnail, CLIPBOARD_POLL_INTERVAL, FOLDER_POLL_INTERVAL, THUMBNAIL_SIZE,
};
pub use take::{canonical, Choice, ClipboardRules, ClipboardTake, ClipboardText, NameLanguage, Platform, ScreenshotClipboard};

/// What the Shelf Module says in Copy Diagnostics: on or off, and how many in
/// each tab — never a name or a path (ADR 0005).
pub fn observation(enabled: bool, shelf: &Shelf, clippings: &Clippings) -> String {
    if !enabled {
        return "shelf-off".into();
    }
    let said = format!(
        "shelf-on-{}-files-{}-screenshots",
        shelf.items(ShelfTab::Files).len(),
        shelf.items(ShelfTab::Screenshots).len()
    );
    if clippings.items().is_empty() {
        said
    } else {
        format!("{said}-{}-clippings", clippings.items().len())
    }
}

#[cfg(test)]
mod tests;
