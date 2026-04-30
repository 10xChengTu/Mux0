import Foundation
import Observation

@Observable
final class WorkspaceStore {
    private(set) var workspaces: [Workspace] = []
    private(set) var selectedId: UUID?
    private let persistenceKey: String
    private var saveWorkItem: DispatchWorkItem?  // debounce rapid ratio updates

    init(persistenceKey: String = "mux0.workspaces.v2") {
        self.persistenceKey = persistenceKey
        load()
        if workspaces.isEmpty && persistenceKey == "mux0.workspaces.v2" {
            createWorkspace(name: "Default")
        }
        if selectedId == nil { selectedId = workspaces.first?.id }
    }

    var selectedWorkspace: Workspace? {
        workspaces.first { $0.id == selectedId }
    }

    // MARK: - Workspace CRUD

    @discardableResult
    func createWorkspace(name: String) -> UUID {
        var ws = Workspace(name: name)
        let tab = makeNewTab(index: 1)
        ws.tabs.append(tab)
        ws.selectedTabId = tab.id
        workspaces.append(ws)
        if selectedId == nil { selectedId = ws.id }
        save()
        // Safe: makeNewTab initializes `layout = .terminal(_)`, so allTerminalIds()
        // always returns a 1-element array.
        return tab.layout.allTerminalIds()[0]
    }

    func deleteWorkspace(id: UUID) {
        workspaces.removeAll { $0.id == id }
        if selectedId == id { selectedId = workspaces.first?.id }
        save()
    }

    func renameWorkspace(id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = wsIndex(id),
              workspaces[idx].name != trimmed else { return }
        workspaces[idx].name = trimmed
        save()
    }

    func updateDefaultCommand(workspaceId: UUID, command: String?) {
        guard let idx = wsIndex(workspaceId) else { return }
        let trimmed = command?.trimmingCharacters(in: .whitespacesAndNewlines)
        let newValue = (trimmed?.isEmpty ?? true) ? nil : trimmed
        guard workspaces[idx].defaultCommand != newValue else { return }
        workspaces[idx].defaultCommand = newValue
        save()
    }

    // MARK: - Reorder

    /// 重排 workspace 顺序。`destination` 使用插入位置语义（0…workspaces.count）。
    /// 若顺序未变不写盘。
    func moveWorkspace(from source: IndexSet, to destination: Int) {
        let beforeIds = workspaces.map(\.id)
        workspaces.move(fromOffsets: source, toOffset: destination)
        guard workspaces.map(\.id) != beforeIds else { return }
        save()
    }

    /// 在指定 workspace 内重排 tabs。`destination` 使用插入位置语义（0…tabs.count），
    /// 与 SwiftUI `onMove` 约定一致。若移动后数组顺序未变（原地放下），不写盘——
    /// 调用方拖拽结束时无条件调用即可，不需要提前判等。
    func moveTab(from source: IndexSet, to destination: Int, in workspaceId: UUID) {
        guard let wsIdx = wsIndex(workspaceId) else { return }
        let beforeIds = workspaces[wsIdx].tabs.map(\.id)
        workspaces[wsIdx].tabs.move(fromOffsets: source, toOffset: destination)
        guard workspaces[wsIdx].tabs.map(\.id) != beforeIds else { return }
        save()
    }

    /// AppKit 便利 overload：`TabBarView` drop handler 用 Int 坐标计算出插入索引，
    /// 这里包一层转为 `IndexSet([fromIndex])` 转发给主 overload。
    func moveTab(fromIndex: Int, toIndex: Int, in workspaceId: UUID) {
        moveTab(from: IndexSet([fromIndex]), to: toIndex, in: workspaceId)
    }

    func select(id: UUID) {
        guard workspaces.contains(where: { $0.id == id }) else { return }
        selectedId = id
    }

    // MARK: - Tab CRUD

