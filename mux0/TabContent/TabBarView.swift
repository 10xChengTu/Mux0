import AppKit
import SwiftUI

// MARK: - TabBarView

/// Horizontal tab strip. Notifies via callbacks; never touches the store directly.
final class TabBarView: NSView {
    var onSelectTab: ((UUID) -> Void)?
    var onAddTab: (() -> Void)?
    var onCloseTab: ((UUID) -> Void)?
    var onRenameTab: ((UUID, String) -> Void)?
    /// (fromIndex, toIndex) 采用 insertion-index 语义（0…count），
    /// 与 `WorkspaceStore.moveTab(fromIndex:toIndex:in:)` 对齐
    var onReorderTab: ((Int, Int) -> Void)?
    /// 若 tab 总数 ≤ 1，TabItemView 禁用 × 按钮与菜单 Close 项
    private var canClose: Bool { tabs.count > 1 }

    /// strip 的固有高度——外层由 TabContentView 统一负责 4pt 内缩。
    static let height: CGFloat = 32
    /// 单位间距：同时用于 (1) pill 到 strip 顶/底 (2) tab 之间 (3) 首尾 tab 到 strip 左右
    static let pillInset: CGFloat = 3
    /// 同心圆角：外层 card 的半径减去 TabContentView 统一提供的内缩。
    static var stripRadius: CGFloat { DT.Radius.card - DT.Space.xs }
    /// 同心圆角：strip 半径减去 pill 到 strip 的内缩
    static var pillRadius: CGFloat { max(0, stripRadius - pillInset) }
    /// 单个 tab pill 的固定宽度。SettingsTabBarView 复用同一常数以保持视觉对齐。
    static let tabItemWidth: CGFloat = 140

    private var theme: AppTheme = .systemFallback(isDark: true)
    /// Mirror of ghostty `background-opacity`. Applied to tab pill fills so
    /// selected/hovered pills don't paint an opaque canvas slab when the rest
    /// of the window is transparent.
    private var backgroundOpacity: CGFloat = 1.0
    private var tabs: [TerminalTab] = []
    private var selectedTabId: UUID?
    private var statuses: [UUID: TerminalStatus] = [:]
    private var showStatusIndicators: Bool = false
    /// Current locale forwarded from LanguageStore via TabContentView → TabBridge.
    /// Used to resolve LocalizedStringResource in makeAddButton() so the "+" tooltip
    /// tracks the user's in-app language choice rather than Locale.current.
    var locale: Locale = .current

    private let stripContainer = NSView()
    private let scrollView = NSScrollView()
    private let tabsContainer = NSView()
    private var addHost: NSHostingView<AnyView>!
    private static let addHostSize: CGFloat = 22

    // Drag preview 状态：让 tabs 在拖拽中实时重排到 "若此刻松手会变成的顺序"。
    /// 当前被拖的 tab id（由 pasteboard 在 draggingEntered 时读出）。
    private var draggingTabId: UUID?
    /// 当前鼠标对应的 insertion index（0…tabs.count）。
    private var previewInsertionIndex: Int?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        wantsLayer = true

        stripContainer.wantsLayer = true
        stripContainer.layer?.masksToBounds = true
        addSubview(stripContainer)

        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.documentView = tabsContainer
        scrollView.autoresizingMask = []
        stripContainer.addSubview(scrollView)

