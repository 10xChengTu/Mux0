# Agent Hooks

mux0 通过注入到各 AI CLI 的生命周期钩子，把 `running` / `idle` / `needsInput` / `finished` 状态推送到 app 的 `TerminalStatusStore`，驱动 sidebar / tab 上的状态图标。Agent 侧（Claude Code / Codex / OpenCode / pi / Grok）另外在 `.finished` 事件里携带 `exitCode` 哨兵值（0 = turn 干净，1 = turn 里有 tool 报错）和可选的 `summary`（最后一条 assistant 消息）。

实现位于 `Resources/agent-hooks/`，由 `project.yml` 的 postBuildScript 拷贝到 app bundle，运行时通过 `ZDOTDIR` shim 自动激活。

## 支持矩阵

| Agent | 注入机制 | 是否改用户全局配置 | resume 命令 | 状态 |
|-------|----------|--------------------|-------------|------|
| Claude Code | `claude --settings <json>`（wrapper） | 否 | `claude --resume <id>` | 稳定 |
| Codex | `$CODEX_HOME` overlay + `hooks.json` + `-c notify=[...]`（wrapper） | 否（overlay 目录） | `codex resume <id>` | 稳定（0.130 起 hooks 默认开） |
| OpenCode | `~/.config/opencode/plugins/mux0-status.js` 插件 symlink（wrapper） | **是**（唯一一个写用户目录的） | `opencode --session <id>` | 稳定 |
| pi | `pi -e <extension>`（wrapper）+ `pi-extension/mux0-status.js` | 否 | `pi --session <id>` | 稳定（0.8.5 起） |
| Grok | `GROK_HOME` overlay + `hooks/mux0.json`（wrapper） | 否（overlay 目录） | `grok --resume <id>` | 稳定（0.8.5 起） |

## IPC

- 传输：Unix domain socket，路径为 `~/Library/Caches/mux0/hooks-<bundle-hash>.sock`（`<bundle-hash>` = SHA256(`Bundle.main.bundlePath`) 前 8 位十六进制）。按 bundle 路径分命名空间是为了让 `/Applications/mux0.app` 和 Xcode DerivedData 里的 Debug 构建互不抢占 socket——后起的实例 `bind()` 前会 `unlink` 掉同路径的旧 sockfile，会把前一实例踢下线。路径由 `GhosttyBridge.initialize()` 写进 `MUX0_HOOK_SOCK`，终端进程通过 env 继承
- 消息格式：每行一个 JSON，`{"terminalId": "...", "event": "running|idle|needsInput|finished", "agent": "claude|opencode|codex", "at": <epoch>, "exitCode": <int>?, "toolDetail": <string>?, "summary": <string>?, "resumeCommand": <string>?}`。`exitCode` 仅在 `event=finished` 时携带（shell = 真实 `$?`；agent = 0/1 哨兵）；`toolDetail` 仅在 agent 的 `event=running` 时携带（如 "Edit Models/Foo.swift"）；`summary` 仅在 agent 的 `event=finished` 时携带（最后一条 assistant 消息，≤200 chars）；`resumeCommand` 在支持 resume 的 agent（全部五个）的 prompt 触发的 `event=running` 时携带（恢复当前 session 的 CLI，如 `claude --resume <session_id>` / `codex resume <session_id>` / `pi --session <session_id>` / `grok --resume <session_id>`）。
- 监听端：`HookSocketListener`（DispatchSourceRead，accept 循环）

## Session title

每条 socket 消息可携带 `sessionTitle` —— 当前 agent 会话的人类可读名字，用于驱动 mux0 的 tab 自动命名（`TerminalSessionTitleStore`）。三个 agent 各自的来源：

| Agent | 来源 | 时机 |
|-------|------|------|
| Claude | `custom-title`（`/rename`）→ `ai-title`（LLM 异步生成）→ 第一条非 slash-command、非 meta 的 user message（typed-content-block 展开） | `prompt` / `stop` |
| Codex | `event_msg.thread_name_updated` 的 `thread_name`（LLM 生成）→ 第一条 `event_msg.user_message`。两者都从 `~/.codex/sessions/**/rollout-*-<session_id>.jsonl` 单次扫描 | `prompt` / `stop` |
| OpenCode | plugin `input.session?.title`（LLM 生成）→ plugin 进程内缓存的"该 session 首条 chat.message 文本"（typed parts 展开） | `chat.message` / `tool.execute.before` |
| pi | `session_info_changed` 的 `event.name`（仅 `/name` / `pi.setSessionName()` 触发，pi **没有** LLM 自动标题）→ 扩展进程内缓存的首条 prompt | `before_agent_start` / `agent_end` / `session_info_changed` |
| Grok | `sessions/**/<session_id>/summary.json` 的 `generated_title`（LLM 生成，异步写入）→ 同目录 `chat_history.jsonl` 首条 `<user_query>` | `prompt` / `stop` |

