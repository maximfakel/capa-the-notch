//! What an MPRIS player says, as plain data: the properties of
//! `org.mpris.MediaPlayer2.Player` (and the player's name), and the choice of
//! which player is "the" one — the one a person would see in the system's
//! media controls. Pure: no bus here, so it is tested on recorded property maps.

use capa_core::music::NowPlaying;
use chrono::{DateTime, Utc};
use std::collections::HashMap;
use zbus::zvariant::{OwnedValue, Value};

pub const PLAYER_INTERFACE: &str = "org.mpris.MediaPlayer2.Player";
pub const ROOT_INTERFACE: &str = "org.mpris.MediaPlayer2";
pub const OBJECT_PATH: &str = "/org/mpris/MediaPlayer2";
pub const BUS_PREFIX: &str = "org.mpris.MediaPlayer2.";

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Snapshot {
    pub playing: bool,
    pub paused: bool,
    pub title: Option<String>,
    pub artists: Vec<String>,
    pub album: Option<String>,
    pub length_us: Option<i64>,
    pub art_url: Option<String>,
    pub track_id: Option<String>,
    pub position_us: Option<i64>,
    pub rate: f64,
    /// The root interface's `DesktopEntry`: the id of the desktop file that
    /// names the application and gives its icon.
    pub desktop_entry: Option<String>,
    /// The root interface's `Identity`: the player's own name for itself.
    pub identity: Option<String>,
}

/// What the player's desktop file says, once looked up: its name, and its
/// icon as the artwork store's id.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct AppFacts {
    pub name: Option<String>,
    pub icon_id: Option<String>,
}

fn int(value: &Value<'_>) -> Option<i64> {
    match value {
        Value::I64(v) => Some(*v),
        Value::U64(v) => i64::try_from(*v).ok(),
        Value::I32(v) => Some(i64::from(*v)),
        Value::U32(v) => Some(i64::from(*v)),
        Value::I16(v) => Some(i64::from(*v)),
        Value::U16(v) => Some(i64::from(*v)),
        Value::F64(v) => Some(*v as i64),
        Value::Value(inner) => int(inner),
        _ => None,
    }
}

fn float(value: &Value<'_>) -> Option<f64> {
    match value {
        Value::F64(v) => Some(*v),
        Value::Value(inner) => float(inner),
        other => int(other).map(|v| v as f64),
    }
}

fn text(value: &Value<'_>) -> Option<String> {
    match value {
        Value::Str(s) => Some(s.to_string()),
        Value::ObjectPath(p) => Some(p.to_string()),
        Value::Value(inner) => text(inner),
        _ => None,
    }
}

fn strings(value: &Value<'_>) -> Vec<String> {
    match value {
        Value::Array(array) => array.iter().filter_map(text).filter(|t| !t.trim().is_empty()).collect(),
        Value::Value(inner) => strings(inner),
        other => text(other).into_iter().filter(|t| !t.trim().is_empty()).collect(),
    }
}

fn dict_get<'a>(value: &'a Value<'a>, wanted: &str) -> Option<&'a Value<'a>> {
    match value {
        Value::Dict(dict) => dict.iter().find_map(|(k, v)| (text(k).as_deref() == Some(wanted)).then_some(v)),
        Value::Value(inner) => dict_get(inner, wanted),
        _ => None,
    }
}

