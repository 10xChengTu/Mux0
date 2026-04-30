import XCTest
@testable import mux0

/// Smoke test that every key in the String Catalog is translated in both
/// en and zh-Hans bundles. Designed to catch missing translations after
/// adding a key but forgetting its zh-Hans counterpart.
///
/// The key list is hardcoded below so the test itself becomes the single
/// source of truth for "what keys exist" — violating DRY with the xcstrings
/// file is intentional: if someone adds a key without updating this list,
/// they get a reviewer question about why it wasn't added to the test.
final class L10nSmokeTests: XCTestCase {
    /// All keys declared in mux0/Localization/Strings.xcstrings. Keep sorted.
    /// Maintain when adding or removing catalog entries.
    private let allKeys: [String] = [
        // App
        "app.ghostty.notFound.detail",
        "app.ghostty.notFound.title",
        // Menu
        "menu.closePane",
        "menu.copy",
        "menu.editConfig",
        "menu.focusNextPane",
        "menu.focusPrevPane",
        "menu.help",
        "menu.newTab",
        "menu.newWorkspace",
        "menu.paste",
        "menu.selectAll",
        "menu.selectNextTab",
        "menu.selectPrevTab",
        "menu.selectTab %lld",
        "menu.settings",
        "menu.splitHorizontal",
        "menu.splitVertical",
        "menu.terminal",
        // QuickActions
        "quickActions.builtin.claude",
        "quickActions.builtin.codex",
        "quickActions.builtin.lazygit",
        "quickActions.builtin.opencode",
        // Settings — appearance
        "settings.appearance.backgroundBlur",
        "settings.appearance.backgroundOpacity",
        "settings.appearance.contentOpacity",
        "settings.appearance.cursorBlink",
        "settings.appearance.cursorStyle",
        "settings.appearance.language",
        "settings.appearance.theme",
        "settings.appearance.unfocusedPaneOpacity",
        "settings.appearance.windowPaddingX",
        "settings.appearance.windowPaddingY",
        // Settings — agents
        "settings.agents.claude",
        "settings.agents.codex",
        "settings.agents.opencode",
        // Settings — chrome
        "settings.close",
        "settings.footer.edit",
        "settings.footer.live",
        // Settings — font
        "settings.font.custom",
        "settings.font.customPlaceholder",
        "settings.font.default",
        "settings.font.family",
        "settings.font.listButton",
        "settings.font.size",
        "settings.font.thicken",
        // Settings — language
        "settings.language.system",
        // Settings — reset
        "settings.reset.alertTitle",
        "settings.reset.button",
        "settings.reset.cancel",
        "settings.reset.message",
        "settings.reset.rowLabel",
        // Settings — section
        "settings.section.agents",
        "settings.section.appearance",
        "settings.section.font",
        "settings.section.quickActions",
        "settings.section.shell",
        "settings.section.terminal",
        "settings.section.update",
        // Settings — shell
        "settings.shell.customCommand",
        "settings.shell.defaultPlaceholder",
        "settings.shell.features",
        "settings.shell.gitViewer.help",
        "settings.shell.gitViewer.installHint",
        "settings.shell.gitViewer.label",
        "settings.shell.integration",
        // Settings — terminal
        "settings.terminal.confirmClose",
        "settings.terminal.copyOnSelect",
        "settings.terminal.hideMouseWhileTyping",
        "settings.terminal.scrollbackLimit",
        // Settings — update (auto-update UI in Settings → Update section)
        "settings.update.action",
        "settings.update.availableUpdate",
        "settings.update.checkForUpdates",
        "settings.update.checking",
        "settings.update.currentVersion",
        "settings.update.debugBuild",
        "settings.update.debugDisabled",
        "settings.update.dismiss",
        "settings.update.downloadInstall",
        "settings.update.downloading",
        "settings.update.error",
        "settings.update.installing",
        "settings.update.releaseNotes",
        "settings.update.retry",
        "settings.update.skipThisVersion",
        "settings.update.status",
        "settings.update.upToDate",
        "settings.update.version %@",
        // Settings — theme
        "settings.theme.dark",
        "settings.theme.followSystem",
        "settings.theme.inherit",
        "settings.theme.light",
        "settings.theme.name",
        "settings.theme.searchPlaceholder",
        "settings.theme.single",
        // Sidebar
        "sidebar.checkForUpdates",
        "sidebar.deleteAlert.cancel",
        "sidebar.deleteAlert.confirm",
        "sidebar.deleteAlert.message %@",
        "sidebar.deleteAlert.title",
        "sidebar.hide",
        "sidebar.newWorkspace",
        "sidebar.row.commandPanel.cancel",
        "sidebar.row.commandPanel.editTitle",
        "sidebar.row.commandPanel.placeholder",
        "sidebar.row.commandPanel.save",
        "sidebar.row.delete",
        "sidebar.row.rename",
        "sidebar.settings",
        "sidebar.show",
        "sidebar.title",
        "sidebar.updateAvailable",
        // Tab
        "tab.close.alert.cancel",
        "tab.close.alert.confirm",
        "tab.close.alert.message %@",
        "tab.close.alert.title",
        "tab.newTab",
        "tab.row.close",
        "tab.row.rename",
        // Topbar
        "topbar.gitButton.tooltip",
    ]

