//! The application behind an MPRIS player, as a person knows it: its desktop
//! file's localized `Name=` and its `Icon=`, found the way the shell finds
//! them — `applications/<DesktopEntry>.desktop` under the XDG data
//! directories, the icon in the current icon theme, `hicolor` or `pixmaps`.
//! The macOS page asks `NSWorkspace` for the same two things
//! (`MusicArtwork.icon(of:)`, `MusicIdlePage.name(of:)`). An icon is a PNG or
//! an SVG; `artwork::icon_png` draws an SVG. Blocking file reads: call it off
//! the async threads.

use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Default, PartialEq)]
pub struct DesktopApp {
    pub name: Option<String>,
    /// A PNG or an SVG of the application's icon.
    pub icon: Option<PathBuf>,
}

/// `$XDG_DATA_HOME` (or `~/.local/share`), then `$XDG_DATA_DIRS` (or
/// `/usr/local/share:/usr/share`), in that order of preference.
pub fn data_dirs() -> Vec<PathBuf> {
    let mut dirs = Vec::new();
    match std::env::var_os("XDG_DATA_HOME").filter(|v| !v.is_empty()) {
        Some(home) => dirs.push(PathBuf::from(home)),
        None => {
            if let Some(home) = std::env::var_os("HOME").filter(|v| !v.is_empty()) {
                dirs.push(PathBuf::from(home).join(".local/share"));
            }
        }
    }
    let system = std::env::var("XDG_DATA_DIRS").ok().filter(|v| !v.is_empty()).unwrap_or_else(|| "/usr/local/share:/usr/share".into());
    dirs.extend(system.split(':').filter(|d| !d.is_empty()).map(PathBuf::from));
    dirs
}

/// The locales a `Name[…]=` is looked up under, most specific first:
/// `ru_RU.UTF-8@x` gives `ru_RU@x`, `ru_RU`, `ru@x`, `ru`. `LC_ALL`, else
/// `LC_MESSAGES`, else `LANG`, as the desktop entry specification says.
pub fn locales() -> Vec<String> {
    let value = ["LC_ALL", "LC_MESSAGES", "LANG"]
        .iter()
        .find_map(|k| std::env::var(k).ok().filter(|v| !v.is_empty()))
        .unwrap_or_default();
    locales_of(&value)
}

pub fn locales_of(value: &str) -> Vec<String> {
    let (rest, modifier) = match value.split_once('@') {
        Some((r, m)) => (r, Some(m)),
        None => (value, None),
    };
    let rest = rest.split('.').next().unwrap_or("");
    if rest.is_empty() || rest == "C" || rest == "POSIX" {
        return Vec::new();
    }
    let lang = rest.split('_').next().unwrap_or(rest);
    let country = rest.contains('_').then_some(rest);
    let mut out = Vec::new();
    if let (Some(c), Some(m)) = (country, modifier) {
        out.push(format!("{c}@{m}"));
    }
    if let Some(c) = country {
        out.push(c.to_owned());
    }
    if let Some(m) = modifier {
        out.push(format!("{lang}@{m}"));
    }
    out.push(lang.to_owned());
    out
}

/// `Name=` (localized) and `Icon=` from the `[Desktop Entry]` group.
pub fn parse(text: &str, locales: &[String]) -> (Option<String>, Option<String>) {
    let mut in_entry = false;
    let mut name: Option<String> = None;
    let mut localized: Vec<Option<String>> = vec![None; locales.len()];
    let mut icon = None;
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            in_entry = line == "[Desktop Entry]";
            continue;
        }
        if !in_entry || line.starts_with('#') {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else { continue };
        let (key, value) = (key.trim(), value.trim());
        if value.is_empty() {
            continue;
        }
        if key == "Name" {
            name = Some(value.to_owned());
        } else if key == "Icon" {
            icon = Some(value.to_owned());
        } else if let Some(locale) = key.strip_prefix("Name[").and_then(|k| k.strip_suffix(']')) {
            if let Some(i) = locales.iter().position(|l| l == locale) {
                localized[i] = Some(value.to_owned());
            }
        }
    }
    (localized.into_iter().flatten().next().or(name), icon)
}

