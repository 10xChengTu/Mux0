import XCTest
@testable import mux0

final class TerminalSessionTitleStoreTests: XCTestCase {

    func testDefaultIsEmpty() {
        let store = TerminalSessionTitleStore(persistenceKey: "test-\(UUID())")
        XCTAssertNil(store.title(for: UUID()))
    }

    func testUpdateStoresValue() {
        let store = TerminalSessionTitleStore(persistenceKey: "test-\(UUID())")
        let id = UUID()
        store.update(terminalId: id, title: "Hello", at: 1)
        XCTAssertEqual(store.title(for: id), "Hello")
    }

    func testUpdateEmptyStringIsIgnored() {
        let store = TerminalSessionTitleStore(persistenceKey: "test-\(UUID())")
        let id = UUID()
        store.update(terminalId: id, title: "Real title", at: 1)
        store.update(terminalId: id, title: "", at: 2)
        XCTAssertEqual(store.title(for: id), "Real title")
    }

    func testUpdateWhitespaceOnlyIsIgnored() {
        let store = TerminalSessionTitleStore(persistenceKey: "test-\(UUID())")
        let id = UUID()
        store.update(terminalId: id, title: "Real", at: 1)
        store.update(terminalId: id, title: "   \n", at: 2)
        XCTAssertEqual(store.title(for: id), "Real")
    }

    func testClearRemovesValue() {
        let store = TerminalSessionTitleStore(persistenceKey: "test-\(UUID())")
        let id = UUID()
        store.update(terminalId: id, title: "X", at: 1)
        store.clear(terminalId: id)
        XCTAssertNil(store.title(for: id))
    }

    func testClearMultipleRemovesAll() {
        let store = TerminalSessionTitleStore(persistenceKey: "test-\(UUID())")
        let a = UUID(); let b = UUID(); let c = UUID()
        store.update(terminalId: a, title: "A", at: 1)
        store.update(terminalId: b, title: "B", at: 1)
        store.update(terminalId: c, title: "C", at: 1)
        store.clear(terminalIds: [a, c])
        XCTAssertNil(store.title(for: a))
        XCTAssertEqual(store.title(for: b), "B")
        XCTAssertNil(store.title(for: c))
    }

    func testPersistenceRoundtrip() {
        let key = "test-\(UUID())"
        let id = UUID()
        let store = TerminalSessionTitleStore(persistenceKey: key)
        store.update(terminalId: id, title: "Persisted", at: 1)
        store.flushSaveForTesting()

        let store2 = TerminalSessionTitleStore(persistenceKey: key)
        XCTAssertEqual(store2.title(for: id), "Persisted")
        UserDefaults.standard.removeObject(forKey: key)
    }

    func testUpdateSameValueIsIdempotent() {
        // Equality guard exists to avoid spurious debounced writes when an
        // agent hook fires the same title repeatedly (e.g. one per turn).
        let key = "test-\(UUID())"
        let id = UUID()
        let store = TerminalSessionTitleStore(persistenceKey: key)
        store.update(terminalId: id, title: "Stable", at: 1)
        store.update(terminalId: id, title: "Stable", at: 2)
        XCTAssertEqual(store.title(for: id), "Stable")
    }

    func testOlderTimestampIsRejected() {
        // An out-of-order hook delivery (e.g. a rotated session's trailing
        // `stop` landing after the next session's `prompt`) must not revert
        // the tab to a stale title.
        let store = TerminalSessionTitleStore(persistenceKey: "test-\(UUID())")
        let id = UUID()
        store.update(terminalId: id, title: "newer", at: 20)
        store.update(terminalId: id, title: "older", at: 10)
        XCTAssertEqual(store.title(for: id), "newer")
    }

    func testEqualTimestampIsAccepted() {
        // Same-turn prompt + stop share the wrapper clock granularity; an
        // equal timestamp must still be allowed to update (not treated stale).
        let store = TerminalSessionTitleStore(persistenceKey: "test-\(UUID())")
        let id = UUID()
        store.update(terminalId: id, title: "first", at: 5)
        store.update(terminalId: id, title: "second", at: 5)
        XCTAssertEqual(store.title(for: id), "second")
    }

    func testTimestampIsPerTerminal() {
        // A high timestamp on terminal A must not block a low timestamp on B.
        let store = TerminalSessionTitleStore(persistenceKey: "test-\(UUID())")
        let a = UUID(); let b = UUID()
        store.update(terminalId: a, title: "A", at: 100)
        store.update(terminalId: b, title: "B", at: 1)
        XCTAssertEqual(store.title(for: b), "B")
    }
}
