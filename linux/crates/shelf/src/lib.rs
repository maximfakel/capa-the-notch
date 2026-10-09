//! The Shelf Module on Linux: files set down on the notch, the
//! screenshots that land in the screenshot folder or on the clipboard, and
//! what is copied, as Clippings — ADR 0005: little, and only in memory.
//!
//! The rules are `capa_core::shelf`. This crate is what talks to the machine:
//! the clipboard, the screenshot folder, thumbnails, the files dragged out —
//! and the `SurfaceModule` the hub hosts. Off, it runs nothing and holds
//! nothing (ADR 0003).

mod folder;
mod pixbuf;
mod pushed;
mod thumbs;
mod wlpaste;

pub use folder::SystemScreenshotFolder;
pub use pushed::{ClipboardPush, PushedClipboard};
pub use thumbs::{ImageThumbnailer, PngCodec};
pub use wlpaste::WlPaste;

use base64::Engine;
use capa_core::module::{BoxFuture, ModuleContext, SurfaceModule};
use capa_core::prefs::Preferences;
use capa_core::shelf::screenshots::Naming;
use capa_core::shelf::{
    ClipboardRules, ClipboardSource, ClippingId, ClippingLimit, DragFileStore, FileThumbnailer, ItemId, NameContext, NameLanguage,
    Platform, ScreenshotFolderWatcher, ShelfController, ShelfEvent, ShelfSettings, ShelfTab, StdFiles, TempDragFiles, THUMBNAIL_SIZE,
};
use capa_core::sound::SoundCue;
use capa_core::surface::SurfacePage;
use chrono::{DateTime, Utc};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::task::JoinHandle;

/// Every CapaTheNotch application id begins so: what is copied in its own windows is never kept.
const OWN_APPLICATIONS: &str = "tech.capathenotch.";

/// `KapaMotion.gulpLength`: how long Kapa takes to eat a dropped file.
const GULP_LENGTH: f64 = 1.3;

/// How the clipboard is read here.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Backend {
    /// A surface pushes what it sees (GNOME's Shell extension).
    Pushed,
    /// `wl-paste` (wlroots, KDE).
    WlPaste,
}

pub struct ShelfModule {
    inner: Arc<Inner>,
}

struct Inner {
    context: ModuleContext,
    controller: Mutex<ShelfController>,
    pushed: Arc<PushedClipboard>,
    board: Box<dyn ClipboardSource + Send + Sync>,
    backend: Backend,
    folder: Box<dyn ScreenshotFolderWatcher + Send + Sync>,
    naming: Naming,
    private_dir: PathBuf,
    runner: Mutex<Option<JoinHandle<()>>>,
    last_state: Mutex<String>,
    rules: ClipboardRules,
}

/// Where what the Shelf writes goes: memory-backed where the system has such a
/// place (`$XDG_RUNTIME_DIR`, a tmpfs only this user reads), else the temp folder.
fn private_directory() -> PathBuf {
    let base = std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .unwrap_or_else(std::env::temp_dir);
    base.join("capa-the-notch").join("shelf")
}

fn language_of(prefs: &Preferences) -> NameLanguage {
    match capa_core::loc::AppLanguage::from(prefs.language()).resolved() {
        capa_core::loc::AppLanguage::Russian => NameLanguage::Russian,
        _ => NameLanguage::English,
    }
}

fn settings_from(prefs: &Preferences) -> ShelfSettings {
    ShelfSettings {
        enabled: prefs.shelf_enabled(),
        takes_clipboard_images: prefs.shelf_takes_clipboard_images(),
        keeps_text: prefs.shelf_keeps_text(),
        clipping_limit: ClippingLimit::from_raw(prefs.clipping_limit().raw()).unwrap_or_default(),
        clippings_expire: prefs.clippings_expire(),
        excluded_applications: prefs.clipboard_excluded_applications(),
    }
}

pub fn module(context: ModuleContext) -> Arc<dyn SurfaceModule> {
    let backend = if WlPaste::available() {
        Backend::WlPaste
    } else {
        Backend::Pushed
    };
    let pushed = Arc::new(PushedClipboard::default());
    let board: Box<dyn ClipboardSource + Send + Sync> = match backend {
        Backend::Pushed => Box::new(SharedPushed(pushed.clone())),
        Backend::WlPaste => Box::new(WlPaste),
    };
    let home = capa_core::dirs::home();
    let platform = Platform::current();
    let desktop = std::env::var("XDG_CURRENT_DESKTOP").unwrap_or_default().to_ascii_lowercase();
    let naming = if desktop.contains("kde") { Naming::Spectacle } else { Naming::Gnome };
    let rules = ClipboardRules::for_platform(platform);
    let private_dir = private_directory();
    let drag: Arc<dyn DragFileStore> = Arc::new(TempDragFiles::at(private_dir.join("drag")));
    // What a previous run left behind goes at launch (ADR 0005).
    drag.remove_all();
    let _ = std::fs::remove_dir_all(private_dir.join("thumbs"));

    let controller = ShelfController::new(settings_from(&context.prefs), rules.clone())
        // Its Settings window, its drop window: all of CapaTheNotch's own (`tech.capathenotch.*`).
        .with_own_application(OWN_APPLICATIONS)
        .with_drag_files(drag);
    Arc::new(ShelfModule::build(Inner {
        context,
        controller: Mutex::new(controller),
        pushed,
        board,
        backend,
        folder: Box::new(SystemScreenshotFolder::locate(&home)),
        naming,
        private_dir,
        runner: Mutex::new(None),
        last_state: Mutex::new(String::new()),
        rules,
    }))
}

