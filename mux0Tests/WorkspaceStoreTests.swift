import XCTest
@testable import mux0

final class WorkspaceStoreTests: XCTestCase {

    // MARK: - Workspace CRUD

    func testCreateWorkspace() {
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        store.createWorkspace(name: "my-project")
        XCTAssertEqual(store.workspaces.count, 1)
        XCTAssertEqual(store.workspaces[0].name, "my-project")
        // Creating a workspace auto-adds one tab
        XCTAssertEqual(store.workspaces[0].tabs.count, 1)
        XCTAssertNotNil(store.workspaces[0].selectedTabId)
    }

    func testSelectWorkspace() {
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        store.createWorkspace(name: "alpha")
        store.createWorkspace(name: "beta")
        let betaId = store.workspaces[1].id
        store.select(id: betaId)
        XCTAssertEqual(store.selectedId, betaId)
    }

    func testDeleteWorkspace() {
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        store.createWorkspace(name: "to-delete")
        let id = store.workspaces[0].id
        store.deleteWorkspace(id: id)
        XCTAssertTrue(store.workspaces.isEmpty)
    }

    // MARK: - Rename workspace

    func testRenameWorkspace() {
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        store.createWorkspace(name: "old")
        let id = store.workspaces[0].id
        store.renameWorkspace(id: id, to: "new")
        XCTAssertEqual(store.workspaces[0].name, "new")
    }

    func testRenameWorkspace_emptyStringIgnored() {
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        store.createWorkspace(name: "keep")
        let id = store.workspaces[0].id
        store.renameWorkspace(id: id, to: "")
        XCTAssertEqual(store.workspaces[0].name, "keep")
    }

    func testRenameWorkspace_whitespaceIgnored() {
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        store.createWorkspace(name: "keep")
        let id = store.workspaces[0].id
        store.renameWorkspace(id: id, to: "   ")
        XCTAssertEqual(store.workspaces[0].name, "keep")
    }

    func testRenameWorkspace_trimsWhitespace() {
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        store.createWorkspace(name: "old")
        let id = store.workspaces[0].id
        store.renameWorkspace(id: id, to: "  trimmed  ")
        XCTAssertEqual(store.workspaces[0].name, "trimmed")
    }

    func testRenameWorkspace_unknownIdIsNoop() {
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        store.createWorkspace(name: "keep")
        store.renameWorkspace(id: UUID(), to: "nope")
        XCTAssertEqual(store.workspaces[0].name, "keep")
    }

    func testRenameWorkspace_sameNameIsNoop() {
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        store.createWorkspace(name: "same")
        let id = store.workspaces[0].id
        store.renameWorkspace(id: id, to: "same")
        XCTAssertEqual(store.workspaces[0].name, "same")
    }

    // MARK: - Move workspace

    func testMoveWorkspace_forward() {
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        store.createWorkspace(name: "a")
        store.createWorkspace(name: "b")
        store.createWorkspace(name: "c")
        // a, b, c → move index 0 (a) to destination 2 → b, a, c
        store.moveWorkspace(from: IndexSet([0]), to: 2)
        XCTAssertEqual(store.workspaces.map(\.name), ["b", "a", "c"])
    }

    func testMoveWorkspace_backward() {
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        store.createWorkspace(name: "a")
        store.createWorkspace(name: "b")
        store.createWorkspace(name: "c")
        // a, b, c → move index 2 (c) to destination 0 → c, a, b
        store.moveWorkspace(from: IndexSet([2]), to: 0)
        XCTAssertEqual(store.workspaces.map(\.name), ["c", "a", "b"])
    }

    func testMoveWorkspace_toSameSpotIsNoop() {
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        store.createWorkspace(name: "a")
        store.createWorkspace(name: "b")
        let idsBefore = store.workspaces.map(\.id)
        store.moveWorkspace(from: IndexSet([0]), to: 0)
        store.moveWorkspace(from: IndexSet([0]), to: 1)  // same position for single-element move
        XCTAssertEqual(store.workspaces.map(\.id), idsBefore)
    }

