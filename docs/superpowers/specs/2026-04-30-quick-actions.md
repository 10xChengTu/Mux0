# Quick Actions —— Design

## Context

未发布的 git tab 功能（`agent/git-tab` 分支，未合并 master）只解决了一个场景：右上角 git 图标按钮 → 在当前 workspace 找到/新建一个跑 `lazygit` 的 tab。

现实里用户经常切换的不只 git 一种工具：还有 `claude` / `codex` / `opencode` 这类 agent CLI，以及他们自己的脚本（比如 `htop` / `gh dashboard` / 自家测试 runner）。用现状的"git button"形态横向扩展会让顶栏写死越来越多专用按钮，而且都写到 `ContentView` / `WorkspaceStore` / `TabContentView` 里去。

这个设计把 git tab 推广为通用的"快捷操作 / Quick Actions"系统：内置 4 个常用 CLI（lazygit、claude、codex、opencode）+ 用户自定义任意条目，每条可单独启用、可改命令、可拖拽排序，启用的按钮按用户排序显示在窗口右上角。

git tab 还没发版，所以本设计**完全替换**git-tab 实现：删除 `TabKind` enum / `mux0-git-viewer` 设置 / `ensureGitTab` 方法 / `gitTabButton` view / `topbar.gitButton.tooltip` i18n key，没有用户数据迁移负担。

## Goals

- **替换 git-tab 为通用化的 Quick Actions**——同样的"右上角按钮 → find-or-create tab"机制扩展到任意 action id。
- **内置 4 个 action**（lazygit / claude / codex / opencode），每个有默认命令和 brand 图标；命令可被用户覆盖。
- **用户可自定义 action**——任意名称、任意命令、首字母自动作为图标。
- **每个 action 独立 enabled toggle**——只有启用的 action 才出现在右上角。
- **可拖拽排序**——内置和自定义混排，顺序即右上角显示顺序。
- **重启后启用按钮恢复 + tab 内的 action 命令重新执行**（现状 git tab 已实现，沿用）。
- **每 workspace 每 action id 最多一个 tab**，重复点同一按钮只切换不新建（沿用 ensureGitTab 语义）。
- **无用户迁移负担**——git tab 未发布，可以直接删旧字段/旧设置。

## Non-Goals

- 不为内置 action 做"未安装时的检测/引导弹窗"（让 CLI 自己报错，避免与状态轮询 race；`lazygit` 现状已是这样）。
- 不在 mux0 里打包任何内置 CLI 的二进制（依赖用户 PATH）。
- 不为"非 git 仓库时禁用 lazygit 按钮"做预检测（现状 git tab 已显式拒绝过这事）。
- 不做 workspace 维度的 action 列表（action 全局共享，不能"workspace A 显示 lazygit、workspace B 显示 claude"）。
- 不做 action 之间的 hotkey（⌘1/⌘2/...）绑定，YAGNI。
- 不做按钮 group / 折叠（如果用户启用了 8 个，就是 8 个按钮挨着；UI 自己会被挤）。
- 不做 action 的图标自定义（内置=固定 brand 图标；自定义=固定取首字母）。
- 不做"内置 action 隐藏"——内置 4 项始终显示在 Settings 列表中，只能开关 enabled，不能删除（避免误删后用户找不回）。
- 不为内置 action 的命令覆盖做"恢复默认按钮"（直接清空 command field 即视为恢复默认）。
- 不做 action 描述/tooltip 自定义（每个 action tooltip = 它的 name）。

## Architecture

```
[ContentView ZStack]
   ├─ HStack (sidebar + cards)
   ├─ sidebarToggleButton (top-leading, 已存在)
   └─ QuickActionsBar (top-trailing, 替代旧 gitTabButton)
            │
            ├─ HStack { ForEach(quickActionsStore.enabledActions) { action in
            │             IconButton { handle(action) } label: { iconView(action) }
            │          }}
            │
            └─ click → handle(action)
                       │
                       └─ WorkspaceStore.ensureQuickActionTab(id: action.id, in: wsId)
                                  │
                                  ├─ 已有 quickActionId == action.id 的 tab → selectTab + return (isNew: false)
                                  └─ 没有 → addTab(quickActionId: action.id) + 继承当前焦点 pane 的 pwd
                                             │
                                             └─ store 推送 → TabBridge → TabContentView.loadWorkspace
                                                        │
                                                        └─ buildSplitPane → terminalViewFor(id) → resolvedStartupCommand
                                                                    │
                                                                    └─ tab.quickActionId 非空 + 是首终端
                                                                        → 注入 quickActionsStore.command(for: id) + "\n"
```

