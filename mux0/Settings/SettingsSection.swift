import Foundation

/// 设置视图的七个硬编码分类。顺序即 tab 条显示顺序（quickActions / agents
/// 被顶到第 2/3 位是产品决定，使用频率高于 font / terminal / shell）。
enum SettingsSection: String, CaseIterable, Identifiable {
    case appearance
    case quickActions
    case agents
    case font
    case terminal
    case shell
    case update

    var id: String { rawValue }

    var label: LocalizedStringResource {
        switch self {
        case .appearance:   return L10n.Settings.sectionAppearance
        case .font:         return L10n.Settings.sectionFont
        case .terminal:     return L10n.Settings.sectionTerminal
        case .shell:        return L10n.Settings.sectionShell
        case .quickActions: return L10n.Settings.sectionQuickActions
        case .agents:       return L10n.Settings.sectionAgents
        case .update:       return L10n.Settings.sectionUpdate
        }
    }
}
