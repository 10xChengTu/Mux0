# mux0 设置项说明

mux0 的设置面板分成七个 tab：**Appearance（外观）**、**Font（字体）**、**Terminal（终端）**、**Shell**、**Quick Actions（快捷操作）**、**Agents**、**Update（更新）**。
每个设置项底层都对应一个 ghostty 的 config key，写入到 mux0 的 override 配置里（保存后即时生效）。
每个 tab 底部的 **Reset** 按钮会把这个 tab 涉及到的 key 从 override 里清空，回到默认值。

---

## 1. Appearance（外观）

控制窗口视觉表现：主题、透明、模糊、内边距、光标。

| 设置项 | config key | 默认值 | 说明 |
|---|---|---|---|
| Theme | `theme` | — | 终端主题（配色方案）。决定前景色、背景色、16 色调色板等。mux0 的主题也会跟随它变化。 |
| Background Opacity | `background-opacity` | `1.0` | 终端窗口背景的不透明度。`1.0` 完全不透明；`0.0` 完全透明。配合下面的 Blur 可做毛玻璃效果。 |
| Background Blur | `background-blur-radius` | `0` | 背景模糊半径，范围 `0…100`。仅在 Opacity < 1 时有视觉效果，用来做毛玻璃。 |
| Window Padding X | `window-padding-x` | `2` | 终端内容区左右两侧的内边距（列数/像素由 ghostty 规则决定）。增大可以让文字离窗口边缘远一点，不那么挤。 |
| Window Padding Y | `window-padding-y` | `2` | 终端内容区上下两侧的内边距。 |
| Cursor Style | `cursor-style` | `block` | 光标形状：`block`（方块）/ `bar`（竖线）/ `underline`（下划线）。 |
| Cursor Blink | `cursor-style-blink` | `false` | 光标是否闪烁。关了更安静，不会打扰视线。 |
| Unfocused Pane Opacity | `unfocused-split-opacity` | `0.7` | 非聚焦 pane 的不透明度。同一 tab 内多个 pane 并排时，未聚焦的 pane 会按这个透明度变暗以突出焦点。（config key 保留 ghostty 的 `unfocused-split-opacity` 名称以兼容既有配置；mux0 自行在 view 层实现，不依赖 ghostty 的 split tree。） |

---

## 2. Font（字体）

控制终端的字体与字号。

| 设置项 | config key | 默认值 | 说明 |
|---|---|---|---|
| Font Family | `font-family` | 系统默认等宽字体 | 终端使用的字体族，例如 `JetBrains Mono`、`Menlo`、`SF Mono`。建议选等宽字体，否则对齐会错。 |
| Font Size | `font-size` | `13` | 字号，范围 `6…72`（单位 pt）。 |
| Font Thicken | `font-thicken` | `false` | 是否让字体变"粗一点"。在 Retina 屏上，小字号有时看起来偏细，开了会加粗描边让字更清晰。副作用是字看起来更"肉"。 |

---

## 3. Terminal（终端）

控制终端行为：回滚缓冲、选中复制、鼠标、关闭确认。

| 设置项 | config key | 默认值 | 说明 |
|---|---|---|---|
| Scrollback Limit | `scrollback-limit` | `10_000_000`（一千万字节） | 回滚缓冲区上限（字节数）。决定你往回滚能看到多少历史输出。设太大吃内存，设为 `0` 等于禁用回滚。 |
| Copy On Select | `copy-on-select` | — | 选中文本是否自动复制。`false`：不复制（要 ⌘C）；`true`：复制到普通剪贴板；`clipboard`：复制到系统剪贴板（跨 app 可粘贴）。 |
| Hide Mouse While Typing | `mouse-hide-while-typing` | `false` | 打字时自动隐藏鼠标指针，防止指针挡住正在输入的位置。 |
| Confirm Close | `confirm-close-surface` | — | 关闭终端 surface 时是否弹确认框。`true`：有运行中的进程才问；`false`：从不问；`always`：总是问。防止误关正在跑的命令。 |

---

## 4. Shell

