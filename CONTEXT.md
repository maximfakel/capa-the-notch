# AI Capacity Notch

A glanceable macOS surface that keeps AI-service capacity visible and reveals detailed usage information on demand. It is initially designed for its creator and a small group of developers.

## Language

**Capacity Notch**:
The product's persistent top-of-screen surface: compact while idle and expandable for details about AI-service capacity.
_Avoid_: Universal notch hub, Dynamic Island clone

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
The Quota Window with the least remaining Capacity, the earlier reset breaking a tie. It represents a Provider in the compact surface.
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