数据 owner：

- **`QuickActionsStore`（@Observable，新）**
  - 持有 `enabledIds: [String]`（按显示顺序排），`builtinCommandOverrides: [String: String]`（per-id），`customActions: [CustomQuickAction]`。
  - 三个值都通过 `SettingsConfigStore` 持久化（与现有 settings 同源），用 JSON encode 存进 `mux0-quickactions-*` 三个 key。
  - 暴露派生读取方法：`enabledActions: [QuickAction]`（按 enabledIds 排序的可显示项）、`command(for id: String) -> String`（命令解析：内置 = override 或默认；自定义 = customActions 里那一条的 cmd）、`displayName(for id: String) -> String` / `iconSource(for id: String) -> QuickActionIcon`。
  - 注入到 `ContentView` 与 `TabContentView` 的 environment / 显式参数（与现有 `settingsStore` 一样的传法）。

- **`WorkspaceStore`（已有，重构）**
  - `addTab(to:quickActionId: String? = nil)` 替代 `addTab(to:kind:)`。
  - `ensureQuickActionTab(id:in:)` 替代 `ensureGitTab(in:)`，签名相同，多一个 id 形参。
  - tab title 由 `addTab` 调用方解析（QuickActionsStore.displayName），不在 store 内 hardcode "Git"。

- **`TerminalTab`（已有，重构）**
  - 把 `kind: TabKind?` 字段改成 `quickActionId: String?`。
  - `TabKind` enum 删除。
  - Codable 自动派生即可（`String?` 的 `decodeIfPresent` 内置）。
  - 不做向后兼容：旧 dev 数据中 `"kind":"git"` 的 tabs 在 decode 时会被丢弃成 `quickActionId == nil`（即普通 tab），可接受。

- **`TabBarView` / `TabContentView`（已有，仅替换字段名）**
  - `tab.kind == .git` 相关分支改成 `tab.quickActionId != nil` + 进一步用 store 查图标。
  - tab pill 的 leading icon 不再写死 `arrow.triangle.branch` vs `terminal`，改为：
    - `quickActionId == nil` → SF Symbol `terminal`（普通 terminal tab）
    - `quickActionId == "lazygit"` → SF Symbol `arrow.triangle.branch`
    - `quickActionId == "claude" / "codex" / "opencode"` → 对应 lobe SVG asset
    - `quickActionId == 自定义 id` → 首字母

- **`Settings/Sections/QuickActionsSectionView`（新）**
  - 新 Settings tab（`SettingsSection.quickActions`）。
  - 一个垂直可拖拽列表，所有 4 内置 + N 自定义混排，每行：drag handle + 图标 + name 字段（内置只读、自定义可编辑） + cmd 字段 + enabled toggle + 删除按钮（自定义独有）。
  - 列表底部 `+ Add Custom Action` 按钮。
  - Settings 中的 Shell section **删除** `mux0-git-viewer` 行（搬到 Quick Actions 内置 lazygit 行的 cmd 字段）。

## 数据模型

### TerminalTab 字段

```swift
struct TerminalTab: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var layout: SplitNode
    var focusedTerminalId: UUID
    var quickActionId: String? = nil  // 替代旧的 kind: TabKind?

    init(id: UUID = UUID(), title: String, terminalId: UUID = UUID(),
         quickActionId: String? = nil) { ... }
}
```

`TabKind` enum 整体删除。`addTab(to:quickActionId:)` 接收新参数；调用方决定 title。

### QuickAction 抽象（Models/QuickAction.swift，新文件）

