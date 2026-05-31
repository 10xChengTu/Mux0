# 终端可点击链接 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让终端里的 URL 支持 Cmd+点击打开、Cmd+悬停显示下划线高亮与手型光标，体验对齐 VS Code 终端。

**Architecture:** libghostty 已内置链接识别 / Cmd 判定 / 下划线渲染，宿主只需补三处接线：在 `GhosttyBridge.actionCallback` 处理 `OPEN_URL` 和 `MOUSE_SHAPE` 两个 action，并在 `GhosttyTerminalView` 重新开启 `mouseMoved` 的 hover 转发并由 ghostty 驱动光标。URL 打开逻辑抽成纯静态函数以便单测。

**Tech Stack:** Swift / AppKit，libghostty C API，XCTest，xcodebuild。

---

## File Structure

- `mux0/Ghostty/GhosttyBridge.swift` — 新增 `static func resolveOpenURL`，在 `actionCallback` 加 `OPEN_URL` / `MOUSE_SHAPE` 两个 case。
- `mux0/Ghostty/GhosttyTerminalView.swift` — 新增 `currentCursor` 状态、`cursorUpdate(with:)`、tracking area 追加 `.cursorUpdate`、`mouseMoved` 改为转发 hover，新增 `applyMouseShape` 方法。
- `mux0Tests/GhosttyBridgeOpenURLTests.swift` — 新建，覆盖 `resolveOpenURL` 白名单逻辑。
- `docs/ghostty-integration.md` — 补充新接入的 action 回调说明。

---

## Task 1: URL scheme 白名单解析（纯函数 + 测试）

**Files:**
- Modify: `mux0/Ghostty/GhosttyBridge.swift`
- Test: `mux0Tests/GhosttyBridgeOpenURLTests.swift`（Create）

- [ ] **Step 1: 写失败测试**

新建 `mux0Tests/GhosttyBridgeOpenURLTests.swift`：

```swift
import XCTest
@testable import mux0

final class GhosttyBridgeOpenURLTests: XCTestCase {
    func testAllowsHTTPAndHTTPS() {
        XCTAssertEqual(GhosttyBridge.resolveOpenURL("http://example.com")?.absoluteString,
                       "http://example.com")
        XCTAssertEqual(GhosttyBridge.resolveOpenURL("https://example.com/a?b=1")?.absoluteString,
                       "https://example.com/a?b=1")
    }

    func testAllowsMailtoAndFile() {
        XCTAssertEqual(GhosttyBridge.resolveOpenURL("mailto:x@y.com")?.scheme, "mailto")
        XCTAssertEqual(GhosttyBridge.resolveOpenURL("file:///tmp/a.txt")?.scheme, "file")
    }

    func testRejectsDisallowedSchemes() {
        XCTAssertNil(GhosttyBridge.resolveOpenURL("javascript:alert(1)"))
        XCTAssertNil(GhosttyBridge.resolveOpenURL("ftp://example.com"))
        XCTAssertNil(GhosttyBridge.resolveOpenURL("custom-scheme://do-something"))
    }

    func testRejectsEmptyAndSchemeless() {
        XCTAssertNil(GhosttyBridge.resolveOpenURL(""))
        XCTAssertNil(GhosttyBridge.resolveOpenURL("   "))
        XCTAssertNil(GhosttyBridge.resolveOpenURL("example.com"))
    }

    func testSchemeMatchIsCaseInsensitive() {
        XCTAssertEqual(GhosttyBridge.resolveOpenURL("HTTPS://example.com")?.scheme?.lowercased(),
                       "https")
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `xcodebuild test -project mux0.xcodeproj -scheme mux0Tests -only-testing:mux0Tests/GhosttyBridgeOpenURLTests 2>&1 | tail -20`
Expected: 编译失败，`resolveOpenURL` 未定义。

- [ ] **Step 3: 实现 resolveOpenURL**

在 `GhosttyBridge.swift` 的 `GhosttyBridge` 类里（靠近 `sanitizedPwd` 静态方法处）新增：

```swift
/// 终端链接 Cmd+点击时由 ghostty 传来的原始 URL 字符串。仅放行安全 scheme，
/// 过滤掉终端输出里可能注入的自定义 scheme（如 javascript:）。
static func resolveOpenURL(_ raw: String) -> URL? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          let url = URL(string: trimmed),
          let scheme = url.scheme?.lowercased(),
          ["http", "https", "mailto", "file"].contains(scheme)
    else { return nil }
    return url
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `xcodebuild test -project mux0.xcodeproj -scheme mux0Tests -only-testing:mux0Tests/GhosttyBridgeOpenURLTests 2>&1 | tail -20`
Expected: 全部 PASS。

