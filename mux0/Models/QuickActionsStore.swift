import Foundation
import Observation

/// State for the Quick Actions feature: a stable visual order across all
/// known ids (`orderedIds`), an enabled set (`enabledSet`), per-builtin
/// command overrides, and the user's custom action list.
///
/// **Ordering model.** A single `orderedIds` array owns the visual order for
/// both the Settings list and the top bar; it is NOT mutated by toggling
/// enable/disable — only by `reorderFull` (drag-reorder). This way a row
/// stays put when the user flips its switch instead of jumping between
/// "enabled" and "disabled" groups.
///
/// Persistence piggybacks on `SettingsConfigStore` (the mux0 config file at
/// `~/Library/Application Support/mux0/config`). Four keys:
///
/// - `mux0-quickactions-order`   — JSON array of all known `QuickActionId`
///   strings, in user-curated visual order. Source of truth for display.
/// - `mux0-quickactions-enabled` — JSON array of enabled ids (membership
///   only; written in `orderedIds` order for human-readable diffs).
/// - `mux0-quickactions-custom`  — JSON array of `CustomQuickAction`.
/// - `mux0-quickactions-builtin-command-<id>` — string, present only when
///   the user has overridden the builtin's default command.
///
/// External edits to the config file (Settings UI's "Edit" mode) should call
/// `reloadFromSettings()` to refresh this store; settings.onChange usually
/// drives that wire-up.
@Observable
final class QuickActionsStore {
    /// Stable visual order across ALL known ids (built-ins + customs). Owns
    /// both the Settings list order and the top-bar order. Mutated only by
    /// `reorderFull` / `addCustomAction` / `removeCustomAction` and by load-
    /// time migration. Never touched by `setEnabled`.
    ///
    /// May contain orphan ids (refs to deleted custom actions); they are
    /// filtered out of `fullList` / `displayList` but kept in storage so an
    /// out-of-band edit doesn't silently lose them.
    private(set) var orderedIds: [QuickActionId] = []

    /// Enabled membership. Order is held by `orderedIds`; this is just a set
    /// for O(1) membership checks.
    private var enabledSet: Set<QuickActionId> = []

    /// Sparse map: only contains an entry for builtins whose command the
    /// user has explicitly set. Empty / whitespace overrides are stored as
    /// "no override" (the entry is removed) so `command(for:)` falls back to
    /// the BuiltinQuickAction default.
    private(set) var builtinCommandOverrides: [QuickActionId: String] = [:]

    /// User-defined actions. Visual order is owned by `orderedIds`, NOT this
    /// array — `customActions` is just the data store keyed by id.
    private(set) var customActions: [CustomQuickAction] = []

    /// Backward-compatible array view for callers that want "enabled, in
    /// display order" (tests, debugging). Filters orphans.
    var enabledIds: [QuickActionId] {
        orderedIds.filter { enabledSet.contains($0) && exists($0) }
    }

    private let settings: SettingsConfigStore

    private static let kEnabled = "mux0-quickactions-enabled"
    private static let kCustom  = "mux0-quickactions-custom"
    private static let kOrder   = "mux0-quickactions-order"
    private static func kBuiltinCmd(_ id: QuickActionId) -> String {
        "mux0-quickactions-builtin-command-\(id)"
    }

    init(settings: SettingsConfigStore) {
        self.settings = settings
        load()
    }

    /// Read all four Quick Actions keys out of the SettingsConfigStore's
    /// in-memory `lines`. Caller is responsible for clearing existing state
    /// first if this is a reload (see `reloadFromSettings`).
    private func load() {
        // 1. customActions (so order migration can validate ids).
        if let raw = settings.get(Self.kCustom),
           let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([CustomQuickAction].self, from: data) {
            customActions = decoded
        }

        // 2. enabledSet (legacy key — array semantics, but we use it as a set).
        var legacyEnabledOrder: [QuickActionId] = []
        if let raw = settings.get(Self.kEnabled),
           let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([QuickActionId].self, from: data) {
            legacyEnabledOrder = decoded
            enabledSet = Set(decoded)
        }

        // 3. orderedIds — load from new key, or migrate from legacy snapshot.
        if let raw = settings.get(Self.kOrder),
           let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([QuickActionId].self, from: data) {
            orderedIds = decoded
        } else {
            // Legacy migration: take the snapshot of the OLD fullList logic
            // (enabled order, then disabled built-ins in allCases order, then
            // disabled customs in customActions array order). After this
            // first load we persist `kOrder` so future toggles never
            // re-shuffle.
            var seen = Set<QuickActionId>()
            var result: [QuickActionId] = []
            for id in legacyEnabledOrder where !seen.contains(id) {
                result.append(id); seen.insert(id)
            }
            for builtin in BuiltinQuickAction.allCases where !seen.contains(builtin.id) {
                result.append(builtin.id); seen.insert(builtin.id)
            }
            for custom in customActions where !seen.contains(custom.id) {
                result.append(custom.id); seen.insert(custom.id)
            }
            orderedIds = result
        }

        // 4. Append any new ids that the saved order didn't have yet (e.g.
        //    builtin shipped in a newer app version, or a custom that
        //    somehow wasn't recorded). Preserves prior ordering for known ids.
        var seen = Set(orderedIds)
        for builtin in BuiltinQuickAction.allCases where !seen.contains(builtin.id) {
            orderedIds.append(builtin.id); seen.insert(builtin.id)
        }
        for custom in customActions where !seen.contains(custom.id) {
            orderedIds.append(custom.id); seen.insert(custom.id)
        }

        // 5. builtin command overrides.
        for builtin in BuiltinQuickAction.allCases {
            if let raw = settings.get(Self.kBuiltinCmd(builtin.id)),
               !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                builtinCommandOverrides[builtin.id] = raw
            }
        }

