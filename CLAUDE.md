# mux0

macOS 标签页 + 分割窗格式终端 app，以 libghostty 作为终端引擎，Swift/AppKit + SwiftUI 实现。

## Quick Start

```bash
# 1. 首次构建 libghostty（只需一次）
./scripts/build-vendor.sh

# 2. 生成 Xcode 工程
xcodegen generate

# 3. 构建并运行（命令行）
xcodebuild -project mux0.xcodeproj -scheme mux0 -configuration Debug build

# 4. 运行测试
xcodebuild test -project mux0.xcodeproj -scheme mux0Tests

# 5. 检查文档/目录是否漂移
./scripts/check-doc-drift.sh
```

## Architecture Overview

SwiftUI 侧边栏 + AppKit 标签页/分割窗格混合架构。每个 Workspace 持有一组 TerminalTab，每个 Tab 存一棵 `SplitNode` 树（二叉 split + terminal 叶子）。WorkspaceStore (@Observable) 是唯一状态来源，通过 environment 注入到所有视图。libghostty C API 封装在 GhosttyBridge 单例中，不直接调用 `ghostty_*` 函数在其他文件。

详见 `docs/architecture.md`。

> **历史说明**：早期版本是"白板/Canvas 无限画布"形态，2026-04 迁移到标签页 + 分割。相关决策见 `docs/decisions/003-tabs-over-canvas.md`，旧的设计笔记保留在 `mux0/Canvas/DESIGN_NOTES.md` 仅作参考。

## Directory Structure

```
mux0/
├── mux0App.swift          — @main 入口，ghostty init，全局 menu commands
├── ContentView.swift      — 根 ZStack/HStack：SidebarView + TabBridge（+ SettingsView 叠层）
├── WindowAccessor.swift   — NSViewRepresentable，把 NSWindow 交给 ghostty 安装 blur layer
├── Bridge/
│   ├── TabBridge.swift          — TabContentView SwiftUI ↔ AppKit 桥接
│   └── SidebarListBridge.swift  — WorkspaceListView SwiftUI ↔ AppKit 桥接
├── Canvas/
│   └── DESIGN_NOTES.md    — 仅保留旧白板形态的设计笔记（代码已全部删除）
├── TabContent/
│   ├── TabBarView.swift       — NSView，水平标签条（新建/关闭/重命名/拖拽）
│   ├── TabContentView.swift   — NSView，承载当前 workspace 的 tabs，管理 SplitPaneView 缓存
│   ├── SplitPaneView.swift    — 递归 NSSplitView 渲染 SplitNode，drag divider + 键盘焦点导航
│   ├── SurfaceScrollView.swift — NSScrollView 包装 GhosttyTerminalView，提供原生 overlay 滚动条（消费 ghostty SCROLLBAR/CELL_SIZE action，拖拽回写 `scroll_to_row:N`）
│   └── PasteboardTypes.swift  — .mux0Tab UTI 常量
├── Ghostty/
│   ├── ghostty-bridging-header.h  — 桥接头文件
│   ├── GhosttyBridge.swift        — libghostty 单例（app/config 生命周期 + window blur）
│   └── GhosttyTerminalView.swift  — NSView，持有 ghostty_surface_t，Metal 渲染
├── Localization/
│   ├── LanguageStore.swift  — @Observable，语言偏好 + UserDefaults 持久化 + effectiveBundle + locale + tick
│   ├── L10n.swift           — 常量命名空间（LocalizedStringResource + AppKit helper L10n.string(_:args...)）
│   └── Localizable.xcstrings    — Xcode String Catalog（en source + zh-Hans 翻译）
├── Metadata/
│   ├── WorkspaceMetadata.swift  — git/PR/通知 数据结构
│   └── MetadataRefresher.swift  — 5s 轮询 + OSC 通知处理 + onRefresh 回调
├── Models/
│   ├── Workspace.swift            — Workspace / TerminalTab / SplitNode / SplitDirection（Codable）
│   ├── WorkspaceStore.swift       — @Observable，workspace / tab / split CRUD + UserDefaults 持久化
│   ├── QuickAction.swift          — BuiltinQuickAction enum + CustomQuickAction struct + QuickActionIcon
│   ├── QuickActionsStore.swift    — @Observable，enabled / overrides / custom 三段持久化
│   ├── TerminalStatus.swift       — 单终端运行状态枚举（running / idle / needsInput）
│   ├── TerminalStatusStore.swift  — @Observable，终端状态聚合（供 sidebar / tab 图标读取）
│   ├── TerminalPwdStore.swift     — @Observable，terminalId → pwd 映射（ghostty PWD action 喂入，sidebar git 分支读取）
│   ├── HookDispatcher.swift       — 按 agent toggle 过滤 hook 事件 + 派生 status icon UI 主开关
│   ├── HookMessage.swift          — agent/shell hook 的 JSON wire format
│   └── HookSocketListener.swift   — Unix domain socket 监听，解析 HookMessage → statusStore
├── Settings/
│   ├── SettingsView.swift         — SwiftUI 根面板，承载七个 Section
│   ├── SettingsConfigStore.swift  — @Observable，读写 mux0 config（200ms debounce）
│   ├── SettingsTabBarView.swift   — Appearance / Font / Terminal / Shell / Quick Actions / Agents / Update 分类切换
│   ├── SettingsSection.swift      — Section 枚举定义
│   ├── ThemeCatalog.swift         — 只读扫描 bundle 内 ghostty/themes/
│   ├── Components/                — 复用 SwiftUI 控件（BoundControls / FontPicker / QuickActionIconView / QuickActionRowView / ThemePicker / ...）
│   └── Sections/                  — 七个 Section 的视图实现（Appearance / Font / Terminal / Shell / QuickActions / Agents / Update）
├── Sidebar/
│   ├── SidebarView.swift              — SwiftUI 壳：header / footer / alert / 通知订阅 / refresher 生命周期
│   ├── WorkspaceListView.swift        — AppKit 列表 + private WorkspaceRowItemView
│   └── WorkspacePasteboardType.swift  — .mux0Workspace UTI 常量
├── Update/
│   ├── UpdateState.swift         — 自动更新 UI 状态枚举（idle / checking / upToDate / updateAvailable / downloading / readyToInstall / error）
│   ├── UpdateStore.swift         — @Observable，自动更新状态存储（sidebar 红点 + Settings Update section 都读这个）
│   ├── SparkleBridge.swift       — 单例，持有 SPUUpdater，对外暴露 checkForUpdates/downloadAndInstall/skip/dismiss/retry；Debug 下为空 stub
│   └── UpdateUserDriver.swift    — 实现 Sparkle 的 SPUUserDriver，事件 → UpdateStore 变更（MainActor，Release-only）
└── Theme/
    ├── AppTheme.swift               — 设计 token 结构体（sidebar / canvas / border / accent / ...）
    ├── DesignTokens.swift           — token 定义与 spacing / radius / layout 常量
    ├── GhosttyConfigReader.swift    — 从 ghostty config 读颜色
    ├── ThemeManager.swift           — @Observable，主题解析与分发（含 opacity / blur）
    ├── IconButton.swift             — 紧凑图标按钮（hover/pressed 走 theme token）
    ├── DraggedSnapshotShadow.swift  — 拖拽 ghost 的分层阴影合成（Josh Comeau layered-shadow 方案）
    └── TerminalStatusIconView.swift — 终端状态圆点图标
```

