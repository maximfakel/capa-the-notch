//! The Linux `MediaSource`: MPRIS on the session bus. Any player that shows
//! its track in the shell's media controls is a player here. The source
//! follows players appearing and going (`NameOwnerChanged`), their property
//! changes and seeks, and reports the one a person would see — the playing
//! one, else the one most recently active — as a whole picture each time.

use crate::artwork::{self, ArtworkStore};
use crate::mpris_parse::{self as parse, AppFacts, Player, Snapshot};
use crate::reading::differs;
use capa_core::music::{MediaEvent, MediaSource, MusicCommand, NowPlayingReading};
use chrono::Utc;
use futures_util::StreamExt;
use std::collections::HashMap;
use std::sync::mpsc::Sender;
use std::sync::Arc;
use tokio::sync::mpsc::{unbounded_channel, UnboundedSender};

/// A track as the cover remembers it: its title and its artists.
type TrackKey = (Option<String>, Vec<String>);
use tokio::task::JoinHandle;
use zbus::fdo::{DBusProxy, PropertiesProxy};
use zbus::names::InterfaceName;
use zbus::zvariant::{ObjectPath, OwnedValue};
use zbus::{Connection, Proxy};

pub struct MprisSource {
    runtime: tokio::runtime::Handle,
    artwork: Arc<ArtworkStore>,
    task: Option<JoinHandle<()>>,
    commands: Option<UnboundedSender<MusicCommand>>,
}

impl MprisSource {
    /// Needs to be made inside a Tokio runtime, whose handle it keeps.
    pub fn new(artwork: Arc<ArtworkStore>) -> Self {
        Self { runtime: tokio::runtime::Handle::current(), artwork, task: None, commands: None }
    }
}

impl MediaSource for MprisSource {
    fn start(&mut self, events: Sender<MediaEvent>) {
        self.stop();
        let (tx, rx) = unbounded_channel();
        self.commands = Some(tx);
        let artwork = self.artwork.clone();
        self.task = Some(self.runtime.spawn(async move {
            if run(events.clone(), rx, artwork).await.is_err() {
                // No session bus, or it went: there is nothing to read from.
                let _ = events.send(MediaEvent::Unreadable { unreadable: true });
            }
        }));
    }

    fn stop(&mut self) {
        if let Some(task) = self.task.take() {
            task.abort();
        }
        self.commands = None;
    }

    fn send(&self, command: MusicCommand) {
        if let Some(commands) = &self.commands {
            let _ = commands.send(command);
        }
    }
}

enum Msg {
    /// A name on the bus gained or lost an owner.
    Appeared(String),
    Vanished(String),
    /// A player's properties changed, or it seeked.
    Changed(String),
    /// A cover came in for a player's current `artUrl`.
    Art(String, String, Option<Vec<u8>>),
}

struct Tracked {
    player: Player,
    /// Where its updates are heard.
    listener: JoinHandle<()>,
    /// The cover's id for `art_url`, once fetched.
    art: Option<(String, Option<String>)>,
}

async fn props_proxy<'a>(connection: &'a Connection, bus_name: &str) -> zbus::Result<PropertiesProxy<'a>> {
    PropertiesProxy::builder(connection)
        .destination(bus_name.to_owned())?
        .path(parse::OBJECT_PATH)?
        .build()
        .await
}

async fn read(connection: &Connection, bus_name: &str) -> zbus::Result<Snapshot> {
    let props = props_proxy(connection, bus_name).await?;
    let player: HashMap<String, OwnedValue> =
        props.get_all(InterfaceName::from_static_str_unchecked(parse::PLAYER_INTERFACE)).await?;
    // The name is a nicety: a player that will not tell it is still a player.
    let root = props
        .get_all(InterfaceName::from_static_str_unchecked(parse::ROOT_INTERFACE))
        .await
        .unwrap_or_default();
    Ok(Snapshot::from_properties(&player, &root))
}

