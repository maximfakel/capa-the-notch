//! The Shelf Module's state and rules, without its timers, its views or the
//! system: files dropped on the notch, held as references, and images with no
//! file, held in memory — all dragged out again — and, on a switch of their
//! own, copied texts as Clippings (ADR 0005). Off, it holds nothing; switching
//! it off empties it.
//!
//! The host calls `poll_clipboard` every `CLIPBOARD_POLL_INTERVAL` and the two
//! halves of the folder scan every `FOLDER_POLL_INTERVAL` while
//! `wants_clipboard` / `wants_folder` say so, hands over the moment, and acts on
//! the events it gets back.

use super::clippings::{Clipping, ClippingId, ClippingLimit, Clippings};
use super::model::{standardize, ItemId, Shelf, ShelfFileKind, ShelfItem, ShelfTab};
use super::platform::*;
use super::screenshots::{self, Naming};
use super::take::{Choice, ClipboardRules, ClipboardTake, ClipboardText, NameLanguage, ScreenshotClipboard};
use chrono::{DateTime, Duration, FixedOffset, Utc};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeSet, HashMap, HashSet};
use std::path::PathBuf;
use std::sync::Arc;

/// What a person has chosen. Everything the Shelf takes by itself is off until
/// asked for; each is its own switch (ADR 0003, 0005).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ShelfSettings {
    /// The Shelf Module itself.
    pub enabled: bool,
    /// Images copied to the clipboard — screenshots among them — and each new
    /// screenshot saved to the screenshot folder, land on the Shelf by
    /// themselves.
    pub takes_clipboard_images: bool,
    /// Text copied lands under the Clipboard tab as Clippings.
    pub keeps_text: bool,
    pub clipping_limit: ClippingLimit,
    pub clippings_expire: bool,
    /// Applications nothing is taken from while they are in front.
    pub excluded_applications: Vec<String>,
}

impl Default for ShelfSettings {
    fn default() -> Self {
        Self {
            enabled: false,
            takes_clipboard_images: false,
            keeps_text: false,
            clipping_limit: ClippingLimit::DEFAULT,
            clippings_expire: true,
            excluded_applications: vec![],
        }
    }
}

/// How a screenshot or an image is named when it is taken in.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NameContext {
    pub language: NameLanguage,
    pub offset: FixedOffset,
}

/// What the host should do about something that happened.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ShelfEvent {
    /// The Shelf took something in by itself (nothing sounds: ADR 0007).
    Took(ShelfTab),
    /// A Clipping was put on the clipboard; sounds "tap".
    ClippingCopied,
    /// The system would not let the Shelf read the clipboard.
    ClipboardRefused,
    /// The system would not let the Shelf read the screenshot folder.
    ScreenshotFolderRefused,
    /// Something was on the clipboard and could not be read; for the log, by
    /// reason code only (ADR 0005: never names, paths or text).
    ReadFailed(&'static str),
}

/// A thumbnail the platform should draw, asynchronously, and hand back to
/// `set_thumbnail`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ThumbnailJob {
    File { id: ItemId, path: PathBuf },
    /// The image is in memory; `ShelfController::bytes` has it.
    Data { id: ItemId },
}

/// A look at the screenshot folder under way: list `folder`, then give the
/// listing to `finish_folder_scan` with this.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FolderScan {
    pub folder: PathBuf,
    naming: Naming,
    watch: u64,
    /// When the look began.
    at: DateTime<Utc>,
}

/// How recently an image taken off the clipboard may have been taken for the
/// same screenshot, saved to the folder too, to stand for it: GNOME puts each
/// screenshot both on the clipboard and in the folder.
pub const SAME_SCREENSHOT_WITHIN: Duration = Duration::seconds(10);

/// What the empty tab says: what lands in it, or how to turn its intake on.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum EmptyTitle {
    DragFiles,
    ScreenshotsWait,
    TextWaits,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "hint", rename_all = "camelCase")]
