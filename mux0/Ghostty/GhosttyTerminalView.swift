import AppKit
import QuartzCore

/// NSView that owns a ghostty_surface_t and renders via ghostty's internal Metal renderer.
final class GhosttyTerminalView: NSView, NSTextInputClient {
    private var surface: ghostty_surface_t?
    private var displayLink: CVDisplayLink?

    // MARK: NSTextInputClient state
    /// 本轮 keyDown 中由 `insertText` 收集到的已提交文本。随 keyDown 开始清空、结束读取。
    private var keyTextAccumulator: String = ""
    /// 仅在 `keyDown(with:)` 调用栈内为 true。用于区分 "按键驱动" 与 "IME 面板主动提交" 两类
    /// `insertText`：前者经 ghostty_surface_key 统一走 text 字段，后者必须立即走 ghostty_surface_text。
    private var insideKeyDown: Bool = false
    /// IME 正在组字时的 preedit 字符串。空字符串表示没有组字中的状态。
    private let markedTextStore = NSMutableAttributedString()

    /// 全局注册表：所有活着的 GhosttyTerminalView。
    private static var registry = NSHashTable<GhosttyTerminalView>.weakObjects()

    /// 当前唯一的"活的" surface。displayLink 回调里只有 currentFrontmost === self
    /// 才会调用 ghostty_surface_draw —— 这是切断 ghostty 内部光标轮询的总闸门。
    /// (libghostty 在 draw 里通过 +[NSEvent mouseLocation] 主动读全局光标,
    /// 想阻止它就只能让它根本不进入 draw。)
    private static weak var currentFrontmost: GhosttyTerminalView?

    /// 非聚焦 pane 的不透明度（0…1）。由 SettingsConfigStore 的
    /// `unfocused-split-opacity` 驱动。ghostty 原生该配置只对其内建 split tree 生效,
    /// mux0 用独立 surface + NSSplitView 自绘，需要我们自己在 view 层 apply alpha。
    private static var unfocusedOpacity: CGFloat = 1.0

    /// The model-layer UUID this view represents. Set by TabContentView right after
    /// construction. Used by GhosttyBridge.actionCallback to route ghostty action
    /// callbacks (e.g. COMMAND_FINISHED) back to TerminalStatusStore.
    var terminalId: UUID?

    // MARK: - Scrollbar state (consumed by SurfaceScrollView)

    /// Rows reported by ghostty's SCROLLBAR action.
    /// - `total`: total rows (scrollback + active)
    /// - `offset`: first visible row index (0 = top of history)
    /// - `len`: visible row count
    struct ScrollbarState: Equatable {
        let total: UInt64
        let offset: UInt64
        let len: UInt64
    }

    /// Last scrollbar state from ghostty, or nil if never reported.
    private(set) var scrollbarState: ScrollbarState?

    /// Cell dimensions in points (already converted from backing px). Reported by
    /// ghostty's CELL_SIZE action when font/scale changes. Zero until first update.
    private(set) var cellSize: CGSize = .zero

    /// Posted with `object: GhosttyTerminalView` whenever `scrollbarState` changes.
    static let scrollbarDidChangeNotification =
        Notification.Name("GhosttyTerminalView.scrollbarDidChange")

    /// Posted with `object: GhosttyTerminalView` whenever `cellSize` changes.
    static let cellSizeDidChangeNotification =
        Notification.Name("GhosttyTerminalView.cellSizeDidChange")

    /// Apply a new scrollbar state from the action callback (main-queue only).
    /// No-op if unchanged. Posts `scrollbarDidChangeNotification`.
    func applyScrollbar(_ s: ScrollbarState) {
        guard scrollbarState != s else { return }
        scrollbarState = s
        NotificationCenter.default.post(name: Self.scrollbarDidChangeNotification, object: self)
    }

    /// Apply a new cell size in **backing pixels**. Converts to points using this
    /// view and posts `cellSizeDidChangeNotification`.
    func applyCellSize(backingWidth: Double, backingHeight: Double) {
        let pt = convertFromBacking(NSSize(width: backingWidth, height: backingHeight))
        let size = CGSize(width: pt.width, height: pt.height)
        guard cellSize != size else { return }
        cellSize = size
        NotificationCenter.default.post(name: Self.cellSizeDidChangeNotification, object: self)
    }

