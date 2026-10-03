# 08: The Clipboard tab

**What to build:** With text intake on, text a person copies is kept under the Clipboard tab as Clippings, by every rule ADR 0005 set for the Clipboard History Module (amended 2026-10-02). Spec stories 37–45. Supersedes ticket capacity-notch/29.

**Blocked by:** 06.

**Status:** done

- [x] Its own switch in the Shelf's settings, off by default; 20 Clippings, or 50 or 100; newest first; a repeat rises rather than duplicating.
- [x] Each Clipping goes after 24 hours unless that is switched off; nothing over 100,000 characters is kept.
- [x] Never kept: concealed/transient/auto-generated pasteboard markers, anything copied while Passwords, Keychain Access or a chosen application is in front, anything Capacity Notch put there itself.
- [x] Clicking a Clipping puts it on the clipboard and shows "Copied"; nothing is pasted.
- [x] The surface is excluded from screen sharing and recordings while any Clipping is held.
- [x] Refused clipboard access reported in Settings and Copy Diagnostics; Clipping model tests cover every rule.

## Comments

- 2026-10-02: Done.
  - **Model.** `Clippings` and `ClipboardText.isKept` in Core hold every rule, tested in `ClippingTests`.
  - **Own copies.** Everything Capacity Notch puts on the clipboard goes through `OwnClipboard` with the type `app.capacitynotch.own`, so it is never kept. That covers Dictation's text, the diagnostics report and a Clipping chosen again; a chosen Clipping therefore does not rise.
  - **Excluded applications.** The applications chosen in Settings are excluded for text only, as ADR 0005 says. Nothing is kept while Capacity Notch's own window is in front either, which covers ⌘C in Dictation's history, the report and the Teleprompter.
  - **Switching text off.** Turning the text switch off removes the Clippings at once. Lowering the limit trims them at once (`Clippings.trim`), and those kept keep their identity.
  - **Expiry.** It is checked on every look at the clipboard (twice a second while watching).
  - **Screen sharing.** While any Clipping is held, the surface is kept out of capture whatever "Appear in screen sharing" says. The Dictation capsule follows, as it already did.
  - **Copy Diagnostics.** It adds `-N-clippings`; never their text.
  - **Not tried live.** Copying, the "Copied" flash and the capture exclusion were not tried on a real clipboard or a real screen share. The picture dump shows the tab at 210, empty and holding three Clippings.
  - **Left as they are.** The capture rule still lives in `TeleprompterSurface.excludedFromCapture`, with a `holdsClippings` argument; a neutral type can wait for the next Module that needs one. The refused-access line in Settings still has no button to System Settings, as for images before.
