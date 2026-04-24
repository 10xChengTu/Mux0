# Agent Status Interactions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add "read" affordance to green/red terminal-status dots (solid → hollow after user views), and fix the Claude/Codex `needsInput → running` sticking after the user answers a permission prompt.

**Architecture:** `TerminalStatus.success` / `.failed` gain a `readAt: Date?` associated value. `TerminalStatus.aggregate` prefers unread entries within the same kind. `TerminalStatusStore` grows a `markRead(terminalIds:)` method; `ContentView` observes workspace + tab selection and calls it. `TerminalStatusIconView` renders hollow (stroke-only) variants when `readAt != nil`. The hook-side bug is a one-line change in `agent-hook.py` adding a `running` emit to the `posttool` branch.

**Tech Stack:** Swift/AppKit/SwiftUI (@Observable), XCTest, Python 3 + pytest (for the hook script).

**Spec:** `docs/superpowers/specs/2026-04-24-agent-status-interactions-design.md`

---

## File Map

**Modify:**
- `mux0/Models/TerminalStatus.swift` — add `readAt` to `.success` / `.failed`, update `aggregate` tie-break
- `mux0/Models/TerminalStatusStore.swift` — add `markRead(terminalIds:at:)`
- `mux0/Theme/TerminalStatusIconView.swift` — render hollow variants + extract testable `renderStyle` helper
- `mux0/ContentView.swift` — observe selection changes, call `markRead`
- `Resources/agent-hooks/agent-hook.py` — `posttool` emits `{"event": "running", "at": now}`
- `mux0Tests/TerminalStatusTests.swift` — add aggregate unread-wins tests
- `mux0Tests/TerminalStatusStoreTests.swift` — add `markRead` + `setFinished`-clears-readAt tests
- `mux0Tests/TerminalStatusIconViewTests.swift` — add hollow-render style tests
- `Resources/agent-hooks/tests/test_agent_hook.py` — add posttool-emits-running test
- `docs/agent-hooks.md` — note PostToolUse now emits `running` for Claude/Codex
- `docs/architecture.md` — note read-state modifier in `### 终端状态推送`

**Do not modify:** `HookDispatcher.swift`, `opencode-plugin/mux0-status.js`, `codex-wrapper.sh`, `claude-wrapper.sh`, `CLAUDE.md`/`AGENTS.md` (no directory changes).

---

## Task 1: Extend `TerminalStatus` with `readAt`

**Files:**
- Modify: `mux0/Models/TerminalStatus.swift`
- Test: `mux0Tests/TerminalStatusTests.swift`

Rationale: adding a defaulted associated value is a non-breaking change — existing constructors like `.success(exitCode: 0, duration: 5, finishedAt: t, agent: .claude)` keep working because `summary` and the new `readAt` both default to `nil`. Enum `Equatable` compares all associated values, so tests that compare two `.success` built with the same args continue to be equal (both readAt = nil).

- [ ] **Step 1: Write the failing test**

Append to `mux0Tests/TerminalStatusTests.swift` just before the closing `}` of the class:

```swift
    // MARK: - readAt modifier

    func testSuccessReadAtDefaultsToNil() {
        let now = Date()
        let s = TerminalStatus.success(exitCode: 0, duration: 1, finishedAt: now, agent: .claude)
        guard case .success(_, _, _, _, _, let readAt) = s else {
            XCTFail("Expected .success"); return
        }
        XCTAssertNil(readAt)
    }

    func testSuccessReadAtCanBeSet() {
        let now = Date()
        let readAt = Date(timeIntervalSince1970: 99)
        let s = TerminalStatus.success(exitCode: 0, duration: 1, finishedAt: now,
                                        agent: .claude, summary: nil, readAt: readAt)
        guard case .success(_, _, _, _, _, let actual) = s else {
            XCTFail("Expected .success"); return
        }
        XCTAssertEqual(actual, readAt)
    }

    func testFailedReadAtDefaultsToNil() {
        let now = Date()
        let f = TerminalStatus.failed(exitCode: 1, duration: 1, finishedAt: now, agent: .claude)
        guard case .failed(_, _, _, _, _, let readAt) = f else {
            XCTFail("Expected .failed"); return
        }
        XCTAssertNil(readAt)
    }

    func testSuccessReadAtParticipatesInEquality() {
        let now = Date()
        let readAt = Date(timeIntervalSince1970: 99)
        let a = TerminalStatus.success(exitCode: 0, duration: 1, finishedAt: now, agent: .claude)
        let b = TerminalStatus.success(exitCode: 0, duration: 1, finishedAt: now,
                                        agent: .claude, summary: nil, readAt: readAt)
        XCTAssertNotEqual(a, b)
    }
```