策略一致：**LLM-generated title 优先于 first user message fallback**，与各 agent 自己 `--resume` picker 的显示语义对齐。LLM title 生成是异步的——短对话或新 session 第一次 emit 可能没有，fallback 到首条 user prompt 保证 tab 仍有可辨识标签。Codex 的 thread_name 与 SQLite `threads.title` 是同一份 LLM 输出，我们走 JSONL 路径（与 thread_name_updated 事件来自同一文件，零额外 IO）。Claude 的 `/rename` 写入的 `custom-title` 是即时的，永远胜过稍后写出的 `ai-title`。Swift 端 `TerminalSessionTitleStore.update` 丢弃空字符串，避免文件还没 flush 时覆盖已知值。

用户在 mux0 内 inline rename tab 后，`TerminalTab.userRenamed = true`，`displayTitle` 锁定不再吃 `sessionTitle`。右键菜单「Reset to auto title」清除锁定。

`HookDispatcher` 路由 `sessionTitle` 时**不**走 `mux0-agent-status-<agent>` 门控 —— 只要插件 emit 了，tab 命名就跟上，与"是否显示状态图标"完全独立。

## Agent Turn 成败检测

Agent turn 没有真实的 exit code，但 Claude Code / Codex 的 `PostToolUse` hook 和 OpenCode 的 `tool.execute.after` 插件事件都带结构化的 "tool 报错了吗" 字段。mux0 在每个 turn 内聚合这些 per-tool 信号到一个布尔 `turnHadError`，在 `Stop` / `session.idle` 时发 `finished` 事件，`exitCode` 设为 0（clean）或 1（had errors）。

**Claude / Codex**（命令行 hook，无状态每次 fork 一个 agent-hook.sh）：per-session 状态存在 `~/Library/Caches/mux0/agent-sessions.json`，按 `session_id` 索引。`PostToolUse` 把 `tool_response.is_error` 粘滞累加（一个 turn 里任一 tool 失败就是失败）；`Stop` 读取后清除该 session 条目并 emit。过期（>1h 未 touch）的条目每次 hook 调用时自动 GC。

**OpenCode**（长驻插件进程）：状态保存在插件 closure 的 `turn` 对象里，`tool.execute.after` 累加 `args.error` / `args.result.status === "error"`，`session.idle` 时 emit。插件进程重启（opencode 退出 / 重开）会丢状态，但同时 opencode 自己也重建 session，语义无歧义。

**pi**（长驻扩展，与 OpenCode 同构）：`pi-extension/mux0-status.js` 在 closure 里记 `state.turnHadError`，`tool_execution_end` 的 `event.isError` 粘滞累加，`agent_end` 时 emit `finished`。

**Grok**（命令行 hook）：与 Claude / Codex 共用 `agent-hook.py` 的 session 文件。grok 的报错字段既不是 `tool_response` 也不是 `is_error`（那是 Claude 的形状）：结果放在**顶层 `toolResult`**，而且**命令退出码非 0 照样走 `PostToolUse`**（不是 `PostToolUseFailure`），只有结构化字段能看出失败——实测 grok 1.0.41 跑 `ls /nonexistent` 得到 `{"type":"Bash","exit_code":1,"signal":null,"timed_out":false,"output_for_prompt":"exit: 1\n..."}`，全程没有 `is_error`。所以 `tool_response_had_error` 认：`is_error`/`isError`/`isFailure` 布尔、非空字符串 `error`、**非 0 `exit_code`**、`timed_out: true`、非 null `signal`，并向下递归一层 `Content`/`content`。dispatch 失败与 MCP 错误才走 `PostToolUseFailure`，权限被拒走 `PermissionDenied`——这两个子命令直接置位。turn 结束有三个互斥事件：`Stop`（`reason == "end_turn"`，正常完成）/ `StopFailure`（API 错误，exitCode 恒为 1）/ `StopCancelled`（打断、拒绝权限、`--max-turns`、no-progress，exitCode 恒为 1）。

**Turn summary**：Claude / Codex 的 `Stop` 从 `transcript_path` 读取 JSONL 最后一条 `role: "assistant"` 的 text 字段，剥掉 `<thinking>...</thinking>` 块，截到 200 chars，放进 `summary`。Grok 优先直接用 `Stop`/`StopFailure`/`StopCancelled` 事件里 grok 自带的 `lastAssistantMessage` 字段（省掉解析），缺失时回落到 `sessions/**/chat_history.jsonl` 最后一条 `type: "assistant"`（grok 的 `transcript_path` 指向 ACP `updates.jsonl`，没有 `role` 字段，Claude 那套 reader 读不了）。pi 从 `agent_end` 的 `event.messages` 里取最后一条 assistant 的 text block。OpenCode 的 summary 在 v1 里留空（它没有等价的 transcript path 参数；后续 spec 可补）。

**Tool detail**（全部 agent）：`PreToolUse` / `tool.execute.before` 时，派发脚本/插件会根据 `tool_name` + `tool_input` 生成一个紧凑的人类可读标签（"Edit Models/Foo.swift"、"Bash: ls"），作为 `running` 事件的 `toolDetail`。Swift 端把它拼到 tooltip 的第二行。

## Resume command 持久化

