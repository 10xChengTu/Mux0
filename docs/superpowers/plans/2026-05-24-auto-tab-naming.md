# Tab 自动命名（从 agent 会话标题）实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tab 标题在用户未手动 rename 时自动跟随当前焦点 pane 的 agent 会话名（Claude / Codex / OpenCode），用户一次 rename 即永久锁定该 tab 名。

**Architecture:** Hook 端（`agent-hook.py` 和 `opencode-plugin/mux0-status.js`）在已有的 socket emit 上附加 `sessionTitle` 字段；Swift 端新增 `TerminalSessionTitleStore` 接收并按 terminalId 持久化；`TerminalTab` 新增 `userRenamed: Bool` 锁定标志；`TabItemView` 渲染时按 `userRenamed → store → tab.title 兜底` 三段回退。

**Tech Stack:** Swift / AppKit / SwiftUI / XCTest / Python 3 stdlib (`sqlite3`) / Node.js (opencode plugin) / pytest

**Spec:** `docs/superpowers/specs/2026-05-24-auto-tab-naming-design.md`

---

## File Structure

**Create:**
- `mux0/Models/TerminalSessionTitleStore.swift` — `@Observable` store，`[UUID: String]` 映射，UserDefaults 持久化
- `mux0Tests/TerminalSessionTitleStoreTests.swift` — store CRUD + 持久化往返
- `mux0Tests/TerminalTabDisplayTitleTests.swift` — `displayTitle(store:)` 三段回退
- `mux0Tests/HookDispatcherSessionTitleTests.swift` — 路由 sessionTitle 到 store

**Modify:**
- `mux0/Models/HookMessage.swift` — 加 `sessionTitle: String?`
- `mux0/Models/Workspace.swift` — `TerminalTab` 加 `userRenamed: Bool = false` + `displayTitle(...)` helper
- `mux0/Models/HookDispatcher.swift` — 收到 `sessionTitle` 时调 store.update
- `mux0/Models/WorkspaceStore.swift` — `renameTab` 设 `userRenamed=true`；新增 `resetTabToAutoTitle`；`closeTerminal`/`removeTab`/`deleteWorkspace` 清 store；接收 store 引用
- `mux0/ContentView.swift` — 实例化 `TerminalSessionTitleStore`，注入 `TabBridge`，`HookDispatcher.dispatch` 传 store
- `mux0/Bridge/TabBridge.swift` — `@Bindable var sessionTitleStore` + 透传到 `TabContentView`
- `mux0/TabContent/TabContentView.swift` — 接 `sessionTitleStore`，传给 `TabBarView`
- `mux0/TabContent/TabBarView.swift` — `update(...)` 接 `sessionTitleStore`；`TabItemView` 渲染 `displayTitle`；右键菜单加「Reset to auto title」
- `mux0/Localization/Localizable.xcstrings` — 加 `tab.row.resetAutoTitle`
- `mux0/Localization/L10n.swift` — 加常量
- `mux0Tests/HookMessageTests.swift` — 加 sessionTitle 解码测试
- `mux0Tests/WorkspaceStoreTests.swift`（若存在）— rename 设锁定 + reset 解锁
- `Resources/agent-hooks/agent-hook.py` — 新增 `read_ai_title()` / `read_codex_title()`；prompt + stop emit 附 `sessionTitle`
- `Resources/agent-hooks/opencode-plugin/mux0-status.js` — `chat.message` / `tool.execute.before` emit 附 `sessionTitle`
- `Resources/agent-hooks/tests/test_agent_hook.py` — read_ai_title / read_codex_title 测试
- `docs/agent-hooks.md` — 加「Session title」节
- `CLAUDE.md` — Directory Structure 加 `TerminalSessionTitleStore.swift`；Common Tasks 加「修改 tab 自动命名行为」
- `AGENTS.md` — Directory Structure 同步

**No-op:** `project.yml` 用 `path: mux0` glob，新增 Swift 文件由 `xcodegen generate` 自动捕获，不需要改。

---

## Task 1: HookMessage 加 sessionTitle 字段

**Files:**
- Modify: `mux0/Models/HookMessage.swift`
- Modify: `mux0Tests/HookMessageTests.swift`

- [ ] **Step 1: 读现有 HookMessageTests，添加失败测试**

打开 `mux0Tests/HookMessageTests.swift`，在文件末尾加：

```swift
func testDecodesSessionTitle() throws {
    let json = #"""
    {"terminalId":"\#(UUID().uuidString)","event":"running","agent":"claude","at":1.0,"sessionTitle":"Implement auto-naming"}
    """#
    let msg = try JSONDecoder().decode(HookMessage.self, from: Data(json.utf8))
    XCTAssertEqual(msg.sessionTitle, "Implement auto-naming")
}

func testSessionTitleMissingIsNil() throws {
    let json = #"""
    {"terminalId":"\#(UUID().uuidString)","event":"running","agent":"claude","at":1.0}
    """#
    let msg = try JSONDecoder().decode(HookMessage.self, from: Data(json.utf8))
    XCTAssertNil(msg.sessionTitle)
}
```

- [ ] **Step 2: 跑测试确认失败**

```bash
xcodebuild test -project mux0.xcodeproj -scheme mux0Tests -only-testing:mux0Tests/HookMessageTests/testDecodesSessionTitle 2>&1 | tail -20
```

Expected: 编译失败，"value of type 'HookMessage' has no member 'sessionTitle'"

- [ ] **Step 3: 在 HookMessage 加字段**

在 `mux0/Models/HookMessage.swift` 中，`resumeCommand` 字段之后插入：

```swift
    /// Optional human-readable session title — e.g. Claude's `ai-title`
    /// transcript entry, Codex's `threads.title` SQLite column, or
    /// OpenCode's `session.title`. Emitted alongside `running` / `stop`
    /// events. mux0 routes it into `TerminalSessionTitleStore`; empty
    /// strings are dropped to avoid clobbering an already-known title with
    /// a transient "title not yet generated" state.
    let sessionTitle: String?
```

`Decodable` 合成自动支持新字段。

- [ ] **Step 4: 跑测试确认通过**

```bash
xcodebuild test -project mux0.xcodeproj -scheme mux0Tests -only-testing:mux0Tests/HookMessageTests 2>&1 | tail -10
```

Expected: `** TEST SUCCEEDED **`，新两个 case 通过，老 case 不破。

- [ ] **Step 5: Commit**

```bash
git add mux0/Models/HookMessage.swift mux0Tests/HookMessageTests.swift
git commit -m "$(cat <<'EOF'
feat(models): add sessionTitle field to HookMessage

Wire-format extension that lets each agent hook attach the current
session's human-readable title alongside running/stop events.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: TerminalSessionTitleStore（@Observable + 持久化）

**Files:**
- Create: `mux0/Models/TerminalSessionTitleStore.swift`
- Create: `mux0Tests/TerminalSessionTitleStoreTests.swift`

- [ ] **Step 1: 写失败测试**

新建 `mux0Tests/TerminalSessionTitleStoreTests.swift`：

```swift
import XCTest
@testable import mux0

final class TerminalSessionTitleStoreTests: XCTestCase {

    func testDefaultIsEmpty() {
        let store = TerminalSessionTitleStore(persistenceKey: "test-\(UUID())")
        XCTAssertNil(store.title(for: UUID()))
    }

    func testUpdateStoresValue() {
        let store = TerminalSessionTitleStore(persistenceKey: "test-\(UUID())")
        let id = UUID()
        store.update(terminalId: id, title: "Hello")
        XCTAssertEqual(store.title(for: id), "Hello")
    }

    func testUpdateEmptyStringIsIgnored() {
        let store = TerminalSessionTitleStore(persistenceKey: "test-\(UUID())")
        let id = UUID()
        store.update(terminalId: id, title: "Real title")
        store.update(terminalId: id, title: "")
        XCTAssertEqual(store.title(for: id), "Real title")
    }

    func testUpdateWhitespaceOnlyIsIgnored() {
        let store = TerminalSessionTitleStore(persistenceKey: "test-\(UUID())")
        let id = UUID()
        store.update(terminalId: id, title: "Real")
        store.update(terminalId: id, title: "   \n")
        XCTAssertEqual(store.title(for: id), "Real")
    }

    func testClearRemovesValue() {
        let store = TerminalSessionTitleStore(persistenceKey: "test-\(UUID())")
        let id = UUID()
        store.update(terminalId: id, title: "X")
        store.clear(terminalId: id)
        XCTAssertNil(store.title(for: id))
    }