## Key Conventions

1. **所有颜色取自 AppTheme token** — 禁止在视图里硬编码 `Color(...)` 或 `NSColor(...)`，从 `@Environment(ThemeManager.self)` 取 `.currentTheme` 或直接传 `theme` 参数
2. **ghostty API 只在 GhosttyBridge 和 GhosttyTerminalView 中调用** — 其他文件不 `import` 也不直接调用 `ghostty_*` 函数
3. **状态写回 WorkspaceStore** — 所有持久化状态（workspace 列表、tab 列表、SplitNode tree、selectedTabId）通过 WorkspaceStore 的方法修改，不直接改 struct 字段
4. **TabBar / SplitPane / SidebarList 用 NSView subclass；SidebarView / SettingsView 壳（header / footer / alert / 通知订阅 / 元数据 refresher 生命周期 / 设置表单）用 SwiftUI View struct** — AppKit ↔ SwiftUI 边界统一在 `*Bridge: NSViewRepresentable`
5. **提交格式** `type(scope): description` — e.g. `feat(tabcontent): add drag-to-reorder`；scope 与目录对应，合法值：`sidebar | tabcontent | settings | theme | ghostty | models | metadata | bridge | build | docs | update | i18n | assets`
6. **不 push 到 master** — 用 `agent/feature-name` 分支，PR 合并
7. **surface 不序列化** — `Workspace → tabs → SplitNode` 只存 UUID 与 split ratio；重启后 GhosttyTerminalView 按 UUID 重建 surface
8. **文档与目录结构同步** — 增删/重命名/移动 `mux0/` 下的目录或 Swift 文件时，**同一 PR 必须同步更新** CLAUDE.md、AGENTS.md 的 Directory Structure 与 `docs/architecture.md` 中受影响的章节。提交前跑 `./scripts/check-doc-drift.sh` 自检。新模块还要在 Common Tasks 或 Documentation Map 里补条目

## Documentation Map