每次 `UserPromptSubmit` 触发时，`agent-hook.py` 把当前 session 对应的恢复 CLI（Claude → `claude --resume <session_id>`；Codex → `codex resume <session_id>`）放进 `running` 事件的 `resumeCommand` 字段。`HookDispatcher` 接到后**双重 gate**：必须同时满足该 agent 的状态通知 toggle (`mux0-agent-status-<agent>`) 与恢复 toggle (`mux0-agent-resume-<agent>`) 都为 `true`，才会调用 `WorkspaceStore.recordResumeCommand(terminalId:command:)` 写到对应 workspace 的 `pendingPrefills[terminalId]` 并同步持久化——保留**最新**那一条（`/clear` / `/resume` 切到新 session 时旧 id 立即被覆盖）。

恢复 toggle 默认 OFF。Settings → Agents 把 toggle 拆成 "Notifications"（控制状态图标）与 "Resume on Launch"（控制本节）两个分组：用户必须显式打开 Resume 行 mux0 才会在磁盘上保留 session id。

不依赖 `NSApplication.willTerminateNotification` 做"退出时提升"——⌘Q / 关窗 / 强退 / 崩溃路径下 willTerminate 触发与否不可靠，每次 hook 收到时立刻 save 才是稳定的持久化点。

下次启动 surface 时，`TabContentView.resolvedStartupCommand(forTerminal:)` 通过 `consumePendingPrefill(terminalId:)` 读取该值，再走一遍 **读端 gate**：用 `HookMessage.Agent.fromResumeCommand` 按 prefix 反推 agent，看 `mux0-agent-resume-<agent>` 是否仍为 `true`，否则降级到 workspace `defaultCommand`。读端 gate 必要——它兜住"老版本写盘 / 用户在另一台机器同步了 UserDefaults / toggle 切换时机异常"导致的 stale 旧值。Quick Action 启动的 tab（侧边栏右上角 claude / codex / opencode 按钮）也走这条路径——`tab.quickActionId` 命中 builtin agent 且对应 Resume toggle 为 ON 时，注入 `pendingPrefills` 而不是裸命令；prefill 与 agent 类型不匹配时降级到 Quick Action 的原命令。

读取**不**清空：pendingPrefills 持久保留"最近一次的恢复命令"，只在下一次新 prompt 触发 `recordResumeCommand` 时被覆盖。这保证"重启 → 自动恢复 → 没发任何 prompt → 再重启"仍然能恢复同一会话；代价是用户手动退出 agent 之后该字段会变 stale，下次重启仍会自动 `claude --resume <id>`，不过 claude/codex 都接受任意旧 session id（只是恢复一段久远对话），不会报错。

**关 toggle 的副作用**：用户在 Settings 把某个 agent 的 Resume 从 ON 切到 OFF 时，`AgentResumeToggleRow` 的 setter 立刻调 `WorkspaceStore.clearResumePrefills(forAgent:)`——按 prefix（`claude ` / `codex `）扫描所有 workspace 的 pendingPrefills，把该 agent 的旧值清掉。下一次启动就回到裸 shell（或 `defaultCommand`），不会再 auto-resume。

**关闭 tab / pane 的副作用**：`closeTerminal` 删该 terminal 的 prefill 一项；`removeTab` 把整 tab 内所有 leaf 的 prefill 全删——避免已死 UUID 的恢复命令永远赖在 UserDefaults 里。

**注入路径**：与 `defaultCommand` 完全相同——`WorkspaceDefaultCommand.startupInput(for:)` 在尾部加 `\n`，由 `GhosttyBridge.newSurface` 通过 ghostty 的 `surfCfg.initial_input` 喂入 PTY，shell 启动后 readline 读到立即执行。

`initial_input` 在 shell 启动之前会先把字节绘制到 surface 一次（PTY echo 路径之外的渲染层副作用），但 Claude / Codex 的 TUI 启动后立即切换到 alternate screen buffer，整屏接管后顶部那行幽灵 echo 被自动覆盖，用户实际感知不到。早期尝试过用 `ghostty_surface_text` 在 OSC 7 之后延时注入避开这一行，也尝试过用 env var + zsh shim eval 完全绕过 PTY，最终还是回到这个方案——简单、不依赖 shell 类型、与现有 `defaultCommand` 路径同构。

**Session id 校验**：`resume_command_for` 在拼 CLI 之前用 `[A-Za-z0-9_-]+` 白名单检查 session_id；不匹配直接返回空串，hook 不发 `resumeCommand`。这是防御层——agent 端的 session id 都是 UUID 形态，但万一被恶意 / 畸形 payload 污染（含空格、`;`、反引号等 shell 元字符），下次启动作为 `initial_input` 喂给 shell 时不会变成命令注入。

