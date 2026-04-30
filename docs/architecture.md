# Architecture

## Overview

mux0 是 SwiftUI 侧边栏 + AppKit 标签页 / 分割窗格混合架构。两层通过 `NSViewRepresentable` 桥接。状态单向流动：**WorkspaceStore → 视图**，用户交互写回 WorkspaceStore。

> **历史说明**：早期版本采用"无限白板 Canvas + 自由浮动终端窗口"，2026-04 改为"Workspace → Tab → SplitNode 树"形态。旧实现已全部删除，只保留 `mux0/Canvas/DESIGN_NOTES.md` 作历史参考。迁移理由见 `docs/decisions/003-tabs-over-canvas.md`。

```
mux0.app
├── Sidebar (SwiftUI 壳 + AppKit 列表)  — workspace 列表，元信息展示
│   └── SidebarView (SwiftUI: header / footer / alert / 通知 / refresher)
│       └── SidebarListBridge (NSViewRepresentable)
│           └── WorkspaceListView (NSView)
│               └── WorkspaceRowItemView[] (private NSView)
├── TabBridge (NSViewRepresentable)
│   └── TabContentView (NSView，按 selectedWorkspace 渲染)
│       ├── TabBarView (NSView，标签条：+ / 关闭 / 重命名 / 拖拽)
│       └── SplitPaneView (NSView，递归 NSSplitView)
│           └── SurfaceScrollView[] (NSScrollView 包装叶子，提供原生滚动条)
│               └── GhosttyTerminalView (Metal + surface)
├── SettingsView (SwiftUI，叠在 TabBridge 上；showSettings 时压底层且关交互)
├── WorkspaceStore (@Observable)        — 持久化状态唯一来源
├── TerminalStatusStore (@Observable)   — 终端运行态聚合（running/idle/needsInput）
├── TerminalPwdStore (@Observable)      — terminalId → pwd 映射（持久化到 UserDefaults；sidebar git 分支读取 / 重启恢复目录）
├── SettingsConfigStore (@Observable)   — mux0 override config 读写
├── ThemeManager (@Observable)          — 主题解析与分发
├── HookSocketListener                  — Unix socket 接收 agent/shell hook
└── GhosttyBridge (singleton)           — libghostty C API 封装
```

## 核心数据模型

```
Workspace
├── id: UUID
├── name: String
├── tabs: [TerminalTab]
└── selectedTabId: UUID?

TerminalTab
├── id: UUID
├── title: String
├── layout: SplitNode      ← indirect enum，二叉树
└── focusedTerminalId: UUID

SplitNode
├── .terminal(UUID)                                       ← 叶子
└── .split(splitId, direction, firstRatio, first, second) ← 分支
```

**不变量：**
- `layout.allTerminalIds()` 不得出现重复 UUID
- `focusedTerminalId` 必须在 `layout.allTerminalIds()` 内
- 同一 workspace 下所有 tabs 的终端 UUID 集合两两不相交
- 仅靠 `SplitNode` 结构 + UUID 持久化终端布局；`ghostty_surface_t` 不序列化

## Data Flow

### 状态流

```
WorkspaceStore (@Observable)
    ↓ 传参 / @Environment
SidebarView ──────── 读 + 交互写回
TabBridge ────────── 读 + 交互写回（createTab / closeTab / split / moveRatio / focus）

用户交互 → WorkspaceStore.method() → 触发视图更新（SwiftUI 自动；AppKit 走 onChange 通知 / observe）
```

### Workspace 切换

```
点击侧边栏 WorkspaceRow
→ WorkspaceStore.select(id)
→ TabBridge 感知 selectedId 变化 → TabContentView.loadWorkspace(newId)
→ 当前 tab 的 SplitPaneView 从视图树移除（GhosttyTerminalView 保留在内存缓存，surface 不销毁）
→ 目标 workspace.selectedTab 对应的 SplitPaneView 重建 / 复用（见下方缓存规则）
```

