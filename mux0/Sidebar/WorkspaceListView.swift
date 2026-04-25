import AppKit

// MARK: - FlippedRowsContainer

/// 文档视图坐标系翻转：第 0 行 y=0 在顶部，行索引递增向下。
/// 不翻转的话 NSView 默认 origin-bottom-left，row 布局算式反复 (height - i*rowH)，
/// 容易出错且难维护。
private final class FlippedRowsContainer: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - WorkspaceListView

/// 侧边栏 workspace 列表（AppKit 实现，对标 TabBarView）。
/// 拖拽 / hover / rename / 右键菜单全部在此层完成，外层 SidebarView 仅作 SwiftUI 壳。
final class WorkspaceListView: NSView {
    var onSelect: ((UUID) -> Void)?
    var onRename: ((UUID, String) -> Void)?
    var onReorder: ((Int, Int) -> Void)?       // (fromIndex, toIndex) insertion 0…count
    var onRequestDelete: ((UUID) -> Void)?
    /// AppKit row bubbles the edit request up (workspaceId + currentCommand);
    /// SwiftUI shell presents the alert and writes back via WorkspaceStore on save.
    var onRequestEditCommand: ((UUID, String) -> Void)?

    private let scrollView = NSScrollView()
    private let rowsContainer = FlippedRowsContainer()
    private var theme: AppTheme = .systemFallback(isDark: true)
    /// Mirror of ghostty `background-opacity`. Applied to selected/hovered row
    /// fills so they don't paint over the now-transparent sidebar column.
    private var backgroundOpacity: CGFloat = 1.0
    private var workspaces: [Workspace] = []
    private var selectedId: UUID?
    private var metadataMap: [UUID: WorkspaceMetadata] = [:]
    private var statusMap: [UUID: TerminalStatus] = [:]
    /// Gated UI state — see SidebarListBridge.showStatusIndicators docstring.
    /// When false, row layout + subview creation omits the status icon.
    private var showStatusIndicators: Bool = false

    // Drag preview state (Task 8 fills these in)
    fileprivate var draggingId: UUID?
    fileprivate var previewInsertionIndex: Int?

    static let baseRowHeight: CGFloat = 44
    static let rowHeight: CGFloat = baseRowHeight
    static let rowSpacing: CGFloat = 3
    static let outerHorizontalInset: CGFloat = DT.Space.sm

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        wantsLayer = true
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.documentView = rowsContainer
        scrollView.autoresizingMask = []
        addSubview(scrollView)
        registerForDraggedTypes([.mux0Workspace])