```swift
/// 一个快捷操作的稳定 ID。内置用固定字符串（"lazygit" / "claude" / "codex" / "opencode"），
/// 自定义用 UUID().uuidString。
typealias QuickActionId = String

/// 内置快捷操作的注册表。所有内置 action 编译期固定，命令默认值 + 图标资源都在这里。
enum BuiltinQuickAction: String, CaseIterable, Identifiable {
    case lazygit
    case claude
    case codex
    case opencode

    var id: QuickActionId { rawValue }

    /// 默认命令——用户在 Settings 中可覆盖。
    var defaultCommand: String {
        switch self {
        case .lazygit:  return "lazygit"
        case .claude:   return "claude"
        case .codex:    return "codex"
        case .opencode: return "opencode"
        }
    }

    /// 显示名（i18n key），Settings 行标题 + 顶栏 tooltip 都用它。
    var displayName: LocalizedStringResource {
        switch self {
        case .lazygit:  return L10n.QuickActions.Builtin.lazygit
        case .claude:   return L10n.QuickActions.Builtin.claude
        case .codex:    return L10n.QuickActions.Builtin.codex
        case .opencode: return L10n.QuickActions.Builtin.opencode
        }
    }

    /// 图标来源——一个枚举，view 层把它映射到 SF Symbol 或 Asset Catalog 资源。
    var iconSource: QuickActionIcon {
        switch self {
        case .lazygit:  return .sfSymbol("arrow.triangle.branch")
        case .claude:   return .asset("quick-action-claudecode")
        case .codex:    return .asset("quick-action-codex")
        case .opencode: return .asset("quick-action-opencode")
        }
    }
}

/// 用户自定义的快捷操作条目。
struct CustomQuickAction: Codable, Identifiable, Equatable {
    let id: QuickActionId   // UUID().uuidString
    var name: String        // 自定义显示名
    var command: String     // shell 命令
    /// 注：enabled 不存在这里；启用状态由 QuickActionsStore.enabledIds 数组的成员关系决定，
    /// 这样内置和自定义共用同一份"启用与排序"机制。
}

/// 图标资源描述——view 层根据它选 SwiftUI Image 构造方式。
enum QuickActionIcon: Equatable {
    case sfSymbol(String)
    case asset(String)
    case letter(Character)  // 自定义 action 用：name 的首字符大写
}
```

### QuickActionsStore（@Observable，新文件）

```swift
@Observable
final class QuickActionsStore {
    /// 当前启用且按显示顺序排好的 action id 列表。这是右上角顶栏的渲染源。
    private(set) var enabledIds: [QuickActionId] = []

    /// 用户对内置 action 默认命令的覆盖，key = builtin id, value = 用户输入。
    /// value 为空字符串视为"恢复默认"，store 内部 normalize 为不存这条记录。
    private(set) var builtinCommandOverrides: [QuickActionId: String] = [:]

    /// 用户自定义 actions 列表（顺序无意义，排序由 enabledIds 决定）。
    private(set) var customActions: [CustomQuickAction] = []

    private let settings: SettingsConfigStore

    init(settings: SettingsConfigStore) { ... 读取三个 key 反序列化 ... }

    // MARK: - Read API

    /// 解析任意 id（内置或自定义）的命令。返回值是要塞进 ghostty initial_input 的命令本体（不含 \n）。
    /// 内置：override 非空 → override；否则 BuiltinQuickAction.defaultCommand。
    /// 自定义：customActions 中找到的 cmd（trim 后非空）；找不到或空则返回 nil。
    func command(for id: QuickActionId) -> String?

    /// 解析任意 id 的显示名。
    /// 内置：BuiltinQuickAction.displayName 本地化字符串。
    /// 自定义：customActions 中的 name（trim 后非空）；找不到/空则 fallback 到 id。
    func displayName(for id: QuickActionId, locale: Locale) -> String

    /// 解析图标资源。
    /// 内置：BuiltinQuickAction.iconSource。
    /// 自定义：.letter(name 首字符大写)。如果 name 为空，fallback "?"。
    func iconSource(for id: QuickActionId) -> QuickActionIcon

    /// 当前应该出现在右上角的、按 enabledIds 顺序排好的"可显示 action"列表。
    /// 过滤掉 enabledIds 里指向不存在的自定义 action 的脏 id（用户删了 custom 但 enabledIds 没及时清）。
    var displayList: [QuickActionId] { ... }

    /// 完整列表（用于 Settings UI 渲染）：所有 4 内置 + 所有 custom。
    /// 顺序 = enabledIds 顺序里出现的元素先排（保留排序），剩下未启用的内置追加在尾部，
    /// 然后未启用的 custom 追加在最后。Settings 用这个顺序展示并允许 onMove 重排。
    var fullList: [QuickActionId] { ... }

    /// id 是否启用。
    func isEnabled(_ id: QuickActionId) -> Bool

    // MARK: - Mutate API（每次 mutate 后写回 settings）

    func setEnabled(_ id: QuickActionId, _ enabled: Bool)
    func reorder(from source: IndexSet, to destination: Int)  // 在 fullList 维度重排，store 同步更新 enabledIds 顺序
    func setBuiltinCommand(_ id: QuickActionId, _ command: String)  // empty/whitespace → 删除 override

    func addCustomAction() -> QuickActionId       // 返回新 id；name/command 都是空，未启用
    func removeCustomAction(_ id: QuickActionId)  // 同时从 enabledIds 移除
    func updateCustomAction(_ id: QuickActionId, name: String? = nil, command: String? = nil)
}
```