    /// Run an arbitrary ghostty binding-action DSL string. Used by e.g. SurfaceScrollView
    /// to send `scroll_to_row:N` when the user drags the scrollbar.
    @discardableResult
    func performBindingAction(_ action: String) -> Bool { runBindingAction(action) }

    /// Injected by TabContentView right after construction. When present,
    /// `viewDidMoveToWindow` reads `pwd(for: terminalId)` and feeds it into
    /// ghostty's `working_directory` so the spawned PTY shell starts in the
    /// inherited / last-known directory.
    var pwdStoreRef: TerminalPwdStore?

    /// Injected by TabContentView. Fired on `mouseDown` so the owning tab can
    /// update `WorkspaceStore.focusedTerminalId`. Cannot rely on the enclosing
    /// SplitPaneView's `mouseDown` because this view consumes the event first.
    var onFocus: (() -> Void)?

    /// Map from the opaque ghostty_surface_t pointer back to the owning view.
    /// The action callback only has a ghostty_target_s with the surface handle; this
    /// lookup is how we get back to Swift-land. Weak references so a freed surface
    /// won't keep its view alive.
    private static var viewBySurface: [OpaquePointer: Weak<GhosttyTerminalView>] = [:]

    /// Lookup by raw ghostty_surface_t. Returns nil if the view has been deallocated.
    static func view(forSurface surface: ghostty_surface_t) -> GhosttyTerminalView? {
        viewBySurface[OpaquePointer(surface)]?.value
    }

    /// All live surfaces across every tab/workspace. Used by GhosttyBridge.reloadConfig
    /// to push a freshly-built config to each surface. Stale weak entries are skipped.
    static func allLiveSurfaces() -> [ghostty_surface_t] {
        registry.allObjects.compactMap { $0.surface }
    }

    /// Returns `path` iff it points to an existing directory. Returns nil for
    /// nil input, nonexistent paths, regular files, and anything else. Used by
    /// `viewDidMoveToWindow` to decide whether to forward a seeded pwd to
    /// libghostty — an invalid path would make the spawned shell print a
    /// `chdir` error, so we silently fall back to ghostty's default ($HOME).
    static func validatedDirectory(_ path: String?) -> String? {
        guard let path else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
              isDir.boolValue else { return nil }
        return path
    }

    private final class Weak<T: AnyObject> {
        weak var value: T?
        init(_ value: T) { self.value = value }
    }

    static func releaseAllExcept(_ keep: GhosttyTerminalView?) {
        let zeroMods = ghostty_input_mods_e(rawValue: 0)
        for v in registry.allObjects where v !== keep {
            guard let s = v.surface else { continue }
            _ = ghostty_surface_mouse_button(s, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, zeroMods)
            _ = ghostty_surface_mouse_button(s, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, zeroMods)
            _ = ghostty_surface_mouse_button(s, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE, zeroMods)
        }
    }

    /// 切换前台 terminal。
    /// - 把 `front` 设为唯一允许 draw / 接收事件的 surface
    /// - 其它 surface: focus=false, occlusion=true, RELEASE 按键, 光标 park 到屏外
    /// - 不再发 click cycle（之前的 click cycle 反而在 ghostty 里建立了 selection anchor，
    ///   配合 ghostty 的 mouseLocation 轮询正好造成"鼠标飘到哪选到哪"）
    static func makeFrontmost(_ front: GhosttyTerminalView?) {
        guard currentFrontmost !== front else { return }
        currentFrontmost = front
        let zeroMods = ghostty_input_mods_e(rawValue: 0)
        for v in registry.allObjects {
            guard let s = v.surface else { continue }
            let isFront = (v === front)
            ghostty_surface_set_focus(s, isFront)
            ghostty_surface_set_occlusion(s, !isFront)
            // 任何切换都对所有 surface 做一次 defensive RELEASE，
            // 防止前一次交互留下未配对的 PRESS。RELEASE 不会影响 ghostty 已提交的选区，
            // 仅清理 button 状态，所以是安全的。
            _ = ghostty_surface_mouse_button(s, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, zeroMods)
            _ = ghostty_surface_mouse_button(s, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, zeroMods)
            _ = ghostty_surface_mouse_button(s, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE, zeroMods)
            if !isFront {
                // park 到屏外一个明确无效的坐标，避免 ghostty 内部 stale cursor pos
                // 落在某个 cell 上被绘制成 hover/选区。
                ghostty_surface_mouse_pos(s, -1, -1, zeroMods)
            }
        }
        applyUnfocusedOpacity()
    }

