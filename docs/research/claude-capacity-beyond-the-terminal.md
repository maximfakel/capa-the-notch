# Claude Capacity beyond the terminal

Researched on 2026-10-08 against Claude Code 2.1.293 (the copy the Claude
desktop app 2.26454.2 runs from `~/Library/Application Support/Claude/claude-code/2.1.293/`,
and the same version on `PATH`). Read-only: no setting was changed, no `claude`
was run, no request was made to Anthropic. Documentation pages were read on
code.claude.com.

The question: how can CapaTheNotch get the five-hour and weekly windows (used
percentage and reset time) while the person works in the desktop app's Code tab
or in VS Code, where Claude Code runs as
`claude --output-format stream-json --input-format stream-json …` and no status
line runs — with at most one action the person accepts at launch?

## Answer

**Claude Code's mods API gives exactly this, officially, on every surface.** A
mod is a plugin whose JavaScript hooks run inside Claude Code. Since 2.1.287
(desktop 2.1.286) mods are on by default, and their hooks run in the terminal,
the desktop Code tab, the VS Code extension's chat panel and `claude -p`. The
event `session.measure` fires "after each turn, and when a plan limit's percent
used changes", and carries `rateLimits: [{ kind, percentUsed, resetsAt }]` —
the same figures the status line gets, from the same response headers. A mod of
a dozen lines can hand them to the existing bridge. The person's one action is
the same kind of consent the app already asks for: let CapaTheNotch put its mod
where Claude Code loads it.

Every other route is either unreachable (the desktop app owns the stream-json
pipe), stale (caches filled only when someone opens a usage view), private to
another program, or carries no limits at all (settings hooks, OpenTelemetry).

## Which surface wrote the 2026-10-06 note

`claude-bridge-last-unreadable.json` (17:35:52 MSK, 941 bytes,
`missingRateLimits`, fields `context_window … workspace`) came from a
**terminal** session, not the desktop app. Its transcript in `~/.claude/projects/`
(home directory, `entrypoint: "cli"`, Claude Code 2.1.291) begins 19 seconds
after the note. The note has no `prompt_id`, which the status line leaves out
"until the first user input", and no `rate_limits`, which arrive "only after the
first API response". So it is the status line's first render of a freshly
started `claude`, before anything was typed — the behaviour ticket 03 already
recorded. Nothing shows the desktop app running a status line: the only caller
of the status-line runner in the 2.1.293 binary is the Ink (terminal UI)
component, and `claude-capacity.json` has not moved since 12:09 today although
three desktop sessions have worked all afternoon with `refreshInterval: 60` set.

## Candidates, best first

### 1. A CapaTheNotch mod on `session.measure` — recommended

**What it gives.** Five-hour and seven-day `percentUsed` (0–100, one decimal)
and `resetsAt` (ISO 8601), plus a gateway's `spend_limit` where there is one.
Pushed after every main-thread turn and whenever a window moves a whole point,
on every API response, mid-turn included — as fresh as the status line, in
every surface. `$.session.usage()` answers the same on demand. Like the status
line, an idle session reports nothing new; the bridge's existing "came back"
logic already covers windows that reset while nobody works.

**Evidence.**

