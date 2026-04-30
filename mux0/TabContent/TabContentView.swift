import AppKit

/// Top-level content view that combines the tab bar and the active tab's split pane.
///
/// ## Caching strategy
///
/// The whole point of this view is to make terminals *survive* workspace/tab switches
/// and divider drags. Naive rebuild-on-every-update destroys the SplitPaneView tree,
/// re-parents every GhosttyTerminalView, which in turn briefly resizes each ghostty
/// surface to 0×0 — and that's enough to leave the Metal renderer blank.
///
/// So we keep TWO caches, both globally keyed:
///   - `terminalViews`: the NSView wrapping each ghostty surface, keyed by terminal UUID.
///   - `tabPanes`: the entire SplitPaneView for each tab, keyed by tab UUID. Along with
///     `tabPaneLayouts`, a structural snapshot used to decide whether the cached pane
///     is still valid.
///
/// On every `loadWorkspace` call we prune both caches using live-IDs gathered across
/// ALL workspaces (not just the current one), then swap the visible pane. The cached
/// pane is reused whenever the tab's layout is structurally identical (ignoring ratio
/// values); only true structural changes (split/close/new terminal) rebuild it.
final class TabContentView: NSView {
    var store: WorkspaceStore?
    var pwdStore: TerminalPwdStore?
    /// Used only by `terminalViewFor` to gate consumption of pending agent
    /// resume commands against the user's Settings → Agents → Resume toggle.
    var settingsStore: SettingsConfigStore?

    private var theme: AppTheme = .systemFallback(isDark: true)
    /// Mirror of ghostty `background-opacity`. Applied to paneContainer's layer so
    /// ghostty_surface's alpha can actually punch through.
    private var backgroundOpacity: CGFloat = 1.0
    private let tabBar: TabBarView
    /// Rounded wrapper holding the currently visible SplitPaneView. Keeping the
    /// pane inside a dedicated clipping container lets it read as its own floating
    /// card — separate from the tab strip above — so the gap between tab bar and
    /// pane shows the window's translucent sidebar backing instead of canvas.
    private let paneContainer = NSView()

    /// Persistent cache: GhosttyTerminalView instances survive tab / workspace switches.
    private var terminalViews: [UUID: GhosttyTerminalView] = [:]
    /// Persistent cache: SplitPaneView instances survive tab / workspace switches so
    /// that switching never re-parents terminal NSViews.
    private var tabPanes: [UUID: SplitPaneView] = [:]
    /// Last layout snapshot per tab; used with SplitNode.sameStructure to decide whether
    /// the cached pane is still valid.
    private var tabPaneLayouts: [UUID: SplitNode] = [:]
    /// The tab whose pane is currently installed as a subview.
    private var visibleTabId: UUID?
    private var keyMonitor: Any?
    private var lastStatuses: [UUID: TerminalStatus] = [:]
    private var lastShowStatusIndicators: Bool = false

    override init(frame: NSRect) {
        tabBar = TabBarView(frame: .zero)
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        wantsLayer = true

        paneContainer.wantsLayer = true
        // 参考 tab strip 的圆角，让终端区看起来像嵌在卡片里的一块"小圆角面板"。
        paneContainer.layer?.cornerRadius = TabBarView.stripRadius
        paneContainer.layer?.masksToBounds = true
        addSubview(paneContainer)

        tabBar.autoresizingMask = [.width]
        addSubview(tabBar)

        tabBar.onSelectTab = { [weak self] tabId in
            guard let self, let wsId = self.store?.selectedId else { return }
            self.store?.selectTab(id: tabId, in: wsId)
            self.reloadFromStore()
        }
        tabBar.onAddTab = { [weak self] in
            self?.addNewTab()
        }
        tabBar.onCloseTab = { [weak self] tabId in
            self?.confirmCloseTab(tabId)
        }
        tabBar.onRenameTab = { [weak self] tabId, newTitle in
            guard let self, let wsId = self.store?.selectedId else { return }
            self.store?.renameTab(id: tabId, in: wsId, to: newTitle)
            self.reloadFromStore()
        }
        tabBar.onReorderTab = { [weak self] fromIndex, toIndex in
            guard let self, let wsId = self.store?.selectedId else { return }
            self.store?.moveTab(fromIndex: fromIndex, toIndex: toIndex, in: wsId)
            self.reloadFromStore()
        }

        subscribeNotifications()
        installKeyMonitor()
    }

