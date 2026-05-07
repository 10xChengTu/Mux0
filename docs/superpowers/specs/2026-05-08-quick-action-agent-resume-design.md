# Quick Action Tab — Agent Session Resume

**Date:** 2026-05-08
**Branch (proposed):** `agent/quickaction-agent-resume`
**Status:** Approved, pending plan

## 背景

通过侧边栏右上角 Quick Action 按钮（claude / codex / opencode）启动的 tab，
关闭 mux0 后再打开**不会** resume 之前的 agent session — 每次都是裸命令
重新开始。但用户在普通终端里手敲 `claude` 启动的 session 重启后**会**自动
变成 `claude --resume <id>`。

行为差异源于 `TabContent/TabContentView.swift` 的 `resolvedStartupCommand(
forTerminal:)`：

```swift
// (0) Quick action：命中即 return 裸命令
if ... let actionId = tab.quickActionId, ... {
    return "\(cmd)\n"
}
// (1) Agent resume：永远轮不到
if let pending = store?.consumePendingPrefill(...) { ... }
```

代码注释明确写了 quick action 分支的语义是「重启即重新执行」，但当时没有
跟 agent resume 机制做协调。pendingPrefills 已经被正确写盘
（`WorkspaceStore.recordResumeCommand`），只是被 (0) 分支吃掉了。

## 目标

让 Quick Action 启动的 claude / codex / opencode tab 在重启后，
跟普通终端一样继承 agent session（前提是用户已开启 Settings → Agents 里
对应的 Resume toggle）。

非目标：

- 不改 hook wrapper（`Resources/agent-hooks/`）
- 不改 pendingPrefills 写入路径
- 不改 toggle UI 或默认值
- 不解决「用户主动 exit 后重启又被起回 claude」（这是 quick action 自身
  「重启即重新执行」的固有语义，跟 resume 正交）

## 设计

### 单点改动

`mux0/TabContent/TabContentView.swift` 的 `resolvedStartupCommand(forTerminal:)`
分支 (0) 内插入 resume 命中检测：

```swift
// (0) Quick action tab's first terminal
if let tab = ..., let actionId = tab.quickActionId,
   id == tab.layout.allTerminalIds().first {

    // 0a. 若该 quick action 是 builtin agent，且 Resume toggle 开 + 有
    //     prefill → 用 prefill 而非裸命令。命中要求 prefill 解析出的 agent
    //     与当前 quick action agent 一致（防止 prefill 错配）。
    if let agent = HookMessage.Agent(rawValue: actionId),
       settingsStore?.get(agent.resumeSettingsKey) == "true",
       let pending = store?.consumePendingPrefill(terminalId: id),
       HookMessage.Agent.fromResumeCommand(pending) == agent {
        return pending  // e.g. "claude --resume <id>"
    }

    // 0b. fallback：原有 quick action 命令（含 builtin override）
    if let cmd = quickActionsStore?.command(for: actionId) {
        return "\(cmd)\n"
    }
}
// (1) 既有 agent resume（裸终端用） — 不变
// (2) workspace defaultCommand — 不变
```

### 关键观察

`BuiltinQuickAction.rawValue` 跟 `HookMessage.Agent.rawValue` 完全一致
（`"claude"` / `"codex"` / `"opencode"`），所以从 quickActionId 映射到
Agent 一行 `Agent(rawValue:)` 就行 — 自定义 quick action 用 UUID 字符串，
天然不命中。

### Override 取舍（已定）

用户改了 builtin claude 的命令字符串（比如 `claude --debug`）+ Resume
toggle 开 + 有 prefill 时，**resume 优先，忽略 override**。理由：

- resume 命令是 hook 上报的合法整条形式（`claude --resume <id>`），
  agent 自己拼好的
- 用户改 builtin 命令是稀有 case，绝大部分是改 flag；既然主动开了 resume
  toggle，期望就是「重启续上」
- 简单 = 可预期：开关一开，所有 claude tab 一致行为

### 行为表