pub enum EmptyDetail {
    /// "Up to 20 files. The Shelf empties when CapaTheNotch quits."
    FilesLimit,
    /// "Up to 20. The Shelf empties when CapaTheNotch quits."
    ScreenshotsLimit,
    /// "Turn on “Images and files from the clipboard” in Settings → Modules → Shelf."
    TurnOnImages,
    /// "Turn on text from the clipboard in Settings → Modules → Shelf."
    TurnOnText,
    /// "Up to %d. Each goes after 24 hours, and all when CapaTheNotch quits."
    ClippingsExpire { limit: usize },
    /// "Up to %d. All go when CapaTheNotch quits."
    ClippingsStay { limit: usize },
}

pub struct ShelfController {
    settings: ShelfSettings,
    shelf: Shelf,
    clippings: Clippings,
    /// The Shelf Tab shown, and the one the Shelf opens on next: remembered for
    /// the session, never written down.
    pub tab: ShelfTab,
    /// Files moved or deleted since they were set down.
    missing: BTreeSet<ItemId>,
    thumbnails: HashMap<ItemId, Thumbnail>,
    requested: HashSet<ItemId>,
    /// A file is being carried over the surface: it has opened on the Shelf,
    /// and the Shelf shows where to drop it.
    pub is_drop_targeted: bool,
    /// The file has come near the drop area: its words go, and Kapa grows to
    /// the dashes to take it (ADR 0006).
    pub is_drop_near: bool,
    swallow: Option<(DateTime<Utc>, Duration)>,
    just_copied: Option<(ClippingId, DateTime<Utc>)>,
    clipboard_refused: bool,
    screenshot_folder_refused: bool,
    rules: ClipboardRules,
    own_application: Option<String>,
    drag_files: Option<Arc<dyn DragFileStore>>,
    // Watching the clipboard.
    clipboard_watching: bool,
    clipboard_count: u64,
    // Watching the screenshot folder.
    folder_watching: bool,
    /// When the folder began to be watched: only screenshots saved since.
    folder_since: DateTime<Utc>,
    folder_taken: BTreeSet<PathBuf>,
    folder_scanning: bool,
    /// Counts each start of watching, so a look begun before the switch went
    /// off — and perhaps on again — is not taken as one of this watch's.
    folder_watch: u64,
    /// When each screenshot taken off the clipboard was taken, so the same one
    /// arriving in the folder a moment later takes its place rather than
    /// landing twice.
    taken_from_clipboard: HashMap<ItemId, DateTime<Utc>>,
}

/// How long "Copied" is said on a Clipping.
pub const COPIED_FOR: Duration = Duration::milliseconds(1200);

impl ShelfController {
    pub fn new(settings: ShelfSettings, rules: ClipboardRules) -> Self {
        Self {
            settings,
            shelf: Shelf::new(),
            clippings: Clippings::new(),
            tab: ShelfTab::Files,
            missing: BTreeSet::new(),
            thumbnails: HashMap::new(),
            requested: HashSet::new(),
            is_drop_targeted: false,
            is_drop_near: false,
            swallow: None,
            just_copied: None,
            clipboard_refused: false,
            screenshot_folder_refused: false,
            rules,
            own_application: None,
            drag_files: None,
            clipboard_watching: false,
            clipboard_count: 0,
            folder_watching: false,
            folder_since: DateTime::<Utc>::MIN_UTC,
            folder_taken: BTreeSet::new(),
            folder_scanning: false,
            folder_watch: 0,
            taken_from_clipboard: HashMap::new(),
        }
    }

    /// CapaTheNotch's own identifier, so what is copied with ⌘C in its own
    /// windows is never kept.
    pub fn with_own_application(mut self, id: impl Into<String>) -> Self {
        self.own_application = Some(id.into());
        self
    }

    pub fn with_drag_files(mut self, store: Arc<dyn DragFileStore>) -> Self {
        self.drag_files = Some(store);
        self
    }

    pub fn settings(&self) -> &ShelfSettings {
        &self.settings
    }

    pub fn is_enabled(&self) -> bool {
        self.settings.enabled
    }

    pub fn shelf(&self) -> &Shelf {
        &self.shelf
    }

    pub fn clippings(&self) -> &Clippings {
        &self.clippings
    }

    pub fn items(&self, tab: ShelfTab) -> &[ShelfItem] {
        self.shelf.items(tab)
    }