    /// 设置非聚焦 pane 的不透明度。立即对现有 view 生效。
    static func setUnfocusedOpacity(_ value: CGFloat) {
        let clamped = max(0.0, min(1.0, value))
        guard clamped != unfocusedOpacity else { return }
        unfocusedOpacity = clamped
        applyUnfocusedOpacity()
    }

    /// 给当前 window 内的每个 view 设 alphaValue：currentFrontmost → 1.0，
    /// 同 window 内其他 → unfocusedOpacity。不在 window 里的 view 也重置回 1.0,
    /// 避免它们将来重新挂回来时还带着旧的变暗状态。
    private static func applyUnfocusedOpacity() {
        for v in registry.allObjects {
            if v === currentFrontmost || v.window == nil {
                v.alphaValue = 1.0
            } else {
                v.alphaValue = unfocusedOpacity
            }
        }
    }

    var rawSurface: ghostty_surface_t? { surface }

    override init(frame: NSRect) {
        super.init(frame: frame)
        Self.registry.add(self)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        wantsLayer = true
        // ghostty renders into the view's backing layer.
        // The NSView pointer is passed to libghostty via GhosttyBridge.newSurface.
        updateTrackingAreas()
        // 接收从 Finder / 其他 app 拖进来的文件（注入 shell-escape 的路径）和文本。
        registerForDraggedTypes([.fileURL, .string])
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }
        // 只在自己是 first responder 时接收 mouseMoved，
        // 防止非聚焦 terminal 也收到鼠标位置更新（导致下层假性选区）。
        let options: NSTrackingArea.Options = [
            .activeWhenFirstResponder, .mouseMoved, .inVisibleRect
        ]
        addTrackingArea(NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // When the view leaves the window (e.g. its enclosing SplitPaneView is being
        // swapped out on a tab/workspace switch) we must stop the display link so it
        // stops driving ghostty_surface_draw into a layer that has no presentation
        // target. Re-entering the window restarts the link; the ghostty surface itself
        // is kept alive (we only free it in deinit) so shell state is preserved.
        guard window != nil else {
            stopDisplayLink()
            return
        }
        if surface == nil {
            let scale = window?.backingScaleFactor ?? 2.0
            let seed = terminalId.flatMap { pwdStoreRef?.pwd(for: $0) }
            let validated = Self.validatedDirectory(seed)
            surface = GhosttyBridge.shared.newSurface(
                nsView: self,
                scaleFactor: scale,
                workingDirectory: validated,
                terminalId: terminalId ?? UUID()
            )
            if let s = surface {
                GhosttyTerminalView.viewBySurface[OpaquePointer(s)] = Weak(self)   // NEW
                let w = UInt32(bounds.width * scale)
                let h = UInt32(bounds.height * scale)
                ghostty_surface_set_size(s, w, h)
                ghostty_surface_set_content_scale(s, scale, scale)
            }
        }
        // Only start a display link if none is running. Without this guard every
        // re-parent would leak a CVDisplayLink (old one keeps firing), racing with
        // the new one and interleaving draws on the same surface.
        if displayLink == nil {
            startDisplayLink()
        }
    }

    deinit {
        stopDisplayLink()
        if let s = surface {
            GhosttyTerminalView.viewBySurface.removeValue(forKey: OpaquePointer(s))
            ghostty_surface_free(s)
        }
    }

    // MARK: - Display link

