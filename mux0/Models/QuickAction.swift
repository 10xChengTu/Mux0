import Foundation

/// Stable identifier for a Quick Action. Builtin actions use their raw enum
/// case as the id (`"gitui"`, `"claude"`, ...); custom actions use a UUID
/// string assigned at creation time.
typealias QuickActionId = String

/// Curated list of first-class Quick Actions ship with mux0. Each entry has a
/// localized display name, a default command (overridable via
/// `QuickActionsStore.setBuiltinCommand`), and a fixed icon source.
///
/// Adding a new builtin: add the case here, extend `defaultCommand`,
/// `displayName`, `iconSource`, and add the corresponding L10n key + icon
/// asset (or SF Symbol).
enum BuiltinQuickAction: String, CaseIterable, Identifiable {
    case gitui
    case claude
    case codex
    case opencode

    var id: QuickActionId { rawValue }

    /// The shell command to execute when this action launches a tab. Users
    /// can override per-action via `QuickActionsStore.setBuiltinCommand`.
    var defaultCommand: String {
        switch self {
        case .gitui:    return "gitui"
        case .claude:   return "claude"
        case .codex:    return "codex"
        case .opencode: return "opencode"
        }
    }

    /// Localized display name. Resolves through the standard L10n catalog;
    /// custom actions render their user-entered name verbatim instead.
    var displayName: LocalizedStringResource {
        switch self {
        case .gitui:    return L10n.QuickActions.Builtin.gitui
        case .claude:   return L10n.QuickActions.Builtin.claude
        case .codex:    return L10n.QuickActions.Builtin.codex
        case .opencode: return L10n.QuickActions.Builtin.opencode
        }
    }

    /// Where the icon comes from. SF Symbols render via NSImage's symbol
    /// constructor; assets refer to images in `Assets.xcassets`. Custom
    /// actions don't have icon sources here — they fall back to a letter
    /// chip (`.letter`) computed from the action's name.
    var iconSource: QuickActionIcon {
        switch self {
        case .gitui:    return .sfSymbol("arrow.branch")
        case .claude:   return .asset("quick-action-claudecode")
        case .codex:    return .asset("quick-action-codex")
        case .opencode: return .asset("quick-action-opencode")
        }
    }

    /// `nil` if `id` doesn't match any builtin (likely a custom action UUID).
    static func from(id: QuickActionId) -> BuiltinQuickAction? {
        BuiltinQuickAction(rawValue: id)
    }
}

/// User-defined Quick Action. Persisted as JSON in the mux0 config file via
/// `QuickActionsStore`.
struct CustomQuickAction: Codable, Identifiable, Equatable {
    let id: QuickActionId
    var name: String
    var command: String
}

/// Discriminator for how a Quick Action's icon should render. The view layer
/// (Task 5: `QuickActionIconView`) switches on this enum.
enum QuickActionIcon: Equatable {
    /// Render via `NSImage(systemSymbolName:)` / `Image(systemName:)`.
    case sfSymbol(String)
    /// Render via `NSImage(named:)` / `Image(_:)` from the asset catalog.
    case asset(String)
    /// Render as a single-letter chip — fallback for custom actions whose
    /// user-entered name is a hint of what command they run.
    case letter(Character)
}
