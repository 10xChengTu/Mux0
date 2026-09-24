<div align="right">
  <strong>English</strong> | <a href="README.zh-CN.md">简体中文</a>
</div>

<div align="center">
  <img src="mux0/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" alt="Mux0 Logo" width="120" />
  <h1>Mux0</h1>
</div>

A macOS tabbed-and-split terminal with live AI agent status in the sidebar. Organize terminals by project, split panes freely, and always know at a glance whether Claude Code, OpenCode, Codex, pi, or Grok is running, idle, or waiting for you.

Powered by the [ghostty](https://ghostty.org) engine with Metal GPU rendering. Bilingual UI — English / 简体中文.

## Features

- **Workspaces → Tabs → Splits** — Organize terminals by project. Each workspace owns its own set of tabs; each tab is a split tree you can cut horizontally or vertically, drag dividers, and navigate with the keyboard.
- **Live AI Agent Status** — Sidebar and tab icons reflect `running` / `idle` / `waiting-for-input` / `finished` state for Claude Code, OpenCode, Codex, pi, and Grok. Each turn is tagged success or failed. Hover an icon to see the currently running tool and a short summary of the agent's last reply (Claude / Codex / pi / Grok).
- **Workspace Sidebar Metadata** — Every workspace row shows its current git branch, open PR status, and unread notifications — refreshed every 5 seconds in the background and updated live via OSC hooks from your shell.
- **Beautiful Theming** — Every ghostty theme bundled in. Adjust background opacity, window blur (vibrancy), cursor shape and blink, and unfocused-pane dimming. Mux0's own sidebar and tab bar re-tint to match the active terminal theme — no jarring chrome.
- **Bilingual UI** — Full English and Simplified Chinese. Switch in **Settings → Appearance → Language** without restarting.
- **Layout Persistence** — Workspace list, tab list, split layout, and each terminal's working directory survive across restarts.
- **Auto-Update** — In-app updates powered by Sparkle. A dot appears in the sidebar footer when a new version is ready; release notes are shown inline and you can defer or skip any release.

![Mux0 screenshot placeholder](images/screenshot.png)

## System Requirements

- macOS 14.0 or later
- Apple Silicon strongly recommended (for Metal GPU rendering)

## Getting Started

### 1. Install

1. Download the latest `mux0.dmg` from [GitHub Releases](https://github.com/10xChengTu/mux0/releases).
2. Open the DMG and drag **Mux0** into your **Applications** folder.
3. Launch Mux0. On first launch macOS may show a security warning — go to **System Settings → Privacy & Security** and click **Open Anyway**.

After that, Mux0 checks for updates once a day automatically. You'll see a small dot in the sidebar footer when a new version is available.

### 2. Create Your First Workspace

1. Click the **＋** button in the sidebar.
2. Pick a project folder — this becomes the workspace's working directory.
3. The sidebar will immediately start tracking that folder's git branch, PR status, and notifications.

Tip: you can add as many workspaces as you like. Each one keeps its own tabs and split layout independently.

### 3. Open Tabs and Split Panes

- **New tab** — `⌘T`, or the **＋** button in the tab bar.
- **Close tab** — `⌘W`, middle-click the tab, or use the ✕ button.
- **Split horizontally** — `⌘D`.
- **Split vertically** — `⌘⇧D`.
- **Move focus between panes** — `⌘⌥` + arrow keys.
- **Resize** — drag the divider with the mouse.
- **Rename tab / workspace** — double-click the title.
- **Reorder** — drag tabs or workspace rows.

### 4. Pick a Theme

Press `⌘,` to open **Settings**, then:

- **Appearance → Theme** — pick any ghostty theme. The sidebar and tab bar re-tint to match.
- **Appearance → Background Opacity** — drop below 1.0 for a translucent window.
- **Appearance → Background Blur** — combined with lower opacity, gives a frosted-glass effect.
- **Font → Font Family / Font Size** — pick any monospace font on your system.

See [`docs/settings-reference.md`](docs/settings-reference.md) for every setting.

### 5. Switch Language (Optional)

**Settings → Appearance → Language**: *System* (follow macOS language), *English*, or *简体中文*. The change applies instantly across the entire UI.

## Using AI Agents in Mux0

Mux0 automatically hooks into Claude Code, OpenCode, Codex, pi, and Grok so their status shows live on the sidebar and tab icons. You don't need to configure anything — just run the agent as usual. Injection is per-process (a wrapper adds a flag or points the CLI at a private config overlay), so your own global agent config stays untouched.

### Status Icons

| Icon color | Meaning |
|---|---|
| Green (pulsing) | Agent is running — a turn is in progress. |
| Amber | Agent is waiting for your input (permission request, clarifying question). |
| ✓ (green check) | Last turn finished cleanly. |
| ✕ (red cross) | Last turn had at least one tool error. |
| Gray | Idle / no agent running. |

Hover a status icon to see which tool is currently running (e.g. *"Edit Models/Foo.swift"*, *"Bash: ls"*) and a one-line summary of the agent's last reply (Claude / Codex / pi / Grok).

### Supported Agents

| Agent | Command | Notes |
|---|---|---|
| **Claude Code** | `claude` | Full status + turn summary + tool detail. |
| **OpenCode** | `opencode` | Full status + tool detail. Summary not available yet. |
| **Codex** | `codex` | Status is experimental — may lag slightly behind. |
| **pi** | `pi` | Full status + turn summary + tool detail. Loaded as a per-process pi extension (`pi -e`), so `~/.pi` is untouched. pi has no permission prompt, so "waiting for input" only appears when an extension asks you something. |
| **Grok** | `grok` | Full status + turn summary + tool detail + resume. Runs through a private `GROK_HOME` overlay, so `~/.grok` is untouched and sessions stay listable by `grok --resume` outside Mux0. |

If an icon doesn't update, see [Troubleshooting](#troubleshooting) below.

## Troubleshooting

### Agent status icon isn't updating

- Make sure **Settings → Shell → Shell Integration** is enabled (default: *detect*).
- Close and re-open the terminal tab. The hooks activate when a new shell starts, so any shells that were already open before you last upgraded Mux0 won't be wired up.
- If you customized your shell's rc files (`~/.zshrc`, `~/.bashrc`, etc.) and disabled ghostty's shell integration, you'll need to re-enable it.

### Theme or font didn't change after saving

Settings debounce for ~200 ms before applying. If a change still hasn't appeared after a second or two, toggle the setting off and back on, or quit and relaunch Mux0.

### Window blur / transparency looks wrong

Blur only has visible effect when **Background Opacity** is below 1.0. If you want a frosted-glass look, lower the opacity first, then raise the blur radius.

### "Mux0 can't be opened" on first launch

This is macOS's Gatekeeper warning. Go to **System Settings → Privacy & Security**, scroll to the bottom, and click **Open Anyway** next to the Mux0 entry. You only need to do this once.

### Auto-update didn't pick up a new release

Auto-update runs at most once a day. To force a check, open **Settings → Update** and click **Check for Updates**.

## Building from Source

```bash
./scripts/build-vendor.sh   # build libghostty (once)
xcodegen generate
xcodebuild -project mux0.xcodeproj -scheme mux0 -configuration Debug build
```

See [`docs/build.md`](docs/build.md) for the full prerequisites, vendor layout, and release workflow.

### Persist local permissions across rebuilds (optional)

By default, Debug builds are **ad-hoc signed** — every `xcodebuild` produces a new `cdhash`, which macOS TCC treats as a different app and revokes any Files & Folders / Full Disk Access permissions you previously granted. The popups come back after every rebuild.

To fix this, sign Debug builds with a stable Apple Development cert:

1. Make sure your Apple ID is signed into **Xcode → Settings → Accounts**.
2. Copy the template and fill in your 10-char Team ID:
   ```bash
   cp Local.xcconfig.example Local.xcconfig
   # then edit Local.xcconfig:
   # DEVELOPMENT_TEAM = XXXXXXXXXX
   ```
3. `xcodegen generate && xcodebuild ... build` — verify with:
   ```bash
   codesign -dv ~/Library/Developer/Xcode/DerivedData/mux0-*/Build/Products/Debug/mux0.app 2>&1 | grep Authority
   ```
   You should see `Authority=Apple Development: <Your Name> (...)` instead of `adhoc`.

`Local.xcconfig` is gitignored. Skipping this step is fine — the build still works, you just keep the ad-hoc popup loop.

## Documentation

- [Settings reference](docs/settings-reference.md) — every setting explained
- [Agent hooks reference](docs/agent-hooks.md) — how status icons are wired up
- [Build & vendor](docs/build.md) — libghostty, signing, release pipeline
- [Internationalization](docs/i18n.md) — supported languages and behavior

## License

Mux0 is released under a **Source-Available License** — see [`LICENSE`](LICENSE). In plain English:

- **✅ Using Mux0 is free, including for commercial work.** Use it personally, use it at your company, use it to build and ship commercial products — just like you'd use any other terminal app. Anything you create inside Mux0 is yours.
- **✅ Forking to contribute back is welcome.** Fork on GitHub, make your changes, and open a PR. We appreciate contributions.
- **🚫 Redistributing Mux0 itself is not permitted.** No reselling, no bundling Mux0 into a product you ship, no hosting it as a service, no maintaining a competing fork as a parallel distribution. The source is published for transparency and contribution, not re-use as a product.

This is not an OSI-approved open-source license. For redistribution, bundling, hosting as a service, or maintaining a non-contribution fork, please contact the copyright holder.

**Contributions.** By submitting a pull request you agree to the terms in [LICENSE § 9](LICENSE) — in short, you grant the project permission to use and relicense your contribution as part of Mux0.