    private func startDisplayLink() {
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        guard let dl = displayLink else { return }
        CVDisplayLinkSetOutputCallback(dl, { _, _, _, _, _, ctx -> CVReturn in
            guard let ctx else { return kCVReturnSuccess }
            let view = Unmanaged<GhosttyTerminalView>.fromOpaque(ctx).takeUnretainedValue()
            // Retain explicitly for the async block so it stays alive until draw completes
            let retained = Unmanaged.passRetained(view)
            DispatchQueue.main.async {
                let v = retained.takeRetainedValue()
                // 关键：只有当前前台 surface 才 draw。
                // libghostty 在 draw 内部会 +[NSEvent mouseLocation] 主动读全局光标，
                // 不让它 draw 就不让它读，从根源切断"鼠标飘到哪选到哪"的循环。
                guard GhosttyTerminalView.currentFrontmost === v else { return }
                if let s = v.surface { ghostty_surface_draw(s) }
            }
            return kCVReturnSuccess
        }, Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(dl)
    }

    private func stopDisplayLink() {
        if let dl = displayLink {
            CVDisplayLinkStop(dl)
            self.displayLink = nil
        }
    }

    // MARK: - Layout

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard let s = surface else { return }
        // Ignore transient zero-sized frames. These happen when the enclosing
        // SplitPaneView is being swapped out and briefly leaves subviews at .zero
        // before layout propagates the real size. Forwarding a (0, 0) size to
        // ghostty tears down its Metal renderer and the surface comes back blank
        // (black screen) even after the real size arrives on the next pass.
        guard newSize.width > 0, newSize.height > 0 else { return }
        let scale = window?.backingScaleFactor ?? 2.0
        let w = UInt32(newSize.width * scale)
        let h = UInt32(newSize.height * scale)
        ghostty_surface_set_size(s, w, h)
        ghostty_surface_set_content_scale(s, scale, scale)
    }

