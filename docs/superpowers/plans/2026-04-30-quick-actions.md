# Quick Actions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把未发布的 git tab 功能重构为通用 Quick Actions：内置 4 个 CLI（lazygit/claude/codex/opencode） + 用户自定义条目，每条独立启用/可改命令/可拖拽排序，启用按钮按用户排序显示在窗口右上角。

**Architecture:** 引入 `QuickActionsStore`（@Observable，由 SettingsConfigStore 持久化）作为 enabled list / 命令覆盖 / 自定义条目的单一真理源。`TerminalTab.kind: TabKind?` 改成 `quickActionId: String?`，TabKind enum 删除。新增 Settings 「Quick Actions」section 提供编辑 UI。`gitTabButton` 替换为 `QuickActionsBar`（HStack 渲染 displayList）。

**Tech Stack:** Swift 5 + AppKit + SwiftUI 混合，@Observable 状态层；SwiftUI Form/List/.onMove 实现拖拽；Asset Catalog SVG 资源（template-rendering）承载 lobe-icons brand 图标；XCTest 单元测试。

---

## File Structure（新增 / 修改 / 删除）

### 新增
- `mux0/Models/QuickAction.swift` — `QuickActionId` typealias、`BuiltinQuickAction` enum、`CustomQuickAction` struct、`QuickActionIcon` enum
- `mux0/Models/QuickActionsStore.swift` — `@Observable` store，封装 enabled / overrides / custom 三块状态 + 持久化
- `mux0/Settings/Components/QuickActionIconView.swift` — 渲染 `.sfSymbol` / `.asset` / `.letter` 三种图标的 SwiftUI View
- `mux0/Settings/Components/QuickActionRowView.swift` — 单行（drag handle、icon、name、cmd、enabled toggle、delete）
- `mux0/Settings/Sections/QuickActionsSectionView.swift` — Settings tab 内容
- `mux0/Assets.xcassets/quick-action-claudecode.imageset/{Contents.json, claudecode.svg}`
- `mux0/Assets.xcassets/quick-action-codex.imageset/{Contents.json, codex.svg}`
- `mux0/Assets.xcassets/quick-action-opencode.imageset/{Contents.json, opencode.svg}`
- `mux0Tests/QuickActionTests.swift` — `BuiltinQuickAction` + `CustomQuickAction` 基础断言
- `mux0Tests/QuickActionsStoreTests.swift` — store mutate/persist 全覆盖

### 修改
- `mux0/Models/Workspace.swift` — `TabKind` enum 删除，`TerminalTab.kind` → `quickActionId: String?`
- `mux0/Models/WorkspaceStore.swift` — `addTab(to:kind:)` → `addTab(to:quickActionId:)`，`ensureGitTab` → `ensureQuickActionTab(id:in:)`，title 由调用方传入
- `mux0/TabContent/TabContentView.swift` — `resolvedStartupCommand` 用 `QuickActionsStore.command(for:)` 替代 `mux0-git-viewer` 设置查找；`tab.kind == .git` → `tab.quickActionId != nil`
- `mux0/TabContent/TabBarView.swift` — `applyKindImage` 用 `QuickActionsStore.iconSource(for:)` 替代写死的 `arrow.triangle.branch`/`terminal` 二选一
- `mux0/TabContent/TabContentView.swift` 桥接 — `TabBridge` / `TabContentView` 加 `quickActionsStore` 参数透传到 `TabBarView`
- `mux0/Settings/SettingsSection.swift` — 加 `case quickActions`
- `mux0/Settings/SettingsTabBarView.swift` — quickActions tab icon (`bolt`)
- `mux0/Settings/SettingsView.swift` — quickActions case 渲染 `QuickActionsSectionView`
- `mux0/Settings/Sections/ShellSectionView.swift` — 删 `mux0-git-viewer` BoundTextField Section
- `mux0/ContentView.swift` — `gitTabButton` 替换为 `QuickActionsBar`，并把 `quickActionsStore` 注入到 TabBridge / SettingsView
- `mux0/Localization/Localizable.xcstrings` — 加 11 个 key、删 5 个 key
- `mux0/Localization/L10n.swift` — 加 `QuickActions` 命名空间 + `Settings.sectionQuickActions`，删 `Topbar.gitButtonTooltip` / `Settings.Shell.gitViewer*`
- `mux0Tests/WorkspaceStoreTests.swift` — `ensureGitTab` 测试改成 `ensureQuickActionTab`，`TabKind` 测试改成 `quickActionId`
- `mux0Tests/L10nSmokeTests.swift` — `allKeys` 同步
- `docs/architecture.md` — Git Tab subsection 改成 Quick Actions subsection
- `docs/settings-reference.md` — 删 `mux0-git-viewer`，加 3 个 `mux0-quickactions-*` key 说明
- `CLAUDE.md` — Common Tasks 「增加新的 tab 类型」行替换成「增加内置/自定义 quick action」；Directory Structure 加 4 个新文件

### 删除（直接删除整段/整 key）
- `Workspace.swift` 中的 `enum TabKind`
- `WorkspaceStore.ensureGitTab(in:)`（被 `ensureQuickActionTab` 替代）
- `ContentView.gitTabButton`（被 `QuickActionsBar` 替代）
- `ShellSectionView` 中的 `mux0-git-viewer` Section（约 18 行）
- `Localizable.xcstrings`：`topbar.gitButton.tooltip`、`settings.shell.gitViewer.label`、`settings.shell.gitViewer.help`、`settings.shell.gitViewer.installHint`
- `L10n.swift`：`Topbar` 命名空间（如果只剩 gitButtonTooltip）、`Settings.Shell.gitViewer*` 三个常量

旧 spec/plan（`docs/superpowers/specs/2026-04-30-git-tab-design.md`、`docs/superpowers/plans/2026-04-30-git-tab.md`）保留作为历史记录，不删。

---

## Task 1: 引入 QuickAction 模型与 Store

**Files:**
- Create: `mux0/Models/QuickAction.swift`
- Create: `mux0/Models/QuickActionsStore.swift`
- Test: `mux0Tests/QuickActionTests.swift`
- Test: `mux0Tests/QuickActionsStoreTests.swift`

本任务**纯新增代码**，不改任何现有文件。Build 必须仍能过。

- [ ] **Step 1: 写失败测试 — `QuickActionTests.swift`**

```swift
import XCTest
@testable import mux0

final class QuickActionTests: XCTestCase {
    func test_builtinAllCases_haveFourEntries() {
        XCTAssertEqual(BuiltinQuickAction.allCases.count, 4)
        XCTAssertEqual(Set(BuiltinQuickAction.allCases.map(\.id)),
                       Set(["lazygit", "claude", "codex", "opencode"]))
    }

    func test_builtinDefaultCommands_matchId() {
        XCTAssertEqual(BuiltinQuickAction.lazygit.defaultCommand, "lazygit")
        XCTAssertEqual(BuiltinQuickAction.claude.defaultCommand, "claude")
        XCTAssertEqual(BuiltinQuickAction.codex.defaultCommand, "codex")
        XCTAssertEqual(BuiltinQuickAction.opencode.defaultCommand, "opencode")
    }

    func test_customAction_codableRoundTrip() throws {
        let original = CustomQuickAction(id: "abc-123", name: "htop", command: "htop -H")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CustomQuickAction.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func test_quickActionIcon_sfSymbolForLazygit() {
        guard case .sfSymbol(let name) = BuiltinQuickAction.lazygit.iconSource else {
            XCTFail("lazygit should be sfSymbol"); return
        }
        XCTAssertEqual(name, "arrow.triangle.branch")
    }

    func test_quickActionIcon_assetForClaude() {
        guard case .asset(let name) = BuiltinQuickAction.claude.iconSource else {
            XCTFail("claude should be asset"); return
        }
        XCTAssertEqual(name, "quick-action-claudecode")
    }
}
```

Run: `xcodebuild test -project mux0.xcodeproj -scheme mux0Tests -only-testing:mux0Tests/QuickActionTests`
Expected: FAIL — types not defined yet.