- [ ] **Step 2: Run tests to verify they fail to compile**

Run: `xcodebuild test -project mux0.xcodeproj -scheme mux0Tests -only-testing:mux0Tests/TerminalStatusTests 2>&1 | tail -30`
Expected: build failure — the new `readAt` argument and the 6-tuple pattern match do not exist yet.

- [ ] **Step 3: Add `readAt` to `.success` / `.failed`**

In `mux0/Models/TerminalStatus.swift`, replace the case declarations (around lines 21-24) with:

```swift
    case success(exitCode: Int32, duration: TimeInterval, finishedAt: Date,
                 agent: HookMessage.Agent, summary: String? = nil,
                 readAt: Date? = nil)
    case failed(exitCode: Int32, duration: TimeInterval, finishedAt: Date,
                agent: HookMessage.Agent, summary: String? = nil,
                readAt: Date? = nil)
```

- [ ] **Step 4: Update `currentTimestamp` tuple bindings in `TerminalStatusStore`**

In `mux0/Models/TerminalStatusStore.swift` `currentTimestamp(for:)` (around lines 73-82), the `.success` / `.failed` patterns now destructure 6 values. Replace:

```swift
        case .success(_, _, let at, _, _):         return at
        case .failed(_, _, let at, _, _):          return at
```

with:

```swift
        case .success(_, _, let at, _, _, _):      return at
        case .failed(_, _, let at, _, _, _):       return at
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -project mux0.xcodeproj -scheme mux0Tests -only-testing:mux0Tests/TerminalStatusTests 2>&1 | tail -30`
Expected: all TerminalStatusTests pass, including the four new `readAt` tests.

- [ ] **Step 6: Commit**

```bash
git add mux0/Models/TerminalStatus.swift mux0/Models/TerminalStatusStore.swift mux0Tests/TerminalStatusTests.swift
git commit -m "feat(models): add readAt to TerminalStatus .success/.failed"
```

---

## Task 2: `aggregate` prefers unread within the same kind

