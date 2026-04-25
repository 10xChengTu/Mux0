import SwiftUI
import AppKit

struct SidebarListBridge: NSViewRepresentable {
    @Bindable var store: WorkspaceStore
    @Bindable var statusStore: TerminalStatusStore
    var theme: AppTheme
    var metadata: [UUID: WorkspaceMetadata]
    /// 由 SidebarView 用 @State Int 触发；本身不读，只用于让 SwiftUI 重跑 body→updateNSView，
    /// 把最新 metadata 推进 WorkspaceListView。
    var metadataTick: Int
    /// 语言切换 ticker：SidebarView 透传 languageStore.tick。任何变化触发 updateNSView，
    /// 我们在里面调 WorkspaceListView.refreshLocalizedStrings() 重读静态文案。
    var languageTick: Int
    /// ghostty `background-opacity`，透传给 row 的 selected/hovered 填充色。
    var backgroundOpacity: CGFloat = 1.0
    /// Beta gate: when false, rows omit the TerminalStatusIconView subview and
    /// collapse its layout slot so the title uses the full row width.
    var showStatusIndicators: Bool = false
    var onRequestDelete: (UUID) -> Void
    /// SwiftUI shell receives (workspaceId, currentCommand) and presents the
    /// edit alert. On Save the shell writes back via `store.updateDefaultCommand`.
    var onRequestEditCommand: (UUID, String) -> Void

    func makeNSView(context: Context) -> WorkspaceListView {
        let view = WorkspaceListView()
        wire(view)
        view.update(workspaces: store.workspaces,
                    selectedId: store.selectedId,
                    metadata: metadata,
                    statuses: statusStore.statusesSnapshot(),
                    theme: theme,
                    backgroundOpacity: backgroundOpacity,
                    showStatusIndicators: showStatusIndicators)
        return view
    }

    func updateNSView(_ view: WorkspaceListView, context: Context) {
        _ = metadataTick
        _ = languageTick
        wire(view)
        view.update(workspaces: store.workspaces,
                    selectedId: store.selectedId,
                    metadata: metadata,
                    statuses: statusStore.statusesSnapshot(),
                    theme: theme,
                    backgroundOpacity: backgroundOpacity,
                    showStatusIndicators: showStatusIndicators)
        view.refreshLocalizedStrings()
    }

    private func wire(_ view: WorkspaceListView) {
        view.onSelect        = { id in store.select(id: id) }
        view.onRename        = { id, name in store.renameWorkspace(id: id, to: name) }
        view.onReorder       = { from, to in store.moveWorkspace(from: IndexSet([from]), to: to) }
        view.onRequestDelete = { id in onRequestDelete(id) }
        view.onRequestEditCommand = { id, current in onRequestEditCommand(id, current) }
    }
}