        // Persist the order — this writes the migrated/appended state on
        // first load (so the next launch reads `kOrder` directly) and is a
        // no-op (idempotent) when `kOrder` already matches.
        saveOrder()
    }

    /// Reload from settings — used when the underlying mux0 config file
    /// changes (e.g. user edited it in their text editor) and we need to
    /// pick up new values without recreating the store.
    func reloadFromSettings() {
        orderedIds.removeAll()
        enabledSet.removeAll()
        builtinCommandOverrides.removeAll()
        customActions.removeAll()
        load()
    }

    // MARK: - Read

    func isEnabled(_ id: QuickActionId) -> Bool {
        enabledSet.contains(id)
    }

    private func exists(_ id: QuickActionId) -> Bool {
        BuiltinQuickAction.from(id: id) != nil
            || customActions.contains(where: { $0.id == id })
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

    /// Top-bar render source: `orderedIds` filtered by enabled membership +
    /// existence (orphans dropped).
    var displayList: [QuickActionId] {
        orderedIds.filter { enabledSet.contains($0) && exists($0) }
    }

    /// Settings list render source: `orderedIds` filtered by existence
    /// (orphans dropped).
    var fullList: [QuickActionId] {
        orderedIds.filter { exists($0) }
    }

    // MARK: - Mutate

    /// Toggle visibility in the top bar. Idempotent. Does NOT change
    /// `orderedIds` — the row keeps its position in both the Settings list
    /// and the top bar across enable/disable transitions.
    func setEnabled(_ id: QuickActionId, _ enabled: Bool) {
        let was = enabledSet.contains(id)
        if enabled {
            enabledSet.insert(id)
        } else {
            enabledSet.remove(id)
        }
        if was != enabled { saveEnabled() }
    }

    /// Set a per-builtin command override. No-ops for non-builtin ids.
    /// Empty/whitespace input clears the override.
    func setBuiltinCommand(_ id: QuickActionId, _ command: String) {
        guard BuiltinQuickAction.from(id: id) != nil else { return }
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
    /// follow up with `updateCustomAction` to fill in name + command. The
    /// new id appears at the bottom of `orderedIds`.
    @discardableResult
    func addCustomAction() -> QuickActionId {
        let id = UUID().uuidString
        customActions.append(CustomQuickAction(id: id, name: "", command: ""))
        orderedIds.append(id)
        saveCustom()
        saveOrder()
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

    /// Remove a custom action by id. Also un-enables it and removes it from
    /// `orderedIds` so the top bar updates immediately.
    func removeCustomAction(_ id: QuickActionId) {
        let beforeEnabled = enabledSet
        let beforeOrder = orderedIds
        customActions.removeAll { $0.id == id }
        enabledSet.remove(id)
        orderedIds.removeAll { $0 == id }
        saveCustom()
        if enabledSet != beforeEnabled { saveEnabled() }
        if orderedIds != beforeOrder { saveOrder() }
    }

    /// `displayList`-dimension reorder. Maps the post-move displayList back
    /// onto `orderedIds` by walking it and swapping enabled positions in the
    /// new order. Disabled items between enabled positions stay put.
    func reorderDisplay(from source: IndexSet, to destination: Int) {
        var working = displayList
        working.move(fromOffsets: source, toOffset: destination)
        let beforeOrder = orderedIds
        var iter = working.makeIterator()
        for (idx, id) in orderedIds.enumerated()
        where enabledSet.contains(id) && exists(id) {
            if let next = iter.next() {
                orderedIds[idx] = next
            }
        }
        if orderedIds != beforeOrder { saveOrder() }
    }

    /// `fullList`-dimension reorder. Same anchor-mapping as `reorderDisplay`,
    /// but over all existing ids. Orphan ids in `orderedIds` are skipped
    /// (they aren't in `fullList`) and keep their position.
    func reorderFull(from source: IndexSet, to destination: Int) {
        var working = fullList
        working.move(fromOffsets: source, toOffset: destination)
        let beforeOrder = orderedIds
        var iter = working.makeIterator()
        for (idx, id) in orderedIds.enumerated() where exists(id) {
            if let next = iter.next() {
                orderedIds[idx] = next
            }
        }
        if orderedIds != beforeOrder { saveOrder() }
    }

    // MARK: - Persist

    private func saveEnabled() {
        // Write enabled ids in `orderedIds` order so the on-disk JSON has a
        // human-readable, deterministic shape — Set has no order, but we'd
        // rather not write a randomized array.
        let arr = orderedIds.filter { enabledSet.contains($0) }
        if let data = try? JSONEncoder().encode(arr),
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

    private func saveOrder() {
        if let data = try? JSONEncoder().encode(orderedIds),
           let s = String(data: data, encoding: .utf8) {
            settings.set(Self.kOrder, s)
        }
    }
}