### 新建 tab / 分割窗格

```
Cmd+T / TabBarView 上的 "+"
→ WorkspaceStore.addTab(to: workspaceId) → 追加 TerminalTab（layout = .terminal(newUUID)）

Cmd+D (vertical) / Cmd+Shift+D (horizontal) / 菜单
→ WorkspaceStore.splitFocused(in: workspaceId, direction:)
→ 更新 tab.layout：把 .terminal(focusedId) 替换成 .split(_, dir, 0.5, .terminal(focusedId), .terminal(newId))
→ SplitPaneView diff 新 tree → 新 GhosttyTerminalView 通过 GhosttyBridge.newSurface(...) 生成 surface
```

### 拖动 divider

```
NSSplitView.delegate 回调
→ WorkspaceStore.updateRatio(splitId:to:) (debounced save)
→ SplitNode 仅 ratio 变化，SplitPaneView 不重建（见 SplitNode.sameStructure）
```

### 主题更新

```
系统外观变化 / ghostty config 变更 / SettingsConfigStore 触发 reloadConfig
→ ThemeManager 重新解析，更新 currentTheme
→ SwiftUI 侧边栏 / SettingsView 自动重绘（@Observable）
→ TabContentView.updateTheme() 穿透刷新 TabBarView + SplitPaneView 内的 layer 颜色
→ GhosttyBridge.shared.reloadConfig() 通知 ghostty 所有 surface
```

### 终端状态推送

```
shell / agent 写一行 JSON 到 Unix socket（~/.config/mux0/hooks.sock 之类）
→ HookSocketListener 读取并解码 HookMessage
→ TerminalStatusStore.setRunning / setIdle / setNeedsInput
→ Theme/TerminalStatusIconView 读 store，sidebar / tab 上的圆点颜色刷新
```

详见 `docs/agent-hooks.md`。

`.success` / `.failed` 这两种 turn 终态支持"已读"修饰：关联值 `readAt: Date?`
为 nil 时实心（未读），非 nil 时空心 stroke-only（已读）。`ContentView` 在
`store.selectedId` 或选中 workspace 的 `selectedTabId` 变化时，把 on-screen
（当前 workspace 的当前 tab 分屏树里的全部）terminal id 喂给
`TerminalStatusStore.markRead(terminalIds:)`。下一次 `setFinished` 会重写
storage entry，`readAt` 自然归 nil（新结果 → 重新未读）。`aggregate` 在同
优先级内偏好未读项，保证 "workspace 还有其它未看过的终态" 能稳住实心显示。

### 终端 PWD 追踪

```
shell 启动 / cd → ghostty shell-integration 发 OSC 7 (kitty-shell-cwd://)
→ ghostty 解析并触发 GHOSTTY_ACTION_PWD（target = surface）
→ GhosttyBridge.actionCallback → DispatchQueue.main
→ GhosttyTerminalView.view(forSurface:) 取回 terminalId
→ GhosttyBridge.onPwdChanged(terminalId, pwd) → TerminalPwdStore.setPwd
→ TerminalPwdStore 300ms debounce → UserDefaults 写盘（key mux0.pwds.v1）
→ SidebarView 的 MetadataRefresher 下一 5s tick 从 pwdStore 读 focused
   terminal 的 pwd 作为 cwd 跑 `git rev-parse --abbrev-ref HEAD`
→ WorkspaceMetadata.gitBranch 更新 → 侧边栏行的 ⎇ 分支刷新
```

`TerminalPwdStore` 的 pwd 映射还有两处消费：

1. **新建 tab / 拆分 pane / 新建 workspace**：`inherit(from:to:)` 在创建新 terminalId 时把源 pane 的 pwd 预写到新 id 下，让新 shell 落在继承的工作目录而非默认目录。
2. **app 重启恢复**：`GhosttyTerminalView.viewDidMoveToWindow` 从 UserDefaults 读出上次记录的 pwd，经 `GhosttyTerminalView.validatedDirectory(_:)` 用 `FileManager` 校验（路径不存在或非目录则返回 nil），再传给 `GhosttyBridge.newSurface(workingDirectory:)`；校验失败时 ghostty 回退默认目录（通常 `$HOME`）。

