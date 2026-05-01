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

    private func makeIsolatedSettings() -> SettingsConfigStore {
        let dir = NSTemporaryDirectory()
        let path = (dir as NSString).appendingPathComponent(
            "mux0-quickactions-\(UUID().uuidString).conf"
        )
        tmpPaths.append(path)
        return SettingsConfigStore(filePath: path)
    }

    private func makeIsolatedStore() -> (QuickActionsStore, SettingsConfigStore) {
        let settings = makeIsolatedSettings()
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
        store.setEnabled("gitui", true)
        XCTAssertEqual(store.enabledIds, ["gitui"])
        XCTAssertTrue(store.isEnabled("gitui"))

        // Force the debounced write to flush to disk, then re-instantiate
        // the SettingsConfigStore from the same file path so the round-trip
        // exercises actual on-disk persistence.
        settings.save()

        let store2 = QuickActionsStore(settings: settings)
        XCTAssertEqual(store2.enabledIds, ["gitui"])
    }

    func test_setEnabled_idempotent() {
        let (store, _) = makeIsolatedStore()
        store.setEnabled("gitui", true)
        store.setEnabled("gitui", true)
        XCTAssertEqual(store.enabledIds, ["gitui"])
    }

    func test_setEnabled_offRemoves() {
        let (store, _) = makeIsolatedStore()
        store.setEnabled("gitui", true)
        store.setEnabled("claude", true)
        store.setEnabled("gitui", false)
        XCTAssertEqual(store.enabledIds, ["claude"])
    }

    func test_command_builtinDefault() {
        let (store, _) = makeIsolatedStore()
        XCTAssertEqual(store.command(for: "gitui"), "gitui")
        XCTAssertEqual(store.command(for: "claude"), "claude")
    }

    func test_command_builtinOverride() {
        let (store, _) = makeIsolatedStore()
        store.setBuiltinCommand("gitui", "lazygit")
        XCTAssertEqual(store.command(for: "gitui"), "lazygit")
    }

    func test_command_builtinEmptyOverrideFallsBackToDefault() {
        let (store, _) = makeIsolatedStore()
        store.setBuiltinCommand("gitui", "lazygit")
        store.setBuiltinCommand("gitui", "")
        XCTAssertEqual(store.command(for: "gitui"), "gitui")
        XCTAssertNil(store.builtinCommandOverrides["gitui"])
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
        // enabledIds filters orphans (the public API is "enabled AND existing");
        // the underlying enabledSet still contains the orphan so an external
        // edit doesn't silently lose it.
        XCTAssertTrue(store2.enabledIds.isEmpty)
        XCTAssertTrue(store2.displayList.isEmpty)
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
        store.setEnabled("gitui", true)
        store.setEnabled("claude", true)
        store.setEnabled("codex", true)
        let codexIdx = store.displayList.firstIndex(of: "codex")!
        store.reorderDisplay(from: IndexSet([codexIdx]), to: 0)
        XCTAssertEqual(store.displayList.first, "codex")
    }

    func test_fullList_stableAcrossEnableToggles() {
        // Visual order is owned by `orderedIds` and does NOT shuffle on
        // enable/disable. Default order on a fresh store is built-ins in
        // declaration order followed by customs in addCustomAction order.
        let (store, _) = makeIsolatedStore()
        let custom1 = store.addCustomAction()
        let custom2 = store.addCustomAction()

        let initial = store.fullList
        XCTAssertEqual(initial,
                       BuiltinQuickAction.allCases.map(\.id) + [custom1, custom2])

        // Toggling any subset of items must NOT mutate the order.
        store.setEnabled("codex", true)
        store.setEnabled(custom2, true)
        XCTAssertEqual(store.fullList, initial,
                       "enabling items should not reshuffle fullList")

        store.setEnabled("codex", false)
        XCTAssertEqual(store.fullList, initial,
                       "disabling items should not reshuffle fullList")
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
        store.setEnabled("gitui", true)
        store.setEnabled("claude", true)
        store.setEnabled("codex", true)
        // fullList prefix is [gitui, claude, codex, ...]; move codex (idx 2) to 0
        let codexIdx = store.fullList.firstIndex(of: "codex")!
        store.reorderFull(from: IndexSet([codexIdx]), to: 0)
        XCTAssertEqual(store.enabledIds, ["codex", "gitui", "claude"])
        XCTAssertEqual(store.displayList, ["codex", "gitui", "claude"])
    }

    func test_reorderFull_movingDisabledItemDoesNotChangeEnabledIds() {
        let (store, _) = makeIsolatedStore()
        store.setEnabled("gitui", true)
        let beforeEnabled = store.enabledIds
        // Move codex (disabled) somewhere
        let codexIdx = store.fullList.firstIndex(of: "codex")!
        store.reorderFull(from: IndexSet([codexIdx]), to: 0)
        XCTAssertEqual(store.enabledIds, beforeEnabled, "moving disabled item should not touch enabledIds")
    }

    func test_reorderFull_movingCustomUpdatesFullListOrder() {
        let (store, _) = makeIsolatedStore()
        let c1 = store.addCustomAction()
        let c2 = store.addCustomAction()
        let c3 = store.addCustomAction()
        // Move c3 (last in fullList) to right after gitui (position 1).
        let c3Idx = store.fullList.firstIndex(of: c3)!
        let gituiIdx = store.fullList.firstIndex(of: "gitui")!
        store.reorderFull(from: IndexSet([c3Idx]), to: gituiIdx + 1)
        // Customs as projected through fullList reflect the new order.
        let customsInFull = store.fullList.filter { id in store.customActions.contains(where: { $0.id == id }) }
        XCTAssertEqual(customsInFull, [c3, c1, c2])
        // `customActions` is now a pure data array (not order-bearing); we
        // intentionally don't assert anything about its index order here.
    }

    func test_setEnabled_preservesFullListOrderAcrossToggles() {
        // Regression for the user-reported "rows shuffle on toggle" bug:
        // a stable orderedIds means flipping the switch must keep the row in
        // place across BOTH the Settings list (`fullList`) and the top bar
        // (`displayList` follows `orderedIds` too).
        let (store, _) = makeIsolatedStore()
        store.setEnabled("gitui", true)
        store.setEnabled("claude", true)
        store.setEnabled("codex", true)
        store.setEnabled("opencode", true)
        let baseline = store.fullList

        store.setEnabled("claude", false)
        XCTAssertEqual(store.fullList, baseline)
        XCTAssertEqual(store.displayList,
                       baseline.filter { $0 != "claude" })

        store.setEnabled("claude", true)
        XCTAssertEqual(store.fullList, baseline)
        XCTAssertEqual(store.displayList, baseline)
    }

    func test_orderedIds_persistsAcrossReload() {
        let (store, settings) = makeIsolatedStore()
        // Move codex to the front via a fullList-dimension reorder.
        let codexIdx = store.fullList.firstIndex(of: "codex")!
        store.reorderFull(from: IndexSet([codexIdx]), to: 0)
        let snapshot = store.fullList
        settings.save()

        let store2 = QuickActionsStore(settings: settings)
        XCTAssertEqual(store2.fullList, snapshot,
                       "orderedIds should round-trip via mux0-quickactions-order")
    }

    func test_legacyMigration_derivesOrderFromOldEnabledIds() {
        // Simulate an older config that only persisted `enabled` (no `order`
        // key). Build the settings file directly (bypassing makeIsolatedStore,
        // which would otherwise initialize a Store and pre-populate kOrder).
        let settings = makeIsolatedSettings()
        let json = try! JSONEncoder().encode(["codex", "gitui"])
        settings.set("mux0-quickactions-enabled", String(data: json, encoding: .utf8))

        let migrated = QuickActionsStore(settings: settings)
        // Migrated order: enabled first (codex, gitui), then the remaining
        // built-ins in BuiltinQuickAction.allCases order (claude, opencode).
        XCTAssertEqual(migrated.fullList, ["codex", "gitui", "claude", "opencode"])

        // Subsequent toggles do NOT shuffle the now-frozen order.
        migrated.setEnabled("codex", false)
        XCTAssertEqual(migrated.fullList, ["codex", "gitui", "claude", "opencode"])
    }
}