    override func layout() {
        super.layout()
        let inset = DT.Space.xs
        let gap = DT.Space.xs
        let tbH = TabBarView.height
        let contentW = max(0, bounds.width - inset * 2)
        tabBar.frame = NSRect(
            x: inset, y: bounds.height - tbH - inset,
            width: contentW, height: tbH)
        let paneH = max(0, bounds.height - tbH - inset * 2 - gap)
        paneContainer.frame = NSRect(x: inset, y: inset, width: contentW, height: paneH)
        // Pane's autoresizingMask keeps it filling paneContainer on layout passes.
    }

    // MARK: - Workspace loading (called by TabBridge)

    func loadWorkspace(_ workspace: Workspace,
                       statuses: [UUID: TerminalStatus] = [:],
                       showStatusIndicators: Bool = false) {
        self.lastStatuses = statuses
        self.lastShowStatusIndicators = showStatusIndicators
        // Prune caches using live IDs collected across EVERY workspace. This is what
        // keeps state alive when the sidebar navigates away from a workspace: its
        // terminals and its cached pane stay in the dictionaries, just temporarily
        // without a superview.
        let allWorkspaces = store?.workspaces ?? [workspace]
        let liveTerms = Set(allWorkspaces.flatMap { ws in
            ws.tabs.flatMap { $0.layout.allTerminalIds() }
        })
        let liveTabs = Set(allWorkspaces.flatMap { $0.tabs.map { $0.id } })

        for id in terminalViews.keys where !liveTerms.contains(id) {
            terminalViews[id]?.removeFromSuperview()
            terminalViews.removeValue(forKey: id)
        }
        for id in tabPanes.keys where !liveTabs.contains(id) {
            tabPanes[id]?.removeFromSuperview()
            tabPanes.removeValue(forKey: id)
            tabPaneLayouts.removeValue(forKey: id)
        }

        // Update tab bar with status dict
        tabBar.update(tabs: workspace.tabs,
                      selectedTabId: workspace.selectedTabId,
                      theme: theme,
                      statuses: self.lastStatuses,
                      backgroundOpacity: backgroundOpacity,
                      showStatusIndicators: self.lastShowStatusIndicators)

        // Install the pane for the workspace's current tab (reusing the cache whenever
        // possible so we never re-parent terminal NSViews on ordinary switches).
        if let tab = workspace.selectedTab {
            activateTab(tab)
        }
    }

    private func reloadFromStore() {
        guard let ws = store?.selectedWorkspace else { return }
        loadWorkspace(ws,
                      statuses: lastStatuses,
                      showStatusIndicators: lastShowStatusIndicators)
    }

    /// Ensure the given tab's SplitPaneView is built/up-to-date, install it as the
    /// single visible pane, and focus its selected terminal. Only rebuilds the pane
    /// when the tab's layout has structurally changed (splits/closes/new terminals);
    /// a pure ratio change reuses the cached pane without touching the tree.
    private func activateTab(_ tab: TerminalTab) {
        let cachedLayout = tabPaneLayouts[tab.id]
        let structureMatches = cachedLayout.map { SplitNode.sameStructure($0, tab.layout) } ?? false
        let pane: SplitPaneView
        if structureMatches, let existing = tabPanes[tab.id] {
            pane = existing
        } else {
            // Old pane for this tab (if any) is detached and dropped; a new one is built.
            // The children it referenced — the GhosttyTerminalView instances — remain
            // alive in `terminalViews`, so no ghostty surface is freed here.
            tabPanes[tab.id]?.removeFromSuperview()
            pane = buildSplitPane(for: tab)
            tabPanes[tab.id] = pane
        }
        // Always refresh the snapshot so the next comparison has the latest ratios on
        // hand (ratios are ignored by sameStructure, but we keep the snapshot honest).
        tabPaneLayouts[tab.id] = tab.layout

        // Swap visible pane: detach whichever pane is currently installed, then make
        // sure `pane` is parented to self with the right frame.
        if let currentId = visibleTabId, currentId != tab.id {
            tabPanes[currentId]?.removeFromSuperview()
        }
        visibleTabId = tab.id
        if pane.superview !== paneContainer {
            // pane 填满 paneContainer，paneContainer 只负责 cornerRadius 裁切。
            // 终端内容到圆角边的"呼吸感"靠 ghostty 自己的 window-padding 实现，
            // 不再在 mux0 侧套一层额外 inset / canvas 层。
            pane.frame = paneContainer.bounds
            pane.autoresizingMask = [.width, .height]
            paneContainer.addSubview(pane)
        }
        pane.applyTheme(theme)

        // Restore focus
        focusTerminal(tab.focusedTerminalId)
    }