        // 滚动时 view 从静止光标下经过，AppKit 不会可靠配对 mouseEntered/mouseExited，
        // 会留下多行残留 hover 背景。这里手动按真实鼠标位置重算每行 hover 状态。
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contentViewBoundsDidChange),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func contentViewBoundsDidChange() {
        syncHoverFromMouseLocation()
    }

    private func syncHoverFromMouseLocation() {
        let rows = rowsContainer.subviews.compactMap { $0 as? WorkspaceRowItemView }
        guard let window else {
            for row in rows where row.isHovered {
                row.isHovered = false
                row.updateStyle()
            }
            return
        }
        let mouseInWindow = window.mouseLocationOutsideOfEventStream
        for row in rows {
            let pInRow = row.convert(mouseInWindow, from: nil)
            let shouldHover = row.bounds.contains(pInRow)
            if row.isHovered != shouldHover {
                row.isHovered = shouldHover
                row.updateStyle()
            }
        }
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        layoutRows(animated: false)
    }

    func update(workspaces: [Workspace],
                selectedId: UUID?,
                metadata: [UUID: WorkspaceMetadata],
                statuses: [UUID: TerminalStatus] = [:],
                theme: AppTheme,
                backgroundOpacity: CGFloat = 1.0,
                showStatusIndicators: Bool = false) {
        self.workspaces = workspaces
        self.selectedId = selectedId
        self.metadataMap = metadata
        self.statusMap = statuses
        self.theme = theme
        self.backgroundOpacity = backgroundOpacity
        self.showStatusIndicators = showStatusIndicators
        rebuildRows()
        applyTheme(theme, backgroundOpacity: backgroundOpacity)
    }

    private func workspaceStatus(_ ws: Workspace) -> TerminalStatus {
        let ids = ws.tabs.flatMap { $0.layout.allTerminalIds() }
        return TerminalStatus.aggregate(ids.map { statusMap[$0] ?? .neverRan })
    }

    func applyTheme(_ theme: AppTheme, backgroundOpacity: CGFloat = 1.0) {
        self.theme = theme
        self.backgroundOpacity = backgroundOpacity
        rowsContainer.subviews
            .compactMap { $0 as? WorkspaceRowItemView }
            .forEach { $0.applyTheme(theme, backgroundOpacity: backgroundOpacity) }
        needsDisplay = true
    }

    /// id-diff：只在 workspace 序列变化时完整重建；否则原地 refresh，保留每行
    /// first responder 与 mouseDown/mouseDragged 链（rename / 拖拽不被打断）。
    private func rebuildRows() {
        let existing = rowsContainer.subviews.compactMap { $0 as? WorkspaceRowItemView }
        let existingIds = existing.map(\.workspaceId)
        let targetIds = workspaces.map(\.id)

        if existingIds == targetIds {
            for item in existing {
                guard let ws = workspaces.first(where: { $0.id == item.workspaceId }) else { continue }
                let meta = metadataMap[item.workspaceId] ?? WorkspaceMetadata()
                item.refresh(workspace: ws,
                             isSelected: ws.id == selectedId,
                             metadata: meta,
                             status: workspaceStatus(ws),
                             theme: theme,
                             backgroundOpacity: backgroundOpacity,
                             showStatusIndicators: showStatusIndicators)
            }
            return
        }

        existing.forEach { $0.removeFromSuperview() }
        for ws in workspaces {
            let meta = metadataMap[ws.id] ?? WorkspaceMetadata()
            let item = WorkspaceRowItemView(
                workspace: ws,
                isSelected: ws.id == selectedId,
                metadata: meta,
                status: workspaceStatus(ws),
                theme: theme,
                backgroundOpacity: backgroundOpacity,
                showStatusIndicators: showStatusIndicators)
            wireRowCallbacks(item)
            rowsContainer.addSubview(item)
        }
        layoutRows(animated: false)
    }

    private func wireRowCallbacks(_ item: WorkspaceRowItemView) {
        let id = item.workspaceId
        item.onSelect        = { [weak self] in self?.onSelect?(id) }
        item.onRename        = { [weak self] newName in self?.onRename?(id, newName) }
        item.onRequestDelete = { [weak self] in self?.onRequestDelete?(id) }
        item.onRequestEditCommand = { [weak self] current in self?.onRequestEditCommand?(id, current) }
        item.onDragEnded     = { [weak self] in self?.cleanupAfterDrag() }
    }

    fileprivate func cleanupAfterDrag() {
        guard draggingId != nil || previewInsertionIndex != nil else { return }
        draggingId = nil
        previewInsertionIndex = nil
        rowsContainer.subviews
            .compactMap { $0 as? WorkspaceRowItemView }
            .forEach { $0.isDragGhost = false }
        layoutRows(animated: true)
    }

    /// 返回应当显示的行顺序（考虑 drag preview）。
    private func previewOrdered(items: [WorkspaceRowItemView]) -> [WorkspaceRowItemView] {
        guard let draggingId,
              let insertion = previewInsertionIndex,
              let fromIdx = items.firstIndex(where: { $0.workspaceId == draggingId })
        else { return items }

        var copy = items
        let picked = copy.remove(at: fromIdx)
        // insertion 用 "before index" 语义；移除被拖项后 > fromIdx 的 insertion 左移 1
        let dest = insertion > fromIdx ? insertion - 1 : insertion
        copy.insert(picked, at: max(0, min(copy.count, dest)))
        return copy
    }

    /// 根据鼠标 y 算应插入的位置（0…workspaces.count）。使用当前行 frame 中线，
    /// 这样拖拽命中区域会跟随 default command 造成的动态行高。
    private func insertionIndex(at pointInSelf: NSPoint) -> Int {
        guard !workspaces.isEmpty else { return 0 }
        let pointInContainer = rowsContainer.convert(pointInSelf, from: self)
        let rows = rowsContainer.subviews
            .compactMap { $0 as? WorkspaceRowItemView }
            .sorted { $0.frame.minY < $1.frame.minY }
        for (idx, row) in rows.enumerated() {
            if pointInContainer.y < row.frame.midY { return idx }
        }
        return workspaces.count
    }

    // 默认按 self.workspaces 顺序排布；drag 进行中时使用 previewOrdered 顺序。
    // rowsContainer 已 flipped → y=0 顶部，向下递增。
    fileprivate func layoutRows(animated: Bool = false) {
        let items = rowsContainer.subviews.compactMap { $0 as? WorkspaceRowItemView }
        let ordered = previewOrdered(items: items)
        let w = max(0, scrollView.contentSize.width - Self.outerHorizontalInset * 2)
        let heights = ordered.map { $0.preferredHeight(forWidth: w) }
        let totalH = heights.reduce(0, +) + CGFloat(max(0, ordered.count - 1)) * Self.rowSpacing
        let containerH = max(totalH, scrollView.contentSize.height)

        let apply = {
            // flipped 容器 → y=0 顶部，向下递增
            var y: CGFloat = 0
            for (idx, item) in ordered.enumerated() {
                let h = heights[idx]
                let frame = NSRect(x: Self.outerHorizontalInset, y: y, width: w, height: h)
                if animated {
                    item.animator().frame = frame
                } else {
                    item.frame = frame
                }
                item.isDragGhost = (item.workspaceId == self.draggingId)
                y += h + Self.rowSpacing
            }
            self.rowsContainer.frame = NSRect(
                x: 0, y: 0,
                width: self.scrollView.contentSize.width,
                height: containerH)
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

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if let idString = sender.draggingPasteboard.string(forType: .mux0Workspace),
           let uuid = UUID(uuidString: idString) {
            draggingId = uuid
        }
        return draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.types?.contains(.mux0Workspace) == true else {
            return []
        }
        let pointInSelf = convert(sender.draggingLocation, from: nil)
        let idx = insertionIndex(at: pointInSelf)
        if idx != previewInsertionIndex {
            previewInsertionIndex = idx
            layoutRows(animated: true)
        }
        if let event = NSApp.currentEvent {
            scrollView.contentView.autoscroll(with: event)
        }
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if previewInsertionIndex != nil {
            previewInsertionIndex = nil
            layoutRows(animated: true)
        }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let idString = sender.draggingPasteboard.string(forType: .mux0Workspace),
              let uuid = UUID(uuidString: idString),
              let from = workspaces.firstIndex(where: { $0.id == uuid })
        else {
            cleanupAfterDrag()
            return false
        }
        let pointInSelf = convert(sender.draggingLocation, from: nil)
        let to = insertionIndex(at: pointInSelf)
        onReorder?(from, to)
        cleanupAfterDrag()
        return true
    }

    /// Called from SidebarListBridge.updateNSView when LanguageStore.tick changes.
    /// Context menu "Rename"/"Delete" strings rebuild on each right-click, so
    /// nothing persistent to refresh here. Rows render workspace.name (user-given)
    /// and metadata fields (branch/PR badge, all dynamic) — all language-independent.
    /// Method exists as a stable refresh hook; keep it even though the body is a no-op.
    func refreshLocalizedStrings() {
        // Intentionally empty — see docstring.
    }
}

