# Capacity Notch

Capacity Notch is a glanceable macOS surface for AI-service Capacity. It reads
Codex through its own App Server and Claude Code through Claude Code itself —
its `/usage` command, and the status-line bridge where one runs. It never
reads a credential.

## Install

Capacity Notch is a free beta for Apple Silicon Macs running macOS 14 or
later.

**It is not signed with an Apple Developer ID and not notarized by Apple.**
That costs a paid Apple membership this project does not have. It means two
things you will notice:

- **macOS warns you the first time you open it**, because Apple has not
  checked it. The steps below approve this one application; nothing asks you
  to turn Gatekeeper off, and you should not.
- **macOS forgets its permissions at every update.** Its signature is made
  fresh with each build, and macOS remembers a permission against a
  signature, so after installing a new version you may be asked again for
  anything you had allowed — notifications, for instance.

To install:

1. Download `CapacityNotch-<version>.zip` and its `.sha256` from the latest
   release.
2. Check the download, in the folder you saved both to:

   ```sh
   shasum -a 256 -c CapacityNotch-<version>.zip.sha256
   ```

   It must print `OK`. If it does not, delete the download.
3. Open the zip and move `CapacityNotch.app` to Applications.
4. Open it. macOS says it could not verify the application; close that
   message.
5. Open **System Settings → Privacy & Security**, scroll down, and click
   **Open Anyway** beside Capacity Notch. When the warning comes back, click
   **Open**. From then on it opens like any other application.

To update, choose **Check for Updates…** in the menu bar menu or in Settings.
It opens the latest release on GitHub; Capacity Notch never checks on its
own. Quit the running copy, then repeat the steps above with the new zip —
step 5 again, because the new build is a new signature to macOS.

## Requirements

- Apple Silicon
- macOS 14 or later
- Swift 6 toolchain

## Verify

Run the executable seam checks:

```sh
swift run CapacityNotchTests
```

Build the executable:

```sh
swift build --product CapacityNotch
```

Build the release archive — the same bytes from the same commit and Swift
toolchain, with no builder's home directory inside:

```sh
./Scripts/build-release.sh
```

It writes `dist/CapacityNotch-<version>.zip` and its `.sha256`.

Build an ad-hoc signed application bundle for the install loop:

```sh
./Scripts/build-app.sh
```

The bundle is written to `.build/CapacityNotch.app`.

## Connect Codex

Capacity Notch reads Codex Capacity through the official Codex App Server. Pick
**Connect Codex** in the menu bar: it starts one `codex app-server` process,
performs the `initialize` handshake, and reads `account/rateLimits/read`. Live
`account/rateLimits/updated` notifications and a sixty-second refresh keep the
surface current without a relaunch. **Disconnect Codex** and Quit end only the
App Server that Capacity Notch started.

Capacity Notch sends four App Server methods and no others: `initialize`,
`initialized`, `account/read`, and `account/rateLimits/read`. It never reads,
copies, stores, or refreshes a Codex credential — sign in with `codex login`.

## Connect Claude Code

Claude Code officially supplies five-hour and seven-day subscription usage to
status-line commands after the session's first API response. Capacity Notch's
bridge accepts that JSON on stdin and persists only the capture time, used
percentages, and reset times. It discards session IDs, prompts, transcript
paths, credentials, and every unrelated field. Capacity Notch never calls
Anthropic.

Capacity Notch asks Claude Code for its own usage with `claude /usage`, a local
command that sends no prompt to the model. Claude Code makes the request with
the credential it already holds, so Capacity Notch reads no credential and
speaks to nothing but the binary. This works wherever you are — a terminal, the
desktop app, VS Code, or nothing open at all — and runs at most once every five
minutes.

The status-line bridge below adds free live updates on top of that, without a
subprocess and with structured data rather than prose. Whichever source saw the
windows last is the one shown. Setting it up is optional.

Claude Code runs a status line only in a terminal session. The desktop app and
the VS Code extension run the same `claude` binary with `--output-format
stream-json`, which has no text interface and so no status line to fill, and
they never invoke the command. Claude Capacity therefore refreshes while you
work in a terminal and goes visibly Stale otherwise. Hooks fire in every
surface but carry no usage figures. Codex is unaffected — Capacity Notch runs
its App Server itself.

Build the app bundle, copy it to `/Applications`, then add this to
`~/.claude/settings.json` (merge the `statusLine` key with your existing
settings):

```json
{
  "statusLine": {
    "type": "command",
    "command": "/Applications/CapacityNotch.app/Contents/MacOS/CapacityNotchClaudeBridge",
    "refreshInterval": 60
  }
}
```

If you already have a status line, keep its output by forwarding the same JSON
to it. Replace the last command with your existing executable or script:

```json
{
  "statusLine": {
    "type": "command",
    "command": "/Applications/CapacityNotch.app/Contents/MacOS/CapacityNotchClaudeBridge -- /Users/you/.claude/statusline.sh",
    "refreshInterval": 60
  }
}
```

Run Claude Code through one response, then choose **Connect Claude Code…** in
the menu bar. Readings older than five minutes are visibly Stale Capacity; a
missing snapshot is disconnected rather than being shown as `0%`. The bridge
works for subscription accounts for which Claude Code exposes `rate_limits`.
See [Anthropic's status-line documentation](https://code.claude.com/docs/en/statusline).

## License

Capacity Notch is available under the MIT License. See `THIRD_PARTY_NOTICES.md` for reference-project attribution.
