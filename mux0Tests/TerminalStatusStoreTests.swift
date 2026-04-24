import XCTest
@testable import mux0

final class TerminalStatusStoreTests: XCTestCase {

    func testDefaultStatusIsNeverRan() {
        let store = TerminalStatusStore()
        let id = UUID()
        XCTAssertEqual(store.status(for: id), .neverRan)
    }

    func testSetRunningMakesItRunning() {
        let store = TerminalStatusStore()
        let id = UUID()
        let t = Date(timeIntervalSince1970: 1000)
        store.setRunning(terminalId: id, at: t)
        XCTAssertEqual(store.status(for: id), .running(startedAt: t))
    }

    func testSetFinishedExitZeroIsSuccess() {
        let store = TerminalStatusStore()
        let id = UUID()
        let t1 = Date(timeIntervalSince1970: 1000)
        let t2 = Date(timeIntervalSince1970: 1005)
        store.setRunning(terminalId: id, at: t1)
        store.setFinished(terminalId: id, exitCode: 0, at: t2, agent: .claude)
        XCTAssertEqual(
            store.status(for: id),
            .success(exitCode: 0, duration: 5, finishedAt: t2, agent: .claude)
        )
    }

    func testSetFinishedExitNonZeroIsFailed() {
        let store = TerminalStatusStore()
        let id = UUID()
        let t = Date(timeIntervalSince1970: 2000)
        store.setFinished(terminalId: id, exitCode: 1, at: t, agent: .claude)
        XCTAssertEqual(
            store.status(for: id),
            .failed(exitCode: 1, duration: 0, finishedAt: t, agent: .claude)
        )
    }

    func testNewRunningAfterFinishOverwrites() {
        let store = TerminalStatusStore()
        let id = UUID()
        let t1 = Date(timeIntervalSince1970: 1000)
        store.setFinished(terminalId: id, exitCode: 0, at: t1, agent: .claude)
        let t2 = Date(timeIntervalSince1970: 2000)
        store.setRunning(terminalId: id, at: t2)
        XCTAssertEqual(store.status(for: id), .running(startedAt: t2))
    }

    func testForgetClearsEntry() {
        let store = TerminalStatusStore()
        let id = UUID()
        store.setRunning(terminalId: id, at: Date())
        store.forget(terminalId: id)
        XCTAssertEqual(store.status(for: id), .neverRan)
    }

    func testAggregateForIdsUsesPriority() {
        let store = TerminalStatusStore()
        let a = UUID(); let b = UUID(); let c = UUID()
        let now = Date()
        store.setRunning(terminalId: a, at: now)
        store.setFinished(terminalId: b, exitCode: 1, at: now, agent: .claude)
        // c left as neverRan
        if case .running = store.aggregateStatus(terminalIds: [a, b, c]) {
            // pass
        } else {
            XCTFail("Expected running to win aggregation")
        }
    }

    func testStatusesSnapshotReturnsAllSetEntries() {
        let store = TerminalStatusStore()
        let a = UUID(); let b = UUID()
        let t = Date()
        store.setRunning(terminalId: a, at: t)
        store.setFinished(terminalId: b, exitCode: 0, at: t, agent: .claude)
        let snap = store.statusesSnapshot()
        XCTAssertEqual(snap.count, 2)
        XCTAssertEqual(snap[a], .running(startedAt: t))
        XCTAssertEqual(snap[b], .success(exitCode: 0, duration: 0, finishedAt: t, agent: .claude))
    }

    func testSetIdle() {
        let store = TerminalStatusStore()
        let id = UUID()
        let t = Date(timeIntervalSince1970: 3000)
        store.setIdle(terminalId: id, at: t)
        XCTAssertEqual(store.status(for: id), .idle(since: t))
    }

    func testSetNeedsInput() {
        let store = TerminalStatusStore()
        let id = UUID()
        let t = Date(timeIntervalSince1970: 4000)
        store.setNeedsInput(terminalId: id, at: t)
        XCTAssertEqual(store.status(for: id), .needsInput(since: t))
    }

    func testIdleOverwritesRunning() {
        let store = TerminalStatusStore()
        let id = UUID()
        let t1 = Date(timeIntervalSince1970: 5000)
        let t2 = Date(timeIntervalSince1970: 5005)
        store.setRunning(terminalId: id, at: t1)
        store.setIdle(terminalId: id, at: t2)
        XCTAssertEqual(store.status(for: id), .idle(since: t2))
    }

