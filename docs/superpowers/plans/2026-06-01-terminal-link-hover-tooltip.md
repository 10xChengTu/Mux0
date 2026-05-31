# 终端链接 hover 下划线 + tooltip（Phase 2）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** 让普通 hover（不按 Cmd）也能显示链接下划线 + tooltip「⌘ + 单击打开链接」，光标保持 iBeam；Cmd+hover 显示手型、Cmd+单击打开。对齐 VS Code。

**Architecture:** 修饰键注入——`mouseMoved` 转发时给 mods 注入 SUPER 骗 ghostty 在普通 hover 也画下划线并发 `MOUSE_OVER_LINK`；点击事件传真实 mods 故只有真 Cmd+单击打开。光标与 tooltip 由宿主根据 `MOUSE_OVER_LINK` + 真实 Cmd 状态集中接管。

**Tech Stack:** Swift / AppKit，libghostty C API，String Catalog，XCTest。

分支：继续在 `agent/terminal-clickable-links`。

---

## Task 6: 新增 tooltip 文案（i18n）

**Files:**
- Modify: `mux0/Localization/Localizable.xcstrings`

- [ ] **Step 1: 加 key**

在 `mux0/Localization/Localizable.xcstrings` 的 `"strings"` 对象里新增一个 key（保持文件其余部分不动，注意 JSON 合法、与现有条目同结构）：

```json
"terminal.link.openHint" : {
  "extractionState" : "manual",
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "⌘ + click to open link" } },
    "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "⌘ + 单击打开链接" } }
  }
}
```

- [ ] **Step 2: 验证 JSON + 构建**

Run: `python3 -c "import json; json.load(open('mux0/Localization/Localizable.xcstrings')); print('ok')"`
Expected: `ok`
Run: `xcodebuild -project mux0.xcodeproj -scheme mux0 -configuration Debug build 2>&1 | tail -8`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: 提交**

```bash
git add mux0/Localization/Localizable.xcstrings
git commit -m "feat(i18n): add terminal link open hint string"
```

---

## Task 7: LinkHintTooltip 浮层窗口（新文件 + 目录文档同步）

**Files:**
- Create: `mux0/Ghostty/LinkHintTooltip.swift`
- Modify: `CLAUDE.md`, `AGENTS.md`（Directory Structure 的 Ghostty/ 段）

- [ ] **Step 1: 新建 tooltip 类**

Create `mux0/Ghostty/LinkHintTooltip.swift`:

```swift
import AppKit

/// 链接 hover 提示气泡。一个无边框、不激活、不接收鼠标事件的浮层窗口，
/// 显示「⌘ + 单击打开链接」之类提示。由 GhosttyTerminalView 在普通 hover
/// 链接时显示，Cmd 按下或离开链接时隐藏。使用系统 toolTip 材质与语义色，
/// 不引入主题耦合。
final class LinkHintTooltip {
    private var label: NSTextField?

    private lazy var window: NSWindow = {
        let w = NSWindow(
            contentRect: .zero,
            styleMask: .borderless,
            backing: .buffered,
            defer: true
        )
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .floating
        w.ignoresMouseEvents = true
        w.hasShadow = true

        let blur = NSVisualEffectView()
        blur.material = .toolTip
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 5
        blur.layer?.masksToBounds = true

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .labelColor
        label.backgroundColor = .clear
        label.isBordered = false
        blur.addSubview(label)

        w.contentView = blur
        self.label = label
        return w
    }()

    /// 在屏幕坐标 `screenPoint` 附近显示提示。
    func show(_ text: String, at screenPoint: NSPoint) {
        _ = window
        guard let label else { return }
        label.stringValue = text
        label.sizeToFit()

        let padX: CGFloat = 8
        let padY: CGFloat = 5
        let size = NSSize(
            width: label.frame.width + padX * 2,
            height: label.frame.height + padY * 2
        )
        label.setFrameOrigin(NSPoint(x: padX, y: padY))
        window.setContentSize(size)
        window.contentView?.frame = NSRect(origin: .zero, size: size)
        // 放在光标右下方一点，避免遮住链接本身。
        window.setFrameOrigin(NSPoint(x: screenPoint.x + 12,
                                      y: screenPoint.y - size.height - 12))
        window.orderFront(nil)
    }

    func hide() {
        window.orderOut(nil)
    }
}
```