控制 shell 启动方式与 shell 集成。

| 设置项 | config key | 默认值 | 说明 |
|---|---|---|---|
| Shell Integration | `shell-integration` | `detect` | 是否启用 ghostty 的 shell 集成脚本。`detect`：根据当前 shell 自动选；`none`：不启用；其余 `fish` / `zsh` / `bash`：强制按该 shell 注入。集成脚本提供光标跳转、OSC7 目录跟踪、`sudo` 转发等能力。 |
| Integration Features | `shell-integration-features` | 全开 | 选择启用哪些集成特性（可多选）：<br>• `cursor` 智能光标形状（命令模式 / 输入模式切换）<br>• `sudo` 让 `sudo` 透传一些终端变量<br>• `title` 自动设置终端标题为当前命令 / 目录<br>• `ssh-env` 在 ssh 时把 terminfo 等环境带到远端 |
| Custom Command | `command` | （空，用默认 shell） | 指定终端启动时跑的命令。为空则用系统默认 shell（`$SHELL`）。填 `nvim` 就是一打开终端直接进 nvim；填 `tmux` 就是直接进 tmux。 |

---

## 5. Quick Actions

控制顶栏 Quick Actions Bar 的内容：哪些快捷操作启用、按什么顺序排、内置 action 的命令是否被用户覆盖、有哪些自定义条目。整组数据通过下面三个 key 持久化在 mux0 config，UI 在 `Settings → Quick Actions` 下统一编辑。

| 设置项 | config key | 类型 | 默认值 | 说明 |
|---|---|---|---|---|
| Enabled & order | `mux0-quickactions-enabled` | JSON 数组 | `[]` | 启用且按显示顺序排列的 quick action id。同时承载启用集合与启用集合内部顺序。 |
| Builtin command override | `mux0-quickactions-builtin-command-<id>` | string | （空 = 默认命令） | 内置 action 的命令覆盖。`<id>` ∈ `{lazygit, claude, codex, opencode}`。空字符串等同删除该覆盖。 |
| Custom actions | `mux0-quickactions-custom` | JSON 数组 | `[]` | 自定义 action 列表。`[{"id":"<uuid>","name":"...","command":"..."}]`。 |

命令字段的语义：传给 shell 直接执行的字符串（不含 `\n`，由 ghostty 启动逻辑追加）。可以包含 shell 解释的语法，例如 `lazygit -p $PWD`、`claude --resume`、`tig log`。

身份按 id 区分（不是 name 也不是 command）；改命令不会让现有 tab 变成另一个 action 的 tab。

---

## 6. Agents

设置面板分成两个分组：**Notifications** 控制状态图标；**Resume on Launch** 控制下次启动时是否自动恢复上次的 agent 会话。两个分组下的开关互相独立，默认全部关闭。底部 **Reset** 一次性清掉本 tab 的全部 key。

### 6.1 Notifications

控制哪些 code agent 会在 sidebar / tab 上显示状态图标。至少打开一个时，图标列才会出现在 UI 上。

| 设置项 | config key | 默认值 | 说明 |
|---|---|---|---|
| Claude Code | `mux0-agent-status-claude` | `false` | 开启后，Claude Code wrapper 发来的 running / idle / needsInput / turn-finished 事件会显示在对应终端的状态图标上。关闭则所有 claude 事件被监听层静默丢弃。 |
| Codex | `mux0-agent-status-codex` | `false` | 同上，对应 Codex wrapper。Codex 需要用户在 `~/.codex/config.toml` 中显式打开 `[features] codex_hooks = true`，否则只有 turn 完成事件，见 `docs/agent-hooks.md#codex-的特殊规则`。 |
| OpenCode | `mux0-agent-status-opencode` | `false` | 同上，对应 OpenCode 插件。 |

### 6.2 Resume on Launch

启用后，每次 `UserPromptSubmit` 都会把 `claude --resume <id>` / `codex resume <id>` 持久化到对应 terminal 的 `pendingPrefills`；下次启动该 terminal 时自动把这条命令塞进 shell 执行（优先级高于侧边栏 `defaultCommand`）。详见 `docs/agent-hooks.md#resume-command-持久化`。