- Docs, [Mods overview](https://code.claude.com/docs/en/plugins/mods/overview):
  "Mods are on by default. In the terminal, use Claude Code v2.1.287 or later.
  The Desktop app … mods work there from v2.1.286." The "Where mods run" table:
  hooks run in the terminal, the desktop Code tab (not WSL), the VS Code
  extension's chat panel, and `claude -p` / the Agent SDK.
- Docs, [Mods reference](https://code.claude.com/docs/en/plugins/mods/reference#session):
  `session.measure` — "After each turn, and when a plan limit's percent used
  changes"; `$.session.usage()` returns `{ startedAt, context, rateLimits, cost }`,
  "`rateLimits` is a list of `{ kind, percentUsed, resetsAt }`".
- This build's own types (written by the `plugin-authoring` skill,
  `types/claude-code.d.ts`): `SessionMeasureInput.rateLimits` — "The rate-limit
  windows the last response reported … empty off a subscription or before the
  first reading"; `changed` names `rateLimits` when "a window moved a whole
  point, appeared or left, or the account's limit status changed".
- Binary: `session.measure` is dispatched from the engine's turn-completion path
  (`turnEvents.enqueue("session.measure", …)`), not from the terminal UI, so it
  is not tied to a surface.
- Writing the reading out: `$.process.run(argv, { stdin, env, timeoutMs })` runs
  a host command with text on stdin; `$.fs.write` writes a file (not atomically,
  the reference warns).

**What the mod would do.** On `session.measure` when `changed` includes
`rateLimits` (and once on `session.start` from `$.session.usage()`), build the
status line's shape — `{ session_id, rate_limits: { five_hour: { used_percentage,
resets_at }, seven_day: { … } } }`, `resetsAt` turned into epoch seconds — and
pipe it to the bundled `CapacityNotchClaudeBridge` through `$.process.run`. The
bridge then does what it already does: atomic write, session digest, newest
change wins. No second format, no second writer.

Two things to get right:

- The desktop app starts Claude Code with `CLAUDE_CODE_OAUTH_TOKEN`,
  `CLAUDE_CODE_USER_EMAIL`, `CLAUDE_CODE_ACCOUNT_UUID` and
  `CLAUDE_CODE_ORGANIZATION_UUID` in its environment (names seen with `ps -E`,
  values not read), and `$.process.run` sets `env` *over* the host's. The mod
  must pass those names as empty strings so the bridge never receives them —
  the same exposure every settings hook and Bash call has today, but the ADR
  promises the app none of it.
- Claude Code writes `.claude-plugin/types/` into a `--plugin-dir` folder it
  loads, so the mod must live in a folder CapaTheNotch copies out of its bundle
  (say `~/Library/Application Support/CapacityNotch/claude-mod/`), never inside
  the signed `.app`.

**What the person does once.** Answer one question at launch, in place of or
beside today's status-line question. Three ways to load the mod, in order of
preference — the first two need a live check before choosing:

1. Copy the mod to `~/.claude/skills/capathenotch/` (a folder with
   `.claude-plugin/plugin.json`). Claude Code loads such a folder as
   `capathenotch@skills-dir` at personal scope with no install step
   ([Plugin loading](https://code.claude.com/docs/en/plugins/loading)). It does
   not touch `settings.json`, which can hold credentials. Unchecked: that the
   desktop app's sessions load skills-directory plugins (they are started with
   `--setting-sources=user,project,local`, so user scope should apply).
2. Add `CLAUDE_CODE_PLUGIN_DIRS` to the `env` block of `~/.claude/settings.json`,
   pointing at the copied folder — documented for exactly this case, "for apps
   you can't pass a flag to", and read from the person's settings only. Same
   consent and restore rules as the `statusLine` edit; keep any value already
   there (`:`-separated).
3. A local directory marketplace plus `enabledPlugins` — the most visible in
   `/plugin`, but either `claude plugin install` (one more `claude` process,
   which the 2026-10-06 amendment avoids) or hand-written `installed_plugins.json`
   state.

Turn Off removes the folder (or the variable). `disableAllHooks`, `--safe-mode`,
and an organization's `allowManagedModsOnly` or `allowManagedHooksOnly` stop the
mod; the first two stop the status line too.

**Fit with ADR 0001: fits the decision, needs an amendment to name the
interface.** Claude Code still authenticates and reads the headers; the mod sees
only the figures the status line sees; CapaTheNotch reads no credential and
contacts no Anthropic endpoint. What is new is that CapaTheNotch's own code runs
inside the Provider's process, where it *could* call `$.env.get` or
`$.settings.read`. So the amendment should say what the mod may call, and a test
should hold it to that: `claude plugin validate --json` lists every event and
API call a module makes; it should list `session.start`, `session.measure`,
`session.usage`, `session.id` and `process.run`, and nothing else.

**Fragility.** Medium-low. The API is documented and on by default, but young
(early access ended at 2.1.287; the reference is "as of v2.1.290"), so names
may move; the mod should fail silently (a hook that throws is skipped) and the
app should go Stale as it does today. People on 2.1.286 or older, WSL desktop
sessions, and managed machines that allow only managed mods are not covered.

**Not verified.** No mod was written or loaded — writing one into this
session's mods folder would have raised the hot-reload question, and the task
was read-only. The first step of the ticket should be a ten-line probe mod
loaded with `CLAUDE_CODE_PLUGIN_DIRS` in a desktop Code-tab session, confirming
that `session.measure` arrives with both windows after a reply.

### 2. `cachedUsageUtilization` in `~/.claude.json` — a fallback, not a source

**What it gives.** `fetchedAtMs`, and under `utilization`: `five_hour` and
`seven_day` each with `utilization` and `resets_at`, plus a `limits[]` list
(`kind` `session` / `weekly_all` / `weekly_scoped`, `percent`, `resets_at`).
Here: fetched 2026-10-06 17:18, five-hour 13 % resetting 14:40 UTC, weekly 6 %
resetting 2026-10-11 14:59 UTC — two days old.

**Evidence.** In the binary, `D6o` writes it after a successful read of the
plan-usage endpoint, at most once a minute (`ynt=60000`), and readers accept it
for an hour (`ALn=3600000`). Changelog: "editor windows and non-interactive
sessions on one machine now share a read made in the last minute instead of
each calling the usage endpoint". So it refreshes only when something asks the
endpoint: the terminal's `/usage`, the VS Code extension's usage meter, or an
SDK host's `get_usage` control request. The desktop app does none of these —
its own main process asks the endpoint itself.

**Once.** Nothing, or consent to read the file.

**ADR 0001: needs an amendment.** No credential (tokens are in the Keychain),
but the file holds `oauthAccount` and other private state of Claude Code, and
is undocumented.

**Fragility.** High: a private cache whose schema already has a dozen
code-named keys. Worth at most a fallback for VS Code people, and the mod covers
them anyway.

### 3. The desktop app's HTTP cache — works, but private

**What it gives.** The JSON of `GET /api/organizations/<id>/usage` that the
desktop app draws its usage view from, with both windows and reset times. Four
cache entries under `~/Library/Application Support/Claude/Cache/Cache_Data/`
match that path; the newest was written at 14:36:50 today, minutes before this
was checked.

**Evidence.** The route ticket 03 recorded from `vinzdg/codenotch`, still
alive.

**Once.** Nothing.

**ADR 0001: needs an amendment** (reading another application's private
Chromium cache; no credential, no request).

**Fragility.** High: Chromium's Simple Cache format, a compressed body, an
undocumented endpoint, and it covers only the desktop app.

### 4. `plan-usage-history.json` in the desktop app's folder — no

**What it gives.** `{ version: 2, samples: [{ t, org, u: { fh, sd, … } }] }`:
integer percentages, every 15 minutes, **no reset times**. Here the last sample
is 2026-09-25 11:48.

**Evidence.** Desktop `app.asar`: `cyi` appends after each background plan-usage
poll; the poll pauses when "tray not opened recently", a remotely set
`pollRequiresTrayOpenWithinHours` that `main.log` shows as 24 hours. The live
reading itself (`new RRe({ name: "plan-usage" })`) is held in memory only.

**ADR 0001: needs an amendment.** **Fragility:** high, and it lacks resets.

### 5. The stream-json `rate_limit_event` — exists, unreachable

Claude Code emits `{ type: "rate_limit_event", rate_limit_info }` on stdout in
stream-json mode, "when rate limit info changes". `rate_limit_info` has
`status`, `resetsAt`, `rateLimitType`, `utilization`, and an `@internal`
`unifiedWindows` with `five_hour` and `seven_day` `{ utilization, resetsAt }`
"emitted when a window's rounded percentage or reset time moves". There is also
an experimental `get_usage` control request returning `rate_limits` from the
usage endpoint. Both live on the pipe the desktop app or the VS Code extension
owns. Neither is written to a file: no transcript, desktop session folder, log,
IndexedDB or Local Storage file contains `rate_limit_event` or `unifiedWindows`,
and the desktop app only passes the event through. A third party could reach it
only by wrapping the `claude` binary the host starts, which nobody should do.

### 6. Settings hooks — no limits

None of the 33 hook events in 2.1.293 (`ConfigChange` … `WorktreeRemove`)
carries rate limits; the shared input is `session_id`, `transcript_path`, `cwd`,
`prompt_id`, `permission_mode`, agent fields and `effort`. Transcripts carry no
rate-limit records either. A hook command could only get limits by asking the
endpoint with the session's `CLAUDE_CODE_OAUTH_TOKEN`, which it inherits in
desktop sessions — that **violates** ADR 0001. (A mod can hook these events as
`classic.*`, but candidate 1 needs none of them.)

### 7. OpenTelemetry to a local collector — no limits

Metrics: `session.count`, `lines_of_code.count`, `pull_request.count`,
`commit.count`, `cost.usage`, `token.usage`, `code_edit_tool.decision`,
`active_time.total`. Events: `user_prompt`, `assistant_response`, `tool_result`,
`tool_decision`, `api_request`, `api_error`, `api_refusal`,
`api_retries_exhausted`, raw bodies, and housekeeping
([Monitoring](https://code.claude.com/docs/en/monitoring-usage)). The binary's
`api_request` attributes are model, tokens, cost, duration, request ids, speed,
query source and effort — no rate-limit header, and raw API bodies do not carry
headers. A localhost collector would give tokens and cost, not the plan's
windows.

### 8. `claude` subcommands — none

The 2.1.293 command table has no usage command with machine output (`auth`,
`plugin`, `mcp`, `doctor`, … only). `/usage` stopped printing plan limits in
2.1.263, and running `claude` from the app is what the 2026-10-06 amendment
gave up.

## Recommendation

Build candidate 1: a CapaTheNotch mod that forwards `session.measure`'s
`rateLimits` to the existing bridge, loaded from a folder the app keeps outside
its bundle, set up after one consent at launch. Start with the live probe named
above and settle the loading route (skills directory vs. `CLAUDE_CODE_PLUGIN_DIRS`)
on what the desktop app actually loads. Record it as an amendment to ADR 0001
that names the mods API as a Provider-owned interface and lists the calls the
mod may make. Keep the status-line bridge as it is: it costs nothing where it
runs, and covers Claude Code older than 2.1.287. Drop candidates 2–4 unless the
probe fails.

## Confirmed live, 2026-10-08

A ten-line test mod (`session.measure` → append the `rateLimits` to a file
outside the project) was loaded by hot reload into a desktop Code-tab session
(Claude Code 2.1.293, the Claude desktop app) and removed afterwards. At the
end of the first turn after it loaded, it received:

    {"changed":["context","rateLimits","cost"],
     "rateLimits":[{"kind":"five_hour","percentUsed":27,"resetsAt":"2026-10-08T12:50:00.000Z"},
                   {"kind":"seven_day","percentUsed":34,"resetsAt":"2026-10-11T15:00:00.000Z"}]}

Both windows, with reset times, in the desktop app. The status-line file at
the same moment still held 16% for the week, a day old. Notes from the test:
the event fires when a turn ends, not after each tool call; `$.fs.write` to an
absolute path outside the project worked.