## Theme System

ThemeManager 按优先级合并三个来源：

1. mux0 用户手动覆盖（最高）
2. `~/.config/ghostty/config` 中的 `theme =` 字段（由 GhosttyConfigReader 解析）
3. macOS 系统深色 / 浅色模式（兜底）

所有视图从 `ThemeManager.currentTheme: AppTheme` 取色，不硬编码任何颜色。ghostty config 解析失败时自动降级，不 crash。

**token 列表（AppTheme）:**

| token | 用途 |
|-------|------|
| `sidebar` | 侧边栏背景 |
| `canvas` | 标签内容区（中央卡片）背景 |
| `foreground` | 主文字色 |
| `border` / `borderStrong` | 分割线、标签未激活边框、hover 背景 |
| `accent` | 激活 tab / 激活 pane 边框、高亮 |
| `selection` | 选中背景色 |
| `textSecondary` | 次要文字（metadata / help） |

ThemeManager 还承载三个窗口级不透明度：`backgroundOpacity`（sidebar 层）、`contentEffectiveOpacity`（卡片层叠加）、`blurRadius`。全部由 SettingsConfigStore 的 `background-opacity` / `background-blur-radius` / `mux0-content-opacity` 驱动。

## Tab & SplitPane Layer

Tab + SplitPane 全部用 AppKit，原因：NSSplitView 的 divider 拖拽、z-order、精确 frame 控制比 SwiftUI `HStack/VStack` 及其 `.gesture` 更可靠；且 ghostty surface 对 live resize 有严格的 frame 约定，AppKit 层 layout pass 更可控。

- `TabBarView` — 固定高度水平条，内部自绘 tab cell，支持拖拽重排（`.mux0Tab` UTI）
- `TabContentView` — 按 `selectedTabId` 渲染对应的 SplitPaneView；对已切走的 tab 做 view 缓存（key = tab.id），避免 surface 被重新创建
- `SplitPaneView` — 递归构建 `NSSplitView`，叶子是 `SurfaceScrollView`（包装 `GhosttyTerminalView`）。结构变化触发 rebuild；仅 ratio 变化只调 `setPosition(_:ofDividerAt:)`（见 `SplitNode.sameStructure` 注释）
- `SurfaceScrollView` — `NSScrollView` + 空白 `documentView`，`GhosttyTerminalView` 作为 documentView 子视图并 pin 在 `visibleRect` 上。消费 ghostty 的 `SCROLLBAR`（total/offset/len 行数）与 `CELL_SIZE`（backing px → pt）action 驱动 scroller；用户拖拽时转成行号并通过 `scroll_to_row:N` binding action 回写 ghostty。永远 overlay 样式以避免非 overlay 滚动条变宽引起的 PTY reflow
- `GhosttyTerminalView` — 持有 `ghostty_surface_t`，Metal CALayer 渲染；失焦时整体降 alpha 到 `unfocused-split-opacity`

### Quick Actions

WorkspaceStore 的每个 Tab 可关联一个**快捷操作 ID**（`TerminalTab.quickActionId: String?`），由顶栏的 Quick Actions Bar（`ContentView.quickActionsBar`）按 `QuickActionsStore.displayList` 顺序渲染按钮触发：点击 → `WorkspaceStore.ensureQuickActionTab(id:title:in:)` 在当前 workspace 找到/新建对应 tab，并通过 `TerminalPwdStore.inherit(from:to:)` 继承前一个焦点 pane 的 pwd（让 `lazygit` 等命令落地在用户当下浏览的 cwd）。

**身份按 ID 区分，不按 title。** 用户改 tab 标题不影响"再点同样按钮 → 复用同一 tab"这条不变量；每个 workspace 对每个 quick action id 最多一个 tab。

