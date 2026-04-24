import SwiftUI
import AppKit

struct ContentView: View {
    @State private var store = WorkspaceStore()
    @State private var statusStore = TerminalStatusStore()
    @State private var pwdStore = TerminalPwdStore()
    @State private var settingsStore = SettingsConfigStore()
    @State private var sidebarCollapsed: Bool = false
    @State private var showSettings: Bool = false
    @State private var hookListener: HookSocketListener?
    @State private var updateStore = UpdateStore(
        currentVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    )
    @State private var pendingSettingsSection: SettingsSection?
    @State private var didScheduleLaunchUpdateCheck: Bool = false
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LanguageStore.self) private var languageStore
    @Environment(\.locale) private var locale

    private let trafficLightInset: CGFloat = 28
    private let cardInset: CGFloat = 8
    private let cardRadius: CGFloat = DT.Radius.card
    /// 与 sidebar row 的状态图标列同中轴：图标中心距 sidebar 右 =
    /// outerHorizontalInset(8) + hPad(12) + iconSize/2(5) = 25；按钮(22)左边距 = width - 25 - 11。
    /// 三个按钮（本按钮、header "+"、footer 齿轮）都落在这条轴上。
    private let sidebarToggleLeading: CGFloat = DT.Layout.sidebarWidth - 25 - 11

    /// Master UI gate for the sidebar + tab bar status icons. True iff the user
    /// has enabled at least one agent in Settings → Agents; false collapses the
    /// icon column in the sidebar row and tab bar item layout.
    private var showStatusIndicators: Bool {
        StatusIndicatorGate.anyAgentEnabled(settingsStore)
    }

    /// UUIDs of all terminals currently rendered on-screen: every descendant
    /// of the selected tab's split tree in the selected workspace. Empty when
    /// nothing is selected (app start before a workspace exists).
    private var visibleTerminalIds: [UUID] {
        guard let ws = store.selectedWorkspace,
              let tab = ws.selectedTab else { return [] }
        return tab.layout.allTerminalIds()
    }

    var body: some View {
        let bgOpacity = themeManager.backgroundOpacity
        // 中间内容区（卡片 canvas、paneContainer、tab strip、Settings 各层等）都走
        // 这个乘过 contentOpacity 的 effective 值，让用户可以在保持 sidebar 透明度
        // 不变的前提下，单独把中心多层叠加的浓度再降一档。
        let contentBg = themeManager.contentEffectiveOpacity
        return ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                if !sidebarCollapsed {
                    SidebarView(
                        store: store,
                        statusStore: statusStore,
                        pwdStore: pwdStore,
                        theme: themeManager.theme,
                        backgroundOpacity: bgOpacity,
                        showStatusIndicators: showStatusIndicators,
                        updateStore: updateStore
                    )
                    .padding(.top, trafficLightInset)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }

                ZStack {
                    // TabBridge 常驻挂载：进入设置只是把它 z-order 压到底层并关交互，
                    // 避免 NSViewRepresentable 被 dismantle 导致 ghostty surface 释放。
                    TabBridge(
                        store: store,
                        statusStore: statusStore,
                        pwdStore: pwdStore,
                        theme: themeManager.theme,
                        backgroundOpacity: contentBg,
                        showStatusIndicators: showStatusIndicators,
                        languageTick: languageStore.tick
                    )
                    .opacity(showSettings ? 0 : 1)
                    .allowsHitTesting(!showSettings)

                    if showSettings {
                        SettingsView(
                            theme: themeManager.theme,
                            settings: settingsStore,
                            updateStore: updateStore,
                            initialSection: pendingSettingsSection,
                            onClose: { showSettings = false }
                        )
                    }
                }
                .background(Color(themeManager.theme.canvas).opacity(contentBg))
                .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
                .padding(.top, trafficLightInset)
                .padding(.leading, sidebarCollapsed ? cardInset : 0)
                .padding(.trailing, cardInset)
                .padding(.bottom, cardInset)
            }

            sidebarToggleButton
                .padding(.leading, sidebarToggleLeading)
                .padding(.top, DT.Space.xs)
        }
        .frame(minWidth: 960, minHeight: 620)
        // 根背景用 sidebar 色作为窗口底色 —— sidebar 区不再额外叠一层，整个
        // 左半部 + 卡片圆角外 + 顶部 traffic light 带都是这单层 sidebar alpha，
        // 浓度一致、无缝；卡片区自己叠一层 canvas alpha，相对根层更浓一点，
        // 圆角因此依然可见。
        .background(Color(themeManager.theme.sidebar).opacity(bgOpacity))
        .ignoresSafeArea()
        .mux0FullSizeContent(
            backgroundOpacity: contentBg,
            blurRadius: themeManager.backgroundBlurRadius
        ) { window in
            // Hand the window pointer to ghostty after every configure so it can
            // (re-)install or tear down the macOS blur layer driven by the current
            // `background-blur-radius` config value.
            GhosttyBridge.shared.applyWindowBackgroundBlur(to: window)
        }
        // 让整窗 NSAppearance 跟随 ghostty 主题亮度。SwiftUI 里的 LabeledContent
        // label、TextField 背景、Slider/Stepper/Picker 默认控件都依赖 NSAppearance
        // 解析颜色；系统外观是浅色但主题是深色时会出现"深灰文字在深蓝底上几乎看不见"
        // 的情况（尤其在 SettingsView 的 Form 里）。锁到 theme.isDark 后这些系统控件
        // 会跟主题一致。不影响 sidebar/tab bar —— 它们本来就读 theme token。
        .preferredColorScheme(themeManager.theme.isDark ? .dark : .light)
        .onAppear {
            themeManager.loadFromGhosttyConfig()
            // ghostty 的 PWD action（OSC 7）回调在 main 上通知 pwdStore，sidebar
            // 的 MetadataRefresher 每 5s tick 从 pwdStore 读最新 cwd 跑 git。
            let pwdStoreRef = pwdStore
            GhosttyBridge.shared.onPwdChanged = { terminalId, pwd in
                pwdStoreRef.setPwd(pwd, for: terminalId)
            }
            applyUnfocusedOpacityFromSettings()
            // applyWindowEffectsFromSettings must run BEFORE reloadConfig so the
            // effective background-opacity it installs on GhosttyBridge is picked
            // up by the next buildConfig.
            applyWindowEffectsFromSettings()
            GhosttyBridge.shared.reloadConfig()
            // Settings edits (debounced 200ms) → push new config to ghostty app
            // + all live surfaces, then re-derive mux0 UI colors from the
            // updated ghostty config so sidebar / tab bar track the new theme.
            settingsStore.onChange = {
                applyWindowEffectsFromSettings()
                GhosttyBridge.shared.reloadConfig()
                themeManager.refresh()
                applyUnfocusedOpacityFromSettings()
            }
            if hookListener == nil {
                let path = HookSocketListener.defaultPath
                do {
                    let listener = try HookSocketListener(path: path)
                    let store = self.statusStore
                    let settingsStoreRef = self.settingsStore
                    listener.onMessage = { msg in
                        HookDispatcher.dispatch(msg,
                                                settings: settingsStoreRef,
                                                store: store)
                    }
                    try listener.start()
                    hookListener = listener
                } catch {
                    print("[mux0] Failed to start hook socket listener: \(error)")
                }
            }
            // Auto-update: wire SparkleBridge and schedule the silent launch check.
            // SparkleBridge.startUpdater is internally idempotent, but the 3 s delayed
            // Task is not — guard the schedule so a re-entry into .onAppear doesn't
            // stack multiple in-flight silent checks.
            SparkleBridge.shared.store = updateStore
            SparkleBridge.shared.start()
            if !didScheduleLaunchUpdateCheck {
                didScheduleLaunchUpdateCheck = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    SparkleBridge.shared.checkForUpdates(silently: true)
                }
            }
        }
        .onChange(of: store.workspaces) { _, workspaces in
            let live = Set(workspaces.flatMap { ws in
                ws.tabs.flatMap { $0.layout.allTerminalIds() }
            })
            for (id, _) in statusStore.statusesSnapshot() where !live.contains(id) {
                statusStore.forget(terminalId: id)
            }
            for (id, _) in pwdStore.pwdsSnapshot() where !live.contains(id) {
                pwdStore.forget(terminalId: id)
            }
        }
        .onChange(of: store.selectedId) { _, _ in
            if showSettings { showSettings = false }
            statusStore.markRead(terminalIds: visibleTerminalIds)
        }
        // Workspace is a struct — selectedTabId changes propagate through the
        // @Observable `workspaces` array mutation in WorkspaceStore.selectTab.
        // If Workspace ever becomes a class, re-verify this observation path.
        .onChange(of: store.selectedWorkspace?.selectedTabId) { _, _ in
            statusStore.markRead(terminalIds: visibleTerminalIds)
        }
        .onReceive(NotificationCenter.default.publisher(for: .mux0OpenSettings)) { note in
            if let raw = note.userInfo?["section"] as? String,
               let section = SettingsSection(rawValue: raw) {
                pendingSettingsSection = section
            } else {
                // 无 section 参数（如 sidebar 齿轮点击）→ SettingsView 回落到默认 .appearance。
                pendingSettingsSection = nil
            }
            showSettings = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .mux0EditConfigFile)) { _ in
            settingsStore.openInEditor()
        }
    }

    /// Read `unfocused-split-opacity` from the mux0 override config (default 0.7) and
    /// push it into GhosttyTerminalView so non-focused panes dim correctly.
    /// Called on appear and whenever settings change.
    private func applyUnfocusedOpacityFromSettings() {
        let raw = settingsStore.get("unfocused-split-opacity")
        let value = raw.flatMap { Double($0) } ?? 0.7
        GhosttyTerminalView.setUnfocusedOpacity(CGFloat(value))
    }

    /// Read `background-opacity` and `background-blur-radius` from the mux0 override
    /// and push them into ThemeManager. Blur is applied in the WindowAccessor
    /// configure callback on the next body pass — that's where we have the live
    /// NSWindow pointer. ghostty surface itself renders fully transparent
    /// (forced by GhosttyBridge); the visible "background" is the canvas color
    /// painted behind it, which already picks up these alphas.
    private func applyWindowEffectsFromSettings() {
        let opacityRaw = settingsStore.get("background-opacity")
        let opacity = CGFloat(opacityRaw.flatMap { Double($0) } ?? 1.0)
        let blurRaw = settingsStore.get("background-blur-radius")
        let blur = CGFloat(blurRaw.flatMap { Double($0) } ?? 0)
        let contentRaw = settingsStore.get("mux0-content-opacity")
        let content = CGFloat(contentRaw.flatMap { Double($0) } ?? 1.0)
        themeManager.applyWindowEffects(opacity: opacity, blurRadius: blur, contentOpacity: content)
    }

    private var sidebarToggleButton: some View {
        IconButton(
            theme: themeManager.theme,
            help: String(localized: (sidebarCollapsed ? L10n.Sidebar.showSidebar : L10n.Sidebar.hideSidebar).withLocale(locale))
        ) {
            withAnimation(.easeInOut(duration: 0.2)) {
                sidebarCollapsed.toggle()
            }
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(Color(themeManager.theme.textSecondary))
        }
    }
}