    pub fn missing(&self) -> &BTreeSet<ItemId> {
        &self.missing
    }

    pub fn clipboard_refused(&self) -> bool {
        self.clipboard_refused
    }

    pub fn screenshot_folder_refused(&self) -> bool {
        self.screenshot_folder_refused
    }

    // MARK: - Switches

    pub fn set_enabled(&mut self, enabled: bool) {
        self.settings.enabled = enabled;
        if !enabled {
            self.clear_all();
        }
    }

    /// Its own switch, off by default: what a person copies is the most
    /// sensitive thing CapaTheNotch could keep (ADR 0005). Off, the Clippings
    /// go at once.
    pub fn set_keeps_text(&mut self, keeps: bool) {
        self.settings.keeps_text = keeps;
        if !keeps {
            self.clippings.clear();
        }
    }

    pub fn set_clipping_limit(&mut self, limit: ClippingLimit) {
        self.settings.clipping_limit = limit;
        if self.clippings.items().len() > limit.raw() {
            self.clippings.trim(limit);
        }
    }

    pub fn set_clippings_expire(&mut self, expire: bool, now: DateTime<Utc>) {
        self.settings.clippings_expire = expire;
        self.clippings.forget_old(now, expire);
    }

    pub fn set_excluded_applications(&mut self, identifiers: Vec<String>) {
        self.settings.excluded_applications = identifiers;
    }

    /// Asked for on its own switch: it means watching the clipboard, which is
    /// the person's to decide (ADR 0003, 0005).
    pub fn set_takes_clipboard_images(&mut self, takes: bool) {
        self.settings.takes_clipboard_images = takes;
        self.clipboard_refused = false;
        self.screenshot_folder_refused = false;
    }

    // MARK: - Holding

    pub fn add(&mut self, paths: &[PathBuf], tab: ShelfTab, files: &dyn ShelfFiles) {
        if !self.settings.enabled || paths.is_empty() {
            return;
        }
        self.shelf.add(paths, tab);
        self.forget_gone();
        self.refresh_availability(files);
    }

    /// Something with no file behind it, held in memory.
    pub fn add_in_memory(&mut self, name: &str, data: Vec<u8>, tab: ShelfTab) {
        if !self.settings.enabled {
            return;
        }
        self.shelf.add_in_memory(name, data, tab);
        self.forget_gone();
    }

    pub fn remove(&mut self, id: ItemId) {
        self.shelf.remove(id);
        self.forget_gone();
    }

    /// Clear on the page: the tab shown, and no other.
    pub fn clear(&mut self) {
        if self.tab == ShelfTab::Clipboard {
            self.clippings.clear();
        }
        self.shelf.clear(self.tab);
        self.forget_gone();
    }

    fn clear_all(&mut self) {
        self.shelf.clear_all();
        self.clippings.clear();
        self.forget_gone();
        self.is_drop_targeted = false;
        self.is_drop_near = false;
        self.swallow = None;
    }

    /// Asked whenever the page is shown: a file moved since then is shown as
    /// moved, not offered to be dragged from nowhere. An image held in memory
    /// cannot go missing.
    pub fn refresh_availability(&mut self, files: &dyn ShelfFiles) {
        let gone: BTreeSet<ItemId> = self
            .shelf
            .all_items()
            .filter(|item| item.path().is_some_and(|p| !files.exists(p)))
            .map(|item| item.id)
            .collect();
        self.missing = gone;
    }

    fn forget_gone(&mut self) {
        let ids: Vec<ItemId> = self.shelf.all_items().map(|i| i.id).collect();
        if let Some(store) = &self.drag_files {
            store.keep_only(&ids);
        }
        self.missing.retain(|id| ids.contains(id));
        self.thumbnails.retain(|id, _| ids.contains(id));
        self.requested.retain(|id| ids.contains(id));
        self.taken_from_clipboard.retain(|id, _| ids.contains(id));
    }

