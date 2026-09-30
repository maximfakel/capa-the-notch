# Capacity Notch

A glanceable macOS surface in the notch that hosts Modules — built-in features, off until asked for. The first, the Capacity Module, keeps AI-service Capacity visible and reveals detailed usage on demand. It is initially designed for its creator and a small group of developers.

## Language

### The surface

**Capacity Notch**:
The application.

**Notch Surface**:
The persistent top-of-screen surface in the notch: a compact strip while idle, expandable to show a Module in full.
_Avoid_: Dynamic Island, hub

**Module**:
One built-in feature the Notch Surface hosts. Every Module except the Capacity Module is off until a person turns it on.
_Avoid_: Plugin, widget, extension

**Capacity Module**:
The Module that shows AI-service Capacity; the one Capacity Notch started as. The terms under Capacity are its language.

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

### Capacity

**Provider**:
An AI service whose capacity information is presented by Capacity Notch.
_Avoid_: Vendor, integration

**Capacity**:
The usable allowance available from a Provider across one or more quota windows.
_Avoid_: Balance, credits

**Quota Window**:
A Provider-defined period with measured usage and a reset time, such as a short rolling window or a weekly allowance.
_Avoid_: Limit, billing period

**Headline Window**:
The Quota Window with the least remaining Capacity, the earlier reset breaking a tie. The compact strip shows it when "Least left" is chosen in Settings; by default the strip shows each Provider's five-hour window instead.
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
