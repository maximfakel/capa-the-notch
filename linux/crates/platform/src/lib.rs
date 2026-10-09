//! What the machine does for CapaTheNotch that is not a Module: the few
//! sounds, starting at login, which display holds the surface and the
//! diagnostic log. Whether a fullscreen application is in front is the shell
//! extension's to say (`scene.fullscreen`). Updates are not looked for:
//! "Check for Updates…" opens the releases page, as on macOS. The logic is in
//! `capa_core`; this crate is the part that touches the system, with a fake
//! for tests.

pub mod diagnostics;
pub mod displays;
pub mod launch_at_login;
pub mod sound;

/// The name of this system as reports and logs write it.
pub fn system_name() -> &'static str {
    if cfg!(target_os = "macos") {
        "macOS"
    } else {
        "Linux"
    }
}

/// The system's own version string, as well as it can be had without a dependency.
pub fn system_version() -> String {
    #[cfg(target_os = "linux")]
    {
        if let Ok(text) = std::fs::read_to_string("/etc/os-release") {
            let get = |key: &str| {
                text.lines()
                    .find_map(|l| l.strip_prefix(&format!("{key}=")))
                    .map(|v| v.trim_matches('"').to_owned())
            };
            if let Some(pretty) = get("PRETTY_NAME") {
                let kernel = std::fs::read_to_string("/proc/sys/kernel/osrelease").unwrap_or_default();
                return format!("{pretty} (kernel {})", kernel.trim());
            }
        }
    }
    std::env::consts::OS.to_owned()
}