### Storage keys（SettingsConfigStore）

| key                                        | 类型   | 内容                                                                  |
| ------------------------------------------ | ------ | --------------------------------------------------------------------- |
| `mux0-quickactions-enabled`                | JSON   | `["lazygit", "<custom-uuid>", "claude"]` —— 启用的 id 列表，顺序即显示顺序 |
| `mux0-quickactions-builtin-command-<id>`   | string | 内置命令覆盖；id ∈ {lazygit, claude, codex, opencode}；空字符串 = 删除 |
| `mux0-quickactions-custom`                 | JSON   | `[{"id":"...","name":"...","command":"..."}]`                         |

为什么 builtin command override 用 4 个 key 而不是 1 个 JSON：和 `SettingsConfigStore` 现有的 per-key debounce/reset 模式对齐，每个内置命令是独立设置项，单独 reset 行为更直观。

`SettingsConfigStore` 已有 `get(_:)/set(_:_:)`，QuickActionsStore 用同样接口，不绕过。settings.onChange callback 在 ContentView 里订阅；QuickActionsStore 也订阅这个 callback 来在外部编辑配置文件后重新加载（与 ThemeManager / Theme 一致）。

### 默认状态

首次启动（无任何 quickactions 相关 key）：
- `enabledIds = []`（空——按用户决定，全部关闭，符合 c 选项）
- `builtinCommandOverrides = [:]`
- `customActions = []`

→ 右上角无任何按钮。用户进 Settings → Quick Actions → 勾选启用 → 按钮出现。

## UI 变更

### 顶栏 QuickActionsBar

替换 `ContentView` 中的 `gitTabButton`。

布局：右上角 HStack，从右往左的顺序对应 `quickActionsStore.displayList` 从前往后（即 list 第一个元素显示在最右边）。

理由：现有 `gitTabButton` 用 `.frame(maxWidth: .infinity, alignment: .topTrailing)` 贴右上角；如果新增按钮往左侧扩，第一个/最常用的按钮被推走。改为 list 第一个元素最右更自然——用户可拖拽把最常用的拖到顶部。

每个按钮：
- 复用现有 `IconButton` 控件（22pt 方形、hover/pressed 走 theme token）。
- icon 内容：根据 `quickActionsStore.iconSource(for: id)` 渲染。
  - `.sfSymbol(name)`: `Image(systemName: name)`。
  - `.asset(name)`: `Image(name).renderingMode(.template)`。
  - `.letter(c)`: `Text(String(c)).font(.system(size: 12, weight: .semibold, design: .rounded))`。
- tint: `theme.textSecondary`（与现有 sidebarToggleButton / 旧 gitTabButton 一致）。
- tooltip: `quickActionsStore.displayName(for: id, locale: locale)`。
- click: `store.ensureQuickActionTab(id: id, in: wsId)` + 必要时 pwd 继承 + selectTab。

`disabled` 条件：`store.selectedId == nil`。

如果 `displayList` 为空，整个 bar 不渲染（不占位）。

### Settings → Quick Actions 新 section

`SettingsSection.quickActions` 加在 `.shell` 之后、`.agents` 之前（视觉上"shell" → "shell 上跑的快捷操作" → "agent 状态钩子"是自然递进）。

Tab icon (SettingsTabBarView): SF Symbol `bolt`。
Tab label: `L10n.Settings.sectionQuickActions`（`Settings.section.quickActions`）—— "快捷操作" / "Quick Actions"。

`QuickActionsSectionView` 布局：

```
Form {
    Section("启用与排序") {
        // 顶部说明文字（footer 形式或独立 Text）
        Text("启用的按钮会按下方顺序出现在窗口右上角。可拖拽调整顺序。")
            .style(textTertiary, DT.Font.small)

        // 列表本体——用 SwiftUI List 而非 ForEach，方便用 onMove
        List {
            ForEach(quickActionsStore.fullList, id: \.self) { id in
                QuickActionRowView(id: id, store: quickActionsStore, theme: theme, settings: settings)
            }
            .onMove { src, dst in quickActionsStore.reorder(from: src, to: dst) }
        }
    }

    Section {
        Button { quickActionsStore.addCustomAction() } label: {
            Label("新建自定义快捷操作", systemImage: "plus.circle")
        }
    }

    SettingsResetRow(settings: settings, keys: managedKeys)
}
```

