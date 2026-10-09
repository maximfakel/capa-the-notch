//! The MPRIS source against a player of our own, on a bus of its own:
//! what it reports, how it reaches it, and that it notices it go.
//!
//! Never the person's session bus: there the source would follow whichever real
//! player is most active, and Next, Previous, PlayPause and Seek would go to it.
//! A private `dbus-daemon` is started for the test and the session address is
//! pointed at it; without `dbus-daemon` the test is skipped.

use capa_core::music::{MediaEvent, MediaSource, MusicCommand, NowPlayingReading};
use capa_music::{ArtworkStore, MprisSource};
use std::collections::HashMap;
use std::sync::mpsc::{channel, Receiver};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use zbus::zvariant::{ObjectPath, OwnedValue, Value};

const NAME: &str = "org.mpris.MediaPlayer2.capatest";
const PATH: &str = "/org/mpris/MediaPlayer2";

#[derive(Clone, Default)]
struct Calls(Arc<Mutex<Vec<String>>>);

struct Player {
    calls: Calls,
    status: Arc<Mutex<String>>,
    /// The track's title and its `mpris:artUrl`, as the test changes them.
    track: Arc<Mutex<(String, Option<String>)>>,
}

struct Root;

#[zbus::interface(name = "org.mpris.MediaPlayer2")]
impl Root {
    #[zbus(property)]
    fn identity(&self) -> String {
        "Capa Test Player".into()
    }
    #[zbus(property)]
    fn desktop_entry(&self) -> String {
        "capatest".into()
    }
}

#[zbus::interface(name = "org.mpris.MediaPlayer2.Player")]
impl Player {
    fn next(&self) {
        self.calls.0.lock().unwrap().push("Next".into());
    }
    fn previous(&self) {
        self.calls.0.lock().unwrap().push("Previous".into());
    }
    fn play_pause(&self) {
        self.calls.0.lock().unwrap().push("PlayPause".into());
    }
    fn set_position(&self, track: ObjectPath<'_>, position: i64) {
        self.calls.0.lock().unwrap().push(format!("SetPosition {track} {position}"));
    }

    #[zbus(property)]
    fn playback_status(&self) -> String {
        self.status.lock().unwrap().clone()
    }
    #[zbus(property)]
    fn position(&self) -> i64 {
        30_000_000
    }
    #[zbus(property)]
    fn rate(&self) -> f64 {
        1.0
    }
    #[zbus(property)]
    fn metadata(&self) -> HashMap<String, OwnedValue> {
        let owned = |v: Value<'_>| v.try_to_owned().unwrap();
        let (title, art) = self.track.lock().unwrap().clone();
        let mut metadata = HashMap::from([
            ("mpris:trackid".to_string(), owned(Value::ObjectPath(ObjectPath::try_from("/capa/track/1").unwrap()))),
            ("xesam:title".to_string(), owned(Value::from(title))),
            ("mpris:length".to_string(), owned(Value::I64(200_000_000))),
        ]);
        if let Some(art) = art {
            metadata.insert("mpris:artUrl".to_string(), owned(Value::from(art)));
        }
        metadata
    }
}

/// A session bus of the test's own, for as long as it lives.
struct PrivateBus(std::process::Child);

impl PrivateBus {
    fn start() -> Option<Self> {
        use std::io::{BufRead, BufReader};
        let mut child = std::process::Command::new("dbus-daemon")
            .args(["--session", "--nofork", "--print-address=1"])
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .spawn()
            .ok()?;
        let mut address = String::new();
        BufReader::new(child.stdout.take()?).read_line(&mut address).ok()?;
        let address = address.trim();
        if address.is_empty() {
            let _ = child.kill();
            return None;
        }
        // Every connection made from here on, the source's included, is to this bus.
        std::env::set_var("DBUS_SESSION_BUS_ADDRESS", address);
        Some(Self(child))
    }
}

