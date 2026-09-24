import XCTest
@testable import mux0

final class HookMessageTests: XCTestCase {

    func testDecodeRunning() throws {
        let json = """
        {"terminalId":"550E8400-E29B-41D4-A716-446655440000","event":"running","agent":"claude","at":1713345678.5}
        """.data(using: .utf8)!
        let msg = try JSONDecoder().decode(HookMessage.self, from: json)
        XCTAssertEqual(msg.terminalId, UUID(uuidString: "550E8400-E29B-41D4-A716-446655440000"))
        XCTAssertEqual(msg.event, .running)
        XCTAssertEqual(msg.agent, .claude)
    }

    func testDecodeUnknownAgentFails() {
        let json = #"{"terminalId":"550E8400-E29B-41D4-A716-446655440000","event":"idle","agent":"cursor","at":1}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(HookMessage.self, from: json))
    }

    func testDecodeShellAgentFails() {
        let json = #"{"terminalId":"550E8400-E29B-41D4-A716-446655440000","event":"idle","agent":"shell","at":1}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(HookMessage.self, from: json))
    }

    func testDecodeNeedsInput() throws {
        let json = #"{"terminalId":"550E8400-E29B-41D4-A716-446655440000","event":"needsInput","agent":"opencode","at":2}"#.data(using: .utf8)!
        let msg = try JSONDecoder().decode(HookMessage.self, from: json)
        XCTAssertEqual(msg.event, .needsInput)
    }

    func testDecodeWithOptionalMeta() throws {
        let json = #"{"terminalId":"550E8400-E29B-41D4-A716-446655440000","event":"running","agent":"codex","at":1,"meta":{"tool":"shell"}}"#.data(using: .utf8)!
        let msg = try JSONDecoder().decode(HookMessage.self, from: json)
        XCTAssertEqual(msg.agent, .codex)
    }

    func testDecodeIdleHasNoExitCode() throws {
        let json = #"{"terminalId":"550E8400-E29B-41D4-A716-446655440000","event":"idle","agent":"claude","at":1}"#.data(using: .utf8)!
        let msg = try JSONDecoder().decode(HookMessage.self, from: json)
        XCTAssertEqual(msg.event, .idle)
        XCTAssertNil(msg.exitCode)
    }

    func testDecodeRunningWithToolDetail() throws {
        let json = #"{"terminalId":"550E8400-E29B-41D4-A716-446655440000","event":"running","agent":"claude","at":1713500000.0,"toolDetail":"Edit Models/Foo.swift"}"#.data(using: .utf8)!
        let msg = try JSONDecoder().decode(HookMessage.self, from: json)
        XCTAssertEqual(msg.event, .running)
        XCTAssertEqual(msg.agent, .claude)
        XCTAssertEqual(msg.toolDetail, "Edit Models/Foo.swift")
        XCTAssertNil(msg.summary)
        XCTAssertNil(msg.exitCode)
    }

    func testDecodeFinishedWithAgentAndSummary() throws {
        let json = #"{"terminalId":"550E8400-E29B-41D4-A716-446655440000","event":"finished","agent":"claude","at":1713500015.3,"exitCode":0,"summary":"Refactored WorkspaceStore."}"#.data(using: .utf8)!
        let msg = try JSONDecoder().decode(HookMessage.self, from: json)
        XCTAssertEqual(msg.event, .finished)
        XCTAssertEqual(msg.agent, .claude)
        XCTAssertEqual(msg.exitCode, 0)
        XCTAssertEqual(msg.summary, "Refactored WorkspaceStore.")
        XCTAssertNil(msg.toolDetail)
    }

    func testAgentAllCasesExcludesShell() {
        XCTAssertEqual(HookMessage.Agent.allCases.count, 5)
        let raws = Set(HookMessage.Agent.allCases.map(\.rawValue))
        XCTAssertEqual(raws, ["claude", "opencode", "codex", "pi", "grok"])
        XCTAssertFalse(raws.contains("shell"))
    }

    // MARK: - pi / grok (0.8.5)

    func testDecodePiFinishedWithSentinel() throws {
        let json = #"{"terminalId":"550E8400-E29B-41D4-A716-446655440000","event":"finished","agent":"pi","at":1,"exitCode":1,"summary":"Two files. DONE"}"#.data(using: .utf8)!
        let msg = try JSONDecoder().decode(HookMessage.self, from: json)
        XCTAssertEqual(msg.agent, .pi)
        XCTAssertEqual(msg.exitCode, 1)
        XCTAssertEqual(msg.summary, "Two files. DONE")
    }

