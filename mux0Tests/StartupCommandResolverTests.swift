import XCTest
@testable import mux0

final class StartupCommandResolverTests: XCTestCase {
    // MARK: - Quick Action branch (unchanged after Task 2)

    func testQuickActionGitui_returnsNakedCommand() {
        let term = UUID()
        let tab = TerminalTab(title: "T", terminalId: term, quickActionId: "gitui")
        let result = StartupCommandResolver.resolve(
            terminalId: term,
            tab: tab,
            workspaceDefaultCommand: "should-not-fire",
            quickActionCommand: { _ in "gitui" },
            isResumeEnabled: { _ in true },
            pendingPrefill: "claude --resume abc"  // ignored: gitui isn't an agent
        )
        XCTAssertEqual(result, "gitui\n")
    }

    func testQuickActionClaude_noPrefill_returnsNakedClaude() {
        let term = UUID()
        let tab = TerminalTab(title: "T", terminalId: term, quickActionId: "claude")
        let result = StartupCommandResolver.resolve(
            terminalId: term,
            tab: tab,
            workspaceDefaultCommand: nil,
            quickActionCommand: { _ in "claude" },
            isResumeEnabled: { _ in true },
            pendingPrefill: nil
        )
        XCTAssertEqual(result, "claude\n")
    }

    func testQuickActionClaude_toggleOff_returnsNakedClaude() {
        let term = UUID()
        let tab = TerminalTab(title: "T", terminalId: term, quickActionId: "claude")
        let result = StartupCommandResolver.resolve(
            terminalId: term,
            tab: tab,
            workspaceDefaultCommand: nil,
            quickActionCommand: { _ in "claude" },
            isResumeEnabled: { _ in false },
            pendingPrefill: "claude --resume abc"
        )
        XCTAssertEqual(result, "claude\n")
    }

    // MARK: - Naked terminal Agent resume branch (must not regress)

    func testNakedTerminal_resumeOn_returnsPrefill() {
        let term = UUID()
        let tab = TerminalTab(title: "T", terminalId: term, quickActionId: nil)
        let result = StartupCommandResolver.resolve(
            terminalId: term,
            tab: tab,
            workspaceDefaultCommand: "default-cmd",
            quickActionCommand: { _ in nil },
            isResumeEnabled: { _ in true },
            pendingPrefill: "claude --resume abc"
        )
        XCTAssertEqual(result, "claude --resume abc")
    }

    func testNakedTerminal_resumeOff_returnsDefaultCommand() {
        let term = UUID()
        let tab = TerminalTab(title: "T", terminalId: term, quickActionId: nil)
        let result = StartupCommandResolver.resolve(
            terminalId: term,
            tab: tab,
            workspaceDefaultCommand: "default-cmd",
            quickActionCommand: { _ in nil },
            isResumeEnabled: { _ in false },
            pendingPrefill: "claude --resume abc"
        )
        XCTAssertEqual(result, "default-cmd")
    }

    func testNakedTerminal_noPrefill_returnsDefaultCommand() {
        let term = UUID()
        let tab = TerminalTab(title: "T", terminalId: term, quickActionId: nil)
        let result = StartupCommandResolver.resolve(
            terminalId: term,
            tab: tab,
            workspaceDefaultCommand: "default-cmd",
            quickActionCommand: { _ in nil },
            isResumeEnabled: { _ in true },
            pendingPrefill: nil
        )
        XCTAssertEqual(result, "default-cmd")
    }

    func testNakedTerminal_noPrefill_noDefault_returnsNil() {
        let term = UUID()
        let tab = TerminalTab(title: "T", terminalId: term, quickActionId: nil)
        let result = StartupCommandResolver.resolve(
            terminalId: term,
            tab: tab,
            workspaceDefaultCommand: nil,
            quickActionCommand: { _ in nil },
            isResumeEnabled: { _ in true },
            pendingPrefill: nil
        )
        XCTAssertNil(result)
    }

    // MARK: - Quick Action tab, non-first pane (split sibling)

    func testQuickActionTab_secondPane_fallsThroughToDefault() {
        let firstTerm = UUID()
        let secondTerm = UUID()
        // SplitNode.split is positional: (UUID, SplitDirection, CGFloat,
        // SplitNode, SplitNode).
        let layout: SplitNode = .split(
            UUID(),
            .horizontal,
            0.5,
            .terminal(firstTerm),
            .terminal(secondTerm)
        )
        var tab = TerminalTab(title: "T", terminalId: firstTerm, quickActionId: "claude")
        tab.layout = layout
        // resolve for the SECOND terminal — not the first leaf.
        let result = StartupCommandResolver.resolve(
            terminalId: secondTerm,
            tab: tab,
            workspaceDefaultCommand: "default-cmd",
            quickActionCommand: { _ in "claude" },
            isResumeEnabled: { _ in true },
            pendingPrefill: nil
        )
        XCTAssertEqual(result, "default-cmd")
    }