        addHost = NSHostingView(rootView: makeAddButton())
        addSubview(addHost)
        registerForDraggedTypes([.mux0Tab])
    }

    override func layout() {
        super.layout()
        let hPad = Self.pillInset
        let addW: CGFloat = 28
        let stripW = max(0, bounds.width - addW)
        stripContainer.frame = NSRect(x: 0, y: 0, width: stripW, height: bounds.height)
        stripContainer.layer?.cornerRadius = Self.stripRadius
        scrollView.frame = NSRect(x: hPad, y: 0,
                                  width: max(0, stripW - hPad * 2), height: bounds.height)
        let hostSize = Self.addHostSize
        addHost.frame = NSRect(
            x: bounds.width - addW + (addW - hostSize) / 2,
            y: (bounds.height - hostSize) / 2,
            width: hostSize, height: hostSize)
        layoutTabItems()
    }

    func update(tabs: [TerminalTab],
                selectedTabId: UUID?,
                theme: AppTheme,
                statuses: [UUID: TerminalStatus] = [:],
                backgroundOpacity: CGFloat = 1.0,
                showStatusIndicators: Bool = false) {
        self.tabs = tabs
        self.selectedTabId = selectedTabId
        self.theme = theme
        self.statuses = statuses
        self.backgroundOpacity = backgroundOpacity
        self.showStatusIndicators = showStatusIndicators
        rebuildTabItems()   // tab items are already initialised with correct theme
        applyTheme(theme, backgroundOpacity: backgroundOpacity)   // re-apply theme to non-tab elements (layer bg, addButton tint)
    }

    /// 复用现有 TabItemView——仅在 tabs 的 id 序列变化时才完整重建。
    /// 这一点对拖拽和 rename 都关键：若 mouseDown → onSelect → reloadFromStore →
    /// rebuildTabItems 销毁了刚收到 mouseDown 的 view，后续 mouseDragged 永远收不到；
    /// 同样，inline rename 中任何 reload 都会毁掉 NSTextField。改为 id-diff 后：
    ///   · 只是 selection 切换 → 所有 view 保留，只刷 isSelected 样式
    ///   · tabs 真正增删或重排 → 整体重建（用户不会在此时拖或 rename，安全）
    private func rebuildTabItems() {
        let existing = tabsContainer.subviews.compactMap { $0 as? TabItemView }
        let existingIds = existing.map(\.tabId)
        let targetIds = tabs.map(\.id)
        let canCloseNow = canClose

        if existingIds == targetIds {
            // 仅 selection / title / canClose 可能变化——原地刷新，保留 view 实例（拖拽与 rename 继续可用）
            for item in existing {
                let isSel = item.tabId == selectedTabId
                if let tab = tabs.first(where: { $0.id == item.tabId }) {
                    let tabStatus = TerminalStatus.aggregate(
                        tab.layout.allTerminalIds().map { statuses[$0] ?? .neverRan }
                    )
                    item.refresh(tab: tab, isSelected: isSel, theme: theme, canClose: canCloseNow, status: tabStatus, backgroundOpacity: backgroundOpacity, showStatusIndicators: showStatusIndicators)
                }
            }
            return
        }

        // 结构变化：完整重建
        existing.forEach { $0.removeFromSuperview() }
        for tab in tabs {
            let tabStatus = TerminalStatus.aggregate(
                tab.layout.allTerminalIds().map { statuses[$0] ?? .neverRan }
            )
            let item = TabItemView(tab: tab, isSelected: tab.id == selectedTabId, theme: theme, status: tabStatus, backgroundOpacity: backgroundOpacity, showStatusIndicators: showStatusIndicators)
            item.canClose = canCloseNow
            item.onSelect = { [weak self] in self?.onSelectTab?(tab.id) }
            item.onClose  = { [weak self] in self?.onCloseTab?(tab.id) }
            item.onRename = { [weak self] newTitle in self?.onRenameTab?(tab.id, newTitle) }
            // drop 失败（拖到 TabBarView 外）时，source 端 sessionEnded 会触发——清理 preview state
            item.onDragEnded = { [weak self] in self?.cleanupAfterDrag() }
            tabsContainer.addSubview(item)
        }
        layoutTabItems()
    }

    /// 默认按 self.tabs 顺序排布。拖拽中 draggingTabId/previewInsertionIndex 有值时，
    /// 按 "如果此刻松手的结果" 顺序排布——被拖 item 仍占位但视觉淡化，其他 item 平移。
    private func layoutTabItems(animated: Bool = false) {
        let items = tabsContainer.subviews.compactMap { $0 as? TabItemView }
        let ordered = previewOrdered(items: items)
        let tabW = Self.tabItemWidth
        let gap = Self.pillInset
        let h = stripContainer.bounds.height

        let apply = {
            var x: CGFloat = 0
            for (i, item) in ordered.enumerated() {
                let frame = NSRect(x: x, y: 0, width: tabW, height: h)
                if animated {
                    item.animator().frame = frame
                } else {
                    item.frame = frame
                }
                x += tabW + (i == ordered.count - 1 ? 0 : gap)
                item.isDragGhost = (item.tabId == self.draggingTabId)
            }
            self.tabsContainer.frame = NSRect(
                x: 0, y: 0,
                width: max(x, self.scrollView.frame.width),
                height: h)
        }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.allowsImplicitAnimation = true
                apply()
            }
        } else {
            apply()
        }
    }

    /// 返回应当显示的 tab 顺序（考虑 drag preview）。
    private func previewOrdered(items: [TabItemView]) -> [TabItemView] {
        guard let draggingTabId,
              let insertion = previewInsertionIndex,
              let fromIdx = items.firstIndex(where: { $0.tabId == draggingTabId })
        else { return items }

        var copy = items
        let picked = copy.remove(at: fromIdx)
        // insertion 用 "before index" 语义（0…items.count，含被拖项时的原索引）；
        // 移除被拖项后需要把 > fromIdx 的 insertion 左移一位。
        let dest = insertion > fromIdx ? insertion - 1 : insertion
        copy.insert(picked, at: max(0, min(copy.count, dest)))
        return copy
    }

    func applyTheme(_ theme: AppTheme, backgroundOpacity: CGFloat = 1.0) {
        self.theme = theme
        self.backgroundOpacity = backgroundOpacity
        // The bar itself is an invisible host for the rounded strip + "+" button;
        // painting it with canvas paints a visible rectangle around the strip once
        // the window becomes transparent.
        layer?.backgroundColor = .clear
        stripContainer.layer?.backgroundColor = theme.sidebar.withAlphaComponent(backgroundOpacity).cgColor
        addHost?.rootView = makeAddButton()
        tabsContainer.subviews
            .compactMap { $0 as? TabItemView }
            .forEach { $0.applyTheme(theme, backgroundOpacity: backgroundOpacity) }
        needsDisplay = true
    }

    /// Called from TabContentView when LanguageStore.tick propagates.
    /// Tab pill labels render user-given `tab.title`, the "+" button is rebuilt via
    /// `applyTheme` → `makeAddButton()` which is already called on every `update()`
    /// (triggered by updateNSView → loadWorkspace), and the right-click NSMenu is
    /// rebuilt on each click — so there are no persistent static labels to refresh
    /// here. Method exists as a stable hook; keep it even when empty.
    func refreshLocalizedStrings() {
        // Intentionally empty — see docstring.
    }

    private func makeAddButton() -> AnyView {
        let currentTheme = theme
        let currentLocale = locale
        return AnyView(
            IconButton(theme: currentTheme, help: String(localized: L10n.Tab.newTabTooltip.withLocale(currentLocale)), action: { [weak self] in
                self?.onAddTab?()
            }) {
                Text("+")
                    .font(Font(DT.Font.body))
                    .foregroundColor(Color(currentTheme.textSecondary))
            }
            .environment(\.locale, currentLocale)
        )
    }

    // MARK: - Drag & drop

    /// 根据鼠标横坐标计算应插入的位置（0…tabs.count）。拖拽中用 self.tabs 的
    /// 原始顺序判定——preview 重排的是视图 frame，模型层 insertion 语义不变。
    private func insertionIndex(at pointInSelf: NSPoint) -> Int {
        guard !tabs.isEmpty else { return 0 }
        // 把 x 转换到 tabsContainer 坐标系
        let pointInContainer = tabsContainer.convert(pointInSelf, from: self)
        // 基于原始 tabs 顺序下每个 slot 的中线（无 preview 时的位置）
        let tabW: CGFloat = 140
        let gap = Self.pillInset
        for i in 0..<tabs.count {
            let midX = CGFloat(i) * (tabW + gap) + tabW / 2
            if pointInContainer.x < midX { return i }
        }
        return tabs.count
    }

    /// 清除 preview 状态并原地恢复布局（无动画，避免 rebuild 前的闪烁）。
    fileprivate func cleanupAfterDrag() {
        guard draggingTabId != nil || previewInsertionIndex != nil else { return }
        draggingTabId = nil
        previewInsertionIndex = nil
        layoutTabItems(animated: true)
    }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // 把被拖的 tabId 记下来，配合 draggingUpdated 驱动 live preview
        if let idString = sender.draggingPasteboard.string(forType: .mux0Tab),
           let uuid = UUID(uuidString: idString) {
            draggingTabId = uuid
        }
        return draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.types?.contains(.mux0Tab) == true else {
            return []
        }
        let pointInSelf = convert(sender.draggingLocation, from: nil)
        let idx = insertionIndex(at: pointInSelf)
        if idx != previewInsertionIndex {
            previewInsertionIndex = idx
            layoutTabItems(animated: true)
        }
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        // 鼠标暂时离开 TabBarView，撤销 preview 但保留 draggingTabId（可能还会回来）
        if previewInsertionIndex != nil {
            previewInsertionIndex = nil
            layoutTabItems(animated: true)
        }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let idString = sender.draggingPasteboard.string(forType: .mux0Tab),
              let tabId = UUID(uuidString: idString),
              let fromIndex = tabs.firstIndex(where: { $0.id == tabId })
        else {
            cleanupAfterDrag()
            return false
        }
        let pointInSelf = convert(sender.draggingLocation, from: nil)
        let toIndex = insertionIndex(at: pointInSelf)
        // 保留 preview 状态到下一次 rebuildTabItems（store 更新 → rebuildTabItems 用新顺序布局）
        // 之后 cleanupAfterDrag 兜底清除任何残留。
        onReorderTab?(fromIndex, toIndex)
        cleanupAfterDrag()
        return true
    }

}