> 注意：新建的测试文件需被 Xcode target 收录。`project.yml` 用目录通配收 `mux0Tests/`，重生工程即可——若测试找不到，先跑 `xcodegen generate` 再测。

- [ ] **Step 5: 提交**

```bash
git add mux0/Ghostty/GhosttyBridge.swift mux0Tests/GhosttyBridgeOpenURLTests.swift
git commit -m "feat(ghostty): add resolveOpenURL scheme allowlist"
```

---

## Task 2: 接入 OPEN_URL action（Cmd+点击打开）

**Files:**
- Modify: `mux0/Ghostty/GhosttyBridge.swift`（`actionCallback` switch，约 347-394 行）

- [ ] **Step 1: 在 actionCallback 加 OPEN_URL case**

在 `GHOSTTY_ACTION_PWD` 之后、`default` 之前插入：

```swift
        case GHOSTTY_ACTION_OPEN_URL:
            let ou = action.action.open_url
            guard let ptr = ou.url else { return true }
            // url 不保证 NUL 结尾，按 len 取字节构造 String。
            let data = Data(bytes: ptr, count: Int(ou.len))
            guard let raw = String(data: data, encoding: .utf8) else { return true }
            DispatchQueue.main.async {
                if let url = GhosttyBridge.resolveOpenURL(raw) {
                    NSWorkspace.shared.open(url)
                }
            }
            return true
```

- [ ] **Step 2: 编译验证**

Run: `xcodebuild -project mux0.xcodeproj -scheme mux0 -configuration Debug build 2>&1 | tail -15`
Expected: BUILD SUCCEEDED。

- [ ] **Step 3: 提交**

```bash
git add mux0/Ghostty/GhosttyBridge.swift
git commit -m "feat(ghostty): open terminal links on cmd-click via OPEN_URL action"
```

---

## Task 3: 接入 MOUSE_SHAPE action（手型光标）

**Files:**
- Modify: `mux0/Ghostty/GhosttyBridge.swift`（`actionCallback` switch）
- Modify: `mux0/Ghostty/GhosttyTerminalView.swift`（tracking area + 新方法 + cursorUpdate）

- [ ] **Step 1: GhosttyTerminalView 新增 currentCursor 与 applyMouseShape**

在 `GhosttyTerminalView` 类的属性区（与其他 `private var` 同处，例如 `surface` 附近）新增：

```swift
    /// 由 ghostty 的 MOUSE_SHAPE action 驱动。默认 iBeam，与终端文本区一致。
    private var currentCursor: NSCursor = .iBeam
```

在类内（靠近 `applyCellSize` 等 `apply*` 方法处）新增：

```swift
    /// ghostty 通知鼠标应显示的形状（悬停链接→手型，文本→iBeam）。
    func applyMouseShape(_ cursor: NSCursor) {
        currentCursor = cursor
        // 若鼠标正悬在自身上，立即生效，不必等下一次 cursorUpdate。
        if let window = window, window.isKeyWindow {
            let pt = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if bounds.contains(pt) {
                cursor.set()
            }
        }
    }
```

- [ ] **Step 2: tracking area 追加 .cursorUpdate 并 override cursorUpdate**

把 `updateTrackingAreas()`（约 250-258 行）的 options 改为：

```swift
        let options: NSTrackingArea.Options = [
            .activeWhenFirstResponder, .mouseMoved, .cursorUpdate, .inVisibleRect
        ]
```

在 `mouseMoved` 附近新增 override：

```swift
    override func cursorUpdate(with event: NSEvent) {
        currentCursor.set()
    }
```

- [ ] **Step 3: GhosttyBridge 加 MOUSE_SHAPE case**

在 `actionCallback` 的 `GHOSTTY_ACTION_OPEN_URL` case 之后插入：

```swift
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            guard target.tag == GHOSTTY_TARGET_SURFACE,
                  let surface = target.target.surface
            else { return true }
            let shape = action.action.mouse_shape
            let cursor: NSCursor
            switch shape {
            case GHOSTTY_MOUSE_SHAPE_POINTER: cursor = .pointingHand
            case GHOSTTY_MOUSE_SHAPE_TEXT:    cursor = .iBeam
            default:                          cursor = .arrow
            }
            DispatchQueue.main.async {
                guard let view = GhosttyTerminalView.view(forSurface: surface) else { return }
                view.applyMouseShape(cursor)
            }
            return true
```

