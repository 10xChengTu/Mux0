import XCTest
@testable import mux0

final class TerminalTabDisplayTitleTests: XCTestCase {

    private func makeStore() -> TerminalSessionTitleStore {
        TerminalSessionTitleStore(persistenceKey: "test-\(UUID())")
    }

    func testFallsBackToTabTitleWhenStoreEmpty() {
        let termId = UUID()
        var tab = TerminalTab(title: "Terminal 1", terminalId: termId)
        tab.focusedTerminalId = termId
        let store = makeStore()
        XCTAssertEqual(tab.displayTitle(sessionTitleStore: store), "Terminal 1")
    }

    func testUsesStoreTitleForFocusedTerminal() {
        let termId = UUID()
        var tab = TerminalTab(title: "claude", terminalId: termId)
        tab.focusedTerminalId = termId
        let store = makeStore()
        store.update(terminalId: termId, title: "Implement feature X")
        XCTAssertEqual(tab.displayTitle(sessionTitleStore: store), "Implement feature X")
    }

    func testUserRenamedOverridesStore() {
        let termId = UUID()
        var tab = TerminalTab(title: "My Tab", terminalId: termId)
        tab.focusedTerminalId = termId
        tab.userRenamed = true
        let store = makeStore()
        store.update(terminalId: termId, title: "Should not show")
        XCTAssertEqual(tab.displayTitle(sessionTitleStore: store), "My Tab")
    }

    func testTracksFocusedTerminalAcrossPanes() {
        // Two-pane tab: focus the second; only second's title should be used.
        let leftId = UUID()
        let rightId = UUID()
        var tab = TerminalTab(title: "split tab", terminalId: leftId)
        tab.layout = .split(UUID(), .vertical, 0.5,
                            .terminal(leftId), .terminal(rightId))
        tab.focusedTerminalId = rightId
        let store = makeStore()
        store.update(terminalId: leftId, title: "Left pane session")
        store.update(terminalId: rightId, title: "Right pane session")
        XCTAssertEqual(tab.displayTitle(sessionTitleStore: store), "Right pane session")
    }

    func testCodableDefaultsUserRenamedToFalse() throws {
        // Legacy tab data without `userRenamed` key must decode with default false.
        // focusedTerminalId must reference the layout's terminalId — they're
        // not independent in valid data; use the same UUID for both.
        let tabId = UUID()
        let termId = UUID()
        let json = #"""
        {"id":"\#(tabId.uuidString)","title":"old","layout":{"type":"terminal","terminalId":"\#(termId.uuidString)"},"focusedTerminalId":"\#(termId.uuidString)"}
        """#
        let tab = try JSONDecoder().decode(TerminalTab.self, from: Data(json.utf8))
        XCTAssertFalse(tab.userRenamed)
    }

    func testCodableRoundtripPreservesUserRenamed() throws {
        let termId = UUID()
        var tab = TerminalTab(title: "X", terminalId: termId)
        tab.userRenamed = true
        let data = try JSONEncoder().encode(tab)
        let decoded = try JSONDecoder().decode(TerminalTab.self, from: data)
        XCTAssertTrue(decoded.userRenamed)
    }
}