    func testMoveWorkspace_preservesSelectedId() {
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        store.createWorkspace(name: "a")
        store.createWorkspace(name: "b")
        store.createWorkspace(name: "c")
        let bId = store.workspaces[1].id
        store.select(id: bId)
        store.moveWorkspace(from: IndexSet([0]), to: 3)  // a → end
        XCTAssertEqual(store.selectedId, bId)
        XCTAssertEqual(store.workspaces.map(\.name), ["b", "c", "a"])
    }

    // MARK: - Tab CRUD

    func testAddTab() {
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        store.createWorkspace(name: "ws")
        let wsId = store.workspaces[0].id
        // createWorkspace auto-adds tab 1; add tab 2
        let tabId = store.addTab(to: wsId)?.tabId
        XCTAssertNotNil(tabId)
        XCTAssertEqual(store.workspaces[0].tabs.count, 2)
        XCTAssertEqual(store.workspaces[0].selectedTabId, tabId)
    }

    func testRemoveTab_keepsAtLeastOne() {
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        store.createWorkspace(name: "ws")
        let wsId = store.workspaces[0].id
        let onlyTabId = store.workspaces[0].tabs[0].id
        store.removeTab(id: onlyTabId, from: wsId)
        // Must still have one tab
        XCTAssertEqual(store.workspaces[0].tabs.count, 1)
    }

    func testSelectTab() {
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        store.createWorkspace(name: "ws")
        let wsId = store.workspaces[0].id
        let tab2Id = store.addTab(to: wsId)!.tabId
        let tab1Id = store.workspaces[0].tabs[0].id
        store.selectTab(id: tab1Id, in: wsId)
        XCTAssertEqual(store.workspaces[0].selectedTabId, tab1Id)
        store.selectTab(id: tab2Id, in: wsId)
        XCTAssertEqual(store.workspaces[0].selectedTabId, tab2Id)
    }

    // MARK: - Rename tab

    func testRenameTab() {
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        store.createWorkspace(name: "ws")
        let wsId = store.workspaces[0].id
        let tabId = store.workspaces[0].tabs[0].id
        store.renameTab(id: tabId, in: wsId, to: "custom")
        XCTAssertEqual(store.workspaces[0].tabs[0].title, "custom")
    }

    func testRenameTab_emptyIgnored() {
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        store.createWorkspace(name: "ws")
        let wsId = store.workspaces[0].id
        let tabId = store.workspaces[0].tabs[0].id
        let original = store.workspaces[0].tabs[0].title
        store.renameTab(id: tabId, in: wsId, to: "")
        store.renameTab(id: tabId, in: wsId, to: "   ")
        XCTAssertEqual(store.workspaces[0].tabs[0].title, original)
    }

    func testRenameTab_unknownIdsAreNoop() {
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        store.createWorkspace(name: "ws")
        let wsId = store.workspaces[0].id
        let original = store.workspaces[0].tabs[0].title
        store.renameTab(id: UUID(), in: wsId, to: "x")              // unknown tab
        store.renameTab(id: store.workspaces[0].tabs[0].id,
                        in: UUID(), to: "y")                         // unknown ws
        XCTAssertEqual(store.workspaces[0].tabs[0].title, original)
    }

    func testRenameTab_sameNameIsNoop() {
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        store.createWorkspace(name: "ws")
        let wsId = store.workspaces[0].id
        let tabId = store.workspaces[0].tabs[0].id
        let original = store.workspaces[0].tabs[0].title
        store.renameTab(id: tabId, in: wsId, to: original)
        XCTAssertEqual(store.workspaces[0].tabs[0].title, original)
    }

    // MARK: - Move tab

    func testMoveTab_basic() {
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        store.createWorkspace(name: "ws")
        let wsId = store.workspaces[0].id
        _ = store.addTab(to: wsId)
        _ = store.addTab(to: wsId)
        // titles are "terminal 1", "terminal 2", "terminal 3"
        store.moveTab(from: IndexSet([0]), to: 3, in: wsId)
        XCTAssertEqual(store.workspaces[0].tabs.map(\.title),
                       ["terminal 2", "terminal 3", "terminal 1"])
    }