**`QuickActionsStore`** 是 enabled 列表（按显示顺序排）+ 内置命令覆盖（per-id）+ 自定义条目数组的单一真理源，全部通过 `SettingsConfigStore` 持久化（3 个键：`mux0-quickactions-enabled` / `mux0-quickactions-builtin-command-<id>` / `mux0-quickactions-custom`）。`@Observable`，UI 直接订阅。

**命令注入路径：** Tab 第一个终端启动时（`id == tab.layout.allTerminalIds().first`），`TabContentView.resolvedStartupCommand(forTerminal:)` 检测 `tab.quickActionId` 非空 → 调 `quickActionsStore.command(for: id)`：内置 = override 或默认（`lazygit` / `claude` / `codex` / `opencode`），自定义 = 用户输入命令。返回值作为 `initial_input` + `\n` 喂给 ghostty surface，shell 启动后立即执行。Split 出的次级 pane 不会再跑（它不是 layout 第一个终端）。

**重启恢复：** Tab 数据序列化到 UserDefaults，重启后 `tab.quickActionId` 还在 → 同一注入路径自动重新跑命令（lazygit 重新打开、claude 重新连接……）。Surface 不序列化，重启后是新 ghostty surface。

**图标：** `BuiltinQuickAction.iconSource` 三种来源——SF Symbol（lazygit 用 `arrow.triangle.branch`）、Asset Catalog（claude / codex / opencode 用 lobe-icons SVG，`template-rendering-intent: template`）、首字母（自定义）。三种统一通过 `QuickActionIconView` 渲染，跟随 theme token tint。

**Settings：** `Settings → Quick Actions` 提供单一可拖拽列表，所有 4 内置 + N 自定义混排，每行可独立 toggle 启用 / 改命令；自定义可改名 / 删除。详见 `docs/superpowers/specs/2026-04-30-quick-actions.md`。

## Settings Layer

`SettingsView` 是纯 SwiftUI Form，覆盖在 TabBridge 之上。进入设置时 TabBridge 被压到底层（`.opacity(0)` + `.allowsHitTesting(false)`）**但不 dismantle**，否则 `NSViewRepresentable` 重建会让所有 ghostty surface 被释放重建。

- `SettingsConfigStore` 读写 mux0 独立的 override config（不污染用户 ghostty config），改动 200ms debounce 后写盘并触发 `onChange`
- `onChange` 依次调用 `applyWindowEffectsFromSettings → GhosttyBridge.reloadConfig → ThemeManager.refresh → applyUnfocusedOpacityFromSettings`
- 字段清单与默认值见 `docs/settings-reference.md`

## GhosttyBridge

封装 libghostty 全部 C API 调用。其他文件 **不直接** 调用 `ghostty_*`。

- `initialize()` — 在 `mux0App.init()` 中调用一次
- `newSurface(nsView:scaleFactor:workingDirectory:)` — 创建 surface，由 `GhosttyTerminalView` 管理生命周期；`workingDirectory` 由 `viewDidMoveToWindow` 从 `TerminalPwdStore` 读出并经 `FileManager` 校验后传入，nil 时 ghostty 在默认目录（通常 `$HOME`）启动 shell
- `reloadConfig()` — SettingsConfigStore 改动后重读 config 并下发到所有活 surface
- `applyWindowBackgroundBlur(to:)` — 根据 config 在 NSWindow 上安装/卸载 blur layer
- `teardown()` — app 退出时释放 app/config

## Persistence

WorkspaceStore 用 UserDefaults + Codable 存 `workspaces` 数组（含 tabs 和 SplitNode tree，key `mux0.workspaces.v2`）和 `selectedId`。divider 拖拽走 debounced save 避免每帧写盘。

`ghostty_surface_t` 不序列化 — 重启后 `GhosttyTerminalView` 按 UUID 重建 surface。