/// `applications/<entry>.desktop` in the first data directory that has it.
pub fn desktop_file(entry: &str, dirs: &[PathBuf]) -> Option<PathBuf> {
    let entry = entry.strip_suffix(".desktop").unwrap_or(entry);
    if entry.is_empty() || entry.contains('/') {
        return None;
    }
    dirs.iter().map(|d| d.join("applications").join(format!("{entry}.desktop"))).find(|p| p.is_file())
}

/// The sizes looked in, the one nearest what is drawn first: the page draws
/// the icon at 0.6 × 146 points, about 175 pixels on a 2× display. A theme's
/// scalable SVG comes after the large PNGs and before the small ones.
const SIZES: [u32; 10] = [256, 512, 192, 128, 96, 64, 48, 32, 24, 16];
const LARGE: usize = 3;

fn is_icon(p: &Path) -> bool {
    p.extension().is_some_and(|e| e.eq_ignore_ascii_case("png") || e.eq_ignore_ascii_case("svg")) && p.is_file()
}

/// An `Icon=` as a PNG or SVG on disk: a path as it is, a name in the
/// `themes` (the current one, then `hicolor`) under `apps`, then in `pixmaps`.
pub fn icon_file(icon: &str, dirs: &[PathBuf], themes: &[String]) -> Option<PathBuf> {
    let path = Path::new(icon);
    if path.is_absolute() {
        return is_icon(path).then(|| path.to_path_buf());
    }
    let name = icon.strip_suffix(".png").or_else(|| icon.strip_suffix(".svg")).unwrap_or(icon);
    if name.is_empty() || name.contains('/') {
        return None;
    }
    let (png, svg) = (format!("{name}.png"), format!("{name}.svg"));
    let mut candidates = Vec::new();
    for theme in themes.iter().filter(|t| !t.is_empty() && !t.contains('/')) {
        let sized = |sizes: &[u32]| -> Vec<PathBuf> {
            sizes.iter().flat_map(|s| dirs.iter().map(move |d| d.join(format!("icons/{theme}/{s}x{s}/apps")))).map(|d| d.join(&png)).collect()
        };
        candidates.extend(sized(&SIZES[..LARGE]));
        candidates.extend(dirs.iter().map(|d| d.join(format!("icons/{theme}/scalable/apps")).join(&svg)));
        candidates.extend(sized(&SIZES[LARGE..]));
    }
    let pixmaps: Vec<PathBuf> = dirs.iter().map(|d| d.join("pixmaps")).chain([PathBuf::from("/usr/share/pixmaps")]).collect();
    candidates.extend(pixmaps.iter().map(|d| d.join(&png)));
    candidates.extend(pixmaps.iter().map(|d| d.join(&svg)));
    candidates.into_iter().find(|p| is_icon(p))
}

/// The themes an icon is looked for in: the desktop's icon theme (read, never
/// written, with `gsettings`), then `hicolor`, which every theme falls back to.
pub fn icon_themes() -> Vec<String> {
    let current = std::process::Command::new("gsettings")
        .args(["get", "org.gnome.desktop.interface", "icon-theme"])
        .stderr(std::process::Stdio::null())
        .output()
        .ok()
        .filter(|o| o.status.success())
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|t| t.trim().trim_matches('\'').to_owned())
        .filter(|t| !t.is_empty() && t != "hicolor");
    current.into_iter().chain(["hicolor".to_owned()]).collect()
}

/// The desktop entry a player's bus name suggests when it names none:
/// `org.mpris.MediaPlayer2.vlc` gives `vlc`, and an instance suffix
/// (`firefox.instance_1_42`, `chromium.instance4021`) is not part of it.
pub fn entry_of_bus_name(bus_name: &str) -> Option<String> {
    let tail = bus_name.strip_prefix("org.mpris.MediaPlayer2.")?;
    let tail = match tail.find(".instance") {
        Some(i) => &tail[..i],
        None => tail,
    };
    (!tail.is_empty()).then(|| tail.to_owned())
}