// MARK: - WorkspaceRowItemView

private final class WorkspaceRowItemView: NSView, NSTextFieldDelegate, NSDraggingSource {
    let workspaceId: UUID

    var onSelect: (() -> Void)?
    var onRename: ((String) -> Void)?
    var onRequestDelete: (() -> Void)?
    /// Bubbles the workspace's current default command up so the SwiftUI shell
    /// can seed its alert TextField. Save/cancel happen entirely in the shell.
    var onRequestEditCommand: ((String) -> Void)?
    var onDragEnded: (() -> Void)?

    var isDragGhost: Bool = false {
        didSet {
            guard oldValue != isDragGhost else { return }
            alphaValue = isDragGhost ? 0.35 : 1
        }
    }

    private let backgroundLayerView = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let branchLabel = NSTextField(labelWithString: "")
    private let commandLabel = NSTextField(labelWithString: "")
    private let prBadge = NSTextField(labelWithString: "")
    private let statusIcon = TerminalStatusIconView(frame: .zero)
    fileprivate let renameField = NSTextField()

    fileprivate var isSelected: Bool
    fileprivate var isHovered = false
    fileprivate var isRenaming = false
    fileprivate var theme: AppTheme
    /// See WorkspaceListView.backgroundOpacity — mirrored onto each row so
    /// updateStyle() can compose alpha into the selected/hovered fill.
    fileprivate var backgroundOpacity: CGFloat
    fileprivate var showStatusIndicators: Bool
    private var workspace: Workspace
    private var metadata: WorkspaceMetadata
    private var status: TerminalStatus
    fileprivate var originalTitle: String = ""

