//! Where this system saves screenshots, and a listing of that folder.

use capa_core::shelf::screenshots::Entry;
use capa_core::shelf::{FolderListing, ScreenshotFolderWatcher};
use chrono::{DateTime, Utc};
use std::path::{Path, PathBuf};

pub struct SystemScreenshotFolder {
    folder: PathBuf,
}

impl SystemScreenshotFolder {
    /// `~/Pictures/Screenshots` where it exists (GNOME saves
    /// there), else the Pictures folder — `$XDG_PICTURES_DIR` or `~/Pictures`.
    pub fn locate(home: &Path) -> Self {
        let pictures = pictures_dir(home);
        let screenshots = pictures.join("Screenshots");
        Self { folder: if screenshots.is_dir() { screenshots } else { pictures } }
    }

    pub fn at(folder: PathBuf) -> Self {
        Self { folder }
    }
}

fn pictures_dir(home: &Path) -> PathBuf {
    if let Some(dir) = std::env::var_os("XDG_PICTURES_DIR").map(PathBuf::from).filter(|p| p.is_absolute()) {
        return dir;
    }
    // `user-dirs.dirs`: `XDG_PICTURES_DIR="$HOME/Pictures"`.
    let config = std::env::var_os("XDG_CONFIG_HOME").map(PathBuf::from).unwrap_or_else(|| home.join(".config"));
    if let Ok(text) = std::fs::read_to_string(config.join("user-dirs.dirs")) {
        for line in text.lines() {
            if let Some(value) = line.trim().strip_prefix("XDG_PICTURES_DIR=") {
                let value = value.trim().trim_matches('"').replace("$HOME", &home.to_string_lossy());
                let path = PathBuf::from(value);
                if path.is_absolute() {
                    return path;
                }
            }
        }
    }
    home.join("Pictures")
}

impl ScreenshotFolderWatcher for SystemScreenshotFolder {
    fn saves_to_folder(&self) -> bool {
        true
    }

    fn folder(&self) -> PathBuf {
        self.folder.clone()
    }

    fn list(&self, folder: &Path) -> FolderListing {
        match std::fs::read_dir(folder) {
            Ok(entries) => FolderListing::Entries(
                entries
                    .flatten()
                    .filter_map(|e| {
                        let meta = e.metadata().ok()?;
                        // Created, where the file system says; modified otherwise.
                        let when = meta.created().or_else(|_| meta.modified()).ok()?;
                        Some(Entry { path: e.path(), created: DateTime::<Utc>::from(when), is_regular_file: meta.is_file() })
                    })
                    .collect(),
            ),
            Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied => FolderListing::Refused,
            // A folder that is not there is only empty.
            Err(_) => FolderListing::Entries(vec![]),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("capa-shelf-folder-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn it_lists_files_with_when_they_were_made() {
        let dir = temp("list");
        std::fs::write(dir.join("Screenshot from 2026-10-02 10-00-01.png"), b"x").unwrap();
        std::fs::create_dir(dir.join("sub")).unwrap();
        let FolderListing::Entries(entries) = SystemScreenshotFolder::at(dir.clone()).list(&dir) else { panic!() };
        assert_eq!(entries.len(), 2);
        assert_eq!(entries.iter().filter(|e| e.is_regular_file).count(), 1);
    }

    #[test]
    fn a_folder_that_is_not_there_is_only_empty() {
        let w = SystemScreenshotFolder::at("/nonexistent/x".into());
        assert_eq!(w.list(Path::new("/nonexistent/x")), FolderListing::Entries(vec![]));
    }

    #[test]
    fn the_screenshots_folder_is_preferred_when_it_exists() {
        let home = temp("home");
        std::fs::create_dir_all(home.join("Pictures/Screenshots")).unwrap();
        // `XDG_PICTURES_DIR` from the environment would win, and tests do not set it.
        if std::env::var_os("XDG_PICTURES_DIR").is_none() && std::env::var_os("XDG_CONFIG_HOME").is_none() {
            assert_eq!(SystemScreenshotFolder::locate(&home).folder(), home.join("Pictures/Screenshots"));
        }
    }

    #[test]
    fn user_dirs_names_the_pictures_folder() {
        let home = temp("userdirs");
        std::fs::create_dir_all(home.join(".config")).unwrap();
        std::fs::write(home.join(".config/user-dirs.dirs"), "XDG_PICTURES_DIR=\"$HOME/Bilder\"\n").unwrap();
        if std::env::var_os("XDG_PICTURES_DIR").is_none() && std::env::var_os("XDG_CONFIG_HOME").is_none() {
            assert_eq!(pictures_dir(&home), home.join("Bilder"));
        }
    }
}
