use super::b64;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

/// What the system reports as playing, from whichever application plays it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NowPlaying {
    pub title: String,
    pub artist: Option<String>,
    pub album: Option<String>,
    /// The application playing it, when known: a bundle identifier on macOS,
    /// an MPRIS bus name or desktop-file id on Linux. Surfaces turn it into a
    /// name and an icon.
    pub player: Option<String>,
    /// The application's name as a person knows it, when the source can tell
    /// (Linux: the desktop file's localized `Name=`, else MPRIS `Identity`).
    /// A surface that resolves `player` itself (macOS) leaves it empty.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub player_name: Option<String>,
    /// The application's icon, as the id a surface fetches the picture by (Linux:
    /// the artwork store's), when the source found one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub icon_id: Option<String>,
    pub is_playing: bool,
    pub duration: Option<f64>,
    /// The position `elapsed_at`; it moves on from there at `rate`.
    pub elapsed: Option<f64>,
    pub elapsed_at: Option<DateTime<Utc>>,
    pub rate: Option<f64>,
    /// The cover, as the bytes of an image file (base64 in JSON).
    #[serde(default, with = "b64::serde_artwork", skip_serializing_if = "Option::is_none")]
    pub artwork: Option<Vec<u8>>,
}

impl NowPlaying {
    pub fn new(title: impl Into<String>, artist: Option<&str>, player: Option<&str>, is_playing: bool) -> Self {
        Self {
            title: title.into(),
            artist: artist.map(str::to_owned),
            album: None,
            player: player.map(str::to_owned),
            player_name: None,
            icon_id: None,
            is_playing,
            duration: None,
            elapsed: None,
            elapsed_at: None,
            rate: None,
            artwork: None,
        }
    }

    pub(crate) fn with_artwork(&self, artwork: Option<Vec<u8>>) -> Self {
        Self { artwork, ..self.clone() }
    }

    pub(crate) fn with_playing(&self, is_playing: bool) -> Self {
        Self { is_playing, ..self.clone() }
    }

    /// Where in the track it is now: the reported position, moved on at the
    /// reported rate, and never outside the track.
    pub fn position(&self, now: DateTime<Utc>) -> Option<f64> {
        let elapsed = self.elapsed?;
        let moved = self
            .elapsed_at
            .map(|at| seconds_between(at, now) * self.rate.unwrap_or(0.0))
            .unwrap_or(0.0);
        let position = (elapsed + moved).max(0.0);
        Some(self.duration.map_or(position, |d| position.min(d)))
    }
}

pub(crate) fn seconds_between(from: DateTime<Utc>, to: DateTime<Utc>) -> f64 {
    (to - from).num_microseconds().map_or_else(|| (to - from).num_seconds() as f64, |us| us as f64 / 1e6)
}

/// One observation of Now Playing: a track, or nothing loaded at all.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", content = "track", rename_all = "camelCase")]
// Swift's enum, as it is: a reading comes a few times a second, not worth a box.
#[allow(clippy::large_enum_variant)]
pub enum NowPlayingReading {
    Nothing,
    Item(NowPlaying),
}

/// Follows mediaremote-adapter's `stream`, one line at a time (macOS).
///
/// Each line is `{"type":"data","diff":…,"payload":{…}}`. A full payload is
/// the whole state, and an empty one is nothing playing; a diff carries only
/// what changed, with `null` for a key that went away — the artwork, for one,
/// arrives on its own after the track. A line the adapter did not write is not
/// a reading: it changes nothing, and is never shown as nothing playing.
///
/// The adapter also sends a full payload without the artwork and the artwork
/// again as a diff, for a track it already reported. So a full payload for the
/// same content item keeps the artwork it had, rather than blinking it out;
/// a new track does not inherit the last one's.
#[derive(Debug, Default)]
pub struct NowPlayingStream {
    fields: Map<String, Value>,
}

impl NowPlayingStream {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn apply(&mut self, line: &str) -> Option<NowPlayingReading> {
        let object: Value = serde_json::from_str(line).ok()?;
        let object = object.as_object()?;
        if object.get("type")?.as_str()? != "data" {
            return None;
        }
        let diff = object.get("diff")?.as_bool()?;
        let payload = object.get("payload")?.as_object()?;

