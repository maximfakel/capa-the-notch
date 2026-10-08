//! The parts of Dictation only a surface can do, done by the surface.
//!
//! The global shortcut (hold *and* release), the application in front, the
//! clipboard and the synthetic paste all belong to the desktop, and on GNOME
//! under Wayland a client cannot do any of them: the compositor's own process
//! — the shell extension — can. So the hub asks, by events, and the host
//! answers by commands; this is the one place that knows the conversation.
//!
//! Hub → host (`ModuleEvent` on `dictation`):
//!   `register`  `{shortcut: KeyShortcut|null, accelerator, evdev, escape: bool}`
//!                                                              grab (or let go of) the keys
//!   `copy`      `{text}`                                       put it on the clipboard as our own
//!   `insert`    `{token, text, target}`                        verify `target` is still in front,
//!                                                              paste, then answer `inserted`
//!   `end_hold`  `{}`                                           the session ended without the key
//!                                                              (the system is going to sleep):
//!                                                              stop waiting for its release
//! Host → hub (`call("dictation", …)`):
//!   `host_ready {insert: bool}`    what this host can do; sent when it connects
//!   `hotkey_pressed {target}`      the shortcut went down; `target` is what is in front now
//!   `hotkey_released` / `escape_pressed`
//!   `shortcut_registered {ok}`     the answer to `register`
//!   `inserted {token, message}`    the answer to `insert`: `message` null when the text went in

use capa_core::dictation::{
    ClipboardWriter, GlobalHotKey, HotKeyHandler, TextInserter, NO_EXTERNAL_APPLICATION, PASTE_FAILED,
    TARGET_NOT_ACTIVE,
};
use capa_core::prefs::KeyShortcut;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{self, Sender};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// What was in front when the shortcut went down.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Target {
    /// The application: its name or id, for the log's sake never the text.
    pub app: String,
    /// The window, as the host names it; the same one must be in front at insertion.
    pub window: String,
    /// A password field is never a target.
    #[serde(default)]
    pub secure: bool,
    /// Whether it is this application itself in front.
    #[serde(default)]
    pub own: bool,
}

type Emit = Arc<dyn Fn(&str, Value) + Send + Sync>;

#[derive(Default)]
struct Inner {
    insert_capable: bool,
    target: Option<Target>,
    registered: Option<KeyShortcut>,
    escape: bool,
    waiting: HashMap<u64, Sender<Option<String>>>,
    /// The last thing Dictation put on the clipboard, so the Shelf can leave it out.
    last_copy: Option<String>,
}

/// One bridge per hub, shared between the driver and the module.
#[derive(Clone)]
pub struct Bridge {
    inner: Arc<Mutex<Inner>>,
    emit: Emit,
    next_token: Arc<AtomicU64>,
    /// How long an insertion is waited for.
    pub timeout: Duration,
}

impl Bridge {
    pub fn new(emit: Emit) -> Self {
        Self {
            inner: Arc::new(Mutex::new(Inner::default())),
            emit,
            next_token: Arc::new(AtomicU64::new(1)),
            timeout: Duration::from_secs(3),
        }
    }

    pub fn host_ready(&self, insert: bool) {
        self.inner.lock().unwrap().insert_capable = insert;
    }

    /// Whether a host that can paste is connected.
    pub fn insertion_allowed_now(&self) -> bool {
        self.inner.lock().unwrap().insert_capable
    }

    pub fn set_target(&self, target: Option<Target>) {
        self.inner.lock().unwrap().target = target;
    }

    /// What the host was last asked to grab: for state, so a host that connects later knows.
    pub fn registration(&self) -> (Option<KeyShortcut>, bool) {
        let i = self.inner.lock().unwrap();
        (i.registered.clone(), i.escape)
    }

    pub fn last_copy(&self) -> Option<String> {
        self.inner.lock().unwrap().last_copy.clone()
    }

    /// The host's answer to `insert`.
    pub fn inserted(&self, token: u64, message: Option<String>) {
        if let Some(waiting) = self.inner.lock().unwrap().waiting.remove(&token) {
            let _ = waiting.send(message);
        }
    }

    /// Tells the host the held key is no longer wanted: its release is not waited for.
    pub fn end_hold(&self) {
        (self.emit)("end_hold", json!({}));
    }

    fn announce_registration(&self) {
        let (shortcut, escape) = self.registration();
        let accelerator = shortcut.as_ref().and_then(KeyShortcut::accelerator);
        let evdev = shortcut.as_ref().and_then(KeyShortcut::linux_evdev);
        (self.emit)("register", json!({ "shortcut": shortcut, "accelerator": accelerator, "evdev": evdev, "escape": escape }));
    }
}

impl TextInserter for Bridge {
    fn capture(&mut self) -> Result<(), String> {
        let i = self.inner.lock().unwrap();
        match &i.target {
            // A password field is never a target; the sentence is the same as for none.
            Some(t) if !t.own && !t.secure => Ok(()),
            _ => Err(NO_EXTERNAL_APPLICATION.to_owned()),
        }
    }