/// `PushedClipboard` shared between the module (which feeds it) and the controller (which reads it).
struct SharedPushed(Arc<PushedClipboard>);

impl ClipboardSource for SharedPushed {
    fn change_count(&self) -> u64 {
        self.0.change_count()
    }
    fn frontmost_application(&self) -> Option<String> {
        self.0.frontmost_application()
    }
    fn item_types(&self) -> Vec<Vec<String>> {
        self.0.item_types()
    }
    fn text(&self) -> Option<String> {
        self.0.text()
    }
    fn file_path(&self) -> Option<PathBuf> {
        self.0.file_path()
    }
    fn data(&self, type_identifier: &str) -> Option<Vec<u8>> {
        self.0.data(type_identifier)
    }
}

impl ShelfModule {
    fn build(inner: Inner) -> Self {
        let module = ShelfModule { inner: Arc::new(inner) };
        module.inner.apply_preferences();
        module
    }
}

impl Inner {
    fn now(&self) -> DateTime<Utc> {
        (self.context.clock)()
    }

    fn names(&self) -> NameContext {
        NameContext { language: language_of(&self.context.prefs), offset: *chrono::Local::now().offset() }
    }

    fn thumbs_dir(&self) -> PathBuf {
        self.private_dir.join("thumbs")
    }

    /// Takes the person's choices as they stand now.
    fn apply_preferences(self: &Arc<Self>) {
        let wanted = settings_from(&self.context.prefs);
        let now = self.now();
        {
            let mut c = self.controller.lock().unwrap();
            let current = c.settings().clone();
            if wanted.enabled != current.enabled {
                c.set_enabled(wanted.enabled);
            }
            if wanted.keeps_text != current.keeps_text {
                c.set_keeps_text(wanted.keeps_text);
            }
            if wanted.clipping_limit != current.clipping_limit {
                c.set_clipping_limit(wanted.clipping_limit);
            }
            if wanted.clippings_expire != current.clippings_expire {
                c.set_clippings_expire(wanted.clippings_expire, now);
            }
            if wanted.excluded_applications != current.excluded_applications {
                c.set_excluded_applications(wanted.excluded_applications.clone());
            }
            if wanted.takes_clipboard_images != current.takes_clipboard_images {
                c.set_takes_clipboard_images(wanted.takes_clipboard_images);
            }
        }
        if !wanted.enabled {
            // Off it holds nothing, and nothing of it is left on disk.
            let _ = std::fs::remove_dir_all(self.thumbs_dir());
        }
        self.ensure_running();
    }

    /// Starts the one task that watches while the Shelf is on, and ends it when it is off:
    /// a Module that is off runs nothing.
    fn ensure_running(self: &Arc<Self>) {
        let enabled = self.controller.lock().unwrap().is_enabled();
        let mut runner = self.runner.lock().unwrap();
        if !enabled {
            if let Some(task) = runner.take() {
                task.abort();
            }
            return;
        }
        if runner.is_some() {
            return;
        }
        // No runtime — a test of the rules — means nothing to watch with.
        let Ok(handle) = tokio::runtime::Handle::try_current() else { return };
        let this = self.clone();
        *runner = Some(handle.spawn(async move { this.run().await }));
    }

    /// The beat: time passes every quarter second, the clipboard is looked at
    /// every half, the screenshot folder every two.
    async fn run(self: Arc<Self>) {
        let mut beat = tokio::time::interval(Duration::from_millis(250));
        let mut n: u64 = 0;
        loop {
            beat.tick().await;
            n += 1;
            let this = self.clone();
            let _ = tokio::task::spawn_blocking(move || this.step(n)).await;
        }
    }

    /// One beat's work, off the async threads: `wl-paste` and the file system block.
    fn step(&self, n: u64) {
        let now = self.now();
        let mut events = vec![];
        {
            let mut c = self.controller.lock().unwrap();
            c.tick(now);
            if n.is_multiple_of(2) && c.wants_clipboard() {
                events.extend(c.poll_clipboard(now, &*self.board, &StdFiles, Some(&PngCodec), &self.names()));
            }
            if n.is_multiple_of(8) && c.wants_folder() {
                events.extend(c.poll_folder(now, &*self.folder, self.naming.clone(), &StdFiles));
            }
        }
        self.handle(events);
        self.make_thumbnails();
        self.publish_if_changed();
    }

    fn handle(&self, events: Vec<ShelfEvent>) {
        for event in events {
            match event {
                ShelfEvent::ClippingCopied => (self.context.sound)(SoundCue::ClippingCopied),
                // Silent (ADR 0007), and read failures are for the log by code only.
                ShelfEvent::Took(_) | ShelfEvent::ClipboardRefused | ShelfEvent::ScreenshotFolderRefused | ShelfEvent::ReadFailed(_) => {}
            }
        }
    }

