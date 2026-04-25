import SwiftUI
import Observation

/// 引用类型 ticker：MetadataRefresher 的 onRefresh 是逃逸闭包，
/// 直接 `metadataTick &+= 1` (值类型 @State Int) 只会修改捕获的副本，不会触发
/// SwiftUI 重渲。换成 @Observable class，闭包按引用捕获，mutate 才能让 SwiftUI 重跑 body。
@Observable
fileprivate final class MetadataChangeTicker {
    var tick: Int = 0
}

struct SidebarView: View {
    @Bindable var store: WorkspaceStore
    @Bindable var statusStore: TerminalStatusStore
    @Bindable var pwdStore: TerminalPwdStore
    var theme: AppTheme
    /// ghostty `background-opacity`。乘到 sidebar 底色上 —— 当 < 1 且 NSWindow
    /// 已经是透明时，桌面/下层应用才透得过来。
    var backgroundOpacity: CGFloat = 1.0
    /// Beta gate: when false, workspace rows hide their TerminalStatusIconView
    /// and collapse its layout slot. Forwarded to SidebarListBridge.
    var showStatusIndicators: Bool = false
    /// Drives the footer version number + red pulsing dot when an update
    /// is available. Clicking the version jumps to Settings → Update.
    @Bindable var updateStore: UpdateStore
    @Environment(LanguageStore.self) private var languageStore
    @Environment(\.locale) private var locale
    @State private var metadataMap: [UUID: WorkspaceMetadata] = [:]
    @State private var refreshers: [UUID: MetadataRefresher] = [:]
    @State private var metadataTicker = MetadataChangeTicker()

    // Delete confirmation (alert lives in SwiftUI shell; AppKit row bubbles request up)
    @State private var workspaceToDelete: UUID?