    /// The file to drag out for an item: the file it is, or one written for an
    /// image held only in memory.
    pub fn file_to_drag(&self, id: ItemId) -> Option<PathBuf> {
        let item = self.shelf.all_items().find(|i| i.id == id)?;
        match &item.content {
            super::model::Content::File(path) => Some(path.clone()),
            super::model::Content::InMemory { name, data } => self.drag_files.as_ref()?.file_for(id, name, data),
        }
    }

    /// The bytes of an image held in memory.
    pub fn bytes(&self, id: ItemId) -> Option<&[u8]> {
        match &self.shelf.all_items().find(|i| i.id == id)?.content {
            super::model::Content::InMemory { data, .. } => Some(data),
            super::model::Content::File(_) => None,
        }
    }

    // MARK: - Thumbnails

    /// The thumbnails still to draw, each asked for once.
    pub fn pending_thumbnails(&mut self) -> Vec<ThumbnailJob> {
        let mut jobs = vec![];
        for item in self.shelf.all_items() {
            if item.kind() != ShelfFileKind::Image || self.thumbnails.contains_key(&item.id) || self.requested.contains(&item.id) {
                continue;
            }
            jobs.push(match item.path() {
                Some(path) => ThumbnailJob::File { id: item.id, path: path.to_path_buf() },
                None => ThumbnailJob::Data { id: item.id },
            });
        }
        for job in &jobs {
            self.requested.insert(match job {
                ThumbnailJob::File { id, .. } | ThumbnailJob::Data { id } => *id,
            });
        }
        jobs
    }

    /// A thumbnail drawn: kept only if the item is still on the Shelf.
    pub fn set_thumbnail(&mut self, id: ItemId, thumbnail: Thumbnail) {
        if self.shelf.all_items().any(|i| i.id == id) {
            self.thumbnails.insert(id, thumbnail);
        }
    }

    pub fn thumbnail(&self, id: ItemId) -> Option<&Thumbnail> {
        self.thumbnails.get(&id)
    }

    // MARK: - Clippings

    /// Choosing a Clipping puts it on the clipboard and nothing more: pasting
    /// is the person's own paste, so no accessibility access is needed. Returns
    /// the text, for the host to put on the clipboard through its own marked
    /// copy (`ClipboardText::OWN_MARKER`).
    pub fn copy(&mut self, id: ClippingId, now: DateTime<Utc>) -> Option<(String, ShelfEvent)> {
        let clipping = self.clippings.items().iter().find(|c| c.id == id)?.clone();
        self.just_copied = Some((id, now));
        Some((clipping.text, ShelfEvent::ClippingCopied))
    }

    /// The Clipping just put on the clipboard, which says "Copied" a moment.
    pub fn just_copied(&self) -> Option<ClippingId> {
        self.just_copied.map(|(id, _)| id)
    }

    /// A text read off the clipboard, kept as the rules say.
    pub fn keep_clipping(&mut self, text: &str, at: DateTime<Utc>) {
        if self.settings.enabled && self.settings.keeps_text {
            self.clippings.keep(text, at, self.settings.clipping_limit);
        }
    }

    pub fn remove_clipping(&mut self, id: ClippingId) {
        self.clippings.remove(id);
    }

    // MARK: - Drop area

    /// Holds the drop area while Kapa eats what was dropped on it — only where
    /// Kapa is shown and motion is not reduced, since without it there is
    /// nothing to watch. `gulp_length` is `KapaMotion.gulpLength`.
    pub fn swallow(&mut self, now: DateTime<Utc>, gulp_length_seconds: f64, kapa_shown: bool, reduced_motion: bool) {
        if !kapa_shown || reduced_motion {
            return;
        }
        let hold = Duration::milliseconds(((gulp_length_seconds + 0.15) * 1000.0).round() as i64);
        self.swallow = Some((now, hold));
    }

    /// When it was dropped, which starts the gulp.
    pub fn swallowed_at(&self) -> Option<DateTime<Utc>> {
        self.swallow.map(|(at, _)| at)
    }

    pub fn is_swallowing(&self, now: DateTime<Utc>) -> bool {
        self.swallow.is_some_and(|(at, hold)| now - at < hold)
    }

    /// The Shelf shows its drop area: a file carried over it, or one being
    /// eaten.
    pub fn shows_drop_area(&self, now: DateTime<Utc>) -> bool {
        self.is_drop_targeted || self.is_swallowing(now)
    }