    func testStaleRunningAfterIdleIsDropped() {
        let store = TerminalStatusStore()
        let id = UUID()
        let preexec = Date(timeIntervalSince1970: 1000)
        let precmd  = Date(timeIntervalSince1970: 1001)
        // Async hook-emit race: precmd's idle (newer at) arrives before preexec's
        // running (older at). The stale running must be dropped or the spinner
        // sticks on until the next command finishes.
        store.setIdle(terminalId: id, at: precmd)
        store.setRunning(terminalId: id, at: preexec)
        XCTAssertEqual(store.status(for: id), .idle(since: precmd))
    }

    func testStaleIdleAfterRunningIsDropped() {
        let store = TerminalStatusStore()
        let id = UUID()
        let earlier = Date(timeIntervalSince1970: 1000)
        let later   = Date(timeIntervalSince1970: 1005)
        store.setRunning(terminalId: id, at: later)
        store.setIdle(terminalId: id, at: earlier)
        XCTAssertEqual(store.status(for: id), .running(startedAt: later))
    }

    func testFinishedDurationDerivedFromRunning() {
        let store = TerminalStatusStore()
        let id = UUID()
        let started = Date(timeIntervalSince1970: 10_000)
        let finished = Date(timeIntervalSince1970: 10_007.25)
        store.setRunning(terminalId: id, at: started)
        store.setFinished(terminalId: id, exitCode: 0, at: finished, agent: .claude)
        XCTAssertEqual(
            store.status(for: id),
            .success(exitCode: 0, duration: 7.25, finishedAt: finished, agent: .claude)
        )
    }

    func testFinishedWithoutPriorRunningHasZeroDuration() {
        let store = TerminalStatusStore()
        let id = UUID()
        let finished = Date(timeIntervalSince1970: 20_000)
        store.setFinished(terminalId: id, exitCode: 2, at: finished, agent: .claude)
        XCTAssertEqual(
            store.status(for: id),
            .failed(exitCode: 2, duration: 0, finishedAt: finished, agent: .claude)
        )
    }

    func testSetRunningWithDetailStoresDetail() {
        let store = TerminalStatusStore()
        let id = UUID()
        let t = Date(timeIntervalSince1970: 1000)
        store.setRunning(terminalId: id, at: t, detail: "Edit Foo.swift")
        XCTAssertEqual(store.status(for: id), .running(startedAt: t, detail: "Edit Foo.swift"))
    }

    func testSetRunningPreservesStartedAtAcrossToolChanges() {
        let store = TerminalStatusStore()
        let id = UUID()
        let t1 = Date(timeIntervalSince1970: 1000)
        let t2 = Date(timeIntervalSince1970: 1005)
        store.setRunning(terminalId: id, at: t1, detail: "Read Foo.swift")
        store.setRunning(terminalId: id, at: t2, detail: "Edit Foo.swift")
        // startedAt stays at t1 — duration is measured from first tool onset
        XCTAssertEqual(store.status(for: id), .running(startedAt: t1, detail: "Edit Foo.swift"))
    }

    func testSetRunningFromNonRunningSetsNewStartedAt() {
        let store = TerminalStatusStore()
        let id = UUID()
        let t1 = Date(timeIntervalSince1970: 1000)
        let t2 = Date(timeIntervalSince1970: 2000)
        store.setIdle(terminalId: id, at: t1)
        store.setRunning(terminalId: id, at: t2, detail: "Bash: ls")
        XCTAssertEqual(store.status(for: id), .running(startedAt: t2, detail: "Bash: ls"))
    }

    func testSetFinishedWithAgentAndSummary() {
        let store = TerminalStatusStore()
        let id = UUID()
        let t1 = Date(timeIntervalSince1970: 100)
        let t2 = Date(timeIntervalSince1970: 112)
        store.setRunning(terminalId: id, at: t1)
        store.setFinished(terminalId: id, exitCode: 1, at: t2,
                          agent: .claude, summary: "Edit failed: permission.")
        XCTAssertEqual(
            store.status(for: id),
            .failed(exitCode: 1, duration: 12, finishedAt: t2,
                    agent: .claude, summary: "Edit failed: permission.")
        )
    }

    // MARK: - markRead

    func testMarkReadStampsUnreadSuccess() {
        let store = TerminalStatusStore()
        let id = UUID()
        let finishedAt = Date(timeIntervalSince1970: 1000)
        store.setFinished(terminalId: id, exitCode: 0, at: finishedAt, agent: .claude)
        let readAt = Date(timeIntervalSince1970: 1010)
        store.markRead(terminalIds: [id], at: readAt)
        guard case .success(_, _, _, _, _, let actual) = store.status(for: id) else {
            XCTFail("Expected .success"); return
        }
        XCTAssertEqual(actual, readAt)
    }

