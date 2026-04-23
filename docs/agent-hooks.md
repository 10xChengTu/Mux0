# Agent Hooks

mux0 通过注入到各 AI CLI 的生命周期钩子，把 `running` / `idle` / `needsInput` / `finished` 状态推送到 app 的 `TerminalStatusStore`，驱动 sidebar / tab 上的状态图标。Agent 侧（Claude Code / Codex / OpenCode）另外在 `.finished` 事件里携带 `exitCode` 哨兵值（0 = turn 干净，1 = turn 里有 tool 报错）和可选的 `summary`（transcript 最后一条 assistant 消息）。

实现位于 `Resources/agent-hooks/`，由 `project.yml` 的 postBuildScript 拷贝到 app bundle，运行时通过 `ZDOTDIR` shim 自动激活。

## IPC

- 传输：Unix domain socket，路径为 `~/Library/Caches/mux0/hooks-<bundle-hash>.sock`（`<bundle-hash>` = SHA256(`Bundle.main.bundlePath`) 前 8 位十六进制）。按 bundle 路径分命名空间是为了让 `/Applications/mux0.app` 和 Xcode DerivedData 里的 Debug 构建互不抢占 socket——后起的实例 `bind()` 前会 `unlink` 掉同路径的旧 sockfile，会把前一实例踢下线。路径由 `GhosttyBridge.initialize()` 写进 `MUX0_HOOK_SOCK`，终端进程通过 env 继承
- 消息格式：每行一个 JSON，`{"terminalId": "...", "event": "running|idle|needsInput|finished", "agent": "claude|opencode|codex", "at": <epoch>, "exitCode": <int>?, "toolDetail": <string>?, "summary": <string>?}`。`exitCode` 仅在 `event=finished` 时携带（shell = 真实 `$?`；agent = 0/1 哨兵）；`toolDetail` 仅在 agent 的 `event=running` 时携带（如 "Edit Models/Foo.swift"）；`summary` 仅在 agent 的 `event=finished` 时携带（transcript 最后一条 assistant 消息，≤200 chars）。
- 监听端：`HookSocketListener`（DispatchSourceRead，accept 循环）

## Agent Turn 成败检测

Agent turn 没有真实的 exit code，但 Claude Code / Codex 的 `PostToolUse` hook 和 OpenCode 的 `tool.execute.after` 插件事件都带结构化的 "tool 报错了吗" 字段。mux0 在每个 turn 内聚合这些 per-tool 信号到一个布尔 `turnHadError`，在 `Stop` / `session.idle` 时发 `finished` 事件，`exitCode` 设为 0（clean）或 1（had errors）。

**Claude / Codex**（命令行 hook，无状态每次 fork 一个 agent-hook.sh）：per-session 状态存在 `~/Library/Caches/mux0/agent-sessions.json`，按 `session_id` 索引。`PostToolUse` 把 `tool_response.is_error` 粘滞累加（一个 turn 里任一 tool 失败就是失败）；`Stop` 读取后清除该 session 条目并 emit。过期（>1h 未 touch）的条目每次 hook 调用时自动 GC。

**OpenCode**（长驻插件进程）：状态保存在插件 closure 的 `turn` 对象里，`tool.execute.after` 累加 `args.error` / `args.result.status === "error"`，`session.idle` 时 emit。插件进程重启（opencode 退出 / 重开）会丢状态，但同时 opencode 自己也重建 session，语义无歧义。

**Turn summary**（Claude 独有）：`Stop` 从 `transcript_path` 读取 JSONL 最后一条 `role: "assistant"` 的 text 字段，剥掉 `<thinking>...</thinking>` 块，截到 200 chars，放进 `summary`。Codex 同理（schema 一致）。OpenCode 的 summary 在 v1 里留空（它没有等价的 transcript path 参数；后续 spec 可补）。