    // Edit-default-command alert (same pattern as deleteAlert: AppKit row only
    // bubbles a request up; SwiftUI shell owns the input field state and writes
    // back through WorkspaceStore on Save).
    @State private var workspaceForCommandEdit: UUID?
    @State private var commandDraft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            SidebarListBridge(
                store: store,
                statusStore: statusStore,
                theme: theme,
                metadata: metadataMap,
                metadataTick: metadataTicker.tick,    // 读取触发 @Observable 跟踪
                languageTick: languageStore.tick,
                backgroundOpacity: backgroundOpacity,
                showStatusIndicators: showStatusIndicators,
                onRequestDelete: { workspaceToDelete = $0 },
                onRequestEditCommand: { id, current in
                    commandDraft = current
                    workspaceForCommandEdit = id
                }
            )
            footer
        }
        .frame(width: DT.Layout.sidebarWidth)
        // Sidebar 区有意不再自画背景 —— 依赖 ContentView 的根 `.background(sidebar)`
        // 单层提供底色。这样 sidebar 区、卡片圆角外、traffic light 带共用同一
        // 根层 alpha，颜色浓度完全一致，中间不出现「双层叠加形成的分格」。
        .onAppear { startRefreshers() }
        .onChange(of: store.workspaces) { _, _ in startRefreshers() }
        .onReceive(NotificationCenter.default.publisher(for: .mux0BeginCreateWorkspace)) { _ in
            createWorkspaceWithDefaultName()
        }
        .alert(String(localized: (L10n.Sidebar.deleteAlertTitle).withLocale(locale)),
               isPresented: Binding(
                   get: { workspaceToDelete != nil },
                   set: { if !$0 { workspaceToDelete = nil } })) {
            Button(String(localized: (L10n.Sidebar.deleteAlertCancel).withLocale(locale)), role: .cancel) {
                workspaceToDelete = nil
            }
            Button(String(localized: (L10n.Sidebar.deleteAlertConfirm).withLocale(locale)), role: .destructive) {
                if let id = workspaceToDelete { store.deleteWorkspace(id: id) }
                workspaceToDelete = nil
            }
        } message: {
            if let id = workspaceToDelete,
               let ws = store.workspaces.first(where: { $0.id == id }) {
                Text(L10n.Sidebar.deleteAlertMessage(ws.name))
            }
        }
        .alert(String(localized: L10n.Sidebar.commandAlertTitle.withLocale(locale)),
               isPresented: Binding(
                   get: { workspaceForCommandEdit != nil },
                   set: { if !$0 { workspaceForCommandEdit = nil } })) {
            TextField(
                String(localized: L10n.Sidebar.commandAlertPlaceholder.withLocale(locale)),
                text: $commandDraft
            )
            Button(String(localized: L10n.Sidebar.commandAlertCancel.withLocale(locale)), role: .cancel) {
                workspaceForCommandEdit = nil
            }
            Button(String(localized: L10n.Sidebar.commandAlertSave.withLocale(locale))) {
                if let id = workspaceForCommandEdit {
                    store.updateDefaultCommand(workspaceId: id, command: commandDraft)
                }
                workspaceForCommandEdit = nil
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: DT.Space.xs) {
            versionButton
            if updateStore.hasUpdate {
                Image(systemName: "circle.fill")
                    .font(.system(size: 6))
                    .foregroundColor(Color(theme.danger))
                    .symbolEffect(.pulse)
                    .help(String(localized: (L10n.Sidebar.updateAvailable).withLocale(locale)))
            }
            Spacer()
            IconButton(theme: theme, help: String(localized: (L10n.Sidebar.settingsTooltip).withLocale(locale))) {
                NotificationCenter.default.post(name: .mux0OpenSettings, object: nil)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(Color(theme.textSecondary))
            }
        }
        .padding(.leading, DT.Space.sm + DT.Space.md)
        .padding(.trailing, Self.iconColumnButtonTrailing)
        .padding(.vertical, DT.Space.sm)
    }

    /// 让 header "+" / footer 齿轮 / ContentView 的 sidebar toggle 按钮中心
    /// 与 sidebar row 状态图标列对齐。图标中心距 sidebar 右 =
    /// outerHorizontalInset(8) + hPad(12) + iconSize/2(5) = 25；22pt 按钮右边距 = 25 - 11 = 14。
    fileprivate static let iconColumnButtonTrailing: CGFloat = 14

    private var versionButton: some View {
        Button {
            NotificationCenter.default.post(
                name: .mux0OpenSettings,
                object: nil,
                userInfo: ["section": "update"]
            )
        } label: {
            Text("v\(updateStore.currentVersion)")
                .font(Font(DT.Font.small))
                .foregroundColor(Color(theme.textSecondary))
        }
        .buttonStyle(.plain)
        .help(String(localized: (L10n.Sidebar.checkForUpdates).withLocale(locale)))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: DT.Space.sm) {
            Text(L10n.Sidebar.title)
                .font(Font(DT.Font.title))
                .foregroundColor(Color(theme.textPrimary))
            Spacer()
            IconButton(theme: theme, help: String(localized: (L10n.Sidebar.newWorkspace).withLocale(locale))) {
                createWorkspaceWithDefaultName()
            } label: {
                Text("+")
                    .font(Font(DT.Font.body))
                    .foregroundColor(Color(theme.textSecondary))
            }
        }
        .padding(.leading, DT.Space.sm + DT.Space.md)
        .padding(.trailing, Self.iconColumnButtonTrailing)
        .padding(.vertical, DT.Space.sm)
    }

    // MARK: - Create

    func createWorkspaceWithDefaultName() {
        // Read sourceId BEFORE createWorkspace. The one case where ordering
        // matters is fresh install (selectedId == nil): createWorkspace auto-
        // selects the new workspace, after which selectedWorkspace.selectedTab
        // would resolve to the brand-new terminal, whose UUID has no pwdStore
        // entry yet — so inherit would be a silent no-op. Pre-reading also
        // documents the intent: we want the pane the user was looking at when
        // they clicked +, not whatever the selection state becomes afterwards.
        let sourceId = store.selectedWorkspace?.selectedTab?.focusedTerminalId
        let name = "workspace \(store.workspaces.count + 1)"
        let newTerminalId = store.createWorkspace(name: name)
        if let sourceId {
            pwdStore.inherit(from: sourceId, to: newTerminalId)
        }
    }

    // MARK: - Refreshers

    private func startRefreshers() {
        let activeIds = Set(store.workspaces.map { $0.id })
        for id in refreshers.keys where !activeIds.contains(id) {
            refreshers[id]?.stop()
            refreshers.removeValue(forKey: id)
            metadataMap.removeValue(forKey: id)
        }
        for ws in store.workspaces where refreshers[ws.id] == nil {
            let meta = WorkspaceMetadata()
            metadataMap[ws.id] = meta
            let workspaceId = ws.id
            let storeRef = store
            let pwdRef = pwdStore
            // workingDirectoryProvider: resolve the workspace's current cwd lazily
            // each tick. Selected tab + its focused terminal can change over time,
            // and the terminal's pwd moves with `cd`, so we can't bake a static
            // path here — we re-read WorkspaceStore + TerminalPwdStore every time.
            let refresher = MetadataRefresher(metadata: meta) { [weak storeRef, weak pwdRef] in
                guard let storeRef, let pwdRef,
                      let ws = storeRef.workspaces.first(where: { $0.id == workspaceId }),
                      let tab = ws.selectedTab
                else { return nil }
                return pwdRef.pwd(for: tab.focusedTerminalId)
            }
            let ticker = metadataTicker  // capture by reference
            refresher.onRefresh = {
                // mutate 引用类型属性 → @Observable 通知 SwiftUI body 重跑 → updateNSView 推 metadata
                // overflow-safe：tick 数值无意义，只要变化就行
                ticker.tick &+= 1
            }
            refreshers[ws.id] = refresher
            refresher.start()
        }
    }
}