- [ ] **Step 2: 构建**

Run: `xcodegen generate` (新文件需进 target) then `xcodebuild -project mux0.xcodeproj -scheme mux0 -configuration Debug build 2>&1 | tail -8`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: 同步目录文档**

在 `CLAUDE.md` 和 `AGENTS.md` 的 Directory Structure 里，`Ghostty/` 段落新增一行（与现有 `│   ├──` 缩进风格一致）：
```
│   ├── LinkHintTooltip.swift      — 链接 hover 提示气泡（无边框浮层窗口）
```
放在 `GhosttyTerminalView.swift` 行之后。读这两个文件确认确切缩进与表述风格后再改。

Run: `./scripts/check-doc-drift.sh 2>&1 | tail -5`
Expected: 目录匹配通过，exit 0。

- [ ] **Step 4: 提交**

```bash
git add mux0/Ghostty/LinkHintTooltip.swift CLAUDE.md AGENTS.md mux0.xcodeproj/project.pbxproj
git commit -m "feat(ghostty): add LinkHintTooltip floating hint window"
```

---

## Task 8: 接线——hover 注入 + MOUSE_OVER_LINK + 光标/tooltip 接管

**Files:**
- Modify: `mux0/Ghostty/GhosttyBridge.swift`（actionCallback 加 MOUSE_OVER_LINK case）
- Modify: `mux0/Ghostty/GhosttyTerminalView.swift`（mouseMoved 注入、hoveredLinkURL、updateLinkAffordance、flagsChanged、applyMouseShape 让位、linkTooltip）

- [ ] **Step 1: GhosttyTerminalView — 状态与集中更新**

在属性区（`currentCursor` 附近）新增：
```swift
    /// 当前 hover 命中的链接 URL（来自 ghostty MOUSE_OVER_LINK）；nil 表示未在链接上。
    private var hoveredLinkURL: String?
    private let linkTooltip = LinkHintTooltip()
```

新增方法（放在 `applyMouseShape` 附近）：
```swift
    /// ghostty 通知 hover 命中/离开链接。url 非 nil 表示在链接上。
    func applyHoveredLink(_ url: String?) {
        hoveredLinkURL = url
        updateLinkAffordance()
    }

    /// 根据「是否在链接上」与「真实 Cmd 是否按下」集中决定光标与 tooltip。
    /// 普通 hover 链接：iBeam + 显示提示；Cmd+hover 链接：手型 + 隐藏提示。
    private func updateLinkAffordance() {
        let cmdHeld = NSEvent.modifierFlags.contains(.command)
        if hoveredLinkURL != nil {
            currentCursor = cmdHeld ? .pointingHand : .iBeam
            if cmdHeld {
                linkTooltip.hide()
            } else {
                linkTooltip.show(L10n.string("terminal.link.openHint"), at: NSEvent.mouseLocation)
            }
        } else {
            currentCursor = .iBeam
            linkTooltip.hide()
        }
        // 若鼠标正悬在自身上，立即生效。
        if let window = window, window.isKeyWindow {
            let pt = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if bounds.contains(pt) { currentCursor.set() }
        }
    }
```

- [ ] **Step 2: GhosttyTerminalView — applyMouseShape 让位 + flagsChanged**

把现有 `applyMouseShape(_:)` 改成在 hover 链接时让位（链接光标由 updateLinkAffordance 接管）。在方法体最前面加一行 guard：
```swift
    func applyMouseShape(_ cursor: NSCursor) {
        // 链接 hover 期间光标由 updateLinkAffordance 接管，避免与注入产生的 POINTER 打架。
        guard hoveredLinkURL == nil else { return }
        currentCursor = cursor
        if let window = window, window.isKeyWindow {
            let pt = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if bounds.contains(pt) {
                cursor.set()
            }
        }
    }
```
（保留原有的「鼠标在自身上则立即 set」逻辑，只是在最前面加 guard。读现有实现，确保只加 guard、不破坏其余。）

新增 `flagsChanged` override（放在 mouseMoved 附近）：
```swift
    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        // Cmd 的按下/松开会切换链接光标与 tooltip（即便鼠标没动）。
        updateLinkAffordance()
    }
```

- [ ] **Step 3: GhosttyTerminalView — mouseMoved 注入 SUPER**

