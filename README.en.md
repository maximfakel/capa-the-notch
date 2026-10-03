# Capacity Notch

[Русский](README.md) · **English**

Codex, Claude Code and OpenCode limits in the MacBook notch — beside the camera, at a
glance. Music, a teleprompter and dictation live there too.

**Website:** https://capacitynotch.vercel.app/ ·
**Download:** [latest release](https://github.com/maximfakel/capacity-notch/releases/latest)

A free beta for Apple Silicon Macs running macOS 14 or later.

## What it does

- **Limits.** What is left in the five-hour and weekly windows of Codex,
  Claude Code and OpenCode (its Go plan) — any two at once — when they reset, and whether it will last until then. An alert
  when a window drops below 10%.
- **Music.** What is playing, the artwork, seeking, the controls and the Mac's
  volume — for any player that shows its track in Control Center.
- **Teleprompter.** A Script scrolls right under the camera, so you can read
  and look into the lens. While it runs, the surface is kept out of screen
  recording and sharing.
- **Dictation.** Hold ⌃⌥D (or a shortcut of your own), speak, let go — the text appears at the cursor.
  Recognised entirely on this Mac, with GigaAM.

Each module is turned on on its own in Settings. The interface speaks English
and Russian.

## Privacy

- Capacity Notch asks Codex and Claude Code **without their credentials**:
  Codex through Codex's own App Server, Claude Code through its `/usage`
  command.
- **OpenCode is the one exception.** OpenCode has no way of its own to report
  its limits, so with your consent Capacity Notch reads your OpenCode Go key
  from OpenCode's own file and asks opencode.ai only for the plan's usage. The
  key is kept nowhere and sent nowhere else.
- **Dictation stays on the Mac.** Audio is never saved. A history of
  recognised text is off unless you turn it on.
- Copied diagnostics carry versions, states and timings — no addresses,
  identifiers or dictated text.

## Install

**It is not signed with an Apple Developer ID and not notarized by Apple** —
that is a paid membership this project does not have. So:

- **macOS warns you the first time you open it**, because Apple has not
  checked it. The steps below approve this one application; nothing asks you
  to turn Gatekeeper off, and you should not;
- **what you allow is kept across updates.**

1. Download `CapacityNotch-<version>.zip` from the
   [latest release](https://github.com/maximfakel/capacity-notch/releases/latest).
2. Open the zip and move `CapacityNotch.app` to Applications.
3. Open it. macOS says it could not verify the application; close that
   message.
4. Open **System Settings → Privacy & Security**, scroll down, and click
   **Open Anyway** beside Capacity Notch. When the warning comes back, click
   **Open**.

**Updating.** Choose **Check for Updates…** in Settings → General; it opens
the latest release on GitHub. Capacity Notch never checks on its own. Quit the
running copy and repeat the steps above with the new zip — step 4 likely
again.

## Connecting

**Codex.** Sign in with `codex login` and turn on Codex in Settings →
Providers. Capacity Notch starts its own `codex app-server` and reads the
limits from it.

**Claude Code.** Turn on Claude Code in Settings → Providers. Capacity Notch
asks `claude /usage` at most once every five minutes — a local command that
sends nothing to the model. It works wherever you work: a terminal, the
desktop app, VS Code.

Optionally, add the status-line bridge, and terminal sessions update the
limits at once. Add this to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "/Applications/CapacityNotch.app/Contents/MacOS/CapacityNotchClaudeBridge",
    "refreshInterval": 60
  }
}
```

If you already have a status line, pass it after `--` and it keeps working:

```json
{
  "statusLine": {
    "type": "command",
    "command": "/Applications/CapacityNotch.app/Contents/MacOS/CapacityNotchClaudeBridge -- /Users/you/.claude/statusline.sh",
    "refreshInterval": 60
  }
}
```

The bridge keeps only the time, the percentages and the reset times, and
discards everything else. See
[Anthropic's status-line documentation](https://code.claude.com/docs/en/statusline).

**OpenCode.** You need an OpenCode Go or Go Plus subscription. Sign in with
`opencode auth login` and turn on OpenCode in Settings → Providers. Every five
minutes, and when you refresh, Capacity Notch takes the key from
`~/.local/share/opencode/auth.json` and asks `opencode.ai` for the five-hour
and weekly windows. The monthly window is not drawn, but when it is used up
the card says so in red.

Any two of the three Providers can be on at once.

## Building from source

Apple Silicon, macOS 14+, Xcode with the Metal Toolchain, and Swift 6.

```sh
swift run CapacityNotchTests      # checks
./Scripts/build-app.sh            # .build/CapacityNotch.app, ad-hoc signed
./Scripts/build-release.sh        # dist/CapacityNotch-<version>.zip
```

The release archive is reproducible: the same commit and Swift toolchain give
the same bytes. Views declare their state with `State(initialValue:)` rather
than `@State`, whose macro plugin ships inside Xcode.

## License

MIT. Third-party parts — sherpa-onnx, ONNX Runtime, Murmur, GigaAM, the Geist
font, the OpenCode logo — are credited in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

Capacity Notch is not affiliated with, or made by, OpenAI, Anthropic or the
OpenCode team.