`TerminalPwdStore` 用 UserDefaults 存 `terminalId → pwd` 映射（key `mux0.pwds.v1`），300ms debounce 写盘。重启时 `GhosttyTerminalView.viewDidMoveToWindow` 读取对应 uuid 的 pwd，校验后传给 `newSurface(workingDirectory:)` 恢复上次工作目录。

SettingsConfigStore 用自己的文件持久化，独立于 UserDefaults。

## Localization (i18n)

The `mux0/Localization/` module handles all user-facing text:

- `LanguageStore` (`@Observable`, singleton) holds the user's preference
  (`.system | .zh | .en`), persists it to UserDefaults (`mux0.language`),
  and publishes a `tick` counter + `locale` + `effectiveBundle`.
- SwiftUI views use `Text(L10n.Namespace.key)`; locale comes from
  `mux0App`'s `.environment(\.locale, languageStore.locale)` injection.
  `Text(LocalizedStringResource)` honors the injected locale directly.
- For call sites that resolve to `String` (e.g. `IconButton.help`) use
  `String(localized: L10n.Namespace.key.withLocale(locale))` after reading
  `@Environment(\.locale) private var locale`. The `.withLocale(_:)` helper
  overrides `Locale.current` which `String(localized:)` would otherwise
  ignore the SwiftUI env.
- AppKit subclasses (`TabBarView`, `WorkspaceListView`, etc.) compute
  strings via `L10n.string("raw.key")` against
  `LanguageStore.shared.effectiveBundle`. When language changes, each
  `*Bridge` reads `languageStore.tick`, triggering `updateNSView` which
  calls `refreshLocalizedStrings()` on its subview to rebuild tracked
  labels.
- The Commands menu bar (`mux0App.swift`) references `LanguageStore.shared.locale`
  directly and touches `languageStore.tick` in the Scene body to force
  re-evaluation on language switch.

See `docs/i18n.md` for the developer guide. Adding a new string or a new
language is documented there.

## Error Handling

| 场景 | 处理 |
|------|------|
| `ghostty_surface_new()` 失败 | 对应 pane 内显示 inline error banner，不影响兄弟 pane |
| libghostty 未初始化 | 启动时检测，显示 GhosttyMissingView |
| ghostty config 解析失败 | 降级到系统模式，不 crash |
| 持久化失败 | 静默跳过，重启后加载上一次成功写盘的状态 |
| HookSocketListener 启动失败 | 打印 log，其他功能正常（状态图标只是不更新） |

## Auto-Update

基于 [Sparkle](https://sparkle-project.org) 2.6+。Sparkle 只负责"下载、EdDSA 校验、重启安装"引擎，UI 完全自绘以对齐 mux0 其它 settings 面板。

```
Sparkle internal ─► UpdateUserDriver (SPUUserDriver)
                       │ (MainActor mutate)
                       ▼
                   UpdateStore (@Observable)
                       │
                       ├─► SidebarView footer (红点)
                       └─► UpdateSectionView (主面板)

User click ──► SparkleBridge.{checkForUpdates | downloadAndInstall | skipVersion | dismiss | retry}
                   │
                   ▼
               SPUUpdater APIs
```

**关键约束:**
- Sparkle 符号只在 `mux0/Update/SparkleBridge.swift` 和 `UpdateUserDriver.swift` 里 `import`，与 ghostty 约定对齐。
- `UpdateStore` 是唯一写入口；所有 UI 通过它读状态。
- Debug 构建 `#if !DEBUG` 守卫掉整个 Sparkle 调用链，`SparkleBridge.isActive` 为 false，不发任何网络请求。
- Feed: `https://github.com/10xChengTu/mux0/releases/latest/download/appcast.xml`。appcast 仅含当前版本一个 `<item>`，历史版本交给 GitHub Releases 页面承载。
- 启动 3 s 后静默 check 一次；Sparkle 自带 24 h 定时器后续 check。