/// The application behind the first of `entries` that has a desktop file.
pub fn lookup(entries: &[String]) -> Option<DesktopApp> {
    lookup_in(entries, &data_dirs(), &locales(), icon_themes)
}

pub fn lookup_in(entries: &[String], dirs: &[PathBuf], locales: &[String], themes: impl FnOnce() -> Vec<String>) -> Option<DesktopApp> {
    let file = entries.iter().find_map(|e| desktop_file(e, dirs))?;
    let text = std::fs::read_to_string(file).ok()?;
    let (name, icon) = parse(&text, locales);
    Some(DesktopApp { name, icon: icon.and_then(|i| icon_file(&i, dirs, &themes())) })
}

#[cfg(test)]
mod tests {
    use super::*;

    const FILE: &str = "[Desktop Entry]\nType=Application\nName=Rhythmbox\nName[ru]=Rhythmbox по-русски\nName[ru_RU]=Ритмбокс\nIcon=org.gnome.Rhythmbox3\n\n[Desktop Action new]\nName=New Window\nIcon=other\n";

    #[test]
    fn the_name_is_the_most_specific_locale_there_is() {
        assert_eq!(parse(FILE, &locales_of("ru_RU.UTF-8")).0.as_deref(), Some("Ритмбокс"));
        assert_eq!(parse(FILE, &locales_of("ru_UA.UTF-8")).0.as_deref(), Some("Rhythmbox по-русски"));
        assert_eq!(parse(FILE, &locales_of("C")).0.as_deref(), Some("Rhythmbox"));
        assert_eq!(parse(FILE, &[]).1.as_deref(), Some("org.gnome.Rhythmbox3"), "an action's icon is not the application's");
    }

    #[test]
    fn locales_go_from_specific_to_general() {
        assert_eq!(locales_of("sr_RS.UTF-8@latin"), ["sr_RS@latin", "sr_RS", "sr@latin", "sr"]);
        assert_eq!(locales_of("en"), ["en"]);
        assert!(locales_of("C.UTF-8").is_empty() && locales_of("").is_empty());
    }

    fn temp_root(tag: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!("capa-desktop-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        root
    }

    fn put(path: PathBuf, bytes: &[u8]) -> PathBuf {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, bytes).unwrap();
        path
    }