    func testClearMultipleRemovesAll() {
        let store = TerminalSessionTitleStore(persistenceKey: "test-\(UUID())")
        let a = UUID(); let b = UUID(); let c = UUID()
        store.update(terminalId: a, title: "A")
        store.update(terminalId: b, title: "B")
        store.update(terminalId: c, title: "C")
        store.clear(terminalIds: [a, c])
        XCTAssertNil(store.title(for: a))
        XCTAssertEqual(store.title(for: b), "B")
        XCTAssertNil(store.title(for: c))
    }

    func testPersistenceRoundtrip() {
        let key = "test-\(UUID())"
        let id = UUID()
        let store = TerminalSessionTitleStore(persistenceKey: key)
        store.update(terminalId: id, title: "Persisted")
        store.flushSaveForTesting()

        let store2 = TerminalSessionTitleStore(persistenceKey: key)
        XCTAssertEqual(store2.title(for: id), "Persisted")
        UserDefaults.standard.removeObject(forKey: key)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

```bash
xcodebuild test -project mux0.xcodeproj -scheme mux0Tests -only-testing:mux0Tests/TerminalSessionTitleStoreTests 2>&1 | tail -10
```

Expected: 编译失败，"cannot find 'TerminalSessionTitleStore' in scope"

- [ ] **Step 3: 创建 store 实现**

新建 `mux0/Models/TerminalSessionTitleStore.swift`：

```swift
import Foundation
import Observation

/// Per-terminal human-readable agent session title, keyed by terminal UUID.
/// Populated by `HookDispatcher` when an agent hook emits a `sessionTitle`
/// field; consumed by `TabItemView` via `TerminalTab.displayTitle(store:)`.
///
/// Persisted to UserDefaults under `mux0.sessionTitles.v1` so that on app
/// restart each tab can keep showing its previous title until the next hook
/// emit refreshes it. Writes are debounced (300 ms) to match `TerminalPwdStore`'s
/// pattern — title arrival typically happens once per turn, not per keystroke,
/// but keeping the same debouncer keeps both stores' UserDefaults patterns aligned.
@Observable
final class TerminalSessionTitleStore {
    private var storage: [String: String] = [:]
    private let persistenceKey: String
    private var saveWorkItem: DispatchWorkItem?

    init(persistenceKey: String = "mux0.sessionTitles.v1") {
        self.persistenceKey = persistenceKey
        load()
    }

    func title(for terminalId: UUID) -> String? {
        storage[terminalId.uuidString]
    }

    /// Write `title` for `terminalId`. Empty or whitespace-only inputs are
    /// dropped — agents emit empty strings before the LLM-generated title is
    /// materialized, and we don't want a transient empty state to wipe out
    /// the previously known title.
    func update(terminalId: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard storage[terminalId.uuidString] != trimmed else { return }
        storage[terminalId.uuidString] = trimmed
        scheduleSave()
    }

    func clear(terminalId: UUID) {
        guard storage.removeValue(forKey: terminalId.uuidString) != nil else { return }
        scheduleSave()
    }

    func clear(terminalIds: [UUID]) {
        var changed = false
        for id in terminalIds {
            if storage.removeValue(forKey: id.uuidString) != nil { changed = true }
        }
        if changed { scheduleSave() }
    }

    // MARK: - Persistence

    #if DEBUG
    func flushSaveForTesting() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        save()
    }
    #endif

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.save() }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(storage) else { return }
        UserDefaults.standard.set(data, forKey: persistenceKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return }
        storage = decoded
    }
}
```

- [ ] **Step 4: 重生成 Xcode 工程 + 跑测试**

```bash
xcodegen generate && xcodebuild test -project mux0.xcodeproj -scheme mux0Tests -only-testing:mux0Tests/TerminalSessionTitleStoreTests 2>&1 | tail -10
```

Expected: 所有 7 个 case 通过。

- [ ] **Step 5: Commit**

```bash
git add mux0/Models/TerminalSessionTitleStore.swift mux0Tests/TerminalSessionTitleStoreTests.swift
git commit -m "$(cat <<'EOF'
feat(models): add TerminalSessionTitleStore for per-terminal session titles

@Observable store keyed by terminal UUID with UserDefaults persistence,
mirroring TerminalPwdStore's shape. Empty/whitespace updates are dropped so
agent hooks can emit unconditionally without clobbering known titles.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: TerminalTab 加 userRenamed + displayTitle helper

**Files:**
- Modify: `mux0/Models/Workspace.swift`
- Create: `mux0Tests/TerminalTabDisplayTitleTests.swift`

- [ ] **Step 1: 写失败测试**

新建 `mux0Tests/TerminalTabDisplayTitleTests.swift`：

```swift
import XCTest
@testable import mux0

final class TerminalTabDisplayTitleTests: XCTestCase {

    private func makeStore() -> TerminalSessionTitleStore {
        TerminalSessionTitleStore(persistenceKey: "test-\(UUID())")
    }

    func testFallsBackToTabTitleWhenStoreEmpty() {
        let termId = UUID()
        var tab = TerminalTab(title: "Terminal 1", terminalId: termId)
        tab.focusedTerminalId = termId
        let store = makeStore()
        XCTAssertEqual(tab.displayTitle(sessionTitleStore: store), "Terminal 1")
    }

    func testUsesStoreTitleForFocusedTerminal() {
        let termId = UUID()
        var tab = TerminalTab(title: "claude", terminalId: termId)
        tab.focusedTerminalId = termId
        let store = makeStore()
        store.update(terminalId: termId, title: "Implement feature X")
        XCTAssertEqual(tab.displayTitle(sessionTitleStore: store), "Implement feature X")
    }

    func testUserRenamedOverridesStore() {
        let termId = UUID()
        var tab = TerminalTab(title: "My Tab", terminalId: termId)
        tab.focusedTerminalId = termId
        tab.userRenamed = true
        let store = makeStore()
        store.update(terminalId: termId, title: "Should not show")
        XCTAssertEqual(tab.displayTitle(sessionTitleStore: store), "My Tab")
    }

    func testTracksFocusedTerminalAcrossPanes() {
        // Two-pane tab: focus the second; only second's title should be used.
        let leftId = UUID()
        let rightId = UUID()
        var tab = TerminalTab(title: "split tab", terminalId: leftId)
        tab.layout = .split(UUID(), .vertical, 0.5,
                            .terminal(leftId), .terminal(rightId))
        tab.focusedTerminalId = rightId
        let store = makeStore()
        store.update(terminalId: leftId, title: "Left pane session")
        store.update(terminalId: rightId, title: "Right pane session")
        XCTAssertEqual(tab.displayTitle(sessionTitleStore: store), "Right pane session")
    }

    func testCodableDefaultsUserRenamedToFalse() throws {
        // Legacy tab data without `userRenamed` key must decode with default false.
        let json = #"""
        {"id":"\#(UUID().uuidString)","title":"old","layout":{"type":"terminal","terminalId":"\#(UUID().uuidString)"},"focusedTerminalId":"\#(UUID().uuidString)"}
        """#
        let tab = try JSONDecoder().decode(TerminalTab.self, from: Data(json.utf8))
        XCTAssertFalse(tab.userRenamed)
    }

    func testCodableRoundtripPreservesUserRenamed() throws {
        let termId = UUID()
        var tab = TerminalTab(title: "X", terminalId: termId)
        tab.userRenamed = true
        let data = try JSONEncoder().encode(tab)
        let decoded = try JSONDecoder().decode(TerminalTab.self, from: data)
        XCTAssertTrue(decoded.userRenamed)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

```bash
xcodebuild test -project mux0.xcodeproj -scheme mux0Tests -only-testing:mux0Tests/TerminalTabDisplayTitleTests 2>&1 | tail -10
```

Expected: 编译失败，提示 `userRenamed` / `displayTitle` 未定义。

- [ ] **Step 3: 修改 TerminalTab**

打开 `mux0/Models/Workspace.swift`，替换 `TerminalTab` 整个 struct 为：

```swift
struct TerminalTab: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var layout: SplitNode
    var focusedTerminalId: UUID
    /// Quick Action binding for this tab. nil = ordinary terminal tab.
    /// Non-nil values match either a `BuiltinQuickAction.id` (e.g.
    /// `"gitui"`, `"claude"`) or a custom action's UUID. When the tab's
    /// first terminal opens, `TabContentView.resolvedStartupCommand` resolves
    /// this id via `QuickActionsStore.command(for:)` and injects the result
    /// as the surface's initial_input.
    var quickActionId: String? = nil
    /// True once the user has manually renamed this tab (inline rename UI).
    /// When true, `displayTitle` returns `title` unconditionally — auto
    /// session titles from `TerminalSessionTitleStore` are ignored. Reset
    /// via `WorkspaceStore.resetTabToAutoTitle` (right-click → "Reset to
    /// auto title"). Defaults to false; old persisted data without this
    /// field decodes as false (legacy tabs re-enter auto mode).
    var userRenamed: Bool = false

    init(id: UUID = UUID(), title: String, terminalId: UUID = UUID(),
         quickActionId: String? = nil, userRenamed: Bool = false) {
        self.id = id
        self.title = title
        self.layout = .terminal(terminalId)
        self.focusedTerminalId = terminalId
        self.quickActionId = quickActionId
        self.userRenamed = userRenamed
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, layout, focusedTerminalId, quickActionId, userRenamed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.layout = try c.decode(SplitNode.self, forKey: .layout)
        self.focusedTerminalId = try c.decode(UUID.self, forKey: .focusedTerminalId)
        self.quickActionId = try c.decodeIfPresent(String.self, forKey: .quickActionId)
        self.userRenamed = try c.decodeIfPresent(Bool.self, forKey: .userRenamed) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(layout, forKey: .layout)
        try c.encode(focusedTerminalId, forKey: .focusedTerminalId)
        try c.encodeIfPresent(quickActionId, forKey: .quickActionId)
        try c.encode(userRenamed, forKey: .userRenamed)
    }

    /// Resolve the title shown in the tab bar. Priority:
    /// 1. User manually renamed → `title` (hard lock, ignores store)
    /// 2. `sessionTitleStore[focusedTerminalId]` is non-nil → that
    /// 3. Fallback → `title` (creation-time default like "Terminal 1" /
    ///    quick action displayName)
    ///
    /// Tracks the focused pane, so split tabs switch label as the user
    /// moves focus between panes. Shell pane (no agent session) falls
    /// through to step 3 rather than retaining the previous agent pane's title.
    func displayTitle(sessionTitleStore: TerminalSessionTitleStore) -> String {
        if userRenamed { return title }
        if let auto = sessionTitleStore.title(for: focusedTerminalId), !auto.isEmpty {
            return auto
        }
        return title
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

```bash
xcodebuild test -project mux0.xcodeproj -scheme mux0Tests -only-testing:mux0Tests/TerminalTabDisplayTitleTests 2>&1 | tail -10
```

Expected: 全部 6 case 通过。

- [ ] **Step 5: Commit**

```bash
git add mux0/Models/Workspace.swift mux0Tests/TerminalTabDisplayTitleTests.swift
git commit -m "$(cat <<'EOF'
feat(models): add userRenamed lock + displayTitle helper to TerminalTab

userRenamed=true permanently locks the tab to its user-given title;
displayTitle falls back through store→tab.title so unlock + agent-driven
auto-naming work uniformly. Codable migration: legacy tabs decode with
userRenamed=false.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: HookDispatcher 路由 sessionTitle

**Files:**
- Modify: `mux0/Models/HookDispatcher.swift`
- Create: `mux0Tests/HookDispatcherSessionTitleTests.swift`

- [ ] **Step 1: 写失败测试**

新建 `mux0Tests/HookDispatcherSessionTitleTests.swift`（沿用 `HookDispatcherTests` 的 JSON-roundtrip 构造 + tmp file SettingsConfigStore 模式）：

```swift
import XCTest
@testable import mux0

final class HookDispatcherSessionTitleTests: XCTestCase {

    private var tmpConfigPath: String!
    private var settings: SettingsConfigStore!
    private var statusStore: TerminalStatusStore!
    private var titleStore: TerminalSessionTitleStore!
    private let tid = UUID()

    override func setUpWithError() throws {
        tmpConfigPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("mux0-dispatch-\(UUID().uuidString).conf").path
        settings = SettingsConfigStore(filePath: tmpConfigPath)
        statusStore = TerminalStatusStore()
        titleStore = TerminalSessionTitleStore(persistenceKey: "test-\(UUID())")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: tmpConfigPath)
    }

    private func makeMsg(sessionTitle: String?) -> HookMessage {
        var fields = #"{"terminalId":"\#(tid.uuidString)","event":"running","agent":"claude","at":1.0"#
        if let t = sessionTitle {
            // JSON-escape minimally — tests use plain ASCII titles.
            fields += #","sessionTitle":"\#(t)""#
        }
        fields += "}"
        return try! JSONDecoder().decode(HookMessage.self, from: Data(fields.utf8))
    }

    func testRoutesSessionTitleWhenAgentEnabled() {
        settings.set(HookMessage.Agent.claude.settingsKey, "true")
        settings.save()
        HookDispatcher.dispatch(makeMsg(sessionTitle: "Doing the thing"),
                                settings: settings, store: statusStore,
                                sessionTitleStore: titleStore)
        XCTAssertEqual(titleStore.title(for: tid), "Doing the thing")
    }

    func testRoutesSessionTitleEvenWhenStatusAgentDisabled() {
        // Title is independent of the per-agent "status notifications" toggle —
        // tab naming is unconditional once the field arrives.
        // (No settings.set — agent NOT enabled.)
        HookDispatcher.dispatch(makeMsg(sessionTitle: "Still applies"),
                                settings: settings, store: statusStore,
                                sessionTitleStore: titleStore)
        XCTAssertEqual(titleStore.title(for: tid), "Still applies")
    }

    func testSkipsWhenSessionTitleNil() {
        settings.set(HookMessage.Agent.claude.settingsKey, "true")
        settings.save()
        titleStore.update(terminalId: tid, title: "Previous")
        HookDispatcher.dispatch(makeMsg(sessionTitle: nil),
                                settings: settings, store: statusStore,
                                sessionTitleStore: titleStore)
        XCTAssertEqual(titleStore.title(for: tid), "Previous",
                       "nil sessionTitle should not clobber existing value")
    }
}
```

> Note: 使用 JSON-roundtrip 构造 `HookMessage` 与现有 `HookDispatcherTests.makeMsg(...)` 模式一致 —— 不依赖 synthesized memberwise init（安全），也保证 Decodable 字段路径被实际测试到。

- [ ] **Step 2: 跑测试确认失败**

```bash
xcodebuild test -project mux0.xcodeproj -scheme mux0Tests -only-testing:mux0Tests/HookDispatcherSessionTitleTests 2>&1 | tail -15
```

Expected: 编译失败，"missing argument 'sessionTitleStore' in call" 或 "extra argument 'sessionTitleStore' in call"

- [ ] **Step 3: 修改 HookDispatcher**

打开 `mux0/Models/HookDispatcher.swift`，把 `dispatch` 签名改为：

```swift
    static func dispatch(_ msg: HookMessage,
                         settings: SettingsConfigStore,
                         store: TerminalStatusStore,
                         workspaceStore: WorkspaceStore? = nil,
                         sessionTitleStore: TerminalSessionTitleStore? = nil) {
        // Session title is independent of status / resume gating — once any
        // agent hook emits it, the tab name follows. Title-only tabs (user
        // disabled notifications but still wants auto-naming) are a real use
        // case; we don't second-guess.
        if let title = msg.sessionTitle, let titleStore = sessionTitleStore {
            titleStore.update(terminalId: msg.terminalId, title: title)
        }

        // (Existing resumeCommand block — keep unchanged)
        if let cmd = msg.resumeCommand, let ws = workspaceStore,
           settings.get(msg.agent.resumeSettingsKey) == "true" {
            ws.recordResumeCommand(terminalId: msg.terminalId, command: cmd)
        }
        guard settings.get(msg.agent.settingsKey) == "true" else { return }
        // ... rest unchanged
```

确保参数顺序与现有调用方兼容（`workspaceStore` 之后加可选 `sessionTitleStore`，调用方按需透传）。

- [ ] **Step 4: 跑测试确认通过**

```bash
xcodebuild test -project mux0.xcodeproj -scheme mux0Tests -only-testing:mux0Tests/HookDispatcherSessionTitleTests 2>&1 | tail -10
```

Expected: 3 case 全过。同时确认旧的 `HookDispatcherTests` 仍通过：

```bash
xcodebuild test -project mux0.xcodeproj -scheme mux0Tests -only-testing:mux0Tests/HookDispatcherTests 2>&1 | tail -10
```

- [ ] **Step 5: Commit**

```bash
git add mux0/Models/HookDispatcher.swift mux0Tests/HookDispatcherSessionTitleTests.swift
git commit -m "$(cat <<'EOF'
feat(models): route HookMessage.sessionTitle into TerminalSessionTitleStore

New optional `sessionTitleStore` arg on dispatch — gated independently
from the per-agent status toggle so title-only mode works.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: WorkspaceStore — rename 设锁定 + reset 解锁 + 清理 store

**Files:**
- Modify: `mux0/Models/WorkspaceStore.swift`
- Modify or Create: `mux0Tests/WorkspaceStoreTests.swift`

- [ ] **Step 1: 写失败测试**

如果 `mux0Tests/WorkspaceStoreTests.swift` 不存在则创建；否则在末尾追加。完整文件内容（如新建）：

```swift
import XCTest
@testable import mux0

final class WorkspaceStoreRenameLockTests: XCTestCase {

    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(persistenceKey: "test-\(UUID())")
    }

    func testRenameTabSetsUserRenamedTrue() {
        let ws = makeStore()
        let wsId = ws.workspaces[0].id
        let (tabId, _) = ws.addTab(to: wsId)!
        ws.renameTab(id: tabId, in: wsId, to: "My Custom Name")
        let tab = ws.workspaces[0].tabs.first { $0.id == tabId }!
        XCTAssertEqual(tab.title, "My Custom Name")
        XCTAssertTrue(tab.userRenamed)
    }

    func testResetTabToAutoTitleClearsLock() {
        let ws = makeStore()
        let wsId = ws.workspaces[0].id
        let (tabId, _) = ws.addTab(to: wsId)!
        ws.renameTab(id: tabId, in: wsId, to: "Locked")
        ws.resetTabToAutoTitle(tabId: tabId, in: wsId)
        let tab = ws.workspaces[0].tabs.first { $0.id == tabId }!
        XCTAssertFalse(tab.userRenamed)
        // title field unchanged — fallback path will continue to show it
        // until next hook emit overrides via the store.
        XCTAssertEqual(tab.title, "Locked")
    }

    func testCloseTerminalClearsSessionTitleStore() {
        let ws = makeStore()
        let titleStore = TerminalSessionTitleStore(persistenceKey: "test-\(UUID())")
        ws.sessionTitleStore = titleStore
        let wsId = ws.workspaces[0].id
        let (tabId, termId) = ws.addTab(to: wsId)!
        // Split so close doesn't auto-remove the tab.
        let newTermId = ws.splitTerminal(id: termId, in: wsId, tabId: tabId,
                                         direction: .vertical)!
        titleStore.update(terminalId: termId, title: "Left")
        titleStore.update(terminalId: newTermId, title: "Right")
        ws.closeTerminal(id: termId, in: wsId, tabId: tabId)
        XCTAssertNil(titleStore.title(for: termId))
        XCTAssertEqual(titleStore.title(for: newTermId), "Right")
    }

    func testRemoveTabClearsAllItsTerminalsInStore() {
        let ws = makeStore()
        let titleStore = TerminalSessionTitleStore(persistenceKey: "test-\(UUID())")
        ws.sessionTitleStore = titleStore
        let wsId = ws.workspaces[0].id
        let (tabId, termId) = ws.addTab(to: wsId)!
        let split2 = ws.splitTerminal(id: termId, in: wsId, tabId: tabId,
                                       direction: .horizontal)!
        titleStore.update(terminalId: termId, title: "A")
        titleStore.update(terminalId: split2, title: "B")
        ws.removeTab(id: tabId, from: wsId)
        XCTAssertNil(titleStore.title(for: termId))
        XCTAssertNil(titleStore.title(for: split2))
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

```bash
xcodebuild test -project mux0.xcodeproj -scheme mux0Tests -only-testing:mux0Tests/WorkspaceStoreRenameLockTests 2>&1 | tail -15
```

Expected: 编译失败，"value of type 'WorkspaceStore' has no member 'resetTabToAutoTitle'" 等。

- [ ] **Step 3: 修改 WorkspaceStore**

打开 `mux0/Models/WorkspaceStore.swift`：

**(a)** 在 class 顶部字段加：

```swift
    /// Optional weak link to the session title store so close/remove paths
    /// can purge stale terminalId → title mappings. Wired by `ContentView`
    /// at app startup. Optional + weak-style (held strong here, but set
    /// post-init) so unit tests can construct a store without the title
    /// store; production injection is guaranteed.
    weak var sessionTitleStore: TerminalSessionTitleStore?
```

> Reason for `weak`: matches the live-injection pattern used by `pwdStoreRef` in `TabContentView`; lets tests omit the store without ARC retain cycles. The `TerminalSessionTitleStore` is owned by `ContentView` for the app's lifetime, so `weak` is safe.

**(b)** 修改 `renameTab` —— 在 title 赋值后加 `userRenamed = true`：

```swift
    func renameTab(id: UUID, in workspaceId: UUID, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let wsIdx = wsIndex(workspaceId),
              let tIdx = tabIndex(id, in: wsIdx) else { return }
        // Always set userRenamed=true (even if title unchanged) — the user
        // explicitly hit enter on the rename UI, signaling intent to lock.
        var changed = false
        if workspaces[wsIdx].tabs[tIdx].title != trimmed {
            workspaces[wsIdx].tabs[tIdx].title = trimmed
            changed = true
        }
        if !workspaces[wsIdx].tabs[tIdx].userRenamed {
            workspaces[wsIdx].tabs[tIdx].userRenamed = true
            changed = true
        }
        if changed { save() }
    }
```

**(c)** 加 `resetTabToAutoTitle`（紧挨 `renameTab` 后面）：

```swift
    /// Clear the manual-rename lock on a tab. After this, the tab falls
    /// back to the auto title chain (`TerminalSessionTitleStore[focused]`
    /// → tab.title). `title` itself is left as-is; next agent hook emit
    /// will overwrite the displayed value via the store.
    func resetTabToAutoTitle(tabId: UUID, in workspaceId: UUID) {
        guard let wsIdx = wsIndex(workspaceId),
              let tIdx = tabIndex(tabId, in: wsIdx),
              workspaces[wsIdx].tabs[tIdx].userRenamed else { return }
        workspaces[wsIdx].tabs[tIdx].userRenamed = false
        save()
    }
```

**(d)** `closeTerminal` 末尾在 `save()` 之前调 `sessionTitleStore?.clear(terminalId:)`：

```swift
    func closeTerminal(id terminalId: UUID, in workspaceId: UUID, tabId: UUID) {
        guard let wsIdx = wsIndex(workspaceId),
              let tIdx = tabIndex(tabId, in: wsIdx) else { return }
        let tab = workspaces[wsIdx].tabs[tIdx]
        if let newLayout = tab.layout.removing(terminalId: terminalId) {
            workspaces[wsIdx].tabs[tIdx].layout = newLayout
            workspaces[wsIdx].pendingPrefills.removeValue(forKey: terminalId.uuidString)
            sessionTitleStore?.clear(terminalId: terminalId)
            if tab.focusedTerminalId == terminalId {
                workspaces[wsIdx].tabs[tIdx].focusedTerminalId =
                    newLayout.allTerminalIds()[0]
            }
            save()
        } else {
            removeTab(id: tabId, from: workspaceId)
        }
    }
```

**(e)** `removeTab` 在 pendingPrefills 清理后加 sessionTitleStore 清理：

```swift
    func removeTab(id: UUID, from workspaceId: UUID) {
        guard let wsIdx = wsIndex(workspaceId) else { return }
        let closedIdx = workspaces[wsIdx].tabs.firstIndex(where: { $0.id == id })
        if let tIdx = closedIdx {
            let leafIds = workspaces[wsIdx].tabs[tIdx].layout.allTerminalIds()
            for tid in leafIds {
                workspaces[wsIdx].pendingPrefills.removeValue(forKey: tid.uuidString)
            }
            sessionTitleStore?.clear(terminalIds: leafIds)
        }
        // ... rest unchanged
```

**(f)** `deleteWorkspace` 顶部加：

```swift
    func deleteWorkspace(id: UUID) {
        if let wsIdx = wsIndex(id) {
            let allLeaves = workspaces[wsIdx].tabs.flatMap { $0.layout.allTerminalIds() }
            sessionTitleStore?.clear(terminalIds: allLeaves)
        }
        workspaces.removeAll { $0.id == id }
        if selectedId == id { selectedId = workspaces.first?.id }
        save()
    }
```

- [ ] **Step 4: 跑测试确认通过**

```bash
xcodebuild test -project mux0.xcodeproj -scheme mux0Tests -only-testing:mux0Tests/WorkspaceStoreRenameLockTests 2>&1 | tail -15
```

Expected: 4 case 全过。再跑全套 `mux0Tests` 确认没有回归：

```bash
xcodebuild test -project mux0.xcodeproj -scheme mux0Tests 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add mux0/Models/WorkspaceStore.swift mux0Tests/WorkspaceStoreTests.swift
git commit -m "$(cat <<'EOF'
feat(models): wire WorkspaceStore to TerminalSessionTitleStore lifecycle

renameTab now flips userRenamed=true; resetTabToAutoTitle clears it.
closeTerminal/removeTab/deleteWorkspace purge stale terminalId entries
from the session title store, mirroring pendingPrefills cleanup.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: agent-hook.py — Claude ai-title + Codex SQLite

**Files:**
- Modify: `Resources/agent-hooks/agent-hook.py`
- Modify: `Resources/agent-hooks/tests/test_agent_hook.py`

- [ ] **Step 1: 写失败测试**

在 `Resources/agent-hooks/tests/test_agent_hook.py` 末尾追加：

```python
# ---------- read_ai_title ----------

def test_read_ai_title_picks_last(tmp_path):
    p = tmp_path / "t.jsonl"
    p.write_text(
        json.dumps({"type": "ai-title", "aiTitle": "Old title"}) + "\n" +
        json.dumps({"type": "user", "content": "noise"}) + "\n" +
        json.dumps({"type": "ai-title", "aiTitle": "Latest title"}) + "\n"
    )
    assert agent_hook.read_ai_title(str(p)) == "Latest title"


def test_read_ai_title_truncates_to_200(tmp_path):
    p = tmp_path / "t.jsonl"
    long = "x" * 500
    p.write_text(json.dumps({"type": "ai-title", "aiTitle": long}) + "\n")
    assert len(agent_hook.read_ai_title(str(p))) == 200


def test_read_ai_title_missing_file():
    assert agent_hook.read_ai_title("/nonexistent/path.jsonl") == ""


def test_read_ai_title_no_match(tmp_path):
    p = tmp_path / "t.jsonl"
    p.write_text(json.dumps({"type": "user", "content": "x"}) + "\n")
    assert agent_hook.read_ai_title(str(p)) == ""


def test_read_ai_title_skips_malformed_lines(tmp_path):
    p = tmp_path / "t.jsonl"
    p.write_text(
        "not json\n" +
        json.dumps({"type": "ai-title", "aiTitle": "Good"}) + "\n"
    )
    assert agent_hook.read_ai_title(str(p)) == "Good"


# ---------- read_codex_title ----------

def test_read_codex_title_reads_from_db(tmp_path, monkeypatch):
    import sqlite3
    db = tmp_path / "state_5.sqlite"
    con = sqlite3.connect(db)
    con.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT)")
    con.execute("INSERT INTO threads VALUES (?, ?)",
                ("abc-123", "Codex session name"))
    con.commit()
    con.close()
    monkeypatch.setattr(agent_hook, "CODEX_HOME", tmp_path)
    assert agent_hook.read_codex_title("abc-123") == "Codex session name"


def test_read_codex_title_picks_newest_schema(tmp_path, monkeypatch):
    import sqlite3
    # Two DB schema versions; we should query state_99 (newest).
    for ver, title in [(3, "Old"), (99, "New")]:
        db = tmp_path / f"state_{ver}.sqlite"
        con = sqlite3.connect(db)
        con.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT)")
        con.execute("INSERT INTO threads VALUES (?, ?)", ("sid", title))
        con.commit()
        con.close()
    monkeypatch.setattr(agent_hook, "CODEX_HOME", tmp_path)
    assert agent_hook.read_codex_title("sid") == "New"


def test_read_codex_title_no_db(tmp_path, monkeypatch):
    monkeypatch.setattr(agent_hook, "CODEX_HOME", tmp_path)
    assert agent_hook.read_codex_title("sid") == ""


def test_read_codex_title_rejects_invalid_session_id(tmp_path, monkeypatch):
    monkeypatch.setattr(agent_hook, "CODEX_HOME", tmp_path)
    assert agent_hook.read_codex_title("bad; DROP TABLE") == ""


def test_read_codex_title_truncates_to_200(tmp_path, monkeypatch):
    import sqlite3
    db = tmp_path / "state_5.sqlite"
    con = sqlite3.connect(db)
    con.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT)")
    con.execute("INSERT INTO threads VALUES (?, ?)", ("sid", "x" * 500))
    con.commit()
    con.close()
    monkeypatch.setattr(agent_hook, "CODEX_HOME", tmp_path)
    assert len(agent_hook.read_codex_title("sid")) == 200


# ---------- dispatch sessionTitle attachment ----------

def test_dispatch_claude_prompt_attaches_session_title(tmp_path):
    sf = tmp_path / "sessions.json"
    transcript = tmp_path / "t.jsonl"
    transcript.write_text(
        json.dumps({"type": "ai-title", "aiTitle": "My session"}) + "\n"
    )
    emit = agent_hook.dispatch("prompt", "claude",
                                {"session_id": "s1",
                                 "transcript_path": str(transcript)},
                                "term1", sf, 1.0)
    assert emit.get("sessionTitle") == "My session"


def test_dispatch_codex_prompt_attaches_session_title(tmp_path, monkeypatch):
    import sqlite3
    db = tmp_path / "state_5.sqlite"
    con = sqlite3.connect(db)
    con.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT)")
    con.execute("INSERT INTO threads VALUES (?, ?)", ("cdx-1", "Codex name"))
    con.commit()
    con.close()
    monkeypatch.setattr(agent_hook, "CODEX_HOME", tmp_path)
    sf = tmp_path / "sessions.json"
    emit = agent_hook.dispatch("prompt", "codex",
                                {"session_id": "cdx-1"},
                                "term-c", sf, 1.0)
    assert emit.get("sessionTitle") == "Codex name"


def test_dispatch_no_session_title_when_empty(tmp_path):
    sf = tmp_path / "sessions.json"
    # No transcript_path → read_ai_title returns ""
    emit = agent_hook.dispatch("prompt", "claude",
                                {"session_id": "s1"},
                                "term1", sf, 1.0)
    assert "sessionTitle" not in emit
```

- [ ] **Step 2: 跑测试确认失败**

```bash
python3 -m pytest Resources/agent-hooks/tests/test_agent_hook.py -v 2>&1 | tail -30
```

Expected: 多个 `AttributeError: module 'agent_hook' has no attribute 'read_ai_title'` 等。

- [ ] **Step 3: 修改 agent-hook.py**

在 `Resources/agent-hooks/agent-hook.py` 顶部 imports 之后加：

```python
CODEX_HOME = pathlib.Path("~/.codex").expanduser()
```

在 `read_transcript_summary` 之后插入：

```python
def read_ai_title(path: str) -> str:
    """Read Claude transcript JSONL, return last `{"type":"ai-title","aiTitle":"..."}`
    entry's title, truncated to SUMMARY_MAXLEN. Empty string on any error.

    Claude Code persists an LLM-generated session title as repeated `ai-title`
    rows throughout the transcript (typically same value each time once
    generated). We reverse-scan and return the most recent one to pick up
    title rewrites if any.
    """
    if not path:
        return ""
    try:
        with open(path) as f:
            lines = f.readlines()
    except (FileNotFoundError, IsADirectoryError, PermissionError, OSError):
        return ""
    for line in reversed(lines):
        try:
            d = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(d, dict) and d.get("type") == "ai-title":
            title = d.get("aiTitle") or ""
            if isinstance(title, str) and title:
                return title[:SUMMARY_MAXLEN]
    return ""


def read_codex_title(session_id: str) -> str:
    """Read Codex thread title from `~/.codex/state_*.sqlite` (newest schema
    version), querying `threads.title WHERE id = ?`. Empty on any failure.

    The `state_N.sqlite` filename embeds Codex's schema version (currently 5);
    we glob and take the highest N so this survives future migrations without
    a code change.
    """
    if not session_id or not SESSION_ID_RE.match(session_id):
        return ""
    candidates = sorted(CODEX_HOME.glob("state_*.sqlite"))
    if not candidates:
        return ""
    db = candidates[-1]
    try:
        import sqlite3
        # mode=ro + small timeout so we never block on Codex's write lock.
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=0.5)
        try:
            row = con.execute(
                "SELECT title FROM threads WHERE id = ?", (session_id,)
            ).fetchone()
        finally:
            con.close()
    except sqlite3.Error:
        return ""
    if not row or not row[0]:
        return ""
    return str(row[0])[:SUMMARY_MAXLEN]
```

在 `dispatch` 的 `prompt` 分支末尾（`resume = ...` 之前或之后均可），attach sessionTitle：

```python
    if subcmd == "prompt":
        entry["turnStartedAt"] = now
        entry["turnHadError"] = False
        entry["currentToolName"] = None
        entry["currentToolDetail"] = None
        tp = payload.get("transcript_path")
        if tp:
            entry["transcriptPath"] = tp
        emit = {"event": "running", "at": now}
        resume = resume_command_for(agent, str(session_id))
        if resume:
            emit["resumeCommand"] = resume
        title = _session_title_for(agent, entry.get("transcriptPath"), str(session_id))
        if title:
            emit["sessionTitle"] = title
```

在 `dispatch` 的 `stop` 分支同样附加：

```python
    elif subcmd == "stop":
        exit_code = 1 if entry.get("turnHadError") else 0
        summary = read_transcript_summary(entry.get("transcriptPath") or "")
        emit = {"event": "finished", "at": now, "exitCode": exit_code}
        if summary:
            emit["summary"] = summary
        title = _session_title_for(agent, entry.get("transcriptPath"), str(session_id))
        if title:
            emit["sessionTitle"] = title
        entries.pop(session_id, None)
```

在文件靠近 `dispatch` 上方加：

```python
def _session_title_for(agent: str, transcript_path: str, session_id: str) -> str:
    """Read the human-readable session title for `agent`. Returns "" if not
    available (LLM hasn't generated it yet, file missing, etc.)."""
    if agent == "claude":
        return read_ai_title(transcript_path or "")
    if agent == "codex":
        return read_codex_title(session_id)
    return ""   # opencode flows through its own JS plugin; never reaches here
```

- [ ] **Step 4: 跑测试确认通过**

```bash
python3 -m pytest Resources/agent-hooks/tests/test_agent_hook.py -v 2>&1 | tail -30
```

Expected: 全部新增 case + 原有 case 全过。

- [ ] **Step 5: Commit**

```bash
git add Resources/agent-hooks/agent-hook.py Resources/agent-hooks/tests/test_agent_hook.py
git commit -m "$(cat <<'EOF'
feat(agent-hooks): emit sessionTitle from Claude transcript + Codex DB

Claude: scan transcript JSONL backwards for last {"type":"ai-title"}.
Codex: query ~/.codex/state_*.sqlite (newest schema) threads.title.
Attached to prompt/stop emits; empty values are dropped.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: opencode plugin — attach sessionTitle

**Files:**
- Modify: `Resources/agent-hooks/opencode-plugin/mux0-status.js`

> No JS unit tests in repo for this plugin — we rely on smoke testing in Task 12. Keep the change small.

- [ ] **Step 1: 改 chat.message + tool.execute.before**

在 `Resources/agent-hooks/opencode-plugin/mux0-status.js`，先看 chat.message 的 input shape。opencode plugin 调用方传 `input` 含 `sessionID` 与（可能的）`session` 对象。修改两处 emit：

`chat.message` block 改为：

```javascript
    "chat.message": async (input, _output) => {
        if (!turn.startedAt) turn.startedAt = Date.now() / 1000;
        const resumeCommand = resumeCommandFor(input?.sessionID);
        const sessionTitle = input?.session?.title || "";
        const payload = { event: "running" };
        if (resumeCommand) payload.resumeCommand = resumeCommand;
        if (sessionTitle) payload.sessionTitle = sessionTitle;
        emit(payload);
    },
```

`tool.execute.before` block 改为：

```javascript
    "tool.execute.before": async (input, output) => {
        turn.tool = input?.tool;
        if (!turn.startedAt) turn.startedAt = Date.now() / 1000;
        const detail = describeOpencodeTool(input?.tool, output?.args);
        const resumeCommand = resumeCommandFor(input?.sessionID);
        const sessionTitle = input?.session?.title || "";
        const payload = { event: "running" };
        if (detail) payload.toolDetail = detail;
        if (resumeCommand) payload.resumeCommand = resumeCommand;
        if (sessionTitle) payload.sessionTitle = sessionTitle;
        emit(payload);
    },
```

> **Fallback if `input.session` is not exposed by the plugin runtime:** read from `~/.local/share/opencode/storage/session/<projectHash>/<sessionId>.json`. To find the projectHash without globbing, walk up from `cwd` to discover the opencode project root, or just glob — performance is fine, file is tiny. Reserve this fallback for Task 12 smoke test; first try the inline `input.session.title` path which is simpler.

- [ ] **Step 2: 手动 smoke test 准备**

无 unit test 阶段；下一步在 Task 12 手动验证。

- [ ] **Step 3: Commit**

```bash
git add Resources/agent-hooks/opencode-plugin/mux0-status.js
git commit -m "$(cat <<'EOF'
feat(agent-hooks): attach sessionTitle from opencode session in chat/tool emits

OpenCode plugin API surfaces session.title on chat.message and
tool.execute.before inputs; forward to the socket so mux0 can name the
tab the same way Claude/Codex do.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: ContentView 实例化 store + 注入 dispatcher

**Files:**
- Modify: `mux0/ContentView.swift`

- [ ] **Step 1: 加 store 字段**

打开 `mux0/ContentView.swift`。在 line 7 (`@State private var pwdStore = TerminalPwdStore()`) 之后插入：

```swift
    @State private var sessionTitleStore = TerminalSessionTitleStore()
```

- [ ] **Step 2: 注入 WorkspaceStore**

ContentView 中 `@State private var store = WorkspaceStore()`（line 5）是 WorkspaceStore 引用，参数名一律叫 `store`。在 ContentView body 的外层 `.task` / `.onAppear` 块中加（如已有 onAppear 用之，否则在最外层 view 末尾追加）：

```swift
        .onAppear {
            store.sessionTitleStore = sessionTitleStore
        }
```

- [ ] **Step 3: 调用 dispatcher 时透传**

定位到 line 196-201（hook listener `onMessage` 注册）。在 closure 内的 dispatch 调用上方加一行 capture：

```swift
                    let sessionTitleStoreRef = self.sessionTitleStore
```

然后修改 dispatch 调用：

```swift
                    listener.onMessage = { msg in
                        HookDispatcher.dispatch(msg,
                                                settings: settingsStoreRef,
                                                store: store,
                                                workspaceStore: workspaceStoreRef,
                                                sessionTitleStore: sessionTitleStoreRef)
                    }
```

- [ ] **Step 4: 把 sessionTitleStore 透传给 TabBridge**

ContentView line ~64-65 构造 `TabBridge(...)`，已有 `statusStore: statusStore, pwdStore: pwdStore`。在 `pwdStore:` 行下面加：

```swift
                        sessionTitleStore: sessionTitleStore,
```

（同样在 line ~80-81 第二处 TabBridge 构造也加）。

- [ ] **Step 5: Defer commit to Task 9**

不单独 commit，因为编译需要 Task 9 的 TabBridge 改动配套。先继续 Task 9。

---

## Task 9: TabBridge / TabContentView 透传 sessionTitleStore

**Files:**
- Modify: `mux0/Bridge/TabBridge.swift`
- Modify: `mux0/TabContent/TabContentView.swift`
- Modify: `mux0/ContentView.swift`（commit 在此处一起做）

- [ ] **Step 1: TabBridge 加字段 + 透传**

打开 `mux0/Bridge/TabBridge.swift`，在 `@Bindable var pwdStore: TerminalPwdStore` 下面加：

```swift
    @Bindable var sessionTitleStore: TerminalSessionTitleStore
```

在 `makeNSView` 和 `updateNSView` 把 `nsView.sessionTitleStore = sessionTitleStore` 加上（紧挨 `pwdStore` 那行下面）。

- [ ] **Step 2: TabContentView 加字段 + 透传到 TabBarView**

打开 `mux0/TabContent/TabContentView.swift`，在 `var pwdStore: TerminalPwdStore?` 下面加：

```swift
    var sessionTitleStore: TerminalSessionTitleStore?
```

找到 `loadWorkspace(...)` 内部所有调 `tabBar.update(tabs:selectedTabId:theme:...)` 的地方，把 `sessionTitleStore: sessionTitleStore` 也透传过去（Task 10 加 TabBarView 参数）。

- [ ] **Step 3: 编译占位**

```bash
xcodebuild build -project mux0.xcodeproj -scheme mux0 -configuration Debug 2>&1 | tail -20
```

Expected: 暂时编译失败（TabBarView 还没收 sessionTitleStore 参数）。继续 Task 10。

---

## Task 10: TabBarView 渲染 displayTitle + Reset 菜单项

**Files:**
- Modify: `mux0/TabContent/TabBarView.swift`
- Modify: `mux0/Localization/Localizable.xcstrings`
- Modify: `mux0/Localization/L10n.swift`

- [ ] **Step 1: 加 L10n 常量**

打开 `mux0/Localization/L10n.swift`，找到 `Tab` 命名空间（或 `tab.row.*` 集中处），加：

```swift
        static let resetAutoTitle = LocalizedStringResource("tab.row.resetAutoTitle")
```

打开 `mux0/Localization/Localizable.xcstrings`，加新键。可以用 grep 找到现有 `tab.row.rename` 条目对照格式，模仿插一条 `tab.row.resetAutoTitle`：
- en source: "Reset to auto title"
- zh-Hans: "重置为自动标题"

如果 .xcstrings 文件难手编，运行下面的 Python 脚本 patch（保险）：

```bash
python3 <<'PY'
import json, pathlib
p = pathlib.Path("mux0/Localization/Localizable.xcstrings")
doc = json.loads(p.read_text())
doc.setdefault("strings", {})["tab.row.resetAutoTitle"] = {
    "extractionState": "manual",
    "localizations": {
        "en": {"stringUnit": {"state": "translated", "value": "Reset to auto title"}},
        "zh-Hans": {"stringUnit": {"state": "translated", "value": "重置为自动标题"}},
    }
}
p.write_text(json.dumps(doc, indent=2, ensure_ascii=False))
PY
```

- [ ] **Step 2: TabBarView.update 加参数 + 透传**

打开 `mux0/TabContent/TabBarView.swift`：

`update(...)` 函数签名加参数：

```swift
    func update(tabs: [TerminalTab],
                selectedTabId: UUID?,
                theme: AppTheme,
                statuses: [UUID: TerminalStatus] = [:],
                sessionTitles: [UUID: String] = [:],
                backgroundOpacity: CGFloat = 1.0,
                showStatusIndicators: Bool = false) {
```

存到字段：

```swift
    private var sessionTitles: [UUID: String] = [:]
```

并在 `update` 中 `self.sessionTitles = sessionTitles`。

在 `rebuildTabItems` / 原地刷新分支里，把 `tab.title` 替换为通过显示规则计算的 title。在 TabBarView 内加一个本地 helper（避免循环引用 store）：

```swift
    /// Display title with same priority as `TerminalTab.displayTitle(store:)`,
    /// but reads from the snapshot dictionary we receive in `update`.
    /// Kept inline here so AppKit views don't need to hold a store reference.
    private func displayTitle(for tab: TerminalTab) -> String {
        if tab.userRenamed { return tab.title }
        if let auto = sessionTitles[tab.focusedTerminalId], !auto.isEmpty {
            return auto
        }
        return tab.title
    }
```

`TabItemView.refresh(...)` 和初始化时，把传给 `titleLabel.stringValue` 的值改为 `displayTitle(for: tab)`。即在 `rebuildTabItems` 的 "原地刷新" 分支：

```swift
            for item in existing {
                let isSel = item.tabId == selectedTabId
                if let tab = tabs.first(where: { $0.id == item.tabId }) {
                    let tabStatus = TerminalStatus.aggregate(
                        tab.layout.allTerminalIds().map { statuses[$0] ?? .neverRan }
                    )
                    item.refresh(tab: tab, isSelected: isSel, theme: theme,
                                 canClose: canCloseNow, status: tabStatus,
                                 backgroundOpacity: backgroundOpacity,
                                 showStatusIndicators: showStatusIndicators,
                                 displayTitle: displayTitle(for: tab))
                }
            }
```

完整重建分支：

```swift
        for tab in tabs {
            let tabStatus = TerminalStatus.aggregate(
                tab.layout.allTerminalIds().map { statuses[$0] ?? .neverRan }
            )
            let item = TabItemView(tab: tab, isSelected: tab.id == selectedTabId,
                                   theme: theme, status: tabStatus,
                                   backgroundOpacity: backgroundOpacity,
                                   showStatusIndicators: showStatusIndicators,
                                   quickActionsStore: quickActionsStore,
                                   displayTitle: displayTitle(for: tab))
            // ... rest unchanged
        }
```

修改 `TabItemView.init` 和 `refresh` 接受 `displayTitle: String` 参数，并在内部用它代替 `tab.title` 给 titleLabel 赋值。**保留** `tab.title` 作为 originalTitle 的来源（rename UI 编辑框的 placeholder 仍展示用户已设值；用户没设值时 placeholder 就是兜底文本 = `tab.title`）。

```swift
    init(tab: TerminalTab, isSelected: Bool, theme: AppTheme,
         status: TerminalStatus = .neverRan,
         backgroundOpacity: CGFloat = 1.0,
         showStatusIndicators: Bool = false,
         quickActionsStore: QuickActionsStore? = nil,
         displayTitle: String) {
        // ... existing
        titleLabel.stringValue = displayTitle
        // ...
    }

    func refresh(tab: TerminalTab, isSelected: Bool, theme: AppTheme,
                 canClose: Bool, status: TerminalStatus = .neverRan,
                 backgroundOpacity: CGFloat = 1.0,
                 showStatusIndicators: Bool = false,
                 displayTitle: String) {
        // ... existing
        if titleLabel.stringValue != displayTitle && !isRenaming {
            titleLabel.stringValue = displayTitle
        }
        // ...
    }
```

在 `beginRenameAction` 用 `tab.title`（用户已设）当 edit field 初值；如果想优先显示当前的 displayTitle 也可以，但 spec 没要求 —— 保持简单：用 `titleLabel.stringValue` 当 originalTitle，让 rename UI 自然展示当前显示的名字。

`originalTitle = titleLabel.stringValue` 已经在原始代码里，保留即可。

- [ ] **Step 3: 加 Reset 菜单项 + onResetAutoTitle callback**

在 `TabBarView` 顶部加：

```swift
    var onResetAutoTitle: ((UUID) -> Void)?
```

在 `rebuildTabItems` 完整重建分支创建 `item` 之后：

```swift
            item.onResetAutoTitle = { [weak self] in self?.onResetAutoTitle?(tab.id) }
            item.userRenamed = tab.userRenamed
```

在 `TabItemView` 顶部加：

```swift
    var onResetAutoTitle: (() -> Void)?
    var userRenamed: Bool = false
```

修改 `refresh` 设置 `userRenamed`：

```swift
        self.userRenamed = tab.userRenamed
```

在 `rightMouseDown` 的 menu 中（Close 之前或 separator 之后）加：

```swift
        if userRenamed {
            menu.addItem(.separator())
            let resetItem = NSMenuItem(title: L10n.string("tab.row.resetAutoTitle"),
                                       action: #selector(resetAutoTitleTapped),
                                       keyEquivalent: "")
            resetItem.target = self
            menu.addItem(resetItem)
        }
```

加 callback selector：

```swift
    @objc private func resetAutoTitleTapped() { onResetAutoTitle?() }
```

- [ ] **Step 4: TabContentView 接 onResetAutoTitle**

打开 `mux0/TabContent/TabContentView.swift`，找到现有的 `tabBar.onRenameTab = { ... }` 旁边加：

```swift
        tabBar.onResetAutoTitle = { [weak self] tabId in
            guard let self, let ws = self.store?.selectedWorkspace else { return }
            self.store?.resetTabToAutoTitle(tabId: tabId, in: ws.id)
        }
```

并在 `loadWorkspace`（实际调 `tabBar.update`）里，把 `sessionTitles:` 透传：

```swift
        tabBar.update(
            tabs: ws.tabs,
            selectedTabId: ws.selectedTabId,
            theme: currentTheme,
            statuses: statuses,
            sessionTitles: sessionTitleStore?.titlesSnapshot() ?? [:],
            backgroundOpacity: backgroundOpacity,
            showStatusIndicators: showStatusIndicators
        )
```

在 `TerminalSessionTitleStore` 加 `titlesSnapshot()` 工具方法（如果还没有）。修改 `mux0/Models/TerminalSessionTitleStore.swift`：

```swift
    func titlesSnapshot() -> [UUID: String] {
        var out: [UUID: String] = [:]
        for (k, v) in storage {
            if let id = UUID(uuidString: k) { out[id] = v }
        }
        return out
    }
```

- [ ] **Step 5: TabBridge 透传 sessionTitles 给 update**

打开 `mux0/Bridge/TabBridge.swift`，已有 `statuses: statusStore.statusesSnapshot()`。改为：

```swift
            view.loadWorkspace(ws,
                               statuses: statusStore.statusesSnapshot(),
                               showStatusIndicators: showStatusIndicators)
```

> Note: `loadWorkspace` 在 `TabContentView` 内部已经拿到 `sessionTitleStore`，自己读 snapshot 即可（Step 4 已经实现）。TabBridge 这边不需要再传 snapshot。

实际上需要确认 `loadWorkspace` 当前签名是否接 statuses：是接的（既有代码 line 33）。我们让 `TabContentView` 在 `loadWorkspace` 里自己从 `sessionTitleStore?` 拿 snapshot 即可。

- [ ] **Step 6: 编译 + 跑全套测试**

```bash
xcodegen generate
xcodebuild build -project mux0.xcodeproj -scheme mux0 -configuration Debug 2>&1 | tail -20
```

Expected: build succeeded。

```bash
xcodebuild test -project mux0.xcodeproj -scheme mux0Tests 2>&1 | tail -20
```

Expected: 全套测试通过。

- [ ] **Step 7: Commit (Task 8 + 9 + 10 一起)**

```bash
git add mux0/ContentView.swift mux0/Bridge/TabBridge.swift mux0/TabContent/TabContentView.swift mux0/TabContent/TabBarView.swift mux0/Models/TerminalSessionTitleStore.swift mux0/Localization/Localizable.xcstrings mux0/Localization/L10n.swift
git commit -m "$(cat <<'EOF'
feat(tabcontent): render auto session titles + add reset-to-auto menu

Tab labels now derive from TerminalSessionTitleStore via
TerminalTab.displayTitle priority chain. Right-click menu gains "Reset
to auto title" when the tab is locked by a manual rename.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: L10n smoke test 包含新键

**Files:**
- Modify: `mux0Tests/L10nSmokeTests.swift`

- [ ] **Step 1: 加测试**

打开 `mux0Tests/L10nSmokeTests.swift`，按现有模式加一条：

```swift
    func testResetAutoTitle() {
        XCTAssertFalse(L10n.string("tab.row.resetAutoTitle").isEmpty)
    }
```

- [ ] **Step 2: 跑测试确认通过**

```bash
xcodebuild test -project mux0.xcodeproj -scheme mux0Tests -only-testing:mux0Tests/L10nSmokeTests 2>&1 | tail -10
```

Expected: 通过（依赖 Task 10 已加 key）。

- [ ] **Step 3: Commit**

```bash
git add mux0Tests/L10nSmokeTests.swift
git commit -m "$(cat <<'EOF'
test(i18n): smoke-check tab.row.resetAutoTitle is wired up

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: 文档同步

**Files:**
- Modify: `docs/agent-hooks.md`
- Modify: `CLAUDE.md`
- Modify: `AGENTS.md`

- [ ] **Step 1: docs/agent-hooks.md 加 Session title 章节**

在 `docs/agent-hooks.md` 的 `## IPC` 章节末尾、`## Agent Turn 成败检测` 章节之前，插入：

```markdown
## Session title

Each socket message may carry `sessionTitle` —— 当前 agent 会话的人类可读名字，用于驱动 mux0 的 tab 自动命名（`TerminalSessionTitleStore`）。三个 agent 各自的来源：

| Agent | 来源 | 时机 |
|-------|------|------|
| Claude | transcript JSONL 内反向扫到的最后一条 `{"type":"ai-title","aiTitle":"..."}` 条目 | `prompt` / `stop` |
| Codex | `~/.codex/state_*.sqlite`（取最新 schema 版本）的 `threads.title WHERE id = <session_id>` | `prompt` / `stop` |
| OpenCode | plugin `input.session?.title` | `chat.message` / `tool.execute.before` |

LLM 异步生成 → 新建 session 后第一次 emit 可能为空字符串，下一个 turn 会填上。Swift 端 `TerminalSessionTitleStore.update` 丢弃空字符串，避免覆盖已知值。

用户在 mux0 内 inline rename tab 后，`TerminalTab.userRenamed = true`，`displayTitle` 锁定不再吃 `sessionTitle`。右键菜单「Reset to auto title」清除锁定。
```

- [ ] **Step 2: CLAUDE.md Directory Structure 加 store**

在 CLAUDE.md 的 Directory Structure → Models 节，按字母顺序在 `TerminalPwdStore.swift` 行附近加：

```
│   ├── TerminalSessionTitleStore.swift — @Observable，terminalId → agent session title（hook 喂入，tab 标题读取）
```

`docs/conventions.md` 或 `docs/architecture.md` 若引用 store 列表也同步加。

- [ ] **Step 3: CLAUDE.md Common Tasks 加新任务**

在 Common Tasks 表加一行：

```
| 修改 tab 自动命名行为（auto title 来源 / 锁定语义） | `Models/TerminalSessionTitleStore.swift`, `Models/Workspace.swift`（displayTitle）, `Models/HookDispatcher.swift`（路由）, `Resources/agent-hooks/agent-hook.py`（claude/codex 来源）, `Resources/agent-hooks/opencode-plugin/mux0-status.js`（opencode 来源） |
```

- [ ] **Step 4: AGENTS.md 同步 Directory Structure**

在 AGENTS.md 的相同 Directory Structure 节加同一条 `TerminalSessionTitleStore.swift` 行。

- [ ] **Step 5: 跑文档漂移检查**

```bash
./scripts/check-doc-drift.sh
```

Expected: 通过。

- [ ] **Step 6: Commit**

```bash
git add docs/agent-hooks.md CLAUDE.md AGENTS.md
git commit -m "$(cat <<'EOF'
docs: document Session title hook field + TerminalSessionTitleStore

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 13: 端到端 smoke test（手动）

**Files:** (none modified — this is a verification task)

- [ ] **Step 1: 构建并启动**

```bash
xcodebuild build -project mux0.xcodeproj -scheme mux0 -configuration Debug 2>&1 | tail -5
```

提示用户重启 mux0.app（不主动 killall）。

- [ ] **Step 2: Claude 验证**

在 mux0 新开 tab → quick action "claude"。发一条 prompt（如 "say hi"）。等待 ~2-5 秒 LLM 生成 ai-title。期望：tab 标题从 "claude" 变为 LLM 生成的会话名（如 "Hello greeting"）。

- [ ] **Step 3: Codex 验证**

同上 quick action "codex"。期望：第一次 prompt 后 tab 显示 first_user_message（如 "hello"），后续 turn 后变为 LLM title。

- [ ] **Step 4: OpenCode 验证**

quick action "opencode" → 发 prompt。期望：tab 显示 session.title（≥ 第二次 turn）。

> 若 OpenCode 的 plugin input 不含 `session.title`（API 形态不同），把 Task 7 的 fallback 实施掉：在 plugin 里读 `~/.local/share/opencode/storage/session/<projectHash>/<sessionId>.json`。

- [ ] **Step 5: 锁定语义验证**

任一 agent tab 上：
1. 右键 → Rename → 输入 "MyName" → Enter
2. 期望：tab 显示 "MyName"
3. 发新 prompt，agent 生成新 ai-title
4. 期望：tab 仍显示 "MyName"（锁定生效）
5. 右键 → 应出现 "Reset to auto title"
6. 点击
7. 期望：tab 立即恢复显示 agent session title

- [ ] **Step 6: Split pane focus 验证**

1. 在 claude tab 里 split 一个 shell pane
2. 焦点切到 shell pane（点击）
3. 期望：tab 标题回退到 tab.title（默认 "claude" 或 "Terminal"）
4. 焦点切回 claude pane
5. 期望：tab 标题变回 agent session title

- [ ] **Step 7: 重启持久化验证**

退出 mux0，重新启动。期望：所有 tab 立即显示上次的 session title（来自 UserDefaults），无需等 hook 再触发。

- [ ] **Step 8: Final sanity — 全套测试**

```bash
xcodebuild test -project mux0.xcodeproj -scheme mux0Tests 2>&1 | tail -15
python3 -m pytest Resources/agent-hooks/tests/ -v 2>&1 | tail -10
./scripts/check-doc-drift.sh
```

Expected: 全部通过。

- [ ] **Step 9: PR 创建（人工触发）**

不自动 push，提示用户审阅本地 commits 并自行决定是否 `git push -u origin agent/auto-tab-naming` 后 `gh pr create`。

---

## Self-review checklist

实施时按顺序勾掉以上 task 即可。完成后再核对：

- [ ] Spec 的每条「改动清单」项目都有对应 task
- [ ] 没有 TBD / "implement later" / 占位
- [ ] 类型/方法名跨 task 一致（`displayTitle`、`sessionTitleStore`、`userRenamed`、`resetTabToAutoTitle`）
- [ ] 三个 agent 数据源都有实测 case
- [ ] 兜底 / 锁定 / 解锁 / 持久化 都有 unit / smoke 覆盖
- [ ] 文档同步任务出现在最后（不在头几个 task 里干扰核心实现）
