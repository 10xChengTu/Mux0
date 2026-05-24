# Tab 自动命名（从 agent 会话标题）

## 背景

目前 `TerminalTab.title` 只有两种状态：创建时的兜底字符串（"Terminal" / quick action displayName 如 "claude"），或用户手动 inline rename 后的字符串。当用户在 tab 里跑 Claude Code / Codex / OpenCode 时，agent 端已经为 session 生成了人类可读的标题（如 `claude --resume` / `codex resume` 列表展示的那个），但 mux0 完全没用上。

本设计让 tab 名自动跟随当前 agent session 的标题，同时保留"用户重命名永久优先"的语义。

## 三个 agent 的会话标题来源

| Agent | 数据源 | 类型 |
|-------|--------|------|
| Claude Code | transcript JSONL（`UserPromptSubmit` payload 已带 `transcript_path`）内 `{"type":"ai-title","aiTitle":"..."}` 条目（取最后一条） | LLM 异步生成；首 turn 可能未生成 |
| Codex | `~/.codex/state_*.sqlite` 的 `threads.title` 列，按 `id = <session_id>` 查询 | LLM 异步生成；首 turn 内 fallback 到 `first_user_message` |
| OpenCode | plugin context 的 `session.title` 字段（持久化在 `~/.local/share/opencode/storage/session/<projectHash>/<sessionId>.json`） | LLM 异步生成 |

三者都是 LLM 异步生成 → 新建 session 后第一次 emit 时可能为空字符串，下一个 turn 会填上。mux0 端只要 idempotent 收最新值即可。

## Tab title 渲染规则

```
displayTitle(tab, sessionTitleStore):
  if tab.userRenamed       → tab.title
  if sessionTitleStore[tab.focusedTerminalId] is non-empty
                           → sessionTitleStore[tab.focusedTerminalId]
  else                     → tab.title    // 兜底，沿用现有默认 ("Terminal" / quick action displayName)
```

**焦点 pane = 焦点终端**（`TerminalTab.focusedTerminalId`），随 split pane 内焦点切换实时更新；焦点 pane 是 shell（store 里查不到）时回退到 `tab.title`，**不**保留上次 agent pane 的标题。

**用户重命名 = 永久锁定。** 一次 inline rename 之后无视后续 session 变化。提供右键菜单「Reset to auto title」解锁（仅 `userRenamed = true` 时显示）。

## 数据流

```
agent 写 session title 到自家 store
  ↓
agent hook 触发 (prompt / stop / tool.execute.before)
  ↓ 读 session title
  ↓ emit HookMessage { ..., sessionTitle: "..." }
  ↓ Unix socket
HookSocketListener (Swift)
  ↓ decode HookMessage
HookDispatcher
  ↓ if sessionTitle != nil → TerminalSessionTitleStore.update(terminalId, title)
TerminalSessionTitleStore (@Observable, [UUID: String])
  ↓ 触发 SwiftUI 失效
TabBarView / TabItemView
  ↓ 渲染 tab.displayTitle(sessionTitleStore:)
```

## 改动清单

### Wire format（`HookMessage` + 三个 hook 端）

`HookMessage` 新增字段：

```swift
let sessionTitle: String?
```

可选；为空 / nil 时不更新 store（避免空字符串覆盖已有值）。

### Hook 端

**`Resources/agent-hooks/agent-hook.py`**：在 `dispatch` 的 `prompt` 和 `stop` 分支里附加 `sessionTitle`。

- Claude：新增 `read_ai_title(path)`，反向扫 transcript JSONL 找最后一条 `{"type":"ai-title","aiTitle":"..."}`，截到 `SUMMARY_MAXLEN`（200 字符）。Stop 子命令已扫一次 transcript 拿 summary，可在同一遍扫描里顺带拿 title。
- Codex：新增 `read_codex_title(session_id)`，glob `~/.codex/state_*.sqlite` 取最新一个，`SELECT title FROM threads WHERE id = ?` 查询。`mode=ro` + `timeout=0.5` URI 打开，防止 codex 写时阻塞 hook。`sqlite3` 模块来自 python stdlib，无新依赖。

**`Resources/agent-hooks/opencode-plugin/mux0-status.js`**：在 `tool.execute.before` 已有的 `running` socket emit 上附 `sessionTitle`，优先用 plugin context 的 `session.title`，fallback 到读 session JSON 文件。

**Session id 校验** 复用已有的 `SESSION_ID_RE`（`[A-Za-z0-9_-]+` 白名单），防止 SQLite 查询拼接被注入。

### Swift 端

**`mux0/Models/TerminalSessionTitleStore.swift`**（新文件）：

```swift
@Observable
final class TerminalSessionTitleStore {
    private(set) var titles: [UUID: String] = [:]

    func update(terminalId: UUID, title: String) { ... }   // 空字符串视为无效，跳过
    func clear(terminalId: UUID) { ... }
    func clear(terminalIds: [UUID]) { ... }
}
```

参考已有的 `TerminalPwdStore` / `TerminalStatusStore` 形态，持久化到 UserDefaults（key 模式与 PwdStore 同构）。

