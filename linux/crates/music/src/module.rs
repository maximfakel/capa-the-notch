//! The Music Module as the hub hosts it: the session (what is shown, loaded,
//! remembered), a media source while the Module is on, and the volume bar's
//! model: read once as a track loads, followed while a bar is on screen. Off,
//! it runs nothing (ADR 0003): no source, no thread, no listening to the audio
//! system.

use crate::artwork::{self, ArtworkStore};
use capa_core::module::{BoxFuture, ModuleContext, SurfaceModule};
use capa_core::music::{
    AudioOutput, MediaEvent, MediaSource, MusicCommand, MusicSession, NowPlaying, SystemVolume,
};
use capa_core::surface::SurfacePage;
use chrono::{DateTime, Utc};
use serde_json::{json, Value};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{channel, RecvTimeoutError};
use std::sync::{Arc, Mutex, Weak};
use std::time::Duration;

/// `MusicModule.unreadableCode`.
pub const UNREADABLE_CODE: &str = "music-unreadable";

/// Where the module gets its source and its output from: the machine's own,
/// or a fake.
pub trait Parts: Send + Sync {
    fn source(&self, artwork: Arc<ArtworkStore>) -> Box<dyn MediaSource>;
    fn output(&self, on_change: Arc<dyn Fn() + Send + Sync>) -> Box<dyn AudioOutput + Send>;
}

/// The platform's own.
pub struct Platform;

impl Parts for Platform {
    #[cfg(target_os = "linux")]
    fn source(&self, artwork: Arc<ArtworkStore>) -> Box<dyn MediaSource> {
        Box::new(crate::mpris::MprisSource::new(artwork))
    }

    #[cfg(not(target_os = "linux"))]
    fn source(&self, _artwork: Arc<ArtworkStore>) -> Box<dyn MediaSource> {
        Box::new(Silent)
    }

    #[cfg(target_os = "linux")]
    fn output(&self, on_change: Arc<dyn Fn() + Send + Sync>) -> Box<dyn AudioOutput + Send> {
        Box::new(crate::volume::LinuxOutput::detect(on_change))
    }

    #[cfg(not(target_os = "linux"))]
    fn output(&self, _on_change: Arc<dyn Fn() + Send + Sync>) -> Box<dyn AudioOutput + Send> {
        Box::new(NoOutput)
    }
}

#[cfg(not(target_os = "linux"))]
struct Silent;
#[cfg(not(target_os = "linux"))]
impl MediaSource for Silent {
    fn start(&mut self, events: std::sync::mpsc::Sender<MediaEvent>) {
        let _ = events.send(MediaEvent::Unreadable { unreadable: true });
    }
    fn stop(&mut self) {}
    fn send(&self, _: MusicCommand) {}
}
#[cfg(not(target_os = "linux"))]
struct NoOutput;
#[cfg(not(target_os = "linux"))]
impl AudioOutput for NoOutput {
    fn level_settable(&self) -> bool { false }
    fn read_level(&self) -> f64 { 0.0 }
    fn mute_settable(&self) -> bool { false }
    fn read_muted(&self) -> bool { false }
    fn write_level(&mut self, _: f64) {}
    fn write_muted(&mut self, _: bool) {}
    fn start_listening(&mut self) {}
    fn stop_listening(&mut self) {}
}

/// `SystemVolume` is generic over its output; the module holds one it can swap.
struct BoxedOutput(Box<dyn AudioOutput + Send>);

impl AudioOutput for BoxedOutput {
    fn level_settable(&self) -> bool { self.0.level_settable() }
    fn read_level(&self) -> f64 { self.0.read_level() }
    fn mute_settable(&self) -> bool { self.0.mute_settable() }
    fn read_muted(&self) -> bool { self.0.read_muted() }
    fn write_level(&mut self, level: f64) { self.0.write_level(level) }
    fn write_muted(&mut self, muted: bool) { self.0.write_muted(muted) }
    fn start_listening(&mut self) { self.0.start_listening() }
    fn stop_listening(&mut self) { self.0.stop_listening() }
    fn take_device_changed(&mut self) -> bool { self.0.take_device_changed() }
}

#[derive(Default)]
struct Inner {
    session: MusicSession,
    source: Option<Box<dyn MediaSource>>,
    /// The thread that carries the source's events in; ended by clearing this.
    pump: Option<Arc<AtomicBool>>,
    volume: Option<SystemVolume<BoxedOutput>>,
    /// Where the running source tells its events, kept to start another on it.
    events: Option<std::sync::mpsc::Sender<MediaEvent>>,
    /// The runtime the source was started in (the Linux source spawns onto it).
    runtime: Option<tokio::runtime::Handle>,
    /// Since when reading has not worked, while it has not.
    unreadable_since: Option<DateTime<Utc>>,
    /// What the surface was last told, the clock aside (`timeless`).
    told: Option<Value>,
}