**Files:**
- Modify: `mux0/Models/TerminalStatus.swift:42-46`
- Test: `mux0Tests/TerminalStatusTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `mux0Tests/TerminalStatusTests.swift` class body:

```swift
    // MARK: - aggregate unread tie-break

    func testAggregateUnreadSuccessBeatsReadSuccess() {
        let now = Date()
        let readAt = Date(timeIntervalSince1970: 99)
        let read   = TerminalStatus.success(exitCode: 0, duration: 1, finishedAt: now,
                                             agent: .claude, summary: nil, readAt: readAt)
        let unread = TerminalStatus.success(exitCode: 0, duration: 2, finishedAt: now,
                                             agent: .claude)
        let agg1 = TerminalStatus.aggregate([read, unread])
        let agg2 = TerminalStatus.aggregate([unread, read])
        // order-independent: unread wins regardless of position
        guard case .success(_, _, _, _, _, let r1) = agg1,
              case .success(_, _, _, _, _, let r2) = agg2 else {
            XCTFail("Expected .success from both aggregations"); return
        }
        XCTAssertNil(r1)
        XCTAssertNil(r2)
    }

    func testAggregateUnreadFailedBeatsReadFailed() {
        let now = Date()
        let read   = TerminalStatus.failed(exitCode: 1, duration: 1, finishedAt: now,
                                            agent: .claude, summary: nil,
                                            readAt: Date(timeIntervalSince1970: 99))
        let unread = TerminalStatus.failed(exitCode: 1, duration: 2, finishedAt: now,
                                            agent: .claude)
        let agg = TerminalStatus.aggregate([read, unread])
        guard case .failed(_, _, _, _, _, let r) = agg else {
            XCTFail("Expected .failed"); return
        }
        XCTAssertNil(r)
    }

    func testAggregateAllReadSuccessStaysRead() {
        let now = Date()
        let readAt = Date(timeIntervalSince1970: 99)
        let a = TerminalStatus.success(exitCode: 0, duration: 1, finishedAt: now,
                                        agent: .claude, summary: nil, readAt: readAt)
        let b = TerminalStatus.success(exitCode: 0, duration: 2, finishedAt: now,
                                        agent: .claude, summary: nil, readAt: readAt)
        let agg = TerminalStatus.aggregate([a, b])
        guard case .success(_, _, _, _, _, let r) = agg else {
            XCTFail("Expected .success"); return
        }
        XCTAssertNotNil(r)
    }

    func testAggregatePriorityLadderUnchangedByReadAt() {
        // needsInput still beats any success regardless of read state.
        let now = Date()
        let readSuccess = TerminalStatus.success(exitCode: 0, duration: 1, finishedAt: now,
                                                  agent: .claude, summary: nil,
                                                  readAt: Date(timeIntervalSince1970: 99))
        let inputs: [TerminalStatus] = [readSuccess, .needsInput(since: now)]
        XCTAssertEqual(TerminalStatus.aggregate(inputs).priorityCaseName, "needsInput")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project mux0.xcodeproj -scheme mux0Tests -only-testing:mux0Tests/TerminalStatusTests 2>&1 | tail -30`
Expected: the first two new tests fail — current `aggregate` keeps first-wins so `[read, unread]` returns the read one.

- [ ] **Step 3: Implement unread tie-break**

Replace `mux0/Models/TerminalStatus.swift` `aggregate(_:)` (around lines 42-46) with:

```swift
    static func aggregate(_ statuses: [TerminalStatus]) -> TerminalStatus {
        statuses.reduce(TerminalStatus.neverRan) { current, next in
            if next.priority > current.priority { return next }
            if next.priority == current.priority {
                // Same kind — prefer unread (readAt == nil) so a single
                // unread entry pulls the aggregate to "needs attention".
                if current.isRead && !next.isRead { return next }
            }
            return current
        }
    }

    /// True when this status has been acknowledged by the user.
    /// Only `.success` / `.failed` can be read; other kinds return `false`.
    var isRead: Bool {
        switch self {
        case .success(_, _, _, _, _, let readAt): return readAt != nil
        case .failed(_, _, _, _, _, let readAt):  return readAt != nil
        default: return false
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project mux0.xcodeproj -scheme mux0Tests -only-testing:mux0Tests/TerminalStatusTests 2>&1 | tail -30`
Expected: all TerminalStatusTests pass (new + existing, including `testAggregateTwoSuccessPicksOneSuccess` which remains valid since both successes are unread by default).

- [ ] **Step 5: Commit**

```bash
git add mux0/Models/TerminalStatus.swift mux0Tests/TerminalStatusTests.swift
git commit -m "feat(models): aggregate prefers unread success/failed within same kind"
```

---

## Task 3: `TerminalStatusStore.markRead`

**Files:**
- Modify: `mux0/Models/TerminalStatusStore.swift`
- Test: `mux0Tests/TerminalStatusStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `mux0Tests/TerminalStatusStoreTests.swift` class body:

```swift
    // MARK: - markRead

    func testMarkReadStampsUnreadSuccess() {
        let store = TerminalStatusStore()
        let id = UUID()
        let finishedAt = Date(timeIntervalSince1970: 1000)
        store.setFinished(terminalId: id, exitCode: 0, at: finishedAt, agent: .claude)
        let readAt = Date(timeIntervalSince1970: 1010)
        store.markRead(terminalIds: [id], at: readAt)
        guard case .success(_, _, _, _, _, let actual) = store.status(for: id) else {
            XCTFail("Expected .success"); return
        }
        XCTAssertEqual(actual, readAt)
    }

    func testMarkReadStampsUnreadFailed() {
        let store = TerminalStatusStore()
        let id = UUID()
        let finishedAt = Date(timeIntervalSince1970: 2000)
        store.setFinished(terminalId: id, exitCode: 1, at: finishedAt, agent: .claude)
        let readAt = Date(timeIntervalSince1970: 2010)
        store.markRead(terminalIds: [id], at: readAt)
        guard case .failed(_, _, _, _, _, let actual) = store.status(for: id) else {
            XCTFail("Expected .failed"); return
        }
        XCTAssertEqual(actual, readAt)
    }

    func testMarkReadPreservesFirstReadAtWhenCalledTwice() {
        let store = TerminalStatusStore()
        let id = UUID()
        store.setFinished(terminalId: id, exitCode: 0, at: Date(timeIntervalSince1970: 1000),
                          agent: .claude)
        let firstRead  = Date(timeIntervalSince1970: 1010)
        let secondRead = Date(timeIntervalSince1970: 1020)
        store.markRead(terminalIds: [id], at: firstRead)
        store.markRead(terminalIds: [id], at: secondRead)
        guard case .success(_, _, _, _, _, let actual) = store.status(for: id) else {
            XCTFail("Expected .success"); return
        }
        XCTAssertEqual(actual, firstRead, "Already-read entries should not be re-stamped")
    }

    func testMarkReadIgnoresNonTerminalStates() {
        let store = TerminalStatusStore()
        let id = UUID()
        let started = Date(timeIntervalSince1970: 1000)
        store.setRunning(terminalId: id, at: started)
        store.markRead(terminalIds: [id], at: Date(timeIntervalSince1970: 2000))
        // Still running — markRead is a no-op for non-success/failed states.
        XCTAssertEqual(store.status(for: id), .running(startedAt: started))
    }

    func testMarkReadIgnoresUnknownIds() {
        let store = TerminalStatusStore()
        let unknown = UUID()
        store.markRead(terminalIds: [unknown], at: Date())
        XCTAssertEqual(store.status(for: unknown), .neverRan)
    }

    func testMarkReadAcceptsMultipleIds() {
        let store = TerminalStatusStore()
        let a = UUID(); let b = UUID()
        let t = Date(timeIntervalSince1970: 1000)
        store.setFinished(terminalId: a, exitCode: 0, at: t, agent: .claude)
        store.setFinished(terminalId: b, exitCode: 1, at: t, agent: .claude)
        let readAt = Date(timeIntervalSince1970: 1010)
        store.markRead(terminalIds: [a, b], at: readAt)
        guard case .success(_, _, _, _, _, let ra) = store.status(for: a),
              case .failed(_, _, _, _, _, let rb) = store.status(for: b) else {
            XCTFail("Expected .success + .failed"); return
        }
        XCTAssertEqual(ra, readAt)
        XCTAssertEqual(rb, readAt)
    }

    func testSetFinishedClearsPriorReadAt() {
        let store = TerminalStatusStore()
        let id = UUID()
        store.setFinished(terminalId: id, exitCode: 0, at: Date(timeIntervalSince1970: 1000),
                          agent: .claude)
        store.markRead(terminalIds: [id], at: Date(timeIntervalSince1970: 1010))
        // New finished event — readAt must reset to nil (new unread result).
        store.setFinished(terminalId: id, exitCode: 0, at: Date(timeIntervalSince1970: 2000),
                          agent: .claude)
        guard case .success(_, _, _, _, _, let readAt) = store.status(for: id) else {
            XCTFail("Expected .success"); return
        }
        XCTAssertNil(readAt)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project mux0.xcodeproj -scheme mux0Tests -only-testing:mux0Tests/TerminalStatusStoreTests 2>&1 | tail -30`
Expected: build failure — `markRead(terminalIds:at:)` doesn't exist.

- [ ] **Step 3: Implement `markRead`**

Append this method to `TerminalStatusStore` in `mux0/Models/TerminalStatusStore.swift` (just before the closing brace at line 98):

```swift
    /// Mark entries as "read" by stamping `readAt` on any `.success` / `.failed`
    /// with `readAt == nil`. Idempotent: entries already read keep their original
    /// readAt. Ids not matching `.success` / `.failed` (or not in storage) are
    /// no-ops. Called from `ContentView` when the user switches workspaces/tabs
    /// so on-screen terminal-state dots fade from solid to hollow.
    func markRead(terminalIds: [UUID], at now: Date = Date()) {
        for id in terminalIds {
            switch storage[id] {
            case .success(let ec, let dur, let fa, let agent, let summary, nil):
                storage[id] = .success(exitCode: ec, duration: dur, finishedAt: fa,
                                        agent: agent, summary: summary, readAt: now)
            case .failed(let ec, let dur, let fa, let agent, let summary, nil):
                storage[id] = .failed(exitCode: ec, duration: dur, finishedAt: fa,
                                       agent: agent, summary: summary, readAt: now)
            default:
                continue
            }
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project mux0.xcodeproj -scheme mux0Tests -only-testing:mux0Tests/TerminalStatusStoreTests 2>&1 | tail -30`
Expected: all TerminalStatusStoreTests pass.

- [ ] **Step 5: Commit**

```bash
git add mux0/Models/TerminalStatusStore.swift mux0Tests/TerminalStatusStoreTests.swift
git commit -m "feat(models): add TerminalStatusStore.markRead for read-state"
```

---

## Task 4: `TerminalStatusIconView` hollow variants

**Files:**
- Modify: `mux0/Theme/TerminalStatusIconView.swift`
- Test: `mux0Tests/TerminalStatusIconViewTests.swift`

Approach: extract a pure `renderStyle(for:theme:)` helper returning `(fill, stroke, lineWidth)` so tests can assert visual state without instantiating an `NSView`. The existing `render()` calls it for fill/stroke/lineWidth; the arc path for `.running` stays inline since it's not a simple ellipse.

- [ ] **Step 1: Write the failing tests**

Append to `mux0Tests/TerminalStatusIconViewTests.swift` class body:

```swift
    // MARK: - renderStyle (read-state visuals)

    private static let darkTheme = AppTheme.systemFallback(isDark: true)

    func testUnreadSuccessIsSolidFill() {
        let style = TerminalStatusIconView.renderStyle(
            for: .success(exitCode: 0, duration: 1, finishedAt: Date(), agent: .claude),
            theme: Self.darkTheme)
        XCTAssertEqual(style.fill, Self.darkTheme.success)
        XCTAssertEqual(style.stroke, NSColor.clear)
        XCTAssertEqual(style.lineWidth, 0)
    }

    func testReadSuccessIsHollowStroke() {
        let style = TerminalStatusIconView.renderStyle(
            for: .success(exitCode: 0, duration: 1, finishedAt: Date(),
                          agent: .claude, summary: nil,
                          readAt: Date(timeIntervalSince1970: 99)),
            theme: Self.darkTheme)
        XCTAssertEqual(style.fill, NSColor.clear)
        XCTAssertEqual(style.stroke, Self.darkTheme.success)
        XCTAssertEqual(style.lineWidth, 1)
    }

    func testUnreadFailedIsSolidFill() {
        let style = TerminalStatusIconView.renderStyle(
            for: .failed(exitCode: 1, duration: 1, finishedAt: Date(), agent: .claude),
            theme: Self.darkTheme)
        XCTAssertEqual(style.fill, Self.darkTheme.danger)
        XCTAssertEqual(style.stroke, NSColor.clear)
        XCTAssertEqual(style.lineWidth, 0)
    }

    func testReadFailedIsHollowStroke() {
        let style = TerminalStatusIconView.renderStyle(
            for: .failed(exitCode: 1, duration: 1, finishedAt: Date(),
                         agent: .claude, summary: nil,
                         readAt: Date(timeIntervalSince1970: 99)),
            theme: Self.darkTheme)
        XCTAssertEqual(style.fill, NSColor.clear)
        XCTAssertEqual(style.stroke, Self.darkTheme.danger)
        XCTAssertEqual(style.lineWidth, 1)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project mux0.xcodeproj -scheme mux0Tests -only-testing:mux0Tests/TerminalStatusIconViewTests 2>&1 | tail -30`
Expected: build failure — `renderStyle` doesn't exist.

- [ ] **Step 3: Refactor render() to use a testable helper**

In `mux0/Theme/TerminalStatusIconView.swift`, inside the class (e.g. just above the `private func render()` definition around line 65), add:

```swift
    /// Pure style function used by `render()` to paint the ellipse layer.
    /// Returns nil for kinds that draw a custom path (e.g. `.running`'s 270° arc).
    static func renderStyle(for status: TerminalStatus, theme: AppTheme)
        -> (fill: NSColor, stroke: NSColor, lineWidth: CGFloat)?
    {
        switch status {
        case .neverRan:
            return (NSColor.clear, theme.textTertiary, 1)
        case .running:
            return nil   // custom arc path; handled inline
        case .idle:
            return (NSColor.clear,
                    theme.textTertiary.withAlphaComponent(0.6), 1)
        case .needsInput:
            return (theme.accent, NSColor.clear, 0)
        case .success(_, _, _, _, _, let readAt):
            if readAt != nil {
                return (NSColor.clear, theme.success, 1)
            }
            return (theme.success, NSColor.clear, 0)
        case .failed(_, _, _, _, _, let readAt):
            if readAt != nil {
                return (NSColor.clear, theme.danger, 1)
            }
            return (theme.danger, NSColor.clear, 0)
        }
    }
```

Then replace the existing `render()` body (around lines 65-110) with:

```swift
    private func render() {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        if case .running = status {
            // 270° open arc, accent colour
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let radius = min(rect.width, rect.height) / 2
            let path = CGMutablePath()
            path.addArc(center: center, radius: radius,
                        startAngle: 0, endAngle: CGFloat.pi * 1.5,
                        clockwise: false)
            shapeLayer.path = path
            shapeLayer.fillColor = NSColor.clear.cgColor
            shapeLayer.strokeColor = theme.accent.cgColor
            shapeLayer.lineWidth = 1.5
            shapeLayer.lineCap = .round
            return
        }
        guard let style = Self.renderStyle(for: status, theme: theme) else { return }
        shapeLayer.path = CGPath(ellipseIn: rect, transform: nil)
        shapeLayer.fillColor = style.fill.cgColor
        shapeLayer.strokeColor = style.stroke.cgColor
        shapeLayer.lineWidth = style.lineWidth
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project mux0.xcodeproj -scheme mux0Tests -only-testing:mux0Tests/TerminalStatusIconViewTests 2>&1 | tail -30`
Expected: all TerminalStatusIconViewTests pass (new + existing tooltip tests).

- [ ] **Step 5: Verify the app still builds**

Run: `xcodebuild -project mux0.xcodeproj -scheme mux0 -configuration Debug build 2>&1 | tail -15`
Expected: `** BUILD SUCCEEDED **` (no regressions from refactoring `render()`).

- [ ] **Step 6: Commit**

```bash
git add mux0/Theme/TerminalStatusIconView.swift mux0Tests/TerminalStatusIconViewTests.swift
git commit -m "feat(theme): hollow status-icon variants for read success/failed"
```

---

## Task 5: Wire markRead from ContentView selection changes

**Files:**
- Modify: `mux0/ContentView.swift`

No new test — this is pure view glue; the `markRead` semantics are already covered by Task 3. The build+run is the verification.

- [ ] **Step 1: Add a helper that derives visible terminal ids**

In `mux0/ContentView.swift`, add this computed inside the `ContentView` struct (just below `showStatusIndicators` around line 34):

```swift
    /// UUIDs of all terminals currently rendered on-screen: every descendant
    /// of the selected tab's split tree in the selected workspace. Empty when
    /// nothing is selected (app start before a workspace exists).
    private var visibleTerminalIds: [UUID] {
        guard let ws = store.selectedWorkspace,
              let tab = ws.selectedTab else { return [] }
        return tab.layout.allTerminalIds()
    }
```

- [ ] **Step 2: Observe selection and call markRead**

Find the existing `.onChange(of: store.selectedId)` block in `mux0/ContentView.swift` (around lines 182-184):

```swift
        .onChange(of: store.selectedId) { _, _ in
            if showSettings { showSettings = false }
        }
```

Replace it with a combined observer that also marks visible terminals read, plus a separate observer for `selectedTabId`:

```swift
        .onChange(of: store.selectedId) { _, _ in
            if showSettings { showSettings = false }
            statusStore.markRead(terminalIds: visibleTerminalIds)
        }
        .onChange(of: store.selectedWorkspace?.selectedTabId) { _, _ in
            statusStore.markRead(terminalIds: visibleTerminalIds)
        }
```

- [ ] **Step 3: Build**

Run: `xcodebuild -project mux0.xcodeproj -scheme mux0 -configuration Debug build 2>&1 | tail -15`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Run full test suite**

Run: `xcodebuild test -project mux0.xcodeproj -scheme mux0Tests 2>&1 | tail -30`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add mux0/ContentView.swift
git commit -m "feat(content): mark visible terminals read on workspace/tab switch"
```

---

## Task 6: Fix `needsInput → running` (Python hook)

**Files:**
- Modify: `Resources/agent-hooks/agent-hook.py`
- Test: `Resources/agent-hooks/tests/test_agent_hook.py`

- [ ] **Step 1: Write the failing test**

Append to `Resources/agent-hooks/tests/test_agent_hook.py`:

```python
def test_dispatch_posttool_emits_running(tmp_path):
    sf = tmp_path / "sessions.json"
    now = 6_000_000.0
    agent_hook.dispatch("prompt", "claude",
                        {"session_id": "s6"}, "term6", sf, now)
    agent_hook.dispatch("pretool", "claude",
                        {"session_id": "s6", "tool_name": "Edit",
                         "tool_input": {"file_path": "/foo.swift"}},
                        "term6", sf, now + 1)
    # Clean posttool — emits running (no toolDetail / exitCode).
    emit = agent_hook.dispatch("posttool", "claude",
                                {"session_id": "s6",
                                 "tool_response": {"is_error": False}},
                                "term6", sf, now + 2)
    assert emit == {"event": "running", "at": now + 2}


def test_dispatch_posttool_running_emit_preserves_sticky_error(tmp_path):
    sf = tmp_path / "sessions.json"
    now = 7_000_000.0
    agent_hook.dispatch("prompt", "claude",
                        {"session_id": "s7"}, "term7", sf, now)
    # Error posttool — still emits running AND sets the sticky flag.
    emit = agent_hook.dispatch("posttool", "claude",
                                {"session_id": "s7",
                                 "tool_response": {"is_error": True}},
                                "term7", sf, now + 1)
    assert emit["event"] == "running"
    # Stop reads the flag → exit code 1.
    stop_emit = agent_hook.dispatch("stop", "claude",
                                     {"session_id": "s7"}, "term7", sf, now + 2)
    assert stop_emit["exitCode"] == 1
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python3 -m pytest Resources/agent-hooks/tests/test_agent_hook.py::test_dispatch_posttool_emits_running Resources/agent-hooks/tests/test_agent_hook.py::test_dispatch_posttool_running_emit_preserves_sticky_error -v`
Expected: first test fails with `assert {} == {"event": "running", "at": 6000002.0}` (posttool currently returns `{}`).

- [ ] **Step 3: Implement the emit**

In `Resources/agent-hooks/agent-hook.py`, find the `posttool` branch in `dispatch` (around lines 206-210):

```python
    elif subcmd == "posttool":
        resp = payload.get("tool_response", {})
        if isinstance(resp, dict) and resp.get("is_error"):
            entry["turnHadError"] = True
        # no emit
```

Replace with:

```python
    elif subcmd == "posttool":
        resp = payload.get("tool_response", {})
        if isinstance(resp, dict) and resp.get("is_error"):
            entry["turnHadError"] = True
        # Emit running so needsInput (set by Notification mid-turn) returns
        # to the live-turn state after the user resolves a permission prompt.
        # Stop fires later with a newer timestamp and overwrites to finished.
        emit = {"event": "running", "at": now}
```

- [ ] **Step 4: Run the new tests + full hook suite to verify they pass**

Run: `python3 -m pytest Resources/agent-hooks/tests/ -v 2>&1 | tail -20`
Expected: all tests pass, including the new posttool tests and the existing `test_dispatch_posttool_sets_sticky_error` (which doesn't assert posttool's return shape).

- [ ] **Step 5: Commit**

```bash
git add Resources/agent-hooks/agent-hook.py Resources/agent-hooks/tests/test_agent_hook.py
git commit -m "fix(ghostty): emit running on PostToolUse to unstick needsInput"
```

---

## Task 7: Documentation

**Files:**
- Modify: `docs/agent-hooks.md`
- Modify: `docs/architecture.md`

- [ ] **Step 1: Update `docs/agent-hooks.md`**

Find this line (around line 3) and add to it, or add a new short subsection below the "IPC" section — open `docs/agent-hooks.md` and in the `## 各 Agent 的信号来源` section, after the existing table, add:

```markdown
## `running` 的覆盖点

Claude / Codex 的 `PostToolUse` hook 除了累加 `turnHadError` 之外，还会 emit `running`。作用是把 `Notification → needsInput` 设置的等待态在用户批准权限、工具继续执行后推回 running——否则在"工具长时间执行"或"该工具是 turn 里最后一个动作"的情况下，橙点会一直卡到 `Stop` 才消失。`Stop` 的时间戳晚于 `posttool`，`TerminalStatusStore.isStale` 保证 `finished` 最终覆盖 `running`。

OpenCode 走另一条路径：`permission.asked → needsInput`，`permission.replied → running`，plugin 层本身已闭环；`tool.execute.after` 不发 socket 消息，只累计 `turn.hadError`。
```

- [ ] **Step 2: Update `docs/architecture.md`**

Find the `### 终端状态推送` block (around line 111). Append these paragraphs after the closing backticks and the `详见 docs/agent-hooks.md.` line (i.e. between line 120 and `### 终端 PWD 追踪` at line 122):

```markdown
`.success` / `.failed` 这两种 turn 终态支持"已读"修饰：关联值 `readAt: Date?`
为 nil 时实心（未读），非 nil 时空心 stroke-only（已读）。`ContentView` 在
`store.selectedId` 或选中 workspace 的 `selectedTabId` 变化时，把 on-screen
（当前 workspace 的当前 tab 分屏树里的全部）terminal id 喂给
`TerminalStatusStore.markRead(terminalIds:)`。下一次 `setFinished` 会重写
storage entry，`readAt` 自然归 nil（新结果 → 重新未读）。`aggregate` 在同
优先级内偏好未读项，保证 "workspace 还有其它未看过的终态" 能稳住实心显示。
```

- [ ] **Step 3: Verify doc drift**

Run: `./scripts/check-doc-drift.sh`
Expected: exit 0, no directory structure mismatch (no Swift files added/moved/renamed in this plan).

- [ ] **Step 4: Commit**

```bash
git add docs/agent-hooks.md docs/architecture.md
git commit -m "docs(agent-hooks): PostToolUse emits running; read-state modifier"
```

---

## Task 8: Final verification

- [ ] **Step 1: Full test sweep**

Run: `xcodebuild test -project mux0.xcodeproj -scheme mux0Tests 2>&1 | tail -30`
Expected: all tests pass.

Run: `python3 -m pytest Resources/agent-hooks/tests/ -v 2>&1 | tail -15`
Expected: all tests pass.

- [ ] **Step 2: Build**

Run: `xcodebuild -project mux0.xcodeproj -scheme mux0 -configuration Debug build 2>&1 | tail -15`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Manual smoke test (user's call when to verify)**

Verify in a running mux0 (user relaunches manually — do not `open` / `killall` the app per `CLAUDE.md`):

1. Start a Claude Code turn in one tab. Watch it go spinner → (optional) amber on permission → spinner after answering → solid green on completion.
2. Switch to a different workspace / tab. Return. Green dot on the workspace row goes hollow.
3. Start a new turn. Green → solid (unread) again.
4. Fail a turn (e.g. a tool error). Red solid → switch tab and back → red hollow.

- [ ] **Step 4: Do not push**

Do not run `git push` — per the user's saved preference, pushing requires explicit consent.
