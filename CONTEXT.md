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
The Module that shows AI-service Capacity; the one Capacity Notch started as. The terms below are its language.

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
The Quota Window with the least remaining Capacity, the earlier reset breaking a tie. It represents a Provider in the compact strip.
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