    init(workspace: Workspace, isSelected: Bool,
         metadata: WorkspaceMetadata,
         status: TerminalStatus = .neverRan,
         theme: AppTheme,
         backgroundOpacity: CGFloat = 1.0,
         showStatusIndicators: Bool = false) {
        self.workspaceId = workspace.id
        self.workspace = workspace
        self.isSelected = isSelected
        self.metadata = metadata
        self.status = status
        self.theme = theme
        self.backgroundOpacity = backgroundOpacity
        self.showStatusIndicators = showStatusIndicators
        super.init(frame: .zero)
        setup()
        updateContent()
        updateStyle()
        statusIcon.isHidden = !showStatusIndicators
        statusIcon.update(status: status, theme: theme)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        wantsLayer = true

        backgroundLayerView.wantsLayer = true
        backgroundLayerView.layer?.cornerRadius = DT.Radius.row
        backgroundLayerView.layer?.masksToBounds = true
        addSubview(backgroundLayerView)

        titleLabel.isBezeled = false
        titleLabel.drawsBackground = false
        titleLabel.isEditable = false
        titleLabel.isSelectable = false
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        branchLabel.isBezeled = false
        branchLabel.drawsBackground = false
        branchLabel.isEditable = false
        branchLabel.isSelectable = false
        branchLabel.lineBreakMode = .byTruncatingMiddle
        branchLabel.font = DT.Font.mono
        addSubview(branchLabel)

        commandLabel.isBezeled = false
        commandLabel.drawsBackground = false
        commandLabel.isEditable = false
        commandLabel.isSelectable = false
        commandLabel.lineBreakMode = .byWordWrapping
        commandLabel.maximumNumberOfLines = 3
        commandLabel.font = DT.Font.mono
        addSubview(commandLabel)

        prBadge.isBezeled = false
        prBadge.drawsBackground = false
        prBadge.isEditable = false
        prBadge.isSelectable = false
        prBadge.font = DT.Font.micro
        addSubview(prBadge)

        addSubview(statusIcon)

        renameField.isBezeled = false
        renameField.drawsBackground = false
        renameField.isEditable = true
        renameField.isSelectable = true
        renameField.focusRingType = .none
        renameField.isHidden = true
        renameField.delegate = self
        renameField.font = DT.Font.body
        addSubview(renameField)
    }

