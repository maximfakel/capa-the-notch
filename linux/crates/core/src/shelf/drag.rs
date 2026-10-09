//! `ShelfDragFiles`: where the files for dragging an in-memory image out are
//! written. A folder of the Shelf's own in the temporary directory, readable
//! by this user alone, a folder per item named by its id.

use super::model::ItemId;
use super::platform::DragFileStore;
use std::fs;
use std::path::{Path, PathBuf};

pub struct TempDragFiles {
    folder: PathBuf,
}

impl TempDragFiles {
    /// `<temporary directory>/capacity-notch-shelf-drag`.
    pub fn new() -> Self {
        Self::at(std::env::temp_dir().join("capacity-notch-shelf-drag"))
    }

    pub fn at(folder: PathBuf) -> Self {
        Self { folder }
    }

    pub fn folder(&self) -> &Path {
        &self.folder
    }

    fn private_directory(path: &Path) -> std::io::Result<()> {
        fs::create_dir_all(path)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
        }
        Ok(())
    }
}

impl Default for TempDragFiles {
    fn default() -> Self {
        Self::new()
    }
}

impl DragFileStore for TempDragFiles {
    fn file_for(&self, item: ItemId, name: &str, data: &[u8]) -> Option<PathBuf> {
        // A name is a name, not a path.
        let name = Path::new(name).file_name()?;
        let directory = self.folder.join(item.to_string());
        let path = directory.join(name);
        if path.exists() {
            return Some(path);
        }
        Self::private_directory(&self.folder).ok()?;
        Self::private_directory(&directory).ok()?;
        fs::write(&path, data).ok()?;
        Some(path)
    }

    fn keep_only(&self, held: &[ItemId]) {
        let Ok(entries) = fs::read_dir(&self.folder) else { return };
        for entry in entries.flatten() {
            let keep = entry.file_name().to_str().and_then(|n| n.parse::<u64>().ok()).is_some_and(|id| held.contains(&ItemId(id)));
            if !keep {
                let _ = fs::remove_dir_all(entry.path());
            }
        }
    }

    fn remove_all(&self) {
        let _ = fs::remove_dir_all(&self.folder);
    }
}
