//! The hub: Providers' services in, one state out. It keeps what each
//! Provider last said, decides which alerts are worth raising, remembers the
//! Capacity for the next start, and paces the reading of every Provider.

use capa_core::alerts::CapacityAlertDecider;
use capa_core::archive::CapacityArchive;
use capa_core::loc::{self, AppLanguage};
use capa_core::diagnostics::DiagnosticEvent;
use capa_core::module::{ModuleContext, SurfaceModule};
use capa_core::sound::SoundCue;
use capa_core::surface::DisplayDescriptor;
use capa_platform::diagnostics::DiagnosticLog;
use capa_platform::displays::{DisplayRegistry, DisplaysView};
use capa_platform::sound::Sounds;
use capa_core::prefs::{JsonFileStore, Preferences};
use capa_core::surface::{CompactWindowChoice, SurfacePage, SurfacePageOrder};
use capa_core::view::{ProviderView, StripView};
use capa_core::claude_bridge;
use capa_core::{CapacitySnapshot, ConnectionState, Provider, RefreshSchedule};
use capa_services::claude::{ClaudeService, FileSource, NewestSource, ThrottledSource, UsageCommandSource};
use capa_services::codex::CodexService;
use capa_services::opencode::OpenCodeService;
use capa_services::{system_clock, Clock};
use serde::Serialize;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock, Weak};
use std::time::Duration;
use tokio::sync::{broadcast, mpsc, Notify};

#[derive(Debug, Clone)]
pub enum Event {
    /// Something on the surface changed; the payload is the state as JSON.
    State(String),
    Alert(String),
    /// Something a Module wants surfaces to know that is not state: `(module, name, data JSON)`.
    Module(String, String, String),
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct StateView {
    providers: Vec<ProviderView>,
    connected: Vec<Provider>,
    expanded: bool,
    alerts_enabled: bool,
    alerts_silenced_for: Vec<Provider>,
    /// `en` or `ru`: the language in force, the system's already resolved.
    language: &'static str,
    /// The Russian table, English sentence to Russian; empty for English.
    dictionary: serde_json::Value,
    strip: StripView,
    compact_window: CompactWindowChoice,
    pages: Vec<SurfacePage>,
    /// Each Module's own state, under its id.
    modules: serde_json::Map<String, serde_json::Value>,
    shows_kapa: bool,
    plays_sounds: bool,
    /// `system`, `light` or `dark`: for what the surface draws in the system's colours (Dictation's popover).
    appearance: &'static str,
    /// Whether the surface may appear in screen recordings; off by default.
    screen_sharing_allowed: bool,
    /// The displays the surface host reported, and which holds the surface.
    displays: DisplaysView,
    now: i64,
}

/// The state without its clocks: the hub's `now` and each Module's
/// `serverNow` / `serverNowMs`, which only say when it was rendered. No surface
/// reads them; each keeps its own clock.
fn timeless(state: &serde_json::Value) -> serde_json::Value {
    let mut state = state.clone();
    if let Some(object) = state.as_object_mut() {
        object.remove("now");
        if let Some(modules) = object.get_mut("modules").and_then(serde_json::Value::as_object_mut) {
            for module in modules.values_mut().filter_map(serde_json::Value::as_object_mut) {
                module.remove("serverNow");
                module.remove("serverNowMs");
            }
        }
    }
    state
}

/// Words the Swift app wrote about the Mac, and what this system says instead,
/// put in where the words are shown: the sentence itself stays the Swift
/// one, so its key and its tests are unchanged. A Provider's own detail is
/// never translated, so the Russian frame around it reads right either way.
const SAID_ON_LINUX: &[(&str, &str)] = &[("runs in Terminal.", "runs in a terminal.")];

fn said_on_linux(text: &str) -> String {
    SAID_ON_LINUX.iter().fold(text.to_owned(), |text, (mac, here)| text.replace(mac, here))
}

/// A card's guidance and its spoken words, said for this system.
fn said_here(mut view: ProviderView) -> ProviderView {
    view.guidance = view.guidance.as_deref().map(said_on_linux);
    view.spoken = said_on_linux(&view.spoken);
    view
}

/// The closed strip's spoken words, which carry a Provider's guidance when it has no figure.
fn strip_said_here(mut strip: StripView) -> StripView {
    for side in [&mut strip.left, &mut strip.right].into_iter().flatten() {
        side.spoken = said_on_linux(&side.spoken);
    }
    strip
}

struct State {
    snapshots: Vec<CapacitySnapshot>,
    decider: CapacityAlertDecider,
    expanded: bool,
    /// Consecutive failures worth retrying, per Provider.
    failures: HashMap<Provider, u32>,
    /// What each Provider last said, so a Provider that was answering and
    /// stopped is told from one that never answered (ADR 0007).
    last_connection: HashMap<Provider, ConnectionState>,
}

/// The least time between two states sent out.
const MIN_PUBLISH_GAP: Duration = Duration::from_millis(40);

/// The longest a quitting waits on one Provider's service to let go.
const SHUTDOWN_DISCONNECT: Duration = Duration::from_secs(2);

/// How often `/usage` is asked. Capacity moves slowly and the question costs a
/// process, so it is asked far less often than the surface refreshes.
const USAGE_COMMAND_INTERVAL: Duration = Duration::from_secs(300);

/// What a bug report notes about the machine itself (`AppDelegate.diagnosticReport`):
/// where the status-line bridge writes, where the Providers' programs are
/// looked for, and whether CapaTheNotch starts at login. Behind a seam so a
/// test's report never looks at the real machine.
pub struct Machine {
    pub claude_bridge: PathBuf,
    pub home: PathBuf,
    pub launches_at_login: Box<dyn Fn() -> bool + Send + Sync>,
}

impl Machine {
    pub fn real(home: PathBuf) -> Self {
        Self {
            claude_bridge: claude_bridge::default_snapshot_path(&home),
            home,
            launches_at_login: Box::new(capa_platform::launch_at_login::is_enabled),
        }
    }