| 设置项 | config key | 默认值 | 说明 |
|---|---|---|---|
| Claude Code | `mux0-agent-resume-claude` | `false` | 开启后，每次 `UserPromptSubmit` 都把 `claude --resume <session_id>` 落盘；关闭时 `HookDispatcher` 直接丢弃 `resumeCommand` 字段，且立刻调 `WorkspaceStore.clearResumePrefills(forAgent: .claude)` 把已存的 claude 命令全清空。 |
| OpenCode | `mux0-agent-resume-opencode` | `false` | 同上，对应 OpenCode（命令形态 `opencode --session <id>`）。session id 由 `mux0-status.js` plugin 在 `tool.execute.before` 的 `input.sessionID` 拿到，每次 tool 调用都附；mux0 端 equality guard 自动 dedup。 |
| Codex | `mux0-agent-resume-codex` | `false` | 同上，对应 Codex。需要先开 6.1 里的 Codex 通知开关（hook 才会跑）。 |

**扩展性**：将来新增 code agent 时，`HookMessage.Agent` 枚举加一个 case；Notifications 分组自动多出一行 Toggle（managed keys + 行列表均由 `.allCases` 派生）。Resume 分组里所有 `supportsResume` 返回 true 的 agent 都会渲染，所以新 agent 默认 supportsResume = false，等到把 wrapper 端的 `resume_command_for` / plugin 接好且 `Agent.supportsResume` 改成 true = 自动出现在 UI。

**行为细节**：
- Notifications 全关 → sidebar / tab 的状态图标列整列折叠（等同于该功能被禁用）。
- Notifications 某 agent 开关 ON → OFF：已落盘到 `TerminalStatusStore` 的状态会残留（不再收到后续事件也无法自动清理）；新事件被丢弃。这是已知边缘场景。
- Resume ON → OFF 立刻按 prefix（`claude ` / `codex `）扫所有 workspace 的 pendingPrefills，把对应 agent 的旧值清空——保证关 toggle 的下一次启动不会再 auto-resume。
- 关闭一个跑过 agent 的 tab / pane 时，`closeTerminal` / `removeTab` 会同步把对应 terminalId 的 pendingPrefill 一起删掉，避免 UserDefaults 里堆积已死 UUID 的命令。
- 老 key `mux0-status-indicators`：2026-04 之前存在的主开关。从代码中移除；如果仍保留在你的 mux0 config 文件里，mux0 不再读取，手动删除即可。

---

## 说明：Reset 按钮

每个 tab 底部都有一个 Reset 行。点击后会把**当前 tab 涉及到的所有 key** 从 mux0 的 override 配置里删除，恢复成 ghostty 默认值（或主题/字体的默认值）。
不会影响其它 tab 的设置。

## 7. Update

新增在 Settings tab 条最后一位。与其它 section 不同：不读写 mux0 config 文件，状态全部活在内存（`UpdateStore`）+ Sparkle 自管的 `UserDefaults` keys。

**UI 状态（共 7 种）**：`idle`, `checking`, `upToDate`, `updateAvailable(version, releaseNotes)`, `downloading(progress)`, `readyToInstall`, `error(message)`。详见 `docs/superpowers/specs/2026-04-19-auto-update-design.md`。

**Sparkle 自管的 `UserDefaults` keys**（不在 mux0 config 文件里）：
- `SULastCheckTime` — 上次 check 时间
- `SUSkippedMinorVersion` / `SUSkippedMajorVersion` — 用户点了 "Skip This Version"
- `SUAutomaticallyUpdate` — （未使用）静默升级开关
- `SUEnableAutomaticChecks` — 由 Info.plist 设为 `YES`
- `SUScheduledCheckInterval` — 由 Info.plist 设为 86400（24h）

Debug 构建整个 section 仍然渲染，但 "Check for Updates" 按钮 disabled，并附一行 `(Auto-update is disabled in Debug builds.)` 说明。
