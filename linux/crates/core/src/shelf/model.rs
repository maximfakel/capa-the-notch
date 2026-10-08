//! What the Shelf Module holds: each tab newest first, up to its limit. It
//! lives in memory only; nothing here is written anywhere (ADR 0005).

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Component, Path, PathBuf};

/// Identifies one thing on the Shelf for as long as it is there.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct ItemId(pub u64);

impl std::fmt::Display for ItemId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum Content {
    /// A file, held as a reference and never copied.
    File(PathBuf),
    /// Something held in memory — an image with no file anywhere, a file
    /// copied out of another application's cache — until it is dragged out,
    /// when it becomes a file wherever it is dropped (ADR 0005).
    InMemory { name: String, data: Vec<u8> },
}

/// One thing set down on the Shelf.
#[derive(Debug, Clone, PartialEq)]
pub struct ShelfItem {
    pub id: ItemId,
    pub content: Content,
}

impl ShelfItem {
    pub fn name(&self) -> String {
        match &self.content {
            Content::File(path) => file_name(path),
            Content::InMemory { name, .. } => name.clone(),
        }
    }

    /// The file behind it; `None` for an image held in memory.
    pub fn path(&self) -> Option<&Path> {
        match &self.content {
            Content::File(path) => Some(path),
            Content::InMemory { .. } => None,
        }
    }

    pub fn kind(&self) -> ShelfFileKind {
        ShelfFileKind::from_name(&self.name())
    }
}

/// `URL.lastPathComponent`.
pub fn file_name(path: &Path) -> String {
    path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()
}

/// `URL.standardizedFileURL`, lexically: `.` and `..` resolved, a trailing
/// slash gone, no symbolic link followed.
pub fn standardize(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                if !out.pop() {
                    out.push("..");
                }
            }
            other => out.push(other.as_os_str()),
        }
    }
    out
}

/// One of the Shelf's three views of what it keeps (CONTEXT: Shelf Tab). All
/// three are always there, whether or not their intake is on.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ShelfTab {
    /// What is dropped on the notch, and documents copied elsewhere.
    Files,
    /// Screenshots and images taken from the clipboard.
    Screenshots,
    /// Copied text, as Clippings.
    Clipboard,
}

impl ShelfTab {
    pub const ALL: [ShelfTab; 3] = [ShelfTab::Files, ShelfTab::Screenshots, ShelfTab::Clipboard];

    /// How many the tab keeps; past it the oldest give way. Twenty each for
    /// files and screenshots; the Clippings are 20, 50 or 100 (`ClippingLimit`).
    pub fn limit(self) -> usize {
        20
    }

    /// Where something taken from the clipboard goes: an image — a screenshot
    /// among them — under Screenshots, anything else under Files.
    pub fn for_copied(name: &str) -> ShelfTab {
        if ShelfFileKind::from_name(name) == ShelfFileKind::Image {
            ShelfTab::Screenshots
        } else {
            ShelfTab::Files
        }
    }
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct Shelf {
    held: BTreeMap<ShelfTab, Vec<ShelfItem>>,
    next_id: u64,
}

impl Shelf {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn items(&self, tab: ShelfTab) -> &[ShelfItem] {
        self.held.get(&tab).map(Vec::as_slice).unwrap_or(&[])
    }

    /// How many it holds, in every tab.
    pub fn count(&self) -> usize {
        self.held.values().map(Vec::len).sum()
    }

    /// Every item held, in every tab.
    pub fn all_items(&self) -> impl Iterator<Item = &ShelfItem> {
        ShelfTab::ALL.into_iter().flat_map(move |tab| self.items(tab).iter())
    }

    fn fresh_id(&mut self) -> ItemId {
        self.next_id += 1;
        ItemId(self.next_id)
    }

    /// Files dropped together keep their order, and the last of them lands in
    /// front. A file already in the tab rises rather than appearing twice, and
    /// past the tab's limit the oldest give way.
    pub fn add(&mut self, paths: &[PathBuf], tab: ShelfTab) {
        let mut items = self.items(tab).to_vec();
        for path in paths {
            let standard = standardize(path);
            let existing = items.iter().position(|i| i.path().map(standardize).as_deref() == Some(standard.as_path()));
            let item = match existing {
                Some(index) => items.remove(index),
                None => ShelfItem { id: self.fresh_id(), content: Content::File(standard) },
            };
            items.insert(0, item);
        }
        self.store(items, tab);
    }

