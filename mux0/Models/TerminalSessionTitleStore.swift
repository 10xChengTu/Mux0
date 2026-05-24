import Foundation
import Observation

/// Per-terminal human-readable agent session title, keyed by terminal UUID.
/// Populated by `HookDispatcher` when an agent hook emits a `sessionTitle`
/// field; consumed by `TabItemView` via `TerminalTab.displayTitle(store:)`.
///
/// Persisted to UserDefaults under `mux0.sessionTitles.v1` so that on app
/// restart each tab can keep showing its previous title until the next hook
/// emit refreshes it. Writes are debounced (300 ms) to match `TerminalPwdStore`'s
/// pattern — title arrival typically happens once per turn, not per keystroke,
/// but keeping the same debouncer keeps both stores' UserDefaults patterns aligned.
@Observable
final class TerminalSessionTitleStore {
    private var storage: [String: String] = [:]
    private let persistenceKey: String
    private var saveWorkItem: DispatchWorkItem?

    init(persistenceKey: String = "mux0.sessionTitles.v1") {
        self.persistenceKey = persistenceKey
        load()
    }

    func title(for terminalId: UUID) -> String? {
        storage[terminalId.uuidString]
    }

    /// Write `title` for `terminalId`. Empty or whitespace-only inputs are
    /// dropped — agents emit empty strings before the LLM-generated title is
    /// materialized, and we don't want a transient empty state to wipe out
    /// the previously known title.
    func update(terminalId: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard storage[terminalId.uuidString] != trimmed else { return }
        storage[terminalId.uuidString] = trimmed
        scheduleSave()
    }

    func clear(terminalId: UUID) {
        guard storage.removeValue(forKey: terminalId.uuidString) != nil else { return }
        scheduleSave()
    }

    func clear(terminalIds: [UUID]) {
        var changed = false
        for id in terminalIds {
            if storage.removeValue(forKey: id.uuidString) != nil { changed = true }
        }
        if changed { scheduleSave() }
    }

    /// Snapshot of all titles keyed by `UUID`. The AppKit tab bar reads this
    /// once per `update(...)` so the render path doesn't depend on Observable
    /// tracking of the SwiftUI side.
    func titlesSnapshot() -> [UUID: String] {
        var out: [UUID: String] = [:]
        for (k, v) in storage {
            if let id = UUID(uuidString: k) { out[id] = v }
        }
        return out
    }

    // MARK: - Persistence

    #if DEBUG
    /// Immediately flush any pending debounced save. Used only in tests.
    func flushSaveForTesting() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        save()
    }
    #endif

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.save() }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(storage) else { return }
        UserDefaults.standard.set(data, forKey: persistenceKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return }
        storage = decoded
    }
}
