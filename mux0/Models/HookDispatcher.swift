import Foundation

/// Stateless filter + fanout from `HookMessage` to `TerminalStatusStore`.
///
/// Extracted out of `ContentView.onMessage` so the per-agent gate can be
/// unit-tested without plumbing an in-process Unix socket. The listener still
/// owns the socket and the main-hop; it calls `dispatch` with each decoded
/// message.
///
/// Filter policy: a message is forwarded iff the user has enabled its agent
/// in Settings → Agents (per-agent key `mux0-agent-status-<rawValue>` == "true").
/// Missing or any non-"true" value = disabled. Shell is not representable —
/// the enum no longer has `.shell`, and the socket listener's JSONDecoder
/// drops stray shell-agent payloads before they reach this function.
enum HookDispatcher {
    static func dispatch(_ msg: HookMessage,
                         settings: SettingsConfigStore,
                         store: TerminalStatusStore) {
        guard settings.get(msg.agent.settingsKey) == "true" else { return }
        switch msg.event {
        case .running:
            store.setRunning(terminalId: msg.terminalId,
                             at: msg.timestamp,
                             detail: msg.toolDetail)
        case .idle:
            // codex-wrapper always writes `notify = [..., "idle", "codex"]` to
            // the overlay config.toml, which fires an `idle` on every turn
            // completion. When the user also has `features.codex_hooks = true`,
            // the Stop hook fires `finished` (with exitCode) at the same point,
            // and the two socket writes race: the notify-driven `idle` often
            // arrives after the Stop-driven `finished` and would overwrite the
            // success/failed state with a neutral idle. Claude's SessionEnd
            // shares the same shape (Stop emits `finished`, SessionEnd emits
            // `idle`). Keep the informative terminal state; the next
            // UserPromptSubmit will move things back to `.running`.
            switch store.status(for: msg.terminalId) {
            case .success, .failed: return
            default: break
            }
            store.setIdle(terminalId: msg.terminalId, at: msg.timestamp)
        case .needsInput:
            // Claude Code's Notification hook fires for two reasons: a real
            // permission request during a live turn, or a 60-second idle
            // heartbeat after the turn has ended. Only promote to needsInput
            // while the terminal is still running — otherwise the heartbeat
            // would overwrite a terminal success/failed one minute later.
            if case .running = store.status(for: msg.terminalId) {
                store.setNeedsInput(terminalId: msg.terminalId, at: msg.timestamp)
            }
        case .finished:
            // hook-emit.sh degrades malformed `finished` to `idle` before it
            // reaches us; this guard is defense in depth.
            guard let ec = msg.exitCode else { return }
            store.setFinished(terminalId: msg.terminalId, exitCode: ec,
                              at: msg.timestamp, agent: msg.agent,
                              summary: msg.summary)
        }
    }
}

/// Master UI gate: is the status indicator column visible anywhere?
///
/// True iff the user has enabled at least one agent in Settings → Agents.
/// All other downstream plumbing (`SidebarListBridge.showStatusIndicators`,
/// `TabBridge.showStatusIndicators`, icon rendering) continues to consume a
/// single Bool — this helper is its authoritative source.
enum StatusIndicatorGate {
    static func anyAgentEnabled(_ settings: SettingsConfigStore) -> Bool {
        HookMessage.Agent.allCases.contains { agent in
            settings.get(agent.settingsKey) == "true"
        }
    }
}