**Tool detail**（全部 agent）：`PreToolUse` / `tool.execute.before` 时，派发脚本/插件会根据 `tool_name` + `tool_input` 生成一个紧凑的人类可读标签（"Edit Models/Foo.swift"、"Bash: ls"），作为 `running` 事件的 `toolDetail`。Swift 端把它拼到 tooltip 的第二行。

## 各 Agent 的信号来源

| Agent | 机制 | 文件 |
|-------|------|------|
| Claude Code | `--settings` 注入 hooks JSON（SessionStart/UserPromptSubmit/PreToolUse/Stop/Notification/SessionEnd） | `claude-wrapper.sh` |
| OpenCode | 插件订阅 bus 事件（tool.execute.before / permission.asked / session.idle 等） | `opencode-plugin/mux0-status.js` |
| Codex | 实验性 `hooks.json` + `notify` 兜底 | `codex-wrapper.sh` |

## `needsInput` 的派发门控

Claude Code 的 `Notification` hook 本身是一个双重信号：**真实的权限请求**会触发它，同时**"已经 60 秒没动静"**的空闲心跳也会触发它（Claude Code 官方行为，不可区分）。如果无条件把 `Notification → needsInput`，一个成功结束的 turn 60 秒后就会被心跳误覆盖，让图标从 `success` 翻成 `needsInput`。

因此 `HookDispatcher` 对 `needsInput` 事件加了一道门：**只有当当前状态是 `.running` 时才转入 `.needsInput`**，在 `success / failed / idle / neverRan` 状态下收到 `needsInput` 直接丢弃。这样能保留 turn 结束后的终态不被后续心跳污染，同时不影响真实的权限请求场景（权限请求发生在 turn 进行中，状态必然是 `.running`）。OpenCode 的 `permission.asked` 同理适用。

## Codex 的特殊规则：实验 flag

**Codex 的 hooks 默认不生效，用户必须在 `~/.codex/config.toml` 里显式打开：**

```toml
[features]
codex_hooks = true
```

**为什么需要**：`codex_hooks` 是 OpenAI 标记的 `Stage::UnderDevelopment` 特性（源码在 `codex-rs/features/src/lib.rs`），官方保留修改权，默认关闭。我们的 wrapper 用 overlay `CODEX_HOME` 写 `hooks.json`，但 flag 必须在用户主 config 里声明——overlay 也无法替用户打开未声明的实验 flag。

**不开的后果**：
- `hooks.json` 被 codex 完全忽略，`UserPromptSubmit` / `PreToolUse` / `Stop` 都收不到
- 只剩 `notify = [...]`（turn 完成时触发）和 wrapper 启动时主动 emit 的一次 idle
- 表现：codex 启动/结束时正确显示 idle，但 **turn 进行中状态不会变成 running**（停留在 idle）

**开了之后的预期**：UserPromptSubmit → running，Stop → idle，PreToolUse → running（目前 codex 只对 `Bash` 工具触发 PreToolUse，MCP/文件工具还没接）。

**调试入口**：用户反馈 "codex 状态不对"，先问 flag 是否打开——未开是已知限制，非 bug；开了仍不对才去查 `~/Library/Caches/mux0/hook-emit.log` 和 `codex-wrapper.sh`。

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

Codex wrapper 往 overlay config.toml 里加 `notify` 时必须**前置**（写在所有用户 `[section]` 之前），不能 append。TOML 里 section 无法"关闭"，一旦进入 section，后续 key 都归属它。如果用户 config 末尾是 `[notice.model_migrations]`，append 的 `notify = [...]` 会被当成 `notice.model_migrations.notify`，解析成"expected a string, got sequence"错误。

## Historical: shell 状态来源

shell preexec/precmd 在 2026-04 之前是第 4 种状态源。现已从 pipeline 中移除：
shell-hooks.{zsh,bash,fish} 脚本删除、bootstrap 不再 source、`HookMessage.Agent`
枚举不含 `.shell` case。详见 `decisions/004-shell-out-of-status-pipeline.md`。
