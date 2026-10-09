//! What the Shelf needs from the platform, and nothing more. Each is a trait
//! here and an implementation per system elsewhere: the core decides what is
//! kept and why, the platform only reads, lists, draws and writes.

use super::model::ItemId;
use super::screenshots::{Entry, Settings};
use serde_json::{Map, Value};
use std::path::{Path, PathBuf};
use std::time::Duration;

/// How often the clipboard is looked at while the Shelf wants it.
pub const CLIPBOARD_POLL_INTERVAL: Duration = Duration::from_millis(500);
/// How often the screenshot folder is looked at while the switch is on.
pub const FOLDER_POLL_INTERVAL: Duration = Duration::from_secs(2);

/// The clipboard, as the Shelf reads it. Every type name is the canonical one
/// (`take::canonical`): the platform maps its own formats onto the identifiers
/// the rules are written against, and reports any marker it knows of — KDE's
/// password hint — under its own name, which the
/// rules' data lists.
pub trait ClipboardSource {
    /// A number that changes whenever the clipboard does.
    fn change_count(&self) -> u64;
    /// The application in front when it changed; the system does not say which
    /// one wrote it. A bundle identifier, a desktop-file id, an executable name.
    fn frontmost_application(&self) -> Option<String>;
    /// Each item's type identifiers. Reading these reads no content.
    fn item_types(&self) -> Vec<Vec<String>>;
    /// The text, when there is some and it may be read.
    fn text(&self) -> Option<String>;
    /// The first file the clipboard points at.
    fn file_path(&self) -> Option<PathBuf>;
    /// The bytes of one type, when they may be read.
    fn data(&self, type_identifier: &str) -> Option<Vec<u8>>;
    /// The system refuses to let this program read the clipboard at all (macOS
    /// 15.4's `accessBehavior == .alwaysDeny`). Settings says so, and Copy
    /// Diagnostics carries `shelf-clipboard-refused` (ADR 0004).
    fn access_refused(&self) -> bool {
        false
    }
}

/// Converts an image the clipboard holds in a format the Shelf does not keep
/// (TIFF, which is the clipboard's converted copy, and large) into PNG.
pub trait ImageCodec {
    fn to_png(&self, data: &[u8], from_type: &str) -> Option<Vec<u8>>;
}

/// A file on disk, as far as the Shelf asks.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FileMeta {
    pub size: u64,
    pub is_directory: bool,
}

/// The file system, so the rules can be tried without one.
pub trait ShelfFiles {
    fn exists(&self, path: &Path) -> bool;
    fn meta(&self, path: &Path) -> Option<FileMeta>;
    fn read(&self, path: &Path) -> Option<Vec<u8>>;
}

/// `std::fs`.
pub struct StdFiles;

impl ShelfFiles for StdFiles {
    fn exists(&self, path: &Path) -> bool {
        path.exists()
    }

    fn meta(&self, path: &Path) -> Option<FileMeta> {
        let meta = std::fs::metadata(path).ok()?;
        Some(FileMeta { size: meta.len(), is_directory: meta.is_dir() })
    }

    fn read(&self, path: &Path) -> Option<Vec<u8>> {
        std::fs::read(path).ok()
    }
}

/// What the platform said about the screenshot folder.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FolderListing {
    Entries(Vec<Entry>),
    /// The system said no; a folder that is not there is only empty.
    Refused,
}

/// Where the screenshots go and what lists the folder. The first look — as the
/// switch is turned on — is what has macOS ask for the folder when it is one it
/// guards: the Desktop, Documents, Downloads.
pub trait ScreenshotFolderWatcher {
    /// The macOS `com.apple.screencapture` domain, or whatever stands for it;
    /// empty where the system keeps none.
    fn domain(&self) -> Map<String, Value> {
        Map::new()
    }
    /// Whether screenshots are saved to a file at all.
    fn saves_to_folder(&self) -> bool;
    /// The folder they are saved to.
    fn folder(&self) -> PathBuf;
    /// How they are named, where the system tells.
    fn settings(&self) -> Settings {
        Settings::default()
    }
    /// Lists the folder. Blocking: the caller runs it where blocking is allowed.
    fn list(&self, folder: &Path) -> FolderListing;
}

/// A picture of a file or of an image held in memory, as RGBA, at most the
/// size asked for (the Shelf draws 112 × 76 at the screen's scale).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Thumbnail {
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<u8>,
}

pub trait FileThumbnailer {
    /// The system's own preview of a file (QuickLook; the desktop's
    /// thumbnailer; the shell's thumbnail cache).
    fn thumbnail_file(&self, path: &Path, max_width: u32, max_height: u32) -> Option<Thumbnail>;
    /// An image held in memory.
    fn thumbnail_data(&self, data: &[u8], max_width: u32, max_height: u32) -> Option<Thumbnail>;
}

/// What the Shelf draws its thumbnails at, in points.
pub const THUMBNAIL_SIZE: (u32, u32) = (112, 76);

/// The files written for dragging out what the Shelf holds only in memory
/// (ADR 0005, amended 2026-10-02): a file per item written as its drag starts,
/// removed when the item leaves the Shelf and all of them at launch and at
/// quit. Not removed when the drag ends — an application that took it may
/// still be reading it.
pub trait DragFileStore: Send + Sync {
    /// The item's file, written if it is not there yet; `None` for a file the
    /// Shelf only refers to, or if it could not be written.
    fn file_for(&self, item: ItemId, name: &str, data: &[u8]) -> Option<PathBuf>;
    /// Removes the files of items no longer on the Shelf.
    fn keep_only(&self, held: &[ItemId]);
    fn remove_all(&self);
}
