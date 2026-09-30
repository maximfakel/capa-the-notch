# 24: Decide what the Shelf and clipboard may keep

**What to build:** Nothing yet. An ADR: what the Shelf and clipboard history
hold, where, for how long, and what they never hold.

**Blocked by:** none.

**Status:** resolved

**Why:** Ticket 15 put the Shelf and clipboard next after the calendar, and
said they need an ADR for the data they hold before any code. Clipboard
history keeps everything the person copies — passwords from a password
manager, tokens, private messages — which is the most sensitive data this
application would ever touch.

## Questions for the author

- **Shelf and clipboard:** one Module or two. The Shelf holds files dropped on
  the notch; the clipboard holds what was copied. They are often shown
  together and they hold very different things.
- **What is never kept:** items a password manager marks as concealed or
  transient (the pasteboard's own markers), items from chosen applications,
  anything over a size.
- **Where it lives:** in memory only, or on disk; if on disk, in what form,
  and whether it is encrypted.
- **How long:** a count, an age, or until quit; and clearing it by hand.
- **What it shows:** text, images, files; whether a preview may reveal a
  copied secret on screen during a call (screen sharing already hides the
  surface only when asked).
- **Diagnostics:** Copy Diagnostics carries counts at most, never contents
  (as ticket 10 requires).

## Answer

Decided with the author on 2026-09-30, in a grilling session; recorded as
ADR 0005, `docs/adr/0005-the-shelf-and-clipboard-history-keep-little-and-only-in-memory.md`.

- **Two Modules,** the Shelf Module (ticket 25) and the Clipboard History
  Module (ticket 29), each with its own switch.
- **Nothing on disk.** Both live in memory, empty after quitting and at once
  when switched off.
- **Clipboard History:** text only, copied after it is switched on; 20
  Clippings by default, 50 or 100 in Settings; each goes after 24 hours,
  switchable; a repeat rises to the top; over 100,000 characters is not
  kept; choosing one puts it on the clipboard, nothing more; not cleared on
  lock or sleep.
- **Never kept:** nspasteboard.org concealed, transient and auto-generated
  items; anything copied while Passwords or Keychain Access was in front,
  plus applications added in Settings; anything Capacity Notch wrote itself.
- **Never on screen sharing or recordings,** whatever the Settings switch.
- **A refusal by macOS** shows in Settings with a way to System Settings,
  and in Copy Diagnostics.
- **Shelf:** references, not copies; up to 20 files; a file dragged out
  stays; a moved or deleted file shows as unavailable.
- **Diagnostics:** counts and reason codes only.