**OpenCode 的 sessionID 来源**：OpenCode 不走 Python hook，由 `Resources/agent-hooks/opencode-plugin/mux0-status.js` 直接 emit 到同一个 Unix socket。`tool.execute.before` 钩子的 `input.sessionID` 就是当前 session id；plugin 拼成 `opencode --session <sessionID>` 放进 `resumeCommand`，跟 claude/codex 路径同构。`session.created` / `session.idle` 等纯 event 钩子拿不到 sessionID，所以 resume 是绑定在 tool 调用边界上的——一个 turn 通常会调多个 tool，每次都附 resumeCommand，mux0 端的 equality guard 自动 dedup 写盘。`agent-hook.py` 的 `resume_command_for` 同时也保留了 opencode 分支，作为 CLI 形态的 single source of truth（即便 Python 端永远不会被 opencode 调用）。

## 各 Agent 的信号来源

| Agent | 机制 | 文件 |
|-------|------|------|
| pi | `pi -e <file>` 按进程加载扩展，扩展订阅 `session_start / before_agent_start / tool_execution_start / tool_execution_end / ui_prompt_start / ui_prompt_end / agent_end / session_info_changed / session_shutdown`，直接用 `node:net` 写 socket（不经 Python）。子命令 `install/remove/uninstall/update/list/config/auth/completions/export/--help/--version` passthrough | `pi-wrapper.sh`, `pi-extension/mux0-status.js` |
| Grok | `GROK_HOME=<稳定 overlay>` + `hooks/mux0.json`（SessionStart/UserPromptSubmit/PreToolUse/PostToolUse/PostToolUseFailure/PermissionDenied/Notification/Stop/StopFailure/StopCancelled/SessionEnd）。见下节 | `grok-wrapper.sh`, `agent-hook.py` |
| Claude Code | `claude --settings <json>` 注入 hooks（SessionStart/UserPromptSubmit/PreToolUse/PostToolUse/Stop/Notification/SessionEnd）。**不**改 `CLAUDE_CONFIG_DIR`——claude 用 `sha256(CLAUDE_CONFIG_DIR)[:8]` 作为 macOS keychain service 名后缀，换路径就会跟原生 claude 的 keychain 登录态对不上。对 `mcp`/`doctor`/`--remote-control` 等 commander 子命令做 passthrough（它们的 sub-parser 不识别 `--settings`） | `claude-wrapper.sh` |
| OpenCode | 插件订阅 bus 事件（tool.execute.before / permission.asked / session.idle 等） | `opencode-plugin/mux0-status.js` |
| Codex | 实验性 `hooks.json` + `notify` 兜底 | `codex-wrapper.sh` |

## `running` 的覆盖点

Claude / Codex 的 `PostToolUse` hook 除了累加 `turnHadError` 之外，还会 emit `running`。作用是把 `Notification → needsInput` 设置的等待态在用户批准权限、工具继续执行后推回 running——否则在"工具长时间执行"或"该工具是 turn 里最后一个动作"的情况下，橙点会一直卡到 `Stop` 才消失。`Stop` 的时间戳晚于 `posttool`，`TerminalStatusStore.isStale` 保证 `finished` 最终覆盖 `running`。

OpenCode 走另一条路径：`permission.asked → needsInput`，`permission.replied → running`，plugin 层本身已闭环；`tool.execute.after` 不发 socket 消息，只累计 `turn.hadError`。

## `needsInput` 的派发门控

Claude Code 的 `Notification` hook 本身是一个双重信号：**真实的权限请求**会触发它，同时**"已经 60 秒没动静"**的空闲心跳也会触发它（Claude Code 官方行为，不可区分）。如果无条件把 `Notification → needsInput`，一个成功结束的 turn 60 秒后就会被心跳误覆盖，让图标从 `success` 翻成 `needsInput`。

因此 `HookDispatcher` 对 `needsInput` 事件加了一道门：**只有当当前状态是 `.running` 时才转入 `.needsInput`**，在 `success / failed / idle / neverRan` 状态下收到 `needsInput` 直接丢弃。这样能保留 turn 结束后的终态不被后续心跳污染，同时不影响真实的权限请求场景（权限请求发生在 turn 进行中，状态必然是 `.running`）。OpenCode 的 `permission.asked` 同理适用。

## Codex 的特殊规则：feature flag + hook trust

### Feature flag（0.130 之后已经是 stable）

历史上 codex 0.12x 把 hook 引擎放在 `Stage::UnderDevelopment` 的 `codex_hooks` flag 后面，必须在 `~/.codex/config.toml` 里写 `[features] codex_hooks = true` 才会读 `hooks.json`。**0.130 起这个 flag 改名成 `hooks`，并升到 `stable`，默认 `true`**——绝大多数情况下不需要用户在 config 里写任何东西。`codex features list` 可以快速确认（`hooks   stable   true`）。如果环境里残留了旧的 `codex_hooks = true`，codex 会把它视为未知 key，按 `deny_unknown_fields` 在配置层报错；新装就别再写了。

### Hook trust（0.130 引入）

0.130 起 codex 给 `hooks.json` 加了一道 **trust 闸门**：每条 hook 第一次被加载时都是 `untrusted`，codex 启动时会在 TUI 顶部显示一行类似 `1 hook needs review before it can run. Open /hooks to review it.`，必须用户进 `/hooks` 手动 approve 后才会执行。**不 trust 的话 `UserPromptSubmit` / `PreToolUse` / `PostToolUse` / `Stop` 一个都不会跑**，表面症状就是 mux0 sidebar / tab 图标常驻 idle、turn 进行中也不变 running——0.130 升级后用户最常碰到的就是这个。