        if diff {
            for (key, value) in payload {
                if value.is_null() {
                    self.fields.remove(key);
                } else {
                    self.fields.insert(key.clone(), value.clone());
                }
            }
        } else {
            let mut replaced: Map<String, Value> =
                payload.iter().filter(|(_, v)| !v.is_null()).map(|(k, v)| (k.clone(), v.clone())).collect();
            let id = replaced.get("contentItemIdentifier").and_then(Value::as_str);
            let same_item = id.is_some() && id == self.fields.get("contentItemIdentifier").and_then(Value::as_str);
            if same_item && !replaced.contains_key("artworkData") {
                for key in ["artworkData", "artworkMimeType"] {
                    if let Some(kept) = self.fields.get(key) {
                        replaced.insert(key.into(), kept.clone());
                    }
                }
            }
            self.fields = replaced;
        }
        Some(self.reading())
    }

    fn reading(&self) -> NowPlayingReading {
        let text = |key: &str| {
            self.fields.get(key).and_then(Value::as_str).filter(|t| !t.is_empty()).map(str::to_owned)
        };
        let number = |key: &str| self.fields.get(key).and_then(Value::as_f64);

        let Some(title) = self.fields.get("title").and_then(Value::as_str).filter(|t| !t.is_empty()) else {
            return NowPlayingReading::Nothing;
        };
        // `as? Bool` in Foundation also takes the numbers 0 and 1.
        let playing = match self.fields.get("playing") {
            Some(Value::Bool(b)) => *b,
            Some(Value::Number(n)) => n.as_i64().is_some_and(|n| n == 1),
            _ => false,
        };
        NowPlayingReading::Item(NowPlaying {
            title: title.to_owned(),
            artist: text("artist"),
            album: text("album"),
            player: text("parentApplicationBundleIdentifier").or_else(|| text("bundleIdentifier")),
            player_name: None,
            icon_id: None,
            is_playing: playing,
            duration: number("duration"),
            elapsed: number("elapsedTime"),
            elapsed_at: text("timestamp")
                .and_then(|t| DateTime::parse_from_rfc3339(&t).ok())
                .map(|d| d.with_timezone(&Utc)),
            rate: number("playbackRate"),
            artwork: text("artworkData").and_then(|t| b64::decode(&t)),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    const FULL: &str = r#"{"type":"data","diff":false,"payload":{"title":"Mad Technology","artist":"CZARFACE","album":"Czarface Meets Metal Face","bundleIdentifier":"com.google.Chrome","playing":true,"duration":224.0,"elapsedTime":46.0,"playbackRate":1,"timestamp":"2026-09-24T02:00:00Z"}}"#;

    fn item(r: Option<NowPlayingReading>) -> NowPlaying {
        match r {
            Some(NowPlayingReading::Item(i)) => i,
            other => panic!("expected a track, got {other:?}"),
        }
    }

    #[test]
    fn a_full_line_from_the_adapter_says_what_is_playing() {
        let mut stream = NowPlayingStream::new();
        let i = item(stream.apply(FULL));
        assert!(i.title == "Mad Technology" && i.artist.as_deref() == Some("CZARFACE"));
        assert!(i.player.as_deref() == Some("com.google.Chrome") && i.is_playing);
        assert!(i.duration == Some(224.0) && i.elapsed == Some(46.0) && i.rate == Some(1.0));
        assert_eq!(i.elapsed_at, Utc.with_ymd_and_hms(2026, 9, 24, 2, 0, 0).single(), "as of when");
        assert_eq!(
            stream.apply(r#"{"type":"data","diff":false,"payload":{}}"#),
            Some(NowPlayingReading::Nothing),
            "an empty full payload is nothing playing"
        );
    }

    #[test]
    fn a_diff_line_updates_the_last_full_one() {
        let mut stream = NowPlayingStream::new();
        stream.apply(FULL);
        let artwork = b64::encode(b"artwork");
        let with_artwork = item(stream.apply(&format!(
            r#"{{"type":"data","diff":true,"payload":{{"artworkData":"{artwork}","artworkMimeType":"image/jpeg"}}}}"#
        )));
        assert_eq!(with_artwork.title, "Mad Technology", "the artwork arrives on its own and the track stays");
        assert_eq!(with_artwork.artwork.as_deref(), Some(&b"artwork"[..]));

        let paused = item(stream.apply(r#"{"type":"data","diff":true,"payload":{"playing":false,"artist":null}}"#));
        assert!(!paused.is_playing, "a diff can pause it");
        assert_eq!(paused.artist, None, "a key set to null is gone");
        assert_eq!(paused.artwork.as_deref(), Some(&b"artwork"[..]), "what the diff does not mention is kept");
    }

    #[test]
    fn the_artwork_outlives_a_full_line_for_the_same_track_only() {
        let artwork = b64::encode(b"cover");
        let full = |id: &str, title: &str| {
            format!(r#"{{"type":"data","diff":false,"payload":{{"title":"{title}","contentItemIdentifier":"{id}","playing":true}}}}"#)
        };
        let mut stream = NowPlayingStream::new();
        stream.apply(&full("a", "Mad Technology"));
        stream.apply(&format!(r#"{{"type":"data","diff":true,"payload":{{"artworkData":"{artwork}"}}}}"#));

        let same = item(stream.apply(&full("a", "Mad Technology")));
        assert_eq!(same.artwork.as_deref(), Some(&b"cover"[..]), "the same track keeps its artwork, rather than blinking");
        let next = item(stream.apply(&full("b", "Something Else")));
        assert_eq!(next.artwork, None, "a new track does not wear the last one's artwork");
    }

    #[test]
    fn the_position_moves_on_from_when_it_was_reported() {
        let reported = Utc.timestamp_opt(1_800_000_000, 0).unwrap();
        let after = |s: i64| reported + chrono::Duration::seconds(s);
        let mut playing = NowPlaying::new("Mad Technology", None, None, true);
        playing.duration = Some(224.0);
        playing.elapsed = Some(46.0);
        playing.elapsed_at = Some(reported);
        playing.rate = Some(1.0);
        assert_eq!(playing.position(after(10)), Some(56.0), "ten seconds on, at normal speed");
        assert_eq!(playing.position(after(500)), Some(224.0), "never past the end");

        let mut paused = playing.with_playing(false);
        paused.rate = Some(0.0);
        assert_eq!(paused.position(after(10)), Some(46.0), "paused, it stays where it stopped");

        let unknown = NowPlaying::new("Live", None, None, true);
        assert_eq!(unknown.position(reported), None, "without a reported position there is none to show");
    }

    #[test]
    fn a_line_the_adapter_did_not_write_is_not_a_reading() {
        let mut stream = NowPlayingStream::new();
        stream.apply(FULL);
        for line in [
            "",
            "not json",
            r#"{"type":"data","payload":{}}"#,
            r#"{"type":"other","diff":false,"payload":{}}"#,
            "[1,2,3]",
        ] {
            assert_eq!(stream.apply(line), None, "{line:?} must not read as nothing playing");
        }
        let i = item(stream.apply(r#"{"type":"data","diff":true,"payload":{}}"#));
        assert_eq!(i.title, "Mad Technology", "lines that were not readings changed nothing");
    }

    /// A track playing in a browser tab is reported by WebKit's GPU process,
    /// on behalf of the browser: the browser is the player a person knows.
    #[test]
    fn a_track_in_a_browser_tab_is_the_browsers() {
        let mut stream = NowPlayingStream::new();
        let i = item(stream.apply(
            r#"{"type":"data","diff":false,"payload":{"title":"Zima","bundleIdentifier":"com.apple.WebKit.GPU","parentApplicationBundleIdentifier":"com.officecommun.search","playing":true}}"#,
        ));
        assert_eq!(i.player.as_deref(), Some("com.officecommun.search"));
    }

    #[test]
    fn artwork_travels_to_surfaces_as_base64_text() {
        let mut track = NowPlaying::new("Zima", Some("annushkaa"), None, true);
        assert!(!serde_json::to_string(&track).unwrap().contains("artwork"), "no cover, no key");
        track.artwork = Some(vec![1, 2, 3]);
        let json = serde_json::to_value(&track).unwrap();
        assert_eq!(json["artwork"], "AQID");
        assert_eq!(json["isPlaying"], true);
        assert_eq!(serde_json::from_value::<NowPlaying>(json).unwrap(), track);
    }
}