    @discardableResult
    func addTab(to workspaceId: UUID) -> (tabId: UUID, terminalId: UUID)? {
        guard let wsIdx = wsIndex(workspaceId) else { return nil }
        let index = workspaces[wsIdx].tabs.count + 1
        let tab = makeNewTab(index: index)
        workspaces[wsIdx].tabs.append(tab)
        workspaces[wsIdx].selectedTabId = tab.id
        save()
        // Safe: makeNewTab initializes `layout = .terminal(_)`, so allTerminalIds()
        // always returns a 1-element array.
        return (tabId: tab.id, terminalId: tab.layout.allTerminalIds()[0])
    }

    func removeTab(id: UUID, from workspaceId: UUID) {
        guard let wsIdx = wsIndex(workspaceId) else { return }
        // Find the index before removal so we can select the adjacent tab
        let closedIdx = workspaces[wsIdx].tabs.firstIndex(where: { $0.id == id })
        if let tIdx = closedIdx {
            for tid in workspaces[wsIdx].tabs[tIdx].layout.allTerminalIds() {
                workspaces[wsIdx].pendingPrefills.removeValue(forKey: tid.uuidString)
            }
        }
        workspaces[wsIdx].tabs.removeAll { $0.id == id }
        if workspaces[wsIdx].tabs.isEmpty {
            let replacement = makeNewTab(index: 1)
            workspaces[wsIdx].tabs.append(replacement)
            workspaces[wsIdx].selectedTabId = replacement.id
        } else if workspaces[wsIdx].selectedTabId == id {
            // Select the tab to the left of the closed one, or the first tab if none
            let newIdx = max(0, (closedIdx ?? 1) - 1)
            workspaces[wsIdx].selectedTabId = workspaces[wsIdx].tabs[newIdx].id
        }
        save()
    }

    func selectTab(id: UUID, in workspaceId: UUID) {
        guard let wsIdx = wsIndex(workspaceId),
              workspaces[wsIdx].tabs.contains(where: { $0.id == id }) else { return }
        workspaces[wsIdx].selectedTabId = id
        save()
    }

    func renameTab(id: UUID, in workspaceId: UUID, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let wsIdx = wsIndex(workspaceId),
              let tIdx = tabIndex(id, in: wsIdx),
              workspaces[wsIdx].tabs[tIdx].title != trimmed else { return }
        workspaces[wsIdx].tabs[tIdx].title = trimmed
        save()
    }

    // MARK: - Split operations

    @discardableResult
    func splitTerminal(id terminalId: UUID, in workspaceId: UUID, tabId: UUID,
                       direction: SplitDirection) -> UUID? {
        guard let wsIdx = wsIndex(workspaceId),
              let tIdx = tabIndex(tabId, in: wsIdx) else { return nil }
        let newTermId = UUID()
        let splitNode = SplitNode.split(UUID(), direction, 0.5,
                                        .terminal(terminalId), .terminal(newTermId))
        workspaces[wsIdx].tabs[tIdx].layout =
            workspaces[wsIdx].tabs[tIdx].layout.replacing(terminalId: terminalId, with: splitNode)
        workspaces[wsIdx].tabs[tIdx].focusedTerminalId = newTermId
        save()
        return newTermId
    }

    func closeTerminal(id terminalId: UUID, in workspaceId: UUID, tabId: UUID) {
        guard let wsIdx = wsIndex(workspaceId),
              let tIdx = tabIndex(tabId, in: wsIdx) else { return }
        let tab = workspaces[wsIdx].tabs[tIdx]
        if let newLayout = tab.layout.removing(terminalId: terminalId) {
            workspaces[wsIdx].tabs[tIdx].layout = newLayout
            workspaces[wsIdx].pendingPrefills.removeValue(forKey: terminalId.uuidString)
            if tab.focusedTerminalId == terminalId {
                // Safe: newLayout is non-nil so it contains at least one terminal
                workspaces[wsIdx].tabs[tIdx].focusedTerminalId =
                    newLayout.allTerminalIds()[0]
            }
            save()
        } else {
            // Last terminal in tab → close the tab
            removeTab(id: tabId, from: workspaceId)
        }
    }

