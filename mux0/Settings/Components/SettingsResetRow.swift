import SwiftUI

/// 每个设置 section 的最后一行。作为 Form 的普通 row 渲染：左边 "Restore Defaults"
/// 标签，右边 "Reset" 按钮。点击把 section 管控的 key 从 mux0 override 文件删光，
/// ghostty 即回退到自身默认。200ms debounce 把多次删除合并成一次落盘 + 一次
/// reloadConfig，UI 不抖。
struct SettingsResetRow: View {
    let settings: SettingsConfigStore
    let keys: [String]
    /// Sections that own state outside `SettingsConfigStore` (e.g. Agents'
    /// per-terminal `pendingPrefills` in `WorkspaceStore`) pass a closure
    /// here so the destructive reset clears that state too — otherwise the
    /// row would only delete the config keys and leave related state stale.
    var additionalAction: () -> Void = { }

    @State private var confirmingReset = false
    @Environment(\.locale) private var locale

    var body: some View {
        LabeledContent(String(localized: (L10n.Settings.resetRowLabel).withLocale(locale))) {
            HStack {
                Spacer(minLength: 0)
                Button {
                    confirmingReset = true
                } label: {
                    Text(L10n.Settings.resetButton)
                }
                .buttonStyle(.bordered)
            }
        }
        .alert(String(localized: (L10n.Settings.resetAlertTitle).withLocale(locale)), isPresented: $confirmingReset) {
            Button(String(localized: (L10n.Settings.resetButton).withLocale(locale)), role: .destructive) {
                for key in keys {
                    settings.set(key, nil)
                }
                additionalAction()
            }
            Button(String(localized: (L10n.Settings.resetCancel).withLocale(locale)), role: .cancel) { }
        } message: {
            Text(L10n.Settings.resetMessage)
        }
    }
}
