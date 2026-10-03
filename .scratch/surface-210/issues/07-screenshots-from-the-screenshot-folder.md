# 07: Screenshots from the screenshot folder

**What to build:** With screenshot intake on, each new screenshot macOS saves to its chosen location appears under Screenshots as a reference to the file. Spec stories 35–36; ADR 0005 (amended 2026-10-02).

**Blocked by:** 06.

**Status:** done

- [x] The location is macOS's own screenshot setting, including a custom folder; only files created after the switch was turned on are taken; only while it is on.
- [x] macOS is asked for folder access when the switch is turned on; refused access shows in Settings and in Copy Diagnostics with a reason code, and clipboard screenshots keep arriving.
- [x] Held as references, never copies; a moved or deleted screenshot shows unavailable, as files do.
- [x] Tests cover which new files in the folder are taken.

## Comments

- 2026-10-02: Done.
  - **Where.** The folder is `location` in `com.apple.screencapture`, read on its own (`persistentDomain`), or the Desktop. It is read again at every look, so a folder chosen later is followed. `location-last` is only what the menu offers last; it is not used.
  - **When.** The folder is looked at only while macOS saves screenshots to a file (`target-screenshot`, else `target`). While they go to the clipboard, Preview, Mail or Messages, it is not looked at, and macOS is not asked for a folder that would get nothing. Watching begins when the switch is turned on, or at launch while it is on. The Shelf is empty after quitting, so nothing from before comes back.
  - **What is taken.** macOS marks a saved screenshot nowhere a program can read: there is no attribute, and Spotlight has nothing yet. So a screenshot is recognised by its name. That is the `name` set there, or "Screenshot", "Screen Shot" or "Снимок экрана", followed by nothing, a number, or the date and time ("Screenshot of the bug" is not taken). Without a `name` of one's own, any name followed by the date and time is taken too, for other languages. A file named that way by someone else would also be taken. Its type must be the `type` set there, PNG by default. Hidden files are not taken (macOS is still writing them), nor folders, nor anything created before watching began.
  - **Looking.** The folder is looked at every two seconds, off the main thread. Each start of watching has its own count, so a look begun before the switch was turned off and on again is dropped. The first look is what has macOS ask for the folder. Info.plist gives the reason for the Desktop, Documents, Downloads, and removable and network volumes.
  - **Refused.** If refused, Settings shows a red line and Copy Diagnostics shows `shelf-screenshot-folder-refused`. The clipboard is unaffected.
  - **Not tried live.** On this Mac screenshots go to the clipboard, so the folder is not looked at. The controller's own sequencing is not unit-tested; the Core rules are.