    // MARK: - Time

    /// What time does by itself: "Copied" fades, the gulp ends, and a Clipping a
    /// day old goes whether or not anything is copied.
    pub fn tick(&mut self, now: DateTime<Utc>) {
        if self.just_copied.is_some_and(|(_, at)| now - at >= COPIED_FOR) {
            self.just_copied = None;
        }
        if self.swallow.is_some() && !self.is_swallowing(now) {
            self.swallow = None;
        }
        self.clippings.forget_old(now, self.settings.clippings_expire);
    }

    // MARK: - From the clipboard

    /// The clipboard and the screenshot folder, on the one switch (ADR 0005,
    /// amended 2026-10-02).
    fn watches_outside(&self) -> bool {
        self.settings.enabled && self.settings.takes_clipboard_images
    }

    /// The clipboard is read for images, for text, or for both.
    pub fn wants_clipboard(&self) -> bool {
        self.watches_outside() || (self.settings.enabled && self.settings.keeps_text)
    }

    pub fn wants_folder(&self) -> bool {
        self.watches_outside()
    }

    /// One look at the clipboard. Only what is copied after it was switched on:
    /// what is on the clipboard already is left alone. Until something is worth
    /// taking, only the kinds of thing on the clipboard are read
    /// (`ClipboardTake`).
    pub fn poll_clipboard(
        &mut self,
        now: DateTime<Utc>,
        board: &dyn ClipboardSource,
        files: &dyn ShelfFiles,
        codec: Option<&dyn ImageCodec>,
        names: &NameContext,
    ) -> Vec<ShelfEvent> {
        let mut events = vec![];
        if !self.wants_clipboard() {
            self.clipboard_watching = false;
            return events;
        }
        if !self.clipboard_watching {
            self.clipboard_watching = true;
            self.clipboard_count = board.change_count();
            return events;
        }
        // A day old, a Clipping goes whether or not anything is copied.
        self.clippings.forget_old(now, self.settings.clippings_expire);
        let count = board.change_count();
        if count == self.clipboard_count {
            return events;
        }
        self.clipboard_count = count;

        // Password apps that mark nothing: nothing is read while one is in front.
        let front = board.frontmost_application();
        if self.rules.is_excluded_application(front.as_deref()) {
            return events;
        }
        let items = board.item_types();
        let excluded: BTreeSet<String> = self.settings.excluded_applications.iter().cloned().collect();
        let text = self.settings.keeps_text
            && ClipboardText::is_kept(&items, front.as_deref(), &excluded, self.own_application.as_deref(), &self.rules);
        let from_file_manager = self.rules.is_file_manager(front.as_deref());
        // Copying in a file manager is left alone, so its files are not even read.
        let file_path = if items.iter().flatten().any(|t| t == "public.file-url") && !from_file_manager {
            board.file_path()
        } else {
            None
        };
        let meta = file_path.as_deref().and_then(|p| files.meta(p));
        let choice = if self.settings.takes_clipboard_images {
            ClipboardTake::choose(
                &items,
                file_path.as_deref(),
                meta.map(|m| m.size),
                meta.is_some_and(|m| m.is_directory),
                from_file_manager,
                &self.rules,
            )
        } else {
            Choice::Nothing
        };
        if choice == Choice::Nothing && !text {
            return events;
        }
        if board.access_refused() {
            self.clipboard_refused = true;
            events.push(ShelfEvent::ClipboardRefused);
            return events;
        }
        if text {
            match board.text() {
                Some(copied) => {
                    self.clipboard_refused = false;
                    self.keep_clipping(&copied, now);
                }
                None => {
                    events.push(ShelfEvent::ReadFailed("clipboard-text-unreadable"));
                    self.clipboard_refused = true;
                }
            }
        }
        let at = now.with_timezone(&names.offset);
        match choice {
            Choice::Nothing => {}
            Choice::Screenshot => {
                if let Some(data) = self.read(board, "public.png", &mut events) {
                    let name = ScreenshotClipboard::name(&at, names.language);
                    self.take_in_memory(&name, data, ShelfTab::Screenshots, now, &mut events);
                }
            }
            Choice::Data(kind) => {
                if let Some(mut data) = self.read(board, &kind, &mut events) {
                    let mut extension = ClipboardTake::extension_for(&kind);
                    // TIFF is the clipboard's converted copy, and large; kept as PNG.
                    if kind == "public.tiff" {
                        if let Some(png) = codec.and_then(|c| c.to_png(&data, &kind)) {
                            data = png;
                            extension = "png";
                        }
                    }
                    let name = ScreenshotClipboard::image_name(&at, names.language, extension);
                    self.take_in_memory(&name, data, ShelfTab::Screenshots, now, &mut events);
                }
            }
            Choice::FileIntoMemory => match file_path.as_deref().and_then(|p| files.read(p).map(|d| (p, d))) {
                Some((path, data)) => {
                    let name = super::model::file_name(path);
                    let tab = ShelfTab::for_copied(&name);
                    self.take_in_memory(&name, data, tab, now, &mut events);
                }
                None => events.push(ShelfEvent::ReadFailed("copied-file-unreadable")),
            },
            Choice::FileReference => {
                if let Some(path) = file_path {
                    let tab = ShelfTab::for_copied(&super::model::file_name(&path));
                    self.add(&[path], tab, files);
                    events.push(ShelfEvent::Took(tab));
                }
            }
        }
        events
    }

