# 29: Build the Clipboard History Module

**What to build:** The Clipboard History Module — the text copied recently,
to put on the clipboard again — exactly as ADR 0005 decides it.

**Blocked by:** none.

**Status:** wontfix (superseded by surface-210/08)

**Why:** Split from the Shelf by ticket 24. It holds the most sensitive data
Capacity Notch touches, so ADR 0005 decides what it may keep; this ticket
builds only that.

- [ ] Off until turned on in Settings; nothing is read or kept while off,
      and switching it off empties it at once (ADR 0003, 0005).
- [ ] Text only, copied after it is switched on; 20 Clippings by default,
      50 or 100 in Settings; over 100,000 characters is not kept.
- [ ] Each Clipping goes 24 hours after it was copied; the expiry is on by
      default and can be switched off.
- [ ] A text copied again rises to the top with a new 24 hours.
- [ ] Never kept: nspasteboard.org concealed, transient and auto-generated
      items; anything copied while Passwords, Keychain Access or an
      application added in Settings was in front; anything Capacity Notch
      wrote itself.
- [ ] Choosing a Clipping puts it on the clipboard and nothing more.
- [ ] Never shown in screen sharing or recordings, whatever Settings allows.
- [ ] A refusal by macOS shows in Settings with a way to System Settings,
      and in Copy Diagnostics as a code.
- [ ] Nothing on disk; Copy Diagnostics and the log carry counts and codes,
      never text.

## What has to be answered first

- The mockup, in Paper: where the history opens from and how Clippings are
  listed.
- How the Module is kept out of screen sharing while the rest of the surface
  may appear: its own window with its own sharing type, or not drawn at all
  while the surface is shared.
- Whether reading the clipboard shows macOS's alert on the Macs it will run
  on, measured, and what `NSPasteboard.accessBehavior` answers.

## Comments

- 2026-10-02: Superseded. The author decided the Clipboard History Module becomes the Shelf's Clipboard tab, with every rule of ADR 0005 unchanged (ADR 0005 amended 2026-10-02). Built in `.scratch/surface-210/issues/08-clipboard-tab.md`.
