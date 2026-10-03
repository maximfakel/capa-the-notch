# 04: OpenCode as a Provider

**What to build:** OpenCode's Go plan can be connected in Settings and shows its five-hour and weekly windows as gauges beside one other Provider, read as ADR 0001 (amended 2026-10-02) allows. Spec stories 14–22, 23, 28; Paper "Limits — C · OpenCode + Codex", "· OpenCode alone".

**Blocked by:** 01, 03.

**Status:** done

- [x] Connecting asks consent first, stating: key read from OpenCode's own file, only percentages asked of opencode.ai, every five minutes and on refresh, key kept nowhere.
- [x] The key is read from OpenCode's `auth.json` at each request and held nowhere between requests; requests go only to the usage endpoint.
- [x] `rolling` → five-hour window, `weekly` → seven-day window; a rate-limited window shows nothing left; a rate-limited or used-up `monthly` shows "Monthly limit reached · until …" in red in the card header.
- [x] Distinct states, each with guidance and a diagnostics code: no sign-in (`opencode auth login`), key refused, endpoint unreachable, answer not understood.
- [x] The third Provider switch is disabled while two are on (from 03); onboarding offers OpenCode under the same rule.
- [x] OpenCode's own mark (MIT, one colour, not redrawn) on the strip and card; credited in THIRD_PARTY_NOTICES; README says Capacity Notch is not affiliated with OpenCode.
- [x] Service tests with a fake network cover every mapping and failure; Russian strings for all new text.

## Comments

- Done 2026-10-02. Declining consent turns the switch back off; `connectOpenCode()` refuses without consent, at launch too. Only the `opencode-go` entry of `auth.json` is taken — the Zen `opencode` entry is not.
- A half-width card says the short "Month used up"; the wide one says "Monthly limit reached · until …".
- The mark is the official SVG's geometry (frame and block at 0.3 opacity), one colour.
- With nothing connected, the three Connect cards are interim until ticket 05.