**`mux0/Models/Workspace.swift`**：`TerminalTab` 加字段：

```swift
var userRenamed: Bool = false
```

Codable 兼容：旧持久化数据没这个字段时按默认 `false` 解码。

**`mux0/Models/HookMessage.swift`**：新增 `sessionTitle: String?`，`init(from:)` 用 `decodeIfPresent`。

**`mux0/Models/HookDispatcher.swift`**：处理 HookMessage 时如果 `sessionTitle` 非 nil 且非空，调 `sessionTitleStore.update`。

**`mux0/Models/WorkspaceStore.swift`**：
- `closeTerminal(_:)` → 调 `sessionTitleStore.clear(terminalId:)`
- `removeTab(_:)` → 调 `clear(terminalIds:)` 遍历所有 leaf
- `removeWorkspace(_:)` → 同上
- 已有的 `renameTab` 路径里把目标 tab 的 `userRenamed` 置为 `true`
- 新增 `resetTabToAutoTitle(tabId:in:)`：把 `userRenamed` 置为 `false`，title 不动（恢复兜底文本，等 hook 重新 emit 覆盖）

**`mux0/TabContent/TabBarView.swift`**：
- `TabItemView.refresh` / 初始化时 title 来源改为 `tab.displayTitle(store:)`
- 右键菜单加「Reset to auto title」项，仅 `tab.userRenamed = true` 时显示
- TabBarView `update(...)` 签名加 `sessionTitleStore` 参数；调用方（`TabBridge` → `TabContentView`）注入

**`mux0/Bridge/TabBridge.swift`** + **`mux0/TabContent/TabContentView.swift`**：把 `TerminalSessionTitleStore` 一并传给 TabBarView，与现有 status / pwd store 路径一致。

**`mux0/mux0App.swift`**：实例化 `TerminalSessionTitleStore` 单例，注入 environment + WorkspaceStore。

### i18n

`mux0/Localization/Localizable.xcstrings` + `Localization/L10n.swift`：
- `tab.row.resetAutoTitle` —— en: "Reset to auto title"，zh-Hans: "重置为自动标题"

### 文档

- `docs/agent-hooks.md`：新增「Session title」一节，描述 `sessionTitle` wire field + 三个 agent 各自读取来源
- `CLAUDE.md` + `AGENTS.md` Directory Structure：Models 节加 `TerminalSessionTitleStore.swift`
- `CLAUDE.md` Common Tasks：新增「修改 tab 自动命名行为」条目，指向 store / dispatcher / hook 三处

## 持久化策略

- `TerminalTab.userRenamed`：随 `Workspace` Codable 一起持久化（UserDefaults，已有路径）
- `TerminalSessionTitleStore.titles`：持久化到 UserDefaults（独立 key）。重启后 tab 立即显示上次会话名，hook 重新 emit 后覆盖
- 旧版本数据：`userRenamed` 缺失按 false 解码 → 全部 tab 进入 auto 模式（即使之前手动 rename 过）。可接受的一次性迁移代价（用户重新 rename 一次即恢复锁定）

## 边界 / 失败模式

| 场景 | 行为 |
|------|------|
| Agent 还未生成 title（首 turn 内） | hook emit 空字符串 → store 跳过 → tab 显示兜底 |
| Codex SQLite 被锁 / IO 错误 | hook 静默捕获，emit 不带 sessionTitle |
| Transcript 文件不存在 / 损坏 | 同上 |
| 用户跨重启 | titles 从 UserDefaults 恢复，hook 重新 emit 覆盖 |
| 用户手动 rename 后 agent session 变了 | tab 仍显示用户名（锁定） |
| 用户 reset auto title 后 store 是空 | 显示兜底，下个 turn hook emit 时填上 |
| Shell pane focus | 显示兜底 `tab.title`，不保留上次 agent pane 的会话名 |
| Hook 端 session id 含非法字符 | `SESSION_ID_RE` 拒绝，不查 SQLite，emit 不带 sessionTitle |

## 测试策略

- `mux0Tests/`：
  - `TerminalSessionTitleStore` 的 update / clear / 持久化往返
  - `TerminalTab.displayTitle` 在 `userRenamed` × `store` 各种组合下的返回值
  - `HookDispatcher` 路由 sessionTitle 到 store
  - `HookMessage` JSON 解码兼容（无 sessionTitle 字段时 nil）
- Hook 端 Python 单测（`Resources/agent-hooks/tests/`）：
  - `read_ai_title` 命中 / 缺失 / 文件损坏
  - `read_codex_title` 命中 / 无表 / 非法 session_id
- 手动 smoke test（每个 agent 各开一个 tab，发一条 prompt，等 LLM title 生成，看 tab 名是否更新）

## 非目标

- **不**在 mux0 端缓存 SQLite / file watcher / 轮询三个 agent 的 store（一切走 hook-driven）
- **不**做"跨 tab 同步 session title"（每个 terminal 独立维护）
- **不**在 sidebar workspace 行展示 agent session title（侧边栏已有 git 分支 / PR 状态，再叠加 session title 信息过载）
- **不**改 `tab.title` 字段名（兼容旧 Codable，仅新增 `userRenamed`）