// MARK: - TabItemView

private final class TabItemView: NSView, NSTextFieldDelegate, NSDraggingSource {
    let tabId: UUID
    var onSelect: (() -> Void)?
    var onClose:  (() -> Void)?
    var onRename: ((String) -> Void)?
    /// 在 drag session 结束时（无论是否成功 drop）调用——用来让 TabBarView 清除 preview 状态。
    var onDragEnded: (() -> Void)?
    var canClose: Bool = true

    /// 拖拽 preview 中被拖 item 的 "占位" 显示——淡化 alpha 暗示它会被移走。
    var isDragGhost: Bool = false {
        didSet {
            guard oldValue != isDragGhost else { return }
            alphaValue = isDragGhost ? 0.35 : 1
        }
    }

    private let pillView   = NSView()
    private let kindIcon   = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let renameField = NSTextField()
    private let statusIcon = TerminalStatusIconView(frame: .zero)

    /// 当前显示的 kind —— 用来在 refresh() 时判断是否需要换 image。
    private var displayedKind: TabKind?
    private var originalTitle: String = ""
    private var isRenaming: Bool = false
    private var isSelected: Bool
    private var isHovered  = false
    private var theme: AppTheme
    /// See TabBarView.backgroundOpacity — the pill fill uses alpha so it doesn't
    /// over-paint the translucent tab strip below.
    private var backgroundOpacity: CGFloat
    private var status: TerminalStatus
    fileprivate var showStatusIndicators: Bool = false