把 Phase 1 的 `mouseMoved` 改为注入伪造 super：
```swift
    override func mouseMoved(with event: NSEvent) {
        guard isCursorOverSelf(event) else { return }
        guard let s = surface else { return }
        let pt = flippedPoint(event.locationInWindow)
        // 注入 SUPER：让 ghostty 在普通 hover 也判定链接可高亮，从而画下划线并发
        // MOUSE_OVER_LINK。点击事件（mouseDown）仍传真实修饰键，且按下按钮前会先用真实
        // mods 发一次 mouse_pos 清掉这里的伪造状态，故只有真·Cmd+单击才会打开链接。
        var raw = modsFromEvent(event).rawValue
        raw |= GHOSTTY_MODS_SUPER.rawValue
        ghostty_surface_mouse_pos(s, pt.x, pt.y, ghostty_input_mods_e(rawValue: raw))
    }
```

- [ ] **Step 4: GhosttyBridge — MOUSE_OVER_LINK case**

在 `actionCallback` 的 `GHOSTTY_ACTION_MOUSE_SHAPE` case 之后、`default` 之前新增：
```swift
        case GHOSTTY_ACTION_MOUSE_OVER_LINK:
            guard target.tag == GHOSTTY_TARGET_SURFACE,
                  let surface = target.target.surface
            else { return true }
            let mol = action.action.mouse_over_link
            let url: String?
            if let ptr = mol.url, mol.len > 0 {
                url = String(data: Data(bytes: UnsafeRawPointer(ptr), count: Int(mol.len)), encoding: .utf8)
            } else {
                url = nil
            }
            DispatchQueue.main.async {
                guard let view = GhosttyTerminalView.view(forSurface: surface) else { return }
                view.applyHoveredLink(url)
            }
            return true
```

- [ ] **Step 5: 构建**

Run: `xcodebuild -project mux0.xcodeproj -scheme mux0 -configuration Debug build 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

- [ ] **Step 6: 提交**

```bash
git add mux0/Ghostty/GhosttyBridge.swift mux0/Ghostty/GhosttyTerminalView.swift
git commit -m "feat(ghostty): plain-hover link underline + tooltip via modifier injection"
```

---

## Task 9: 全量测试 + 文档

**Files:**
- Modify: `docs/ghostty-integration.md`

- [ ] **Step 1: 全量测试**

Run: `xcodebuild test -project mux0.xcodeproj -scheme mux0Tests 2>&1 | tail -20`
Expected: TEST SUCCEEDED（含 i18n smoke 测试通过）。若失败，STOP 并报告。

- [ ] **Step 2: 更新 ghostty-integration.md**

在「### 链接交互相关 action」小节补充 `MOUSE_OVER_LINK` 与修饰键注入说明：
```markdown
- `GHOSTTY_ACTION_MOUSE_OVER_LINK` — hover 命中/离开链接时通知 URL；用于驱动
  `LinkHintTooltip` 提示与链接光标（经 `GhosttyTerminalView.applyHoveredLink`）。
- 普通 hover 也想要下划线/提示：`mouseMoved` 转发时注入 `GHOSTTY_MODS_SUPER`
  伪造 Cmd，使 ghostty 在无修饰键时也高亮链接并发 MOUSE_OVER_LINK；点击事件传真实
  修饰键，故仅真·Cmd+单击打开。光标与 tooltip 由 `updateLinkAffordance` 按真实 Cmd
  状态接管（`applyMouseShape` 在 hover 链接期间让位）。
```
（读现有小节，衔接自然、不重复。）

- [ ] **Step 3: 提交**

```bash
git add docs/ghostty-integration.md
git commit -m "docs(ghostty): document MOUSE_OVER_LINK + modifier injection"
```

---

## 手动验证（实现完成后由用户执行）

1. `xcodebuild build` 通过，用户自行重启 app。
2. `echo https://example.com`：
   - 普通 hover → 出现下划线 + tooltip「⌘ + 单击打开链接」，光标仍是 iBeam。
   - 按住 Cmd hover → 下划线 + 手型光标，tooltip 隐藏。
   - 普通单击 → 不打开链接（只定位/选择）。
   - Cmd+单击 → 浏览器打开。
3. 多 pane：仅焦点 pane 响应；离开链接 tooltip 消失。
4. 重点验证「修饰键注入」无副作用：普通单击不误开、拖拽选区正常。
