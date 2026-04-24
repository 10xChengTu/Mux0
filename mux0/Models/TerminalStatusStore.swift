import Foundation
import Observation

/// In-memory-only per-terminal status. Lives for app session; app restart wipes all
/// entries. Mutations happen on the main queue (signal path from the hook listener
/// hops back to main before calling these setters).
@Observable
final class TerminalStatusStore {
    private var storage: [UUID: TerminalStatus] = [:]

    init() {}

    func status(for terminalId: UUID) -> TerminalStatus {
        storage[terminalId] ?? .neverRan
    }

    func setRunning(terminalId: UUID, at startedAt: Date, detail: String? = nil) {
        guard !isStale(terminalId: terminalId, at: startedAt) else { return }
        // Preserve the original startedAt when we were already running — subsequent
        // PreToolUse / tool.execute.before hooks within a single agent turn arrive
        // with later timestamps, but duration should run from the turn's first
        // transition into running, not from the current tool.
        let effectiveStart: Date
        if case .running(let prev, _) = storage[terminalId] {
            effectiveStart = prev
        } else {
            effectiveStart = startedAt
        }
        storage[terminalId] = .running(startedAt: effectiveStart, detail: detail)
    }

    func setFinished(terminalId: UUID, exitCode: Int32, at finishedAt: Date,
                     agent: HookMessage.Agent, summary: String? = nil) {
        guard !isStale(terminalId: terminalId, at: finishedAt) else { return }
        let duration: TimeInterval
        if case .running(let startedAt, _) = storage[terminalId] {
            duration = max(0, finishedAt.timeIntervalSince(startedAt))
        } else {
            duration = 0
        }
        if exitCode == 0 {
            storage[terminalId] = .success(exitCode: exitCode, duration: duration,
                                           finishedAt: finishedAt,
                                           agent: agent, summary: summary)
        } else {
            storage[terminalId] = .failed(exitCode: exitCode, duration: duration,
                                          finishedAt: finishedAt,
                                          agent: agent, summary: summary)
        }
    }

    func setIdle(terminalId: UUID, at since: Date) {
        guard !isStale(terminalId: terminalId, at: since) else { return }
        storage[terminalId] = .idle(since: since)
    }

    func setNeedsInput(terminalId: UUID, at since: Date) {
        guard !isStale(terminalId: terminalId, at: since) else { return }
        storage[terminalId] = .needsInput(since: since)
    }

    /// Reject events older than the current state. Agent hooks fork `hook-emit.sh`
    /// with `&!`, so two near-simultaneous socket connects can race and arrive out
    /// of order. Each event's timestamp is captured synchronously before the fork,
    /// giving us a reliable fire-order proxy regardless of which socket connect
    /// wins. This guard keeps the spinner from sticking when an older `running`
    /// lands after a newer `idle`.
    private func isStale(terminalId: UUID, at: Date) -> Bool {
        guard let cur = currentTimestamp(for: terminalId) else { return false }
        return at < cur
    }

    private func currentTimestamp(for terminalId: UUID) -> Date? {
        switch storage[terminalId] {
        case .none, .neverRan:                     return nil
        case .running(let at, _):                  return at
        case .idle(let at):                        return at
        case .needsInput(let at):                  return at
        case .success(_, _, let at, _, _, _):      return at
        case .failed(_, _, let at, _, _, _):       return at
        }
    }

    /// Drop the entry (e.g. when the terminal is closed). Subsequent reads return `.neverRan`.
    func forget(terminalId: UUID) {
        storage.removeValue(forKey: terminalId)
    }

    /// Mark entries as "read" by stamping `readAt` on any `.success` / `.failed`
    /// with `readAt == nil`. Idempotent: entries already read keep their original
    /// readAt. Ids not matching `.success` / `.failed` (or not in storage) are
    /// no-ops. Called from `ContentView` when the user switches workspaces/tabs
    /// so on-screen terminal-state dots fade from solid to hollow.
    func markRead(terminalIds: [UUID], at now: Date = Date()) {
        for id in terminalIds {
            switch storage[id] {
            case .success(let ec, let dur, let fa, let agent, let summary, nil):
                storage[id] = .success(exitCode: ec, duration: dur, finishedAt: fa,
                                        agent: agent, summary: summary, readAt: now)
            case .failed(let ec, let dur, let fa, let agent, let summary, nil):
                storage[id] = .failed(exitCode: ec, duration: dur, finishedAt: fa,
                                       agent: agent, summary: summary, readAt: now)
            default:
                continue
            }
        }
    }

    /// Aggregate over a bag of ids using priority running > failed > success > neverRan.
    func aggregateStatus(terminalIds: [UUID]) -> TerminalStatus {
        TerminalStatus.aggregate(terminalIds.map { status(for: $0) })
    }

    /// Copy of the whole map. Used by bridges to push status dicts into AppKit views.
    func statusesSnapshot() -> [UUID: TerminalStatus] {
        storage
    }
}
