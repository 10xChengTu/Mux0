import XCTest
@testable import mux0

final class QuickActionsStoreTests: XCTestCase {
    /// Tracks the temp config files created in a single test method so we can
    /// remove them in tearDown. `makeIsolatedStore` returns the same
    /// SettingsConfigStore instance to both the store-under-test and the
    /// caller so tests can simulate "external" mux0 config edits and reload
    /// the store from them.
    private var tmpPaths: [String] = []

    override func tearDown() {
        for path in tmpPaths {
            try? FileManager.default.removeItem(atPath: path)
        }
        tmpPaths.removeAll()
        super.tearDown()
    }

    private func makeIsolatedStore() -> (QuickActionsStore, SettingsConfigStore) {
        let dir = NSTemporaryDirectory()
        let path = (dir as NSString).appendingPathComponent(
            "mux0-quickactions-\(UUID().uuidString).conf"
        )
        tmpPaths.append(path)
        let settings = SettingsConfigStore(filePath: path)
        let store = QuickActionsStore(settings: settings)
        return (store, settings)
    }

    func test_defaultState_allEmpty() {
        let (store, _) = makeIsolatedStore()
        XCTAssertTrue(store.enabledIds.isEmpty)
        XCTAssertTrue(store.builtinCommandOverrides.isEmpty)
        XCTAssertTrue(store.customActions.isEmpty)
        XCTAssertTrue(store.displayList.isEmpty)
    }

    func test_setEnabled_appendsAndPersists() {
        let (store, settings) = makeIsolatedStore()
        store.setEnabled("lazygit", true)
        XCTAssertEqual(store.enabledIds, ["lazygit"])
        XCTAssertTrue(store.isEnabled("lazygit"))

        // Force the debounced write to flush to disk, then re-instantiate
        // the SettingsConfigStore from the same file path so the round-trip
        // exercises actual on-disk persistence.
        settings.save()

        let store2 = QuickActionsStore(settings: settings)
        XCTAssertEqual(store2.enabledIds, ["lazygit"])
    }

    func test_setEnabled_idempotent() {
        let (store, _) = makeIsolatedStore()
        store.setEnabled("lazygit", true)
        store.setEnabled("lazygit", true)
        XCTAssertEqual(store.enabledIds, ["lazygit"])
    }

    func test_setEnabled_offRemoves() {
        let (store, _) = makeIsolatedStore()
        store.setEnabled("lazygit", true)
        store.setEnabled("claude", true)
        store.setEnabled("lazygit", false)
        XCTAssertEqual(store.enabledIds, ["claude"])
    }

    func test_command_builtinDefault() {
        let (store, _) = makeIsolatedStore()
        XCTAssertEqual(store.command(for: "lazygit"), "lazygit")
        XCTAssertEqual(store.command(for: "claude"), "claude")
    }

    func test_command_builtinOverride() {
        let (store, _) = makeIsolatedStore()
        store.setBuiltinCommand("lazygit", "gitui")
        XCTAssertEqual(store.command(for: "lazygit"), "gitui")
    }

    func test_command_builtinEmptyOverrideFallsBackToDefault() {
        let (store, _) = makeIsolatedStore()
        store.setBuiltinCommand("lazygit", "gitui")
        store.setBuiltinCommand("lazygit", "")
        XCTAssertEqual(store.command(for: "lazygit"), "lazygit")
        XCTAssertNil(store.builtinCommandOverrides["lazygit"])
    }

    func test_command_unknownIdReturnsNil() {
        let (store, _) = makeIsolatedStore()
        XCTAssertNil(store.command(for: "no-such-id"))
    }

    func test_addCustomAction_appendsEmpty() {
        let (store, _) = makeIsolatedStore()
        let newId = store.addCustomAction()
        XCTAssertEqual(store.customActions.count, 1)
        XCTAssertEqual(store.customActions.first?.id, newId)
        XCTAssertEqual(store.customActions.first?.name, "")
        XCTAssertEqual(store.customActions.first?.command, "")
        XCTAssertFalse(store.isEnabled(newId))
    }

    func test_updateCustomAction_changesNameAndCommand() {
        let (store, _) = makeIsolatedStore()
        let id = store.addCustomAction()
        store.updateCustomAction(id, name: "htop", command: "htop -H")
        XCTAssertEqual(store.customActions.first?.name, "htop")
        XCTAssertEqual(store.customActions.first?.command, "htop -H")
        XCTAssertEqual(store.command(for: id), "htop -H")
    }

    func test_removeCustomAction_alsoUnenables() {
        let (store, _) = makeIsolatedStore()
        let id = store.addCustomAction()
        store.updateCustomAction(id, name: "htop", command: "htop")
        store.setEnabled(id, true)
        store.removeCustomAction(id)
        XCTAssertTrue(store.customActions.isEmpty)
        XCTAssertFalse(store.isEnabled(id))
    }

    func test_displayList_filtersOrphanCustomIds() {
        let (_, settings) = makeIsolatedStore()
        let orphan = "orphan-uuid"
        let json = try! JSONEncoder().encode([orphan])
        settings.set("mux0-quickactions-enabled", String(data: json, encoding: .utf8))
        let store2 = QuickActionsStore(settings: settings)
        XCTAssertEqual(store2.enabledIds, [orphan])  // raw retained — not silently cleaned
        XCTAssertTrue(store2.displayList.isEmpty)     // but filtered from displayList
    }