| 主题 | 文件 |
|------|------|
| 系统架构与数据流 | `docs/architecture.md` |
| 编码规范与模式 | `docs/conventions.md` |
| libghostty 集成 | `docs/ghostty-integration.md` |
| 测试策略 | `docs/testing.md` |
| 构建与 Vendor | `docs/build.md` |
| Agent 状态钩子（Claude/OpenCode/Codex wrapper + IPC） | `docs/agent-hooks.md` |
| 设置面板字段参考 | `docs/settings-reference.md` |
| 设计决策记录 | `docs/decisions/` |
| 国际化 (i18n) | `docs/i18n.md` |

## Common Tasks

| 任务 | 相关文件 / 命令 |
|------|----------------|
| 修改主题颜色逻辑 | `Theme/ThemeManager.swift`, `Theme/AppTheme.swift`, `docs/architecture.md#theme` |
| 增加新的 workspace 元信息字段 | `Metadata/WorkspaceMetadata.swift` → `Metadata/MetadataRefresher.swift` → `Sidebar/WorkspaceListView.swift`（行视觉） |
| 改标签/分割窗格交互（新建 tab、拆分、拖 divider） | `TabContent/TabBarView.swift`, `TabContent/TabContentView.swift`, `TabContent/SplitPaneView.swift`, `Models/WorkspaceStore.swift`（新 CRUD 方法） |
| 增加新的内置快捷操作 | `Models/QuickAction.swift`（加 `BuiltinQuickAction` case + 默认命令 + `iconSource`），`Models/QuickActionsStore.swift`（默认 enabled 列表如需调整），`Localizable.xcstrings` + `Localization/L10n.swift`（displayName key），必要时 `Assets.xcassets` 加 SVG imageset（`template-rendering-intent: template`），`docs/settings-reference.md`（如新增 builtin id 范围） |
| 增加用户自定义快捷操作 | UI 已支持，运行时由用户在 Settings → Quick Actions 中点击「新建自定义快捷操作」创建，无需改代码 |
| 接入新的 ghostty C API | `Ghostty/GhosttyBridge.swift`，需同步更新 `docs/ghostty-integration.md` |
| 改自动更新 UI / 行为 | `mux0/Update/UpdateStore.swift`, `mux0/Update/UpdateUserDriver.swift`, `mux0/Settings/Sections/UpdateSectionView.swift`, `mux0/Sidebar/SidebarView.swift`（footer） |
| 改发布流水线 / appcast 格式 | `.github/workflows/release.yml`, `.github/scripts/render-appcast.sh`, `docs/build.md` |
| 发新版本 | 改 `project.yml` 的 `MARKETING_VERSION` → `./scripts/sync-landing-version.sh` 同步 landing → commit → push 到 master（CI 自动 bump build + 打 tag + 发版，详见 `docs/build.md#release-流程`） |
| 同步 landing 版本号 | `./scripts/sync-landing-version.sh`（`--check` 为只读校验，CI drift check 会调用） |
| 新增设置项 | `Settings/Sections/<对应>.swift`, `Settings/SettingsConfigStore.swift`（默认值/校验）, `docs/settings-reference.md` |
| 新增终端状态来源 | `Models/HookMessage.swift` → `Models/HookSocketListener.swift` → `Models/TerminalStatusStore.swift`，展示在 `Theme/TerminalStatusIconView.swift` |
| 侧边栏 / Tab 的 rename / delete / reorder 交互 | `Sidebar/SidebarView.swift`, `Sidebar/WorkspaceListView.swift`, `Bridge/SidebarListBridge.swift`, `TabContent/TabBarView.swift`, `TabContent/TabContentView.swift`, `Models/WorkspaceStore.swift` |
| 跑测试 | `xcodebuild test -project mux0.xcodeproj -scheme mux0Tests` |
| 重新生成 Xcode 工程 | `xcodegen generate`（修改 `project.yml` 后执行）|
| 检查文档漂移 | `./scripts/check-doc-drift.sh`（对比 Directory Structure 与真实 `mux0/` 目录；同时校验 landing 版本号与 `project.yml` 一致） |
| 新增文案 / 支持新语言 | `mux0/Localization/Localizable.xcstrings`, `mux0/Localization/L10n.swift`, `mux0Tests/L10nSmokeTests.swift`, `docs/i18n.md` |

## Agent Permissions

**允许:**
- 修改 `mux0/` 下任意 Swift 文件
- 运行 `xcodebuild build/test`、`xcodegen generate`
- 创建 `agent/` 前缀的 git 分支
- 修改 `docs/` 文档

**禁止（需人工确认）:**
- 修改 `scripts/build-vendor.sh` 或 Vendor 目录
- 修改 `project.yml`（影响 Xcode 工程结构）
- Push 到 master
- 修改 `.github/` CI 配置
- **主动重启 / `open` / `killall` 运行中的 mux0.app** — mux0 是原生 macOS 应用不支持热更新，但用户可能正在使用这个应用。改完代码跑 `xcodebuild build` 验证能编译即可，由用户自己决定何时重启看效果