- [ ] **Step 2: 实现 `QuickAction.swift`**

```swift
import Foundation

typealias QuickActionId = String

enum BuiltinQuickAction: String, CaseIterable, Identifiable {
    case lazygit
    case claude
    case codex
    case opencode

    var id: QuickActionId { rawValue }

    var defaultCommand: String {
        switch self {
        case .lazygit:  return "lazygit"
        case .claude:   return "claude"
        case .codex:    return "codex"
        case .opencode: return "opencode"
        }
    }

    var displayName: LocalizedStringResource {
        switch self {
        case .lazygit:  return L10n.QuickActions.Builtin.lazygit
        case .claude:   return L10n.QuickActions.Builtin.claude
        case .codex:    return L10n.QuickActions.Builtin.codex
        case .opencode: return L10n.QuickActions.Builtin.opencode
        }
    }

    var iconSource: QuickActionIcon {
        switch self {
        case .lazygit:  return .sfSymbol("arrow.triangle.branch")
        case .claude:   return .asset("quick-action-claudecode")
        case .codex:    return .asset("quick-action-codex")
        case .opencode: return .asset("quick-action-opencode")
        }
    }

    static func from(id: QuickActionId) -> BuiltinQuickAction? {
        BuiltinQuickAction(rawValue: id)
    }
}

struct CustomQuickAction: Codable, Identifiable, Equatable {
    let id: QuickActionId
    var name: String
    var command: String
}

enum QuickActionIcon: Equatable {
    case sfSymbol(String)
    case asset(String)
    case letter(Character)
}
```

注意：`BuiltinQuickAction.displayName` 引用了 `L10n.QuickActions.Builtin.*`——这些 key 在 Task 4 里加；先在 `L10n.swift` 加桩子（`QuickActions` enum + 4 个内置 key）即可让本任务编译过。在 Step 4 一并加。

- [ ] **Step 3: 写失败测试 — `QuickActionsStoreTests.swift`**

```swift
import XCTest
@testable import mux0

final class QuickActionsStoreTests: XCTestCase {
    /// 每个测试用独立 UserDefaults suite，避免 settings key 串扰。
    private func makeIsolatedStore() -> (QuickActionsStore, SettingsConfigStore) {
        let suite = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = SettingsConfigStore(defaults: defaults)
        let store = QuickActionsStore(settings: settings)
        return (store, settings)
    }

    func test_defaultState_allEmpty() {
        let (store, _) = makeIsolatedStore()
        XCTAssertTrue(store.enabledIds.isEmpty)
        XCTAssertTrue(store.builtinCommandOverrides.isEmpty)
        XCTAssertTrue(store.customActions.isEmpty)
        XCTAssertTrue(store.displayList.isEmpty)
    }

    func test_setEnabled_appendsAndPersists() {
        let (store, settings) = makeIsolatedStore()
        store.setEnabled("lazygit", true)
        XCTAssertEqual(store.enabledIds, ["lazygit"])
        XCTAssertTrue(store.isEnabled("lazygit"))

        // 重建 store → 状态应恢复
        let store2 = QuickActionsStore(settings: settings)
        XCTAssertEqual(store2.enabledIds, ["lazygit"])
    }

    func test_setEnabled_idempotent() {
        let (store, _) = makeIsolatedStore()
        store.setEnabled("lazygit", true)
        store.setEnabled("lazygit", true)
        XCTAssertEqual(store.enabledIds, ["lazygit"])
    }

    func test_setEnabled_offRemoves() {
        let (store, _) = makeIsolatedStore()
        store.setEnabled("lazygit", true)
        store.setEnabled("claude", true)
        store.setEnabled("lazygit", false)
        XCTAssertEqual(store.enabledIds, ["claude"])
    }

    func test_command_builtinDefault() {
        let (store, _) = makeIsolatedStore()
        XCTAssertEqual(store.command(for: "lazygit"), "lazygit")
        XCTAssertEqual(store.command(for: "claude"), "claude")
    }

    func test_command_builtinOverride() {
        let (store, _) = makeIsolatedStore()
        store.setBuiltinCommand("lazygit", "gitui")
        XCTAssertEqual(store.command(for: "lazygit"), "gitui")
    }

    func test_command_builtinEmptyOverrideFallsBackToDefault() {
        let (store, _) = makeIsolatedStore()
        store.setBuiltinCommand("lazygit", "gitui")
        store.setBuiltinCommand("lazygit", "")  // clear override
        XCTAssertEqual(store.command(for: "lazygit"), "lazygit")
        XCTAssertNil(store.builtinCommandOverrides["lazygit"])  // normalize
    }

    func test_command_unknownIdReturnsNil() {
        let (store, _) = makeIsolatedStore()
        XCTAssertNil(store.command(for: "no-such-id"))
    }

    func test_addCustomAction_appendsEmpty() {
        let (store, _) = makeIsolatedStore()
        let newId = store.addCustomAction()
        XCTAssertEqual(store.customActions.count, 1)
        XCTAssertEqual(store.customActions.first?.id, newId)
        XCTAssertEqual(store.customActions.first?.name, "")
        XCTAssertEqual(store.customActions.first?.command, "")
        XCTAssertFalse(store.isEnabled(newId))
    }

    func test_updateCustomAction_changesNameAndCommand() {
        let (store, _) = makeIsolatedStore()
        let id = store.addCustomAction()
        store.updateCustomAction(id, name: "htop", command: "htop -H")
        XCTAssertEqual(store.customActions.first?.name, "htop")
        XCTAssertEqual(store.customActions.first?.command, "htop -H")
        XCTAssertEqual(store.command(for: id), "htop -H")
    }

    func test_removeCustomAction_alsoUnenables() {
        let (store, _) = makeIsolatedStore()
        let id = store.addCustomAction()
        store.updateCustomAction(id, name: "htop", command: "htop")
        store.setEnabled(id, true)
        store.removeCustomAction(id)
        XCTAssertTrue(store.customActions.isEmpty)
        XCTAssertFalse(store.isEnabled(id))
    }

    func test_displayList_filtersOrphanCustomIds() {
        let (store, settings) = makeIsolatedStore()
        // 直接写入脏的 enabledIds 模拟"删了 custom 但 enabledIds 没清"的容错路径
        let orphan = "orphan-uuid"
        let json = try! JSONEncoder().encode([orphan])
        settings.set("mux0-quickactions-enabled", String(data: json, encoding: .utf8))
        let store2 = QuickActionsStore(settings: settings)
        XCTAssertEqual(store2.enabledIds, [orphan])  // 原样保留——不静默清
        XCTAssertTrue(store2.displayList.isEmpty)     // 但 displayList 过滤掉
    }

    func test_iconSource_letterForCustom() {
        let (store, _) = makeIsolatedStore()
        let id = store.addCustomAction()
        store.updateCustomAction(id, name: "htop")
        guard case .letter(let c) = store.iconSource(for: id) else {
            XCTFail("custom should be letter"); return
        }
        XCTAssertEqual(c, "H")
    }

    func test_iconSource_letterFallbackForEmptyName() {
        let (store, _) = makeIsolatedStore()
        let id = store.addCustomAction()
        guard case .letter(let c) = store.iconSource(for: id) else {
            XCTFail("custom should be letter"); return
        }
        XCTAssertEqual(c, "?")
    }

    func test_reorder_movesEnabledIds() {
        let (store, _) = makeIsolatedStore()
        store.setEnabled("lazygit", true)
        store.setEnabled("claude", true)
        store.setEnabled("codex", true)
        // displayList = [lazygit, claude, codex]；把 codex 移到首
        let indexInDisplay = store.displayList.firstIndex(of: "codex")!
        store.reorderDisplay(from: IndexSet([indexInDisplay]), to: 0)
        XCTAssertEqual(store.displayList.first, "codex")
    }
}
```