impl Drop for PrivateBus {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn next_reading(rx: &Receiver<MediaEvent>, mut wanted: impl FnMut(&NowPlayingReading) -> bool) -> Option<NowPlayingReading> {
    let until = Instant::now() + Duration::from_secs(8);
    while let Some(left) = until.checked_duration_since(Instant::now()) {
        if let Ok(MediaEvent::Reading { reading }) = rx.recv_timeout(left) {
            if wanted(&reading) {
                return Some(reading);
            }
        }
    }
    None
}

fn is_ours(reading: &NowPlayingReading) -> bool {
    matches!(reading, NowPlayingReading::Item(t) if t.title.starts_with("Capa Test"))
}

/// The player's desktop file and icon, in data directories of the test's own.
fn private_data_dirs() -> std::path::PathBuf {
    let root = std::env::temp_dir().join(format!("capa-mpris-data-{}", std::process::id()));
    let (apps, icons) = (root.join("applications"), root.join("icons/hicolor/256x256/apps"));
    std::fs::create_dir_all(&apps).unwrap();
    std::fs::create_dir_all(&icons).unwrap();
    std::fs::write(apps.join("capatest.desktop"), "[Desktop Entry]\nType=Application\nName=Capa Test App\nName[ru]=Тестовый плеер\nIcon=capatest\n").unwrap();
    let mut png = std::io::Cursor::new(Vec::new());
    image::DynamicImage::ImageRgba8(image::RgbaImage::from_pixel(64, 64, image::Rgba([200, 30, 30, 255])))
        .write_to(&mut png, image::ImageFormat::Png)
        .unwrap();
    std::fs::write(icons.join("capatest.png"), png.into_inner()).unwrap();
    std::env::set_var("XDG_DATA_HOME", &root);
    std::env::set_var("XDG_DATA_DIRS", root.join("nothing-else"));
    std::env::set_var("LC_ALL", "ru_RU.UTF-8");
    root
}

#[tokio::test(flavor = "multi_thread")]
async fn it_reads_a_player_controls_it_and_notices_it_go() {
    let Some(_bus) = PrivateBus::start() else { return };
    let data = private_data_dirs();
    let Ok(connection) = zbus::connection::Builder::session() else { return };
    let calls = Calls::default();
    let status = Arc::new(Mutex::new("Playing".to_string()));
    let song = Arc::new(Mutex::new(("Capa Test".to_string(), None::<String>)));
    let Ok(builder) = connection
        .name(NAME)
        .and_then(|b| b.serve_at(PATH, Root))
        .and_then(|b| b.serve_at(PATH, Player { calls: calls.clone(), status: status.clone(), track: song.clone() }))
    else {
        return;
    };
    let Ok(player_connection) = builder.build().await else { return };

    let store = Arc::new(ArtworkStore::new());
    let mut source = MprisSource::new(store.clone());
    let (tx, rx) = channel();
    source.start(tx);

    // It reports the playing player, with its length, position and name.
    let reading = next_reading(&rx, is_ours).expect("our player is reported");
    let NowPlayingReading::Item(track) = reading else { unreachable!() };
    assert!(track.is_playing);
    assert_eq!(track.duration, Some(200.0));
    assert_eq!(track.elapsed, Some(30.0));
    assert_eq!(track.player.as_deref(), Some("capatest"), "the raw id: the desktop entry");
    assert_eq!(track.player_name.as_deref(), Some("Тестовый плеер"), "the desktop file's name, in the locale");
    let icon = track.icon_id.as_deref().expect("the desktop file's icon");
    assert!(store.get(icon).is_some_and(|png| png.starts_with(b"\x89PNG")), "kept in the store as a PNG");

    // Controls reach it, a seek by SetPosition with the track's id.
    source.send(MusicCommand::Next);
    source.send(MusicCommand::Previous);
    source.send(MusicCommand::TogglePlayPause);
    source.send(MusicCommand::Seek { to: 12.5 });
    let until = Instant::now() + Duration::from_secs(5);
    while calls.0.lock().unwrap().len() < 4 && Instant::now() < until {
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert_eq!(
        *calls.0.lock().unwrap(),
        ["Next", "Previous", "PlayPause", "SetPosition /capa/track/1 12500000"]
    );

    // A change of state is followed.
    *status.lock().unwrap() = "Paused".into();
    let object = player_connection.object_server().interface::<_, Player>(PATH).await.unwrap();
    object.get().await.playback_status_changed(object.signal_emitter()).await.unwrap();
    assert!(next_reading(&rx, |r| matches!(r, NowPlayingReading::Item(t) if t.title == "Capa Test" && !t.is_playing)).is_some());

    // A cover, then the same track's cover at an address not yet readable — a browser
    // writes a fresh temporary file on a seek: the cover stays, it does not blink out.
    let cover = data.join("cover.png");
    let mut png = std::io::Cursor::new(Vec::new());
    image::DynamicImage::ImageRgba8(image::RgbaImage::from_pixel(32, 32, image::Rgba([10, 120, 200, 255])))
        .write_to(&mut png, image::ImageFormat::Png)
        .unwrap();
    std::fs::write(&cover, png.into_inner()).unwrap();
    song.lock().unwrap().1 = Some(format!("file://{}", cover.display()));
    object.get().await.metadata_changed(object.signal_emitter()).await.unwrap();
    let shown = next_reading(&rx, |r| matches!(r, NowPlayingReading::Item(t) if t.title == "Capa Test" && t.artwork.is_some()))
        .expect("the cover is read");
    let NowPlayingReading::Item(shown) = shown else { unreachable!() };
    song.lock().unwrap().1 = Some(format!("file://{}", data.join("not-yet-written.png").display()));
    object.get().await.metadata_changed(object.signal_emitter()).await.unwrap();
    let until = Instant::now() + Duration::from_millis(1500);
    while let Some(left) = until.checked_duration_since(Instant::now()) {
        if let Ok(MediaEvent::Reading { reading: NowPlayingReading::Item(t) }) = rx.recv_timeout(left) {
            if t.title == "Capa Test" {
                assert_eq!(t.artwork, shown.artwork, "the same track keeps its cover while the new address is read");
            }
        }
    }
    // Another track does not inherit it.
    song.lock().unwrap().0 = "Capa Test 2".into();
    object.get().await.metadata_changed(object.signal_emitter()).await.unwrap();
    let other = next_reading(&rx, |r| matches!(r, NowPlayingReading::Item(t) if t.title == "Capa Test 2")).expect("the next track");
    let NowPlayingReading::Item(other) = other else { unreachable!() };
    assert_eq!(other.artwork, None, "a new track's cover is its own");

    // And it going is noticed: it is no longer the track shown.
    drop(object);
    drop(player_connection);
    assert!(next_reading(&rx, |r| !is_ours(r)).is_some(), "the player left");
    source.stop();
    let _ = std::fs::remove_dir_all(data);
}
