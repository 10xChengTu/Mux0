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
        XCTAssertEqual(HookMessage.Agent.allCases.count, 3)
        let raws = Set(HookMessage.Agent.allCases.map(\.rawValue))
        XCTAssertEqual(raws, ["claude", "opencode", "codex"])
        XCTAssertFalse(raws.contains("shell"))
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
}