Run: `xcodebuild test -project mux0.xcodeproj -scheme mux0Tests -only-testing:mux0Tests/QuickActionsStoreTests`
Expected: FAIL — `QuickActionsStore` not defined and `SettingsConfigStore` 不接受 `defaults:` 参数（如果当前 init 不支持，需要在 store 实现中扩展或者用 swizzle；下一步实现）。

- [ ] **Step 4: 实现 `QuickActionsStore.swift` + L10n 桩子**

先在 `mux0/Localization/L10n.swift` 加：

```swift
extension L10n {
    enum QuickActions {
        enum Builtin {
            static let lazygit  = LocalizedStringResource("quickActions.builtin.lazygit")
            static let claude   = LocalizedStringResource("quickActions.builtin.claude")
            static let codex    = LocalizedStringResource("quickActions.builtin.codex")
            static let opencode = LocalizedStringResource("quickActions.builtin.opencode")
        }
    }
}
```

并在 `Localizable.xcstrings` 加四条记录：

| key                              | en           | zh-Hans       |
| -------------------------------- | ------------ | ------------- |
| `quickActions.builtin.lazygit`   | Lazygit      | Lazygit       |
| `quickActions.builtin.claude`    | Claude Code  | Claude Code   |
| `quickActions.builtin.codex`     | Codex        | Codex         |
| `quickActions.builtin.opencode`  | opencode     | opencode      |

然后实现 store：

```swift
import Foundation
import Observation

@Observable
final class QuickActionsStore {
    private(set) var enabledIds: [QuickActionId] = []
    private(set) var builtinCommandOverrides: [QuickActionId: String] = [:]
    private(set) var customActions: [CustomQuickAction] = []

    private let settings: SettingsConfigStore

    private static let kEnabled = "mux0-quickactions-enabled"
    private static let kCustom  = "mux0-quickactions-custom"
    private static func kBuiltinCmd(_ id: QuickActionId) -> String {
        "mux0-quickactions-builtin-command-\(id)"
    }

    init(settings: SettingsConfigStore) {
        self.settings = settings
        load()
    }

    private func load() {
        if let raw = settings.get(Self.kEnabled),
           let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([QuickActionId].self, from: data) {
            enabledIds = decoded
        }
        if let raw = settings.get(Self.kCustom),
           let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([CustomQuickAction].self, from: data) {
            customActions = decoded
        }
        for builtin in BuiltinQuickAction.allCases {
            if let raw = settings.get(Self.kBuiltinCmd(builtin.id)),
               !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                builtinCommandOverrides[builtin.id] = raw
            }
        }
    }

    /// 外部配置文件被改了（settings.onChange 触发）时调用，全量重读。
    func reloadFromSettings() {
        enabledIds.removeAll()
        builtinCommandOverrides.removeAll()
        customActions.removeAll()
        load()
    }

    // MARK: - Read

    func isEnabled(_ id: QuickActionId) -> Bool {
        enabledIds.contains(id)
    }

    func command(for id: QuickActionId) -> String? {
        if let builtin = BuiltinQuickAction.from(id: id) {
            if let override = builtinCommandOverrides[id]?
                .trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
                return override
            }
            return builtin.defaultCommand
        }
        guard let custom = customActions.first(where: { $0.id == id }) else { return nil }
        let trimmed = custom.command.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func displayName(for id: QuickActionId, locale: Locale) -> String {
        if let builtin = BuiltinQuickAction.from(id: id) {
            return String(localized: builtin.displayName.withLocale(locale))
        }
        if let custom = customActions.first(where: { $0.id == id }) {
            let trimmed = custom.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? id : trimmed
        }
        return id
    }

    func iconSource(for id: QuickActionId) -> QuickActionIcon {
        if let builtin = BuiltinQuickAction.from(id: id) {
            return builtin.iconSource
        }
        let name = customActions.first(where: { $0.id == id })?
            .name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let first = name.first.map { Character(String($0).uppercased()) } ?? "?"
        return .letter(first)
    }

    /// 顶栏渲染源：保持 enabledIds 的顺序，过滤掉指向已删 custom 的脏 id。
    var displayList: [QuickActionId] {
        enabledIds.filter { id in
            BuiltinQuickAction.from(id: id) != nil
                || customActions.contains(where: { $0.id == id })
        }
    }

    /// Settings 列表渲染源：所有 4 内置 + 所有 custom。
    /// 顺序：先按 enabledIds 顺序里出现的（保留显示顺序），再追加未启用的内置（按 BuiltinQuickAction.allCases 顺序），
    /// 再追加未启用的 custom（按 customActions 数组顺序）。
    var fullList: [QuickActionId] {
        var seen = Set<QuickActionId>()
        var result: [QuickActionId] = []
        for id in enabledIds where !seen.contains(id) {
            // 仅保留实际存在的（脏 id 被丢）
            if BuiltinQuickAction.from(id: id) != nil
                || customActions.contains(where: { $0.id == id }) {
                result.append(id); seen.insert(id)
            }
        }
        for builtin in BuiltinQuickAction.allCases where !seen.contains(builtin.id) {
            result.append(builtin.id); seen.insert(builtin.id)
        }
        for custom in customActions where !seen.contains(custom.id) {
            result.append(custom.id); seen.insert(custom.id)
        }
        return result
    }

    // MARK: - Mutate

    func setEnabled(_ id: QuickActionId, _ enabled: Bool) {
        let before = enabledIds
        if enabled, !enabledIds.contains(id) {
            enabledIds.append(id)
        } else if !enabled {
            enabledIds.removeAll { $0 == id }
        }
        if enabledIds != before { saveEnabled() }
    }

    func setBuiltinCommand(_ id: QuickActionId, _ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            builtinCommandOverrides.removeValue(forKey: id)
            settings.set(Self.kBuiltinCmd(id), nil)
        } else {
            builtinCommandOverrides[id] = command  // store raw to preserve user input
            settings.set(Self.kBuiltinCmd(id), command)
        }
    }

    @discardableResult
    func addCustomAction() -> QuickActionId {
        let id = UUID().uuidString
        customActions.append(CustomQuickAction(id: id, name: "", command: ""))
        saveCustom()
        return id
    }

    func updateCustomAction(_ id: QuickActionId, name: String? = nil, command: String? = nil) {
        guard let idx = customActions.firstIndex(where: { $0.id == id }) else { return }
        if let n = name { customActions[idx].name = n }
        if let c = command { customActions[idx].command = c }
        saveCustom()
    }

    func removeCustomAction(_ id: QuickActionId) {
        customActions.removeAll { $0.id == id }
        let beforeEnabled = enabledIds
        enabledIds.removeAll { $0 == id }
        saveCustom()
        if enabledIds != beforeEnabled { saveEnabled() }
    }

    /// `from` / `to` 是 displayList 维度的索引（即用户在 Settings 拖拽时看到的那个列表）。
    /// 已启用条目按显示顺序排列；未启用条目不参与 displayList 维度的拖拽（在 Settings 里
    /// 它们出现在 fullList 尾部，单独的 reorderFull(_:to:) 处理）。本方法只更新 enabledIds
    /// 数组顺序，不影响 customActions 数组顺序。
    func reorderDisplay(from source: IndexSet, to destination: Int) {
        let before = enabledIds
        // displayList 是 enabledIds 的过滤结果，但非启用脏 id 会被过滤掉。先把 displayList 提取出来。
        var working = displayList
        working.move(fromOffsets: source, toOffset: destination)
        // 把 working 写回 enabledIds：保留 enabledIds 中出现但被 displayList 过滤掉的脏 id（追加在末尾，
        // 避免静默丢数据，与 spec "脏 id 不被 mutate API 自动清理" 一致）。
        let validSet = Set(working)
        let dirty = before.filter { !validSet.contains($0) }
        enabledIds = working + dirty
        if enabledIds != before { saveEnabled() }
    }

    // MARK: - Persist

    private func saveEnabled() {
        if let data = try? JSONEncoder().encode(enabledIds),
           let s = String(data: data, encoding: .utf8) {
            settings.set(Self.kEnabled, s)
        }
    }

    private func saveCustom() {
        if let data = try? JSONEncoder().encode(customActions),
           let s = String(data: data, encoding: .utf8) {
            settings.set(Self.kCustom, s)
        }
    }
}
```

