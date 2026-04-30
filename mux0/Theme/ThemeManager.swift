import AppKit
import Observation

enum ColorSchemePreference {
    case dark, light, system
}

@Observable
final class ThemeManager {
    private(set) var theme: AppTheme
    private var currentScheme: ColorSchemePreference = .system

    /// ghostty `background-opacity`，值域 0…1。驱动 NSWindow 透明以及所有承载
    /// ghostty surface 的背景层的 alpha —— libghostty 按 alpha 渲染单元背景，
    /// 但任何一层不透明的 Swift/AppKit 背景都会把它挡住。
    private(set) var backgroundOpacity: CGFloat = 1.0

    /// ghostty `background-blur-radius`。仅用于让 ContentView 判断当前是否需要
    /// 在 window 上挂 blur；具体 radius 值由 libghostty 从自己的 config 里读。
    private(set) var backgroundBlurRadius: CGFloat = 0

    /// mux0 自定义 `mux0-content-opacity`，值域 0…1。作用于"中间内容区"的所有
    /// 叠加层 —— 卡片外层 canvas、paneContainer canvas、tab strip sidebar、
    /// settings 各层背景 —— 让用户在整体 `background-opacity` 之外再统一调低
    /// 中心卡片的累积浓度（因为它们原本是多层 canvas/sidebar 叠加，肉眼看起来
    /// 比 sidebar 区浑厚）。sidebar 行的选中/悬停高亮不受此倍数影响。
    private(set) var contentOpacity: CGFloat = 1.0

    /// 中间内容层实际使用的不透明度 = backgroundOpacity × contentOpacity。所有
    /// 画"中间内容"底色的视图都读它，以保证两档设置的组合效果一致。
    var contentEffectiveOpacity: CGFloat { backgroundOpacity * contentOpacity }

    /// mux0 自定义 `mux0-content-shadow`，值域 0…1。控制中央内容卡片的浅边框
    /// 与浅阴影强度——0 完全不画边框/阴影，1 为最强（仍保持"轻量"感）。
    /// 边框颜色取 theme.border，alpha 随该值线性缩放；阴影是黑色，opacity 与
    /// radius 也随该值缩放。
    private(set) var contentShadowIntensity: CGFloat = 0

    init() {
        // 初始化时直接尝试解析 ghostty config (不需要 libghostty)
        let isDark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let colors = GhosttyConfigReader.load()
        let accent = colors.palette[3] ?? colors.palette[11] ?? colors.palette[6]
        self.theme = AppTheme.derive(
            background: colors.background,
            foreground: colors.foreground,
            accent: accent,
            systemIsDark: isDark
        )
        observeSystemAppearance()
    }

    /// 根据偏好刷新主题。优先用 ghostty 的 config 文件解析结果，
    /// 否则回退到系统外观。
    func applyScheme(_ scheme: ColorSchemePreference) {
        currentScheme = scheme
        let systemIsDark: Bool
        switch scheme {
        case .dark:
            systemIsDark = true
        case .light:
            systemIsDark = false
        case .system:
            systemIsDark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }

        // 直接从 ghostty config + theme 文件解析颜色（绕过 libghostty C API 的 key 不确定性）
        let colors = GhosttyConfigReader.load()
        let accent = colors.palette[3]   // ANSI yellow
            ?? colors.palette[11]
            ?? colors.palette[6]
            ?? colors.palette[14]

        let newTheme = AppTheme.derive(
            background: colors.background,
            foreground: colors.foreground,
            accent: accent,
            systemIsDark: systemIsDark
        )

        // 只在主题真的变了时才赋值，避免无谓的 @Observable 通知。
        // 无谓的 theme 重设会冒泡到 ContentView 重建整棵视图树，
        // 导致正在编辑的 TextField 被拆掉、焦点丢失。
        if theme != newTheme {
            theme = newTheme
        }

        if GhosttyBridge.shared.isInitialized {
            GhosttyBridge.shared.applyColorScheme(theme.isDark)
        }
    }

    /// 触发一次刷新，使用当前偏好。供 ghostty 配置变化或外部事件调用。
    func refresh() {
        applyScheme(currentScheme)
    }

    /// 推入最新的 window effects。clamp 后只在值真的变化时赋值，避免无谓的
    /// @Observable 通知让 SwiftUI 重建视图树。
    func applyWindowEffects(opacity: CGFloat, blurRadius: CGFloat, contentOpacity: CGFloat = 1.0, contentShadow: CGFloat = 0) {
        let clampedOpacity = max(0, min(1, opacity))
        let clampedBlur = max(0, min(100, blurRadius))
        let clampedContent = max(0, min(1, contentOpacity))
        let clampedShadow = max(0, min(1, contentShadow))
        if backgroundOpacity != clampedOpacity { backgroundOpacity = clampedOpacity }
        if backgroundBlurRadius != clampedBlur { backgroundBlurRadius = clampedBlur }
        if self.contentOpacity != clampedContent { self.contentOpacity = clampedContent }
        if contentShadowIntensity != clampedShadow { contentShadowIntensity = clampedShadow }
    }

    // MARK: - ghostty config color → NSColor

    private static func nsColor(from c: ghostty_config_color_s) -> NSColor {
        NSColor(
            srgbRed: CGFloat(c.r) / 255.0,
            green:   CGFloat(c.g) / 255.0,
            blue:    CGFloat(c.b) / 255.0,
            alpha:   1
        )
    }

    /// 从 ghostty 256-color palette 选 accent。优先 yellow(3)，回退 cyan(6)，再回退 nil。
    private static func accentFromPalette(_ palette: ghostty_config_palette_s?) -> NSColor? {
        guard let palette else { return nil }
        let colors = withUnsafeBytes(of: palette.colors) { buf in
            buf.bindMemory(to: ghostty_config_color_s.self)
        }
        // 跳过纯黑/纯白占位
        func valid(_ idx: Int) -> NSColor? {
            guard idx < colors.count else { return nil }
            let c = colors[idx]
            if c.r == 0 && c.g == 0 && c.b == 0 { return nil }
            return nsColor(from: c)
        }
        return valid(3) ?? valid(11) ?? valid(6) ?? valid(14)
    }

    // MARK: - Legacy (保留给老调用点 / 测试)

    @available(*, deprecated, message: "Use applyScheme + ghostty config")
    func parseThemeFromConfig(at path: String) -> String? {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#") else { continue }
            let parts = trimmed.components(separatedBy: "=")
            guard parts.count >= 2,
                  parts[0].trimmingCharacters(in: .whitespaces) == "theme" else { continue }
            let value = parts[1...].joined(separator: "=").trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { return value }
        }
        return nil
    }

    /// 给老 ContentView.onAppear 用的入口；现在等同于 refresh()。
    func loadFromGhosttyConfig() {
        applyScheme(currentScheme)
    }

    private func observeSystemAppearance() {
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.currentScheme == .system else { return }
            self.applyScheme(.system)
        }
    }
}
