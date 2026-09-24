import AppKit
import XCTest
@testable import mux0

final class QuickActionTests: XCTestCase {
    func test_builtinAllCases_haveSixEntries() {
        XCTAssertEqual(BuiltinQuickAction.allCases.count, 6)
        XCTAssertEqual(Set(BuiltinQuickAction.allCases.map(\.id)),
                       Set(["gitui", "claude", "codex", "opencode", "pi", "grok"]))
    }

    func test_builtinDefaultCommands_matchId() {
        XCTAssertEqual(BuiltinQuickAction.gitui.defaultCommand, "gitui")
        XCTAssertEqual(BuiltinQuickAction.claude.defaultCommand, "claude")
        XCTAssertEqual(BuiltinQuickAction.codex.defaultCommand, "codex")
        XCTAssertEqual(BuiltinQuickAction.opencode.defaultCommand, "opencode")
        XCTAssertEqual(BuiltinQuickAction.pi.defaultCommand, "pi")
        XCTAssertEqual(BuiltinQuickAction.grok.defaultCommand, "grok")
    }

    func test_builtinAgentIds_matchHookMessageAgentRawValues() {
        // StartupCommandResolver maps a Quick Action id straight to
        // HookMessage.Agent(rawValue:), so the two namespaces must agree.
        for agent in HookMessage.Agent.allCases {
            XCTAssertNotNil(BuiltinQuickAction.from(id: agent.rawValue),
                            "builtin quick action missing for agent \(agent.rawValue)")
        }
    }

    func test_customAction_codableRoundTrip() throws {
        let original = CustomQuickAction(id: "abc-123", name: "htop", command: "htop -H")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CustomQuickAction.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func test_quickActionIcon_sfSymbolForGitui() {
        guard case .sfSymbol(let name) = BuiltinQuickAction.gitui.iconSource else {
            XCTFail("gitui should be sfSymbol"); return
        }
        XCTAssertEqual(name, "arrow.branch")
    }

    func test_quickActionIcon_assetForPiAndGrok() {
        guard case .asset(let piName) = BuiltinQuickAction.pi.iconSource,
              case .asset(let grokName) = BuiltinQuickAction.grok.iconSource else {
            XCTFail("pi / grok should be asset icons"); return
        }
        XCTAssertEqual(piName, "quick-action-pi")
        XCTAssertEqual(grokName, "quick-action-grok")
        // The asset catalog must actually ship both, else the sidebar renders an
        // empty button and nothing fails at compile time.
        for name in [piName, grokName] {
            XCTAssertNotNil(NSImage(named: name), "missing asset \(name) in Assets.xcassets")
        }
    }

    func test_quickActionIcon_assetForClaude() {
        guard case .asset(let name) = BuiltinQuickAction.claude.iconSource else {
            XCTFail("claude should be asset"); return
        }
        XCTAssertEqual(name, "quick-action-claudecode")
    }
}