    #[test]
    fn the_desktop_file_and_its_png_icon_are_found_in_the_data_dirs() {
        let root = temp_root("png");
        let (home, system) = (root.join("home"), root.join("system"));
        put(home.join("applications/player.desktop"), FILE.as_bytes());
        let png = put(system.join("icons/hicolor/128x128/apps/org.gnome.Rhythmbox3.png"), b"png");
        let dirs = vec![home.clone(), system.clone()];
        let hicolor = ["hicolor".to_owned()];

        assert_eq!(desktop_file("player", &dirs), Some(home.join("applications/player.desktop")));
        assert_eq!(desktop_file("player.desktop", &dirs), Some(home.join("applications/player.desktop")));
        assert_eq!(desktop_file("../player", &dirs), None);
        assert_eq!(desktop_file("absent", &dirs), None);
        assert_eq!(icon_file("org.gnome.Rhythmbox3", &dirs, &hicolor), Some(png.clone()));
        assert_eq!(icon_file("org.gnome.Rhythmbox3.png", &dirs, &hicolor), Some(png.clone()));
        assert_eq!(icon_file(png.to_str().unwrap(), &dirs, &hicolor), Some(png.clone()));
        assert_eq!(icon_file("absent", &dirs, &hicolor), None);
        assert_eq!(icon_file("../escape", &dirs, &hicolor), None);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_scalable_svg_is_an_icon_too() {
        let root = temp_root("svg");
        let system = root.join("system");
        let svg = put(system.join("icons/hicolor/scalable/apps/org.gnome.Music.svg"), b"<svg/>");
        let dirs = vec![root.join("home"), system.clone()];
        let hicolor = ["hicolor".to_owned()];
        assert_eq!(icon_file("org.gnome.Music", &dirs, &hicolor), Some(svg.clone()));
        assert_eq!(icon_file(svg.to_str().unwrap(), &dirs, &hicolor), Some(svg.clone()), "an absolute SVG path");
        assert_eq!(icon_file("/nowhere/at/all.svg", &dirs, &hicolor), None);
        assert_eq!(icon_file(system.join("icons/hicolor/scalable/apps/org.gnome.Music.txt").to_str().unwrap(), &dirs, &hicolor), None);

        // A large PNG is still preferred; a small one is not.
        let small = put(system.join("icons/hicolor/48x48/apps/org.gnome.Music.png"), b"png");
        assert_eq!(icon_file("org.gnome.Music", &dirs, &hicolor), Some(svg.clone()));
        let large = put(system.join("icons/hicolor/256x256/apps/org.gnome.Music.png"), b"png");
        assert_eq!(icon_file("org.gnome.Music", &dirs, &hicolor), Some(large));
        assert_ne!(small, svg);

        // An SVG in pixmaps, when nothing else has it.
        let pixmap = put(system.join("pixmaps/oldplayer.svg"), b"<svg/>");
        assert_eq!(icon_file("oldplayer", &dirs, &hicolor), Some(pixmap));
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn the_current_theme_comes_before_hicolor() {
        let root = temp_root("theme");
        let system = root.join("system");
        put(system.join("icons/hicolor/256x256/apps/player.png"), b"png");
        let themed = put(system.join("icons/Fancy/scalable/apps/player.svg"), b"<svg/>");
        let dirs = vec![system.clone()];
        let themes = ["Fancy".to_owned(), "hicolor".to_owned()];
        assert_eq!(icon_file("player", &dirs, &themes), Some(themed));
        assert_eq!(icon_file("player", &dirs, &["../x".to_owned()]), None, "a theme name is not a path");
        assert_eq!(icon_themes().last().map(String::as_str), Some("hicolor"));
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_bus_name_stands_for_a_missing_desktop_entry() {
        assert_eq!(entry_of_bus_name("org.mpris.MediaPlayer2.vlc").as_deref(), Some("vlc"));
        assert_eq!(entry_of_bus_name("org.mpris.MediaPlayer2.firefox.instance_1_42").as_deref(), Some("firefox"));
        assert_eq!(entry_of_bus_name("org.mpris.MediaPlayer2.chromium.instance4021").as_deref(), Some("chromium"));
        assert_eq!(entry_of_bus_name("org.mpris.MediaPlayer2.org.gnome.Music").as_deref(), Some("org.gnome.Music"));
        assert_eq!(entry_of_bus_name("org.mpris.MediaPlayer2."), None);
        assert_eq!(entry_of_bus_name("org.example.Other"), None);

        let root = temp_root("bus");
        let home = root.join("home");
        put(home.join("applications/vlc.desktop"), b"[Desktop Entry]\nName=VLC\nIcon=vlc\n");
        let svg = put(home.join("icons/hicolor/scalable/apps/vlc.svg"), b"<svg/>");
        let dirs = vec![home];
        let entries = ["absent".to_owned(), entry_of_bus_name("org.mpris.MediaPlayer2.vlc").unwrap()];
        let app = lookup_in(&entries, &dirs, &[], || vec!["hicolor".to_owned()]).unwrap();
        assert_eq!((app.name.as_deref(), app.icon), (Some("VLC"), Some(svg)));
        assert_eq!(lookup_in(&entries[..1], &dirs, &[], Vec::new), None);
        let _ = std::fs::remove_dir_all(&root);
    }
}