注意 `SettingsConfigStore`：测试用 `init(defaults: UserDefaults)`。当前 `SettingsConfigStore` 的 init 是 `init()`（默认拿 standard）。需要在 `SettingsConfigStore` 上加一个 `init(defaults:)` 重载或者加可选参数。Step 5 处理。

- [ ] **Step 5: 给 `SettingsConfigStore` 加可注入 UserDefaults 的 init**

读 `mux0/Settings/SettingsConfigStore.swift`，把现有 `init()` 改为：

```swift
init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    // ... 原 init 内容
}
```

并把内部使用 `UserDefaults.standard` 的地方都改成 `self.defaults`。

如果当前实现不是基于 UserDefaults（而是自己读写 `~/.config/mux0/config`），则改用一个其他 mock 边界（比如把 `set/get` 抽成 protocol，测试用 in-memory 实现）。先读源文件再决定具体改法。

- [ ] **Step 6: 跑测试 + commit**

```bash
xcodebuild test -project mux0.xcodeproj -scheme mux0Tests \
    -only-testing:mux0Tests/QuickActionTests \
    -only-testing:mux0Tests/QuickActionsStoreTests
# Expected: PASS

git add mux0/Models/QuickAction.swift mux0/Models/QuickActionsStore.swift \
        mux0/Localization/L10n.swift mux0/Localization/Localizable.xcstrings \
        mux0/Settings/SettingsConfigStore.swift \
        mux0Tests/QuickActionTests.swift mux0Tests/QuickActionsStoreTests.swift
git commit -m "feat(models): add QuickActionsStore + builtin/custom action types"
```

---

## Task 2: TerminalTab.quickActionId 重构 + WorkspaceStore 方法重命名

**Files:**
- Modify: `mux0/Models/Workspace.swift`
- Modify: `mux0/Models/WorkspaceStore.swift`
- Modify: `mux0/TabContent/TabContentView.swift`
- Modify: `mux0/TabContent/TabBarView.swift`
- Modify: `mux0/Bridge/TabBridge.swift`（如需透传 quickActionsStore）
- Modify: `mux0/ContentView.swift`（gitTabButton 调用方重命名为 ensureQuickActionTab(id: "lazygit")，并把 quickActionsStore 注入到 TabBridge）
- Test: `mux0Tests/WorkspaceStoreTests.swift`

本任务把数据模型字段名从 `kind: TabKind?` 改成 `quickActionId: String?`，删除 TabKind enum，重命名 `ensureGitTab` → `ensureQuickActionTab(id:in:)`，并把 TabContentView/TabBarView 切到新字段。`gitTabButton` 暂时保留（仍然挂在右上角），call site 改成 `ensureQuickActionTab(id: "lazygit", ...)`，留待 Task 8 再删除并替换为 QuickActionsBar。

- [ ] **Step 1: 写失败测试 — 替换 ensureGitTab 测试**

`WorkspaceStoreTests.swift` 中现有的：
- `test_ensureGitTab_*` → 重命名为 `test_ensureQuickActionTab_*`，所有 `ensureGitTab(in:)` 调用改成 `ensureQuickActionTab(id: "lazygit", in:)`，断言 `kind == .git` 改成 `quickActionId == "lazygit"`
- `test_terminalTab_codable_*` 中 TabKind 相关断言改成 quickActionId 字符串断言
- 加一条新测试：

```swift
func test_ensureQuickActionTab_differentIdsCreateDifferentTabs() {
    let store = WorkspaceStore(persistenceKey: "test.\(UUID().uuidString)")
    let wsId = store.workspaces[0].id
    let r1 = store.ensureQuickActionTab(id: "lazygit", in: wsId)
    let r2 = store.ensureQuickActionTab(id: "claude", in: wsId)
    XCTAssertTrue(r1.isNew)
    XCTAssertTrue(r2.isNew)
    XCTAssertNotEqual(r1.tabId, r2.tabId)
}

func test_ensureQuickActionTab_sameIdReusesTab() {
    let store = WorkspaceStore(persistenceKey: "test.\(UUID().uuidString)")
    let wsId = store.workspaces[0].id
    let r1 = store.ensureQuickActionTab(id: "lazygit", in: wsId)
    let r2 = store.ensureQuickActionTab(id: "lazygit", in: wsId)
    XCTAssertTrue(r1.isNew)
    XCTAssertFalse(r2.isNew)
    XCTAssertEqual(r1.tabId, r2.tabId)
}
```

Run: `xcodebuild test -project mux0.xcodeproj -scheme mux0Tests -only-testing:mux0Tests/WorkspaceStoreTests`
Expected: FAIL — 编译失败（TabKind 还在 / ensureQuickActionTab 不存在）。

- [ ] **Step 2: 改 `Workspace.swift`**

```swift
// 删除整个 enum TabKind 段
// MARK: - TerminalTab
struct TerminalTab: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var layout: SplitNode
    var focusedTerminalId: UUID
    var quickActionId: String? = nil

    init(id: UUID = UUID(), title: String, terminalId: UUID = UUID(),
         quickActionId: String? = nil) {
        self.id = id
        self.title = title
        self.layout = .terminal(terminalId)
        self.focusedTerminalId = terminalId
        self.quickActionId = quickActionId
    }
}
```

Codable 自动派生即可——`Optional<String>` 的 `decodeIfPresent` 是 Swift 内置行为，缺字段会 → nil。

- [ ] **Step 3: 改 `WorkspaceStore.swift` — addTab + ensureQuickActionTab**

```swift
@discardableResult
func addTab(to workspaceId: UUID, quickActionId: String? = nil, title: String? = nil)
    -> (tabId: UUID, terminalId: UUID)?
{
    guard let wsIdx = wsIndex(workspaceId) else { return nil }
    let index = workspaces[wsIdx].tabs.count + 1
    let resolvedTitle: String = title ?? "terminal \(index)"
    var tab = makeNewTab(index: index)
    tab.title = resolvedTitle
    tab.quickActionId = quickActionId
    workspaces[wsIdx].tabs.append(tab)
    workspaces[wsIdx].selectedTabId = tab.id
    save()
    return (tabId: tab.id, terminalId: tab.layout.allTerminalIds()[0])
}

@discardableResult
func ensureQuickActionTab(id: String, title: String, in workspaceId: UUID) -> (
    tabId: UUID,
    terminalId: UUID,
    isNew: Bool,
    sourcePwdTerminalId: UUID?
) {
    guard let wsIdx = wsIndex(workspaceId) else {
        return (UUID(), UUID(), false, nil)
    }
    let sourcePwdTerminalId: UUID? = {
        guard let selId = workspaces[wsIdx].selectedTabId,
              let selTab = workspaces[wsIdx].tabs.first(where: { $0.id == selId })
        else { return nil }
        return selTab.focusedTerminalId
    }()

    if let existing = workspaces[wsIdx].tabs.first(where: { $0.quickActionId == id }) {
        selectTab(id: existing.id, in: workspaceId)
        return (existing.id, existing.focusedTerminalId, false, sourcePwdTerminalId)
    }

    guard let created = addTab(to: workspaceId, quickActionId: id, title: title) else {
        assertionFailure("addTab failed despite validated workspaceId — invariant broken")
        return (UUID(), UUID(), false, nil)
    }
    return (created.tabId, created.terminalId, true, sourcePwdTerminalId)
}
```

删除旧的 `ensureGitTab`、旧的 `addTab(to:kind:)`。

- [ ] **Step 4: 改 `TabContentView.swift` — resolvedStartupCommand 用 QuickActionsStore**

把现有的 git-tab 注入逻辑：

```swift
// 删除：tab.kind == .git, mux0-git-viewer 查找
// 新增：
if let actionId = tab.quickActionId,
   id == tab.layout.allTerminalIds().first,
   let cmd = quickActionsStore?.command(for: actionId) {
    return "\(cmd)\n"
}
```