`QuickActionRowView`（每行）：

```
HStack {
    // 拖拽 handle —— SwiftUI List 在 macOS 默认会渲染（无需 editMode）
    QuickActionIconView(source: store.iconSource(for: id), size: 16)  // 16pt 视觉

    if isBuiltin(id) {
        Text(store.displayName(for: id, locale: locale))
            .frame(width: 100, alignment: .leading)
    } else {
        TextField("名称", text: customNameBinding(id))  // 直接编辑 customAction.name
            .frame(width: 100)
    }

    TextField(builtinDefaultCommand(id) ?? "命令", text: commandBinding(id))
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: .infinity)

    Toggle("", isOn: enabledBinding(id))
        .toggleStyle(.switch)
        .labelsHidden()

    if !isBuiltin(id) {
        Button(role: .destructive) { store.removeCustomAction(id) } label: {
            Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
    }
}
```

行内绑定细节：
- `commandBinding(id)`：内置 = `Binding(get: store.builtinCommandOverrides[id] ?? "", set: store.setBuiltinCommand(id, _))`；自定义 = `store.customActions.first(where:.id == id)?.command`。
- `enabledBinding(id)`：`Binding(get: store.isEnabled(id), set: store.setEnabled(id, _))`。
- `customNameBinding(id)`：自定义专用，写入触发 `store.updateCustomAction(id, name: ...)`。
- 命令字段空白时，placeholder 是该内置的 `defaultCommand`（让用户清晰看到"清空 = 走默认 lazygit"）；自定义占位符是固定字面量"命令"。

### Shell section 改动

删除 ShellSectionView 中 `mux0-git-viewer` 的 `Section { BoundTextField } footer { ... }` 整段（约 18 行）。`managedKeys` 列表去掉 `"mux0-git-viewer"`。

`L10n.Settings.Shell.gitViewerLabel/Help/InstallHint` 三个 key 整体删除（不需要保留向后兼容）。

新 i18n keys 在 `L10n.QuickActions.*` 命名空间下。

## i18n keys 清单

新增（English source 为准；zh-Hans 同步）：

| key                                              | en                                                    | zh-Hans                          |
| ------------------------------------------------ | ----------------------------------------------------- | -------------------------------- |
| `settings.section.quickActions`                  | Quick Actions                                          | 快捷操作                          |
| `settings.quickActions.heading`                  | Enabled & Order                                       | 启用与排序                        |
| `settings.quickActions.headingFooter`            | Enabled buttons appear in the top-right corner of the window. Drag to reorder. | 启用的按钮会按下方顺序出现在窗口右上角，可拖拽排序。 |
| `settings.quickActions.addCustomButton`          | Add Custom Action                                      | 新建自定义快捷操作                 |
| `settings.quickActions.customNamePlaceholder`    | Name                                                   | 名称                              |
| `settings.quickActions.customCommandPlaceholder` | Command                                                | 命令                              |
| `quickActions.builtin.lazygit`                   | Lazygit                                                | Lazygit                           |
| `quickActions.builtin.claude`                    | Claude Code                                            | Claude Code                       |
| `quickActions.builtin.codex`                     | Codex                                                  | Codex                             |
| `quickActions.builtin.opencode`                  | opencode                                               | opencode                          |

删除：
- `topbar.gitButton.tooltip`（被 per-action displayName 替代，不再需要单独 tooltip key）
- `settings.shell.gitViewer.label`
- `settings.shell.gitViewer.help`
- `settings.shell.gitViewer.installHint`

## 资源文件

`mux0/Assets.xcassets/` 下新增 3 个 imageset，每个含一个 SVG（从 lobe-icons 拷入）+ Contents.json：

```
mux0/Assets.xcassets/quick-action-claudecode.imageset/
    Contents.json
    claudecode.svg          # 来源: https://raw.githubusercontent.com/lobehub/lobe-icons/refs/heads/master/packages/static-svg/icons/claudecode.svg
mux0/Assets.xcassets/quick-action-codex.imageset/
    Contents.json
    codex.svg               # 同上 codex.svg
mux0/Assets.xcassets/quick-action-opencode.imageset/
    Contents.json
    opencode.svg            # 同上 opencode.svg
```