    init(tab: TerminalTab, isSelected: Bool, theme: AppTheme, status: TerminalStatus = .neverRan, backgroundOpacity: CGFloat = 1.0, showStatusIndicators: Bool = false) {
        self.tabId = tab.id
        self.isSelected = isSelected
        self.theme = theme
        self.backgroundOpacity = backgroundOpacity
        self.status = status
        self.displayedKind = tab.kind
        super.init(frame: .zero)
        self.showStatusIndicators = showStatusIndicators
        titleLabel.stringValue = tab.title
        setup()
        applyKindImage(tab.kind)
        updateStyle()
        statusIcon.isHidden = !showStatusIndicators
        statusIcon.update(status: status, theme: theme)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        wantsLayer = true

        pillView.wantsLayer = true
        pillView.layer?.masksToBounds = true
        addSubview(pillView)

        kindIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        kindIcon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(kindIcon)

        addSubview(statusIcon)

        titleLabel.isBezeled = false
        titleLabel.drawsBackground = false
        titleLabel.isEditable = false
        titleLabel.isSelectable = false
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.font = DT.Font.small
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(titleLabel)

        renameField.isBezeled = false
        renameField.drawsBackground = false
        renameField.isEditable = true
        renameField.isSelectable = true
        renameField.font = DT.Font.small
        renameField.focusRingType = .none
        renameField.delegate = self
        renameField.isHidden = true
        addSubview(renameField)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self))
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let vInset = TabBarView.pillInset
        let pillH = h - vInset * 2
        pillView.frame = NSRect(x: 0, y: vInset, width: bounds.width, height: pillH)
        pillView.layer?.cornerRadius = TabBarView.pillRadius

        let margin: CGFloat = 10
        let trailingIconSize: CGFloat = showStatusIndicators ? TerminalStatusIconView.size : 0
        let trailingGap: CGFloat = showStatusIndicators ? 6 : 0
        if showStatusIndicators {
            statusIcon.frame = NSRect(
                x: bounds.width - margin - trailingIconSize, y: (h - trailingIconSize) / 2,
                width: trailingIconSize, height: trailingIconSize)
        }

        // Leading kind icon: 11pt SF Symbol, fixed gap to title.
        let leadingIconSize: CGFloat = 11
        let leadingGap: CGFloat = 6
        kindIcon.frame = NSRect(
            x: margin, y: (h - leadingIconSize) / 2,
            width: leadingIconSize, height: leadingIconSize)

        let textH = ceil(titleLabel.intrinsicContentSize.height)
        let textX = margin + leadingIconSize + leadingGap
        let textFrame = NSRect(
            x: textX, y: (h - textH) / 2,
            width: bounds.width - margin - trailingIconSize - trailingGap - textX,
            height: textH)
        titleLabel.frame = textFrame
        renameField.frame = textFrame
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        // Rename 模式下让 NSTextField 用默认 I-beam 光标
        guard !isRenaming else { return }
        addCursorRect(bounds, cursor: .pointingHand)
    }

    // MARK: - Rename

    @objc private func beginRenameAction() {
        originalTitle = titleLabel.stringValue
        renameField.stringValue = originalTitle
        titleLabel.isHidden = true
        renameField.isHidden = false
        isRenaming = true
        window?.makeFirstResponder(renameField)
        renameField.currentEditor()?.selectAll(nil)
        window?.invalidateCursorRects(for: self)
    }

    private func finishRenameUI() {
        renameField.isHidden = true
        titleLabel.isHidden = false
        isRenaming = false
        window?.invalidateCursorRects(for: self)
    }

    private func commitRename() {
        guard isRenaming else { return }
        let newTitle = renameField.stringValue
        finishRenameUI()
        onRename?(newTitle)
    }

    private func cancelRename() {
        guard isRenaming else { return }
        // 恢复原始显示，不触发回调
        renameField.stringValue = originalTitle
        finishRenameUI()
    }

    // NSTextFieldDelegate —— 回车 / 失焦均触发 commit
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelRename()
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        // 回车 / 失焦都走这里；Esc 的情况已经在 doCommandBy 里被处理并提前 finish 了
        commitRename()
    }

    func applyTheme(_ theme: AppTheme, backgroundOpacity: CGFloat = 1.0) {
        self.theme = theme
        self.backgroundOpacity = backgroundOpacity
        updateStyle()
        statusIcon.update(status: status, theme: theme)
    }

    /// 原地刷新——保留 view 实例、所有 responder 状态（拖拽 mouseDown/mouseDragged 链、
    /// inline rename 的 NSTextField first responder）。只更新显示字段。
    func refresh(tab: TerminalTab, isSelected: Bool, theme: AppTheme,
                 canClose: Bool, status: TerminalStatus = .neverRan,
                 backgroundOpacity: CGFloat = 1.0,
                 showStatusIndicators: Bool = false) {
        self.theme = theme
        self.backgroundOpacity = backgroundOpacity
        self.isSelected = isSelected
        self.canClose = canClose
        self.status = status
        if titleLabel.stringValue != tab.title && !isRenaming {
            titleLabel.stringValue = tab.title
        }
        if displayedKind != tab.kind {
            displayedKind = tab.kind
            applyKindImage(tab.kind)
        }
        self.showStatusIndicators = showStatusIndicators
        statusIcon.isHidden = !showStatusIndicators
        statusIcon.update(status: status, theme: theme)
        updateStyle()
        needsLayout = true
    }

    private func applyKindImage(_ kind: TabKind?) {
        let symbolName: String = (kind == .git) ? "arrow.triangle.branch" : "terminal"
        kindIcon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
    }

    private func updateStyle() {
        if isSelected {
            pillView.layer?.backgroundColor = theme.canvas.withAlphaComponent(backgroundOpacity).cgColor
            titleLabel.textColor = theme.textPrimary
        } else if isHovered {
            pillView.layer?.backgroundColor = theme.canvas.withAlphaComponent(0.5 * backgroundOpacity).cgColor
            titleLabel.textColor = theme.textSecondary
        } else {
            pillView.layer?.backgroundColor = .clear
            titleLabel.textColor = theme.textSecondary
        }
        kindIcon.contentTintColor = titleLabel.textColor
        needsDisplay = true
    }


    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateStyle()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateStyle()
    }

    private var mouseDownLocation: NSPoint = .zero

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = event.locationInWindow
        onSelect?()
    }

    override func mouseDragged(with event: NSEvent) {
        // Rename 中不启动拖拽
        if isRenaming { return }
        let dx = event.locationInWindow.x - mouseDownLocation.x
        let dy = event.locationInWindow.y - mouseDownLocation.y
        guard (dx * dx + dy * dy) > 16 else { return }  // 4pt 阈值

        let pbItem = NSPasteboardItem()
        pbItem.setString(tabId.uuidString, forType: .mux0Tab)

        let (ghost, frame) = snapshotForDragging()
        let draggingItem = NSDraggingItem(pasteboardWriter: pbItem)
        draggingItem.setDraggingFrame(frame, contents: ghost)

        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    private func snapshotForDragging() -> (image: NSImage, frame: NSRect) {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else {
            return (NSImage(), bounds)
        }
        cacheDisplay(in: bounds, to: rep)
        let raw = NSImage(size: bounds.size)
        raw.addRepresentation(rep)
        return DraggedSnapshotShadow.compose(content: raw,
                                             contentSize: bounds.size,
                                             cornerRadius: TabBarView.pillRadius)
    }

    // NSDraggingSource
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return .move
    }

    /// 松手后（drop 成功与否都触发）通知 TabBarView 清 preview state。
    /// 成功 drop 时 performDragOperation 已清理过；这里是失败路径兜底。
    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        onDragEnded?()
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        // autoenablesItems=true 会根据 target/action 把 isEnabled=false 覆盖回 true；
        // 这里希望 "最后一个 tab 时 Close 真的 disabled"，所以关闭自动启用。
        menu.autoenablesItems = false

        let renameItem = NSMenuItem(title: L10n.string("tab.row.rename"),
                                    action: #selector(beginRenameAction),
                                    keyEquivalent: "")
        renameItem.target = self
        menu.addItem(renameItem)

        menu.addItem(.separator())

        let closeItem = NSMenuItem(title: L10n.string("tab.row.close"),
                                   action: #selector(closeTapped),
                                   keyEquivalent: "")
        closeItem.target = self
        closeItem.isEnabled = canClose
        menu.addItem(closeItem)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func closeTapped() { onClose?() }
}
