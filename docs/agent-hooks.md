# Agent Hooks

mux0 通过注入到各 AI CLI 的生命周期钩子，把 `running` / `idle` / `needsInput` / `finished` 状态推送到 app 的 `TerminalStatusStore`，驱动 sidebar / tab 上的状态图标。Agent 侧（Claude Code / Codex / OpenCode）另外在 `.finished` 事件里携带 `exitCode` 哨兵值（0 = turn 干净，1 = turn 里有 tool 报错）和可选的 `summary`（transcript 最后一条 assistant 消息）。

实现位于 `Resources/agent-hooks/`，由 `project.yml` 的 postBuildScript 拷贝到 app bundle，运行时通过 `ZDOTDIR` shim 自动激活。

## IPC

- 传输：Unix domain socket，路径为 `~/Library/Caches/mux0/hooks-<bundle-hash>.sock`（`<bundle-hash>` = SHA256(`Bundle.main.bundlePath`) 前 8 位十六进制）。按 bundle 路径分命名空间是为了让 `/Applications/mux0.app` 和 Xcode DerivedData 里的 Debug 构建互不抢占 socket——后起的实例 `bind()` 前会 `unlink` 掉同路径的旧 sockfile，会把前一实例踢下线。路径由 `GhosttyBridge.initialize()` 写进 `MUX0_HOOK_SOCK`，终端进程通过 env 继承
- 消息格式：每行一个 JSON，`{"terminalId": "...", "event": "running|idle|needsInput|finished", "agent": "claude|opencode|codex", "at": <epoch>, "exitCode": <int>?, "toolDetail": <string>?, "summary": <string>?, "resumeCommand": <string>?}`。`exitCode` 仅在 `event=finished` 时携带（shell = 真实 `$?`；agent = 0/1 哨兵）；`toolDetail` 仅在 agent 的 `event=running` 时携带（如 "Edit Models/Foo.swift"）；`summary` 仅在 agent 的 `event=finished` 时携带（transcript 最后一条 assistant 消息，≤200 chars）；`resumeCommand` 仅在 Claude/Codex 的 prompt 触发的 `event=running` 时携带（恢复当前 session 的 CLI，如 `claude --resume <session_id>` / `codex resume <session_id>`，OpenCode 暂未支持）。
- 监听端：`HookSocketListener`（DispatchSourceRead，accept 循环）

## Agent Turn 成败检测

Agent turn 没有真实的 exit code，但 Claude Code / Codex 的 `PostToolUse` hook 和 OpenCode 的 `tool.execute.after` 插件事件都带结构化的 "tool 报错了吗" 字段。mux0 在每个 turn 内聚合这些 per-tool 信号到一个布尔 `turnHadError`，在 `Stop` / `session.idle` 时发 `finished` 事件，`exitCode` 设为 0（clean）或 1（had errors）。

**Claude / Codex**（命令行 hook，无状态每次 fork 一个 agent-hook.sh）：per-session 状态存在 `~/Library/Caches/mux0/agent-sessions.json`，按 `session_id` 索引。`PostToolUse` 把 `tool_response.is_error` 粘滞累加（一个 turn 里任一 tool 失败就是失败）；`Stop` 读取后清除该 session 条目并 emit。过期（>1h 未 touch）的条目每次 hook 调用时自动 GC。

**OpenCode**（长驻插件进程）：状态保存在插件 closure 的 `turn` 对象里，`tool.execute.after` 累加 `args.error` / `args.result.status === "error"`，`session.idle` 时 emit。插件进程重启（opencode 退出 / 重开）会丢状态，但同时 opencode 自己也重建 session，语义无歧义。

**Turn summary**（Claude 独有）：`Stop` 从 `transcript_path` 读取 JSONL 最后一条 `role: "assistant"` 的 text 字段，剥掉 `<thinking>...</thinking>` 块，截到 200 chars，放进 `summary`。Codex 同理（schema 一致）。OpenCode 的 summary 在 v1 里留空（它没有等价的 transcript path 参数；后续 spec 可补）。

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

## Historical: shell 状态来源

shell preexec/precmd 在 2026-04 之前是第 4 种状态源。现已从 pipeline 中移除：
shell-hooks.{zsh,bash,fish} 脚本删除、bootstrap 不再 source、`HookMessage.Agent`
枚举不含 `.shell` case。详见 `decisions/004-shell-out-of-status-pipeline.md`。