    private func buildSplitPane(for tab: TerminalTab) -> SplitPaneView {
        let tabId = tab.id
        return SplitPaneView(
            node: tab.layout,
            terminalViewForId: { [weak self] id -> GhosttyTerminalView in
                // SplitPaneView is owned by TabContentView, so self cannot be nil while
                // any SplitPaneView built by this instance is alive.
                guard let self else { fatalError("TabContentView deallocated while SplitPaneView still active") }
                let tv = self.terminalViewFor(id: id)
                // Wire focus callback here (not in terminalViewFor) so we have
                // tabId in scope; GhosttyTerminalView.mouseDown will invoke it
                // to update WorkspaceStore.focusedTerminalId on direct click,
                // because the terminal view consumes the event before SplitPaneView.
                tv.onFocus = { [weak self] in
                    guard let self, let wsId = self.store?.selectedId else { return }
                    self.store?.updateFocusedTerminal(id: id, tabId: tabId, in: wsId)
                }
                return tv
            },
            onRatioChanged: { [weak self] splitId, ratio in
                guard let self, let wsId = self.store?.selectedId else { return }
                self.store?.updateSplitRatio(splitId: splitId, to: ratio, tabId: tabId, in: wsId)
            },
            onFocus: { [weak self] terminalId in
                guard let self, let wsId = self.store?.selectedId else { return }
                self.store?.updateFocusedTerminal(id: terminalId, tabId: tabId, in: wsId)
                self.focusTerminal(terminalId)
            }
        )
    }

    private func terminalViewFor(id: UUID) -> GhosttyTerminalView {
        if let existing = terminalViews[id] { return existing }
        let tv = GhosttyTerminalView(frame: .zero)
        tv.terminalId = id
        tv.pwdStoreRef = pwdStore
        tv.command = resolvedStartupCommand(forTerminal: id)
        terminalViews[id] = tv
        return tv
    }

    /// Pick the shell command to auto-execute on a fresh surface. Source order:
    ///   0. Git tab's first terminal: the configured `mux0-git-viewer` command
    ///      (default "lazygit"). Fires every time the surface is built — so
    ///      restarting mux0 re-runs the viewer automatically. Splitting inside
    ///      a git tab does NOT apply this to the new pane (only the layout's
    ///      first terminal id matches).
    ///   1. Pending agent resume command (`claude --resume <id>` /
    ///      `codex resume <id>`) — only when the matching agent's Resume
    ///      toggle in Settings is ON. Default OFF means stale UserDefaults
    ///      entries from earlier runs (or before the toggle existed) are
    ///      ignored, not replayed.
    ///   2. Workspace-level `defaultCommand`.
    private func resolvedStartupCommand(forTerminal id: UUID) -> String? {
        // (0) Git tab's first terminal → mux0-git-viewer setting.
        if let tab = store?.selectedWorkspace?.tabs.first(where: {
                $0.layout.allTerminalIds().contains(id)
            }),
            tab.kind == .git,
            id == tab.layout.allTerminalIds().first {
            let raw = settingsStore?.get("mux0-git-viewer")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let cmd = (raw?.isEmpty == false) ? raw! : "lazygit"
            return "\(cmd)\n"
        }

        // (1) Agent resume.
        if let pending = store?.consumePendingPrefill(terminalId: id),
           let agent = HookMessage.Agent.fromResumeCommand(pending),
           settingsStore?.get(agent.resumeSettingsKey) == "true" {
            return pending
        }

        // (2) Workspace default command.
        return store?.selectedWorkspace?.defaultCommand
    }

