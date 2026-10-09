//! Launch at login (`LaunchAtLogin.swift`): the platform crate does it — an
//! autostart entry — and this is the seam
//! the module reads and writes it through, so tests need no home directory.

pub trait LoginItem: Send + Sync {
    fn is_enabled(&self) -> bool;
    /// Switches it. Returns what is true afterwards: the system has the last
    /// word, and a switch that did nothing must not stay on.
    fn set(&self, enabled: bool) -> bool;
}

/// The system's own.
pub struct SystemLogin;

impl LoginItem for SystemLogin {
    fn is_enabled(&self) -> bool {
        capa_platform::launch_at_login::is_enabled()
    }

    fn set(&self, enabled: bool) -> bool {
        capa_platform::launch_at_login::set(enabled)
    }
}

/// A login item that only remembers, for tests.
#[derive(Default)]
pub struct MemoryLogin(std::sync::atomic::AtomicBool);

impl LoginItem for MemoryLogin {
    fn is_enabled(&self) -> bool {
        self.0.load(std::sync::atomic::Ordering::SeqCst)
    }

    fn set(&self, enabled: bool) -> bool {
        self.0.store(enabled, std::sync::atomic::Ordering::SeqCst);
        enabled
    }
}
