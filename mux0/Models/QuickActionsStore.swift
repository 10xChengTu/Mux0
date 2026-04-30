import Foundation
import Observation

/// State for the Quick Actions feature: which actions appear in the top bar
/// (`enabledIds`), per-builtin command overrides, and the user's custom
/// action list.
///
/// Persistence piggybacks on `SettingsConfigStore` (the mux0 config file at
/// `~/Library/Application Support/mux0/config`). Three keys:
///
/// - `mux0-quickactions-enabled` — JSON array of enabled `QuickActionId`
///   strings, ordered.
/// - `mux0-quickactions-custom`  — JSON array of `CustomQuickAction`.
/// - `mux0-quickactions-builtin-command-<id>` — string, present only when
///   the user has overridden the builtin's default command.
///
/// External edits to the config file (Settings UI's "Edit" mode) should call
/// `reloadFromSettings()` to refresh this store; settings.onChange usually
/// drives that wire-up.
@Observable
final class QuickActionsStore {
    /// User's chosen visible-and-ordered Quick Actions. Mix of builtin ids
    /// and custom UUIDs. Ordering matters — this is also the top-bar render
    /// order. Orphan ids (custom UUIDs whose action was deleted) stay in
    /// this array but are filtered out of `displayList`; we don't silently
    /// strip them on load to avoid clobbering edits made in another window.
    private(set) var enabledIds: [QuickActionId] = []

    /// Sparse map: only contains an entry for builtins whose command the
    /// user has explicitly set. Empty / whitespace overrides are stored as
    /// "no override" (the entry is removed) so `command(for:)` falls back to
    /// the BuiltinQuickAction default.
    private(set) var builtinCommandOverrides: [QuickActionId: String] = [:]

    /// User-defined actions. Order is the user's authoring order; the
    /// top-bar render order comes from `enabledIds`, not this array.
    private(set) var customActions: [CustomQuickAction] = []

    private let settings: SettingsConfigStore

    private static let kEnabled = "mux0-quickactions-enabled"
    private static let kCustom  = "mux0-quickactions-custom"
    private static func kBuiltinCmd(_ id: QuickActionId) -> String {
        "mux0-quickactions-builtin-command-\(id)"
    }

    init(settings: SettingsConfigStore) {
        self.settings = settings
        load()
    }