**Trust state 的存储位置**：是 `$CODEX_HOME/config.toml` 的 `[hooks.state]` 段（不是单独的 `hooks.state` 文件），由 codex 通过 `tempfile + rename(2)` 整体替换写出。每条 entry 形如：

```toml
[hooks.state."<hooks.json 绝对路径>:<event_name_snake_case>:<group_idx>:<handler_idx>"]
trusted_hash = "sha256:..."
```

**mux0 overlay 路径稳定化**：早期 wrapper 用 `mktemp -d -t mux0-codex.XXXXXX` 生成 OVERLAY，每次启动路径里 8 字符随机串都不同，trust state key 永远命不中——用户**每次新开 codex tab 都要再 `/hooks` approve 一次**，并且 `~/.codex/config.toml` 末尾会累积一堆死 entry。

现在 OVERLAY 改成**全局稳定路径** `$HOME/Library/Caches/mux0/codex-overlay`（不再 per-launch、不再 per-tab），所有 mux0 codex 进程共用同一个目录。这跟原生 codex「`~/.codex/hooks.json` trust 一次 per-user 永久生效」的语义对齐：第一次启动 mux0 codex 后用户 `/hooks` approve 一次，之后所有 tab、所有 mux0 重启都直接命中。之所以不直接复用 `~/.codex/hooks.json`，是因为会污染用户自己写的 hooks，且 SIGKILL 残留的 hooks.json 会让用户在原生 Terminal 里跑 codex 时执行陌生命令。

**并发约束**：多个 codex 进程共用同一 OVERLAY 时，进程 A 通过 `tempfile + rename(2)` 把 OVERLAY 内的 symlink 替换成 regular file（如 `codex features enable` 写 `config.toml`）后，进程 B 启动若直接 `ln -sfn` 强制覆盖，会丢失 A 的写入。wrapper 因此在每次启动**进入 symlink 重建之前**先扫描 OVERLAY，把所有非 symlink 的 regular file `cp` 回 `$USER_HOME`，再让 `ln -sfn` 原子替换为 symlink——一致性等价于 codex 在多个原生 Terminal 共用 `~/.codex` 的行为。

**Cleanup 的实际作用**：

1. **`codex login` / `codex features enable` 这类会改 `config.toml` 的子命令的写入**——codex 用 `tempfile + rename(2)` 把 overlay 里的 `config.toml` symlink 替换成 regular file，cleanup 把它 cp 回 `~/.codex/config.toml`
2. **trust 写入持久化**——`/hooks` approve 触发 codex 写 `config.toml`，cleanup 把它 cp 回。但因为 OVERLAY 路径现在稳定，即便 cleanup 在某次启动里没跑成（SIGKILL），下次启动时的 pre-symlink 同步也会把残留 regular file 拷回去，trust 不丢

cleanup **不再 `rm -rf $OVERLAY`**——OVERLAY 是共享目录，删了会踢掉同时运行的其他 codex tab。regular file 留在 OVERLAY 里也无害，下一次启动会被同步并替换成 symlink。

能跑成是因为 wrapper 末尾改成 subprocess + wait 模式而不是 `exec`——bash 的 EXIT trap 在 `exec` 后不触发，旧版 wrapper 这段 cleanup 是死代码。

**迁移备注**：旧版本 `mktemp` 出来的 OVERLAY 路径条目（`[hooks.state."/private/var/folders/.../T/mux0-codex.XXXXXX.<random>/hooks.json:..."]`）会一直留在 `~/.codex/config.toml` 末尾。它们无害（路径已永不存在），但累积多了视觉上脏。用户可以一次性手工删掉所有 `mktemp` 时代的 entry。

### 调试入口

用户反馈 "codex 状态不对" 时按这条顺序查：

1. 在 mux0 里启动 codex tab，进入 codex TUI 后输入 `/hooks`——若 hook 显示 `untrusted` 或 `needs review`，approve 一遍就好（**全局只需一次**，approve 后路径稳定，所有 mux0 tab 和后续重启都命中；见上文 trust 一节）
2. 看 `~/.codex/config.toml` 末尾有没有 `[hooks.state]` 段，entry 是不是指向 `~/Library/Caches/mux0/codex-overlay/hooks.json`（稳定路径）。若仍然只看到 `/private/var/folders/.../T/mux0-codex.XXXXXX.*/hooks.json` 这种 mktemp 残留，说明跑的还是老 wrapper
3. 看 `~/Library/Caches/mux0/hook-emit.log` 里 `agent=codex` 的事件类型——`grep 'agent=codex' ~/Library/Caches/mux0/hook-emit.log | awk '{print $2}' | sort -u`。如果只有 `event=idle`，说明 hook 根本没在 turn 进行中触发，回去查 trust
4. 最后再看 `codex features list` 确认 `hooks` 是 `stable=true`，以及 `codex-wrapper.sh` 自己的逻辑（subprocess 形态 + cleanup 真的执行）