每个 `Contents.json`：

```json
{
  "images" : [
    { "idiom" : "universal", "filename" : "<svg-name>.svg" }
  ],
  "info" : { "author" : "xcode", "version" : 1 },
  "properties" : {
    "preserves-vector-representation" : true,
    "template-rendering-intent" : "template"
  }
}
```

`template-rendering-intent: template` 让 `Image(name).renderingMode(.template).foregroundColor(...)` 按 SF Symbol 一样的方式 tint，跟随 theme token 切换深浅色。

不需要改 `project.yml`：现有 `sources: - path: mux0` 已经把整个 `Assets.xcassets` 收进来。

注意：lobe-icons 没有 `lazygit` / `git` 的 logo，所以 lazygit 的图标继续用 SF Symbol `arrow.triangle.branch`（与现状 git tab 完全一致）。

## 文件结构变更

### 新增

```
mux0/Models/QuickAction.swift                              # BuiltinQuickAction + CustomQuickAction + QuickActionIcon
mux0/Models/QuickActionsStore.swift                        # @Observable store
mux0/Settings/Sections/QuickActionsSectionView.swift       # Settings tab body
mux0/Settings/Components/QuickActionRowView.swift          # 单行
mux0/Settings/Components/QuickActionIconView.swift         # icon 渲染（SF Symbol / Asset / 首字母）
mux0/Assets.xcassets/quick-action-claudecode.imageset/{Contents.json, claudecode.svg}
mux0/Assets.xcassets/quick-action-codex.imageset/{Contents.json, codex.svg}
mux0/Assets.xcassets/quick-action-opencode.imageset/{Contents.json, opencode.svg}
mux0Tests/QuickActionTests.swift                           # BuiltinQuickAction + CustomQuickAction Codable
mux0Tests/QuickActionsStoreTests.swift                     # store mutate API 全覆盖
docs/superpowers/specs/2026-04-30-quick-actions.md         # 本文件
docs/superpowers/plans/2026-04-30-quick-actions.md         # 实施计划
```

### 修改

```
mux0/Models/Workspace.swift                # 删 TabKind，TerminalTab.kind → quickActionId
mux0/Models/WorkspaceStore.swift           # addTab(quickActionId:) + ensureQuickActionTab(id:in:)
mux0/TabContent/TabContentView.swift       # resolvedStartupCommand 用 quickActionsStore.command(for:)
mux0/TabContent/TabBarView.swift           # tab pill icon 取 quickActionsStore.iconSource(for:)
mux0/Settings/SettingsSection.swift        # 加 .quickActions case
mux0/Settings/SettingsTabBarView.swift     # quickActions tab icon
mux0/Settings/SettingsView.swift           # quickActions case 渲染
mux0/Settings/Sections/ShellSectionView.swift   # 删 mux0-git-viewer 字段
mux0/ContentView.swift                     # gitTabButton → QuickActionsBar
mux0/Localization/Localizable.xcstrings    # 加新 key、删旧 key
mux0/Localization/L10n.swift               # 加 QuickActions 命名空间、删 Topbar.gitButtonTooltip / Settings.Shell.gitViewer*
mux0Tests/WorkspaceStoreTests.swift        # ensureGitTab → ensureQuickActionTab、TabKind → quickActionId
mux0Tests/L10nSmokeTests.swift             # allKeys 同步
docs/architecture.md                       # Git Tab section → Quick Actions section
docs/settings-reference.md                 # mux0-git-viewer 删除，加 mux0-quickactions-* 三个 key
CLAUDE.md                                  # 把 Common Tasks 的"增加新的 tab 类型"行 → "增加新的内置 quick action"
```

### 删除（直接删整段、整 key、整字段；无兼容层）

```
TabKind enum (Workspace.swift)
TerminalTab.kind 字段
WorkspaceStore.ensureGitTab
ContentView.gitTabButton
ShellSectionView 中 mux0-git-viewer Section
i18n: topbar.gitButton.tooltip
i18n: settings.shell.gitViewer.label / help / installHint
L10n.Topbar 命名空间（如果只有 gitButtonTooltip 一个 key 用过）
L10n.Settings.Shell.gitViewerLabel / Help / InstallHint
```