    fn observations(&self) -> Vec<String> {
        let mut notes = Vec::new();
        if let Some(bridge) = claude_bridge::observation(&self.claude_bridge) {
            notes.push(bridge.to_owned());
        }
        if capa_services::claude::locate(&self.home).is_none() {
            notes.push("claude-binary-not-found".into());
        }
        if capa_core::codex::locate(&self.home).is_none() {
            notes.push("codex-binary-not-found".into());
        }
        if !(self.launches_at_login)() {
            notes.push("launch-at-login-off".into());
        }
        notes
    }
}

/// The order a report lists the Modules' notes in, as `AppDelegate` writes them.
const REPORT_ORDER: [&str; 4] = ["music", "dictation", "teleprompter", "shelf"];

fn slot(provider: Provider) -> usize {
    Provider::ALL.iter().position(|p| *p == provider).unwrap_or(0)
}

pub struct Hub {
    state: Mutex<State>,
    prefs: Arc<Preferences>,
    modules: OnceLock<Vec<Arc<dyn SurfaceModule>>>,
    sounds: OnceLock<Arc<Sounds>>,
    log: OnceLock<DiagnosticLog>,
    machine: OnceLock<Machine>,
    displays: DisplayRegistry,
    archive: CapacityArchive,
    now: Clock,
    events: broadcast::Sender<Event>,
    /// When the state last went out, and whether it changed since while it was being held back:
    /// however busy the Modules are, surfaces are sent the state at most about twenty-five times a second.
    last_emit: Mutex<Option<std::time::Instant>>,
    held_back: AtomicBool,
    throttled: AtomicBool,
    /// The state last sent, without the clocks in it (`timeless`): one that is
    /// only later is not sent again.
    last_sent: Mutex<Option<serde_json::Value>>,
    /// Each Provider's reader, woken when it should look now: the Provider was
    /// switched on or off, or a person asked. `notify_one` keeps the wake for a
    /// reader that is busy reading, so none is missed.
    wake: [Notify; 3],
    /// A person asked for this Provider: OpenCode is read past its five-minute pace.
    forced: [AtomicBool; 3],
    /// Whether each Provider was to be read when last looked at, to tell a
    /// preference that switched one on or off from any other.
    readers_on: Mutex<HashMap<Provider, bool>>,
    /// Quitting: nothing is read, connected or remembered any more.
    shutting_down: AtomicBool,
    codex: CodexService,
    claude: ClaudeService,
    opencode: OpenCodeService,
}

impl Hub {
    /// Builds the hub with the real services and Modules, and the tasks that feed it.
    /// `config` is the directory the preferences live in.
    pub fn start(config: PathBuf, archive: CapacityArchive) -> Arc<Self> {
        let prefs = Arc::new(Preferences::new(Arc::new(JsonFileStore::open(config.join("preferences.json")))));
        migrate_settings_file(&config, &prefs);
        loc::set_current(prefs.language().into());

        let (tx, rx) = mpsc::unbounded_channel();
        let now = system_clock();
        let home = capa_core::dirs::home();
        // Two ways to the same windows. The bridge is free and structured but
        // only runs in a terminal; `/usage` costs a subprocess and works
        // wherever the person is. Whichever saw the windows last wins.
        let claude_source = NewestSource::new(
            vec![
                Box::new(FileSource::new(claude_bridge::default_snapshot_path(&home))),
                Box::new(ThrottledSource::new(
                    UsageCommandSource::new(home.clone(), now.clone()),
                    USAGE_COMMAND_INTERVAL,
                    Duration::from_secs(30),
                )),
            ],
            now.clone(),
        );
        // The App Server's own output is kept only while the person has asked
        // for it, read at the moment a connection is made: turning the log on
        // takes effect on the next reconnect.
        let codex_log = {
            let prefs = prefs.clone();
            Arc::new(move || {
                prefs.keeps_diagnostic_log().then(|| {
                    DiagnosticLog::new(DiagnosticLog::default_path(), Box::new(|| true)).prepare().map(|p| p.to_path_buf())
                })?
            })
        };
        let hub = Arc::new(Self::new(
            prefs,
            archive,
            now.clone(),
            CodexService::with_process_transport(tx.clone(), now.clone(), env!("CARGO_PKG_VERSION"), codex_log),
            ClaudeService::new(tx.clone(), now.clone(), Arc::new(claude_source)),
            OpenCodeService::with_http(tx, now),
        ));
        // The machine's own parts: sounds (drawn only if they are on) and the
        // log (written only if it is on). No update is looked for: "Check for
        // Updates…" opens the releases page, as on macOS.
        let sounds = Arc::new(Sounds::system(hub.prefs.clone()));
        sounds.prepare();
        let _ = hub.sounds.set(sounds);
        let _ = hub.machine.set(Machine::real(home));
        let prefs = hub.prefs.clone();
        let _ = hub.log.set(DiagnosticLog::new(DiagnosticLog::default_path(), Box::new(move || prefs.keeps_diagnostic_log())));
        // `capa_core::diagnostics::record` — the Modules' own lines — goes to the same log.
        let recorder = Arc::downgrade(&hub);
        capa_core::diagnostics::set_recorder(Arc::new(move |event| {
            if let Some(hub) = recorder.upgrade() {
                hub.record(event);
            }
        }));
        hub.record(&DiagnosticEvent::Launched { version: env!("CARGO_PKG_VERSION").into(), system: capa_platform::system_version() });
        hub.attach(crate::modules::all);
        // What the Modules say at launch — Dictation's state — after `launched`.
        for module in hub.modules() {
            for event in module.launch_events() {
                hub.record(&event);
            }
        }
        tokio::spawn(hub.clone().consume(rx));
        hub.throttled.store(true, Ordering::Relaxed);
        tokio::spawn(hub.clone().flush_held_back());
        tokio::spawn(hub.clone().tick());
        for provider in Provider::ALL {
            tokio::spawn(hub.clone().read_loop(provider));
        }
        hub
    }

    /// Gives the hub its Modules: `make` is handed what a Module needs and returns them.
    pub fn attach(self: &Arc<Self>, make: impl FnOnce(ModuleContext) -> Vec<Arc<dyn SurfaceModule>>) {
        let weak: Weak<Hub> = Arc::downgrade(self);
        // A Module's state changed: publish it. Nothing else follows from that.
        let notify = {
            let weak = weak.clone();
            Arc::new(move || {
                if let Some(hub) = weak.upgrade() {
                    let state = hub.state.lock().unwrap();
                    hub.publish(&state);
                }
            }) as Arc<dyn Fn() + Send + Sync>
        };
        // A preference was written: Modules read theirs again.
        let prefs_changed = {
            let weak = weak.clone();
            Arc::new(move || {
                if let Some(hub) = weak.upgrade() {
                    hub.preferences_or_state_changed();
                }
            }) as Arc<dyn Fn() + Send + Sync>
        };
        let emit = {
            let weak = weak.clone();
            Arc::new(move |module: &str, name: &str, data: serde_json::Value| {
                if let Some(hub) = weak.upgrade() {
                    let _ = hub.events.send(Event::Module(module.into(), name.into(), data.to_string()));
                }
            }) as Arc<dyn Fn(&str, &str, serde_json::Value) + Send + Sync>
        };
        let context = ModuleContext {
            prefs: self.prefs.clone(),
            clock: self.now.clone(),
            notify,
            prefs_changed,
            emit,
            sound: {
                let weak = weak.clone();
                Arc::new(move |cue| {
                    if let Some(hub) = weak.upgrade() {
                        hub.play(cue);
                    }
                })
            },
        };
        let _ = self.modules.set(make(context));
    }

    fn modules(&self) -> &[Arc<dyn SurfaceModule>] {
        self.modules.get().map_or(&[], Vec::as_slice)
    }

    /// A Module or a preference changed: Modules read their preferences again, and the state goes out.
    fn preferences_or_state_changed(&self) {
        for module in self.modules() {
            module.preferences_changed();
        }
        {
            let state = self.state.lock().unwrap();
            self.publish(&state);
        }
        // A Provider switched on or off — onboarding finishing included — is
        // looked at now; any other preference leaves the readers at their pace.
        self.wake_switched();
    }

    /// Whether a Provider is read: on, past onboarding — nothing is read
    /// before the person has chosen — and, for OpenCode, with consent to read
    /// its key (ADR 0001, amended).
    fn should_read(&self, provider: Provider) -> bool {
        self.prefs.connects_at_launch(provider)
            && !self.prefs.needs_onboarding()
            && (provider != Provider::OpenCode || self.prefs.open_code_consent_given())
    }

    /// Wakes the readers of the Providers switched on or off since last looked at.
    fn wake_switched(&self) {
        let mut on = self.readers_on.lock().unwrap();
        for provider in Provider::ALL {
            let now = self.should_read(provider);
            if on.insert(provider, now) != Some(now) {
                self.wake(provider);
            }
        }
    }

    fn wake(&self, provider: Provider) {
        self.wake[slot(provider)].notify_one();
    }

    pub fn preferences(&self) -> Arc<Preferences> {
        self.prefs.clone()
    }

    /// A command for a Module, from a surface.
    pub async fn call(&self, module: &str, method: &str, args: serde_json::Value) -> Result<serde_json::Value, String> {
        if module == "hub" {
            return self.call_hub(method, args).await;
        }
        let module = self.modules().iter().find(|m| m.id() == module).cloned().ok_or_else(|| format!("no module {module}"))?;
        module.call(method, args).await
    }

    /// The hub's own commands: what only it knows (what the Providers have said).
    async fn call_hub(&self, method: &str, args: serde_json::Value) -> Result<serde_json::Value, String> {
        match method {
            "diagnosticReport" => Ok(serde_json::Value::String(self.diagnostic_report())),
            // A person asked to read again: one Provider (`{provider}`, a card's
            // refresh), or every one (the menu's Refresh Now).
            "refresh" => {
                match args.get("provider").filter(|p| !p.is_null()) {
                    Some(provider) => {
                        let provider: Provider =
                            serde_json::from_value(provider.clone()).map_err(|_| format!("no provider {provider}"))?;
                        self.refresh_provider(provider).await;
                    }
                    None => self.refresh_now(),
                }
                Ok(serde_json::Value::Null)
            }
            other => Err(format!("hub has no command {other}")),
        }
    }

    pub fn new(
        prefs: Arc<Preferences>,
        archive: CapacityArchive,
        now: Clock,
        codex: CodexService,
        claude: ClaudeService,
        opencode: OpenCodeService,
    ) -> Self {
        let remembered = archive.load();
        let snapshots = Provider::ALL
            .into_iter()
            .map(|p| {
                // What a restart opens on: the Capacity last seen, for a
                // Provider that will be read again. The rest are switched off.
                remembered
                    .iter()
                    .find(|s| s.provider == p && prefs.connects_at_launch(p))
                    .cloned()
                    .unwrap_or_else(|| CapacitySnapshot::disconnected(p, now(), p.switched_off_reason()))
            })
            .collect();
        let (events, _) = broadcast::channel(64);

        let hub = Self {
            state: Mutex::new(State {
                snapshots,
                decider: CapacityAlertDecider::new(),
                expanded: false,
                failures: HashMap::new(),
                last_connection: HashMap::new(),
            }),
            prefs,
            modules: OnceLock::new(),
            sounds: OnceLock::new(),
            log: OnceLock::new(),
            machine: OnceLock::new(),
            displays: DisplayRegistry::new(),
            archive,
            now,
            events,
            last_emit: Mutex::new(None),
            held_back: AtomicBool::new(false),
            throttled: AtomicBool::new(false),
            last_sent: Mutex::new(None),
            wake: [Notify::new(), Notify::new(), Notify::new()],
            forced: [AtomicBool::new(false), AtomicBool::new(false), AtomicBool::new(false)],
            readers_on: Mutex::new(HashMap::new()),
            shutting_down: AtomicBool::new(false),
            codex,
            claude,
            opencode,
        };
        // Where the readers start from: a later preference that changes none of
        // this wakes none of them.
        *hub.readers_on.lock().unwrap() = Provider::ALL.into_iter().map(|p| (p, hub.should_read(p))).collect();
        hub
    }

