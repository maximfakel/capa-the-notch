# 01: Create the clean-room Capacity Notch shell

**What to build:** A runnable MIT-licensed macOS application that gives users the first complete Capacity Notch experience with mock Codex and Claude Code data: a compact top-of-screen surface, an expanded detail surface, and a menu bar entry point. The implementation must remain clean-room and preserve required attribution for MIT-licensed references.

**Blocked by:** None (can start immediately).

**Status:** resolved

- [x] The application builds and launches on Apple Silicon with macOS 14 or later as a menu bar application without a Dock icon.
- [x] The compact surface presents mock Capacity for both initial Providers and expands into two mock Provider cards.
- [x] The surface uses the built-in display by default and does not create simultaneous copies on multiple displays.
- [x] The repository declares the MIT license and records required attribution without copying GPL-licensed implementation code.
- [x] Automated tests cover the initial Capacity, Quota Window, and Capacity Snapshot behavior used by the mock experience.