    func testDecodeGrokRunningWithResumeAndTitle() throws {
        let json = #"{"terminalId":"550E8400-E29B-41D4-A716-446655440000","event":"running","agent":"grok","at":1,"resumeCommand":"grok --resume 01a0d1d8-4252","sessionTitle":"List Files"}"#.data(using: .utf8)!
        let msg = try JSONDecoder().decode(HookMessage.self, from: json)
        XCTAssertEqual(msg.agent, .grok)
        XCTAssertEqual(msg.resumeCommand, "grok --resume 01a0d1d8-4252")
        XCTAssertEqual(msg.sessionTitle, "List Files")
    }

    func testAgentSettingsAndResumeKeysForPiGrok() {
        XCTAssertEqual(HookMessage.Agent.pi.settingsKey, "mux0-agent-status-pi")
        XCTAssertEqual(HookMessage.Agent.pi.resumeSettingsKey, "mux0-agent-resume-pi")
        XCTAssertEqual(HookMessage.Agent.grok.settingsKey, "mux0-agent-status-grok")
        XCTAssertEqual(HookMessage.Agent.grok.resumeSettingsKey, "mux0-agent-resume-grok")
        XCTAssertTrue(HookMessage.Agent.pi.supportsResume)
        XCTAssertTrue(HookMessage.Agent.grok.supportsResume)
    }

    func testFromResumeCommandPiAndGrok() {
        XCTAssertEqual(HookMessage.Agent.fromResumeCommand("pi --session abc"), .pi)
        XCTAssertEqual(HookMessage.Agent.fromResumeCommand("grok --resume abc"), .grok)
        // Prefix must be a whole CLI token — a longer command beginning with the
        // same letters belongs to a different program.
        XCTAssertNil(HookMessage.Agent.fromResumeCommand("pico --session abc"))
        XCTAssertNil(HookMessage.Agent.fromResumeCommand("grokify --resume abc"))
        // Existing agents keep resolving (regression guard for the new prefixes).
        XCTAssertEqual(HookMessage.Agent.fromResumeCommand("claude --resume abc"), .claude)
        XCTAssertEqual(HookMessage.Agent.fromResumeCommand("codex resume abc"), .codex)
        XCTAssertEqual(HookMessage.Agent.fromResumeCommand("opencode --session abc"), .opencode)
        XCTAssertNil(HookMessage.Agent.fromResumeCommand("gitui"))
        XCTAssertNil(HookMessage.Agent.fromResumeCommand(""))
    }

    func testDisplayNameForPiAndGrok() {
        XCTAssertEqual(HookMessage.Agent.pi.displayName, "pi")
        XCTAssertEqual(HookMessage.Agent.grok.displayName, "Grok")
    }

    func testDecodeRunningWithResumeCommand() throws {
        let json = #"{"terminalId":"550E8400-E29B-41D4-A716-446655440000","event":"running","agent":"claude","at":1713500000.0,"resumeCommand":"claude --resume abc-123"}"#.data(using: .utf8)!
        let msg = try JSONDecoder().decode(HookMessage.self, from: json)
        XCTAssertEqual(msg.resumeCommand, "claude --resume abc-123")
    }

    func testDecodeRunningWithoutResumeCommand() throws {
        let json = #"{"terminalId":"550E8400-E29B-41D4-A716-446655440000","event":"running","agent":"claude","at":1}"#.data(using: .utf8)!
        let msg = try JSONDecoder().decode(HookMessage.self, from: json)
        XCTAssertNil(msg.resumeCommand)
    }

    func testAgentSettingsKeyFormat() {
        XCTAssertEqual(HookMessage.Agent.claude.settingsKey,   "mux0-agent-status-claude")
        XCTAssertEqual(HookMessage.Agent.codex.settingsKey,    "mux0-agent-status-codex")
        XCTAssertEqual(HookMessage.Agent.opencode.settingsKey, "mux0-agent-status-opencode")
    }

    func testDecodesSessionTitle() throws {
        let json = #"""
        {"terminalId":"\#(UUID().uuidString)","event":"running","agent":"claude","at":1.0,"sessionTitle":"Implement auto-naming"}
        """#
        let msg = try JSONDecoder().decode(HookMessage.self, from: Data(json.utf8))
        XCTAssertEqual(msg.sessionTitle, "Implement auto-naming")
    }

    func testSessionTitleMissingIsNil() throws {
        let json = #"""
        {"terminalId":"\#(UUID().uuidString)","event":"running","agent":"claude","at":1.0}
        """#
        let msg = try JSONDecoder().decode(HookMessage.self, from: Data(json.utf8))
        XCTAssertNil(msg.sessionTitle)
    }
}