`quickActionsStore` 通过 `TabContentView` 的初始化参数接收（`@MainActor` 持有 weak 引用，与现有 `settingsStore` 一样的传法）。需要 `TabBridge` / `ContentView` 一起接通。

- [ ] **Step 5: 改 `TabBarView.swift` — applyKindImage 用 iconSource**

把 `applyKindImage(_ kind: TabKind?)` 改成 `applyQuickActionImage(_ id: String?)`：

```swift
private func applyQuickActionImage(_ id: String?) {
    guard let id = id else {
        // 普通 terminal tab → SF Symbol "terminal"
        kindIcon.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        kindIcon.contentTintColor = NSColor(theme.textSecondary)
        return
    }
    let source = quickActionsStore?.iconSource(for: id) ?? .sfSymbol("terminal")
    switch source {
    case .sfSymbol(let name):
        kindIcon.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        kindIcon.contentTintColor = NSColor(theme.textSecondary)
    case .asset(let name):
        kindIcon.image = NSImage(named: name)
        kindIcon.contentTintColor = NSColor(theme.textSecondary)
    case .letter(let c):
        kindIcon.image = makeLetterImage(String(c), tint: NSColor(theme.textSecondary))
    }
}
```

`makeLetterImage` 是用 `NSAttributedString` 在 14×14 NSImage 上绘字符的小工具——可放进 TabBarView fileprivate。

`displayedKind: TabKind?` 改成 `displayedQuickActionId: String?`。所有 `tab.kind` 引用改成 `tab.quickActionId`。

- [ ] **Step 6: 改 `ContentView.swift`、`TabBridge.swift` — 注入 quickActionsStore**

`ContentView`：
```swift
@State private var quickActionsStore = QuickActionsStore(settings: SettingsConfigStore())
```

但要注意 settings 是 `@State` 的，要等 init 完成后才能传。改用懒加载：
```swift
@State private var settingsStore = SettingsConfigStore()
@State private var quickActionsStore: QuickActionsStore? = nil

// 在 onAppear:
if quickActionsStore == nil {
    quickActionsStore = QuickActionsStore(settings: settingsStore)
}
```

把 `quickActionsStore` 传给 `TabBridge` + `SettingsView`（后者 Task 4 才用，先只接通 TabBridge）。

`gitTabButton` 暂保留，把内部 `store.ensureGitTab(in: wsId)` 改成：
```swift
let title = quickActionsStore?.displayName(for: "lazygit", locale: locale) ?? "Lazygit"
let result = store.ensureQuickActionTab(id: "lazygit", title: title, in: wsId)
```

- [ ] **Step 7: 跑测试 + build + commit**

```bash
xcodebuild test -project mux0.xcodeproj -scheme mux0Tests \
    -only-testing:mux0Tests/WorkspaceStoreTests
xcodebuild -project mux0.xcodeproj -scheme mux0 -configuration Debug build
# Expected: 二者均 PASS

git add mux0/Models/Workspace.swift mux0/Models/WorkspaceStore.swift \
        mux0/TabContent/TabContentView.swift mux0/TabContent/TabBarView.swift \
        mux0/Bridge/TabBridge.swift mux0/ContentView.swift \
        mux0Tests/WorkspaceStoreTests.swift
git commit -m "refactor(models): TabKind→quickActionId; WorkspaceStore.ensureQuickActionTab"
```

---

## Task 3: Asset Catalog 加 3 个 lobe-icons SVG

**Files:**
- Create: `mux0/Assets.xcassets/quick-action-claudecode.imageset/Contents.json`
- Create: `mux0/Assets.xcassets/quick-action-claudecode.imageset/claudecode.svg`
- Create: `mux0/Assets.xcassets/quick-action-codex.imageset/Contents.json`
- Create: `mux0/Assets.xcassets/quick-action-codex.imageset/codex.svg`
- Create: `mux0/Assets.xcassets/quick-action-opencode.imageset/Contents.json`
- Create: `mux0/Assets.xcassets/quick-action-opencode.imageset/opencode.svg`

无测试（资产文件）。验证靠 build：Xcode/asset compiler 解析失败会编译报错。

- [ ] **Step 1: 下载并放置 SVG**

```bash
mkdir -p mux0/Assets.xcassets/quick-action-claudecode.imageset
mkdir -p mux0/Assets.xcassets/quick-action-codex.imageset
mkdir -p mux0/Assets.xcassets/quick-action-opencode.imageset

curl -sL https://raw.githubusercontent.com/lobehub/lobe-icons/refs/heads/master/packages/static-svg/icons/claudecode.svg \
    > mux0/Assets.xcassets/quick-action-claudecode.imageset/claudecode.svg
curl -sL https://raw.githubusercontent.com/lobehub/lobe-icons/refs/heads/master/packages/static-svg/icons/codex.svg \
    > mux0/Assets.xcassets/quick-action-codex.imageset/codex.svg
curl -sL https://raw.githubusercontent.com/lobehub/lobe-icons/refs/heads/master/packages/static-svg/icons/opencode.svg \
    > mux0/Assets.xcassets/quick-action-opencode.imageset/opencode.svg
```

预期 SVG 内容（确认前已通过 lobe-icons 仓库 API 验证 HTTP 200 + 包含 `fill="currentColor"`）。

- [ ] **Step 2: 写每个 imageset 的 `Contents.json`**

`mux0/Assets.xcassets/quick-action-claudecode.imageset/Contents.json`:

```json
{
  "images" : [
    {
      "filename" : "claudecode.svg",
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  },
  "properties" : {
    "preserves-vector-representation" : true,
    "template-rendering-intent" : "template"
  }
}
```

codex.imageset 的 Contents.json 把 filename 改成 `codex.svg`，opencode.imageset 改成 `opencode.svg`。其它字段一致。

- [ ] **Step 3: build 验证 + commit**

```bash
xcodebuild -project mux0.xcodeproj -scheme mux0 -configuration Debug build
# Expected: PASS （asset catalog 编译期 validate 通过）

git add mux0/Assets.xcassets/quick-action-claudecode.imageset \
        mux0/Assets.xcassets/quick-action-codex.imageset \
        mux0/Assets.xcassets/quick-action-opencode.imageset
git commit -m "feat(assets): add lobe-icons SVGs for claude/codex/opencode quick actions"
```

---

## Task 4: SettingsSection 加 .quickActions case + 占位 SectionView

**Files:**
- Modify: `mux0/Settings/SettingsSection.swift`
- Modify: `mux0/Settings/SettingsTabBarView.swift`
- Modify: `mux0/Settings/SettingsView.swift`
- Create: `mux0/Settings/Sections/QuickActionsSectionView.swift`
- Modify: `mux0/Localization/Localizable.xcstrings`
- Modify: `mux0/Localization/L10n.swift`
- Modify: `mux0Tests/L10nSmokeTests.swift`

只把 settings tab 占位拉好。SectionView 内容是空的（"Coming soon" 占位 Text），下个任务才填内容。

- [ ] **Step 1: 加 i18n key**

`Localizable.xcstrings` 加：

| key                              | en             | zh-Hans     |
| -------------------------------- | -------------- | ----------- |
| `settings.section.quickActions`  | Quick Actions  | 快捷操作    |

`L10n.swift` 在 `Settings` 命名空间下加：

```swift
static let sectionQuickActions = LocalizedStringResource("settings.section.quickActions")
```

`L10nSmokeTests.swift` 的 `allKeys` 数组按字母位置插入 `"settings.section.quickActions"`。

- [ ] **Step 2: 加 SettingsSection.quickActions**

```swift
enum SettingsSection: String, CaseIterable, Identifiable {
    case appearance, font, terminal, shell, quickActions, agents, update
    // ↑ 顺序：shell 之后、agents 之前

    var label: LocalizedStringResource {
        switch self {
        // ...
        case .quickActions: return L10n.Settings.sectionQuickActions
        // ...
        }
    }
}
```

- [ ] **Step 3: SettingsTabBarView icon**