pub struct MusicModule {
    /// The `Arc` this lives in: the pump and the volume listener hold it weakly.
    me: Weak<MusicModule>,
    context: ModuleContext,
    parts: Arc<dyn Parts>,
    artwork: Arc<ArtworkStore>,
    inner: Arc<Mutex<Inner>>,
}

/// The module with the machine's own source and output. Needs a Tokio
/// runtime when the Module is on (the Linux source spawns onto it).
pub fn module(context: ModuleContext) -> Arc<dyn SurfaceModule> {
    MusicModule::with_parts(context, Arc::new(Platform))
}

impl MusicModule {
    pub fn with_parts(context: ModuleContext, parts: Arc<dyn Parts>) -> Arc<Self> {
        let module = Arc::new_cyclic(|me| Self {
            me: me.clone(),
            context,
            parts,
            artwork: Arc::new(ArtworkStore::new()),
            inner: Arc::new(Mutex::new(Inner::default())),
        });
        module.follow_preference();
        module
    }

    fn upgrade(&self) -> Option<Arc<MusicModule>> {
        self.me.upgrade()
    }

    fn enabled(&self) -> bool {
        self.context.prefs.music_enabled()
    }

    /// Starts or stops what runs, to match the preference. Does not notify:
    /// whoever changed the preference publishes the state.
    fn follow_preference(self: &Arc<Self>) {
        let enabled = self.enabled();
        let mut inner = self.inner.lock().unwrap();
        let running = inner.session.is_on();
        if enabled && !running {
            self.start(&mut inner);
        } else if !enabled && running {
            self.stop(&mut inner);
        }
    }

    fn start(self: &Arc<Self>, inner: &mut Inner) {
        inner.session.start();
        // Whoever switched it on publishes the state; the pump tells only what changes after.
        inner.told = Some(timeless(Self::state_of(inner, (self.context.clock)())));
        let (tx, rx) = channel::<MediaEvent>();
        inner.runtime = tokio::runtime::Handle::try_current().ok();
        inner.events = Some(tx.clone());
        inner.unreadable_since = None;
        let mut source = self.parts.source(self.artwork.clone());
        source.start(tx);
        inner.source = Some(source);

        let alive = Arc::new(AtomicBool::new(true));
        inner.pump = Some(alive.clone());
        let weak: Weak<MusicModule> = Arc::downgrade(self);
        std::thread::spawn(move || pump(weak, rx, alive));
    }

    fn stop(&self, inner: &mut Inner) {
        let now = (self.context.clock)();
        if let Some(alive) = inner.pump.take() {
            alive.store(false, Ordering::Relaxed);
        }
        if let Some(mut source) = inner.source.take() {
            source.stop();
        }
        inner.events = None;
        inner.runtime = None;
        inner.unreadable_since = None;
        // The volume bar's listening ends with the Module (ADR 0003).
        if let Some(mut volume) = inner.volume.take() {
            while volume.is_watching() {
                volume.stop_watching();
            }
        }
        inner.session.stop(now);
    }

    /// Takes an event in. Returns whether a track loaded with it: one where
    /// none was, or another than the one before.
    fn apply(&self, event: MediaEvent) -> bool {
        let now = (self.context.clock)();
        let mut inner = self.inner.lock().unwrap();
        let identity = |track: NowPlaying| (track.title, track.artist, track.player);
        let before = inner.session.view(now).loaded.map(identity);
        match event {
            MediaEvent::Reading { reading } => inner.session.observe(&reading, now),
            MediaEvent::Lost => inner.session.lose(now),
            MediaEvent::Unreadable { unreadable } => {
                inner.session.set_unreadable(unreadable, now);
                if !unreadable {
                    inner.unreadable_since = None;
                } else if inner.unreadable_since.is_none() {
                    inner.unreadable_since = Some(now);
                }
            }
        }
        let after = inner.session.view(now).loaded.map(identity);
        after.is_some() && after != before
    }

    /// A track loaded: the level is read once, so the first open already has
    /// it — the Swift's page is built, and reads it (`onAppear`), while the
    /// surface is still closed. Nothing is listened to; while a bar listens,
    /// what it hears is newer, and is left alone. The output is looked at
    /// afresh, since what it heard before may be old by now.
    fn read_volume(self: &Arc<Self>) {
        {
            let mut inner = self.inner.lock().unwrap();
            if !inner.session.is_on() || inner.volume.as_ref().is_some_and(SystemVolume::is_watching) {
                return;
            }
            inner.volume = None;
        }
        self.with_volume(SystemVolume::read);
    }

