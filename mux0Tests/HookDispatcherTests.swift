import XCTest
@testable import mux0

final class HookDispatcherTests: XCTestCase {

    private var tmpConfigPath: String!
    private var settings: SettingsConfigStore!
    private var store: TerminalStatusStore!
    private let tid = UUID()

    override func setUpWithError() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mux0-dispatch-\(UUID().uuidString).conf")
        tmpConfigPath = tmp.path
        settings = SettingsConfigStore(filePath: tmpConfigPath)
        store = TerminalStatusStore()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: tmpConfigPath)
    }

    private func makeMsg(event: HookMessage.Event,
                         agent: HookMessage.Agent,
                         at: TimeInterval,
                         exitCode: Int32? = nil) -> HookMessage {
        let json = """
        {"terminalId":"\(tid.uuidString)","event":"\(event.rawValue)","agent":"\(agent.rawValue)","at":\(at)\(exitCode.map { ",\"exitCode\":\($0)" } ?? "")}
        """
        return try! JSONDecoder().decode(HookMessage.self, from: json.data(using: .utf8)!)
    }

    func testDispatchAgentOnForwardsRunning() {
        settings.set(HookMessage.Agent.claude.settingsKey, "true")
        settings.save()
        HookDispatcher.dispatch(makeMsg(event: .running, agent: .claude, at: 100),
                                settings: settings, store: store)
        if case .running = store.status(for: tid) { /* pass */ } else {
            XCTFail("Expected .running, got \(store.status(for: tid))")
        }
    }

    func testDispatchAgentOffDropsEvent() {
        // Claude toggle absent → treated as OFF.
        HookDispatcher.dispatch(makeMsg(event: .running, agent: .claude, at: 100),
                                settings: settings, store: store)
        XCTAssertEqual(store.status(for: tid), .neverRan)
    }

    func testDispatchAgentExplicitFalseDropsEvent() {
        settings.set(HookMessage.Agent.claude.settingsKey, "false")
        settings.save()
        HookDispatcher.dispatch(makeMsg(event: .running, agent: .claude, at: 100),
                                settings: settings, store: store)
        XCTAssertEqual(store.status(for: tid), .neverRan)
    }

    func testDispatchFinishedForwardsWithAgent() {
        settings.set(HookMessage.Agent.claude.settingsKey, "true")
        settings.save()
        HookDispatcher.dispatch(makeMsg(event: .running, agent: .claude, at: 100),
                                settings: settings, store: store)
        HookDispatcher.dispatch(makeMsg(event: .finished, agent: .claude,
                                        at: 110, exitCode: 0),
                                settings: settings, store: store)
        if case .success(_, _, _, let agent, _) = store.status(for: tid) {
            XCTAssertEqual(agent, .claude)
        } else {
            XCTFail("Expected .success, got \(store.status(for: tid))")
        }
    }

    func testDispatchFinishedWithoutExitCodeDropsSilently() {
        settings.set(HookMessage.Agent.claude.settingsKey, "true")
        settings.save()
        HookDispatcher.dispatch(makeMsg(event: .finished, agent: .claude, at: 100),
                                settings: settings, store: store)
        // No exitCode → setFinished would fail; dispatcher must guard.
        XCTAssertEqual(store.status(for: tid), .neverRan)
    }

    func testDispatchToggleFlipOffRetainsStoredState() {
        settings.set(HookMessage.Agent.claude.settingsKey, "true")
        settings.save()
        HookDispatcher.dispatch(makeMsg(event: .running, agent: .claude, at: 100),
                                settings: settings, store: store)
        // User flips the toggle off mid-turn.
        settings.set(HookMessage.Agent.claude.settingsKey, "false")
        settings.save()
        // New events dropped, but the already-stored .running stays.
        HookDispatcher.dispatch(makeMsg(event: .idle, agent: .claude, at: 200),
                                settings: settings, store: store)
        if case .running = store.status(for: tid) { /* pass */ } else {
            XCTFail("Expected .running to persist after toggle-off")
        }
    }

    func testDispatchNeedsInputPromotesFromRunning() {
        settings.set(HookMessage.Agent.claude.settingsKey, "true")
        settings.save()
        HookDispatcher.dispatch(makeMsg(event: .running, agent: .claude, at: 100),
                                settings: settings, store: store)
        HookDispatcher.dispatch(makeMsg(event: .needsInput, agent: .claude, at: 110),
                                settings: settings, store: store)
        if case .needsInput = store.status(for: tid) { /* pass */ } else {
            XCTFail("running → needsInput should transition, got \(store.status(for: tid))")
        }
    }

    func testDispatchNeedsInputDroppedFromSuccess() {
        settings.set(HookMessage.Agent.claude.settingsKey, "true")
        settings.save()
        HookDispatcher.dispatch(makeMsg(event: .running, agent: .claude, at: 100),
                                settings: settings, store: store)
        HookDispatcher.dispatch(makeMsg(event: .finished, agent: .claude,
                                        at: 110, exitCode: 0),
                                settings: settings, store: store)
        // 60s idle heartbeat after turn ended — must not overwrite success.
        HookDispatcher.dispatch(makeMsg(event: .needsInput, agent: .claude, at: 170),
                                settings: settings, store: store)
        if case .success = store.status(for: tid) { /* pass */ } else {
            XCTFail("success should survive needsInput heartbeat, got \(store.status(for: tid))")
        }
    }

    func testDispatchNeedsInputDroppedFromFailed() {
        settings.set(HookMessage.Agent.claude.settingsKey, "true")
        settings.save()
        HookDispatcher.dispatch(makeMsg(event: .running, agent: .claude, at: 100),
                                settings: settings, store: store)
        HookDispatcher.dispatch(makeMsg(event: .finished, agent: .claude,
                                        at: 110, exitCode: 1),
                                settings: settings, store: store)
        HookDispatcher.dispatch(makeMsg(event: .needsInput, agent: .claude, at: 170),
                                settings: settings, store: store)
        if case .failed = store.status(for: tid) { /* pass */ } else {
            XCTFail("failed should survive needsInput heartbeat, got \(store.status(for: tid))")
        }
    }

    func testDispatchNeedsInputDroppedFromIdle() {
        settings.set(HookMessage.Agent.claude.settingsKey, "true")
        settings.save()
        HookDispatcher.dispatch(makeMsg(event: .idle, agent: .claude, at: 100),
                                settings: settings, store: store)
        HookDispatcher.dispatch(makeMsg(event: .needsInput, agent: .claude, at: 160),
                                settings: settings, store: store)
        if case .idle = store.status(for: tid) { /* pass */ } else {
            XCTFail("idle should survive needsInput heartbeat, got \(store.status(for: tid))")
        }
    }

    func testDispatchNeedsInputDroppedFromNeverRan() {
        settings.set(HookMessage.Agent.claude.settingsKey, "true")
        settings.save()
        HookDispatcher.dispatch(makeMsg(event: .needsInput, agent: .claude, at: 100),
                                settings: settings, store: store)
        XCTAssertEqual(store.status(for: tid), .neverRan)
    }

    func testDispatchIdleDroppedFromSuccess() {
        settings.set(HookMessage.Agent.codex.settingsKey, "true")
        settings.save()
        HookDispatcher.dispatch(makeMsg(event: .running, agent: .codex, at: 100),
                                settings: settings, store: store)
        HookDispatcher.dispatch(makeMsg(event: .finished, agent: .codex,
                                        at: 110, exitCode: 0),
                                settings: settings, store: store)
        // codex-wrapper's notify-driven `idle` races with the Stop hook and can
        // arrive after `finished` — must not demote success back to idle.
        HookDispatcher.dispatch(makeMsg(event: .idle, agent: .codex, at: 111),
                                settings: settings, store: store)
        if case .success = store.status(for: tid) { /* pass */ } else {
            XCTFail("success should survive late idle, got \(store.status(for: tid))")
        }
    }

    func testDispatchIdleDroppedFromFailed() {
        settings.set(HookMessage.Agent.codex.settingsKey, "true")
        settings.save()
        HookDispatcher.dispatch(makeMsg(event: .running, agent: .codex, at: 100),
                                settings: settings, store: store)
        HookDispatcher.dispatch(makeMsg(event: .finished, agent: .codex,
                                        at: 110, exitCode: 1),
                                settings: settings, store: store)
        HookDispatcher.dispatch(makeMsg(event: .idle, agent: .codex, at: 111),
                                settings: settings, store: store)
        if case .failed = store.status(for: tid) { /* pass */ } else {
            XCTFail("failed should survive late idle, got \(store.status(for: tid))")
        }
    }

    func testDispatchIdleStillTransitionsFromRunning() {
        settings.set(HookMessage.Agent.codex.settingsKey, "true")
        settings.save()
        HookDispatcher.dispatch(makeMsg(event: .running, agent: .codex, at: 100),
                                settings: settings, store: store)
        HookDispatcher.dispatch(makeMsg(event: .idle, agent: .codex, at: 110),
                                settings: settings, store: store)
        if case .idle = store.status(for: tid) { /* pass */ } else {
            XCTFail("running → idle must still work when no finished arrived, got \(store.status(for: tid))")
        }
    }

    func testDispatchRunningAfterSuccessStartsNewTurn() {
        // After the idle-guard, a success state must still be replaceable by
        // the next UserPromptSubmit's `running` — otherwise the UI freezes on
        // success until app restart.
        settings.set(HookMessage.Agent.codex.settingsKey, "true")
        settings.save()
        HookDispatcher.dispatch(makeMsg(event: .running, agent: .codex, at: 100),
                                settings: settings, store: store)
        HookDispatcher.dispatch(makeMsg(event: .finished, agent: .codex,
                                        at: 110, exitCode: 0),
                                settings: settings, store: store)
        HookDispatcher.dispatch(makeMsg(event: .idle, agent: .codex, at: 111),
                                settings: settings, store: store)
        HookDispatcher.dispatch(makeMsg(event: .running, agent: .codex, at: 200),
                                settings: settings, store: store)
        if case .running = store.status(for: tid) { /* pass */ } else {
            XCTFail("success → running (new turn) must work, got \(store.status(for: tid))")
        }
    }

    func testDispatchMixedAgentsRespectsEachToggle() {
        settings.set(HookMessage.Agent.claude.settingsKey, "true")
        // codex toggle absent (OFF)
        settings.save()
        HookDispatcher.dispatch(makeMsg(event: .running, agent: .codex, at: 50),
                                settings: settings, store: store)
        XCTAssertEqual(store.status(for: tid), .neverRan, "codex OFF should drop")
        HookDispatcher.dispatch(makeMsg(event: .running, agent: .claude, at: 100),
                                settings: settings, store: store)
        if case .running = store.status(for: tid) { /* pass */ } else {
            XCTFail("claude ON should forward")
        }
    }
}