    /// The Providers that are on, in surface order.
    pub fn connected(&self) -> Vec<Provider> {
        self.prefs.connected_providers()
    }

    pub fn alerts_enabled(&self) -> bool {
        self.prefs.alerts_enabled()
    }

    pub fn subscribe(&self) -> broadcast::Receiver<Event> {
        self.events.subscribe()
    }

    pub fn state_json(&self) -> String {
        let state = self.state.lock().unwrap();
        self.render(&state)
    }

    fn language(&self) -> AppLanguage {
        AppLanguage::from(self.prefs.language()).resolved()
    }

    fn render(&self, state: &State) -> String {
        self.render_value(state).to_string()
    }

    fn render_value(&self, state: &State) -> serde_json::Value {
        let now = (self.now)();
        let language = self.language();
        // What a screen reader says is worded in the language in force, which
        // is the hub's: kept to the choice however it was written.
        if loc::current() != language {
            loc::set_current(language);
        }
        let compact_window: CompactWindowChoice = self.prefs.compact_window().into();
        let has = |page: SurfacePage| self.modules().iter().any(|m| m.page() == Some(page));
        let modules = self.modules().iter().map(|m| (m.id().to_owned(), m.state())).collect();
        serde_json::to_value(&StateView {
            providers: state.snapshots.iter().map(|s| said_here(ProviderView::localized(s, now, language).with_speech(s, now))).collect(),
            language: if language == AppLanguage::Russian { "ru" } else { "en" },
            dictionary: serde_json::from_str(&loc::dictionary_json(language)).unwrap_or_default(),
            strip: strip_said_here(StripView::of(&state.snapshots, compact_window)),
            compact_window,
            pages: SurfacePageOrder::pages(has(SurfacePage::Music), has(SurfacePage::Teleprompter), has(SurfacePage::Shelf)),
            modules,
            shows_kapa: self.prefs.shows_kapa(),
            plays_sounds: self.prefs.plays_sounds(),
            appearance: self.prefs.appearance().raw(),
            screen_sharing_allowed: self.prefs.screen_sharing_allowed(),
            displays: self.displays.view(self.prefs.preferred_display_id()),
            connected: self.prefs.connected_providers(),
            expanded: state.expanded,
            alerts_enabled: self.prefs.alerts_enabled(),
            alerts_silenced_for: self.prefs.alerts_silenced_for(),
            now: now.timestamp(),
        })
        .unwrap_or_else(|_| serde_json::json!({}))
    }

    /// Sends the state to every surface — unless it went out a moment ago, in
    /// which case the latest is sent once the moment is over (`flush_held_back`),
    /// or nothing in it but the time has changed since it last went out.
    fn publish(&self, state: &State) {
        if self.throttled.load(Ordering::Relaxed) {
            let mut last = self.last_emit.lock().unwrap();
            if last.is_some_and(|at| at.elapsed() < MIN_PUBLISH_GAP) {
                self.held_back.store(true, Ordering::Relaxed);
                return;
            }
            if self.send_if_changed(state) {
                *last = Some(std::time::Instant::now());
            }
            return;
        }
        self.send_if_changed(state);
    }

    /// Sends the state unless it is the one last sent, only later: the clocks
    /// aside (`timeless`), what a surface or Settings draws is the same. Every
    /// countdown and "read … ago" is text the hub words, so a state whose words
    /// moved on is sent; the 30-second tick sends one only when they have.
    /// Whether it was sent.
    fn send_if_changed(&self, state: &State) -> bool {
        let value = self.render_value(state);
        let key = timeless(&value);
        let mut last = self.last_sent.lock().unwrap();
        if last.as_ref() == Some(&key) {
            return false;
        }
        *last = Some(key);
        let _ = self.events.send(Event::State(value.to_string()));
        true
    }

    async fn flush_held_back(self: Arc<Self>) {
        let mut interval = tokio::time::interval(MIN_PUBLISH_GAP + Duration::from_millis(10));
        loop {
            interval.tick().await;
            if self.held_back.swap(false, Ordering::Relaxed) {
                let state = self.state.lock().unwrap();
                if self.send_if_changed(&state) {
                    *self.last_emit.lock().unwrap() = Some(std::time::Instant::now());
                }
            }
        }
    }

    /// Takes in what a service said.
    pub fn apply(&self, snapshot: CapacitySnapshot) {
        // Quitting: what the services say as they stop is not news.
        if self.shutting_down.load(Ordering::SeqCst) {
            return;
        }
        let mut state = self.state.lock().unwrap();
        let provider = snapshot.provider;

        // A service answers after it is switched off, now and then: the
        // switched-off card stands.
        let still_wanted = self.prefs.connects_at_launch(provider);
        if !still_wanted && !snapshot.is_switched_off() {
            return;
        }

        // Counts what just arrived, so the next wait knows whether this
        // Provider is answering. A Provider waiting on a person is not counted:
        // backing off does not help it.
        match &snapshot.connection_state {
            ConnectionState::Fresh => {
                state.failures.insert(provider, 0);
            }
            ConnectionState::Stale | ConnectionState::Disconnected(_) => {
                let transient = snapshot.status_reason.as_ref().is_some_and(|r| r.is_transient());
                let failures = state.failures.entry(provider).or_insert(0);
                *failures = if transient { failures.saturating_add(1) } else { 0 };
            }
            ConnectionState::Connecting | ConnectionState::Mock => {}
        }

        let snapshot_state = snapshot.connection_state.clone();
        let snapshot_reason = snapshot.status_reason.clone();
        let now = (self.now)();
        state.decider.language = self.language();
        let prefs = self.prefs.clone();
        let alerts = state.decider.alerts(&snapshot, now, |p| prefs.alerts_enabled_for(p));

        match state.snapshots.iter().position(|s| s.provider == provider) {
            Some(i) => state.snapshots[i] = snapshot,
            None => state.snapshots.push(snapshot),
        }
        // Kept current while a Provider is answering, and at quitting.
        if snapshot_state == ConnectionState::Fresh {
            self.archive.save(&state.snapshots);
        }

        // A Provider that was answering and stopped: once, on the change, and
        // not for a blip that is retried, nor one never connected this session —
        // that would sound at every launch (ADR 0007). Old numbers alone are
        // only time passing; a reason is a failure.
        let stopped = match &snapshot_state {
            ConnectionState::Disconnected(reason) => !reason.is_transient(),
            ConnectionState::Stale => snapshot_reason.as_ref().is_some_and(|r| !r.is_transient()),
            _ => false,
        };
        let was_answering = state.last_connection.get(&provider) == Some(&ConnectionState::Fresh);
        state.last_connection.insert(provider, snapshot_state);

        let recovered = !state.decider.recovered.is_empty();
        let mut sent = 0;
        for alert in alerts {
            if let Ok(json) = serde_json::to_string(&alert) {
                let _ = self.events.send(Event::Alert(json));
                sent += 1;
            }
        }
        self.publish(&state);
        drop(state);

        // The banner itself stays silent; the alert's sound is CapaTheNotch's
        // own, with every alert sent (`CapacityNotifications.send`). Played
        // once the state is let go, as the other cues are.
        for _ in 0..sent {
            self.play(SoundCue::CapacityAlert);
        }
        if recovered {
            self.play(SoundCue::CapacityRecovered);
        }
        if stopped && was_answering {
            self.play(SoundCue::ProviderStopped);
        }
    }

    async fn consume(self: Arc<Self>, mut rx: mpsc::UnboundedReceiver<CapacitySnapshot>) {
        while let Some(snapshot) = rx.recv().await {
            self.apply(snapshot);
        }
    }

    /// Countdowns are text, so they are redrawn as time passes: every thirty
    /// seconds, as the Swift surface's timeline does — sent when the words
    /// changed (`send_if_changed`).
    async fn tick(self: Arc<Self>) {
        let mut interval = tokio::time::interval(Duration::from_secs(30));
        interval.tick().await;
        loop {
            interval.tick().await;
            self.publish(&self.state.lock().unwrap());
        }
    }