    /// The Swift reader tests again a minute after a failed test, for as long
    /// as the Module is on: one failure — a session bus restarting — must not
    /// close the Module until it is switched off and on. Here the source is
    /// started afresh on the same channel.
    fn retry_if_unreadable(&self) {
        let now = (self.context.clock)();
        let (old, events, runtime) = {
            let mut inner = self.inner.lock().unwrap();
            let due = inner.unreadable_since.is_some_and(|since| {
                (now - since).num_milliseconds() as f64 >= capa_core::music::ReaderSupervisor::RETRY_AFTER * 1000.0
            });
            if !inner.session.is_on() || !due {
                return;
            }
            // The next try is another minute on, unless this one works.
            inner.unreadable_since = Some(now);
            (inner.source.take(), inner.events.clone(), inner.runtime.clone())
        };
        if let Some(mut old) = old {
            old.stop();
        }
        let Some(events) = events else { return };
        let _entered = runtime.as_ref().map(|r| r.enter());
        let mut source = self.parts.source(self.artwork.clone());
        source.start(events);
        let mut inner = self.inner.lock().unwrap();
        if inner.session.is_on() && inner.source.is_none() {
            inner.source = Some(source);
        } else {
            source.stop();
        }
    }

    /// The output's level, its mute or the device itself changed. Reads only
    /// what the output last heard: nothing runs while the lock is held.
    fn volume_changed(&self) {
        {
            let mut inner = self.inner.lock().unwrap();
            if let Some(volume) = inner.volume.as_mut() {
                if volume.output().take_device_changed() {
                    volume.follow();
                } else {
                    volume.read();
                }
            }
        }
        self.tell_if_changed();
    }

    /// Tells the hub when what the surface shows changed, and only then: a
    /// reading that repeats the last, a level heard again, a moment that passes
    /// while a pause lingers change nothing it draws.
    fn tell_if_changed(&self) {
        let changed = {
            let mut inner = self.inner.lock().unwrap();
            let state = timeless(Self::state_of(&inner, (self.context.clock)()));
            if inner.told.as_ref() == Some(&state) {
                false
            } else {
                inner.told = Some(state);
                true
            }
        };
        if changed {
            (self.context.notify)();
        }
    }

    fn state_of(inner: &Inner, now: DateTime<Utc>) -> Value {
        let view = inner.session.view(now);
        json!({
            "on": view.on,
            "unreadable": view.unreadable,
            "shown": view.shown.as_ref().map(Self::track_json),
            "loaded": view.loaded.as_ref().map(Self::track_json),
            "remembered": view.remembered.as_ref().map(|r| json!({
                "track": Self::track_json(&r.track),
                "endedAt": r.ended_at,
            })),
            "volume": Self::volume_json(inner),
            // The surface moves the position on from `elapsedAt` by its own clock.
            "serverNow": now.timestamp_millis(),
        })
    }

    fn track_json(track: &NowPlaying) -> Value {
        let mut value = serde_json::to_value(track).unwrap_or(Value::Null);
        if let Some(object) = value.as_object_mut() {
            // The source keeps the cover's id where the bytes would be.
            object.remove("artwork");
            if let Some(id) = track.artwork.as_ref().and_then(|b| std::str::from_utf8(b).ok()) {
                object.insert("artworkId".into(), json!(id));
            }
        }
        value
    }

    fn volume_json(inner: &Inner) -> Value {
        match inner.volume.as_ref().and_then(SystemVolume::speaker) {
            Some(speaker) => json!({
                "level": speaker.level,
                "isMuted": speaker.is_muted,
                "shownLevel": speaker.shown_level(),
                "icon": speaker.icon(),
            }),
            None => Value::Null,
        }
    }

    fn command(&self, command: MusicCommand) -> Result<Value, String> {
        let inner = self.inner.lock().unwrap();
        // Controls work only while reading works.
        if !inner.session.is_on() || inner.session.view((self.context.clock)()).unreadable {
            return Err("the Music Module is not reading".into());
        }
        if let Some(source) = inner.source.as_ref() {
            source.send(command);
        }
        Ok(Value::Null)
    }

    fn with_volume<R>(self: &Arc<Self>, f: impl FnOnce(&mut SystemVolume<BoxedOutput>) -> R) -> Option<R> {
        let needs_output = {
            let inner = self.inner.lock().unwrap();
            if !inner.session.is_on() {
                return None;
            }
            inner.volume.is_none()
        };
        // Finding the output asks the audio system: not under the lock.
        let output = needs_output.then(|| {
            let weak = Arc::downgrade(self);
            let on_change: Arc<dyn Fn() + Send + Sync> = Arc::new(move || {
                if let Some(module) = weak.upgrade() {
                    module.volume_changed();
                }
            });
            self.parts.output(on_change)
        });
        let mut inner = self.inner.lock().unwrap();
        if !inner.session.is_on() {
            return None;
        }
        if let (None, Some(output)) = (inner.volume.as_ref(), output) {
            inner.volume = Some(SystemVolume::new(BoxedOutput(output)));
        }
        inner.volume.as_mut().map(f)
    }
}

