import XCTest
@testable import mux0

final class QuickActionTests: XCTestCase {
    func test_builtinAllCases_haveFourEntries() {
        XCTAssertEqual(BuiltinQuickAction.allCases.count, 4)
        XCTAssertEqual(Set(BuiltinQuickAction.allCases.map(\.id)),
                       Set(["gitui", "claude", "codex", "opencode"]))
    }

    func test_builtinDefaultCommands_matchId() {
        XCTAssertEqual(BuiltinQuickAction.gitui.defaultCommand, "gitui")
        XCTAssertEqual(BuiltinQuickAction.claude.defaultCommand, "claude")
        XCTAssertEqual(BuiltinQuickAction.codex.defaultCommand, "codex")
        XCTAssertEqual(BuiltinQuickAction.opencode.defaultCommand, "opencode")
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

    func test_quickActionIcon_assetForClaude() {
        guard case .asset(let name) = BuiltinQuickAction.claude.iconSource else {
            XCTFail("claude should be asset"); return
        }
        XCTAssertEqual(name, "quick-action-claudecode")
    }
}