    override func layout() {
        super.layout()
        backgroundLayerView.frame = bounds

        let hPad = DT.Space.md
        let topPad = DT.Space.xs
        let lineGap = DT.Space.xxs
        let titleH = ceil(titleLabel.intrinsicContentSize.height)
        let branchH = ceil(branchLabel.intrinsicContentSize.height)

        // Status icon at top-right of the row, aligned to title baseline.
        // When showStatusIndicators is false, the icon is hidden AND its layout
        // slot collapses so the title uses the full row width.
        let iconSize: CGFloat = showStatusIndicators ? TerminalStatusIconView.size : 0
        if showStatusIndicators {
            statusIcon.frame = NSRect(
                x: bounds.width - hPad - iconSize,
                y: bounds.height - topPad - titleH + (titleH - iconSize) / 2,
                width: iconSize, height: iconSize)
        }

        // PR badge, if present, sits to the LEFT of the icon
        let prW: CGFloat = prBadge.isHidden
            ? 0
            : ceil(prBadge.intrinsicContentSize.width) + DT.Space.xs
        let iconReservedW: CGFloat = showStatusIndicators ? (iconSize + DT.Space.xs) : 0

        let titleFrame = NSRect(
            x: hPad,
            y: bounds.height - topPad - titleH,
            width: bounds.width - hPad * 2 - prW - iconReservedW,
            height: titleH)
        titleLabel.frame = titleFrame
        renameField.frame = titleFrame
        renameField.font = titleLabel.font

        if !prBadge.isHidden {
            prBadge.frame = NSRect(
                x: bounds.width - hPad - iconSize - DT.Space.xs - prW + DT.Space.xs,
                y: bounds.height - topPad - titleH,
                width: prW, height: titleH)
        }

        branchLabel.frame = NSRect(
            x: hPad, y: topPad,
            width: bounds.width - hPad * 2, height: branchH)

        var nextY = titleFrame.minY - lineGap
        if !commandLabel.isHidden {
            let cmdH = commandLabelHeight(forWidth: bounds.width - hPad * 2)
            commandLabel.frame = NSRect(
                x: hPad,
                y: max(topPad, nextY - cmdH),
                width: bounds.width - hPad * 2,
                height: cmdH)
            nextY = commandLabel.frame.minY - lineGap
        }

        if !branchLabel.isHidden, !commandLabel.isHidden {
            branchLabel.frame = NSRect(
                x: hPad,
                y: max(topPad, nextY - branchH),
                width: bounds.width - hPad * 2,
                height: branchH)
        }
    }

    fileprivate func preferredHeight(forWidth width: CGFloat) -> CGFloat {
        guard workspace.defaultCommand?.isEmpty == false else {
            return WorkspaceListView.baseRowHeight
        }

        let contentWidth = max(0, width - DT.Space.md * 2)
        let titleH = ceil(titleLabel.intrinsicContentSize.height)
        let branchH = branchLabel.isHidden ? 0 : ceil(branchLabel.intrinsicContentSize.height)
        let branchGap = branchLabel.isHidden ? 0 : DT.Space.xxs
        let commandH = commandLabelHeight(forWidth: contentWidth)
        return max(
            WorkspaceListView.baseRowHeight,
            DT.Space.xs + titleH + DT.Space.xxs + commandH + branchGap + branchH + DT.Space.xs)
    }