impl Snapshot {
    /// From `GetAll` of the player interface, and of the root interface for the name.
    pub fn from_properties(player: &HashMap<String, OwnedValue>, root: &HashMap<String, OwnedValue>) -> Self {
        let get = |key: &str| player.get(key).map(|v| &**v);
        let status = get("PlaybackStatus").and_then(text).unwrap_or_default();
        let meta = get("Metadata");
        let from_meta = |key: &str| meta.and_then(|m| dict_get(m, key));
        let title = from_meta("xesam:title").and_then(text).filter(|t| !t.trim().is_empty());
        Self {
            playing: status == "Playing",
            paused: status == "Paused",
            title,
            artists: from_meta("xesam:artist").map(strings).unwrap_or_default(),
            album: from_meta("xesam:album").and_then(text).filter(|t| !t.is_empty()),
            length_us: from_meta("mpris:length").and_then(int).filter(|l| *l > 0),
            art_url: from_meta("mpris:artUrl").and_then(text).filter(|t| !t.is_empty()),
            track_id: from_meta("mpris:trackid").and_then(text),
            position_us: get("Position").and_then(int),
            rate: get("Rate").and_then(float).unwrap_or(1.0),
            desktop_entry: root.get("DesktopEntry").and_then(|v| text(v)).filter(|t| !t.trim().is_empty()),
            identity: root.get("Identity").and_then(|v| text(v)).filter(|t| !t.trim().is_empty()),
        }
    }

    /// Whether the player has anything loaded at all.
    pub fn has_track(&self) -> bool {
        self.title.is_some()
    }

    /// The track as the Module knows it. `artwork` is whatever stands for the
    /// cover (the store's id, as bytes); `app` what the desktop file said;
    /// `sampled` is when the position was read.
    ///
    /// `player` is the raw id (`DesktopEntry`, else `Identity`, else the bus
    /// name's tail); `player_name` is what a person reads: the desktop file's
    /// name, else `Identity`, else nothing (the page then says "Played at").
    pub fn now_playing(&self, bus_name: &str, artwork: Option<Vec<u8>>, app: Option<&AppFacts>, sampled: DateTime<Utc>) -> Option<NowPlaying> {
        let title = self.title.clone()?;
        let artist = (!self.artists.is_empty()).then(|| self.artists.join(", "));
        let id = self
            .desktop_entry
            .as_deref()
            .or(self.identity.as_deref())
            .unwrap_or_else(|| bus_name.strip_prefix(BUS_PREFIX).unwrap_or(bus_name));
        let mut track = NowPlaying::new(title, artist.as_deref(), Some(id), self.playing);
        track.player_name = app.and_then(|a| a.name.clone()).or_else(|| self.identity.clone());
        track.icon_id = app.and_then(|a| a.icon_id.clone());
        track.album = self.album.clone();
        track.duration = self.length_us.map(|l| l as f64 / 1e6);
        track.elapsed = self.position_us.map(|p| (p.max(0)) as f64 / 1e6);
        track.elapsed_at = Some(sampled);
        track.rate = Some(if self.playing { self.rate } else { 0.0 });
        track.artwork = artwork;
        Some(track)
    }
}

/// One player on the bus, as the chooser sees it.
#[derive(Debug, Clone, PartialEq)]
pub struct Player {
    pub bus_name: String,
    pub snapshot: Snapshot,
    /// Counts up each time the player's state changes: the most recently
    /// active has the highest.
    pub activity: u64,
}

/// The player a person would see in the system's media controls: one that is
/// playing (the most recently active, if several), else the most recently
/// active that has a track loaded. `None` is nothing loaded anywhere.
pub fn current(players: &[Player]) -> Option<&Player> {
    let loaded = || players.iter().filter(|p| p.snapshot.has_track());
    loaded()
        .filter(|p| p.snapshot.playing)
        .max_by_key(|p| p.activity)
        .or_else(|| loaded().max_by_key(|p| p.activity))
}