    fn read(&mut self, board: &dyn ClipboardSource, kind: &str, events: &mut Vec<ShelfEvent>) -> Option<Vec<u8>> {
        match board.data(kind) {
            Some(data) => {
                self.clipboard_refused = false;
                Some(data)
            }
            None => {
                events.push(ShelfEvent::ReadFailed("clipboard-image-unreadable"));
                self.clipboard_refused = true;
                None
            }
        }
    }

    fn take_in_memory(&mut self, name: &str, data: Vec<u8>, tab: ShelfTab, now: DateTime<Utc>, events: &mut Vec<ShelfEvent>) {
        self.add_in_memory(name, data, tab);
        if tab == ShelfTab::Screenshots && self.settings.enabled {
            if let Some(item) = self.shelf.items(tab).first() {
                self.taken_from_clipboard.insert(item.id, now);
            }
        }
        events.push(ShelfEvent::Took(tab));
    }

    // MARK: - From the screenshot folder

    /// The start of one look at the folder, or `None` when none is wanted: the
    /// switch is off, a look is still under way, or macOS saves screenshots
    /// somewhere else. The first look — as the switch is turned on — is what has
    /// macOS ask for the folder when it is one it guards.
    ///
    /// Read each time, so a folder chosen since is followed. While screenshots
    /// go to the clipboard, the folder gets none, and the system is not asked
    /// for one it would get nothing from.
    pub fn begin_folder_scan(
        &mut self,
        now: DateTime<Utc>,
        watcher: &dyn ScreenshotFolderWatcher,
        naming: Naming,
    ) -> Option<FolderScan> {
        if !self.wants_folder() {
            if self.folder_watching {
                self.folder_watching = false;
                self.folder_watch += 1;
                self.folder_scanning = false;
                self.folder_taken.clear();
                self.screenshot_folder_refused = false;
            }
            return None;
        }
        if !self.folder_watching {
            self.folder_watching = true;
            self.folder_watch += 1;
            self.folder_scanning = false;
            self.folder_taken.clear();
            self.folder_since = now;
        }
        if self.folder_scanning || !watcher.saves_to_folder() {
            return None;
        }
        self.folder_scanning = true;
        Some(FolderScan { folder: watcher.folder(), naming, watch: self.folder_watch, at: now })
    }