    /// Draws what is waiting for a picture and writes it where the surfaces read it.
    fn make_thumbnails(&self) {
        let jobs = self.controller.lock().unwrap().pending_thumbnails();
        if jobs.is_empty() {
            return;
        }
        let (w, h) = THUMBNAIL_SIZE;
        for job in jobs {
            let (id, thumbnail) = match job {
                capa_core::shelf::ThumbnailJob::File { id, path } => (id, ImageThumbnailer.thumbnail_file(&path, w, h)),
                capa_core::shelf::ThumbnailJob::Data { id } => {
                    let data = self.controller.lock().unwrap().bytes(id).map(<[u8]>::to_vec);
                    (id, data.and_then(|d| ImageThumbnailer.thumbnail_data(&d, w, h)))
                }
            };
            if let Some(thumbnail) = thumbnail {
                if let Some(png) = thumbs::png(&thumbnail) {
                    write_private(&self.thumbs_dir(), &format!("{id}.png"), &png);
                }
                self.controller.lock().unwrap().set_thumbnail(id, thumbnail);
            }
        }
    }

    /// Thumbnail files of things no longer on the Shelf go.
    fn prune_thumbnails(&self, held: &[ItemId]) {
        let Ok(entries) = std::fs::read_dir(self.thumbs_dir()) else { return };
        for entry in entries.flatten() {
            let keep = entry
                .path()
                .file_stem()
                .and_then(|s| s.to_str())
                .and_then(|s| s.parse::<u64>().ok())
                .is_some_and(|id| held.contains(&ItemId(id)));
            if !keep {
                let _ = std::fs::remove_file(entry.path());
            }
        }
    }

    fn state(&self) -> Value {
        let now = self.now();
        let c = self.controller.lock().unwrap();
        let view = c.view(now);
        let held: Vec<ItemId> = view.files.iter().chain(&view.screenshots).map(|i| i.id).collect();
        let thumbnails: BTreeMap<String, String> = held
            .iter()
            .filter(|id| c.thumbnail(**id).is_some())
            .map(|id| (id.to_string(), self.thumbs_dir().join(format!("{id}.png")).to_string_lossy().into_owned()))
            .collect();
        let wants_text = c.is_enabled() && c.settings().keeps_text;
        let wants_images = c.is_enabled() && c.settings().takes_clipboard_images;
        let holds_clippings = !c.clippings().items().is_empty();
        // The counts in the person's language: "5 files", "5 файлов".
        let language = match language_of(&self.context.prefs) {
            NameLanguage::Russian => capa_core::loc::AppLanguage::Russian,
            NameLanguage::English => capa_core::loc::AppLanguage::English,
        };
        let counts = json!({
            "files": capa_core::loc::file_count_in(view.files.len() as i64, language),
            "screenshots": capa_core::loc::screenshot_count_in(view.screenshots.len() as i64, language),
            "clipboard": capa_core::loc::clipping_count_in(view.clippings.len() as i64, language),
        });
        let excluded = c.settings().excluded_applications.clone();
        drop(c);
        json!({
            "view": view,
            "thumbnails": thumbnails,
            "counts": counts,
            // What a host that reads the clipboard for the hub needs to know.
            "pushClipboard": self.backend == Backend::Pushed,
            "wantsClipboard": wants_text || wants_images,
            "wantsText": wants_text,
            "wantsImages": wants_images,
            "secretMarkers": self.rules.secret_markers,
            // The built-in list keeps everything out; the person's own list, text only (`ShelfController`).
            "excludedApplications": self.rules.excluded_applications,
            "textExcludedApplications": excluded,
            "fileManagers": self.rules.file_managers,
            // While the Shelf holds a Clipping the surface is kept out of screen capture (ADR 0005).
            "holdsClippings": holds_clippings,
        })
    }

    /// Tells the hub when what a surface draws has changed — a fade ended, a file arrived.
    fn publish_if_changed(&self) {
        let json = self.state().to_string();
        let changed = {
            let mut last = self.last_state.lock().unwrap();
            if *last == json {
                false
            } else {
                *last = json;
                true
            }
        };
        if changed {
            let held: Vec<ItemId> = {
                let c = self.controller.lock().unwrap();
                c.items(ShelfTab::Files).iter().chain(c.items(ShelfTab::Screenshots)).map(|i| i.id).collect()
            };
            self.prune_thumbnails(&held);
            (self.context.notify)();
        }
    }
}

/// Writes a file only this user can read.
fn write_private(dir: &Path, name: &str, bytes: &[u8]) {
    if std::fs::create_dir_all(dir).is_err() {
        return;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        // The parent too, as the Shelf's own folder: 0700.
        if let Some(parent) = dir.parent() {
            let _ = std::fs::set_permissions(parent, std::fs::Permissions::from_mode(0o700));
        }
        let _ = std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700));
    }
    let _ = std::fs::write(dir.join(name), bytes);
}

fn tab_of(value: &Value) -> Option<ShelfTab> {
    serde_json::from_value(value.clone()).ok()
}