| 场景 | 旧行为 | 新行为 |
|------|--------|--------|
| Quick Action `claude` tab，Resume toggle 开，有 prefill | 裸 `claude\n` | `claude --resume <id>` |
| 同上但 Resume toggle 关 | 裸 `claude\n` | 裸 `claude\n` |
| 同上但 prefill 为空（首次 / 已被 clearResumePrefills 清过） | 裸 `claude\n` | 裸 `claude\n` |
| Quick Action `claude` tab，但 builtin 命令 override 成 `claude --debug` | `claude --debug\n` | `claude --resume <id>` |
| Quick Action `gitui` tab（非 agent） | `gitui\n` | `gitui\n` |
| 自定义 Quick Action（actionId 是 UUID） | 用户命令 | 用户命令（`Agent(rawValue:)` 失败 → 0b） |
| Quick Action tab 内 split 出的 pane | workspace defaultCommand | workspace defaultCommand（不是第一个 terminal，不进 0 分支） |
| 普通终端（无 quickActionId） | 走 (1) → resume / 或 (2) | 不变 |
| `claude` quick action tab 但 prefill 是 `codex --resume ...`（理论不应发生） | — | 不 resume，落到 0b（agent mismatch 保护） |

## 不需要改

- `WorkspaceStore.recordResumeCommand` / `consumePendingPrefill`：现有写
  盘+读取逻辑已经覆盖 quick action tab（key 是 terminalId，跟 tab 来源
  无关）
- `clearResumePrefills(forAgent:)`：toggle 关闭时清掉对应 agent 的所有
  prefill —— 已存在，无须改
- CLAUDE.md「surface 不序列化」语义不变；只在 `docs/agent-hooks.md` 里
  补一行「Quick Action tab 也参与 resume」的说明

## 测试策略

`resolvedStartupCommand` 当前是 `private`。改动后逻辑分支变多，需要单元
测试，因此抽出一个纯函数 helper：

```swift
// 静态、纯函数：仅依赖入参，便于测试
static func resolveStartupCommand(
    forTerminal id: UUID,
    in tab: TerminalTab?,
    workspace: Workspace?,
    quickActionsStore: QuickActionsStore?,
    settingsStore: SettingsConfigStore?,
    pendingPrefill: String?
) -> String?
```

`TabContentView.resolvedStartupCommand` 内部组装入参后调用之；测试直接
调用 static helper，避免桥接 NSView/store 真实实例。

新增 `mux0Tests/TabContent/StartupCommandResolverTests.swift`，覆盖：

1. quick action `claude` + toggle on + matching prefill → 返回 prefill
2. 同上 + toggle off → 返回裸 `claude\n`
3. 同上 + prefill 解析出的 agent 与 actionId mismatch（`codex --resume ...`） → 裸 `claude\n`
4. 同上 + prefill 为空 → 裸 `claude\n`
5. quick action `gitui` + 任意 prefill → `gitui\n`（非 agent 不走 resume）
6. 自定义 quick action（UUID id）+ matching-looking prefill → 用户命令（Agent rawValue 不命中）
7. quick action `claude` + builtin override `claude --debug` + toggle on + prefill → 返回 prefill（A1 取舍）
8. 普通终端（无 quickActionId） + claude prefill + toggle on → 返回 prefill（既有 (1) 分支不回归）
9. 普通终端 + 无 prefill + workspace defaultCommand → 返回 defaultCommand（既有 (2) 分支不回归）

## 影响面

- 一个 Swift 文件主要改动：`mux0/TabContent/TabContentView.swift`
- 新增一个 helper 文件或保持在 TabContentView.swift 内部 static 方法（plan
  阶段决定）
- 一个新测试文件
- 一行 `docs/agent-hooks.md` 更新

## 风险

- **prefill 与 quick action agent 类型 mismatch 时被错误注入**：通过
  `HookMessage.Agent.fromResumeCommand(pending) == agent` 二次校验
  消除
- **回归普通终端 (1) 分支**：通过测试 8/9 锁定既有行为
- **opencode wrapper 不上报 resumeCommand**：自然落到 fallback 0b，跑裸
  `opencode\n` —— 跟现状等价，无回归

## 提交格式

`feat(tabcontent): resume agent session on quick-action tab restart`

scope `tabcontent` 与 CLAUDE.md 第 5 条 commit 规则一致。