/// A bus name that is a player.
pub fn is_player(bus_name: &str) -> bool {
    bus_name.starts_with(BUS_PREFIX)
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;
    use zbus::zvariant::{Array, Dict, ObjectPath, Signature};

    fn owned<'a>(v: impl Into<Value<'a>>) -> OwnedValue {
        v.into().try_to_owned().unwrap()
    }

    fn metadata_value(entries: Vec<(&str, Value<'static>)>) -> OwnedValue {
        let mut dict = Dict::new(&Signature::Str, &Signature::Variant);
        for (k, v) in entries {
            dict.append(Value::from(k), Value::Value(Box::new(v))).unwrap();
        }
        owned(Value::Dict(dict))
    }

    fn artist(names: &[&str]) -> Value<'static> {
        let mut array = Array::new(&Signature::Str);
        for n in names {
            array.append(Value::from(n.to_string())).unwrap();
        }
        Value::Array(array)
    }

    fn props(status: &str, title: Option<&str>, extra: Vec<(&str, Value<'static>)>) -> HashMap<String, OwnedValue> {
        let mut entries = vec![("mpris:trackid", Value::ObjectPath(ObjectPath::try_from("/org/test/1").unwrap().into_owned()))];
        if let Some(t) = title {
            entries.push(("xesam:title", Value::from(t.to_string())));
        }
        entries.extend(extra);
        HashMap::from([
            ("PlaybackStatus".into(), owned(status.to_string())),
            ("Metadata".into(), metadata_value(entries)),
            ("Position".into(), owned(46_000_000i64)),
            ("Rate".into(), owned(1.0f64)),
        ])
    }

    fn root(identity: &str, desktop: Option<&str>) -> HashMap<String, OwnedValue> {
        let mut r = HashMap::from([("Identity".to_string(), owned(identity.to_string()))]);
        if let Some(d) = desktop {
            r.insert("DesktopEntry".into(), owned(d.to_string()));
        }
        r
    }

    #[test]
    fn a_players_properties_become_a_snapshot() {
        let p = props(
            "Playing",
            Some("Mad Technology"),
            vec![
                ("xesam:artist", artist(&["CZARFACE", "Method Man"])),
                ("xesam:album", Value::from("Czarmageddon!".to_string())),
                ("mpris:length", Value::I64(224_000_000)),
                ("mpris:artUrl", Value::from("file:///tmp/a%20b.png".to_string())),
            ],
        );
        let s = Snapshot::from_properties(&p, &root("Chromium", Some("yandex-browser")));
        assert!(s.playing && !s.paused && s.has_track());
        assert_eq!(s.title.as_deref(), Some("Mad Technology"));
        assert_eq!(s.artists, ["CZARFACE", "Method Man"]);
        assert_eq!(s.album.as_deref(), Some("Czarmageddon!"));
        assert_eq!(s.length_us, Some(224_000_000));
        assert_eq!(s.position_us, Some(46_000_000));
        assert_eq!(s.track_id.as_deref(), Some("/org/test/1"));
        assert_eq!(s.desktop_entry.as_deref(), Some("yandex-browser"));
        assert_eq!(s.identity.as_deref(), Some("Chromium"));
        let t = Utc.timestamp_opt(1_800_000_000, 0).unwrap();
        let app = AppFacts { name: Some("Yandex Browser".into()), icon_id: Some("abc".into()) };
        let np = s.now_playing("org.mpris.MediaPlayer2.chromium.instance1", Some(b"id".to_vec()), Some(&app), t).unwrap();
        assert_eq!(np.player.as_deref(), Some("yandex-browser"), "the raw id, for the icon");
        assert_eq!(np.player_name.as_deref(), Some("Yandex Browser"), "the desktop file names it, over the identity");
        assert_eq!(np.icon_id.as_deref(), Some("abc"));
        let bare = s.now_playing("org.mpris.MediaPlayer2.chromium.instance1", None, None, t).unwrap();
        assert_eq!(bare.player_name.as_deref(), Some("Chromium"), "no desktop file: the identity");
        assert_eq!(bare.icon_id, None);
        assert_eq!((np.title.as_str(), np.artist.as_deref(), np.is_playing), ("Mad Technology", Some("CZARFACE, Method Man"), true));
        assert_eq!((np.duration, np.elapsed, np.elapsed_at, np.rate), (Some(224.0), Some(46.0), Some(t), Some(1.0)));
        assert_eq!(np.artwork.as_deref(), Some(&b"id"[..]));
    }

    #[test]
    fn an_empty_artist_is_no_artist() {
        let p = props("Playing", Some("T"), vec![("xesam:artist", artist(&[""]))]);
        let s = Snapshot::from_properties(&p, &root("X", None));
        assert!(s.artists.is_empty());
        assert_eq!(s.now_playing("org.mpris.MediaPlayer2.x", None, None, Utc::now()).unwrap().artist, None);
    }

    #[test]
    fn other_integer_widths_and_a_string_track_id_read_too() {
        let p = props("Paused", Some("Zima"), vec![("mpris:length", Value::U64(100_000_000)), ("mpris:trackid", Value::from("/x/y".to_string()))]);
        let s = Snapshot::from_properties(&p, &root("Rhythmbox", None));
        assert!(s.paused && !s.playing);
        assert_eq!(s.length_us, Some(100_000_000));
        assert_eq!(s.track_id.as_deref(), Some("/x/y"));
        assert_eq!((s.desktop_entry.as_deref(), s.identity.as_deref()), (None, Some("Rhythmbox")));
        let np = s.now_playing("org.mpris.MediaPlayer2.rb", None, None, Utc::now()).unwrap();
        assert_eq!((np.player.as_deref(), np.player_name.as_deref()), (Some("Rhythmbox"), Some("Rhythmbox")), "no desktop entry: the identity");
        assert_eq!(np.rate, Some(0.0), "a paused track does not move on");
    }

    #[test]
    fn a_player_with_no_title_has_nothing_loaded() {
        let s = Snapshot::from_properties(&props("Stopped", None, vec![]), &root("X", None));
        assert!(!s.has_track());
        assert!(s.now_playing("org.mpris.MediaPlayer2.x", None, None, Utc::now()).is_none());
        let blank = Snapshot::from_properties(&props("Playing", Some("  "), vec![]), &root("X", None));
        assert!(!blank.has_track(), "a blank title is no title");
    }

    #[test]
    fn a_bare_bus_name_stands_for_the_player_when_nothing_else_does() {
        let s = Snapshot::from_properties(&props("Playing", Some("T"), vec![]), &HashMap::new());
        let np = s.now_playing("org.mpris.MediaPlayer2.vlc", None, None, Utc::now()).unwrap();
        assert_eq!(np.player.as_deref(), Some("vlc"));
        assert_eq!(np.player_name, None, "and no name to read: the page says only when it played");
    }

    fn player(name: &str, playing: bool, title: Option<&str>, activity: u64) -> Player {
        Player {
            bus_name: format!("org.mpris.MediaPlayer2.{name}"),
            snapshot: Snapshot { playing, paused: !playing && title.is_some(), title: title.map(str::to_owned), rate: 1.0, ..Snapshot::default() },
            activity,
        }
    }

    #[test]
    fn the_playing_player_is_the_current_one_and_the_latest_wins_among_several() {
        let players = [player("a", false, Some("A"), 9), player("b", true, Some("B"), 2), player("c", true, Some("C"), 5)];
        assert_eq!(current(&players).unwrap().bus_name, "org.mpris.MediaPlayer2.c");
    }

    #[test]
    fn with_nothing_playing_the_latest_loaded_one_stands_and_empty_ones_do_not() {
        let players = [player("a", false, Some("A"), 3), player("b", false, Some("B"), 7), player("c", false, None, 99)];
        assert_eq!(current(&players).unwrap().bus_name, "org.mpris.MediaPlayer2.b");
        assert!(current(&[player("c", false, None, 1)]).is_none());
        assert!(current(&[]).is_none());
    }

    #[test]
    fn only_mpris_names_are_players() {
        assert!(is_player("org.mpris.MediaPlayer2.vlc"));
        assert!(!is_player("org.freedesktop.Notifications"));
    }
}