    // MARK: - Quick Action resume (Task 2)

    func testQuickActionClaude_resumeOn_matchingPrefill_returnsPrefill() {
        let term = UUID()
        let tab = TerminalTab(title: "T", terminalId: term, quickActionId: "claude")
        let result = StartupCommandResolver.resolve(
            terminalId: term,
            tab: tab,
            workspaceDefaultCommand: nil,
            quickActionCommand: { _ in "claude" },
            isResumeEnabled: { $0 == .claude },
            pendingPrefill: "claude --resume abc-123"
        )
        XCTAssertEqual(result, "claude --resume abc-123")
    }

    func testQuickActionClaude_resumeOn_mismatchedPrefill_returnsNakedClaude() {
        let term = UUID()
        let tab = TerminalTab(title: "T", terminalId: term, quickActionId: "claude")
        let result = StartupCommandResolver.resolve(
            terminalId: term,
            tab: tab,
            workspaceDefaultCommand: nil,
            quickActionCommand: { _ in "claude" },
            isResumeEnabled: { _ in true },
            // Cross-agent prefill must not be replayed: the (0a) agent
            // equality guard (`fromResumeCommand(pending) == agent`) is
            // what prevents this — without it, this test would return
            // the codex prefill instead of "claude\n".
            pendingPrefill: "codex resume xyz-789"
        )
        XCTAssertEqual(result, "claude\n")
    }

    func testQuickActionClaude_overrideCommand_resumeOn_returnsPrefill() {
        // User changed the builtin claude command to `claude --debug` AND
        // turned the Resume toggle on. Spec: resume wins, ignore override.
        let term = UUID()
        let tab = TerminalTab(title: "T", terminalId: term, quickActionId: "claude")
        let result = StartupCommandResolver.resolve(
            terminalId: term,
            tab: tab,
            workspaceDefaultCommand: nil,
            quickActionCommand: { _ in "claude --debug" },
            isResumeEnabled: { $0 == .claude },
            pendingPrefill: "claude --resume abc-123"
        )
        XCTAssertEqual(result, "claude --resume abc-123")
    }

    func testQuickActionCustomUUID_claudePrefill_returnsCustomCommand() {
        // Custom Quick Action id is a UUID string — `Agent(rawValue:)` fails,
        // so the resume branch must NOT fire for it.
        let term = UUID()
        let customId = UUID().uuidString
        let tab = TerminalTab(title: "T", terminalId: term, quickActionId: customId)
        let result = StartupCommandResolver.resolve(
            terminalId: term,
            tab: tab,
            workspaceDefaultCommand: nil,
            quickActionCommand: { _ in "my-script.sh" },
            isResumeEnabled: { _ in true },
            pendingPrefill: "claude --resume abc-123"
        )
        XCTAssertEqual(result, "my-script.sh\n")
    }

    func testQuickActionCodex_resumeOn_returnsCodexResumePrefill() {
        // Codex uses `codex resume <id>` (no double-dash). Verify both
        // builtin agents work, not just claude.
        let term = UUID()
        let tab = TerminalTab(title: "T", terminalId: term, quickActionId: "codex")
        let result = StartupCommandResolver.resolve(
            terminalId: term,
            tab: tab,
            workspaceDefaultCommand: nil,
            quickActionCommand: { _ in "codex" },
            isResumeEnabled: { $0 == .codex },
            pendingPrefill: "codex resume xyz-789"
        )
        XCTAssertEqual(result, "codex resume xyz-789")
    }

    func testQuickActionOpencode_resumeOn_returnsOpencodeSessionPrefill() {
        // Opencode uses `opencode --session <id>` (not `--resume`).
        // Confirms (0a) treats all three builtin agents symmetrically.
        let term = UUID()
        let tab = TerminalTab(title: "T", terminalId: term, quickActionId: "opencode")
        let result = StartupCommandResolver.resolve(
            terminalId: term,
            tab: tab,
            workspaceDefaultCommand: nil,
            quickActionCommand: { _ in "opencode" },
            isResumeEnabled: { $0 == .opencode },
            pendingPrefill: "opencode --session sess-42"
        )
        XCTAssertEqual(result, "opencode --session sess-42")
    }
}