    /// The listing of the folder a scan asked for, taken in: new screenshots go
    /// under Screenshots, as references to their files.
    pub fn finish_folder_scan(&mut self, scan: FolderScan, listing: FolderListing, files: &dyn ShelfFiles) -> Vec<ShelfEvent> {
        let mut events = vec![];
        if scan.watch != self.folder_watch || !self.folder_watching {
            return events;
        }
        self.folder_scanning = false;
        match listing {
            FolderListing::Refused => {
                if !self.screenshot_folder_refused {
                    events.push(ShelfEvent::ScreenshotFolderRefused);
                }
                self.screenshot_folder_refused = true;
            }
            FolderListing::Entries(entries) => {
                self.screenshot_folder_refused = false;
                let new = screenshots::new_screenshots(&entries, self.folder_since, &self.folder_taken, &scan.naming);
                if new.is_empty() {
                    return events;
                }
                self.folder_taken.extend(new.iter().cloned());
                // The same screenshot, taken off the clipboard a moment ago, gives
                // way to its file where it stands: one tile, and a file behind it.
                let mut rest = vec![];
                for path in new {
                    match self.same_screenshot_in_memory(&path, scan.at, files) {
                        Some(id) => {
                            self.shelf.replace_with_file(id, &path);
                            self.taken_from_clipboard.remove(&id);
                        }
                        None => rest.push(path),
                    }
                }
                if rest.is_empty() {
                    self.refresh_availability(files);
                    return events;
                }
                self.add(&rest, ShelfTab::Screenshots, files);
                events.push(ShelfEvent::Took(ShelfTab::Screenshots));
            }
        }
        events
    }

    /// An image under Screenshots held in memory, taken off the clipboard within
    /// `SAME_SCREENSHOT_WITHIN` of `at`, whose bytes are the file's.
    fn same_screenshot_in_memory(&self, path: &std::path::Path, at: DateTime<Utc>, files: &dyn ShelfFiles) -> Option<ItemId> {
        let recent: Vec<ItemId> = self
            .taken_from_clipboard
            .iter()
            .filter(|(_, taken)| at - **taken <= SAME_SCREENSHOT_WITHIN && **taken - at <= SAME_SCREENSHOT_WITHIN)
            .map(|(id, _)| *id)
            .collect();
        if recent.is_empty() {
            return None;
        }
        let bytes = files.read(path)?;
        self.shelf.items(ShelfTab::Screenshots).iter().find_map(|item| match &item.content {
            super::model::Content::InMemory { data, .. } if recent.contains(&item.id) && *data == bytes => Some(item.id),
            _ => None,
        })
    }

    /// Both halves in one, for a host that may block.
    pub fn poll_folder(
        &mut self,
        now: DateTime<Utc>,
        watcher: &dyn ScreenshotFolderWatcher,
        naming: Naming,
        files: &dyn ShelfFiles,
    ) -> Vec<ShelfEvent> {
        match self.begin_folder_scan(now, watcher, naming) {
            Some(scan) => {
                let listing = watcher.list(&scan.folder);
                self.finish_folder_scan(scan, listing, files)
            }
            None => vec![],
        }
    }

    // MARK: - What the surface draws

    pub fn empty_title(&self, tab: ShelfTab) -> EmptyTitle {
        match tab {
            ShelfTab::Files => EmptyTitle::DragFiles,
            ShelfTab::Screenshots => EmptyTitle::ScreenshotsWait,
            ShelfTab::Clipboard => EmptyTitle::TextWaits,
        }
    }

    /// An empty tab says what lands in it, or, while its intake is off, how to
    /// turn it on.
    pub fn empty_detail(&self, tab: ShelfTab) -> EmptyDetail {
        match tab {
            ShelfTab::Files => EmptyDetail::FilesLimit,
            ShelfTab::Screenshots => {
                if self.settings.takes_clipboard_images {
                    EmptyDetail::ScreenshotsLimit
                } else {
                    EmptyDetail::TurnOnImages
                }
            }
            ShelfTab::Clipboard => {
                if !self.settings.keeps_text {
                    EmptyDetail::TurnOnText
                } else if self.settings.clippings_expire {
                    EmptyDetail::ClippingsExpire { limit: self.settings.clipping_limit.raw() }
                } else {
                    EmptyDetail::ClippingsStay { limit: self.settings.clipping_limit.raw() }
                }
            }
        }
    }

    /// How many the tab holds.
    pub fn held(&self, tab: ShelfTab) -> usize {
        match tab {
            ShelfTab::Clipboard => self.clippings.items().len(),
            other => self.shelf.items(other).len(),
        }
    }

