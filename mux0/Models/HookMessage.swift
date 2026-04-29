import Foundation

/// Message sent by an agent hook (Claude Code / Codex / OpenCode wrapper) to the
/// mux0 Unix socket. Format: one message per newline, UTF-8 JSON.
struct HookMessage: Decodable, Equatable {
    enum Event: String, Decodable {
        case running
        case idle
        case needsInput
        case finished
    }

    enum Agent: String, Decodable, CaseIterable, Identifiable {
        case claude
        case opencode
        case codex

        var id: String { rawValue }

        /// Config key used by Settings → Agents and by the listener filter.
        var settingsKey: String { "mux0-agent-status-\(rawValue)" }
    }

    let terminalId: UUID
    let event: Event
    let agent: Agent
    let at: TimeInterval
    /// Present when `event == .finished`. Nil for other events.
    /// `0` = clean turn, `1` = turn had at least one tool error.
    let exitCode: Int32?
    /// Optional running-state detail — e.g. "Edit Models/Foo.swift".
    /// Present when Claude/Codex `PreToolUse` or OpenCode `tool.execute.before`
    /// captures a tool name + inputs.
    let toolDetail: String?
    /// Optional finished-state summary (e.g. last assistant message, ≤200 chars).
    /// Present when Claude/Codex Stop reads transcript; nil otherwise.
    let summary: String?
    /// Optional resume command (e.g. `claude --resume <session_id>`,
    /// `codex resume <session_id>`). Emitted on the `running` events
    /// triggered by `UserPromptSubmit`; mux0 records the most-recent value
    /// per terminal and replays it as the next-launch shell input.
    let resumeCommand: String?

    var timestamp: Date { Date(timeIntervalSince1970: at) }
}

extension HookMessage.Agent {
    /// Human-readable name for tooltips and log messages.
    var displayName: String {
        switch self {
        case .claude:   return "Claude"
        case .opencode: return "OpenCode"
        case .codex:    return "Codex"
        }
    }

    /// Localized label for the Settings → Agents row.
    var label: LocalizedStringResource {
        switch self {
        case .claude:   return L10n.Settings.Agents.claude
        case .opencode: return L10n.Settings.Agents.opencode
        case .codex:    return L10n.Settings.Agents.codex
        }
    }
}
