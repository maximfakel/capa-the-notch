# Build a Clean-Room MIT Application

Capacity Notch is a new MIT-licensed application rather than a fork of an existing notch utility. MIT-licensed implementation patterns from Cyclop and Codeburn may be adapted with the required attribution, while GPL-3.0 boring.notch is used only as a behavioral and UX reference; this preserves the option to distribute Capacity Notch under MIT while accepting the cost of implementing and validating its own interface and architecture.

**2026-09-30.** Nothing was taken from Cyclop or Codeburn in the end. Cyclop's panel, notch geometry, pointer tracking and Teleprompter share nothing with ours beyond standard AppKit lines, and Codeburn reads Provider credentials, which ADR 0001 rules out. Their entries, added to `THIRD_PARTY_NOTICES.md` before any of this code existed, are removed; Codenotch stays, for the `claude /usage` flags adapted from it.