    /// What the Shelf Module says in Copy Diagnostics: on or off, and how many
    /// in each tab — never a name or a path (ADR 0005) — and what the system
    /// refused.
    pub fn diagnostics(&self) -> Vec<String> {
        let mut said = vec![super::observation(self.settings.enabled, &self.shelf, &self.clippings)];
        if self.settings.enabled && self.clipboard_refused {
            said.push("shelf-clipboard-refused".into());
        }
        if self.settings.enabled && self.screenshot_folder_refused {
            said.push("shelf-screenshot-folder-refused".into());
        }
        said
    }

    pub fn view(&self, now: DateTime<Utc>) -> ShelfView {
        let item = |i: &ShelfItem| {
            let name = i.name();
            ItemView {
                id: i.id,
                kind: i.kind(),
                badge: ShelfFileKind::badge(&name),
                name,
                path: i.path().map(|p| standardize(p).to_string_lossy().into_owned()),
                in_memory: i.path().is_none(),
                missing: self.missing.contains(&i.id),
                has_thumbnail: self.thumbnails.contains_key(&i.id),
            }
        };
        ShelfView {
            enabled: self.settings.enabled,
            tab: self.tab,
            tabs: ShelfTab::ALL
                .into_iter()
                .map(|tab| TabView {
                    tab,
                    held: self.held(tab),
                    limit: if tab == ShelfTab::Clipboard { self.settings.clipping_limit.raw() } else { tab.limit() },
                    empty_title: self.empty_title(tab),
                    empty_detail: self.empty_detail(tab),
                })
                .collect(),
            files: self.shelf.items(ShelfTab::Files).iter().map(item).collect(),
            screenshots: self.shelf.items(ShelfTab::Screenshots).iter().map(item).collect(),
            // What a card shows is four lines: the surface is sent the start of each text,
            // not up to 100 000 characters twenty times over with every state (copying
            // goes by the id, and takes the whole text from here).
            clippings: self.clippings.items().iter().map(Clipping::preview).collect(),
            just_copied: self.just_copied(),
            is_drop_targeted: self.is_drop_targeted,
            is_drop_near: self.is_drop_near,
            shows_drop_area: self.shows_drop_area(now),
            swallowed_at: self.swallowed_at().map(|d| d.timestamp_millis()),
            takes_clipboard_images: self.settings.takes_clipboard_images,
            keeps_text: self.settings.keeps_text,
            clipping_limit: self.settings.clipping_limit,
            clippings_expire: self.settings.clippings_expire,
            excluded_applications: self.settings.excluded_applications.clone(),
            clipboard_refused: self.clipboard_refused,
            screenshot_folder_refused: self.screenshot_folder_refused,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ItemView {
    pub id: ItemId,
    pub name: String,
    pub kind: ShelfFileKind,
    /// The extension, four letters at most.
    pub badge: Option<String>,
    pub path: Option<String>,
    pub in_memory: bool,
    pub missing: bool,
    pub has_thumbnail: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TabView {
    pub tab: ShelfTab,
    pub held: usize,
    pub limit: usize,
    pub empty_title: EmptyTitle,
    pub empty_detail: EmptyDetail,
}

/// Everything a surface draws of the Shelf, with every decision made. Nothing
/// in it carries the bytes of an image: those stay with the controller.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ShelfView {
    pub enabled: bool,
    pub tab: ShelfTab,
    pub tabs: Vec<TabView>,
    pub files: Vec<ItemView>,
    pub screenshots: Vec<ItemView>,
    pub clippings: Vec<Clipping>,
    pub just_copied: Option<ClippingId>,
    pub is_drop_targeted: bool,
    pub is_drop_near: bool,
    pub shows_drop_area: bool,
    /// Unix milliseconds, which starts the gulp.
    pub swallowed_at: Option<i64>,
    pub takes_clipboard_images: bool,
    pub keeps_text: bool,
    pub clipping_limit: ClippingLimit,
    pub clippings_expire: bool,
    pub excluded_applications: Vec<String>,
    pub clipboard_refused: bool,
    pub screenshot_folder_refused: bool,
}
