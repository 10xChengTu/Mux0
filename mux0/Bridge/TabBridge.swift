import SwiftUI
import AppKit

struct TabBridge: NSViewRepresentable {
    @Bindable var store: WorkspaceStore
    @Bindable var statusStore: TerminalStatusStore
    @Bindable var pwdStore: TerminalPwdStore
    @Bindable var settings: SettingsConfigStore
    var theme: AppTheme
    /// ghostty `background-opacity`，用来给 AppKit layer 背景（canvas / sidebar strip）
    /// 加 alpha —— 不动 theme token 本身，避免派生出的 border/text 色也被乘透。
    var backgroundOpacity: CGFloat = 1.0
    /// Beta gate: when false, per-tab TerminalStatusIconView is hidden and its
    /// layout slot collapses so the tab label uses the full pill width.
    var showStatusIndicators: Bool = false
    /// 语言切换 ticker：ContentView 透传 languageStore.tick。任何变化触发 updateNSView，
    /// 我们在里面调 TabContentView.refreshLocalizedStrings() 让子 AppKit view 重读静态文案。
    var languageTick: Int

    @Environment(\.locale) private var locale

    func makeNSView(context: Context) -> TabContentView {
        let view = TabContentView(frame: .zero)
        view.store = store
        view.pwdStore = pwdStore
        view.settingsStore = settings
        view.applyTheme(theme, backgroundOpacity: backgroundOpacity, locale: locale)
        if let ws = store.selectedWorkspace {
            view.loadWorkspace(ws,
                               statuses: statusStore.statusesSnapshot(),
                               showStatusIndicators: showStatusIndicators)
        }
        return view
    }

    func updateNSView(_ nsView: TabContentView, context: Context) {
        _ = languageTick
        nsView.store = store
        nsView.pwdStore = pwdStore
        nsView.settingsStore = settings
        nsView.applyTheme(theme, backgroundOpacity: backgroundOpacity, locale: locale)
        if let ws = store.selectedWorkspace {
            nsView.loadWorkspace(ws,
                                 statuses: statusStore.statusesSnapshot(),
                                 showStatusIndicators: showStatusIndicators)
        }
        nsView.refreshLocalizedStrings(locale: locale)
    }

    static func dismantleNSView(_ nsView: TabContentView, coordinator: ()) {
        nsView.detach()
    }
}