    fn insert(&mut self, text: &str) -> Option<String> {
        let (token, rx, target) = {
            let mut i = self.inner.lock().unwrap();
            if !i.insert_capable {
                // Nothing here can paste: the text stays on the clipboard.
                return Some(PASTE_FAILED.to_owned());
            }
            let Some(target) = i.target.clone() else { return Some(NO_EXTERNAL_APPLICATION.to_owned()) };
            let token = self.next_token.fetch_add(1, Ordering::SeqCst);
            let (tx, rx) = mpsc::channel();
            i.waiting.insert(token, tx);
            (token, rx, target)
        };
        (self.emit)("insert", json!({ "token": token, "text": text, "target": target }));
        match rx.recv_timeout(self.timeout) {
            Ok(answer) => answer,
            Err(_) => {
                self.inner.lock().unwrap().waiting.remove(&token);
                Some(TARGET_NOT_ACTIVE.to_owned())
            }
        }
    }

    fn insertion_allowed(&self) -> bool {
        self.inner.lock().unwrap().insert_capable
    }

    /// Nothing to ask for: a host that can paste says so when it connects.
    fn request_insertion(&mut self) {}
}

impl ClipboardWriter for Bridge {
    fn copy(&mut self, text: &str) {
        self.inner.lock().unwrap().last_copy = Some(text.to_owned());
        (self.emit)("copy", json!({ "text": text }));
    }
}

/// The shortcut is the host's to grab; this records what it was asked to grab
/// and tells it. `set_handler` is not used: the host's presses arrive as
/// commands, which the driver turns into the machine's events.
pub struct HostHotKey {
    bridge: Bridge,
}

impl HostHotKey {
    pub fn new(bridge: Bridge) -> Self {
        Self { bridge }
    }
}

impl GlobalHotKey for HostHotKey {
    fn register(&mut self, shortcut: Option<&KeyShortcut>) -> bool {
        self.bridge.inner.lock().unwrap().registered = shortcut.cloned();
        self.bridge.announce_registration();
        // The host answers with `shortcut_registered`; until it does the shortcut is presumed free.
        true
    }

    fn capture_escape(&mut self, active: bool) {
        self.bridge.inner.lock().unwrap().escape = active;
        self.bridge.announce_registration();
    }

    fn set_handler(&mut self, _handler: Box<dyn HotKeyHandler>) {}
}

#[cfg(test)]
mod tests {
    use super::*;

    type Log = Arc<Mutex<Vec<(String, Value)>>>;

    fn bridge() -> (Bridge, Log) {
        let log = Arc::new(Mutex::new(Vec::new()));
        let sink = log.clone();
        let mut b = Bridge::new(Arc::new(move |name, data| sink.lock().unwrap().push((name.to_owned(), data))));
        b.timeout = Duration::from_millis(200);
        (b, log)
    }

    fn target() -> Target {
        Target { app: "editor".into(), window: "7".into(), secure: false, own: false }
    }

    #[test]
    fn a_password_field_or_ourselves_is_no_target_and_says_the_one_sentence() {
        let (mut b, _) = bridge();
        assert_eq!(b.capture(), Err(NO_EXTERNAL_APPLICATION.into()), "nothing in front");
        b.set_target(Some(Target { secure: true, ..target() }));
        assert_eq!(b.capture(), Err(NO_EXTERNAL_APPLICATION.into()));
        b.set_target(Some(Target { own: true, ..target() }));
        assert_eq!(b.capture(), Err(NO_EXTERNAL_APPLICATION.into()));
        b.set_target(Some(target()));
        assert_eq!(b.capture(), Ok(()));
    }

    #[test]
    fn an_insertion_waits_for_the_hosts_answer_and_the_token_pairs_them() {
        let (mut b, log) = bridge();
        b.host_ready(true);
        b.set_target(Some(target()));
        let answering = b.clone();
        let watcher = log.clone();
        let t = std::thread::spawn(move || loop {
            if let Some((_, data)) = watcher.lock().unwrap().iter().find(|(n, _)| n == "insert").cloned() {
                answering.inserted(data["token"].as_u64().unwrap(), None);
                return data;
            }
            std::thread::sleep(Duration::from_millis(5));
        });
        assert_eq!(b.insert("hello"), None, "the text went in");
        let sent = t.join().unwrap();
        assert_eq!(sent["text"], "hello");
        assert_eq!(sent["target"]["window"], "7");
    }

    #[test]
    fn a_host_that_says_why_not_is_believed_and_one_that_says_nothing_times_out() {
        let (mut b, _) = bridge();
        b.host_ready(true);
        b.set_target(Some(target()));
        assert_eq!(b.insert("x"), Some(TARGET_NOT_ACTIVE.into()), "no answer in time");
        let (mut b, _) = bridge();
        b.set_target(Some(target()));
        assert_eq!(b.insert("x"), Some(PASTE_FAILED.into()), "no host that can paste");
        assert!(!b.insertion_allowed());
    }

    #[test]
    fn copying_and_registering_tell_the_host_and_are_remembered() {
        let (mut b, log) = bridge();
        b.copy("text");
        assert_eq!(b.last_copy().as_deref(), Some("text"));
        let mut hot = HostHotKey::new(b.clone());
        let shortcut = capa_core::prefs::default_dictation_shortcut();
        assert!(hot.register(Some(&shortcut)));
        hot.capture_escape(true);
        assert_eq!(b.registration(), (Some(shortcut), true));
        let names: Vec<String> = log.lock().unwrap().iter().map(|(n, _)| n.clone()).collect();
        assert_eq!(names, ["copy", "register", "register"]);
        let register = log.lock().unwrap()[1].1.clone();
        assert_eq!(register["accelerator"], "<Control><Alt>d", "grabbed by the key, as the host binds it");
        assert_eq!(register["evdev"], 32);
        b.end_hold();
        assert_eq!(log.lock().unwrap().last().unwrap().0, "end_hold");
    }
}