    func testMarkReadStampsUnreadFailed() {
        let store = TerminalStatusStore()
        let id = UUID()
        let finishedAt = Date(timeIntervalSince1970: 2000)
        store.setFinished(terminalId: id, exitCode: 1, at: finishedAt, agent: .claude)
        let readAt = Date(timeIntervalSince1970: 2010)
        store.markRead(terminalIds: [id], at: readAt)
        guard case .failed(_, _, _, _, _, let actual) = store.status(for: id) else {
            XCTFail("Expected .failed"); return
        }
        XCTAssertEqual(actual, readAt)
    }

    func testMarkReadPreservesFirstReadAtWhenCalledTwice() {
        let store = TerminalStatusStore()
        let id = UUID()
        store.setFinished(terminalId: id, exitCode: 0, at: Date(timeIntervalSince1970: 1000),
                          agent: .claude)
        let firstRead  = Date(timeIntervalSince1970: 1010)
        let secondRead = Date(timeIntervalSince1970: 1020)
        store.markRead(terminalIds: [id], at: firstRead)
        store.markRead(terminalIds: [id], at: secondRead)
        guard case .success(_, _, _, _, _, let actual) = store.status(for: id) else {
            XCTFail("Expected .success"); return
        }
        XCTAssertEqual(actual, firstRead, "Already-read entries should not be re-stamped")
    }

    func testMarkReadIgnoresNonTerminalStates() {
        let store = TerminalStatusStore()
        let id = UUID()
        let started = Date(timeIntervalSince1970: 1000)
        store.setRunning(terminalId: id, at: started)
        store.markRead(terminalIds: [id], at: Date(timeIntervalSince1970: 2000))
        // Still running — markRead is a no-op for non-success/failed states.
        XCTAssertEqual(store.status(for: id), .running(startedAt: started))
    }

    func testMarkReadIgnoresUnknownIds() {
        let store = TerminalStatusStore()
        let unknown = UUID()
        store.markRead(terminalIds: [unknown], at: Date())
        XCTAssertEqual(store.status(for: unknown), .neverRan)
    }

    func testMarkReadAcceptsMultipleIds() {
        let store = TerminalStatusStore()
        let a = UUID(); let b = UUID()
        let t = Date(timeIntervalSince1970: 1000)
        store.setFinished(terminalId: a, exitCode: 0, at: t, agent: .claude)
        store.setFinished(terminalId: b, exitCode: 1, at: t, agent: .claude)
        let readAt = Date(timeIntervalSince1970: 1010)
        store.markRead(terminalIds: [a, b], at: readAt)
        guard case .success(_, _, _, _, _, let ra) = store.status(for: a),
              case .failed(_, _, _, _, _, let rb) = store.status(for: b) else {
            XCTFail("Expected .success + .failed"); return
        }
        XCTAssertEqual(ra, readAt)
        XCTAssertEqual(rb, readAt)
    }

    func testMarkReadEmptyIdsIsNoOp() {
        let store = TerminalStatusStore()
        let id = UUID()
        let finishedAt = Date(timeIntervalSince1970: 1000)
        store.setFinished(terminalId: id, exitCode: 0, at: finishedAt, agent: .claude)
        store.markRead(terminalIds: [], at: Date(timeIntervalSince1970: 1010))
        // Existing entry untouched when ids list is empty — Task 5's ContentView
        // hits this path at launch before any workspace is selected.
        guard case .success(_, _, _, _, _, let readAt) = store.status(for: id) else {
            XCTFail("Expected .success"); return
        }
        XCTAssertNil(readAt)
    }

    func testSetFinishedClearsPriorReadAt() {
        let store = TerminalStatusStore()
        let id = UUID()
        store.setFinished(terminalId: id, exitCode: 0, at: Date(timeIntervalSince1970: 1000),
                          agent: .claude)
        store.markRead(terminalIds: [id], at: Date(timeIntervalSince1970: 1010))
        // New finished event — readAt must reset to nil (new unread result).
        store.setFinished(terminalId: id, exitCode: 0, at: Date(timeIntervalSince1970: 2000),
                          agent: .claude)
        guard case .success(_, _, _, _, _, let readAt) = store.status(for: id) else {
            XCTFail("Expected .success"); return
        }
        XCTAssertNil(readAt)
    }

}