    private func focusTerminal(_ id: UUID) {
        guard let tv = terminalViews[id] else { return }
        GhosttyTerminalView.makeFrontmost(tv)
        window?.makeFirstResponder(tv)
    }

    func applyTheme(_ theme: AppTheme, backgroundOpacity: CGFloat = 1.0, locale: Locale = .current) {
        self.theme = theme
        self.backgroundOpacity = backgroundOpacity
        // paneContainer 不再画自己的 canvas 层 —— 否则会在 ghostty surface 之外
        // 套出一圈可见的额外容器色，变成"两层 DOM"。保留 cornerRadius 作为单纯
        // 的 clip 容器，让 surface 自己成为那一块圆角终端。
        layer?.backgroundColor = .clear
        paneContainer.layer?.backgroundColor = .clear
        tabBar.locale = locale
        tabBar.applyTheme(theme, backgroundOpacity: backgroundOpacity)
        // Propagate to all cached panes — even the ones not currently visible, so
        // they're styled correctly when we swap them in on a future tab/workspace switch.
        tabPanes.values.forEach { $0.applyTheme(theme) }
    }

    /// Called from TabBridge.updateNSView when LanguageStore.tick changes.
    /// Forwards the refresh to the tab bar; splits and terminal views render
    /// dynamic content (user-named tabs, libghostty output) so they don't need
    /// a refresh pass.
    func refreshLocalizedStrings(locale: Locale = .current) {
        tabBar.locale = locale
        tabBar.refreshLocalizedStrings()
    }

