//! The clipboard through `wl-paste`, for Wayland compositors that give a
//! background program the data-control protocol (wlroots, KDE, COSMIC). GNOME
//! does not — there the Shell extension pushes what it sees (`pushed`) — and
//! `wl-paste` under GNOME would put up a window that takes the focus, so it is
//! never used there.

use capa_core::shelf::{canonical, ClipboardSource};
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::path::PathBuf;
use std::process::{Command, Stdio};

pub struct WlPaste;

fn wl_paste(args: &[&str]) -> Option<Vec<u8>> {
    let out = Command::new("wl-paste").args(args).stdin(Stdio::null()).stderr(Stdio::null()).output().ok()?;
    out.status.success().then_some(out.stdout)
}

impl WlPaste {
    /// Whether `wl-paste` can be used here: a Wayland session that is not
    /// GNOME's, with the tool installed and a clipboard it can read.
    pub fn available() -> bool {
        let wayland = std::env::var("XDG_SESSION_TYPE").is_ok_and(|s| s == "wayland") || std::env::var_os("WAYLAND_DISPLAY").is_some();
        let gnome = std::env::var("XDG_CURRENT_DESKTOP").is_ok_and(|d| d.to_ascii_uppercase().contains("GNOME"));
        wayland && !gnome && wl_paste(&["--list-types"]).is_some()
    }

    fn types() -> Vec<String> {
        wl_paste(&["--list-types"])
            .map(|b| String::from_utf8_lossy(&b).lines().map(str::to_owned).filter(|l| !l.is_empty()).collect())
            .unwrap_or_default()
    }
}

impl ClipboardSource for WlPaste {
    /// No counter is offered, so one is made of the kinds on the clipboard and
    /// the start of its text.
    fn change_count(&self) -> u64 {
        let mut hasher = DefaultHasher::new();
        let types = Self::types();
        types.hash(&mut hasher);
        if types.iter().any(|t| t.starts_with("text/plain")) {
            if let Some(text) = wl_paste(&["--no-newline", "--type", "text/plain"]) {
                text.len().hash(&mut hasher);
                text[..text.len().min(4096)].hash(&mut hasher);
            }
        }
        hasher.finish()
    }

    /// Nothing portable says which window is in front on these compositors.
    fn frontmost_application(&self) -> Option<String> {
        None
    }

    fn item_types(&self) -> Vec<Vec<String>> {
        vec![Self::types().iter().map(|t| canonical::linux(t)).collect()]
    }

    fn text(&self) -> Option<String> {
        String::from_utf8(wl_paste(&["--no-newline", "--type", "text/plain"])?).ok()
    }

    fn file_path(&self) -> Option<PathBuf> {
        let list = String::from_utf8(wl_paste(&["--type", "text/uri-list"])?).ok()?;
        let uri = list.lines().find(|l| l.starts_with("file://"))?;
        Some(PathBuf::from(percent_decode(uri.trim_start_matches("file://"))))
    }

    fn data(&self, type_identifier: &str) -> Option<Vec<u8>> {
        let mime = match type_identifier {
            "public.png" => "image/png",
            "public.jpeg" => "image/jpeg",
            "public.tiff" => "image/tiff",
            "com.compuserve.gif" => "image/gif",
            "org.webmproject.webp" => "image/webp",
            other => other,
        };
        wl_paste(&["--type", mime])
    }
}

fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            if let Some(v) = s.get(i + 1..i + 3).and_then(|h| u8::from_str_radix(h, 16).ok()) {
                out.push(v);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_uri_is_decoded_to_a_path() {
        assert_eq!(percent_decode("/home/a/My%20File%D1%8F.png"), "/home/a/My Fileя.png");
        assert_eq!(percent_decode("/a%"), "/a%");
        assert_eq!(percent_decode("/a%zz"), "/a%zz");
    }
}