    func updateSplitRatio(splitId: UUID, to ratio: CGFloat,
                          tabId: UUID, in workspaceId: UUID) {
        guard let wsIdx = wsIndex(workspaceId),
              let tIdx = tabIndex(tabId, in: wsIdx) else { return }
        // Clamp to prevent zero-size panes from drag noise
        let clamped = max(0.05, min(0.95, ratio))
        workspaces[wsIdx].tabs[tIdx].layout =
            workspaces[wsIdx].tabs[tIdx].layout.updatingRatio(splitId: splitId, to: clamped)
        // Debounce: divider drags fire this hundreds of times per second; only persist at end.
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.save() }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    func updateFocusedTerminal(id terminalId: UUID, tabId: UUID, in workspaceId: UUID) {
        guard let wsIdx = wsIndex(workspaceId),
              let tIdx = tabIndex(tabId, in: wsIdx) else { return }
        workspaces[wsIdx].tabs[tIdx].focusedTerminalId = terminalId
        save()
    }

    func updateTabLayout(_ layout: SplitNode, tabId: UUID, in workspaceId: UUID) {
        guard let wsIdx = wsIndex(workspaceId),
              let tIdx = tabIndex(tabId, in: wsIdx) else { return }
        workspaces[wsIdx].tabs[tIdx].layout = layout
        save()
    }

    // MARK: - Agent resume / prefill

    private func wsIndexContaining(terminalId: UUID) -> Int? {
        workspaces.firstIndex { ws in
            ws.tabs.contains { $0.layout.allTerminalIds().contains(terminalId) }
        }
    }

    /// Persist the latest agent resume command for `terminalId`. Synchronous
    /// save — the value must survive force-quit / crash with no termination
    /// hook. No-op when unchanged.
    func recordResumeCommand(terminalId: UUID, command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let wsIdx = wsIndexContaining(terminalId: terminalId) else { return }
        let key = terminalId.uuidString
        guard workspaces[wsIdx].pendingPrefills[key] != trimmed else { return }
        workspaces[wsIdx].pendingPrefills[key] = trimmed
        save()
    }

    /// Non-destructive read: a relaunch that lands back inside the agent and
    /// quits without typing a new prompt should still resume the same session
    /// next time. Only the next `recordResumeCommand` overwrites.
    func consumePendingPrefill(terminalId: UUID) -> String? {
        guard let wsIdx = wsIndexContaining(terminalId: terminalId) else { return nil }
        return workspaces[wsIdx].pendingPrefills[terminalId.uuidString]
    }

    /// Drop every stored resume command for the given agent. Called when the
    /// user turns the Resume toggle off, so the change takes effect on next
    /// launch instead of waiting for the stale entry to be overwritten.
    func clearResumePrefills(forAgent agent: HookMessage.Agent) {
        guard agent.supportsResume else { return }
        var changed = false
        for i in workspaces.indices {
            let kept = workspaces[i].pendingPrefills.filter {
                HookMessage.Agent.fromResumeCommand($0.value) != agent
            }
            if kept.count != workspaces[i].pendingPrefills.count {
                workspaces[i].pendingPrefills = kept
                changed = true
            }
        }
        if changed { save() }
    }

    // MARK: - Helpers

    private func makeNewTab(index: Int) -> TerminalTab {
        TerminalTab(title: "terminal \(index)")
    }

    private func wsIndex(_ id: UUID) -> Int? {
        workspaces.firstIndex(where: { $0.id == id })
    }

    private func tabIndex(_ id: UUID, in wsIdx: Int) -> Int? {
        workspaces[wsIdx].tabs.firstIndex(where: { $0.id == id })
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(workspaces) else { return }
        UserDefaults.standard.set(data, forKey: persistenceKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey),
              let decoded = try? JSONDecoder().decode([Workspace].self, from: data)
        else { return }
        workspaces = decoded
        selectedId = workspaces.first?.id
    }
}
