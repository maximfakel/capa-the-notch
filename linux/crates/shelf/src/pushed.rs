//! A clipboard that is told what it holds, rather than asked.
//!
//! GNOME on Wayland lets no background program read the clipboard — there is
//! no data-control protocol in mutter — but the Shell itself can, so the
//! extension watches it and pushes what changed. The same shape serves any host
//! that has to do the reading (a test, say): `ClipboardSource` over
//! the last thing pushed.

use capa_core::shelf::ClipboardSource;
use serde::Deserialize;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Mutex;

/// One look at the clipboard, as the host that read it reports it. Every type
/// name is already canonical (`take::canonical`) or a marker named as the
/// platform names it.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ClipboardPush {
    /// A number that changes whenever the clipboard does.
    pub count: u64,
    /// The application in front: a desktop-file id or a window class.
    pub frontmost: Option<String>,
    /// Each item's type identifiers (MIME types on Linux), as the host saw them.
    pub types: Vec<Vec<String>>,
    /// The text, when it was wanted and there was some.
    pub text: Option<String>,
    /// The first file the clipboard points at.
    pub file_path: Option<String>,
    /// Bytes by type, base64, for the types the host was asked to read.
    pub data: HashMap<String, String>,
    /// Types the host would not send, being too large for the bus. Not a
    /// refusal: they are taken as not offered, so nothing is read or reported.
    pub too_large: Vec<String>,
}

#[derive(Default)]
pub struct PushedClipboard {
    last: Mutex<ClipboardPush>,
}

impl PushedClipboard {
    pub fn push(&self, push: ClipboardPush) {
        *self.last.lock().unwrap() = push;
    }
}

impl ClipboardSource for PushedClipboard {
    fn change_count(&self) -> u64 {
        self.last.lock().unwrap().count
    }

    fn frontmost_application(&self) -> Option<String> {
        self.last.lock().unwrap().frontmost.clone()
    }

    fn item_types(&self) -> Vec<Vec<String>> {
        let last = self.last.lock().unwrap();
        last.types
            .iter()
            .map(|item| {
                item.iter()
                    .filter(|t| !last.too_large.contains(t))
                    .map(|t| capa_core::shelf::canonical::linux(t))
                    .collect()
            })
            .collect()
    }

    fn text(&self) -> Option<String> {
        self.last.lock().unwrap().text.clone()
    }

    fn file_path(&self) -> Option<PathBuf> {
        self.last.lock().unwrap().file_path.clone().map(PathBuf::from)
    }

    fn data(&self, type_identifier: &str) -> Option<Vec<u8>> {
        use base64::Engine;
        let last = self.last.lock().unwrap();
        // The host sends bytes under the type it saw; the rules ask by the canonical one.
        let wanted = last
            .data
            .iter()
            .find(|(mime, _)| capa_core::shelf::canonical::linux(mime) == type_identifier)?;
        base64::engine::general_purpose::STANDARD.decode(wanted.1).ok()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn it_reports_what_it_was_told_under_the_canonical_names() {
        let board = PushedClipboard::default();
        board.push(ClipboardPush {
            count: 4,
            frontmost: Some("org.gnome.Terminal".into()),
            types: vec![vec!["text/plain;charset=utf-8".into(), "x-kde-passwordManagerHint".into()]],
            text: Some("hello".into()),
            data: HashMap::from([("image/png".to_owned(), "aGk=".to_owned())]),
            ..Default::default()
        });
        assert_eq!(board.change_count(), 4);
        assert_eq!(board.frontmost_application().as_deref(), Some("org.gnome.Terminal"));
        let types = board.item_types();
        assert!(types[0].contains(&"public.utf8-plain-text".to_string()), "{types:?}");
        assert!(types[0].contains(&"x-kde-passwordManagerHint".to_string()), "a marker is found by its own name");
        assert_eq!(board.text().as_deref(), Some("hello"));
        assert_eq!(board.data("public.png"), Some(b"hi".to_vec()));
        assert_eq!(board.data("public.tiff"), None);
    }

    #[test]
    fn what_was_never_pushed_is_nothing() {
        let board = PushedClipboard::default();
        assert_eq!(board.change_count(), 0);
        assert!(board.item_types().is_empty());
        assert_eq!(board.text(), None);
        assert_eq!(board.file_path(), None);
    }
}