    func testMoveTab_preservesSelectedTabId() {
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        store.createWorkspace(name: "ws")
        let wsId = store.workspaces[0].id
        _ = store.addTab(to: wsId)
        _ = store.addTab(to: wsId)
        let firstId = store.workspaces[0].tabs[0].id
        store.selectTab(id: firstId, in: wsId)
        store.moveTab(from: IndexSet([0]), to: 3, in: wsId)  // first → end
        XCTAssertEqual(store.workspaces[0].selectedTabId, firstId)
        XCTAssertEqual(store.workspaces[0].tabs.last?.id, firstId)
    }

    func testMoveTab_unknownWorkspaceIsNoop() {
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        store.createWorkspace(name: "ws")
        let wsId = store.workspaces[0].id
        _ = store.addTab(to: wsId)
        let titlesBefore = store.workspaces[0].tabs.map(\.title)
        store.moveTab(from: IndexSet([0]), to: 2, in: UUID())
        XCTAssertEqual(store.workspaces[0].tabs.map(\.title), titlesBefore)
    }

    func testMoveTab_fromIndexToIndexOverload() {
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        store.createWorkspace(name: "ws")
        let wsId = store.workspaces[0].id
        _ = store.addTab(to: wsId)
        _ = store.addTab(to: wsId)
        store.moveTab(fromIndex: 2, toIndex: 0, in: wsId)  // "terminal 3" → front
        XCTAssertEqual(store.workspaces[0].tabs.map(\.title),
                       ["terminal 3", "terminal 1", "terminal 2"])
    }

    func testMoveTab_toSameSpotIsNoop() {
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        store.createWorkspace(name: "ws")
        let wsId = store.workspaces[0].id
        _ = store.addTab(to: wsId)
        let idsBefore = store.workspaces[0].tabs.map(\.id)
        store.moveTab(from: IndexSet([0]), to: 0, in: wsId)
        store.moveTab(from: IndexSet([0]), to: 1, in: wsId)  // single-element: same position
        XCTAssertEqual(store.workspaces[0].tabs.map(\.id), idsBefore)
    }

    func testMoveTab_persistenceRoundTrip() throws {
        let key = "test-movetab-\(UUID())"
        let store1 = WorkspaceStore(persistenceKey: key)
        store1.createWorkspace(name: "ws")
        let wsId = store1.workspaces[0].id
        _ = store1.addTab(to: wsId)
        _ = store1.addTab(to: wsId)
        store1.moveTab(from: IndexSet([0]), to: 3, in: wsId)
        let expectedTitles = store1.workspaces[0].tabs.map(\.title)

        let store2 = WorkspaceStore(persistenceKey: key)
        XCTAssertEqual(store2.workspaces[0].tabs.map(\.title), expectedTitles)

        UserDefaults.standard.removeObject(forKey: key)
    }