    /// Read all three Quick Actions keys out of the SettingsConfigStore's
    /// in-memory `lines`. Caller is responsible for clearing existing state
    /// first if this is a reload (see `reloadFromSettings`).
    private func load() {
        if let raw = settings.get(Self.kEnabled),
           let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([QuickActionId].self, from: data) {
            enabledIds = decoded
        }
        if let raw = settings.get(Self.kCustom),
           let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([CustomQuickAction].self, from: data) {
            customActions = decoded
        }
        for builtin in BuiltinQuickAction.allCases {
            if let raw = settings.get(Self.kBuiltinCmd(builtin.id)),
               !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                builtinCommandOverrides[builtin.id] = raw
            }
        }
    }

    /// Reload from settings — used when the underlying mux0 config file
    /// changes (e.g. user edited it in their text editor) and we need to
    /// pick up new values without recreating the store.
    func reloadFromSettings() {
        enabledIds.removeAll()
        builtinCommandOverrides.removeAll()
        customActions.removeAll()
        load()
    }

    // MARK: - Read

    func isEnabled(_ id: QuickActionId) -> Bool {
        enabledIds.contains(id)
    }

    /// The shell command associated with `id`, after applying builtin
    /// overrides and custom-action lookups. Returns nil if `id` is unknown
    /// (no matching builtin / custom) or if a custom action's command is
    /// empty.
    func command(for id: QuickActionId) -> String? {
        if let builtin = BuiltinQuickAction.from(id: id) {
            if let override = builtinCommandOverrides[id]?
                .trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
                return override
            }
            return builtin.defaultCommand
        }
        guard let custom = customActions.first(where: { $0.id == id }) else { return nil }
        let trimmed = custom.command.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Localized display name. Builtin uses the L10n catalog (resolved
    /// against the supplied `locale`); custom uses the user-entered name
    /// (verbatim, untrimmed-but-trimmed-for-fallback). Falls back to the id
    /// string if neither matches.
    func displayName(for id: QuickActionId, locale: Locale) -> String {
        if let builtin = BuiltinQuickAction.from(id: id) {
            return String(localized: builtin.displayName.withLocale(locale))
        }
        if let custom = customActions.first(where: { $0.id == id }) {
            let trimmed = custom.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? id : trimmed
        }
        return id
    }

    /// Render hint for the icon — see QuickActionIcon doc comments.
    /// Custom actions get a `.letter` chip computed from the first letter of
    /// the name (uppercased), or `"?"` when the name is blank.
    func iconSource(for id: QuickActionId) -> QuickActionIcon {
        if let builtin = BuiltinQuickAction.from(id: id) {
            return builtin.iconSource
        }
        let name = customActions.first(where: { $0.id == id })?
            .name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let first = name.first.map { Character(String($0).uppercased()) } ?? "?"
        return .letter(first)
    }

    /// Top-bar render source: keeps `enabledIds` order, filters out orphan
    /// ids (ids referencing a custom action that no longer exists). Builtin
    /// ids always pass.
    var displayList: [QuickActionId] {
        enabledIds.filter { id in
            BuiltinQuickAction.from(id: id) != nil
                || customActions.contains(where: { $0.id == id })
        }
    }

    // MARK: - Mutate

    /// Toggle visibility in the top bar. Idempotent. New ids append at the
    /// end (preserves user-curated ordering of older ids).
    func setEnabled(_ id: QuickActionId, _ enabled: Bool) {
        let before = enabledIds
        if enabled, !enabledIds.contains(id) {
            enabledIds.append(id)
        } else if !enabled {
            enabledIds.removeAll { $0 == id }
        }
        if enabledIds != before { saveEnabled() }
    }

    /// Set or clear the per-builtin command override. Empty / whitespace
    /// command clears the override (so `command(for:)` falls back to the
    /// builtin default). Non-builtin ids are silently no-ops at the
    /// persistence layer (the key is still written, but `command(for:)`
    /// won't read it back) — callers should restrict to builtins.
    func setBuiltinCommand(_ id: QuickActionId, _ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            builtinCommandOverrides.removeValue(forKey: id)
            settings.set(Self.kBuiltinCmd(id), nil)
        } else {
            builtinCommandOverrides[id] = command
            settings.set(Self.kBuiltinCmd(id), command)
        }
    }

    /// Append a new empty custom action and return its UUID. Caller should
    /// follow up with `updateCustomAction` to fill in name + command.
    @discardableResult
    func addCustomAction() -> QuickActionId {
        let id = UUID().uuidString
        customActions.append(CustomQuickAction(id: id, name: "", command: ""))
        saveCustom()
        return id
    }

    /// Patch a custom action's name and/or command. No-op if id doesn't
    /// match a known custom (silently ignored — guard the caller, e.g.
    /// SwiftUI bindings should never feed unknown ids here in practice).
    func updateCustomAction(_ id: QuickActionId, name: String? = nil, command: String? = nil) {
        guard let idx = customActions.firstIndex(where: { $0.id == id }) else { return }
        if let n = name { customActions[idx].name = n }
        if let c = command { customActions[idx].command = c }
        saveCustom()
    }

    /// Remove a custom action by id. Also un-enables it (removes from
    /// `enabledIds`) so the top bar updates immediately.
    func removeCustomAction(_ id: QuickActionId) {
        customActions.removeAll { $0.id == id }
        let beforeEnabled = enabledIds
        enabledIds.removeAll { $0 == id }
        saveCustom()
        if enabledIds != beforeEnabled { saveEnabled() }
    }

    /// `displayList`-dimension reorder. Maps the reorder back onto
    /// `enabledIds` (the ordering source). Preserves any orphan ids in
    /// `enabledIds` (filtered from displayList) by appending them at the
    /// end so we don't accidentally clobber config from another window.
    func reorderDisplay(from source: IndexSet, to destination: Int) {
        let before = enabledIds
        var working = displayList
        working.move(fromOffsets: source, toOffset: destination)
        let validSet = Set(working)
        let dirty = before.filter { !validSet.contains($0) }
        enabledIds = working + dirty
        if enabledIds != before { saveEnabled() }
    }

    // MARK: - Persist

    private func saveEnabled() {
        if let data = try? JSONEncoder().encode(enabledIds),
           let s = String(data: data, encoding: .utf8) {
            settings.set(Self.kEnabled, s)
        }
    }

    private func saveCustom() {
        if let data = try? JSONEncoder().encode(customActions),
           let s = String(data: data, encoding: .utf8) {
            settings.set(Self.kCustom, s)
        }
    }
}