## 交互流（关键路径）

### 启用一个内置 action（例如 lazygit）

1. 用户：Settings → Quick Actions → Lazygit 行 → 切 Toggle 到 ON。
2. `QuickActionRowView.enabledBinding.set(true)` → `quickActionsStore.setEnabled("lazygit", true)`。
3. Store: `enabledIds.append("lazygit")` if not present，写 `mux0-quickactions-enabled` JSON。
4. SettingsConfigStore.onChange 触发 → ContentView 体感不需要做任何事（QuickActionsStore 是 @Observable，`enabledIds` 变化自动 propagate）。
5. 顶栏 `QuickActionsBar` ForEach 重新计算，新增一个 IconButton。

### 点击顶栏 lazygit 按钮

1. `IconButton.action` → `store.ensureQuickActionTab(id: "lazygit", in: wsId)`。
2. WorkspaceStore: capture sourcePwdTerminalId（前一个 selected tab 的 focusedTerminalId）。
3. 找 `tab.quickActionId == "lazygit"`：有则 selectTab + return (isNew: false)；没有则 `addTab(quickActionId: "lazygit")` + 用 `quickActionsStore.displayName("lazygit", locale)` 解析的 title。
4. 如果 isNew：调用方调 `pwdStore.inherit(from: prev, to: result.terminalId)`。
5. SwiftUI propagate → TabBridge → TabContentView.loadWorkspace → buildSplitPane → terminalViewFor(terminalId) → resolvedStartupCommand。
6. resolvedStartupCommand 检测 `tab.quickActionId == "lazygit"` + 是首终端 → 注入 `quickActionsStore.command(for: "lazygit") ?? "lazygit"` + "\n"。
7. ghostty surface 启动 → shell 自动跑 lazygit。

### 添加自定义 action

1. 用户：Settings → Quick Actions → "+ 新建自定义快捷操作" → `quickActionsStore.addCustomAction()`。
2. Store: 生成 UUID().uuidString 作为新 id，append 一条 `CustomQuickAction(id: ..., name: "", command: "")` 到 `customActions`。enabledIds 不变。
3. UI：fullList 重新计算 → 新行出现在列表底部，name/command 字段都是空白可编辑。
4. 用户输入 name = "htop", command = "htop"，切 Toggle 到 ON。
5. Store: 三次 mutation 分别更新 customActions、enabledIds、写盘。
6. 顶栏出现新按钮，icon = `letter('H')`（首字符大写）。

### 拖拽排序

1. 用户：Settings → Quick Actions → 在 List 上把第三行拖到第一行位置。
2. SwiftUI List `.onMove(perform: { src, dst in store.reorder(from: src, to: dst) })`。
3. Store.reorder：在 fullList 维度计算 destination 索引，然后把 enabledIds 里出现的元素按新顺序排列；未启用的元素不影响 enabledIds（顺序仅在启用集内有意义）。
4. 写 `mux0-quickactions-enabled` JSON。
5. 顶栏 ForEach(displayList) 重新计算 → 按钮顺序更新。

### 删除自定义 action

1. 用户：Settings → Quick Actions → 自定义行 → 点垃圾桶。
2. `quickActionsStore.removeCustomAction(id)`。
3. Store: 从 customActions 删；从 enabledIds 删（如果在）；写 2 个 key。
4. 现有 workspaces 中如果还有 `tab.quickActionId == 那个 id` 的 tabs：保持不动，tab 名字不变，下次该 tab 重启时 `command(for: id)` 返回 nil → tab 行为退化成普通 terminal（不注入命令，shell 直接进入交互），完全可接受。
5. 顶栏对应按钮消失。

## 测试策略

### Unit tests

`QuickActionTests`:
- `BuiltinQuickAction.allCases.count == 4`，每个 id 独特。
- `BuiltinQuickAction(rawValue:)` 对内置 id 字符串往返。
- `CustomQuickAction` JSON encode/decode 往返保留 id/name/command。

