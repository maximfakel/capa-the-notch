# 06: The Shelf in three tabs

**What to build:** The Shelf page has three Shelf Tabs — Files, Screenshots, Clipboard — at 210. Files holds dropped files (up to 20); Screenshots holds screenshots and images taken from the clipboard (up to 20); Clipboard shows how to turn text intake on until ticket 08 fills it. Spec stories 29–34, 46; Paper "Expanded — Shelf" (7P5), "Expanded — Shelf empty" (7DU).

**Blocked by:** 02.

**Status:** done

- [x] Three tabs always shown; the Shelf opens on the tab last used this session.
- [x] Each item lands in its tab; each tab has its own limit, oldest giving way.
- [x] Clear empties only the current tab; the count in the header is the current tab's.
- [x] A tab whose intake is off says how to turn it on; empty tabs as in 7DU.
- [x] The Shelf page is 210 (metrics dump); swiping its row still scrolls files that overflow.
- [x] Shelf model tests cover placement, per-tab limits and Clear.

## Comments

- 2026-10-02: Done. `Shelf` holds one list per `ShelfTab`, each with its own limit; `clear(_:)` empties one tab, `clearAll()` is for switching off. Dropped items go under Files, as today, and a drop shows Files. From the clipboard, screenshots and images go under Screenshots, and copied documents under Files (`ShelfTab.forCopied`). The tab shown is the controller's, for the session. Clear stays in the header: red when there is something to clear, grey and disabled when the tab is empty, as in 7P5/7DU. The count is the current tab's ("5 файлов", "1 скрин"). The empty Screenshots tab names its switch while intake is off. The Clipboard tab names a text switch that ticket 08 adds. The picture dump prints each tab's height: all are 210. Copy Diagnostics now says `shelf-on-N-files-M-screenshots`. The tab labels are Geist 500, as SwiftUI offers no weight at 510.