- [ ] **Step 4: 编译验证**

Run: `xcodebuild -project mux0.xcodeproj -scheme mux0 -configuration Debug build 2>&1 | tail -15`
Expected: BUILD SUCCEEDED。

- [ ] **Step 5: 提交**

```bash
git add mux0/Ghostty/GhosttyBridge.swift mux0/Ghostty/GhosttyTerminalView.swift
git commit -m "feat(ghostty): drive cursor shape from MOUSE_SHAPE action (pointer over links)"
```

---

## Task 4: 重新开启 mouseMoved hover 转发（Cmd+悬停高亮）

**Files:**
- Modify: `mux0/Ghostty/GhosttyTerminalView.swift`（`mouseMoved`，约 686-690 行）

- [ ] **Step 1: 把 mouseMoved 空实现改为转发**

将现有空的 `mouseMoved(with:)` 替换为：

```swift
    override func mouseMoved(with event: NSEvent) {
        // 转发 hover 位置以驱动 ghostty 的链接下划线高亮与光标形状。
        // 安全性：tracking area 为 .activeWhenFirstResponder，仅焦点 pane 触发；
        // 再加 isCursorOverSelf 守卫。纯 hover（无按键）不会扩选区，后台 pane 的
        // mouseLocation 轮询问题已被现有 frontmost gate 拦住。
        guard isCursorOverSelf(event) else { return }
        guard let s = surface else { return }
        let pt = flippedPoint(event.locationInWindow)
        ghostty_surface_mouse_pos(s, pt.x, pt.y, modsFromEvent(event))
    }
```

- [ ] **Step 2: 编译验证**

Run: `xcodebuild -project mux0.xcodeproj -scheme mux0 -configuration Debug build 2>&1 | tail -15`
Expected: BUILD SUCCEEDED。

- [ ] **Step 3: 提交**

```bash
git add mux0/Ghostty/GhosttyTerminalView.swift
git commit -m "feat(ghostty): forward hover to ghostty for cmd-hover link highlight"
```

---

## Task 5: 跑全量测试 + 更新文档

**Files:**
- Modify: `docs/ghostty-integration.md`

- [ ] **Step 1: 跑全量测试**

Run: `xcodebuild test -project mux0.xcodeproj -scheme mux0Tests 2>&1 | tail -20`
Expected: 全部 PASS（含新增 `GhosttyBridgeOpenURLTests`）。

- [ ] **Step 2: 更新 ghostty-integration.md**

在该文档的 action 回调相关章节补充一段，说明现已处理的 action：

```markdown
### 链接交互相关 action

- `GHOSTTY_ACTION_OPEN_URL` — Cmd+点击链接时触发；宿主经 `GhosttyBridge.resolveOpenURL`
  做 scheme 白名单（http/https/mailto/file）后用 `NSWorkspace.shared.open` 打开。
- `GHOSTTY_ACTION_MOUSE_SHAPE` — 悬停链接等场景下 ghostty 通知期望光标；映射到
  `NSCursor`（POINTER→pointingHand、TEXT→iBeam、其余→arrow），经
  `GhosttyTerminalView.applyMouseShape` 应用，配合 `.cursorUpdate` tracking + `cursorUpdate(with:)`。
- 下划线高亮由 ghostty 渲染器自绘，依赖 `mouseMoved` 把带修饰键的 hover 位置转发给
  `ghostty_surface_mouse_pos`（仅焦点 pane）。`GHOSTTY_ACTION_MOUSE_OVER_LINK` 未接入。
```

（若文档结构不同，放到最贴切的 action / 鼠标章节，保持风格一致。）

- [ ] **Step 3: 提交**

```bash
git add docs/ghostty-integration.md
git commit -m "docs(ghostty): document link-interaction action callbacks"
```

---

## 手动验证（实现完成后由用户执行）

1. `xcodebuild -project mux0.xcodeproj -scheme mux0 -configuration Debug build` 编译通过。
2. 用户自行重启 mux0.app（不要由 agent `open`/`killall`）。
3. 在终端里 `echo https://example.com`，Cmd+悬停看是否出现下划线 + 手型光标；Cmd+点击是否在浏览器打开。
4. 普通点击（不按 Cmd）链接不触发打开、不误选区；多 pane 时只有焦点 pane 响应 hover。
