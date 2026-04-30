import SwiftUI

struct SettingsView: View {
    let theme: AppTheme
    let settings: SettingsConfigStore
    let updateStore: UpdateStore
    let workspaceStore: WorkspaceStore
    let onClose: () -> Void

    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.locale) private var locale
    @State private var section: SettingsSection

    init(
        theme: AppTheme,
        settings: SettingsConfigStore,
        updateStore: UpdateStore,
        workspaceStore: WorkspaceStore,
        initialSection: SettingsSection? = nil,
        onClose: @escaping () -> Void
    ) {
        self.theme = theme
        self.settings = settings
        self.updateStore = updateStore
        self.workspaceStore = workspaceStore
        self.onClose = onClose
        _section = State(initialValue: initialSection ?? .appearance)
    }

    var body: some View {
        VStack(spacing: 0) {
            // 四向 xs 内边距 + 下方 xs 间隔，对齐 TabContentView.layout 里 tab 条的边距。
            SettingsTabBarView(
                theme: theme,
                selection: $section,
                onClose: onClose
            )
            .padding(.top, DT.Space.xs)
            .padding(.horizontal, DT.Space.xs)
            .padding(.bottom, DT.Space.xs)

            // sectionBody + footer 共处同一圆角卡片，边界上的 hairline 由 footer
            // 自带的 overlay 负责；外层 clipShape 把两者一起裁成 stripRadius 圆角，
            // 视觉上是一整块（对齐终端模式下 paneContainer 的形状）。
            VStack(spacing: 0) {
                sectionBody
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                footer
            }
            .clipShape(RoundedRectangle(cornerRadius: TabBarView.stripRadius, style: .continuous))
            .padding(.horizontal, DT.Space.xs)
            .padding(.bottom, DT.Space.xs)
        }
        .background(Color(theme.canvas).opacity(themeManager.contentEffectiveOpacity))
        // .tint 通过 env 传给所有 Slider/Toggle/Picker 等，把系统蓝强调色换成主题 accent。
        .tint(Color(theme.accent))
        // 允许 sidebar 的版本号点击在 Settings 已经打开时再次跳转到 Update section。
        .onReceive(NotificationCenter.default.publisher(for: .mux0OpenSettings)) { note in
            if let raw = note.userInfo?["section"] as? String,
               let next = SettingsSection(rawValue: raw) {
                section = next
            }
        }
    }

    // MARK: - Section switcher

    @ViewBuilder
    private var sectionBody: some View {
        switch section {
        case .appearance: AppearanceSectionView(theme: theme, settings: settings)
        case .font:       FontSectionView(theme: theme, settings: settings)
        case .terminal:   TerminalSectionView(theme: theme, settings: settings)
        case .shell:      ShellSectionView(theme: theme, settings: settings)
        case .agents:     AgentsSectionView(theme: theme, settings: settings, workspaceStore: workspaceStore)
        case .update:     UpdateSectionView(theme: theme, updateStore: updateStore)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            TextLinkButton(theme: theme, title: String(localized: (L10n.Settings.footerEdit).withLocale(locale))) {
                settings.openInEditor()
            }
            Spacer()
            Text(L10n.Settings.footerLive)
                .font(Font(DT.Font.small))
                .foregroundColor(Color(theme.textTertiary))
        }
        .padding(.horizontal, DT.Space.md)
        .padding(.vertical, DT.Space.sm)
        .background(Color(theme.canvas).opacity(themeManager.contentEffectiveOpacity))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(theme.border).opacity(0.5 * themeManager.contentEffectiveOpacity))
                .frame(height: DT.Stroke.hairline)
        }
    }
}