找到现有 sectionIcon 映射，加：
```swift
case .quickActions: return "bolt"
```

- [ ] **Step 4: SettingsView 渲染分支**

```swift
case .quickActions:
    QuickActionsSectionView(theme: theme, settings: settings, quickActionsStore: quickActionsStore)
```

`SettingsView` 的 init/参数列表加 `quickActionsStore: QuickActionsStore`，由 ContentView 传入（Task 2 已经创建 quickActionsStore）。

- [ ] **Step 5: 占位 QuickActionsSectionView**

```swift
import SwiftUI

struct QuickActionsSectionView: View {
    let theme: AppTheme
    let settings: SettingsConfigStore
    let quickActionsStore: QuickActionsStore

    var body: some View {
        Form {
            Text("Quick Actions UI — implemented in next task")
                .foregroundColor(Color(theme.textTertiary))
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
```

- [ ] **Step 6: build + L10n smoke test + commit**

```bash
xcodebuild test -project mux0.xcodeproj -scheme mux0Tests \
    -only-testing:mux0Tests/L10nSmokeTests
xcodebuild -project mux0.xcodeproj -scheme mux0 -configuration Debug build

git add mux0/Settings/SettingsSection.swift mux0/Settings/SettingsTabBarView.swift \
        mux0/Settings/SettingsView.swift mux0/Settings/Sections/QuickActionsSectionView.swift \
        mux0/Localization/Localizable.xcstrings mux0/Localization/L10n.swift \
        mux0Tests/L10nSmokeTests.swift mux0/ContentView.swift
git commit -m "feat(settings): add Quick Actions section scaffold"
```

---

## Task 5: QuickActionIconView 组件

**Files:**
- Create: `mux0/Settings/Components/QuickActionIconView.swift`

无独立测试（组件极小）；下游任务的视觉行为靠人工验证。

- [ ] **Step 1: 实现 `QuickActionIconView.swift`**

```swift
import SwiftUI

/// 16pt 默认尺寸的图标——SF Symbol / Asset / Letter 三选一渲染。
/// 调用方传入颜色（通常是 theme.textSecondary），不在内部读 environment 主题，
/// 让 Settings 行 / 顶栏复用同一个组件。
struct QuickActionIconView: View {
    let source: QuickActionIcon
    var size: CGFloat = 16
    var color: Color = .primary

    var body: some View {
        switch source {
        case .sfSymbol(let name):
            Image(systemName: name)
                .font(.system(size: size, weight: .regular))
                .foregroundColor(color)
                .frame(width: size + 4, height: size + 4)
        case .asset(let name):
            Image(name)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .foregroundColor(color)
        case .letter(let c):
            Text(String(c))
                .font(.system(size: size - 2, weight: .semibold, design: .rounded))
                .foregroundColor(color)
                .frame(width: size + 4, height: size + 4)
                .background(
                    Circle()
                        .stroke(color.opacity(0.4), lineWidth: 1)
                )
        }
    }
}
```

- [ ] **Step 2: build + commit**

```bash
xcodebuild -project mux0.xcodeproj -scheme mux0 -configuration Debug build

git add mux0/Settings/Components/QuickActionIconView.swift
git commit -m "feat(settings): add QuickActionIconView component"
```

---

## Task 6: QuickActionRowView 组件

**Files:**
- Create: `mux0/Settings/Components/QuickActionRowView.swift`
- Modify: `mux0/Localization/Localizable.xcstrings`
- Modify: `mux0/Localization/L10n.swift`
- Modify: `mux0Tests/L10nSmokeTests.swift`

- [ ] **Step 1: 加 i18n key**

| key                                              | en                                                    | zh-Hans                          |
| ------------------------------------------------ | ----------------------------------------------------- | -------------------------------- |
| `settings.quickActions.customNamePlaceholder`    | Name                                                   | 名称                              |
| `settings.quickActions.customCommandPlaceholder` | Command                                                | 命令                              |
| `settings.quickActions.deleteCustom.tooltip`     | Delete custom action                                   | 删除自定义快捷操作                 |

`L10n.swift` 加 `Settings.QuickActions.customNamePlaceholder` 等常量；`L10nSmokeTests.allKeys` 同步。

- [ ] **Step 2: 实现 QuickActionRowView**

```swift
import SwiftUI

struct QuickActionRowView: View {
    let id: QuickActionId
    let store: QuickActionsStore
    let theme: AppTheme
    let isBuiltin: Bool

    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: 8) {
            QuickActionIconView(source: store.iconSource(for: id),
                                size: 16,
                                color: Color(theme.textSecondary))
                .frame(width: 24)

            if isBuiltin {
                Text(store.displayName(for: id, locale: locale))
                    .frame(width: 100, alignment: .leading)
                    .foregroundColor(Color(theme.text))
            } else {
                TextField(L10n.Settings.QuickActions.customNamePlaceholder.localized(locale),
                          text: nameBinding)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
            }

            TextField(commandPlaceholder, text: commandBinding)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)

            Toggle("", isOn: enabledBinding)
                .toggleStyle(.switch)
                .labelsHidden()

            if !isBuiltin {
                Button {
                    store.removeCustomAction(id)
                } label: {
                    Image(systemName: "trash")
                        .foregroundColor(Color(theme.textTertiary))
                }
                .buttonStyle(.borderless)
                .help(String(localized: L10n.Settings.QuickActions.deleteCustomTooltip.withLocale(locale)))
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Bindings

    private var nameBinding: Binding<String> {
        Binding(
            get: { store.customActions.first(where: { $0.id == id })?.name ?? "" },
            set: { store.updateCustomAction(id, name: $0) }
        )
    }

    private var commandBinding: Binding<String> {
        Binding(
            get: {
                if isBuiltin {
                    return store.builtinCommandOverrides[id] ?? ""
                }
                return store.customActions.first(where: { $0.id == id })?.command ?? ""
            },
            set: { newValue in
                if isBuiltin {
                    store.setBuiltinCommand(id, newValue)
                } else {
                    store.updateCustomAction(id, command: newValue)
                }
            }
        )
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { store.isEnabled(id) },
            set: { store.setEnabled(id, $0) }
        )
    }

    private var commandPlaceholder: String {
        if let builtin = BuiltinQuickAction.from(id: id) {
            return builtin.defaultCommand
        }
        return String(localized: L10n.Settings.QuickActions.customCommandPlaceholder.withLocale(locale))
    }
}

// 帮手——LocalizedStringResource → String 简写
private extension LocalizedStringResource {
    func localized(_ locale: Locale) -> String {
        String(localized: self.withLocale(locale))
    }
}
```

如果 `LocalizedStringResource.localized(_)` 已存在于项目内（很可能），删掉 fileprivate extension 不重复定义。先检查 `L10n.swift` / `LanguageStore.swift`。

- [ ] **Step 3: build + L10n smoke test + commit**

```bash
xcodebuild test -project mux0.xcodeproj -scheme mux0Tests \
    -only-testing:mux0Tests/L10nSmokeTests
xcodebuild -project mux0.xcodeproj -scheme mux0 -configuration Debug build

git add mux0/Settings/Components/QuickActionRowView.swift \
        mux0/Localization/Localizable.xcstrings mux0/Localization/L10n.swift \
        mux0Tests/L10nSmokeTests.swift
git commit -m "feat(settings): add QuickActionRowView with editable bindings"
```

---

## Task 7: QuickActionsSectionView 真正实现

**Files:**
- Modify: `mux0/Settings/Sections/QuickActionsSectionView.swift`
- Modify: `mux0/Localization/Localizable.xcstrings`
- Modify: `mux0/Localization/L10n.swift`
- Modify: `mux0Tests/L10nSmokeTests.swift`

- [ ] **Step 1: 加 i18n key**