    /// Reads every connected Provider at once, without waiting for its turn
    /// (`AppDelegate.refreshNow`): any run of failures is forgotten, and
    /// OpenCode is asked past its five-minute pace.
    pub fn refresh_now(&self) {
        self.state.lock().unwrap().failures.clear();
        self.forced[slot(Provider::OpenCode)].store(true, Ordering::SeqCst);
        for provider in Provider::ALL {
            self.wake(provider);
        }
    }

    /// Reads one Provider at once (`AppDelegate.refresh(_:)`). A Provider that
    /// is not connected cannot be read, and a button that silently does
    /// nothing is worse than no button: it is connected instead — Codex
    /// directly, Claude Code and OpenCode once their consent is given, and
    /// otherwise in Settings ▸ Providers, where it is asked for.
    pub async fn refresh_provider(&self, provider: Provider) {
        self.state.lock().unwrap().failures.insert(provider, 0);
        if self.should_read(provider) {
            if provider == Provider::OpenCode {
                // A person asked: answered at once, past the five-minute pace.
                self.forced[slot(provider)].store(true, Ordering::SeqCst);
            }
            self.wake(provider);
            return;
        }
        // Wherever it is asked from, a third Provider is not connected while two are on.
        if !self.prefs.can_connect(provider) {
            return;
        }
        let consented = match provider {
            Provider::Codex => true,
            Provider::ClaudeCode => self.prefs.claude_consent_given(),
            Provider::OpenCode => self.prefs.open_code_consent_given(),
        };
        if consented {
            self.set_provider_enabled(provider, true).await;
        } else {
            let _ = self.events.send(Event::Module("hub".into(), "openSettings".into(), r#"{"section":"providers"}"#.into()));
        }
    }

    pub fn set_expanded(&self, expanded: bool) {
        let mut state = self.state.lock().unwrap();
        if state.expanded == expanded {
            return;
        }
        // The new pace is taken at the next wait, as the Swift readers take it.
        state.expanded = expanded;
        self.publish(&state);
        drop(state);
        for module in self.modules() {
            module.presentation_changed(expanded);
        }
    }

    /// Turns a Provider on or off. Returns whether the choice was made: two
    /// at most, so a third is refused rather than quietly dropping another,
    /// and OpenCode never without the person's consent to read its key.
    pub async fn set_provider_enabled(&self, provider: Provider, enabled: bool) -> bool {
        if enabled && provider == Provider::OpenCode && !self.prefs.open_code_consent_given() {
            return false;
        }
        if !self.prefs.set_connects_at_launch(provider, enabled) {
            return false;
        }
        if !enabled {
            let mut state = self.state.lock().unwrap();
            state.decider.forget(provider);
            state.failures.remove(&provider);
        }
        if !enabled {
            self.disconnect(provider).await;
            self.leave_switched_off(provider);
        } else if self.should_read(provider) {
            self.connect(provider).await;
        }
        self.preferences_or_state_changed();
        true
    }

    /// A Provider switched off takes its last reading with it
    /// (`AppDelegate.disconnectCodex`): its card says it is off, the strip
    /// says "—", and the other Provider takes the width. Put in place
    /// directly, not through `apply`: switching off is no Provider stopping,
    /// and sounds nothing.
    fn leave_switched_off(&self, provider: Provider) {
        let snapshot = CapacitySnapshot::disconnected(provider, (self.now)(), provider.switched_off_reason());
        let mut state = self.state.lock().unwrap();
        state.last_connection.insert(provider, snapshot.connection_state.clone());
        match state.snapshots.iter().position(|s| s.provider == provider) {
            Some(i) => state.snapshots[i] = snapshot,
            None => state.snapshots.push(snapshot),
        }
        self.publish(&state);
    }

    /// Quits cleanly (`applicationWillTerminate`): the archive is written, the
    /// Modules stop, and every Provider's service lets go of what it started.
    /// Quitting remembers nothing else: a Provider on at quitting is on at the
    /// next launch.
    pub async fn shutdown(&self) {
        if self.shutting_down.swap(true, Ordering::SeqCst) {
            return;
        }
        {
            let state = self.state.lock().unwrap();
            self.archive.save(&state.snapshots);
        }
        for module in self.modules() {
            module.stop();
        }
        for provider in Provider::ALL {
            // A service that hangs does not keep the quitting waiting: what it
            // started ends with the daemon anyway (`kill_on_drop`).
            let _ = tokio::time::timeout(SHUTDOWN_DISCONNECT, self.disconnect(provider)).await;
            // Its reader sees the quitting and ends.
            self.wake(provider);
        }
    }

    pub fn set_language(&self, language: AppLanguage) {
        self.prefs.set_language(language.into());
        loc::set_current(language);
        self.preferences_or_state_changed();
    }

    pub fn set_compact_window(&self, choice: CompactWindowChoice) {
        self.prefs.set_compact_window(choice.into());
        self.preferences_or_state_changed();
    }

    pub fn set_alerts_enabled(&self, enabled: bool) {
        self.prefs.set_alerts_enabled(enabled);
        self.preferences_or_state_changed();
    }

    pub fn set_alerts_for(&self, provider: Provider, enabled: bool) {
        self.prefs.set_alerts_enabled_for(provider, enabled);
        self.preferences_or_state_changed();
    }

    /// Plays one of the app's sounds, if the person wants sounds and nothing
    /// wants quiet (the Teleprompter running).
    pub fn play(&self, cue: SoundCue) -> bool {
        let Some(sounds) = self.sounds.get() else { return false };
        sounds.set_quiet(self.modules().iter().any(|m| m.wants_quiet()));
        sounds.play(cue)
    }

    /// A surface asks for a sound by its name (`surfacePinned`, `kapaTapped`, ...).
    pub fn play_named(&self, cue: &str) -> bool {
        match serde_json::from_value::<SoundCue>(serde_json::Value::String(cue.to_owned())) {
            Ok(cue) => self.play(cue),
            Err(_) => false,
        }
    }

    /// The application's own line in the diagnostic log, if the log is on.
    pub fn record(&self, event: &DiagnosticEvent) {
        if let Some(log) = self.log.get() {
            log.record(event, (self.now)());
        }
    }

    /// The path of the diagnostic log (made if need be), where a Provider's own output may go.
    pub fn diagnostic_log_path(&self) -> Option<std::path::PathBuf> {
        self.log.get().and_then(|l| l.prepare().map(|p| p.to_path_buf()))
    }

    /// The text of a bug report: versions, each Provider's state, and the
    /// notes, in the Swift order — the machine's (the status-line bridge, the
    /// Providers' programs, launch at login), then each Module's.
    pub fn diagnostic_report(&self) -> String {
        let state = self.state.lock().unwrap();
        let snapshots: Vec<_> = state
            .snapshots
            .iter()
            .map(|s| (s.clone(), state.failures.get(&s.provider).copied().unwrap_or(0)))
            .collect();
        drop(state);
        let mut observations = self.machine.get().map(Machine::observations).unwrap_or_default();
        let mut modules: Vec<_> = self.modules().iter().collect();
        modules.sort_by_key(|m| REPORT_ORDER.iter().position(|id| *id == m.id()).unwrap_or(REPORT_ORDER.len()));
        observations.extend(modules.into_iter().flat_map(|m| m.observations()));
        capa_platform::diagnostics::report(env!("CARGO_PKG_VERSION"), &snapshots, observations, (self.now)())
    }

    /// The surface host says which displays there are now; the choice of the one that holds the surface is made again.
    pub fn set_displays(&self, displays: Vec<DisplayDescriptor>) {
        self.displays.set(displays);
        let state = self.state.lock().unwrap();
        self.publish(&state);
    }

    /// The display that holds the surface now, once the host has reported any.
    pub fn chosen_display_id(&self) -> Option<u32> {
        self.displays.chosen(self.prefs.preferred_display_id()).map(|d| d.id)
    }

    pub fn set_preferred_display(&self, id: Option<u32>) {
        self.prefs.set_preferred_display_id(id);
        self.preferences_or_state_changed();
    }

    pub async fn connect(&self, provider: Provider) {
        match provider {
            Provider::Codex => self.codex.connect().await,
            Provider::ClaudeCode => self.claude.connect().await,
            Provider::OpenCode => self.opencode.connect().await,
        }
    }

    async fn disconnect(&self, provider: Provider) {
        match provider {
            Provider::Codex => self.codex.disconnect().await,
            Provider::ClaudeCode => self.claude.disconnect().await,
            Provider::OpenCode => self.opencode.disconnect().await,
        }
    }

    async fn read(&self, provider: Provider) {
        match provider {
            Provider::Codex => {
                // Reconnects a Codex that went away; its first read is part of connecting.
                if self.codex.is_connected().await {
                    self.codex.refresh().await
                } else {
                    self.codex.connect().await
                }
            }
            Provider::ClaudeCode => self.claude.refresh().await,
            Provider::OpenCode => {
                let forced = self.forced[slot(provider)].swap(false, Ordering::SeqCst);
                self.opencode.refresh(forced).await
            }
        }
    }

    /// Reads one Provider at the pace the surface sets, for as long as it is on.
    async fn read_loop(self: Arc<Self>, provider: Provider) {
        let schedule = RefreshSchedule::STANDARD;
        let mut was_on = false;
        loop {
            if self.shutting_down.load(Ordering::SeqCst) {
                return;
            }
            let on = self.should_read(provider);
            if on && !was_on {
                // Connecting is the first read.
                self.connect(provider).await;
            } else if on {
                self.read(provider).await;
            } else {
                self.forced[slot(provider)].store(false, Ordering::SeqCst);
                if was_on {
                    // Switched off somewhere else (Settings writes the preference and nothing more):
                    // what it said is forgotten with it, and the process it started ends.
                    {
                        let mut state = self.state.lock().unwrap();
                        state.decider.forget(provider);
                        state.failures.remove(&provider);
                    }
                    self.disconnect(provider).await;
                    // Switched off by the person, its reading goes too; one only
                    // waiting (onboarding, OpenCode's consent) keeps its card.
                    if !self.prefs.connects_at_launch(provider) {
                        self.leave_switched_off(provider);
                    }
                }
            }
            was_on = on;

            // The surface's own pace, stretched by any run of failures worth
            // retrying — `RefreshSchedule.delay`, and nothing else, as in Swift.
            let wait = if on {
                let state = self.state.lock().unwrap();
                schedule.delay(state.expanded, state.failures.get(&provider).copied().unwrap_or(0))
            } else {
                schedule.while_compact
            };
            tokio::select! {
                _ = tokio::time::sleep(wait) => {}
                _ = self.wake[slot(provider)].notified() => {}
            }
        }
    }
}

/// A `settings.json` written before the preferences existed is taken as the person's choice, once.
fn migrate_settings_file(config: &std::path::Path, prefs: &Preferences) {
    let old = config.join("settings.json");
    let migrated = config.join("settings.json.migrated");
    if !old.exists() || migrated.exists() {
        return;
    }
    if let Some(json) = std::fs::read(&old).ok().and_then(|d| serde_json::from_slice(&d).ok()) {
        prefs.import_hub_json(&json);
    }
    let _ = std::fs::rename(&old, &migrated);
}

#[cfg(test)]
mod tests {
    use super::*;
    use capa_core::prefs::MemoryStore;
    use capa_core::claude::SourceError;
    use capa_core::{CapacityStatusReason, QuotaWindow};
    use capa_services::claude::CapacitySource;
    use chrono::{TimeZone, Utc};

    struct Nothing;
    impl CapacitySource for Nothing {
        fn read(&self) -> Result<capa_core::claude::ClaudeCapacityReading, SourceError> {
            Err(SourceError::Usage(capa_core::claude::UsageCommandError::ClaudeCodeNotInstalled))
        }
    }
    struct NoNetwork;
    impl capa_services::opencode::UsageClient for NoNetwork {
        fn usage(&self, _: &str) -> Result<(u16, Vec<u8>), capa_services::opencode::Unreachable> {
            Err(capa_services::opencode::Unreachable)
        }
    }

    fn hub(name: &str, connected: &[Provider]) -> Hub {
        hub_with_feed(name, connected).0
    }

    /// The hub, and what its services have said, for a test to carry across
    /// as `consume` does.
    fn hub_with_feed(name: &str, connected: &[Provider]) -> (Hub, mpsc::UnboundedReceiver<CapacitySnapshot>) {
        hub_at(name, connected, Arc::new(|| Utc.timestamp_opt(1_700_000_000, 0).unwrap()))
    }

    /// The hub on a clock the test moves.
    fn hub_at(name: &str, connected: &[Provider], now: Clock) -> (Hub, mpsc::UnboundedReceiver<CapacitySnapshot>) {
        let dir = std::env::temp_dir().join(format!("capa-hub-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let prefs = Arc::new(Preferences::new(Arc::new(MemoryStore::new())));
        // The tests read English whatever the machine speaks, and start with
        // exactly the Providers they name on.
        prefs.set_language(AppLanguage::English.into());
        prefs.set_alerts_enabled(true);
        // Past onboarding, with OpenCode's key allowed: what most tests are about.
        prefs.set_has_finished_onboarding(true);
        prefs.set_open_code_consent_given(true);
        for p in Provider::ALL {
            prefs.set_connects_at_launch(p, false);
        }
        for p in connected {
            prefs.set_connects_at_launch(*p, true);
        }

        let (tx, rx) = mpsc::unbounded_channel();
        let hub = Hub::new(
            prefs,
            CapacityArchive::new(dir.join("archive.json")),
            now.clone(),
            CodexService::new(tx.clone(), now.clone(), "0", Arc::new(|| Ok(None))),
            ClaudeService::new(tx.clone(), now.clone(), Arc::new(Nothing)),
            OpenCodeService::new(tx, now, Arc::new(|| None), Arc::new(NoNetwork)),
        );
        (hub, rx)
    }

    fn fresh(provider: Provider, used: f64) -> CapacitySnapshot {
        CapacitySnapshot {
            provider,
            captured_at: Utc.timestamp_opt(1_700_000_000, 0).unwrap(),
            windows: vec![QuotaWindow::new("w", "5 hour", Some(300), used, None)],
            connection_state: ConnectionState::Fresh,
            status_reason: None,
        }
    }

    fn state(hub: &Hub) -> serde_json::Value {
        serde_json::from_str(&hub.state_json()).unwrap()
    }

    #[test]
    fn it_starts_with_every_provider_switched_off() {
        let h = hub("off", &[]);
        let s = state(&h);
        assert_eq!(s["providers"].as_array().unwrap().len(), 3);
        assert!(s["providers"].as_array().unwrap().iter().all(|p| p["switchedOff"] == true));
        assert_eq!(s["connected"], serde_json::json!([]));
    }

    #[test]
    fn a_reading_replaces_the_providers_card_in_its_place() {
        let h = hub("apply", &[Provider::ClaudeCode]);
        h.apply(fresh(Provider::ClaudeCode, 0.24));
        let s = state(&h);
        assert_eq!(s["providers"][1]["provider"], "claudeCode");
        assert_eq!(s["providers"][1]["state"], "fresh");
        assert_eq!(s["providers"][1]["windows"][0]["remainingPercentage"], 76.0);
    }

    #[test]
    fn a_reading_from_a_provider_that_is_off_is_ignored() {
        let h = hub("ignored", &[]);
        h.apply(fresh(Provider::Codex, 0.1));
        assert_eq!(state(&h)["providers"][0]["switchedOff"], true);
    }

    #[test]
    fn a_critical_window_raises_one_alert_and_a_silenced_provider_none() {
        let h = hub("alert", &[Provider::Codex]);
        let mut events = h.subscribe();
        h.apply(fresh(Provider::Codex, 0.96));
        h.apply(fresh(Provider::Codex, 0.97));
        let mut alerts = 0;
        while let Ok(e) = events.try_recv() {
            if let Event::Alert(json) = e {
                alerts += 1;
                assert!(json.contains("Codex is running out"), "{json}");
            }
        }
        assert_eq!(alerts, 1);

        let h = hub("silenced", &[Provider::Codex]);
        h.set_alerts_for(Provider::Codex, false);
        let mut events = h.subscribe();
        h.apply(fresh(Provider::Codex, 0.96));
        assert!(std::iter::from_fn(|| events.try_recv().ok()).all(|e| !matches!(e, Event::Alert(_))));
    }

    #[test]
    fn only_transient_failures_count_toward_backing_off() {
        let h = hub("failures", &[Provider::OpenCode]);
        let failed = |reason| CapacitySnapshot::disconnected(Provider::OpenCode, Utc::now(), reason);
        h.apply(failed(CapacityStatusReason::OpenCodeUnreachable));
        h.apply(failed(CapacityStatusReason::OpenCodeUnreachable));
        assert_eq!(h.state.lock().unwrap().failures[&Provider::OpenCode], 2);
        h.apply(failed(CapacityStatusReason::OpenCodeKeyRefused));
        assert_eq!(h.state.lock().unwrap().failures[&Provider::OpenCode], 0, "waiting on a person is not backed off");
    }

    #[tokio::test]
    async fn turning_a_third_provider_on_is_refused() {
        let h = hub("limit", &[Provider::Codex, Provider::ClaudeCode]);
        assert!(!h.set_provider_enabled(Provider::OpenCode, true).await);
        assert_eq!(state(&h)["connected"], serde_json::json!(["codex", "claudeCode"]));
    }

    #[tokio::test]
    async fn turning_one_off_leaves_its_switched_off_card() {
        let (h, mut feed) = hub_with_feed("turnoff", &[Provider::ClaudeCode]);
        h.apply(fresh(Provider::ClaudeCode, 0.2));
        assert!(h.set_provider_enabled(Provider::ClaudeCode, false).await);
        while let Ok(said) = feed.try_recv() {
            h.apply(said);
        }
        let s = state(&h);
        assert_eq!(s["providers"][1]["switchedOff"], true);
        assert_eq!(s["connected"], serde_json::json!([]));
    }

    #[tokio::test]
    async fn turning_codex_off_takes_its_last_reading_off_the_surface_silently() {
        let (h, mut feed) = hub_with_feed("turnoff-codex", &[Provider::Codex, Provider::ClaudeCode]);
        let heard = listening(&h);
        h.apply(fresh(Provider::Codex, 0.2));
        h.apply(fresh(Provider::ClaudeCode, 0.3));
        assert!(h.set_provider_enabled(Provider::Codex, false).await);
        while let Ok(said) = feed.try_recv() {
            h.apply(said);
        }
        let s = state(&h);
        assert_eq!(s["providers"][0]["switchedOff"], true, "Codex's service says nothing as it stops: the hub puts the card");
        assert_eq!(s["providers"][0]["windows"], serde_json::json!([]));
        assert_eq!(s["strip"]["left"]["provider"], "claudeCode", "the other Provider takes the strip");
        assert!(s["strip"]["right"].is_null());
        assert!(heard.0.lock().unwrap().is_empty(), "switching off is not a Provider stopping");
    }

    #[tokio::test]
    async fn quitting_does_not_wait_on_a_hung_app_server() {
        let dir = std::env::temp_dir().join(format!("capa-hub-{}-hung", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let prefs = Arc::new(Preferences::new(Arc::new(MemoryStore::new())));
        let now: Clock = Arc::new(|| Utc.timestamp_opt(1_700_000_000, 0).unwrap());
        let (tx, _rx) = mpsc::unbounded_channel();
        // An App Server that takes every question and answers none.
        let server = Arc::new(Mutex::new(None));
        let held = server.clone();
        let hung: capa_services::codex::TransportFactory = Arc::new(move || {
            let (line, lines) = mpsc::unbounded_channel::<String>();
            *held.lock().unwrap() = Some(line);
            Ok(Some(capa_services::codex::Transport { lines, send: Box::new(|_| Ok(())), terminate: Box::new(|| {}) }))
        });
        let h = Arc::new(Hub::new(
            prefs,
            CapacityArchive::new(dir.join("archive.json")),
            now.clone(),
            CodexService::new(tx.clone(), now.clone(), "0", hung),
            ClaudeService::new(tx.clone(), now.clone(), Arc::new(Nothing)),
            OpenCodeService::new(tx, now, Arc::new(|| None), Arc::new(NoNetwork)),
        ));
        let connecting = tokio::spawn({
            let h = h.clone();
            async move { h.connect(Provider::Codex).await }
        });
        while server.lock().unwrap().is_none() {
            tokio::task::yield_now().await;
        }
        tokio::time::timeout(Duration::from_secs(3), h.shutdown()).await.expect("quitting is not held up");
        let _ = tokio::time::timeout(Duration::from_secs(1), connecting).await;
    }

    #[test]
    fn codex_failures_say_a_terminal_not_the_macs_terminal() {
        let h = hub("terminal", &[Provider::Codex]);
        let failed = |reason| CapacitySnapshot::disconnected(Provider::Codex, Utc::now(), reason);
        // Swift's sentence, as the service says it.
        h.apply(failed(CapacityStatusReason::ProviderUnavailable(
            "it stopped before answering. Check that `codex app-server` runs in Terminal.".into(),
        )));
        let s = state(&h);
        assert_eq!(
            s["providers"][0]["guidance"],
            "Codex is not answering — it stopped before answering. Check that `codex app-server` runs in a terminal."
        );
        assert!(!s["providers"][0]["spoken"].as_str().unwrap().contains("Terminal"));
        assert!(!s["strip"]["left"]["spoken"].as_str().unwrap().contains("Terminal"), "{}", s["strip"]);
        // In Russian the frame is the table's and the detail the Provider's, said the same way.
        let snapshot = h.state.lock().unwrap().snapshots[0].clone();
        let ru = said_here(ProviderView::localized(&snapshot, Utc::now(), AppLanguage::Russian));
        let guidance = ru.guidance.unwrap();
        assert!(guidance.starts_with("Codex не отвечает"), "{guidance}");
        assert!(guidance.ends_with("runs in a terminal."), "{guidance}");

        // The other sentence comes through the same way, untouched.
        h.apply(failed(CapacityStatusReason::ProviderIncompatible("the App Server did not start.".into())));
        assert_eq!(state(&h)["providers"][0]["guidance"], "Update the Codex CLI — the App Server did not start.");
    }

    #[test]
    fn the_failure_count_follows_what_each_state_says() {
        let h = hub("count", &[Provider::OpenCode]);
        let failures = |h: &Hub| h.state.lock().unwrap().failures.get(&Provider::OpenCode).copied();
        let unreachable = CapacitySnapshot::disconnected(Provider::OpenCode, Utc::now(), CapacityStatusReason::OpenCodeUnreachable);
        h.apply(unreachable.clone());
        let connecting = CapacitySnapshot { connection_state: ConnectionState::Connecting, status_reason: None, ..unreachable.clone() };
        h.apply(connecting);
        assert_eq!(failures(&h), Some(1), "connecting says nothing about failing");
        let stale = CapacitySnapshot { connection_state: ConnectionState::Stale, ..unreachable.clone() };
        h.apply(stale);
        assert_eq!(failures(&h), Some(2), "Stale for a reason worth retrying counts too");
        h.apply(fresh(Provider::OpenCode, 0.1));
        assert_eq!(failures(&h), Some(0));
    }

    #[test]
    fn the_archive_is_written_on_fresh_capacity_only() {
        let h = hub("archive-fresh", &[Provider::Codex]);
        let stale = CapacitySnapshot {
            connection_state: ConnectionState::Stale,
            status_reason: Some(CapacityStatusReason::ProviderCouldNotRead("x".into())),
            ..fresh(Provider::Codex, 0.3)
        };
        h.apply(stale);
        assert!(!h.archive.path.exists(), "a Stale reading is not news worth keeping");
        h.apply(fresh(Provider::Codex, 0.3));
        assert_eq!(h.archive.load().len(), 1);
    }

    #[test]
    fn alerts_silenced_for_names_only_the_providers_silenced_one_by_one() {
        let h = hub("silenced-list", &[Provider::Codex]);
        h.set_alerts_for(Provider::ClaudeCode, false);
        h.set_alerts_enabled(false);
        assert_eq!(state(&h)["alertsSilencedFor"], serde_json::json!(["claudeCode"]));
        assert!(state(&h).get("update").is_none(), "no update is looked for");
        assert_eq!(state(&h)["appearance"], "system");
    }

    #[test]
    fn the_state_carries_what_a_screen_reader_says() {
        let h = hub("spoken", &[Provider::Codex]);
        h.apply(fresh(Provider::Codex, 0.24));
        let s = state(&h);
        assert!(s["providers"][0]["spoken"].as_str().unwrap().starts_with("Codex. Fresh Capacity."));
        assert_eq!(s["providers"][0]["windows"][0]["usedPercentage"], 24);
        assert!(s["providers"][0]["windows"][0]["spoken"].as_str().unwrap().starts_with("5 hour window"));
        assert!(s["strip"]["left"]["spoken"].as_str().unwrap().starts_with("Codex, 5 hour window"));
    }

    /// Whether the reader of `provider` was woken (and takes the wake).
    async fn woken(h: &Hub, provider: Provider) -> bool {
        tokio::time::timeout(Duration::from_millis(20), h.wake[slot(provider)].notified()).await.is_ok()
    }

    #[tokio::test]
    async fn readers_wake_for_a_switch_or_a_refresh_and_nothing_else() {
        let h = hub("wakes", &[Provider::Codex]);
        h.set_expanded(true);
        h.set_compact_window(CompactWindowChoice::Weekly);
        for p in Provider::ALL {
            assert!(!woken(&h, p).await, "{p:?} woken by an unrelated change");
        }
        // Settings writes the preference, and says so.
        h.prefs.set_connects_at_launch(Provider::ClaudeCode, true);
        h.preferences_or_state_changed();
        assert!(woken(&h, Provider::ClaudeCode).await);
        assert!(!woken(&h, Provider::Codex).await);
        h.refresh_now();
        for p in Provider::ALL {
            assert!(woken(&h, p).await, "{p:?} not woken by Refresh Now");
        }
    }

    #[tokio::test]
    async fn a_wake_while_reading_is_kept_for_after() {
        let h = hub("kept", &[Provider::Codex]);
        // Nobody waits yet — the reader is busy reading — and the wake is not lost.
        h.refresh_now();
        assert!(woken(&h, Provider::Codex).await);
    }

    #[tokio::test]
    async fn refresh_now_forgets_failures_and_asks_opencode_past_its_pace() {
        let h = hub("refresh-now", &[Provider::OpenCode]);
        h.apply(CapacitySnapshot::disconnected(Provider::OpenCode, Utc::now(), CapacityStatusReason::OpenCodeUnreachable));
        h.refresh_now();
        assert!(h.state.lock().unwrap().failures.is_empty());
        assert!(h.forced[slot(Provider::OpenCode)].load(Ordering::SeqCst));
    }

    #[test]
    fn nothing_is_read_before_onboarding_and_opencode_never_without_consent() {
        let h = hub("onboarding", &[Provider::Codex, Provider::OpenCode]);
        assert!(h.should_read(Provider::Codex));
        h.prefs.set_open_code_consent_given(false);
        assert!(!h.should_read(Provider::OpenCode));

        // A first launch: nothing chosen, Codex on only by default.
        let (tx, _rx) = mpsc::unbounded_channel();
        let now: Clock = Arc::new(Utc::now);
        let dir = std::env::temp_dir().join(format!("capa-hub-{}-first-run", std::process::id()));
        let first = Hub::new(
            Arc::new(Preferences::new(Arc::new(MemoryStore::new()))),
            CapacityArchive::new(dir.join("archive.json")),
            now.clone(),
            CodexService::new(tx.clone(), now.clone(), "0", Arc::new(|| Ok(None))),
            ClaudeService::new(tx.clone(), now.clone(), Arc::new(Nothing)),
            OpenCodeService::new(tx, now, Arc::new(|| None), Arc::new(NoNetwork)),
        );
        assert!(first.prefs.connects_at_launch(Provider::Codex));
        assert!(!first.should_read(Provider::Codex), "nothing is read before onboarding");
        first.prefs.set_has_finished_onboarding(true);
        assert!(first.should_read(Provider::Codex));
    }

    #[tokio::test]
    async fn opencode_is_not_turned_on_without_consent() {
        let h = hub("consent", &[]);
        h.prefs.set_open_code_consent_given(false);
        assert!(!h.set_provider_enabled(Provider::OpenCode, true).await);
        assert!(!h.prefs.connects_at_launch(Provider::OpenCode));
    }

    #[tokio::test]
    async fn refreshing_a_provider_not_connected_asks_settings_for_its_consent() {
        let h = hub("refresh-one", &[]);
        let mut events = h.subscribe();
        h.refresh_provider(Provider::ClaudeCode).await;
        let asked = std::iter::from_fn(|| events.try_recv().ok())
            .any(|e| matches!(e, Event::Module(m, n, d) if m == "hub" && n == "openSettings" && d.contains("providers")));
        assert!(asked);
        assert!(!h.prefs.connects_at_launch(Provider::ClaudeCode), "no consent, no connection");

        // Codex needs none: it is connected at once.
        h.refresh_provider(Provider::Codex).await;
        assert!(h.prefs.connects_at_launch(Provider::Codex));
    }

    #[tokio::test]
    async fn refreshing_a_connected_provider_forgets_its_failures_and_wakes_it() {
        let h = hub("refresh-connected", &[Provider::OpenCode]);
        h.apply(CapacitySnapshot::disconnected(Provider::OpenCode, Utc::now(), CapacityStatusReason::OpenCodeUnreachable));
        let _ = h.call("hub", "refresh", serde_json::json!({"provider": "openCode"})).await.unwrap();
        assert_eq!(h.state.lock().unwrap().failures[&Provider::OpenCode], 0);
        assert!(h.forced[slot(Provider::OpenCode)].load(Ordering::SeqCst));
        assert!(woken(&h, Provider::OpenCode).await);
        assert!(!woken(&h, Provider::Codex).await);
    }

    #[tokio::test]
    async fn quitting_keeps_the_archive_and_hears_nothing_after() {
        let h = hub("shutdown", &[Provider::Codex]);
        let stale = CapacitySnapshot {
            connection_state: ConnectionState::Stale,
            status_reason: Some(CapacityStatusReason::ProviderCouldNotRead("x".into())),
            ..fresh(Provider::Codex, 0.3)
        };
        h.apply(stale);
        h.shutdown().await;
        assert_eq!(h.archive.load().len(), 1, "written at quitting");
        h.apply(fresh(Provider::Codex, 0.9));
        assert_eq!(state(&h)["providers"][0]["state"], "stale", "nothing is taken in once quitting");
        assert!(h.prefs.connects_at_launch(Provider::Codex), "quitting remembers nothing else");
    }

    // MARK: - What goes out

    /// A Module whose state carries the time it was rendered, and a level.
    struct Clocked {
        clock: Clock,
        level: Mutex<i64>,
    }
    impl capa_core::module::SurfaceModule for Clocked {
        fn id(&self) -> &'static str {
            "clocked"
        }
        fn state(&self) -> serde_json::Value {
            let now = (self.clock)();
            serde_json::json!({
                "level": *self.level.lock().unwrap(),
                "serverNow": now.timestamp_millis(),
                "serverNowMs": now.timestamp_millis(),
            })
        }
        fn call(&self, _: &str, _: serde_json::Value) -> capa_core::module::BoxFuture<Result<serde_json::Value, String>> {
            Box::pin(async { Ok(serde_json::Value::Null) })
        }
    }

    fn states_sent(events: &mut broadcast::Receiver<Event>) -> Vec<serde_json::Value> {
        std::iter::from_fn(|| events.try_recv().ok())
            .filter_map(|e| match e {
                Event::State(json) => Some(serde_json::from_str(&json).unwrap()),
                _ => None,
            })
            .collect()
    }

    #[test]
    fn a_state_that_only_aged_is_not_sent_again() {
        let at = Arc::new(Mutex::new(Utc.timestamp_opt(1_700_000_000, 0).unwrap()));
        let clock: Clock = {
            let at = at.clone();
            Arc::new(move || *at.lock().unwrap())
        };
        let h = Arc::new(hub_at("aged", &[], clock.clone()).0);
        let module = Arc::new(Clocked { clock, level: Mutex::new(1) });
        h.attach(|_| vec![module.clone() as Arc<dyn capa_core::module::SurfaceModule>]);
        let mut events = h.subscribe();
        let publish = || h.publish(&h.state.lock().unwrap());

        publish();
        assert_eq!(states_sent(&mut events).len(), 1, "the first goes out");
        publish();
        assert!(states_sent(&mut events).is_empty(), "the same state, not again");

        // Only the clocks moved: the hub's `now`, the Module's `serverNow`.
        *at.lock().unwrap() += chrono::Duration::seconds(10);
        publish();
        assert!(states_sent(&mut events).is_empty(), "ten seconds older is not news");

        // What the Module shows changed: it goes, with the time it was rendered.
        *module.level.lock().unwrap() = 2;
        publish();
        let sent = states_sent(&mut events);
        assert_eq!(sent.len(), 1);
        assert_eq!(sent[0]["modules"]["clocked"]["level"], 2);
        assert_eq!(sent[0]["modules"]["clocked"]["serverNow"], at.lock().unwrap().timestamp_millis());
        assert_eq!(sent[0]["now"], at.lock().unwrap().timestamp());
        // And what the hub says.
        h.set_expanded(true);
        assert_eq!(states_sent(&mut events).len(), 1);
    }

    #[test]
    fn the_tick_sends_a_countdown_only_when_its_words_change() {
        let start = Utc.timestamp_opt(1_700_000_000, 0).unwrap();
        let at = Arc::new(Mutex::new(start));
        let clock: Clock = {
            let at = at.clone();
            Arc::new(move || *at.lock().unwrap())
        };
        let h = hub_at("countdown", &[Provider::Codex], clock).0;
        let resets = start + chrono::Duration::seconds(90 * 60 + 30);
        h.apply(CapacitySnapshot {
            windows: vec![QuotaWindow::new("w", "5 hour", Some(300), 0.3, Some(resets))],
            ..fresh(Provider::Codex, 0.3)
        });
        let mut events = h.subscribe();
        let tick = || h.publish(&h.state.lock().unwrap());
        let words = |s: &serde_json::Value| s["providers"][0].to_string();

        tick();
        assert!(states_sent(&mut events).is_empty(), "nothing changed since the reading went out");
        *at.lock().unwrap() += chrono::Duration::seconds(1);
        tick();
        assert!(states_sent(&mut events).is_empty(), "a second on, the countdown reads the same");
        let before = state(&h);
        *at.lock().unwrap() += chrono::Duration::minutes(31);
        tick();
        let sent = states_sent(&mut events);
        assert_eq!(sent.len(), 1, "half an hour on, it reads otherwise and goes out");
        assert_ne!(words(&sent[0]), words(&before));
    }

    #[test]
    fn the_report_notes_the_machine_first_then_the_modules_in_order() {
        use capa_core::module::{BoxFuture, SurfaceModule};
        struct Noting(&'static str);
        impl SurfaceModule for Noting {
            fn id(&self) -> &'static str {
                self.0
            }
            fn state(&self) -> serde_json::Value {
                serde_json::Value::Null
            }
            fn call(&self, _: &str, _: serde_json::Value) -> BoxFuture<Result<serde_json::Value, String>> {
                Box::pin(async { Ok(serde_json::Value::Null) })
            }
            fn observations(&self) -> Vec<String> {
                vec![format!("{}-note", self.0)]
            }
        }
        let h = Arc::new(hub("report-order", &[]));
        let home = std::env::temp_dir().join(format!("capa-hub-machine-{}", std::process::id()));
        let _ = h.machine.set(Machine {
            claude_bridge: home.join("nothing/claude-capacity.json"),
            home,
            launches_at_login: Box::new(|| false),
        });
        h.attach(|_| ["shelf", "teleprompter", "dictation", "music", "settings"].map(|id| Arc::new(Noting(id)) as Arc<dyn SurfaceModule>).to_vec());
        let text = h.diagnostic_report();
        let at = |note: &str| text.find(note).unwrap_or_else(|| panic!("{note} missing: {text}"));
        assert!(at("claude-bridge-snapshot-missing") < at("launch-at-login-off"));
        assert!(at("launch-at-login-off") < at("music-note"));
        assert!(at("music-note") < at("dictation-note"));
        assert!(at("dictation-note") < at("teleprompter-note"));
        assert!(at("teleprompter-note") < at("shelf-note"));
        assert!(at("shelf-note") < at("settings-note"));
    }

    // MARK: - The machine's parts

    #[derive(Default)]
    struct Heard(Mutex<Vec<SoundCue>>);
    impl capa_core::sound::SoundOut for Heard {
        fn play(&self, cue: SoundCue, _: &capa_core::sound::SoundBuffer) {
            self.0.lock().unwrap().push(cue);
        }
    }

    fn listening(h: &Hub) -> Arc<Heard> {
        let heard = Arc::new(Heard::default());
        h.prefs.set_plays_sounds(true);
        let sounds = Sounds::with_interface_probe(h.prefs.clone(), heard.clone(), Box::new(|| true));
        let _ = h.sounds.set(Arc::new(sounds));
        heard
    }

    #[test]
    fn an_alert_sounds_once_and_the_recovery_after_it_sounds_too() {
        let h = hub("sound-alert", &[Provider::Codex]);
        let heard = listening(&h);
        h.apply(fresh(Provider::Codex, 0.96));
        h.apply(fresh(Provider::Codex, 0.97));
        assert_eq!(*heard.0.lock().unwrap(), [SoundCue::CapacityAlert], "the banner is silent; the sound is ours, once");
        h.apply(fresh(Provider::Codex, 0.40));
        assert_eq!(*heard.0.lock().unwrap(), [SoundCue::CapacityAlert, SoundCue::CapacityRecovered]);
    }

    #[test]
    fn every_alert_sent_sounds() {
        let h = hub("sound-each", &[Provider::Codex]);
        let heard = listening(&h);
        let both = CapacitySnapshot {
            windows: vec![
                QuotaWindow::new("five", "5 hour", Some(300), 0.96, None),
                QuotaWindow::new("week", "weekly", Some(10080), 0.97, None),
            ],
            ..fresh(Provider::Codex, 0.0)
        };
        h.apply(both);
        assert_eq!(*heard.0.lock().unwrap(), [SoundCue::CapacityAlert, SoundCue::CapacityAlert], "two windows ran out: two alerts, two sounds");
    }

    #[test]
    fn a_provider_that_was_answering_and_stopped_sounds_but_a_blip_or_a_stranger_does_not() {
        let h = hub("sound-stopped", &[Provider::Codex, Provider::OpenCode]);
        let heard = listening(&h);
        let failed = |p, reason| CapacitySnapshot::disconnected(p, Utc::now(), reason);
        // Never answered this session: it would sound at every launch.
        h.apply(failed(Provider::OpenCode, CapacityStatusReason::OpenCodeKeyRefused));
        assert!(heard.0.lock().unwrap().is_empty());
        // Answering, then a blip that is retried: no sound.
        h.apply(fresh(Provider::Codex, 0.1));
        h.apply(failed(Provider::Codex, CapacityStatusReason::ProviderUnavailable("x".into())));
        assert!(heard.0.lock().unwrap().is_empty());
        // Answering, then stopping for a reason that is not retried: once.
        h.apply(fresh(Provider::Codex, 0.1));
        h.apply(failed(Provider::Codex, CapacityStatusReason::ProviderNotAuthenticated));
        assert_eq!(*heard.0.lock().unwrap(), [SoundCue::ProviderStopped]);
        h.apply(failed(Provider::Codex, CapacityStatusReason::ProviderNotAuthenticated));
        assert_eq!(heard.0.lock().unwrap().len(), 1, "on the change, not again");
    }

    #[test]
    fn sounds_off_means_silence() {
        let h = hub("sound-off", &[Provider::Codex]);
        let heard = listening(&h);
        h.prefs.set_plays_sounds(false);
        h.apply(fresh(Provider::Codex, 0.96));
        assert!(heard.0.lock().unwrap().is_empty());
    }

    #[test]
    fn the_displays_the_host_reports_are_in_the_state_with_the_one_chosen() {
        let h = hub("displays", &[]);
        h.set_displays(vec![DisplayDescriptor::new(7, "Dell", false), DisplayDescriptor::new(2, "Built-in", true)]);
        assert_eq!(state(&h)["displays"]["chosenId"], 2);
        h.set_preferred_display(Some(7));
        let s = state(&h);
        assert_eq!(s["displays"]["chosenId"], 7);
        assert_eq!(s["displays"]["preferredId"], 7);
    }

    #[test]
    fn the_report_carries_each_provider_and_the_log_stays_off_until_asked() {
        let h = hub("report", &[Provider::Codex]);
        h.apply(fresh(Provider::Codex, 0.2));
        let text = h.diagnostic_report();
        assert!(text.starts_with("CapaTheNotch "), "{text}");
        assert!(text.contains("codex:") && text.contains("state fresh"), "{text}");
        assert!(h.diagnostic_log_path().is_none(), "no log was set up in this hub");
    }

    /// A Module that publishes from `preferences_changed`, as Dictation does,
    /// must not be told to read its preferences again by its own publishing:
    /// that circle once sent the state out six thousand times a second.
    #[test]
    fn a_module_that_notifies_from_preferences_changed_does_not_go_round_in_a_circle() {
        use capa_core::module::{BoxFuture, SurfaceModule};
        use std::sync::atomic::AtomicUsize;

        struct Echo {
            context: ModuleContext,
            reads: Arc<AtomicUsize>,
        }
        impl SurfaceModule for Echo {
            fn id(&self) -> &'static str {
                "echo"
            }
            fn state(&self) -> serde_json::Value {
                serde_json::Value::Null
            }
            fn call(&self, _: &str, _: serde_json::Value) -> BoxFuture<Result<serde_json::Value, String>> {
                Box::pin(async { Ok(serde_json::Value::Null) })
            }
            fn preferences_changed(&self) {
                self.reads.fetch_add(1, Ordering::SeqCst);
                (self.context.notify)();
            }
        }

        let h = Arc::new(hub("circle", &[]));
        let reads = Arc::new(AtomicUsize::new(0));
        let seen = reads.clone();
        h.attach(move |context| vec![Arc::new(Echo { context, reads: seen }) as Arc<dyn SurfaceModule>]);
        h.set_alerts_enabled(false);
        assert_eq!(reads.load(Ordering::SeqCst), 1, "one preference changed, one read");
    }
}