/// The state without the moment it was rendered at.
fn timeless(mut state: Value) -> Value {
    if let Some(object) = state.as_object_mut() {
        object.remove("serverNow");
    }
    state
}

/// The longest the pump waits for an event before it looks again (the source
/// retried, the Module switched off).
const PUMP_WAIT: Duration = Duration::from_millis(500);

/// How long the pump may wait: until the view next changes by itself — a pause
/// that has lingered its ten seconds, a track held for its grace — if that is sooner.
fn pump_wait(module: &MusicModule) -> Duration {
    let now = (module.context.clock)();
    let next = module.inner.lock().unwrap().session.next_change(now);
    next.and_then(|at| (at - now).to_std().ok())
        // A millisecond past it, so the view has changed when it is read.
        .map_or(PUMP_WAIT, |left| (left + Duration::from_millis(1)).min(PUMP_WAIT))
}

/// Carries a source's events into the session, and says when something the
/// surface shows changes, by an event or by itself at the moment it does: a
/// pause that has lingered its ten seconds, a track held for its grace.
fn pump(module: Weak<MusicModule>, events: std::sync::mpsc::Receiver<MediaEvent>, alive: Arc<AtomicBool>) {
    let mut wait = PUMP_WAIT;
    while alive.load(Ordering::Relaxed) {
        let event = match events.recv_timeout(wait) {
            Ok(event) => Some(event),
            Err(RecvTimeoutError::Timeout) => None,
            Err(RecvTimeoutError::Disconnected) => break,
        };
        let Some(module) = module.upgrade() else { break };
        if !alive.load(Ordering::Relaxed) {
            break;
        }
        if let Some(event) = event {
            if module.apply(event) {
                module.read_volume();
            }
        }
        module.tell_if_changed();
        module.retry_if_unreadable();
        wait = pump_wait(&module);
    }
}