`QuickActionsStoreTests`（每个 case 用全新的内存 SettingsConfigStore 实例隔离）：
- 默认状态：enabledIds/builtinCommandOverrides/customActions 都为空。
- `setEnabled("lazygit", true)` 后 isEnabled 为 true、displayList 含 lazygit。
- `setEnabled` 重复 ON 幂等不重复 append。
- `setBuiltinCommand("lazygit", "gitui")` 后 command(for: lazygit) 返回 gitui；setBuiltinCommand 空字符串后回到默认 "lazygit"。
- `addCustomAction` 返回的 id 出现在 customActions 中，name/command 都空。
- `updateCustomAction` 改 name 后 customActions 中的对象同步。
- `removeCustomAction` 同时从 customActions 和 enabledIds 移除。
- `reorder` 改变 displayList 顺序。
- 持久化：mutate 后用同 settingsConfig 重建 store，状态完全一致。
- 脏 enabledIds（指向已删 custom）被 displayList 自动过滤但不被 mutate API 自动清理（避免静默丢数据）。

`WorkspaceStoreTests`（替换原 ensureGitTab 测试）：
- `addTab(to:quickActionId: "lazygit")` 创建的 tab.quickActionId 为 "lazygit"。
- `ensureQuickActionTab(id: "lazygit", in:)` 第一次 isNew=true，第二次 isNew=false 且 tabId 一致。
- 不同 id 的 ensure 独立查找：先 ensure lazygit 再 ensure claude，两个不同 tab。
- sourcePwdTerminalId 在已存在 tab 时仍然返回前一个 selected tab 的 focusedTerminalId。
- TerminalTab Codable 往返 quickActionId。

`L10nSmokeTests`:
- allKeys 数组同步加新 key、删旧 key；遍历断言每个 key 在 zh-Hans 都有非空翻译。

### 编译验证（每个任务后）

`xcodebuild -project mux0.xcodeproj -scheme mux0 -configuration Debug build` 必须通过。

### 整合验证（最后）

- `xcodebuild test -project mux0.xcodeproj -scheme mux0Tests` 全过（保留原 237 个 + 新增）。
- `./scripts/check-doc-drift.sh` 通过（新文件已加入 Directory Structure）。
- 人工：build 后由用户手动 launch 验证 — 启用 1 内置 + 1 自定义 → 顶栏出现两按钮 → 拖拽排序 → 点击各创建对应 tab 跑命令 → 重启后状态恢复。

## Rejected alternatives

**A. 保留 TabKind enum，扩成 .git / .claude / .codex / .opencode / .custom(String)**
关联值的 enum Codable 实现复杂（要写自定义 init/encode），且为内置项编译期 case → 添加新内置必改 enum 反而比 String id 不好扩展。否决。

**B. 把 enabled、order 都存进 customActions，内置另存 enabled set + order set**
复杂度翻倍：order 要在两个集合之间跨界排序，又要避免 enabled 状态飘移。当前设计用单一的 `enabledIds: [String]` 数组同时承载启用集 + 启用顺序，简洁。否决。

**C. 不做拖拽排序，固定"内置在前、自定义按创建顺序"**
用户明确要"可以排序"，否决。

**D. 内置可隐藏（从 Settings 列表删除）**
用户明确要"内置都不能删除"，否决。如果用户不想看到某个内置，关 toggle 即可。

**E. 命令字段允许多行 / shell pipeline 编辑器**
本项目现有 `mux0-git-viewer` 已经是单行 BoundTextField，足以支持 `lazygit -p $PWD` 这种参数化用法。多行 / 复杂编辑器是 YAGNI。否决。

**F. 给自定义 action 提供"图标选择器"（任意 SF Symbol 或图片）**
"首字母" 简洁、零交互、不需要资源管理；如果之后真的需要再加。当前否决。

**G. 顶栏按钮失败时显示红点（lazygit not found 之类）**
检测复杂、维护负担重；ghostty surface 自身的 stderr 已经把"lazygit: command not found"显示给用户。否决。

**H. 顶栏按钮支持⌘-数字快捷键**
未提需求，目前不做。预留：未来可以在 menu 里加（不需要改快捷键基础设施）。

**I. 内置 action 提供"恢复默认命令"按钮**
用户清空命令字段即视为恢复默认，多余的 reset 按钮反而增加 UI 噪声。整个 Quick Actions Settings 已有 SettingsResetRow 一键全清，足够。否决。

## 与 git-tab spec 的关系

`docs/superpowers/specs/2026-04-30-git-tab-design.md` 是当前 `agent/git-tab` 分支的设计文档。本 spec **取代**它：实现完成后该文件可以删除（或留着作为历史 reference，文件名带日期就是为了这种情况）。`docs/superpowers/plans/2026-04-30-git-tab.md` 同理。

实施时不主动删除旧 spec/plan——保留历史；新工作以本 spec 为准。
