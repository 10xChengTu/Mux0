import Foundation

/// Pure resolver for the shell command auto-injected into a freshly created
/// ghostty surface. Mirrors the precedence rules previously inlined in
/// `TabContentView.resolvedStartupCommand(forTerminal:)`.
///
/// Source order:
///   0. Quick action tab's first terminal:
///      0a. If the action id is a builtin agent (claude / codex / opencode),
///          the agent's Resume toggle is on, AND `pendingPrefill` is a
///          matching `<agent> --resume <id>` (or `codex resume <id>` /
///          `opencode --session <id>`)
///          string → return the prefill verbatim. The agent equality guard
///          prevents a stale prefill written by a different agent from
///          being replayed here. User overrides of the builtin command
///          (e.g. `claude --debug`) are intentionally bypassed: the resume
///          command is the agent's canonical CLI form, and a user who
///          turned Resume on expects continuity.
///      0b. Otherwise → return `"<quickActionCommand>\n"` (built-in default
///          or user override).
///   1. Pending agent resume command (`claude --resume <id>` /
///      `codex resume <id>` / `opencode --session <id>`) — only when the
///      matching agent's Resume toggle is on. Default OFF means stale
///      UserDefaults entries are ignored, not replayed.
///   2. Workspace-level `defaultCommand`.
///
/// Inputs are passed explicitly (rather than wiring up real stores) so the
/// resolver can be unit-tested without bringing up an NSView, WorkspaceStore,
/// SettingsConfigStore, or QuickActionsStore.
enum StartupCommandResolver {
    static func resolve(
        terminalId: UUID,
        tab: TerminalTab?,
        workspaceDefaultCommand: String?,
        quickActionCommand: (QuickActionId) -> String?,
        isResumeEnabled: (HookMessage.Agent) -> Bool,
        pendingPrefill: String?
    ) -> String? {
        // (0) Quick action tab's first terminal.
        if let tab,
           let actionId = tab.quickActionId,
           terminalId == tab.layout.allTerminalIds().first {

            // (0a) If this Quick Action is a builtin agent, the agent's
            //      Resume toggle is on, AND we have a stored prefill whose
            //      leading CLI token matches the same agent → replay that
            //      `<agent> --resume <id>` instead of the bare command.
            //      The agent equality guard prevents a stale prefill written
            //      by a different agent from being replayed here.
            if let agent = HookMessage.Agent(rawValue: actionId),
               isResumeEnabled(agent),
               let pending = pendingPrefill,
               HookMessage.Agent.fromResumeCommand(pending) == agent {
                return pending
            }

            // (0b) Fallback: original Quick Action command (built-in default
            //      or user override).
            if let cmd = quickActionCommand(actionId) {
                return "\(cmd)\n"
            }
        }

        // (1) Agent resume — naked terminal path.
        if let pending = pendingPrefill,
           let agent = HookMessage.Agent.fromResumeCommand(pending),
           isResumeEnabled(agent) {
            return pending
        }

        // (2) Workspace default command.
        return workspaceDefaultCommand
    }
}