    private func commandLabelHeight(forWidth width: CGFloat) -> CGFloat {
        guard !commandLabel.stringValue.isEmpty else { return 0 }
        let attr = NSAttributedString(
            string: commandLabel.stringValue,
            attributes: [.font: commandLabel.font ?? DT.Font.mono])
        let measured = attr.boundingRect(
            with: NSSize(width: max(1, width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        let lineHeight = ceil((commandLabel.font ?? DT.Font.mono).boundingRectForFont.height)
        return min(ceil(measured), lineHeight * 3)
    }

    func refresh(workspace: Workspace, isSelected: Bool,
                 metadata: WorkspaceMetadata,
                 status: TerminalStatus = .neverRan,
                 theme: AppTheme,
                 backgroundOpacity: CGFloat = 1.0,
                 showStatusIndicators: Bool = false) {
        self.workspace = workspace
        self.isSelected = isSelected
        self.metadata = metadata
        self.status = status
        self.theme = theme
        self.backgroundOpacity = backgroundOpacity
        self.showStatusIndicators = showStatusIndicators
        if !isRenaming, titleLabel.stringValue != workspace.name {
            titleLabel.stringValue = workspace.name
        }
        updateContent()
        updateStyle()
        statusIcon.isHidden = !showStatusIndicators
        statusIcon.update(status: status, theme: theme)
        needsLayout = true
    }

    func applyTheme(_ theme: AppTheme, backgroundOpacity: CGFloat = 1.0) {
        self.theme = theme
        self.backgroundOpacity = backgroundOpacity
        updateStyle()
        statusIcon.update(status: status, theme: theme)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateStyle()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateStyle()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        // Rename 模式下让 NSTextField 用默认 I-beam 光标
        guard !isRenaming else { return }
        addCursorRect(bounds, cursor: .pointingHand)
    }

    fileprivate var mouseDownLocation: NSPoint = .zero

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = event.locationInWindow
        onSelect?()
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let renameItem = NSMenuItem(
            title: L10n.string("sidebar.row.rename"),
            action: #selector(beginRenameAction),
            keyEquivalent: "")
        renameItem.target = self
        menu.addItem(renameItem)

        let commandItem = NSMenuItem(
            title: L10n.string("sidebar.row.commandPanel.editTitle"),
            action: #selector(requestEditCommandAction),
            keyEquivalent: "")
        commandItem.target = self
        menu.addItem(commandItem)

        menu.addItem(.separator())

        let deleteItem = NSMenuItem(
            title: L10n.string("sidebar.row.delete"),
            action: #selector(deleteAction),
            keyEquivalent: "")
        deleteItem.target = self
        menu.addItem(deleteItem)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc fileprivate func deleteAction() {
        onRequestDelete?()
    }

    @objc private func requestEditCommandAction() {
        onRequestEditCommand?(workspace.defaultCommand ?? "")
    }

    @objc fileprivate func beginRenameAction() {
        guard !isRenaming else { return }
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
        renameField.stringValue = originalTitle
        finishRenameUI()
    }

    // NSTextFieldDelegate
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelRename()
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        // 回车 / 失焦都走这里；Esc 已在 doCommandBy 中提前 finish 了
        commitRename()
    }

    override func mouseDragged(with event: NSEvent) {
        if isRenaming { return }
        let dx = event.locationInWindow.x - mouseDownLocation.x
        let dy = event.locationInWindow.y - mouseDownLocation.y
        guard (dx * dx + dy * dy) > 16 else { return }    // 4pt 阈值

        let pbItem = NSPasteboardItem()
        pbItem.setString(workspaceId.uuidString, forType: .mux0Workspace)

        let draggingItem = NSDraggingItem(pasteboardWriter: pbItem)
        draggingItem.setDraggingFrame(bounds, contents: snapshotForDragging())

        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    private func snapshotForDragging() -> NSImage {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return NSImage() }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }

    // NSDraggingSource
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return .move
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        onDragEnded?()
    }

    private func updateContent() {
        titleLabel.stringValue = workspace.name
        if let branch = metadata.gitBranch {
            branchLabel.stringValue = "⎇ \(branch)"
            branchLabel.isHidden = false
        } else {
            branchLabel.stringValue = ""
            branchLabel.isHidden = true
        }
        if let cmd = workspace.defaultCommand, !cmd.isEmpty {
            commandLabel.stringValue = "$ \(cmd)"
            commandLabel.isHidden = false
        } else {
            commandLabel.stringValue = ""
            commandLabel.isHidden = true
        }
        if let pr = metadata.prStatus {
            prBadge.stringValue = pr.uppercased()
            prBadge.isHidden = false
        } else {
            prBadge.stringValue = ""
            prBadge.isHidden = true
        }
    }

    fileprivate func updateStyle() {
        if isSelected {
            backgroundLayerView.layer?.backgroundColor = theme.border.withAlphaComponent(backgroundOpacity).cgColor
            titleLabel.textColor = theme.textPrimary
            titleLabel.font = DT.Font.body
        } else if isHovered {
            backgroundLayerView.layer?.backgroundColor = theme.border.withAlphaComponent(backgroundOpacity).cgColor
            titleLabel.textColor = theme.textSecondary
            titleLabel.font = DT.Font.body
        } else {
            backgroundLayerView.layer?.backgroundColor = NSColor.clear.cgColor
            titleLabel.textColor = theme.textSecondary
            titleLabel.font = DT.Font.body
        }
        branchLabel.textColor = theme.textTertiary
        commandLabel.textColor = theme.textTertiary
        prBadge.textColor = theme.textTertiary
        renameField.textColor = theme.textPrimary
        needsDisplay = true
    }
}