    func detach() {
        GhosttyTerminalView.makeFrontmost(nil)
        terminalViews.values.forEach { $0.isHidden = true }
        removeKeyMonitor()
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    func attach() {
        terminalViews.values.forEach { $0.isHidden = false }
        if let tab = store?.selectedWorkspace?.selectedTab {
            focusTerminal(tab.focusedTerminalId)
        }
        if keyMonitor == nil { installKeyMonitor() }
    }

    // MARK: - Notification subscriptions

    private func subscribeNotifications() {
        let names: [Notification.Name] = [
            .mux0NewTab, .mux0ClosePane,
            .mux0SplitVertical, .mux0SplitHorizontal,
            .mux0SelectNextTab, .mux0SelectPrevTab,
            .mux0SelectTabAtIndex,
            .mux0FocusNextPane, .mux0FocusPrevPane,
            .mux0Copy, .mux0Paste, .mux0SelectAll,
        ]
        for name in names {
            NotificationCenter.default.addObserver(
                self, selector: #selector(handleNotification(_:)), name: name, object: nil)
        }
    }

    @objc private func handleNotification(_ note: Notification) {
        // Ignore broadcasts targeting other windows when multiple workspaces are open.
        guard window?.isKeyWindow == true else { return }
        switch note.name {
        case .mux0NewTab:           addNewTab()
        case .mux0ClosePane:        closeCurrentPane()
        case .mux0SplitVertical:    splitCurrentPane(direction: .vertical)
        case .mux0SplitHorizontal:  splitCurrentPane(direction: .horizontal)
        case .mux0SelectNextTab:    cycleTab(forward: true)
        case .mux0SelectPrevTab:    cycleTab(forward: false)
        case .mux0SelectTabAtIndex:
            if let idx = note.userInfo?["index"] as? Int { selectTab(at: idx) }
        case .mux0FocusNextPane:    focusAdjacentPane(forward: true)
        case .mux0FocusPrevPane:    focusAdjacentPane(forward: false)
        case .mux0Copy:             focusedTerminalView()?.copySelection()
        case .mux0Paste:            focusedTerminalView()?.pasteClipboard()
        case .mux0SelectAll:        focusedTerminalView()?.selectAll()
        default: break
        }
    }

    // MARK: - Close confirmation

    private func confirmCloseTab(_ tabId: UUID) {
        guard let window,
              let wsId = store?.selectedId,
              let ws = store?.workspaces.first(where: { $0.id == wsId }),
              let tab = ws.tabs.first(where: { $0.id == tabId }) else { return }

        let alert = NSAlert()
        alert.messageText = L10n.string("tab.close.alert.title")
        alert.informativeText = L10n.string("tab.close.alert.message %@", tab.title)
        alert.addButton(withTitle: L10n.string("tab.close.alert.confirm"))
        alert.addButton(withTitle: L10n.string("tab.close.alert.cancel"))
        alert.alertStyle = .warning

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.store?.removeTab(id: tabId, from: wsId)
            self.reloadFromStore()
        }
    }

    private func addNewTab() {
        guard let wsId = store?.selectedId,
              let ws = store?.selectedWorkspace else { return }
        // Read sourceId BEFORE addTab: addTab switches selectedTabId to the
        // new tab, after which selectedTab?.focusedTerminalId would resolve to
        // the fresh terminal and inherit would self-copy a nil.
        let sourceId = ws.selectedTab?.focusedTerminalId
        guard let result = store?.addTab(to: wsId) else { return }
        if let sourceId {
            pwdStore?.inherit(from: sourceId, to: result.terminalId)
        }
        reloadFromStore()
    }

    private func closeCurrentPane() {
        guard let ws = store?.selectedWorkspace,
              let wsId = store?.selectedId,
              let tab = ws.selectedTab else { return }
        store?.closeTerminal(id: tab.focusedTerminalId, in: wsId, tabId: tab.id)
        reloadFromStore()
    }

    private func splitCurrentPane(direction: SplitDirection) {
        guard let ws = store?.selectedWorkspace,
              let wsId = store?.selectedId,
              let tab = ws.selectedTab else { return }
        let sourceId = tab.focusedTerminalId
        guard let newId = store?.splitTerminal(
            id: sourceId, in: wsId, tabId: tab.id, direction: direction)
        else { return }
        pwdStore?.inherit(from: sourceId, to: newId)
        reloadFromStore()
    }

    private func cycleTab(forward: Bool) {
        guard let ws = store?.selectedWorkspace,
              let wsId = store?.selectedId,
              let idx = ws.tabs.firstIndex(where: { $0.id == ws.selectedTabId }) else { return }
        let count = ws.tabs.count
        let next = forward ? (idx + 1) % count : (idx - 1 + count) % count
        store?.selectTab(id: ws.tabs[next].id, in: wsId)
        reloadFromStore()
    }

    private func selectTab(at index: Int) {
        guard let ws = store?.selectedWorkspace,
              let wsId = store?.selectedId,
              index < ws.tabs.count else { return }
        store?.selectTab(id: ws.tabs[index].id, in: wsId)
        reloadFromStore()
    }

    /// Returns the currently focused pane's view, or nil if the workspace has no tab/pane.
    /// Used by Edit-menu handlers to target the right surface.
    private func focusedTerminalView() -> GhosttyTerminalView? {
        guard let tab = store?.selectedWorkspace?.selectedTab else { return nil }
        return terminalViews[tab.focusedTerminalId]
    }

    // MARK: - Key monitor for ⌘⌥arrow pane navigation

    private func installKeyMonitor() {
        // ⌘⌥→ and ⌘⌥← are now menu items (Terminal → Focus Next/Previous Pane),
        // so SwiftUI dispatches those via .mux0FocusNextPane / .mux0FocusPrevPane.
        // The monitor remains only for the ↑/↓ aliases — intentional hidden duplicates
        // not shown in the menu, kept because they're a common pane-nav habit.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.modifierFlags.intersection([.command, .option]) == [.command, .option]
            else { return event }
            switch event.keyCode {
            case 125: self.focusAdjacentPane(forward: true);  return nil  // ↓
            case 126: self.focusAdjacentPane(forward: false); return nil  // ↑
            default: return event
            }
        }
    }

    private func focusAdjacentPane(forward: Bool) {
        guard let ws = store?.selectedWorkspace,
              let tab = ws.selectedTab,
              let wsId = store?.selectedId else { return }
        let ids = tab.layout.allTerminalIds()
        guard let idx = ids.firstIndex(of: tab.focusedTerminalId) else { return }
        let next = forward ? (idx + 1) % ids.count : (idx - 1 + ids.count) % ids.count
        let nextId = ids[next]
        store?.updateFocusedTerminal(id: nextId, tabId: tab.id, in: wsId)
        focusTerminal(nextId)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        removeKeyMonitor()
    }
}