| key                                       | en                                                    | zh-Hans                          |
| ----------------------------------------- | ----------------------------------------------------- | -------------------------------- |
| `settings.quickActions.heading`           | Enabled & Order                                       | 启用与排序                        |
| `settings.quickActions.headingFooter`     | Enabled buttons appear in the top-right corner of the window. Drag to reorder. | 启用的按钮会按下方顺序出现在窗口右上角，可拖拽排序。 |
| `settings.quickActions.addCustomButton`   | Add Custom Action                                      | 新建自定义快捷操作                 |

L10n + smoke test 同步。

- [ ] **Step 2: 替换 QuickActionsSectionView body**

```swift
import SwiftUI

struct QuickActionsSectionView: View {
    let theme: AppTheme
    let settings: SettingsConfigStore
    let quickActionsStore: QuickActionsStore

    @Environment(\.locale) private var locale

    private var managedKeys: [String] {
        var keys = ["mux0-quickactions-enabled", "mux0-quickactions-custom"]
        keys.append(contentsOf: BuiltinQuickAction.allCases.map {
            "mux0-quickactions-builtin-command-\($0.id)"
        })
        return keys
    }

    var body: some View {
        Form {
            Section {
                List {
                    ForEach(quickActionsStore.fullList, id: \.self) { id in
                        QuickActionRowView(
                            id: id,
                            store: quickActionsStore,
                            theme: theme,
                            isBuiltin: BuiltinQuickAction.from(id: id) != nil
                        )
                    }
                    .onMove { src, dst in
                        // List 的 onMove 是 fullList 维度的——store 内部把 displayList 维度
                        // 的重排映射到 enabledIds 顺序。未启用项的位置变化不影响 enabledIds。
                        quickActionsStore.reorderFull(from: src, to: dst)
                    }
                }
                .frame(minHeight: 200)
            } header: {
                Text(L10n.Settings.QuickActions.heading)
            } footer: {
                Text(L10n.Settings.QuickActions.headingFooter)
                    .font(Font(DT.Font.small))
                    .foregroundColor(Color(theme.textTertiary))
            }

            Section {
                Button {
                    _ = quickActionsStore.addCustomAction()
                } label: {
                    Label(String(localized: L10n.Settings.QuickActions.addCustomButton.withLocale(locale)),
                          systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
            }

            SettingsResetRow(settings: settings, keys: managedKeys)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
```

- [ ] **Step 3: 给 store 加 reorderFull**

`QuickActionsStore` 需要新方法：

```swift
/// fullList 维度的拖拽——只更新 enabledIds 的顺序与 customActions 的顺序，
/// 内置项的相对顺序变化也只影响 enabledIds（如果它们启用了）。
func reorderFull(from source: IndexSet, to destination: Int) {
    var working = fullList
    working.move(fromOffsets: source, toOffset: destination)
    // 1. 重排 enabledIds：保持 working 顺序里被启用的元素的相对位置。
    let enabledSet = Set(enabledIds)
    let newEnabledOrder = working.filter { enabledSet.contains($0) }
    // 保留之前启用但 working 不在的脏 id（追加在末尾）
    let dirtyEnabled = enabledIds.filter { !working.contains($0) }
    let beforeEnabled = enabledIds
    enabledIds = newEnabledOrder + dirtyEnabled

    // 2. 重排 customActions：按 working 中 custom id 的顺序。
    let customById = Dictionary(uniqueKeysWithValues: customActions.map { ($0.id, $0) })
    let workingCustomIds = working.compactMap { id -> CustomQuickAction? in
        BuiltinQuickAction.from(id: id) == nil ? customById[id] : nil
    }
    let dirtyCustom = customActions.filter { !working.contains($0.id) }
    let beforeCustom = customActions
    customActions = workingCustomIds + dirtyCustom

    if enabledIds != beforeEnabled { saveEnabled() }
    if customActions != beforeCustom { saveCustom() }
}
```

写一条测试：

```swift
func test_reorderFull_disabledBuiltinToTop() {
    let (store, _) = makeIsolatedStore()
    store.setEnabled("lazygit", true)
    // fullList: [lazygit, claude, codex, opencode]（claude/codex/opencode 未启用，但都列在 fullList）
    let codexIdx = store.fullList.firstIndex(of: "codex")!
    store.reorderFull(from: IndexSet([codexIdx]), to: 0)
    // codex 移到首位但因为没启用，不影响 enabledIds
    XCTAssertEqual(store.fullList.first, "codex")
    XCTAssertEqual(store.enabledIds, ["lazygit"])
}
```

- [ ] **Step 4: build + 测试 + commit**

```bash
xcodebuild test -project mux0.xcodeproj -scheme mux0Tests \
    -only-testing:mux0Tests/QuickActionsStoreTests \
    -only-testing:mux0Tests/L10nSmokeTests
xcodebuild -project mux0.xcodeproj -scheme mux0 -configuration Debug build

git add mux0/Settings/Sections/QuickActionsSectionView.swift \
        mux0/Models/QuickActionsStore.swift \
        mux0/Localization/Localizable.xcstrings mux0/Localization/L10n.swift \
        mux0Tests/L10nSmokeTests.swift mux0Tests/QuickActionsStoreTests.swift
git commit -m "feat(settings): implement Quick Actions list with reorder + add custom"
```

---

## Task 8: ContentView QuickActionsBar + 删除 gitTabButton + 删除 mux0-git-viewer

**Files:**
- Modify: `mux0/ContentView.swift`
- Modify: `mux0/Settings/Sections/ShellSectionView.swift`
- Modify: `mux0/Localization/Localizable.xcstrings`
- Modify: `mux0/Localization/L10n.swift`
- Modify: `mux0Tests/L10nSmokeTests.swift`

- [ ] **Step 1: ContentView — 替换 gitTabButton 为 quickActionsBar**

```swift
@ViewBuilder
private var quickActionsBar: some View {
    if let store = quickActionsStore {
        let displayList = store.displayList
        if !displayList.isEmpty {
            HStack(spacing: 4) {
                ForEach(displayList, id: \.self) { id in
                    quickActionButton(id: id, store: store)
                }
            }
        }
    }
}

private func quickActionButton(id: QuickActionId, store: QuickActionsStore) -> some View {
    let tooltip = store.displayName(for: id, locale: locale)
    let icon = store.iconSource(for: id)
    return IconButton(theme: themeManager.theme, help: tooltip) {
        guard let wsId = self.store.selectedId else { return }
        let title = tooltip
        let result = self.store.ensureQuickActionTab(id: id, title: title, in: wsId)
        if result.isNew, let prev = result.sourcePwdTerminalId {
            pwdStore.inherit(from: prev, to: result.terminalId)
        }
    } label: {
        QuickActionIconView(source: icon, size: 13,
                            color: Color(themeManager.theme.textSecondary))
    }
    .disabled(self.store.selectedId == nil)
}
```

ZStack 里把：
```swift
gitTabButton
    .frame(maxWidth: .infinity, alignment: .topTrailing)
    .padding(.trailing, cardInset + DT.Space.xs)
    .padding(.top, DT.Space.xs)
```
替换为：
```swift
quickActionsBar
    .frame(maxWidth: .infinity, alignment: .topTrailing)
    .padding(.trailing, cardInset + DT.Space.xs)
    .padding(.top, DT.Space.xs)
```

删除 `private var gitTabButton: some View { ... }` 整段。

- [ ] **Step 2: 删除 mux0-git-viewer ShellSectionView 区段**

`ShellSectionView.swift` 中删除：
- `Section { BoundTextField (key: "mux0-git-viewer", ...) } footer: { ... }` 整段
- `managedKeys` 数组中的 `"mux0-git-viewer"` 项

- [ ] **Step 3: 删除旧 i18n key**

`Localizable.xcstrings` 删 4 条记录：
- `topbar.gitButton.tooltip`
- `settings.shell.gitViewer.label`
- `settings.shell.gitViewer.help`
- `settings.shell.gitViewer.installHint`

`L10n.swift`：
- 删 `enum Topbar { static let gitButtonTooltip ... }` 整个命名空间（如果只有这一项）
- 删 `Settings.Shell.gitViewerLabel/Help/InstallHint` 三个常量