    /// Something with no file behind it, held in memory. The same bytes again
    /// rise, under the name they came with this time.
    pub fn add_in_memory(&mut self, name: &str, data: Vec<u8>, tab: ShelfTab) {
        let mut items = self.items(tab).to_vec();
        items.retain(|i| !matches!(&i.content, Content::InMemory { data: held, .. } if *held == data));
        let id = self.fresh_id();
        items.insert(0, ShelfItem { id, content: Content::InMemory { name: name.to_owned(), data } });
        self.store(items, tab);
    }

    /// From whichever tab holds it.
    /// An item held in memory becomes a reference to `path`, where it stands and
    /// with its id: the same image, found saved as a file.
    pub fn replace_with_file(&mut self, id: ItemId, path: &Path) {
        for items in self.held.values_mut() {
            if let Some(item) = items.iter_mut().find(|i| i.id == id) {
                item.content = Content::File(standardize(path));
            }
        }
    }

    pub fn remove(&mut self, id: ItemId) {
        for items in self.held.values_mut() {
            items.retain(|i| i.id != id);
        }
    }

    /// Clear on the Shelf page: the tab shown, and no other.
    pub fn clear(&mut self, tab: ShelfTab) {
        self.held.remove(&tab);
    }

    /// Switched off or quitting: everything goes.
    pub fn clear_all(&mut self) {
        self.held.clear();
    }

    fn store(&mut self, mut items: Vec<ShelfItem>, tab: ShelfTab) {
        items.truncate(tab.limit());
        self.held.insert(tab, items);
    }
}

/// How a file is drawn on the Shelf: a thumbnail for an image, otherwise a
/// page with its extension on a badge coloured by what kind it is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ShelfFileKind {
    Image,
    Pdf,
    Archive,
    Presentation,
    Document,
    Spreadsheet,
    Other,
}

/// `NSString.pathExtension`: after the last dot, and nothing for a name that
/// is only a dotfile or ends in a dot.
pub fn path_extension(name: &str) -> &str {
    match name.rfind('.') {
        Some(0) | None => "",
        Some(index) => &name[index + 1..],
    }
}

impl ShelfFileKind {
    pub fn from_name(name: &str) -> ShelfFileKind {
        match path_extension(name).to_lowercase().as_str() {
            "png" | "jpg" | "jpeg" | "gif" | "heic" | "heif" | "tiff" | "tif" | "bmp" | "webp" => ShelfFileKind::Image,
            "pdf" => ShelfFileKind::Pdf,
            "zip" | "tar" | "gz" | "tgz" | "bz2" | "xz" | "7z" | "rar" | "dmg" => ShelfFileKind::Archive,
            "key" | "ppt" | "pptx" | "odp" => ShelfFileKind::Presentation,
            "doc" | "docx" | "pages" | "rtf" | "txt" | "md" | "odt" => ShelfFileKind::Document,
            "xls" | "xlsx" | "numbers" | "csv" | "ods" => ShelfFileKind::Spreadsheet,
            _ => ShelfFileKind::Other,
        }
    }

    pub fn from_path(path: &Path) -> ShelfFileKind {
        Self::from_name(&file_name(path))
    }

    /// The extension, four letters at most, or nothing when there is none.
    pub fn badge(name: &str) -> Option<String> {
        let ext = path_extension(name).to_uppercase();
        if ext.is_empty() {
            None
        } else {
            Some(ext.chars().take(4).collect())
        }
    }
}

/// A file's name in two lines at most, cut in the middle as Finder cuts it:
/// the start, an ellipsis, and the last word — "Снимок экра… 12.41.png" — so
/// the end that tells two screenshots apart stays. `fits` is the surface's own
/// measure: whether the text, drawn in its type at the tile's width, stands
/// in two lines.
pub fn fitted_tile_name(name: &str, fits: impl Fn(&str) -> bool) -> String {
    if fits(name) {
        return name.to_owned();
    }
    let chars: Vec<char> = name.chars().collect();
    let last_space = chars.iter().rposition(|c| *c == ' ');
    let tail: String = match last_space {
        Some(index) => chars[index + 1..].iter().collect(),
        None => chars[chars.len().saturating_sub(8)..].iter().collect(),
    };
    let joint = if last_space.is_none() { "…" } else { "… " };
    let tail_len = tail.chars().count();
    let room = chars.len() - tail_len;
    let (mut low, mut high) = (0usize, room.saturating_sub(1));
    while low < high {
        let middle = (low + high).div_ceil(2);
        let candidate: String = chars[..middle].iter().collect::<String>() + joint + &tail;
        if fits(&candidate) {
            low = middle;
        } else {
            high = middle - 1;
        }
    }
    let head: String = chars[..low].iter().collect();
    head.trim().to_owned() + joint + &tail
}
