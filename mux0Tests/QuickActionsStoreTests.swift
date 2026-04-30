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

    func test_reorderDisplay_movesEnabledIds() {
        let (store, _) = makeIsolatedStore()
        store.setEnabled("lazygit", true)
        store.setEnabled("claude", true)
        store.setEnabled("codex", true)
        let codexIdx = store.displayList.firstIndex(of: "codex")!
        store.reorderDisplay(from: IndexSet([codexIdx]), to: 0)
        XCTAssertEqual(store.displayList.first, "codex")
    }
}