`L10nSmokeTests.allKeys` 数组同步删除这 4 项。

- [ ] **Step 4: build + 测试 + commit**

```bash
xcodebuild test -project mux0.xcodeproj -scheme mux0Tests
xcodebuild -project mux0.xcodeproj -scheme mux0 -configuration Debug build

git add mux0/ContentView.swift mux0/Settings/Sections/ShellSectionView.swift \
        mux0/Localization/Localizable.xcstrings mux0/Localization/L10n.swift \
        mux0Tests/L10nSmokeTests.swift
git commit -m "feat(bridge): replace gitTabButton with QuickActionsBar; drop legacy git-viewer"
```

---

## Task 9: 文档同步

**Files:**
- Modify: `CLAUDE.md`
- Modify: `docs/architecture.md`
- Modify: `docs/settings-reference.md`

- [ ] **Step 1: CLAUDE.md**

Directory Structure 加：
```
├── Models/
│   ├── QuickAction.swift              — Builtin/Custom action 类型与 Icon 来源
│   ├── QuickActionsStore.swift        — @Observable，enabled / overrides / custom 三段持久化
│   ...
├── Settings/
│   ├── Components/
│   │   ├── QuickActionIconView.swift  — SF Symbol / Asset / Letter 三种图标渲染
│   │   ├── QuickActionRowView.swift   — Quick Actions Settings 单行
│   │   ...
│   ├── Sections/
│   │   ├── QuickActionsSectionView.swift  — Quick Actions Settings 主面板
│   │   ...
```

Common Tasks 把现有「增加新的 tab 类型 (TabKind)」行替换为：

| 任务 | 相关文件 / 命令 |
|------|----------------|
| 增加新的内置快捷操作 | `Models/QuickAction.swift` 加 `BuiltinQuickAction` case + 默认命令 + 图标，`Localizable.xcstrings` + `L10n.swift` 加 displayName key，必要时 `Assets.xcassets` 加 SVG imageset |
| 增加用户自定义快捷操作 | UI 已支持：Settings → Quick Actions → "新建自定义快捷操作" |

合法 commit scope 列表加 `quickactions`（如果选择 commit 用 `feat(quickactions): ...`；目前 plan 用 `feat(models)/feat(settings)/feat(bridge)` 也合法）。

- [ ] **Step 2: docs/architecture.md**

把 Git Tab subsection 整个改写为 Quick Actions：

```markdown
### Quick Actions

WorkspaceStore 的每个 Tab 可关联一个 **快捷操作 ID**（`TerminalTab.quickActionId: String?`），由顶栏的 Quick Actions Bar（`ContentView.quickActionsBar`）按 `QuickActionsStore.displayList` 顺序渲染按钮触发：点击 → `WorkspaceStore.ensureQuickActionTab(id:title:in:)` 在当前 workspace 找到/新建对应 tab，并继承前一个焦点 pane 的 pwd（让 `lazygit` 等命令落地在用户当下浏览的 cwd）。

**身份按 ID 区分，不按 title。** 用户改 tab 标题不影响"再点同样按钮 → 复用同一 tab"这条不变量。

**`QuickActionsStore`** 是 enabled 列表（按显示顺序排）+ 内置命令覆盖（per-id）+ 自定义条目数组的单一真理源，全部通过 `SettingsConfigStore` 持久化（3 个键：`mux0-quickactions-enabled` / `mux0-quickactions-builtin-command-<id>` / `mux0-quickactions-custom`）。`@Observable`，UI 直接订阅。

**命令注入路径：** Tab 第一个终端启动时，`TabContentView.resolvedStartupCommand` 检测 `tab.quickActionId` 非空 → 调 `quickActionsStore.command(for: id)`：内置 = override 或默认（`lazygit`/`claude`/`codex`/`opencode`），自定义 = 用户输入命令。返回值作为 `initial_input` + `\n` 喂给 ghostty surface，shell 启动后立即执行。

**重启恢复：** Tab 数据序列化到 UserDefaults，重启后 `tab.quickActionId` 还在 → 同一注入路径自动重新跑命令（lazygit 重新打开、claude 重新连接……）。Surface 不序列化，重启后是新 ghostty surface。

**图标：** `BuiltinQuickAction.iconSource` 三种来源——SF Symbol（lazygit 用 `arrow.triangle.branch`）、Asset Catalog（claude/codex/opencode 用 lobe-icons SVG，`template-rendering-intent: template`）、首字母（自定义）。三种统一通过 `QuickActionIconView` 渲染，跟随 theme token tint。

**Settings：** `Settings → Quick Actions` 提供单一可拖拽列表，所有 4 内置 + N 自定义混排，每行可独立 toggle 启用 / 改命令；自定义可改名 / 删除。详见 `docs/superpowers/specs/2026-04-30-quick-actions.md`。
```

- [ ] **Step 3: docs/settings-reference.md**

删除 `mux0-git-viewer` 一节。新增：

```markdown
### Quick Actions

| 键 | 类型 | 默认 | 说明 |
|----|------|------|------|
| `mux0-quickactions-enabled` | JSON 数组 | `[]` | 启用且按显示顺序排列的 quick action id。同时承载启用集合与启用集合内部顺序。 |
| `mux0-quickactions-builtin-command-<id>` | string | （空 = 默认命令） | 内置 action 的命令覆盖。`<id>` ∈ `{lazygit, claude, codex, opencode}`。空字符串等同删除该覆盖。 |
| `mux0-quickactions-custom` | JSON 数组 | `[]` | 自定义 action 列表。`[{"id":"<uuid>","name":"...","command":"..."}]`。 |

命令字段的语义：传给 shell 直接执行的字符串（不含 `\n`，由 ghostty 启动逻辑追加）。可以包含 shell 解释的语法，例如 `lazygit -p $PWD`、`claude --resume`、`tig log`。

身份按 id 区分（不是 name 也不是 command）；改命令不会让现有 tab 变成另一个 action 的 tab。
```

- [ ] **Step 4: 跑文档漂移检查 + commit**

```bash
./scripts/check-doc-drift.sh
# Expected: PASS

git add CLAUDE.md docs/architecture.md docs/settings-reference.md
git commit -m "docs: sync Quick Actions feature into CLAUDE.md, architecture, settings reference"
```

---

## Task 10: 整合验证

**Files:** 无（验证步骤）

- [ ] **Step 1: 全套测试**

```bash
xcodebuild test -project mux0.xcodeproj -scheme mux0Tests
# Expected: 全部通过
```

- [ ] **Step 2: 干净 build**

```bash
xcodebuild -project mux0.xcodeproj -scheme mux0 -configuration Debug build
# Expected: BUILD SUCCEEDED
```

- [ ] **Step 3: doc 漂移检查**

```bash
./scripts/check-doc-drift.sh
# Expected: PASS
```

- [ ] **Step 4: 人工验证清单交付给用户**

由于 mux0 是原生 macOS app 不支持热更新，agent 不主动重启 mux0.app。给用户列一份手动验证清单：

- [ ] 进 Settings → Quick Actions：能看到 4 个内置 row + 0 个自定义
- [ ] 启用 lazygit toggle → 顶栏出现 1 个按钮（git symbol）
- [ ] 改 lazygit 命令为 "echo lazygit" → 顶栏点击 → 新 tab 跑 echo
- [ ] 把命令字段清空 → 命令恢复成 lazygit
- [ ] 启用 claude / codex / opencode → 三个 brand 图标按钮出现，跟随主题切色
- [ ] 拖拽 Settings 列表里的某行到顶部 → 顶栏按钮顺序跟随更新
- [ ] 新建自定义 action："htop" / "htop -H" → 启用 → 顶栏出现 H 字母按钮
- [ ] 删除自定义 action → 按钮消失，对应 tab 保留但下次重启不再跑命令（变成普通 shell）
- [ ] 重启 mux0 → enabled 列表 + 顺序 + 自定义都恢复
- [ ] 中英文切换 Settings → 内置名称跟随切换

如人工清单中任何一条不符合预期，回到对应 task 修复。
