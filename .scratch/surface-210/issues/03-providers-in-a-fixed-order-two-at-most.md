# 03: Providers in a fixed order, two at most (prefactor)

**What to build:** No visible change with today's two Providers. The order Providers are shown in, and the rule that at most two can be on, become one Core rule that the cards, the closed strip's sides and the nothing-connected view all read; the strip's sides become "first" and "second" rather than Codex and Claude Code. Makes ticket 04 a matter of adding a case. Spec stories 23–26.

**Blocked by:** None (can start immediately).

**Status:** done

- [x] One ordered selection (Codex, Claude Code, then any later Provider) drives cards, strip sides and the nothing/one-connected cases.
- [x] Preferences refuse to connect a third Provider while two are on, and say which switch would be disabled and why ("Turn one off to turn this on").
- [x] With one Provider on, the strip still shows its five-hour window left and its week right.
- [x] Compact-strip, switched-off and preferences tests cover the rule; existing behaviour unchanged.

## Comments

- 2026-10-02: Done. `ProviderSelection` holds the order (the Provider list's own) and the two-at-most rule; cards, strip sides, unread placeholders and the Settings/onboarding lists all read it. The rule is a Preferences invariant, not only the switch's: a third Provider chosen anywhere is read as off, so it is neither connected nor given a card. The refusal is tested through `limit:` while only two Providers exist. One visible change: a single Provider on and not read yet now shows its dash on the left, where its five hours will stand once read (before, Claude Code's sat on the right and jumped).