fn id_of(args: &Value, key: &str) -> Option<u64> {
    args.get(key).and_then(Value::as_u64)
}

impl SurfaceModule for ShelfModule {
    fn id(&self) -> &'static str {
        "shelf"
    }

    fn state(&self) -> Value {
        self.inner.state()
    }

    fn page(&self) -> Option<SurfacePage> {
        self.inner.controller.lock().unwrap().is_enabled().then_some(SurfacePage::Shelf)
    }

    fn preferences_changed(&self) {
        self.inner.apply_preferences();
        self.inner.publish_if_changed();
    }

    /// `ShelfModule.observation(enabled:shelf:clippings:)`, and what the system
    /// refused (`shelf-clipboard-refused`, `shelf-screenshot-folder-refused`).
    fn observations(&self) -> Vec<String> {
        self.inner.controller.lock().unwrap().diagnostics()
    }

    fn call(&self, method: &str, args: Value) -> BoxFuture<Result<Value, String>> {
        let inner = self.inner.clone();
        let method = method.to_owned();
        Box::pin(async move {
            let answer = inner.dispatch(&method, &args)?;
            inner.publish_if_changed();
            Ok(answer)
        })
    }
}

impl Inner {
    /// A command from a surface.
    fn dispatch(self: &Arc<Self>, method: &str, args: &Value) -> Result<Value, String> {
        let now = self.now();
        let mut c = self.controller.lock().unwrap();
        match method {
            "setTab" => {
                c.tab = tab_of(args.get("tab").unwrap_or(&Value::Null)).ok_or("no such tab")?;
                Ok(Value::Null)
            }
            "clear" => {
                c.clear();
                Ok(Value::Null)
            }
            "remove" => {
                c.remove(ItemId(id_of(args, "id").ok_or("no id")?));
                Ok(Value::Null)
            }
            "removeClipping" => {
                c.remove_clipping(ClippingId(id_of(args, "id").ok_or("no id")?));
                Ok(Value::Null)
            }
            // Puts a Clipping on the clipboard: the text goes back to the surface to write
            // (it is the one that owns the clipboard), with the sound and "Copied".
            "copy" => {
                let (text, event) = c.copy(ClippingId(id_of(args, "id").ok_or("no id")?), now).ok_or("no such Clipping")?;
                drop(c);
                self.handle(vec![event]);
                // The surface owns the clipboard: it writes it, and is told.
                (self.context.emit)("shelf", "copyText", json!({ "text": text }));
                Ok(json!({ "text": text }))
            }
            // Files dropped on the surface, from the paths the host was given.
            "add" => {
                let paths: Vec<PathBuf> = args
                    .get("paths")
                    .and_then(Value::as_array)
                    .map(|a| a.iter().filter_map(Value::as_str).map(PathBuf::from).collect())
                    .unwrap_or_default();
                c.tab = ShelfTab::Files;
                c.add(&paths, ShelfTab::Files, &StdFiles);
                Ok(Value::Null)
            }
            // An image dropped with no file behind it, held in memory.
            "addImage" => {
                let data = base64::engine::general_purpose::STANDARD
                    .decode(args.get("data").and_then(Value::as_str).ok_or("no data")?)
                    .map_err(|e| e.to_string())?;
                let name = args.get("name").and_then(Value::as_str).map(str::to_owned).unwrap_or_else(|| {
                    let at = now.with_timezone(&chrono::Local);
                    capa_core::loc::format(
                        "Image %@",
                        &[capa_core::shelf::ScreenshotClipboard::name(&at, language_of(&self.context.prefs))
                            .chars()
                            .skip_while(|ch| !ch.is_ascii_digit())
                            .collect::<String>()
                            .into()],
                    )
                });
                c.tab = ShelfTab::Files;
                c.add_in_memory(&name, data, ShelfTab::Files);
                Ok(Value::Null)
            }
            "dragFile" => {
                let path = c.file_to_drag(ItemId(id_of(args, "id").ok_or("no id")?));
                Ok(json!({ "path": path.map(|p| p.to_string_lossy().into_owned()) }))
            }
            "refreshAvailability" => {
                c.refresh_availability(&StdFiles);
                Ok(Value::Null)
            }
            "dropTargeted" => {
                c.is_drop_targeted = args.get("value").and_then(Value::as_bool).unwrap_or(false);
                if !c.is_drop_targeted {
                    c.is_drop_near = false;
                }
                Ok(Value::Null)
            }
            "dropNear" => {
                c.is_drop_near = args.get("value").and_then(Value::as_bool).unwrap_or(false);
                Ok(Value::Null)
            }
            "swallow" => {
                let kapa = self.context.prefs.shows_kapa();
                c.swallow(now, GULP_LENGTH, kapa, args.get("reduceMotion").and_then(Value::as_bool).unwrap_or(false));
                Ok(Value::Null)
            }
            // A file let go over the surface, in one step, so no surface ever sees the
            // drop area without its file between them: Kapa eats it, and the drag is over.
            "dropped" => {
                let kapa = self.context.prefs.shows_kapa();
                c.swallow(now, GULP_LENGTH, kapa, args.get("reduceMotion").and_then(Value::as_bool).unwrap_or(false));
                c.is_drop_targeted = false;
                c.is_drop_near = false;
                Ok(Value::Null)
            }
            // What the surface read off the clipboard, where the hub cannot (`PushedClipboard`).
            "clipboard" => {
                drop(c);
                let push: ClipboardPush = serde_json::from_value(args.clone()).map_err(|e| e.to_string())?;
                self.pushed.push(push);
                let mut c = self.controller.lock().unwrap();
                let events = c.poll_clipboard(now, &*self.board, &StdFiles, Some(&PngCodec), &self.names());
                drop(c);
                self.handle(events);
                Ok(Value::Null)
            }
            // A thumbnail as PNG, base64, for a surface that cannot read the file.
            "thumbnail" => {
                drop(c);
                let id = id_of(args, "id").ok_or("no id")?;
                let bytes = std::fs::read(self.thumbs_dir().join(format!("{id}.png"))).map_err(|_| "no thumbnail")?;
                Ok(json!({ "png": base64::engine::general_purpose::STANDARD.encode(bytes) }))
            }
            other => Err(format!("shelf has no command {other}")),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use capa_core::prefs::MemoryStore;
    use chrono::TimeZone;
    use std::sync::atomic::{AtomicUsize, Ordering};

    struct Rig {
        module: ShelfModule,
        prefs: Arc<Preferences>,
        notified: Arc<AtomicUsize>,
        sounds: Arc<Mutex<Vec<SoundCue>>>,
        events: Arc<Mutex<Vec<(String, String, Value)>>>,
        clock: Arc<Mutex<DateTime<Utc>>>,
        dir: PathBuf,
    }

    fn rig(name: &str) -> Rig {
        let dir = std::env::temp_dir().join(format!("capa-shelf-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let prefs = Arc::new(Preferences::new(Arc::new(MemoryStore::new())));
        prefs.set_language(capa_core::prefs::AppLanguage::English);
        let clock = Arc::new(Mutex::new(Utc.timestamp_opt(1_700_000_000, 0).unwrap()));
        let (notified, sounds, events) = (Arc::new(AtomicUsize::new(0)), Arc::new(Mutex::new(vec![])), Arc::new(Mutex::new(vec![])));
        let (n, s, e, c) = (notified.clone(), sounds.clone(), events.clone(), clock.clone());
        let context = ModuleContext {
            prefs: prefs.clone(),
            clock: Arc::new(move || *c.lock().unwrap()),
            prefs_changed: Arc::new(|| {}),
            notify: Arc::new(move || {
                n.fetch_add(1, Ordering::SeqCst);
            }),
            emit: Arc::new(move |m, name, data| e.lock().unwrap().push((m.into(), name.into(), data))),
            sound: Arc::new(move |cue| s.lock().unwrap().push(cue)),
        };
        let pushed = Arc::new(PushedClipboard::default());
        let rules = ClipboardRules::linux();
        let private_dir = dir.join("private");
        let controller = ShelfController::new(settings_from(&prefs), rules.clone())
            .with_own_application(OWN_APPLICATIONS)
            .with_drag_files(Arc::new(TempDragFiles::at(private_dir.join("drag"))));
        let inner = Inner {
            context,
            controller: Mutex::new(controller),
            pushed: pushed.clone(),
            board: Box::new(SharedPushed(pushed)),
            backend: Backend::Pushed,
            folder: Box::new(SystemScreenshotFolder::at(dir.join("Screenshots"))),
            naming: Naming::Gnome,
            private_dir,
            runner: Mutex::new(None),
            last_state: Mutex::new(String::new()),
            rules,
        };
        Rig { module: ShelfModule::build(inner), prefs, notified, sounds, events, clock, dir }
    }

    impl Rig {
        fn call(&self, method: &str, args: Value) -> Result<Value, String> {
            self.module.inner.dispatch(method, &args)
        }
        fn state(&self) -> Value {
            self.module.state()
        }
        fn turn_on(&self) {
            self.prefs.set_shelf_enabled(true);
            self.module.preferences_changed();
        }
        fn beat(&self, n: u64) {
            self.module.inner.step(n);
        }
        fn push(&self, args: Value) {
            self.call("clipboard", args).unwrap();
        }
    }

    fn png() -> Vec<u8> {
        let image = image::RgbaImage::from_pixel(60, 40, image::Rgba([200, 30, 30, 255]));
        let mut out = std::io::Cursor::new(Vec::new());
        image.write_to(&mut out, image::ImageFormat::Png).unwrap();
        out.into_inner()
    }

    #[test]
    fn off_it_has_no_page_holds_nothing_and_takes_nothing() {
        let r = rig("off");
        assert_eq!(r.module.page(), None);
        let s = r.state();
        assert_eq!(s["view"]["enabled"], false);
        assert_eq!(s["wantsClipboard"], false);
        r.call("add", json!({"paths": [r.dir.to_string_lossy()]})).unwrap();
        assert_eq!(r.state()["view"]["files"].as_array().unwrap().len(), 0, "off, the Shelf takes nothing");
    }

    #[test]
    fn on_it_has_a_page_and_holds_dropped_files_as_references() {
        let r = rig("files");
        r.turn_on();
        assert_eq!(r.module.page(), Some(SurfacePage::Shelf));
        let file = r.dir.join("notes.txt");
        std::fs::write(&file, "x").unwrap();
        r.call("add", json!({"paths": [file.to_string_lossy()]})).unwrap();
        let s = r.state();
        let files = s["view"]["files"].as_array().unwrap();
        assert_eq!(files.len(), 1);
        assert_eq!(files[0]["name"], "notes.txt");
        assert_eq!(files[0]["inMemory"], false);
        assert_eq!(files[0]["missing"], false);
        let id = files[0]["id"].as_u64().unwrap();
        let drag = r.call("dragFile", json!({"id": id})).unwrap();
        assert_eq!(drag["path"], file.to_string_lossy().as_ref());
        // Moved or deleted since, it is noticed when the page is shown.
        std::fs::remove_file(&file).unwrap();
        r.call("refreshAvailability", Value::Null).unwrap();
        assert_eq!(r.state()["view"]["files"][0]["missing"], true);
    }

    #[test]
    fn an_image_dropped_with_no_file_is_held_in_memory_with_a_thumbnail_and_dragged_as_a_file() {
        let r = rig("image");
        r.turn_on();
        r.call("addImage", json!({"name": "pic.png", "data": base64::engine::general_purpose::STANDARD.encode(png())})).unwrap();
        let s = r.state();
        assert_eq!(s["view"]["files"][0]["inMemory"], true);
        r.beat(1);
        let s = r.state();
        assert_eq!(s["view"]["files"][0]["hasThumbnail"], true);
        let id = s["view"]["files"][0]["id"].as_u64().unwrap();
        let path = s["thumbnails"][id.to_string()].as_str().unwrap().to_owned();
        assert!(Path::new(&path).exists(), "the picture is where the surfaces read it");
        let served = r.call("thumbnail", json!({"id": id})).unwrap();
        assert!(served["png"].as_str().unwrap().len() > 20);
        // Dragging it out writes a file for the drag, in the Shelf's own folder.
        let drag = r.call("dragFile", json!({"id": id})).unwrap();
        let dragged = PathBuf::from(drag["path"].as_str().unwrap());
        assert!(dragged.starts_with(r.dir.join("private")));
        assert_eq!(std::fs::read(&dragged).unwrap(), png());
        // Removed, its picture goes with it.
        r.call("remove", json!({"id": id})).unwrap();
        r.beat(2);
        r.module.inner.publish_if_changed();
        assert!(!Path::new(&path).exists());
    }

    #[test]
    fn switching_it_off_empties_it_and_removes_its_pictures() {
        let r = rig("empties");
        r.turn_on();
        r.call("addImage", json!({"name": "pic.png", "data": base64::engine::general_purpose::STANDARD.encode(png())})).unwrap();
        r.beat(1);
        assert!(r.dir.join("private/thumbs").exists());
        r.prefs.set_shelf_enabled(false);
        r.module.preferences_changed();
        assert_eq!(r.state()["view"]["files"].as_array().unwrap().len(), 0);
        assert!(!r.dir.join("private/thumbs").exists());
        assert_eq!(r.module.page(), None);
    }

    #[test]
    fn the_clipboard_is_wanted_only_when_asked_for_and_text_only_after_the_first_look() {
        let r = rig("text");
        r.turn_on();
        assert_eq!(r.state()["wantsClipboard"], false, "everything it takes by itself is off until asked for");
        r.prefs.set_shelf_keeps_text(true);
        r.module.preferences_changed();
        let s = r.state();
        assert_eq!((s["wantsText"].clone(), s["wantsImages"].clone(), s["pushClipboard"].clone()), (json!(true), json!(false), json!(true)));

        let text = |count: u64, t: &str| json!({"count": count, "frontmost": "org.gnome.Terminal",
            "types": [["text/plain;charset=utf-8"]], "text": t});
        // What was on the clipboard when it began to be watched is left alone.
        r.push(text(1, "already there"));
        assert_eq!(r.state()["view"]["clippings"].as_array().unwrap().len(), 0);
        r.push(text(2, "copied after"));
        let s = r.state();
        assert_eq!(s["view"]["clippings"][0]["text"], "copied after");
        assert_eq!(s["holdsClippings"], true, "the surface is kept out of screen capture while it holds one");
    }

    #[test]
    fn a_copy_marked_secret_or_made_in_a_password_app_is_never_kept() {
        let r = rig("secret");
        r.turn_on();
        r.prefs.set_shelf_keeps_text(true);
        r.module.preferences_changed();
        r.push(json!({"count": 1, "types": [["text/plain"]], "text": "start"}));
        r.push(json!({"count": 2, "frontmost": "org.gnome.Terminal",
            "types": [["text/plain", "x-kde-passwordManagerHint"]], "text": "hunter2"}));
        r.push(json!({"count": 3, "frontmost": "org.keepassxc.KeePassXC", "types": [["text/plain"]], "text": "p4ss"}));
        assert_eq!(r.state()["view"]["clippings"].as_array().unwrap().len(), 0);
        r.push(json!({"count": 4, "frontmost": "org.gnome.Terminal", "types": [["text/plain"]], "text": "fine"}));
        assert_eq!(r.state()["view"]["clippings"].as_array().unwrap().len(), 1);
        // The person's own list of applications.
        r.prefs.set_clipboard_excluded_applications(&["my.app".to_owned()]);
        r.module.preferences_changed();
        r.push(json!({"count": 5, "frontmost": "my.app", "types": [["text/plain"]], "text": "nope"}));
        assert_eq!(r.state()["view"]["clippings"].as_array().unwrap().len(), 1);
    }

    #[test]
    fn a_screenshot_copied_to_the_clipboard_lands_under_screenshots() {
        let r = rig("shot");
        r.turn_on();
        r.prefs.set_shelf_takes_clipboard_images(true);
        r.module.preferences_changed();
        assert_eq!(r.state()["wantsImages"], true);
        r.push(json!({"count": 1, "types": [["image/png"]]}));
        r.push(json!({"count": 2, "types": [["image/png"]], "data": {"image/png": base64::engine::general_purpose::STANDARD.encode(png())}}));
        let s = r.state();
        assert_eq!(s["view"]["screenshots"].as_array().unwrap().len(), 1);
        assert!(s["view"]["screenshots"][0]["name"].as_str().unwrap().starts_with("Screenshot "));
    }

    #[test]
    fn a_screenshot_saved_to_the_folder_after_it_was_switched_on_is_taken_as_a_reference() {
        let r = rig("folder");
        r.turn_on();
        let folder = r.dir.join("Screenshots");
        std::fs::create_dir_all(&folder).unwrap();
        // Saved before: left alone. The clock the controller reads is the context's.
        std::fs::write(folder.join("Screenshot from 2020-01-01 00-00-01.png"), png()).unwrap();
        r.prefs.set_shelf_takes_clipboard_images(true);
        r.module.preferences_changed();
        std::thread::sleep(std::time::Duration::from_millis(20));
        *r.clock.lock().unwrap() = Utc::now();
        r.beat(0); // the first look begins the watch (n % 8 == 0)
        std::thread::sleep(std::time::Duration::from_millis(20));
        *r.clock.lock().unwrap() = Utc::now();
        std::fs::write(folder.join("Screenshot from 2026-10-05 12-00-01.png"), png()).unwrap();
        r.beat(8);
        let s = r.state();
        let shots = s["view"]["screenshots"].as_array().unwrap();
        assert_eq!(shots.len(), 1, "{s}");
        assert_eq!(shots[0]["inMemory"], false);
    }

    #[test]
    fn choosing_a_clipping_puts_it_on_the_clipboard_says_copied_and_taps() {
        let r = rig("copy");
        r.turn_on();
        r.prefs.set_shelf_keeps_text(true);
        r.module.preferences_changed();
        r.push(json!({"count": 1, "types": [["text/plain"]], "text": "a"}));
        r.push(json!({"count": 2, "frontmost": "x", "types": [["text/plain"]], "text": "hello  world"}));
        let id = r.state()["view"]["clippings"][0]["id"].as_u64().unwrap();
        let answer = r.call("copy", json!({"id": id})).unwrap();
        assert_eq!(answer["text"], "hello  world");
        assert_eq!(r.state()["view"]["justCopied"], id);
        assert_eq!(*r.sounds.lock().unwrap(), vec![SoundCue::ClippingCopied]);
        let events = r.events.lock().unwrap();
        assert_eq!(events[0].1, "copyText");
        drop(events);
        // "Copied" fades after a moment.
        *r.clock.lock().unwrap() += chrono::Duration::seconds(2);
        r.beat(1);
        assert_eq!(r.state()["view"]["justCopied"], Value::Null);
        r.call("removeClipping", json!({"id": id})).unwrap();
        assert_eq!(r.state()["view"]["clippings"].as_array().unwrap().len(), 0);
    }

    #[test]
    fn the_drop_area_follows_the_file_and_kapa_eats_it() {
        let r = rig("drop");
        r.turn_on();
        r.call("dropTargeted", json!({"value": true})).unwrap();
        assert_eq!(r.state()["view"]["showsDropArea"], true);
        r.call("dropNear", json!({"value": true})).unwrap();
        assert_eq!(r.state()["view"]["isDropNear"], true);
        r.call("swallow", json!({})).unwrap();
        r.call("dropTargeted", json!({"value": false})).unwrap();
        let s = r.state();
        assert_eq!(s["view"]["isDropNear"], false);
        assert_eq!(s["view"]["showsDropArea"], true, "held while Kapa is eating");
        assert!(s["view"]["swallowedAt"].is_i64());
        *r.clock.lock().unwrap() += chrono::Duration::seconds(3);
        r.beat(1);
        assert_eq!(r.state()["view"]["showsDropArea"], false);
    }

    #[test]
    fn a_drop_is_one_step_eaten_and_the_drag_over() {
        let r = rig("dropped");
        r.turn_on();
        r.call("dropTargeted", json!({"value": true})).unwrap();
        r.call("dropNear", json!({"value": true})).unwrap();
        r.call("dropped", json!({"reduceMotion": false})).unwrap();
        let s = r.state();
        assert_eq!((s["view"]["isDropTargeted"].clone(), s["view"]["isDropNear"].clone()), (json!(false), json!(false)));
        assert_eq!(s["view"]["showsDropArea"], true, "held while Kapa is eating");
        assert!(s["view"]["swallowedAt"].is_i64());
        // Under Reduce Motion there is nothing to watch: the drag is just over.
        r.call("dropTargeted", json!({"value": true})).unwrap();
        *r.clock.lock().unwrap() += chrono::Duration::seconds(3);
        r.beat(1);
        r.call("dropped", json!({"reduceMotion": true})).unwrap();
        assert_eq!(r.state()["view"]["showsDropArea"], false);
    }

    #[test]
    fn diagnostics_say_how_many_and_what_was_refused_never_which() {
        let r = rig("observations");
        assert_eq!(r.module.observations(), vec!["shelf-off".to_owned()]);
        r.turn_on();
        r.call("addImage", json!({"name": "a.png", "data": base64::engine::general_purpose::STANDARD.encode(png())})).unwrap();
        assert_eq!(r.module.observations(), vec!["shelf-on-1-files-0-screenshots".to_owned()]);
    }

    #[test]
    fn an_image_too_large_to_send_is_not_a_refusal_and_a_tiff_is_kept_as_png() {
        let r = rig("large");
        r.turn_on();
        r.prefs.set_shelf_takes_clipboard_images(true);
        r.module.preferences_changed();
        r.push(json!({"count": 1, "types": [["image/png"]]}));
        r.push(json!({"count": 2, "types": [["image/png"]], "tooLarge": ["image/png"]}));
        let s = r.state();
        assert_eq!(s["view"]["screenshots"].as_array().unwrap().len(), 0);
        assert_eq!(s["view"]["clipboardRefused"], false);
        assert!(r.module.observations().iter().all(|o| o != "shelf-clipboard-refused"));

        let tiff = {
            let image = image::RgbaImage::from_pixel(8, 8, image::Rgba([10, 200, 30, 255]));
            let mut out = std::io::Cursor::new(Vec::new());
            image.write_to(&mut out, image::ImageFormat::Tiff).unwrap();
            out.into_inner()
        };
        r.push(json!({"count": 3, "frontmost": "org.gnome.Loupe", "types": [["image/tiff"]],
            "data": {"image/tiff": base64::engine::general_purpose::STANDARD.encode(tiff)}}));
        let s = r.state();
        let name = s["view"]["screenshots"][0]["name"].as_str().unwrap().to_owned();
        assert!(name.ends_with(".png"), "{name}");
    }

    #[test]
    fn copies_in_capathenotchs_own_windows_are_never_kept() {
        let r = rig("own");
        r.turn_on();
        r.prefs.set_shelf_keeps_text(true);
        r.module.preferences_changed();
        r.push(json!({"count": 1, "types": [["text/plain"]], "text": "start"}));
        r.push(json!({"count": 2, "frontmost": "tech.capathenotch.Settings", "types": [["text/plain"]], "text": "mine"}));
        assert_eq!(r.state()["view"]["clippings"].as_array().unwrap().len(), 0);
    }

    #[test]
    fn counts_are_said_in_the_language_in_force() {
        let r = rig("counts");
        r.turn_on();
        r.call("addImage", json!({"name": "a.png", "data": base64::engine::general_purpose::STANDARD.encode(png())})).unwrap();
        assert_eq!(r.state()["counts"]["files"], "1 file");
        r.prefs.set_language(capa_core::prefs::AppLanguage::Russian);
        assert_eq!(r.state()["counts"]["files"], "1 файл");
        assert_eq!(r.state()["counts"]["clipboard"], "0 текстов");
    }

    #[test]
    fn tabs_clear_one_at_a_time() {
        let r = rig("tabs");
        r.turn_on();
        r.call("addImage", json!({"name": "a.png", "data": base64::engine::general_purpose::STANDARD.encode(png())})).unwrap();
        r.call("setTab", json!({"tab": "screenshots"})).unwrap();
        assert_eq!(r.state()["view"]["tab"], "screenshots");
        r.call("clear", Value::Null).unwrap();
        assert_eq!(r.state()["view"]["files"].as_array().unwrap().len(), 1, "Clear empties only the tab it is on");
        r.call("setTab", json!({"tab": "files"})).unwrap();
        r.call("clear", Value::Null).unwrap();
        assert_eq!(r.state()["view"]["files"].as_array().unwrap().len(), 0);
        assert!(r.call("setTab", json!({"tab": "nope"})).is_err());
        assert!(r.call("nothing", Value::Null).is_err());
    }

    #[test]
    fn a_change_the_surfaces_should_see_notifies_the_hub_once() {
        let r = rig("notify");
        r.turn_on();
        r.module.inner.publish_if_changed();
        let before = r.notified.load(Ordering::SeqCst);
        r.module.inner.publish_if_changed();
        assert_eq!(r.notified.load(Ordering::SeqCst), before, "nothing changed, nothing said");
        r.call("setTab", json!({"tab": "clipboard"})).unwrap();
        r.module.inner.publish_if_changed();
        assert_eq!(r.notified.load(Ordering::SeqCst), before + 1);
    }
}