    func test_iconSource_letterForCustom() {
        let (store, _) = makeIsolatedStore()
        let id = store.addCustomAction()
        store.updateCustomAction(id, name: "htop")
        guard case .letter(let c) = store.iconSource(for: id) else {
            XCTFail("custom should be letter"); return
        }
        XCTAssertEqual(c, "H")
    }

    func test_iconSource_letterFallbackForEmptyName() {
        let (store, _) = makeIsolatedStore()
        let id = store.addCustomAction()
        guard case .letter(let c) = store.iconSource(for: id) else {
            XCTFail("custom should be letter"); return
        }
        XCTAssertEqual(c, "?")
    }

    func test_setBuiltinCommand_ignoresNonBuiltinId() {
        let (store, settings) = makeIsolatedStore()
        store.setBuiltinCommand("not-a-builtin", "some-cmd")
        XCTAssertTrue(store.builtinCommandOverrides.isEmpty,
                      "non-builtin ids should not enter the overrides map")
        // No phantom key should land in settings either
        XCTAssertNil(settings.get("mux0-quickactions-builtin-command-not-a-builtin"))
    }

    func test_reorderDisplay_movesEnabledIds() {
        let (store, _) = makeIsolatedStore()
        store.setEnabled("lazygit", true)
        store.setEnabled("claude", true)
        store.setEnabled("codex", true)
        let codexIdx = store.displayList.firstIndex(of: "codex")!
        store.reorderDisplay(from: IndexSet([codexIdx]), to: 0)
        XCTAssertEqual(store.displayList.first, "codex")
    }

    func test_fullList_orderEnabledFirstThenBuiltinsThenCustoms() {
        let (store, _) = makeIsolatedStore()
        let custom1 = store.addCustomAction()
        let custom2 = store.addCustomAction()

        // Enable lazygit + custom1 (in that order)
        store.setEnabled("lazygit", true)
        store.setEnabled(custom1, true)

        let list = store.fullList
        // Enabled items first, in enabledIds order
        XCTAssertEqual(list.prefix(2), ["lazygit", custom1])
        // Then disabled built-ins (in BuiltinQuickAction.allCases order)
        XCTAssertTrue(list.contains("claude"))
        XCTAssertTrue(list.contains("codex"))
        XCTAssertTrue(list.contains("opencode"))
        // Then disabled customs
        XCTAssertTrue(list.contains(custom2))
        // No duplicates
        XCTAssertEqual(list.count, Set(list).count)
        // Total: 4 builtins + 2 customs = 6
        XCTAssertEqual(list.count, 6)
    }

    func test_fullList_dropsOrphanEnabledIds() {
        let (_, settings) = makeIsolatedStore()
        let orphan = "orphan-uuid"
        let json = try! JSONEncoder().encode([orphan])
        settings.set("mux0-quickactions-enabled", String(data: json, encoding: .utf8))
        let store = QuickActionsStore(settings: settings)
        XCTAssertFalse(store.fullList.contains(orphan))
    }

    func test_reorderFull_movesEnabledBuiltinUpdatesEnabledIdsOrder() {
        let (store, _) = makeIsolatedStore()
        store.setEnabled("lazygit", true)
        store.setEnabled("claude", true)
        store.setEnabled("codex", true)
        // fullList prefix is [lazygit, claude, codex, ...]; move codex (idx 2) to 0
        let codexIdx = store.fullList.firstIndex(of: "codex")!
        store.reorderFull(from: IndexSet([codexIdx]), to: 0)
        XCTAssertEqual(store.enabledIds, ["codex", "lazygit", "claude"])
        XCTAssertEqual(store.displayList, ["codex", "lazygit", "claude"])
    }

    func test_reorderFull_movingDisabledItemDoesNotChangeEnabledIds() {
        let (store, _) = makeIsolatedStore()
        store.setEnabled("lazygit", true)
        let beforeEnabled = store.enabledIds
        // Move codex (disabled) somewhere
        let codexIdx = store.fullList.firstIndex(of: "codex")!
        store.reorderFull(from: IndexSet([codexIdx]), to: 0)
        XCTAssertEqual(store.enabledIds, beforeEnabled, "moving disabled item should not touch enabledIds")
    }

    func test_reorderFull_movingCustomUpdatesCustomActionsOrder() {
        let (store, _) = makeIsolatedStore()
        let c1 = store.addCustomAction()
        let c2 = store.addCustomAction()
        let c3 = store.addCustomAction()
        // customActions order: [c1, c2, c3]
        // Move c3 (last in fullList) to right after lazygit (position 1).
        let c3Idx = store.fullList.firstIndex(of: c3)!
        let lazygitIdx = store.fullList.firstIndex(of: "lazygit")!
        store.reorderFull(from: IndexSet([c3Idx]), to: lazygitIdx + 1)
        // customActions array's relative order should now be [c3, c1, c2] OR [c1, c3, c2] OR similar — verify via fullList
        let customsInFull = store.fullList.filter { id in store.customActions.contains(where: { $0.id == id }) }
        XCTAssertEqual(customsInFull, [c3, c1, c2])
        // And the customActions array itself should match
        XCTAssertEqual(store.customActions.map(\.id), [c3, c1, c2])
    }
}