async fn run(
    events: Sender<MediaEvent>,
    mut commands: tokio::sync::mpsc::UnboundedReceiver<MusicCommand>,
    artwork: Arc<ArtworkStore>,
) -> zbus::Result<()> {
    let connection = Connection::session().await?;
    let dbus = DBusProxy::new(&connection).await?;
    let (msg_tx, mut msgs) = unbounded_channel::<Msg>();

    // Names coming and going.
    let mut owner_changes = dbus.receive_name_owner_changed().await?;
    {
        let msg_tx = msg_tx.clone();
        tokio::spawn(async move {
            while let Some(change) = owner_changes.next().await {
                let Ok(args) = change.args() else { continue };
                let name = args.name().to_string();
                if !parse::is_player(&name) {
                    continue;
                }
                let msg = if args.new_owner().is_some() { Msg::Appeared(name) } else { Msg::Vanished(name) };
                if msg_tx.send(msg).is_err() {
                    break;
                }
            }
        });
    }

    // Connected: reading works (again, if a retry brought it back).
    if events.send(MediaEvent::Unreadable { unreadable: false }).is_err() {
        return Ok(());
    }

    let mut tracked: HashMap<String, Tracked> = HashMap::new();
    // What each desktop entry's file says, looked up once.
    let mut apps: HashMap<String, AppFacts> = HashMap::new();
    let mut activity = 0u64;
    for name in dbus.list_names().await? {
        if parse::is_player(&name) {
            let _ = msg_tx.send(Msg::Appeared(name.to_string()));
        }
    }
    let mut last_sent: Option<NowPlayingReading> = None;
    // The last cover shown for each player, with the track it was shown for. A browser hands
    // the same track a new `artUrl` (a fresh temporary file) on a seek, or briefly none, and
    // fetching it again takes a moment: the same track keeps its cover meanwhile, as the Mac
    // never shows it blink (the fetched one is the same picture, so the same id, anyway).
    let mut last_art: HashMap<String, (TrackKey, String)> = HashMap::new();

    loop {
        tokio::select! {
            command = commands.recv() => {
                let Some(command) = command else { break };
                let current = parse::current(&players(&tracked)).map(|p| (p.bus_name.clone(), p.snapshot.clone()));
                if let Some((bus_name, snapshot)) = current {
                    let _ = control(&connection, &bus_name, &snapshot, command).await;
                }
            }
            msg = msgs.recv() => {
                let Some(msg) = msg else { break };
                match msg {
                    Msg::Appeared(name) => {
                        if tracked.contains_key(&name) { continue; }
                        let Ok(snapshot) = read(&connection, &name).await else { continue };
                        let entries = app_entries(&name, &snapshot);
                        if let Some(key) = entries.first().cloned() {
                            if let std::collections::hash_map::Entry::Vacant(slot) = apps.entry(key) {
                                slot.insert(look_up_app(entries, &artwork).await);
                            }
                        }
                        activity += 1;
                        let listener = listen(&connection, &name, msg_tx.clone()).await;
                        tracked.insert(name.clone(), Tracked {
                            player: Player { bus_name: name.clone(), snapshot, activity },
                            listener,
                            art: None,
                        });
                        want_art(&mut tracked, &name, &msg_tx);
                    }
                    Msg::Vanished(name) => {
                        if let Some(t) = tracked.remove(&name) { t.listener.abort(); }
                        last_art.remove(&name);
                    }
                    Msg::Changed(name) => {
                        let Some(t) = tracked.get_mut(&name) else { continue };
                        let Ok(snapshot) = read(&connection, &name).await else { continue };
                        // Position moves on its own; a change is a change of what is shown.
                        let moved = changed_materially(&t.player.snapshot, &snapshot);
                        t.player.snapshot = snapshot;
                        if moved {
                            activity += 1;
                            t.player.activity = activity;
                        }
                        want_art(&mut tracked, &name, &msg_tx);
                    }
                    Msg::Art(name, url, bytes) => {
                        if let Some(t) = tracked.get_mut(&name) {
                            let id = bytes.and_then(|b| artwork.put(&b));
                            if t.player.snapshot.art_url.as_deref() == Some(&url) {
                                t.art = Some((url, id));
                            }
                        }
                    }
                }
            }
        }

        // The whole picture, when it differs from the last one told.
        let sampled = Utc::now();
        let reading = match parse::current(&players(&tracked)) {
            Some(p) => {
                let fetched = tracked.get(&p.bus_name).and_then(|t| t.art.as_ref()).and_then(|(url, id)| {
                    (p.snapshot.art_url.as_deref() == Some(url)).then(|| id.clone()).flatten()
                });
                let track = (p.snapshot.title.clone(), p.snapshot.artists.clone());
                let art = match fetched {
                    Some(id) => {
                        last_art.insert(p.bus_name.clone(), (track, id.clone()));
                        Some(id)
                    }
                    None => last_art.get(&p.bus_name).filter(|(shown, _)| *shown == track).map(|(_, id)| id.clone()),
                };
                let app = app_entries(&p.bus_name, &p.snapshot).first().and_then(|e| apps.get(e));
                match p.snapshot.now_playing(&p.bus_name, art.map(String::into_bytes), app, sampled) {
                    Some(track) => NowPlayingReading::Item(track),
                    None => NowPlayingReading::Nothing,
                }
            }
            None => NowPlayingReading::Nothing,
        };
        if last_sent.as_ref().is_none_or(|last| differs(last, &reading)) {
            last_sent = Some(reading.clone());
            if events.send(MediaEvent::Reading { reading }).is_err() {
                break;
            }
        }
    }
    Ok(())
}