    func testMoveWorkspace_persistenceRoundTrip() throws {
        let key = "test-movews-\(UUID())"
        let store1 = WorkspaceStore(persistenceKey: key)
        store1.createWorkspace(name: "a")
        store1.createWorkspace(name: "b")
        store1.createWorkspace(name: "c")
        store1.moveWorkspace(from: IndexSet([0]), to: 3)
        let expected = store1.workspaces.map(\.name)

        let store2 = WorkspaceStore(persistenceKey: key)
        XCTAssertEqual(store2.workspaces.map(\.name), expected)

        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: - SplitNode tree helpers

    func testSplitNodeAllTerminalIds_leaf() {
        let id = UUID()
        let node = SplitNode.terminal(id)
        XCTAssertEqual(node.allTerminalIds(), [id])
    }

    func testSplitNodeAllTerminalIds_split() {
        let a = UUID(), b = UUID()
        let node = SplitNode.split(UUID(), .vertical, 0.5, .terminal(a), .terminal(b))
        XCTAssertEqual(Set(node.allTerminalIds()), Set([a, b]))
    }

    func testSplitNodeRemoving_leaf_selfIsTarget() {
        let id = UUID()
        let node = SplitNode.terminal(id)
        XCTAssertNil(node.removing(terminalId: id))
    }

    func testSplitNodeRemoving_promotesFirstSibling() {
        let a = UUID(), b = UUID()
        let node = SplitNode.split(UUID(), .vertical, 0.5, .terminal(a), .terminal(b))
        // Remove b → expect .terminal(a)
        let result = node.removing(terminalId: b)
        XCTAssertEqual(result, .terminal(a))
    }

    func testSplitNodeRemoving_promotesSecondSibling() {
        let a = UUID(), b = UUID()
        let node = SplitNode.split(UUID(), .vertical, 0.5, .terminal(a), .terminal(b))
        // Remove a → expect .terminal(b)
        let result = node.removing(terminalId: a)
        XCTAssertEqual(result, .terminal(b))
    }

    func testSplitNodeRemoving_nested() {
        let a = UUID(), b = UUID(), c = UUID()
        let inner = SplitNode.split(UUID(), .horizontal, 0.5, .terminal(b), .terminal(c))
        let node = SplitNode.split(UUID(), .vertical, 0.5, .terminal(a), inner)
        // Remove c → inner becomes .terminal(b); outer stays .split
        guard case .split(_, _, _, let newFirst, let newSecond) = node.removing(terminalId: c) else {
            XCTFail("Expected split"); return
        }
        XCTAssertEqual(newFirst, .terminal(a))
        XCTAssertEqual(newSecond, .terminal(b))
    }

    func testSplitNodeUpdatingRatio() {
        let splitId = UUID()
        let a = UUID(), b = UUID()
        let node = SplitNode.split(splitId, .vertical, 0.5, .terminal(a), .terminal(b))
        let updated = node.updatingRatio(splitId: splitId, to: 0.3)
        guard case .split(_, _, let ratio, _, _) = updated else { XCTFail(); return }
        XCTAssertEqual(ratio, 0.3, accuracy: 0.001)
    }

    func testSplitNodeCodableRoundTrip() throws {
        let a = UUID(), b = UUID(), splitId = UUID()
        let node = SplitNode.split(splitId, .horizontal, 0.4, .terminal(a), .terminal(b))
        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(SplitNode.self, from: data)
        XCTAssertEqual(node, decoded)
    }

    // MARK: - Store split operations

    func testSplitTerminal() {
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        store.createWorkspace(name: "ws")
        let wsId = store.workspaces[0].id
        let tab = store.workspaces[0].tabs[0]
        let tabId = tab.id
        guard case .terminal(let origId) = tab.layout else { XCTFail(); return }

        let newId = store.splitTerminal(id: origId, in: wsId, tabId: tabId, direction: .vertical)
        XCTAssertNotNil(newId)

        let updatedTab = store.workspaces[0].tabs[0]
        let allIds = updatedTab.layout.allTerminalIds()
        XCTAssertEqual(allIds.count, 2)
        XCTAssertTrue(allIds.contains(origId))
        XCTAssertTrue(allIds.contains(newId!))
        XCTAssertEqual(updatedTab.focusedTerminalId, newId)
    }

    func testCloseTerminal_lastTerminalClosesTab() {
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        store.createWorkspace(name: "ws")
        let wsId = store.workspaces[0].id
        let tab = store.workspaces[0].tabs[0]
        guard case .terminal(let termId) = tab.layout else { XCTFail(); return }

        store.closeTerminal(id: termId, in: wsId, tabId: tab.id)
        // Tab closed, a new default tab was created
        XCTAssertEqual(store.workspaces[0].tabs.count, 1)
        XCTAssertNotEqual(store.workspaces[0].tabs[0].id, tab.id)
    }

    func testCloseTerminal_removesPane() {
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        store.createWorkspace(name: "ws")
        let wsId = store.workspaces[0].id
        let tabId = store.workspaces[0].tabs[0].id
        guard case .terminal(let origId) = store.workspaces[0].tabs[0].layout else { XCTFail(); return }

        let newId = store.splitTerminal(id: origId, in: wsId, tabId: tabId, direction: .vertical)!
        store.closeTerminal(id: newId, in: wsId, tabId: tabId)

        let updatedTab = store.workspaces[0].tabs[0]
        XCTAssertEqual(updatedTab.layout.allTerminalIds(), [origId])
    }

    func testPersistenceRoundTrip() throws {
        let key = "test-persist-\(UUID())"
        let store1 = WorkspaceStore(persistenceKey: key)
        store1.createWorkspace(name: "persistent")
        let wsId = store1.workspaces[0].id
        let tabId = store1.workspaces[0].tabs[0].id
        guard case .terminal(let termId) = store1.workspaces[0].tabs[0].layout else { XCTFail(); return }
        _ = store1.splitTerminal(id: termId, in: wsId, tabId: tabId, direction: .horizontal)

        let store2 = WorkspaceStore(persistenceKey: key)
        XCTAssertEqual(store2.workspaces.count, 1)
        XCTAssertEqual(store2.workspaces[0].name, "persistent")
        XCTAssertEqual(store2.workspaces[0].tabs[0].layout.allTerminalIds().count, 2)

        UserDefaults.standard.removeObject(forKey: key)
    }

    func testAddTabReturnsTerminalId() {
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        store.createWorkspace(name: "ws")
        let wsId = store.workspaces[0].id
        guard let result = store.addTab(to: wsId) else {
            XCTFail("addTab returned nil"); return
        }
        let tab = store.workspaces[0].tabs.first(where: { $0.id == result.tabId })
        XCTAssertNotNil(tab)
        // Structural check: new tab's layout is a single terminal leaf whose UUID
        // matches the returned terminalId. The case match also guards against a
        // future regression that makes new tabs start as a split.
        if case .terminal(let id) = tab?.layout {
            XCTAssertEqual(id, result.terminalId)
        } else {
            XCTFail("new tab layout must be a single terminal leaf")
        }
    }

    func testCreateWorkspaceReturnsFirstTerminalId() {
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        let termId = store.createWorkspace(name: "ws")
        guard let tab = store.workspaces.last?.tabs.first else {
            XCTFail("new workspace should have at least one tab"); return
        }
        if case .terminal(let id) = tab.layout {
            XCTAssertEqual(id, termId)
        } else {
            XCTFail("new workspace's first tab must be a single terminal leaf")
        }
    }

    // MARK: - Agent resume / prefill

    /// Helper: return the (single) terminalId of the (single) tab in the
    /// (single) workspace of a freshly-built store.
    private func firstTerminalId(_ store: WorkspaceStore) -> UUID {
        store.workspaces[0].tabs[0].layout.allTerminalIds()[0]
    }

    func testRecordResumeCommandWritesIntoPendingPrefills() {
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        store.createWorkspace(name: "p")
        let term = firstTerminalId(store)

        store.recordResumeCommand(terminalId: term, command: "claude --resume abc")

        XCTAssertEqual(store.workspaces[0].pendingPrefills[term.uuidString],
                       "claude --resume abc")
    }

    func testRecordResumeCommandTrimsWhitespace() {
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        store.createWorkspace(name: "p")
        let term = firstTerminalId(store)

        store.recordResumeCommand(terminalId: term, command: "  codex resume xyz  \n")

        XCTAssertEqual(store.workspaces[0].pendingPrefills[term.uuidString],
                       "codex resume xyz")
    }

    func testRecordResumeCommandUnknownTerminalNoOp() {
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        store.createWorkspace(name: "p")

        store.recordResumeCommand(terminalId: UUID(), command: "claude --resume nope")

        XCTAssertTrue(store.workspaces[0].pendingPrefills.isEmpty)
    }

    func testRecordResumeCommandEmptyValueIgnored() {
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        store.createWorkspace(name: "p")
        let term = firstTerminalId(store)

        store.recordResumeCommand(terminalId: term, command: "   ")

        XCTAssertTrue(store.workspaces[0].pendingPrefills.isEmpty)
    }

    func testRecordResumeCommandLatestValueWins() {
        // A second prompt within the same session (e.g. after /clear or
        // /resume) emits a new resumeCommand — pendingPrefills must reflect
        // the newest value, since that's the session id the user is
        // actively working in and would want to resume on next launch.
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        store.createWorkspace(name: "p")
        let term = firstTerminalId(store)

        store.recordResumeCommand(terminalId: term, command: "claude --resume old")
        store.recordResumeCommand(terminalId: term, command: "claude --resume new")

        XCTAssertEqual(store.workspaces[0].pendingPrefills[term.uuidString],
                       "claude --resume new")
    }

    func testConsumePendingPrefillReadsButDoesNotClear() {
        // pendingPrefills must survive a "relaunch + no new prompt"
        // scenario, so consume reads non-destructively. Only the next
        // recordResumeCommand call overwrites it.
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        store.createWorkspace(name: "p")
        let term = firstTerminalId(store)
        store.recordResumeCommand(terminalId: term, command: "claude --resume abc")

        let first = store.consumePendingPrefill(terminalId: term)
        let second = store.consumePendingPrefill(terminalId: term)

        XCTAssertEqual(first, "claude --resume abc")
        XCTAssertEqual(second, "claude --resume abc")
        XCTAssertEqual(store.workspaces[0].pendingPrefills[term.uuidString],
                       "claude --resume abc")
    }

    func testConsumePendingPrefillUnknownTerminalReturnsNil() {
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        store.createWorkspace(name: "p")
        XCTAssertNil(store.consumePendingPrefill(terminalId: UUID()))
    }

    func testWorkspaceCodableRoundTripPreservesPendingPrefill() throws {
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        store.createWorkspace(name: "p")
        let term = firstTerminalId(store)
        store.recordResumeCommand(terminalId: term, command: "claude --resume rt")

        let data = try JSONEncoder().encode(store.workspaces)
        let decoded = try JSONDecoder().decode([Workspace].self, from: data)

        XCTAssertEqual(decoded[0].pendingPrefills[term.uuidString], "claude --resume rt")
    }

    func testCloseTerminalDropsItsPendingPrefill() {
        // Splitting yields a 2-leaf tab; after recording resume on each leaf
        // and closing one, only the survivor's entry must remain — otherwise
        // pendingPrefills accumulates orphan terminalId keys forever.
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        store.createWorkspace(name: "p")
        let wsId = store.workspaces[0].id
        let tabId = store.workspaces[0].tabs[0].id
        let term1 = firstTerminalId(store)
        guard let term2 = store.splitTerminal(id: term1, in: wsId, tabId: tabId,
                                              direction: .vertical) else {
            return XCTFail("split failed")
        }
        store.recordResumeCommand(terminalId: term1, command: "claude --resume one")
        store.recordResumeCommand(terminalId: term2, command: "claude --resume two")

        store.closeTerminal(id: term1, in: wsId, tabId: tabId)

        XCTAssertNil(store.workspaces[0].pendingPrefills[term1.uuidString])
        XCTAssertEqual(store.workspaces[0].pendingPrefills[term2.uuidString],
                       "claude --resume two")
    }

    func testClearResumePrefillsForClaudeKeepsCodexEntries() {
        // Clearing one agent's stored resume commands must not touch the
        // other's — users may turn off claude's auto-resume while still
        // wanting codex's to fire.
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        store.createWorkspace(name: "p")
        let wsId = store.workspaces[0].id
        let tabId = store.workspaces[0].tabs[0].id
        let term1 = firstTerminalId(store)
        guard let term2 = store.splitTerminal(id: term1, in: wsId, tabId: tabId,
                                              direction: .vertical) else {
            return XCTFail("split failed")
        }
        store.recordResumeCommand(terminalId: term1, command: "claude --resume one")
        store.recordResumeCommand(terminalId: term2, command: "codex resume two")

        store.clearResumePrefills(forAgent: .claude)

        XCTAssertNil(store.workspaces[0].pendingPrefills[term1.uuidString])
        XCTAssertEqual(store.workspaces[0].pendingPrefills[term2.uuidString],
                       "codex resume two")
    }

    func testClearResumePrefillsForOpencodeKeepsClaude() {
        // OpenCode has its own resume CLI (`opencode --session <id>`). The
        // clear-by-agent helper must drop ONLY opencode entries, leaving
        // claude/codex stored values alone.
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        store.createWorkspace(name: "p")
        let wsId = store.workspaces[0].id
        let tabId = store.workspaces[0].tabs[0].id
        let term1 = firstTerminalId(store)
        guard let term2 = store.splitTerminal(id: term1, in: wsId, tabId: tabId,
                                              direction: .vertical) else {
            return XCTFail("split failed")
        }
        store.recordResumeCommand(terminalId: term1, command: "claude --resume keep")
        store.recordResumeCommand(terminalId: term2, command: "opencode --session drop")

        store.clearResumePrefills(forAgent: .opencode)

        XCTAssertEqual(store.workspaces[0].pendingPrefills[term1.uuidString],
                       "claude --resume keep")
        XCTAssertNil(store.workspaces[0].pendingPrefills[term2.uuidString])
    }

    func testRemoveTabDropsAllItsTerminalsPendingPrefills() {
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        store.createWorkspace(name: "p")
        let wsId = store.workspaces[0].id
        let tab1Id = store.workspaces[0].tabs[0].id
        let term1 = firstTerminalId(store)
        guard let term2 = store.splitTerminal(id: term1, in: wsId, tabId: tab1Id,
                                              direction: .vertical) else {
            return XCTFail("split failed")
        }
        guard let extra = store.addTab(to: wsId) else { return XCTFail("addTab failed") }
        store.recordResumeCommand(terminalId: term1, command: "claude --resume one")
        store.recordResumeCommand(terminalId: term2, command: "claude --resume two")
        store.recordResumeCommand(terminalId: extra.terminalId, command: "claude --resume three")

        store.removeTab(id: tab1Id, from: wsId)

        XCTAssertNil(store.workspaces[0].pendingPrefills[term1.uuidString])
        XCTAssertNil(store.workspaces[0].pendingPrefills[term2.uuidString])
        XCTAssertEqual(store.workspaces[0].pendingPrefills[extra.terminalId.uuidString],
                       "claude --resume three")
    }

    // MARK: - TabKind & ensureGitTab

    func testTerminalTabKind_codableRoundTrip_gitValue() throws {
        var tab = TerminalTab(title: "Git")
        tab.kind = .git

        let data = try JSONEncoder().encode(tab)
        let decoded = try JSONDecoder().decode(TerminalTab.self, from: data)

        XCTAssertEqual(decoded.kind, .git)
        XCTAssertEqual(decoded.title, "Git")
    }

    func testTerminalTabKind_codableRoundTrip_nilValue() throws {
        let tab = TerminalTab(title: "terminal 1")
        XCTAssertNil(tab.kind)

        let data = try JSONEncoder().encode(tab)
        let decoded = try JSONDecoder().decode(TerminalTab.self, from: data)

        XCTAssertNil(decoded.kind)
    }

    func testTerminalTabKind_decodingLegacyJSONWithoutKindField() throws {
        // Old persistence (pre-TabKind) had no `kind` key. Decoding must succeed
        // and land on nil, otherwise existing UserDefaults blobs break on upgrade.
        let termId = UUID()
        let tabId = UUID()
        let json = """
        {
            "id": "\(tabId.uuidString)",
            "title": "old tab",
            "layout": { "type": "terminal", "terminalId": "\(termId.uuidString)" },
            "focusedTerminalId": "\(termId.uuidString)"
        }
        """
        let data = json.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(TerminalTab.self, from: data)

        XCTAssertNil(decoded.kind)
        XCTAssertEqual(decoded.title, "old tab")
        XCTAssertEqual(decoded.id, tabId)
    }
}