    // MARK: - Focus

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        if let s = surface { ghostty_surface_set_focus(s, true) }
        return true
    }

    override func resignFirstResponder() -> Bool {
        if let s = surface {
            // 防御性释放：清掉任何可能残留的按键/拖拽选区状态，
            // 避免下次再聚焦时出现"鼠标一动就在选"的假象。
            _ = ghostty_surface_mouse_button(s, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, ghostty_input_mods_e(rawValue: 0))
            _ = ghostty_surface_mouse_button(s, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, ghostty_input_mods_e(rawValue: 0))
            ghostty_surface_set_focus(s, false)
        }
        return true
    }

    // MARK: - Binding actions

    /// Invoke a ghostty binding-action DSL string on this surface.
    /// Returns false silently if the surface isn't ready or ghostty refused.
    @discardableResult
    private func runBindingAction(_ action: String) -> Bool {
        guard let s = surface else { return false }
        return action.withCString { ptr in
            ghostty_surface_binding_action(s, ptr, UInt(action.utf8.count))
        }
    }

    /// Copy the current selection to the system clipboard.
    /// No-op (returns false) if there is no surface or no selection.
    @discardableResult
    func copySelection() -> Bool { runBindingAction("copy_to_clipboard") }

    /// Paste the system clipboard into the focused surface.
    @discardableResult
    func pasteClipboard() -> Bool { runBindingAction("paste_from_clipboard") }

    /// Select the entire scrollback contents.
    @discardableResult
    func selectAll() -> Bool { runBindingAction("select_all") }

    // MARK: - Keyboard input

    override func keyDown(with event: NSEvent) {
        guard let s = surface else { super.keyDown(with: event); return }

        // 这是 ghostty macOS 上游采用的"先走 NSTextInputClient、再单次交付给 ghostty"协议：
        //
        //   1. interpretKeyEvents 驱动输入法与键绑定翻译：
        //       - 普通可打印字符 / 死键合成 / IME 候选提交 → 调回 insertText，落到 keyTextAccumulator
        //       - IME 正在组字 → 调回 setMarkedText，只更新 preedit，不落到 accumulator
        //       - Backspace/Arrow/Enter 等特殊键 → 调回 doCommand，我们 no-op 掉，让 keycode 路径处理
        //   2. interpretKeyEvents 返回后，用一次 ghostty_surface_key 把 "文本 + 原始 keycode + 组字标志"
        //      一起交付给 ghostty，由 ghostty 自行决定是作为 binding 消费、作为文本写入 PTY，
        //      还是按 keycode 翻译成 C0 / 转义序列。
        let hadMarkedTextBefore = hasMarkedText()
        insideKeyDown = true
        keyTextAccumulator = ""
        interpretKeyEvents([event])
        let committedText = keyTextAccumulator
        keyTextAccumulator = ""
        insideKeyDown = false

        // IME 消费了本次按键的情况：之前在组字，按键后既没产生提交文本，组字状态也被清掉。
        // 典型例子是在有 preedit 时按 Backspace 删掉最后一个拼音字符，或按 Esc 取消组字。
        // 此时不能把原始 keycode 再交给 ghostty，否则 ghostty 会把 Backspace 当成真正的
        // 退格发给 PTY，把前一个已提交的汉字也一起删掉。
        if hadMarkedTextBefore && committedText.isEmpty && !hasMarkedText() {
            return
        }

        let action: ghostty_input_action_e = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        let mods = modsFromEvent(event)
        let consumedMods = consumedModsFromEvent(event)
        let keycode = UInt32(event.keyCode)
        // unshifted_codepoint 必须是"完全无修饰符"的字符（含 shift 也要剥离）。
        // `charactersIgnoringModifiers` 的坑：按 Apple 文档它会忽略除 Shift 以外的所有修饰符，
        // 所以 Shift+9 返回的是 '(' 而非 '9'。ghostty 的 binding 解析依赖真正的 unshifted 键来
        // 识别物理键位，传入 '(' 会让 `shift+(` 这种荒谬组合走进未匹配 binding 路径，最终被
        // 整个事件丢弃——表现就是"Shift+9 / Shift+0 / Shift+- / Shift+` / Shift+1"等键无任何输出。
        // 上游 ghostty 的 NSEvent+Extension.swift 走的是 characters(byApplyingModifiers: [])。
        let unshifted: UInt32 = event.characters(byApplyingModifiers: [])?
            .unicodeScalars.first?.value ?? 0
        let composing = hasMarkedText()

        func send(_ cstr: UnsafePointer<CChar>?) {
            var input = ghostty_input_key_s()
            input.action = action
            input.mods = mods
            input.consumed_mods = consumedMods
            input.keycode = keycode
            input.text = cstr
            input.unshifted_codepoint = unshifted
            input.composing = composing
            _ = ghostty_surface_key(s, input)
        }

        if !committedText.isEmpty {
            committedText.withCString { send($0) }
        } else {
            send(nil)
        }
    }

    /// NSTextInputClient / NSStandardKeyBindingResponding 会对非文本键 (Backspace/Arrow/Home/...)
    /// 回调 `doCommand(by:)`。我们统一 no-op：
    ///   - 这些键已经在 keyDown 的 keycode 路径交给 ghostty 处理（ghostty 会翻译成 ^H / ESC[D / ...）
    ///   - 如果 fall through 到 super，AppKit 会在 responder 链找不到目标时调用 noResponder(for:)，
    ///     发出系统 beep，体验极差。
    override func doCommand(by selector: Selector) {
        // intentional no-op
    }

    override func keyUp(with event: NSEvent) {
        guard let s = surface else { return }
        var input = ghostty_input_key_s()
        input.action = GHOSTTY_ACTION_RELEASE
        input.mods = modsFromEvent(event)
        input.consumed_mods = consumedModsFromEvent(event)
        input.keycode = UInt32(event.keyCode)
        input.text = nil
        input.unshifted_codepoint = event.characters(byApplyingModifiers: [])?
            .unicodeScalars.first?.value ?? 0
        input.composing = false
        _ = ghostty_surface_key(s, input)
    }

    // MARK: - Mouse input

    override func mouseDown(with event: NSEvent) {
        // This view consumes the event before SplitPaneView sees it, so notify
        // the owner here so `focusedTerminalId` tracks the actual user focus.
        onFocus?()
        Self.makeFrontmost(self)
        window?.makeFirstResponder(self)
        guard let s = surface else { return }
        let pt = flippedPoint(event.locationInWindow)
        ghostty_surface_mouse_pos(s, pt.x, pt.y, modsFromEvent(event))
        _ = ghostty_surface_mouse_button(
            s,
            GHOSTTY_MOUSE_PRESS,
            GHOSTTY_MOUSE_LEFT,
            modsFromEvent(event)
        )
    }

    override func mouseUp(with event: NSEvent) {
        guard let s = surface else { return }
        let pt = flippedPoint(event.locationInWindow)
        ghostty_surface_mouse_pos(s, pt.x, pt.y, modsFromEvent(event))
        _ = ghostty_surface_mouse_button(
            s,
            GHOSTTY_MOUSE_RELEASE,
            GHOSTTY_MOUSE_LEFT,
            modsFromEvent(event)
        )
    }

    override func rightMouseDown(with event: NSEvent) {
        Self.releaseAllExcept(self)
        guard let s = surface else { return }
        let pt = flippedPoint(event.locationInWindow)
        ghostty_surface_mouse_pos(s, pt.x, pt.y, modsFromEvent(event))
        _ = ghostty_surface_mouse_button(
            s,
            GHOSTTY_MOUSE_PRESS,
            GHOSTTY_MOUSE_RIGHT,
            modsFromEvent(event)
        )
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let s = surface else { return }
        let pt = flippedPoint(event.locationInWindow)
        ghostty_surface_mouse_pos(s, pt.x, pt.y, modsFromEvent(event))
        _ = ghostty_surface_mouse_button(
            s,
            GHOSTTY_MOUSE_RELEASE,
            GHOSTTY_MOUSE_RIGHT,
            modsFromEvent(event)
        )
    }

    override func otherMouseDown(with event: NSEvent) {
        Self.releaseAllExcept(self)
        guard let s = surface else { return }
        let pt = flippedPoint(event.locationInWindow)
        ghostty_surface_mouse_pos(s, pt.x, pt.y, modsFromEvent(event))
        _ = ghostty_surface_mouse_button(
            s,
            GHOSTTY_MOUSE_PRESS,
            GHOSTTY_MOUSE_MIDDLE,
            modsFromEvent(event)
        )
    }

    override func otherMouseUp(with event: NSEvent) {
        guard let s = surface else { return }
        let pt = flippedPoint(event.locationInWindow)
        ghostty_surface_mouse_pos(s, pt.x, pt.y, modsFromEvent(event))
        _ = ghostty_surface_mouse_button(
            s,
            GHOSTTY_MOUSE_RELEASE,
            GHOSTTY_MOUSE_MIDDLE,
            modsFromEvent(event)
        )
    }

    override func mouseMoved(with event: NSEvent) {
        // 故意不转发 hover 位置：mux0 是多窗口浮动布局，
        // ghostty 内部对未匹配 PRESS 的 mouse_pos 推进可能引发"鼠标飘到哪里就在哪里画选区"的假象。
        // hover 仅用于 link 高亮等次要特性，宁可放弃也不要在底层 terminal 上误触发选中。
    }

    override func mouseDragged(with event: NSEvent) {
        // mouseDragged 只在自己接到过 mouseDown 时触发，无需 hitTest 守卫。
        guard let s = surface else { return }
        let pt = flippedPoint(event.locationInWindow)
        ghostty_surface_mouse_pos(s, pt.x, pt.y, modsFromEvent(event))
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard let s = surface else { return }
        let pt = flippedPoint(event.locationInWindow)
        ghostty_surface_mouse_pos(s, pt.x, pt.y, modsFromEvent(event))
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard let s = surface else { return }
        let pt = flippedPoint(event.locationInWindow)
        ghostty_surface_mouse_pos(s, pt.x, pt.y, modsFromEvent(event))
    }

    override func scrollWheel(with event: NSEvent) {
        guard isCursorOverSelf(event) else { return }
        guard let s = surface else { return }

        // Mirror upstream ghostty macOS: without the precision bit, precise trackpad
        // deltas (tiny pt values) get treated as line counts and scroll far too fast.
        // Layout of ghostty_input_scroll_mods_t: [bit0 = precision][bits1-3 = momentum].
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precision = event.hasPreciseScrollingDeltas
        if precision {
            x *= 2
            y *= 2
        }

        var mods: Int32 = 0
        if precision { mods |= 0b1 }
        let momentum: Int32
        switch event.momentumPhase {
        case .began:      momentum = 1
        case .stationary: momentum = 2
        case .changed:    momentum = 3
        case .ended:      momentum = 4
        case .cancelled:  momentum = 5
        case .mayBegin:   momentum = 6
        default:          momentum = 0
        }
        mods |= momentum << 1

        ghostty_surface_mouse_scroll(s, x, y, ghostty_input_scroll_mods_t(mods))
    }

    // MARK: - Drag and drop

    /// 接收外部拖进来的文件 URL / 文本。文件路径会经过 shell 转义后以空格拼接注入 PTY，
    /// 表现对齐 ghostty 官方 macOS 客户端：拖 Finder 文件进终端即在光标处插入可直接使用的参数串。
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        acceptedDragOperation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        acceptedDragOperation(for: sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let s = surface else { return false }
        let pb = sender.draggingPasteboard

        // 拖放本身已经明确指向这个 pane，把 focus 切过来，注入的文本才会去用户期望的终端。
        onFocus?()
        Self.makeFrontmost(self)
        window?.makeFirstResponder(self)

        // 优先文件 URL（Finder / 其他 app）。多文件按空格拼接，结尾补一个空格方便用户继续敲命令。
        let fileOptions: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: fileOptions) as? [URL],
           !urls.isEmpty {
            let joined = urls.map { Self.shellEscape($0.path) }.joined(separator: " ") + " "
            ghostty_surface_text(s, joined, UInt(joined.utf8.count))
            return true
        }

        // 回退：纯文本拖拽（浏览器选中文本等）直接按原样注入。
        if let text = pb.string(forType: .string), !text.isEmpty {
            ghostty_surface_text(s, text, UInt(text.utf8.count))
            return true
        }

        return false
    }

    private func acceptedDragOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        let types = sender.draggingPasteboard.types ?? []
        if types.contains(.fileURL) || types.contains(.string) {
            return .copy
        }
        return []
    }

    /// 为 shell 命令行安全注入一条路径做最小转义。全 "安全" 字符（字母数字与常见文件名标点）
    /// 直接透传，保持可读；一旦出现空格 / 引号 / shell 元字符就整体包单引号，把内嵌单引号
    /// 通过 `'\''` 序列闭合—重开的方式保留。
    private static let shellSafeChars: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "abcdefghijklmnopqrstuvwxyz")
        set.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        set.insert(charactersIn: "0123456789")
        set.insert(charactersIn: "/._-+=@:,")
        return set
    }()

    private static func shellEscape(_ path: String) -> String {
        if path.unicodeScalars.allSatisfy({ shellSafeChars.contains($0) }) {
            return path
        }
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    // MARK: - Helpers

    /// Convert window coordinates to view-local coordinates, flipped for ghostty (origin top-left).
    private func flippedPoint(_ windowPoint: NSPoint) -> NSPoint {
        let local = convert(windowPoint, from: nil)
        return NSPoint(x: local.x, y: bounds.height - local.y)
    }

    /// 当前光标位置经窗口 hitTest 后是否落到自己（或自己的祖先链）。
    /// 用于过滤掉「鼠标其实在上层 terminal 上、但下层 tracking area 也派发了事件」的情况。
    private func isCursorOverSelf(_ event: NSEvent) -> Bool {
        guard let win = window else { return false }
        let hit = win.contentView?.hitTest(event.locationInWindow)
        var v: NSView? = hit
        while let cur = v {
            if cur === self { return true }
            v = cur.superview
        }
        return false
    }

    private func modsFromEvent(_ event: NSEvent) -> ghostty_input_mods_e {
        var rawValue: ghostty_input_mods_e.RawValue = 0
        if event.modifierFlags.contains(.shift)   { rawValue |= GHOSTTY_MODS_SHIFT.rawValue }
        if event.modifierFlags.contains(.control) { rawValue |= GHOSTTY_MODS_CTRL.rawValue }
        if event.modifierFlags.contains(.option)  { rawValue |= GHOSTTY_MODS_ALT.rawValue }
        if event.modifierFlags.contains(.command) { rawValue |= GHOSTTY_MODS_SUPER.rawValue }
        return ghostty_input_mods_e(rawValue: rawValue)
    }

    /// 告诉 ghostty 哪些修饰符已被 macOS 消耗掉用于字符翻译。与上游 ghostty 对齐：
    /// Shift / Option 参与 `characters` 的字符生成（Shift+9→'(', Option+e→死键组合），
    /// Ctrl / Cmd 不参与（它们走 binding / C0 控制码路径）。
    /// 不设置这个字段会导致 ghostty 把 `mods=SHIFT, consumed_mods=0` 解读为
    /// "用户显式想触发 shift+key 绑定"，未命中绑定时事件被丢弃，表现为 Shift+数字不出字符。
    private func consumedModsFromEvent(_ event: NSEvent) -> ghostty_input_mods_e {
        var rawValue: ghostty_input_mods_e.RawValue = 0
        if event.modifierFlags.contains(.shift)  { rawValue |= GHOSTTY_MODS_SHIFT.rawValue }
        if event.modifierFlags.contains(.option) { rawValue |= GHOSTTY_MODS_ALT.rawValue }
        return ghostty_input_mods_e(rawValue: rawValue)
    }

    // MARK: - NSTextInputClient
    //
    // 这一套方法是 macOS 文本输入系统与 ghostty 的桥：
    //   - insertText: 可打印文本 / IME 候选提交。落到 keyTextAccumulator 由 keyDown 统一交付，
    //     或（非 keyDown 上下文，例如输入法面板直接提交）立即走 ghostty_surface_text。
    //   - setMarkedText/unmarkText: IME 组字状态。直接透传给 ghostty_surface_preedit，ghostty
    //     侧决定是否在终端里显示 preedit 浮层。
    //   - hasMarkedText/markedRange: AppKit 用来判断当前是否处于组字中，配合 keyDown 的
    //     `composing` 字段一起交给 ghostty。

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        if let s = string as? String {
            text = s
        } else if let a = string as? NSAttributedString {
            text = a.string
        } else {
            return
        }
        guard !text.isEmpty else { return }

        // 一旦有"真正的提交文本"进来，立即清掉正在组字的状态（避免与 preedit 同时存在）。
        if hasMarkedText() {
            markedTextStore.mutableString.setString("")
            if let s = surface { ghostty_surface_preedit(s, nil, 0) }
        }

        if insideKeyDown {
            keyTextAccumulator.append(text)
        } else {
            // IME 面板在非 keyDown 上下文里直接提交（例如鼠标点击候选词）。
            guard let s = surface else { return }
            ghostty_surface_text(s, text, UInt(text.utf8.count))
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text: String
        if let s = string as? String {
            text = s
        } else if let a = string as? NSAttributedString {
            text = a.string
        } else {
            return
        }
        markedTextStore.mutableString.setString(text)
        guard let s = surface else { return }
        if text.isEmpty {
            ghostty_surface_preedit(s, nil, 0)
        } else {
            ghostty_surface_preedit(s, text, UInt(text.utf8.count))
        }
    }

    func unmarkText() {
        markedTextStore.mutableString.setString("")
        if let s = surface { ghostty_surface_preedit(s, nil, 0) }
    }

    func selectedRange() -> NSRange {
        NSRange(location: NSNotFound, length: 0)
    }

    func markedRange() -> NSRange {
        let len = markedTextStore.length
        return len > 0
            ? NSRange(location: 0, length: len)
            : NSRange(location: NSNotFound, length: 0)
    }

    func hasMarkedText() -> Bool {
        markedTextStore.length > 0
    }

    func attributedSubstring(
        forProposedRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSAttributedString? {
        nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    /// 输入法候选窗的锚点。macOS 会用返回的屏幕坐标矩形决定候选词浮层弹出位置。
    /// `ghostty_surface_ime_point` 返回 view-local 坐标，但原点在左上角；AppKit 非翻转视图
    /// 用左下角原点，所以 y 要翻转成 `frame.height - y`，否则候选框会掉到终端底部。
    /// w/h 缺省用 cellSize，让 surface 尚未上报尺寸时也能给 IME 一个合理的锚点矩形。
    func firstRect(
        forCharacterRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSRect {
        guard let win = window else { return .zero }
        let rectInView: NSRect
        if let surface {
            var x: Double = 0
            var y: Double = 0
            var w: Double = cellSize.width
            var h: Double = cellSize.height
            ghostty_surface_ime_point(surface, &x, &y, &w, &h)
            rectInView = NSRect(
                x: x,
                y: frame.size.height - y,
                width: w,
                height: max(h, cellSize.height)
            )
        } else {
            rectInView = NSRect(x: 0, y: 0, width: 1, height: 1)
        }
        let inWindow = convert(rectInView, to: nil)
        return win.convertToScreen(inWindow)
    }

    func characterIndex(for point: NSPoint) -> Int {
        NSNotFound
    }
}