### hooks.json Schema 注意事项

Codex 和 Claude Code 用**同一种嵌套格式**（不是 flat）：

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [{ "type": "command", "command": "..." }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "..." }] }
    ]
  }
}
```

Codex parser 使用 Serde 的 `deny_unknown_fields`——flat 格式 `{"command": "..."}` 或多余字段会导致**整个文件被静默跳过**，没有错误日志。

## config.toml 注入的坑

Codex wrapper **不**写 overlay 版的 `config.toml`：overlay 里的 `config.toml` 起步是符号链接到用户真实 `~/.codex/config.toml`，`notify` 改用 codex 的 `-c notify=[...]` CLI 覆盖参数注入（仅作用于本次进程，不污染用户配置）。

**坑：rename 会替换 symlink**。Codex 持久化 config 走的是 `tempfile + rename(2)`，而 `rename` 会把目录项**原子替换**——overlay 里的 symlink 会被替换成一个真实文件，并不会跟随 symlink 写到用户真实路径。所以 `codex features enable` / `codex login` 等子命令实际上是写到 `$OVERLAY/config.toml`（已变成真实文件，不再是 symlink）。为此 wrapper 的 `cleanup` trap 在 `rm -rf` 前会做一次检测：如果 `$OVERLAY/config.toml` 已经从 symlink 变成 regular file，就 `cp -f` 回 `$USER_HOME/config.toml`，然后再清 overlay。SIGKILL 跳过 trap 会丢失这次同步，与所有 temp-dir 方案同温层。

**历史**：早期版本把用户 `config.toml` 拷贝到 overlay 并在前面 prepend `notify = [...]`，结果会写 config 的子命令把改动写进 overlay，进程退出 `rm -rf` 后丢失（无回写）。现在用 symlink + cleanup 回写 + `-c` 覆盖避免了这个 bug，也不再担心 TOML section 边界（早期方案为了避免被用户末尾的 `[notice.model_migrations]` 吞掉必须前置）。

## pi 的特殊规则：按进程加载扩展

pi **没有** hook 配置文件，只有"扩展"（extension）。扩展有三个发现位置
（`~/.pi/agent/extensions/`、`<repo>/.pi/extensions/`、`settings.json` 的 `extensions` 列表），
全都是持久的——往里放文件会让用户在原生 Terminal 里跑的 pi 也回调 mux0，
SIGKILL 还会留下孤儿。所以 `pi-wrapper.sh` 走 `pi -e <path>`：只对本次进程生效，
且 `--no-extensions` 也拦不住显式 `-e` 路径。这跟 `claude --settings <json>` 是同一个思路。

扩展（`pi-extension/mux0-status.js`）的实现约束：

- **只用 node 内置模块**（`node:net` / `node:fs`），零第三方 import。pi 的扩展依赖解析
  需要 package.json / node_modules，纯内置模块保证任何机器上都加载得起来。
- **没有 MUX0_HOOK_SOCK / MUX0_TERMINAL_ID 时直接 return**，一个事件都不订阅。
  用户在 mux0 外面跑 pi 时扩展等于不存在，绝不会发出 terminalId 为空的孤儿事件。
- **时间戳严格递增**（`nextAt()`）：每个事件新建一条 socket 连接，同一毫秒内的两个事件
  如果时间戳相等会被 `TerminalStatusStore.isStale` 丢掉后一个，所以手工 +1e-6。
  写完立刻 `sock.end()` 半关闭——mux0 的 listener 是 read-until-EOF 模型。
- **`emit()` 是 `await` 的**（上限 200ms）。两个原因：(1) **顺序**——一事件一连接时
  accept 顺序由内核决定，`finished` 可能比它前面的 `running` 先被应用，之后那条
  `running` 会被 stale 保护重新盖时间戳，图标就永远转圈了；pi 会 await 每个 handler，
  所以 await 写完就等于串行投递——**前提是 handler 里真的 `await emit(...)`**。
  `ui_prompt_end` 曾写成 `emit("running")`（丢掉 Promise），结果权限确认完后的橙点
  要等到下一条被 await 的事件才消；现在每个 emit 都必须 await，
  `tests/pi_extension_test.py::test_pi_extension_awaits_every_emit` 静态兜这条。
  (2) **不丢尾部**——pi 发完 `session_shutdown` 往往立刻
  `process.exit()`，还在排队的 connect 会被直接杀掉。socket 不存在时 connect 立刻
  ENOENT/ECONNREFUSED 返回，正常投递是亚毫秒级，最坏只多等 200ms。
- `finished` 只在 `agent_end` 且**确实有 turn 开着**时发（`before_agent_start` 置位）。
  pi 的 `agent_settled` 表示"不会再自动续跑了"，但 summary 只在 `agent_end` 的
  `event.messages` 里，且续跑会再发一次 `before_agent_start` → 新一轮 running，语义不冲突。

### turn 成功/失败

pi 的 `tool_execution_end` 带 `isError`（实测：`ls /nonexistent` → `isError: true`）。
任一 tool 报错就粘滞置位 `turnHadError`，`agent_end` 时发 `finished` 并把 `exitCode`
设成 1，跟 claude / codex / grok 的聚合口径一致。

### needsInput：pi 没有权限提示

pi 的工具默认直接执行，**没有** Claude 那种 permission prompt。唯一等用户的信号是扩展自己调
`ctx.ui.confirm/select/input/editor/custom` 时的 `ui_prompt_start` / `ui_prompt_end`
（`needsInput` → 回到 `running`）。所以没装会弹框扩展的用户，pi 永远不会出现橙点——
这是 pi 的行为，不是漏接。

### pi 的 sessionTitle

只有 `/name`、`pi.setSessionName()` 或 RPC 会触发 `session_info_changed`；pi **没有**
LLM 自动标题。因此优先级是 `session_info_changed.name` → 首条 prompt（与 claude/codex 的
fallback 语义一致）。`session_info_changed` 发事件时按当前是否处于 turn 中选 `running` / `idle`，
避免在 turn 刚结束后用一个 `running` 把 success 图标打回转圈。

## Grok 的特殊规则：GROK_HOME overlay 与 folder trust

### 为什么只能走 GROK_HOME

grok 没有 `--settings` 这类 CLI 注入；`GROK_CONFIG` / `GROK_CONFIG_PATH` 环境变量 overlay
虽然是按进程注入，但它是 **fail-closed 白名单**：只有 `models` / `features` / 收窄的 `toolset` /
`shell_environment_policy` 的过滤字段能进去，**其它 table 一律在 choke point 被丢弃——包括 `hooks`**。
剩下的落点只有：

| 方案 | 结果 |
|------|------|
| `$GROK_HOME/hooks/*.json` | **Always trusted**，全目录生效，零配置 → 采用 |
| `<repo>/.grok/hooks/*.json` | 需要 folder trust（`/hooks-trust` 或 `--trust`），未 trust 时**静默跳过**，还要往用户仓库写文件 → 不采用 |
| 直接写 `~/.grok/hooks/mux0.json` | 污染用户目录，SIGKILL 留孤儿 → 不采用 |

`grok-wrapper.sh` 因此构造 `$HOME/Library/Caches/mux0/grok-overlay`（**稳定路径**，与 codex 同理：
`/hooks` 面板里显示的文件路径、`grok du` 的输出去重都依赖它不变），把真实 `~/.grok` 的条目
逐个 symlink 进去（含 dotfile），只自己拥有 `hooks/` 一个目录：`hooks/` 里逐个 symlink 用户自己的
`~/.grok/hooks/*.json`（用户手写的全局 hook 在 mux0 里照样生效）+ 我们的 `mux0.json`。

### sessions 必须是符号链接

`overlay/sessions -> ~/.grok/sessions` 保证：session 记录（含 LLM 生成的
`summary.json.generated_title`）落在用户真实 session 目录里，**mux0 外面 `grok --resume` 一样能列出
mux0 里开的会话**，`agent-hook.py` 也能读到标题。反过来说，如果哪天把 sessions 改成 overlay 内真实
目录，resume 列表和 tab 命名会同时退化——改这块要留意。

### rename 会把 symlink 变成普通文件

跟 codex 一模一样：grok 用 `tempfile + rename(2)` 写 `.metadata_version` / `config.toml`，
`rename` 替换的是目录项，symlink 就地变成普通文件。wrapper 因此在**重建 symlink 之前**先把 overlay
里的普通文件 `cp` 回真实 `~/.grok`（`sync_overlay_back`），EXIT trap 里再同步一次。
`hooks/`、`*.sock` 跳过；目录与 socket 不是 regular file，天然被 `[ -f ]` 排除。

因为用 subprocess + wait 而不是 `exec`，trap 才真的会跑（见 codex 一节同样的教训）。

### 已知限制

- **`--sandbox <profile>` 下 hook 不生效**：grok 的文档（`18-sandbox.md`）说 symlink 化的
  `$GROK_HOME` 会在 sandbox 启动时被拒绝。sandbox 是用户显式开启的，默认关闭。
- **leader 模式**：`[cli] use_leader`（默认关）开启后多个 grok 会话共享 leader 进程，
  hook 是从 leader 派生的，环境里的 `MUX0_TERMINAL_ID` 会是**第一个**启动它的 tab 的。
  默认配置下（in-process）不存在这个问题。
- `Notification` 的 `idle_prompt` 在**每个 turn 结束都会发**（包括已经发过 `Stop` 的），
  所以它只做兜底：`agent-hook.py` 仅在 session 文件里该 session 的 turn 还开着
  （`turnStartedAt` 非 0）时才据此补发 `finished`，否则静默——否则每个 turn 都会收到两个
  `finished`，后一个会用更晚的时间戳覆盖掉前一个的状态。
- `Stop` 在会话 teardown 时会额外发一次 `reason: "shutdown"` / `"channel_closed"` 的观察事件，
  只有 `reason == "end_turn"` 才当作 turn 结束处理（claude/codex 不带 `reason`，守卫对它们是 no-op）。
- 事件里的 `subagentType`（子 agent 内触发）目前不做区分：子 agent 的 tool 事件同样带
  `session_id`，会并入同一 terminal 的 turn 状态，与 Claude 的子 agent 行为一致。

### 卸载 / 还原：`grok-restore.sh`

A 方案（现行）不写 `~/.grok`：**唯一的痕迹是 overlay 目录**，
`Resources/agent-hooks/grok-restore.sh` 就是删它（先删符号链接再删目录，绝不跟着符号链接删用户数据），
并检查 `~/.grok` 里是否残留 `hooks/mux0.json`。

若将来 grok 取消 `GROK_HOME`（或 sandbox 模式下必须回退）而走 B 方案——直接写用户的
`~/.grok`——B 的写入方**必须**同时留下：

| 位置 | 内容 |
|---|---|
| `~/.grok/.mux0-backup/<UTC 时间戳>/<相对路径>` | 改动前的原文件内容；原本不存在的文件记为 `<相对路径>.NEW` |
| `~/.grok/.mux0-backup/CHANGES.log` | 每个改动一行 TAB 分隔：`<时间>\t<new\|modify\|delete>\t<相对路径>\t<原因>` |

`grok-restore.sh` 按 CHANGES.log **倒序**回放（同一路径只看最新一条决定动作，原始内容取**最早**
那份还存在的快照），`new` → 删除、`modify`/`delete` → 从快照写回，然后追加一行 `restore`。
支持 `--dry-run` / `--home DIR` / `--keep-overlay`，并且拒绝把 `--home` 指向 overlay 本身。
测试见 `tests/grok_restore.sh`（含「两次快照时最早那份胜出」「用户的 `hooks/user.json` 不许动」
「sessions/ 不许动」等断言）。

> 快照目录是用 `find … -exec stat -f '%m %N'` + `sort` 枚举的，**不是 `ls`**。这脚本曾经用
> `ls -1dt "$BACKUP_DIR"/*/` 拿快照列表，在 `CLICOLOR_FORCE=1` 的环境下目录名带上了
> `\033[34m`，于是 `[ -e "$snap/$path" ]` 永远是假 —— 还原时打一句 `WARN no backup found`，
> 然后把 mux0 写进 `config.toml` 的注入内容**原地留下**了。测试现在强制开着颜色跑。

`~/.grok/sessions/`、`~/.grok/logs/`、`active_sessions.json` 是 **grok 自己的运行数据**，
还原时故意不动：它们本来就是符号链接指回真实目录（见上面 sessions 契约），
用户在 mux0 外面 `grok --resume` 要能看到 mux0 里跑的会话。

### 调试入口（pi / grok）

1. `grep -E 'agent=(pi|grok)' ~/Library/Caches/mux0/hook-emit.log | awk '{print $2}' | sort | uniq -c`
   —— 看不到 `event=running` 说明 turn 期间的 hook 根本没跑；grok 就去查 `grok inspect`
   与 overlay（下一步），pi 就去查扩展是否加载（wrapper 会记 `[pi-wrapper] execing: ... -e ...`）。
2. `cat ~/Library/Caches/mux0/grok-overlay/hooks/mux0.json` —— 命令里的路径必须指向当前
   app bundle 内的 `agent-hooks/`；路径不对通常是 bundle 没重新 build（postBuildScript 负责拷贝）。
3. 手动验半条链路：`MUX0_HOOK_SOCK=... MUX0_TERMINAL_ID=... GROK_HOME=~/Library/Caches/mux0/grok-overlay
   grok -p "list files"`，然后看 socket 收到的 JSON 行。
4. pi 侧可以直接跑单测（不需要模型）：`python3 -m pytest Resources/agent-hooks/tests/pi_extension_test.py -v`。
5. 真跑一次、拿到事件原文：`…/mux0.app/Contents/Resources/agent-hooks/e2e-live.sh pi|grok|both [--fail]`。
   它用**当前 bundle 里的 wrapper** 跑一个强制调工具的提示词，自己起一个独立进程监听临时
   socket，然后断言「带 resumeCommand 的 running」/「带 toolDetail 的 running」/「带 exitCode +
   summary 的 finished」（`--fail` 要求 exitCode 非 0）并打印全部事件。这是唯一花模型额度（要
   登录、要网络）的验收脚本，所以放在 `agent-hooks/` 而不是 `tests/`，`run-all.sh` 不会跑它。

> 跑 `tests/` 下的 shell 测试得用 **bash**（它们会在被 zsh 直接启动时 `exec bash` 拉起自己）；
> 一次性跑全部并 bash + zsh 双跑：`bash Resources/agent-hooks/tests/run-all.sh`，见 `docs/testing.md`。

## Historical: shell 状态来源

shell preexec/precmd 在 2026-04 之前是第 4 种状态源。现已从 pipeline 中移除：
shell-hooks.{zsh,bash,fish} 脚本删除、bootstrap 不再 source、`HookMessage.Agent`
枚举不含 `.shell` case。详见 `decisions/004-shell-out-of-status-pipeline.md`。