impl SurfaceModule for MusicModule {
    fn id(&self) -> &'static str {
        "music"
    }

    fn state(&self) -> Value {
        Self::state_of(&self.inner.lock().unwrap(), (self.context.clock)())
    }

    fn page(&self) -> Option<SurfacePage> {
        self.inner.lock().unwrap().session.is_on().then_some(SurfacePage::Music)
    }

    fn preferences_changed(&self) {
        if let Some(me) = self.upgrade() {
            me.follow_preference();
        }
    }

    /// `AppDelegate.diagnosticReport`: on, and the system will not say what plays.
    fn observations(&self) -> Vec<String> {
        let inner = self.inner.lock().unwrap();
        let unreadable = inner.session.view((self.context.clock)()).unreadable;
        if inner.session.is_on() && unreadable {
            vec![UNREADABLE_CODE.to_owned()]
        } else {
            Vec::new()
        }
    }

    fn call(&self, method: &str, args: Value) -> BoxFuture<Result<Value, String>> {
        let me = self.upgrade();
        let method = method.to_owned();
        Box::pin(async move {
            let me = me.ok_or("the Music Module is gone")?;
            match method.as_str() {
                "command" => {
                    let command: MusicCommand = serde_json::from_value(args).map_err(|e| e.to_string())?;
                    me.command(command)
                }
                // A volume bar appeared or went; the audio system is asked about
                // only while one is on screen.
                "volume.watch" => {
                    let on = args.get("on").and_then(Value::as_bool).unwrap_or(false);
                    tokio::task::spawn_blocking({
                        let me = me.clone();
                        move || {
                            me.with_volume(|v| if on { v.start_watching() } else { v.stop_watching() });
                            me.tell_if_changed();
                        }
                    })
                    .await
                    .map_err(|e| e.to_string())?;
                    Ok(Value::Null)
                }
                "volume.setLevel" => {
                    let level = args.get("level").and_then(Value::as_f64).ok_or("no level")?;
                    tokio::task::spawn_blocking(move || {
                        me.with_volume(|v| v.set_level(level));
                        me.tell_if_changed();
                    })
                    .await
                    .map_err(|e| e.to_string())?;
                    Ok(Value::Null)
                }
                "volume.toggleMute" => {
                    tokio::task::spawn_blocking(move || {
                        me.with_volume(|v| v.toggle_mute());
                        me.tell_if_changed();
                    })
                    .await
                    .map_err(|e| e.to_string())?;
                    Ok(Value::Null)
                }
                // A cover, as a small PNG: `{png: base64}`, or null for one not kept.
                "artwork" => {
                    let id = args.get("id").and_then(Value::as_str).ok_or("no id")?;
                    Ok(me.artwork.get(id).map_or(Value::Null, |png| json!({ "png": artwork::base64(&png) })))
                }
                other => Err(format!("music has no command {other}")),
            }
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use capa_core::music::NowPlayingReading;
    use capa_core::prefs::{MemoryStore, Preferences};
    use chrono::{DateTime, Duration as Span, TimeZone, Utc};
    use std::sync::atomic::AtomicUsize;
    use std::sync::mpsc::Sender;

    #[derive(Default)]
    struct Shared {
        events: Mutex<Option<Sender<MediaEvent>>>,
        sent: Mutex<Vec<MusicCommand>>,
        starts: AtomicUsize,
        stops: AtomicUsize,
        listening: AtomicUsize,
        stopped_listening: AtomicUsize,
        level: Mutex<f64>,
        muted: Mutex<bool>,
        on_change: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
        device_changed: AtomicBool,
    }

    struct FakeSource(Arc<Shared>);
    impl MediaSource for FakeSource {
        fn start(&mut self, events: Sender<MediaEvent>) {
            self.0.starts.fetch_add(1, Ordering::SeqCst);
            *self.0.events.lock().unwrap() = Some(events);
        }
        fn stop(&mut self) {
            self.0.stops.fetch_add(1, Ordering::SeqCst);
            *self.0.events.lock().unwrap() = None;
        }
        fn send(&self, command: MusicCommand) {
            self.0.sent.lock().unwrap().push(command);
        }
    }

    struct FakeOutput(Arc<Shared>);
    impl AudioOutput for FakeOutput {
        fn level_settable(&self) -> bool { true }
        fn read_level(&self) -> f64 { *self.0.level.lock().unwrap() }
        fn mute_settable(&self) -> bool { true }
        fn read_muted(&self) -> bool { *self.0.muted.lock().unwrap() }
        fn write_level(&mut self, level: f64) { *self.0.level.lock().unwrap() = level; }
        fn write_muted(&mut self, muted: bool) { *self.0.muted.lock().unwrap() = muted; }
        fn start_listening(&mut self) { self.0.listening.fetch_add(1, Ordering::SeqCst); }
        fn stop_listening(&mut self) { self.0.stopped_listening.fetch_add(1, Ordering::SeqCst); }
        fn take_device_changed(&mut self) -> bool { self.0.device_changed.swap(false, Ordering::SeqCst) }
    }

    struct FakeParts(Arc<Shared>);
    impl Parts for FakeParts {
        fn source(&self, _: Arc<ArtworkStore>) -> Box<dyn MediaSource> {
            Box::new(FakeSource(self.0.clone()))
        }
        fn output(&self, on_change: Arc<dyn Fn() + Send + Sync>) -> Box<dyn AudioOutput + Send> {
            *self.0.on_change.lock().unwrap() = Some(on_change);
            Box::new(FakeOutput(self.0.clone()))
        }
    }

    struct Rig {
        module: Arc<MusicModule>,
        shared: Arc<Shared>,
        prefs: Arc<Preferences>,
        notified: Arc<AtomicUsize>,
        clock: Arc<Mutex<DateTime<Utc>>>,
    }

    fn t0() -> DateTime<Utc> {
        Utc.timestamp_opt(1_800_000_000, 0).unwrap()
    }

    fn rig(enabled: bool) -> Rig {
        let prefs = Arc::new(Preferences::new(Arc::new(MemoryStore::new())));
        prefs.set_music_enabled(enabled);
        let shared = Arc::new(Shared::default());
        *shared.level.lock().unwrap() = 0.5;
        let notified = Arc::new(AtomicUsize::new(0));
        let clock = Arc::new(Mutex::new(t0()));
        let (n, c) = (notified.clone(), clock.clone());
        let context = ModuleContext {
            prefs: prefs.clone(),
            clock: Arc::new(move || *c.lock().unwrap()),
            prefs_changed: Arc::new(|| {}),
            notify: Arc::new(move || {
                n.fetch_add(1, Ordering::SeqCst);
            }),
            emit: Arc::new(|_, _, _| {}),
            sound: Arc::new(|_| {}),
        };
        let module = MusicModule::with_parts(context, Arc::new(FakeParts(shared.clone())));
        Rig { module, shared, prefs, notified, clock }
    }

    fn eventually(what: &str, mut condition: impl FnMut() -> bool) {
        for _ in 0..200 {
            if condition() {
                return;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        panic!("never: {what}");
    }

    fn playing(title: &str) -> NowPlayingReading {
        let mut track = NowPlaying::new(title, Some("annushkaa"), Some("yandex-music"), true);
        track.duration = Some(224.0);
        track.elapsed = Some(46.0);
        track.elapsed_at = Some(t0());
        track.rate = Some(1.0);
        track.artwork = Some(b"0123456789abcdef".to_vec());
        NowPlayingReading::Item(track)
    }

    fn say(rig: &Rig, event: MediaEvent) {
        rig.shared.events.lock().unwrap().as_ref().expect("a source is running").send(event).unwrap();
    }

    #[tokio::test]
    async fn off_it_runs_nothing_has_no_page_and_says_so() {
        let r = rig(false);
        assert_eq!(r.shared.starts.load(Ordering::SeqCst), 0, "no source was started");
        assert_eq!(r.module.page(), None);
        let state = r.module.state();
        assert_eq!(state["on"], false);
        assert!(state["shown"].is_null() && state["loaded"].is_null() && state["volume"].is_null());
    }

    #[tokio::test]
    async fn on_it_reads_and_the_page_stands() {
        let r = rig(true);
        assert_eq!(r.shared.starts.load(Ordering::SeqCst), 1);
        assert_eq!(r.module.page(), Some(SurfacePage::Music), "the page stands whether or not anything plays");
        assert!(r.module.state()["loaded"].is_null());

        say(&r, MediaEvent::Reading { reading: playing("Zima") });
        eventually("the track is shown", || !r.module.state()["shown"].is_null());
        let state = r.module.state();
        assert_eq!(state["shown"]["title"], "Zima");
        assert_eq!(state["loaded"]["artist"], "annushkaa");
        assert_eq!(state["shown"]["artworkId"], "0123456789abcdef", "the cover is its id, never its bytes");
        assert!(state["shown"].get("artwork").is_none());
        assert_eq!(state["serverNow"], t0().timestamp_millis());
        assert!(r.notified.load(Ordering::SeqCst) >= 1, "the hub was told");
    }

    #[tokio::test]
    async fn switching_it_off_stops_the_source_and_forgets() {
        let r = rig(true);
        say(&r, MediaEvent::Reading { reading: playing("Zima") });
        eventually("shown", || !r.module.state()["shown"].is_null());

        r.prefs.set_music_enabled(false);
        r.module.preferences_changed();
        assert_eq!(r.shared.stops.load(Ordering::SeqCst), 1);
        assert_eq!(r.module.page(), None);
        let state = r.module.state();
        assert!(state["shown"].is_null() && state["remembered"].is_null(), "off, it holds nothing");

        r.prefs.set_music_enabled(true);
        r.module.preferences_changed();
        assert_eq!(r.shared.starts.load(Ordering::SeqCst), 2, "and on again starts a new one");
    }

    #[tokio::test]
    async fn controls_reach_the_source_only_while_it_reads() {
        let r = rig(true);
        let sent = |r: &Rig| r.shared.sent.lock().unwrap().clone();
        r.module.call("command", json!({"command": "next"})).await.unwrap();
        r.module.call("command", json!({"command": "seek", "to": 12.5})).await.unwrap();
        assert_eq!(sent(&r), [MusicCommand::Next, MusicCommand::Seek { to: 12.5 }]);

        say(&r, MediaEvent::Unreadable { unreadable: true });
        eventually("unreadable", || r.module.state()["unreadable"] == true);
        assert!(r.module.call("command", json!({"command": "previous"})).await.is_err());
        assert_eq!(sent(&r).len(), 2);
        assert!(r.module.call("command", json!({"command": "nonsense"})).await.is_err());
        assert!(r.module.call("whatever", Value::Null).await.is_err());
    }

    #[tokio::test]
    async fn a_pause_lingers_ten_seconds_and_the_end_of_it_is_told() {
        let r = rig(true);
        say(&r, MediaEvent::Reading { reading: playing("Zima") });
        eventually("playing", || !r.module.state()["shown"].is_null());
        let mut paused = playing("Zima");
        if let NowPlayingReading::Item(t) = &mut paused {
            t.is_playing = false;
        }
        say(&r, MediaEvent::Reading { reading: paused });
        eventually("paused", || r.module.state()["shown"]["isPlaying"] == false);

        let before = r.notified.load(Ordering::SeqCst);
        *r.clock.lock().unwrap() = t0() + Span::seconds(11);
        eventually("the row goes", || r.module.state()["shown"].is_null());
        eventually("and the surface is told", || r.notified.load(Ordering::SeqCst) > before);
        assert!(!r.module.state()["loaded"].is_null(), "though the page keeps the track");
    }

    #[tokio::test]
    async fn a_reading_that_repeats_the_last_tells_nothing() {
        let r = rig(true);
        say(&r, MediaEvent::Reading { reading: playing("Zima") });
        eventually("told", || r.notified.load(Ordering::SeqCst) == 1);
        say(&r, MediaEvent::Reading { reading: playing("Zima") });
        *r.clock.lock().unwrap() = t0() + Span::seconds(3);
        std::thread::sleep(Duration::from_millis(1200));
        assert_eq!(r.notified.load(Ordering::SeqCst), 1, "the same track, later: nothing the surface draws changed");
        say(&r, MediaEvent::Reading { reading: playing("Kometa") });
        eventually("a new track is told", || r.notified.load(Ordering::SeqCst) == 2);
    }

    #[tokio::test]
    async fn a_lingering_pause_tells_only_the_pause_and_the_row_going() {
        let r = rig(true);
        say(&r, MediaEvent::Reading { reading: playing("Zima") });
        eventually("playing", || !r.module.state()["shown"].is_null());
        let mut paused = playing("Zima");
        if let NowPlayingReading::Item(t) = &mut paused {
            t.is_playing = false;
        }
        say(&r, MediaEvent::Reading { reading: paused });
        eventually("paused", || r.module.state()["shown"]["isPlaying"] == false);
        eventually("the pause is told", || r.notified.load(Ordering::SeqCst) == 2);

        // The linger: the pump looks again, and has nothing to tell.
        for second in [2, 5, 9] {
            *r.clock.lock().unwrap() = t0() + Span::seconds(second);
            std::thread::sleep(Duration::from_millis(600));
        }
        assert_eq!(r.notified.load(Ordering::SeqCst), 2, "nothing while the paused row stays as it is");

        *r.clock.lock().unwrap() = t0() + Span::seconds(11);
        eventually("the row goes", || r.module.state()["shown"].is_null());
        eventually("and that is told", || r.notified.load(Ordering::SeqCst) == 3);
        std::thread::sleep(Duration::from_millis(1100));
        assert_eq!(r.notified.load(Ordering::SeqCst), 3, "once");
    }

    #[tokio::test]
    async fn the_pump_looks_again_the_moment_the_row_goes() {
        let r = rig(true);
        say(&r, MediaEvent::Reading { reading: playing("Zima") });
        eventually("playing", || !r.module.state()["shown"].is_null());
        assert_eq!(pump_wait(&r.module), PUMP_WAIT, "playing, nothing is timed");
        let mut paused = playing("Zima");
        if let NowPlayingReading::Item(t) = &mut paused {
            t.is_playing = false;
        }
        say(&r, MediaEvent::Reading { reading: paused });
        eventually("paused", || r.module.state()["shown"]["isPlaying"] == false);
        *r.clock.lock().unwrap() = t0() + Span::milliseconds(9_800);
        assert_eq!(pump_wait(&r.module), Duration::from_millis(201), "the ten seconds from the pause, and a millisecond");
        *r.clock.lock().unwrap() = t0() + Span::seconds(10);
        assert_eq!(pump_wait(&r.module), PUMP_WAIT, "gone: nothing more is timed");
        assert!(r.module.state()["shown"].is_null());
    }

    #[tokio::test]
    async fn the_volume_bar_listens_only_while_a_bar_is_on_screen() {
        let r = rig(true);
        let listening = |r: &Rig| (r.shared.listening.load(Ordering::SeqCst), r.shared.stopped_listening.load(Ordering::SeqCst));
        assert_eq!(listening(&r), (0, 0), "nothing is asked of the audio system until a bar appears");
        assert!(r.module.state()["volume"].is_null());

        r.module.call("volume.watch", json!({"on": true})).await.unwrap();
        assert_eq!(listening(&r), (1, 0));
        let volume = r.module.state()["volume"].clone();
        assert_eq!(volume["level"], 0.5);
        assert_eq!(volume["icon"], "wave2");

        r.module.call("volume.setLevel", json!({"level": 0.25})).await.unwrap();
        assert_eq!(*r.shared.level.lock().unwrap(), 0.25);
        assert_eq!(r.module.state()["volume"]["icon"], "wave1");

        r.module.call("volume.toggleMute", Value::Null).await.unwrap();
        assert_eq!(r.module.state()["volume"]["shownLevel"], 0.0, "muted reads as silent");
        r.module.call("volume.setLevel", json!({"level": 0.4})).await.unwrap();
        assert!(!*r.shared.muted.lock().unwrap(), "dragging up from silence brings the sound back");

        // The device changing under the bar is followed.
        *r.shared.level.lock().unwrap() = 0.9;
        let on_change = r.shared.on_change.lock().unwrap().clone().unwrap();
        on_change();
        assert_eq!(r.module.state()["volume"]["level"], 0.9);

        r.module.call("volume.watch", json!({"on": false})).await.unwrap();
        assert_eq!(listening(&r), (1, 1));
    }

    #[tokio::test]
    async fn a_track_loading_reads_the_level_once_without_listening() {
        let r = rig(true);
        assert!(r.module.state()["volume"].is_null(), "nothing is read while nothing is loaded");
        say(&r, MediaEvent::Reading { reading: playing("Zima") });
        eventually("the level is read", || !r.module.state()["volume"].is_null());
        assert_eq!(r.module.state()["volume"]["level"], 0.5, "the first open already has it");
        assert_eq!(r.shared.listening.load(Ordering::SeqCst), 0, "nothing is listened to");

        // Another track looks again; the same one does not.
        *r.shared.level.lock().unwrap() = 0.3;
        say(&r, MediaEvent::Reading { reading: playing("Zima") });
        std::thread::sleep(Duration::from_millis(100));
        assert_eq!(r.module.state()["volume"]["level"], 0.5);
        say(&r, MediaEvent::Reading { reading: playing("Kometa") });
        eventually("read again", || r.module.state()["volume"]["level"] == 0.3);

        // While a bar listens, what it hears is left alone.
        r.module.call("volume.watch", json!({"on": true})).await.unwrap();
        *r.shared.level.lock().unwrap() = 0.8;
        say(&r, MediaEvent::Reading { reading: playing("Zima") });
        eventually("Zima", || r.module.state()["loaded"]["title"] == "Zima");
        std::thread::sleep(Duration::from_millis(100));
        assert_eq!(r.module.state()["volume"]["level"], 0.3);
        assert_eq!(r.shared.listening.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn switching_the_module_off_ends_the_volume_listening_too() {
        let r = rig(true);
        r.module.call("volume.watch", json!({"on": true})).await.unwrap();
        r.prefs.set_music_enabled(false);
        r.module.preferences_changed();
        assert_eq!(r.shared.stopped_listening.load(Ordering::SeqCst), 1);
        assert!(r.module.state()["volume"].is_null());
        // A bar that appears with the Module off is not served.
        r.module.call("volume.watch", json!({"on": true})).await.unwrap();
        assert_eq!(r.shared.listening.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn a_new_output_device_is_followed() {
        let r = rig(true);
        r.module.call("volume.watch", json!({"on": true})).await.unwrap();
        *r.shared.level.lock().unwrap() = 0.2;
        r.shared.device_changed.store(true, Ordering::SeqCst);
        let on_change = r.shared.on_change.lock().unwrap().clone().unwrap();
        on_change();
        assert_eq!(r.module.state()["volume"]["level"], 0.2);
        assert!(!r.shared.device_changed.load(Ordering::SeqCst), "the change was taken");
    }

    #[tokio::test]
    async fn unreadable_is_tried_again_a_minute_later_and_reported() {
        let r = rig(true);
        assert!(r.module.observations().is_empty());
        say(&r, MediaEvent::Unreadable { unreadable: true });
        eventually("unreadable", || r.module.state()["unreadable"] == true);
        assert_eq!(r.module.observations(), ["music-unreadable"]);

        *r.clock.lock().unwrap() = t0() + Span::seconds(59);
        std::thread::sleep(Duration::from_millis(700));
        assert_eq!(r.shared.starts.load(Ordering::SeqCst), 1, "not before the minute");
        *r.clock.lock().unwrap() = t0() + Span::seconds(60);
        eventually("a new source", || r.shared.starts.load(Ordering::SeqCst) == 2);
        assert_eq!(r.shared.stops.load(Ordering::SeqCst), 1, "the old one stopped");

        // The new source reads: the Module recovers on its own, and stops retrying.
        say(&r, MediaEvent::Unreadable { unreadable: false });
        eventually("readable", || r.module.state()["unreadable"] == false);
        assert!(r.module.observations().is_empty());
        *r.clock.lock().unwrap() = t0() + Span::seconds(200);
        std::thread::sleep(Duration::from_millis(700));
        assert_eq!(r.shared.starts.load(Ordering::SeqCst), 2);

        r.prefs.set_music_enabled(false);
        r.module.preferences_changed();
        assert!(r.module.observations().is_empty(), "off, it says nothing");
    }

    #[tokio::test]
    async fn a_cover_is_fetched_by_its_id() {
        let r = rig(true);
        assert_eq!(r.module.call("artwork", json!({"id": "nope"})).await.unwrap(), Value::Null);
        let png = {
            let image = image::RgbaImage::from_pixel(8, 8, image::Rgba([1, 2, 3, 255]));
            let mut out = std::io::Cursor::new(Vec::new());
            image::DynamicImage::ImageRgba8(image).write_to(&mut out, image::ImageFormat::Png).unwrap();
            out.into_inner()
        };
        let id = r.module.artwork.put(&png).unwrap();
        let answer = r.module.call("artwork", json!({"id": id})).await.unwrap();
        assert!(answer["png"].as_str().unwrap().starts_with("iVBOR"), "a PNG, in base64");
    }
}
