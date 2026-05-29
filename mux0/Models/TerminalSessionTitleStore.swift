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
    /// Last accepted update timestamp per terminal (epoch seconds). NOT
    /// persisted — on relaunch it starts empty so the first live hook always
    /// wins over whatever title was restored from disk. Used to reject
    /// out-of-order hook deliveries (e.g. a rotated session's trailing `stop`
    /// landing after the next session's `prompt`), mirroring
    /// `TerminalStatusStore`'s staleness guard.
    private var lastAt: [String: TimeInterval] = [:]
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
    /// the previously known title. `at` (the hook event timestamp) gates
    /// out-of-order deliveries: an update older than the last accepted one
    /// for the same terminal is ignored.
    func update(terminalId: UUID, title: String, at: TimeInterval) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let key = terminalId.uuidString
        if let prev = lastAt[key], at < prev { return }
        lastAt[key] = at
        guard storage[key] != trimmed else { return }
        storage[key] = trimmed
        scheduleSave()
    }

    func clear(terminalId: UUID) {
        lastAt.removeValue(forKey: terminalId.uuidString)
        guard storage.removeValue(forKey: terminalId.uuidString) != nil else { return }
        scheduleSave()
    }

    func clear(terminalIds: [UUID]) {
        var changed = false
        for id in terminalIds {
            lastAt.removeValue(forKey: id.uuidString)
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
