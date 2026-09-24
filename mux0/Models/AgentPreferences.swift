import Foundation

/// First-run preference migration for agents whose hook layer shipped in a
/// newer app version.
///
/// Why: `Settings → Agents` notification toggles are opt-in (missing key = off,
/// see `docs/settings-reference.md`). If a new agent simply appeared, a user who
/// already runs Claude/Codex with status icons would still have to discover the
/// two new rows by hand — the integration would look like it didn't ship. So on
/// the first launch after an upgrade we switch the new agents on, but ONLY for
/// users who already turned at least one agent on (a fresh install keeps the
/// documented "all off" default) and ONLY once per agent (the seen-list means a
/// toggle the user later turns off stays off).
///
/// Resume toggles are deliberately excluded: they persist session ids to disk,
/// so they stay opt-in (default OFF) for every agent, new or old.
enum AgentPreferences {
    /// Raw values of every agent this install has already been shown.
    static let seenKey = "mux0-agent-status-seen"

    /// Agents that existed before the seen-list was introduced. 0.8.5 added pi
    /// and grok; an install upgrading from ≤0.8.4 has no seen-list, so this is
    /// the "already known" baseline. Later releases only have to extend
    /// `HookMessage.Agent.allCases` — from then on the seen-list carries the
    /// information and this list never has to change again.
    static let preSeenListAgents: [HookMessage.Agent] = [.claude, .opencode, .codex]

    /// Returns the agents this call switched on (empty when nothing changed).
    @discardableResult
    static func migrate(settings: SettingsConfigStore) -> [HookMessage.Agent] {
        let known = knownSeen(settings)
        let fresh = HookMessage.Agent.allCases.filter { !known.contains($0) }

        let previouslyEnabled = HookMessage.Agent.allCases
            .filter { settings.get($0.settingsKey) == "true" }
        var switchedOn: [HookMessage.Agent] = []
        if !fresh.isEmpty && !previouslyEnabled.isEmpty {
            for agent in fresh {
                settings.set(agent.settingsKey, "true")
                switchedOn.append(agent)
            }
        }
        saveSeen(previous: known, settings: settings)
        return switchedOn
    }

    private static func knownSeen(_ settings: SettingsConfigStore) -> Set<HookMessage.Agent> {
        guard let raw = settings.get(seenKey),
              let data = raw.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data) else {
            return Set(preSeenListAgents)
        }
        return Set(values.compactMap { HookMessage.Agent(rawValue: $0) })
    }

    private static func saveSeen(previous: Set<HookMessage.Agent>,
                                 settings: SettingsConfigStore) {
        var all = previous
        all.formUnion(HookMessage.Agent.allCases)
        // Persist in allCases order so the config line stays readable.
        let ordered = HookMessage.Agent.allCases.filter { all.contains($0) }.map(\.rawValue)
        guard let data = try? JSONEncoder().encode(ordered),
              let raw = String(data: data, encoding: .utf8) else { return }
        settings.set(seenKey, raw)
    }
}