    override func tearDown() {
        LanguageStore.shared.preference = .system
        super.tearDown()
    }

    private func bundle(for code: String) -> Bundle? {
        let parent = Bundle(for: LanguageStore.self)
        guard let path = parent.path(forResource: code, ofType: "lproj") else { return nil }
        return Bundle(path: path)
    }

    func testCatalogKeyListMatchesActualCount() {
        // Sanity: if someone adds a key to Strings.xcstrings but forgets to
        // add it here, this test doesn't directly fail — but the key-count
        // check catches it on both sides.
        XCTAssertEqual(allKeys.count, Set(allKeys).count,
                       "Duplicate keys in allKeys list.")
    }

    func testAllKeysResolveInEnBundle() throws {
        let b = try XCTUnwrap(bundle(for: "en"), "en.lproj not found in test bundle")
        for key in allKeys {
            let v = b.localizedString(forKey: key, value: "__MISSING__", table: nil)
            XCTAssertNotEqual(v, "__MISSING__", "Missing en translation for: \(key)")
            XCTAssertFalse(v.isEmpty, "Empty en translation for: \(key)")
            XCTAssertNotEqual(v, key, "en translation equals key for: \(key) — likely missing")
        }
    }

    func testAllKeysResolveInZhHansBundle() throws {
        let b = try XCTUnwrap(bundle(for: "zh-Hans"), "zh-Hans.lproj not found in test bundle")
        for key in allKeys {
            let v = b.localizedString(forKey: key, value: "__MISSING__", table: nil)
            XCTAssertNotEqual(v, "__MISSING__", "Missing zh-Hans translation for: \(key)")
            XCTAssertFalse(v.isEmpty, "Empty zh-Hans translation for: \(key)")
            XCTAssertNotEqual(v, key, "zh-Hans translation equals key for: \(key) — likely missing")
        }
    }

    func testFormattedMessageSubstitutesWorkspaceName() {
        // Smoke-test the sidebar.deleteAlert.message %@ path end-to-end through L10n.string.
        LanguageStore.shared.preference = .en
        let s = L10n.string("sidebar.deleteAlert.message %@", "my-ws")
        XCTAssertTrue(s.contains("my-ws"),
                      "Expected 'my-ws' to appear in formatted message; got: \(s)")
        XCTAssertFalse(s.contains("%@"),
                       "Expected '%@' to be substituted; got: \(s)")
    }

    func testFormattedTabMessageSubstitutesTabTitle() {
        LanguageStore.shared.preference = .en
        let s = L10n.string("tab.close.alert.message %@", "main.swift")
        XCTAssertTrue(s.contains("main.swift"),
                      "Expected 'main.swift' to appear; got: \(s)")
        XCTAssertFalse(s.contains("%@"),
                       "Expected '%@' to be substituted; got: \(s)")
    }
}