// MARK: - Notification names

extension Notification.Name {
    static let mux0BeginCreateWorkspace = Notification.Name("mux0.beginCreateWorkspace")
    static let mux0NewTab               = Notification.Name("mux0.newTab")
    static let mux0ClosePane            = Notification.Name("mux0.closePane")
    static let mux0SplitVertical        = Notification.Name("mux0.splitVertical")
    static let mux0SplitHorizontal      = Notification.Name("mux0.splitHorizontal")
    static let mux0SelectNextTab        = Notification.Name("mux0.selectNextTab")
    static let mux0SelectPrevTab        = Notification.Name("mux0.selectPrevTab")
    static let mux0SelectTabAtIndex     = Notification.Name("mux0.selectTabAtIndex")

    // Pane focus navigation (also bound in the "Terminal" menu).
    static let mux0FocusNextPane        = Notification.Name("mux0.focusNextPane")
    static let mux0FocusPrevPane        = Notification.Name("mux0.focusPrevPane")

    // Edit menu → focused GhosttyTerminalView (routes to ghostty_surface_binding_action).
    static let mux0Copy                 = Notification.Name("mux0.copy")
    static let mux0Paste                = Notification.Name("mux0.paste")
    static let mux0SelectAll            = Notification.Name("mux0.selectAll")

    // Settings
    static let mux0OpenSettings         = Notification.Name("mux0.openSettings")
    static let mux0EditConfigFile       = Notification.Name("mux0.editConfigFile")
}