/// The desktop entries a player may be: its `DesktopEntry`, then what its bus
/// name suggests (`org.mpris.MediaPlayer2.vlc` → `vlc`), as is and in lower
/// case. The first is the key its facts are kept under.
fn app_entries(bus_name: &str, snapshot: &Snapshot) -> Vec<String> {
    let mut entries: Vec<String> = snapshot.desktop_entry.iter().cloned().collect();
    if let Some(tail) = crate::desktop::entry_of_bus_name(bus_name) {
        let lower = tail.to_lowercase();
        entries.extend([tail, lower]);
    }
    let mut seen = std::collections::HashSet::new();
    entries.retain(|e| seen.insert(e.clone()));
    entries
}

/// A desktop entry's name and icon (the icon kept in the store), read off the
/// async threads.
async fn look_up_app(entries: Vec<String>, artwork: &Arc<ArtworkStore>) -> AppFacts {
    let artwork = artwork.clone();
    tokio::task::spawn_blocking(move || {
        let Some(app) = crate::desktop::lookup(&entries) else { return AppFacts::default() };
        let icon_id = app.icon.and_then(|path| crate::artwork::icon_png(&path)).and_then(|png| artwork.put_icon(&png));
        AppFacts { name: app.name, icon_id }
    })
    .await
    .unwrap_or_default()
}

fn players(tracked: &HashMap<String, Tracked>) -> Vec<Player> {
    tracked.values().map(|t| t.player.clone()).collect()
}

/// Whether the new snapshot changed something a person would notice (or
/// something that makes this player the active one), as against a position
/// that is only the old one moved on.
fn changed_materially(old: &Snapshot, new: &Snapshot) -> bool {
    old.playing != new.playing || old.paused != new.paused || old.title != new.title || old.artists != new.artists
}

/// Fetches a player's cover if its `artUrl` is one we do not have.
fn want_art(tracked: &mut HashMap<String, Tracked>, name: &str, msgs: &UnboundedSender<Msg>) {
    let Some(t) = tracked.get_mut(name) else { return };
    let Some(url) = t.player.snapshot.art_url.clone() else {
        t.art = None;
        return;
    };
    if t.art.as_ref().is_some_and(|(known, _)| *known == url) {
        return;
    }
    // Marked as asked, so a burst of changes asks once.
    t.art = Some((url.clone(), None));
    let (name, msgs) = (name.to_owned(), msgs.clone());
    tokio::task::spawn_blocking(move || {
        let bytes = artwork::fetch(&url);
        let _ = msgs.send(Msg::Art(name, url, bytes));
    });
}

/// Listens to one player's property changes and seeks.
async fn listen(connection: &Connection, bus_name: &str, msgs: UnboundedSender<Msg>) -> JoinHandle<()> {
    let name = bus_name.to_owned();
    let connection = connection.clone();
    tokio::spawn(async move {
        let Ok(props) = props_proxy(&connection, &name).await else { return };
        let Ok(mut changed) = props.receive_properties_changed().await else { return };
        let player = Proxy::new(&connection, name.clone(), parse::OBJECT_PATH, parse::PLAYER_INTERFACE).await;
        let mut seeked = match &player {
            Ok(p) => p.receive_signal("Seeked").await.ok(),
            Err(_) => None,
        };
        loop {
            let ping = match &mut seeked {
                Some(stream) => tokio::select! {
                    c = changed.next() => c.is_some(),
                    s = stream.next() => s.is_some(),
                },
                None => changed.next().await.is_some(),
            };
            if !ping || msgs.send(Msg::Changed(name.clone())).is_err() {
                break;
            }
        }
    })
}

/// A control, on the player the person sees.
async fn control(connection: &Connection, bus_name: &str, snapshot: &Snapshot, command: MusicCommand) -> zbus::Result<()> {
    let player = Proxy::new(connection, bus_name.to_owned(), parse::OBJECT_PATH, parse::PLAYER_INTERFACE).await?;
    match command {
        MusicCommand::Previous => player.call_method("Previous", &()).await.map(|_| ()),
        MusicCommand::Next => player.call_method("Next", &()).await.map(|_| ()),
        MusicCommand::TogglePlayPause => player.call_method("PlayPause", &()).await.map(|_| ()),
        MusicCommand::Seek { to } => {
            let target_us = (to.max(0.0) * 1_000_000.0).round() as i64;
            // `SetPosition` is exact but needs the track's id; without one,
            // `Seek` by the difference from where the player says it is.
            let track = snapshot.track_id.as_deref().and_then(|id| ObjectPath::try_from(id).ok());
            match track {
                Some(track) => player.call_method("SetPosition", &(track, target_us)).await.map(|_| ()),
                None => {
                    let now: i64 = player.get_property("Position").await.unwrap_or(0);
                    player.call_method("Seek", &(target_us - now)).await.map(|_| ())
                }
            }
        }
    }
}
