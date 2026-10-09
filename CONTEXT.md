# CapaTheNotch

A glanceable macOS surface in the notch that hosts Modules — built-in features, off until asked for. The first, the Capacity Module, keeps AI-service Capacity visible and reveals detailed usage on demand. It is initially designed for its creator and a small group of developers.

## Language

### The surface

**CapaTheNotch**:
The application, CapaTheNotch.app, shipped as CapaTheNotch-<version>.zip. Called Capacity Notch,
and CapacityNotch.app, until 3 October 2026 (0.3.0); its identifiers, bundle identifier, binaries
(CapacityNotchClaudeBridge among them) and Application Support folder keep the old name.
_Avoid_: Capacity Notch

**Notch Surface**:
The persistent top-of-screen surface in the notch: a compact strip while idle, expandable to show a Module in full.
_Avoid_: Dynamic Island, hub

**Module**:
One built-in feature the Notch Surface hosts. Every Module except the Capacity Module is off until a person turns it on.
_Avoid_: Plugin, widget, extension

**Capacity Module**:
The Module that shows AI-service Capacity; the one CapaTheNotch started as. The terms under Capacity are its language.

**Kapa**:
The surface's one character: a cyan bell whose face says what the Module it stands in already says — calm, worried, listening, pleased. Part of how Modules look, never a Module itself, and never in the compact strip (ADR 0006).
_Avoid_: Mascot, companion, buddy, pet, avatar

### The teleprompter

**Teleprompter Module**:
The Module that scrolls a Script beside the camera, so a person can read it aloud while looking into the lens.
_Avoid_: Prompter, autocue

**Script**:
The one text the Teleprompter Module reads out; a new one replaces it, and only the one before can be brought back.
_Avoid_: Prompt (read as an instruction to an AI model), notes, document

**Teleprompter Row**:
The lines of the Script shown beneath the compact strip, the current line nearest the camera, while the Teleprompter Module is running or paused.
_Avoid_: Prompter bar, overlay

**Running**, **Paused**, **Finished**, **Stopped**:
The Teleprompter Module's states. Running moves the Script on by itself; Paused holds its place; Finished holds the last line in view for a moment once the Script has been read; Stopped shows no Teleprompter Row and starts the Script over.

### Dictation

**Dictation Module**:
The Module that turns speech into text for the application a person is using, with the clipboard as a fallback when insertion is unavailable.
_Avoid_: Voice assistant, transcription service

**Dictation Capsule**:
The temporary indicator beneath the Notch Surface that shows a dictation’s recording, recognition and completion states.
_Avoid_: Dictation Row, dictation page

### The Shelf and the clipboard

**Shelf Module**:
The Module that keeps things at hand on the notch — files, screenshots and copied text — until they are dragged or copied somewhere else (ADR 0005).
_Avoid_: Drop zone, tray, stash, clipboard manager, pasteboard archive

**Shelf Tab**:
One of the Shelf's three views of what it keeps: Files, Screenshots, and Clipboard (the Clippings).
_Avoid_: Section, category, filter

**Clipping**:
One copied text the Shelf keeps: what was copied, and when.
_Avoid_: Snippet (read as something saved on purpose), clip, entry

### The calendar

**Calendar Module**:
The Module that shows what is next in the person's calendars — every calendar on the Mac, events only, read through EventKit — as a row beneath Capacity from ten minutes before an event starts until five minutes after, with Join when the event carries a call link, and as a page in the expanded surface with three views: the day, the seven days from today, and the month.
_Avoid_: Agenda, schedule, meetings widget

### Capacity

**Provider**:
An AI service whose capacity information is presented by CapaTheNotch.
_Avoid_: Vendor, integration

**Capacity**:
The usable allowance available from a Provider across one or more quota windows.
_Avoid_: Balance, credits

**Quota Window**:
A Provider-defined period with measured usage and a reset time, such as a short rolling window or a weekly allowance.
_Avoid_: Limit, billing period

**Headline Window**:
The Quota Window with the least remaining Capacity, the earlier reset breaking a tie. The compact strip does not choose by it: with two Providers on, it shows each one's five-hour window, or its week when "Неделя" is chosen in Settings ("Least left" was a third choice until 8 October 2026).
_Avoid_: Primary limit, most urgent window

**Fresh Capacity**:
Capacity confirmed by the most recent successful Provider refresh.
_Avoid_: Live limit, current balance

**Stale Capacity**:
The last successfully observed Capacity when its expected refresh has failed or expired; it must remain distinguishable from Fresh Capacity.
_Avoid_: Estimated limit, cached balance

**Capacity Pace**:
How comfortable a Quota Window's remaining Capacity is, read as bands of what is left: sustainable at 60% and above, tightening at 10% and above, unsustainable below that. Deliberately not weighed against the time still to run — a person glancing at the surface reads eleven percent as nearly gone whatever the clock says.
_Avoid_: Burn rate, usage speed

**Capacity Alert**:
A single system notification emitted when a Provider's Quota Window newly enters a critical Capacity Pace state.
_Avoid_: Limit warning, usage notification

**Capacity Snapshot**:
A timestamped observation of a Provider's Quota Windows and connection state. A persisted snapshot is Stale Capacity until refreshed successfully.
_Avoid_: Usage cache, quota response

## Initial Provider Scope

- Codex
- Claude Code
- OpenCode (its Go plan; ADR 0001)
