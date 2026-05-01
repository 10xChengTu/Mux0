import SwiftUI

struct AgentsSectionView: View {
    let theme: AppTheme
    let settings: SettingsConfigStore
    let workspaceStore: WorkspaceStore

    /// Every config key this section manages — both notification toggles
    /// (all agents) and resume toggles (claude/codex only). Used by the
    /// "Restore Defaults" reset row to clear them in one shot.
    private static let managedKeys: [String] = {
        let status = HookMessage.Agent.allCases.map(\.settingsKey)
        let resume = HookMessage.Agent.allCases.filter(\.supportsResume).map(\.resumeSettingsKey)
        return status + resume
    }()

    /// Codex hooks are gated behind an experimental flag (`[features].codex_hooks = true`
    /// in `~/.codex/config.toml`). The wrapper can't flip it for the user — the flag
    /// must live in the user's main config. See docs/agent-hooks.md.
    @State private var showingCodexAlert = false
    @Environment(\.locale) private var locale

    var body: some View {
        Form {
            // ForEach + Section under Form(.grouped) on macOS 26.4 has a
            // layout quirk: the 3rd ForEach row gets ejected from the
            // section card (the first two render with shared rounded
            // background, the third loses it). Listing rows explicitly
            // sidesteps it. Same expansion rule applies to future agents
            // — the array literal stays the single source of truth.
            Section {
                AgentToggleRow(theme: theme, settings: settings, agent: .claude)
                AgentToggleRow(theme: theme, settings: settings, agent: .opencode)
                AgentToggleRow(theme: theme, settings: settings, agent: .codex)
            } header: {
                Text(L10n.Settings.Agents.notificationsTitle)
            } footer: {
                Text(L10n.Settings.Agents.notificationsFooter)
                    .font(Font(DT.Font.small))
                    .foregroundColor(Color(theme.textTertiary))
            }

            Section {
                AgentResumeToggleRow(theme: theme, settings: settings,
                                     workspaceStore: workspaceStore, agent: .claude)
                AgentResumeToggleRow(theme: theme, settings: settings,
                                     workspaceStore: workspaceStore, agent: .opencode)
                AgentResumeToggleRow(theme: theme, settings: settings,
                                     workspaceStore: workspaceStore, agent: .codex)
            } header: {
                Text(L10n.Settings.Agents.resumeTitle)
            } footer: {
                Text(L10n.Settings.Agents.resumeFooter)
                    .font(Font(DT.Font.small))
                    .foregroundColor(Color(theme.textTertiary))
            }

            SettingsResetRow(
                settings: settings,
                keys: Self.managedKeys,
                additionalAction: {
                    // pendingPrefills are read non-destructively, so wiping
                    // the resume toggle keys alone would leave them in
                    // place and replay on the next launch when the user
                    // re-enables Resume. Mirror the per-row OFF transition
                    // here for every resume-capable agent.
                    for agent in HookMessage.Agent.allCases where agent.supportsResume {
                        workspaceStore.clearResumePrefills(forAgent: agent)
                    }
                }
            )
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .alert(
            String(localized: L10n.Settings.Agents.codexAlertTitle.withLocale(locale)),
            isPresented: $showingCodexAlert
        ) {
            Button(String(localized: L10n.Settings.Agents.codexAlertOK.withLocale(locale))) { }
        } message: {
            Text(L10n.Settings.Agents.codexAlertMessage)
        }
        .onReceive(NotificationCenter.default.publisher(for: .mux0CodexHookAlert)) { _ in
            showingCodexAlert = true
        }
    }
}

/// Notifications row: per-agent label + BETA badge + status toggle.
/// All rows share an identical view signature — Codex's experimental-flag
/// alert is fired via NotificationCenter from inside the binding setter so
/// the row struct doesn't need a per-agent callback parameter (which would
/// cause Form(.grouped) to split that row out into its own card).
private struct AgentToggleRow: View {
    let theme: AppTheme
    let settings: SettingsConfigStore
    let agent: HookMessage.Agent

    var body: some View {
        LabeledContent {
            Toggle("", isOn: binding)
                .labelsHidden()
                .toggleStyle(.switch)
        } label: {
            HStack(spacing: DT.Space.sm) {
                Text(agent.label)
                // Codex hooks ride an experimental flag in the user's
                // ~/.codex/config.toml, so we keep the BETA badge there as a
                // discoverability cue. Claude/OpenCode are stable.
                if agent == .codex {
                    BetaBadge(theme: theme)
                }
            }
        }
    }

    private var binding: Binding<Bool> {
        Binding(
            get: {
                guard let raw = settings.get(agent.settingsKey) else { return false }
                return raw.lowercased() == "true"
            },
            set: { newValue in
                let wasOn = settings.get(agent.settingsKey)?.lowercased() == "true"
                settings.set(agent.settingsKey, newValue ? "true" : nil)
                if newValue && !wasOn && agent == .codex {
                    NotificationCenter.default.post(name: .mux0CodexHookAlert, object: nil)
                }
            }
        )
    }
}

/// Resume row: same shape as the notifications row, but the off-transition
/// also drops every saved resume command for this agent so the change takes
/// effect at the very next launch.
private struct AgentResumeToggleRow: View {
    let theme: AppTheme
    let settings: SettingsConfigStore
    let workspaceStore: WorkspaceStore
    let agent: HookMessage.Agent

    var body: some View {
        LabeledContent {
            Toggle("", isOn: binding)
                .labelsHidden()
                .toggleStyle(.switch)
        } label: {
            Text(agent.label)
        }
    }

    private var binding: Binding<Bool> {
        Binding(
            get: {
                guard let raw = settings.get(agent.resumeSettingsKey) else { return false }
                return raw.lowercased() == "true"
            },
            set: { newValue in
                settings.set(agent.resumeSettingsKey, newValue ? "true" : nil)
                if !newValue { workspaceStore.clearResumePrefills(forAgent: agent) }
            }
        )
    }
}

private struct BetaBadge: View {
    let theme: AppTheme

    var body: some View {
        Text(L10n.Settings.Agents.betaBadge)
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(Color(theme.accent))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(Color(theme.accent).opacity(0.6), lineWidth: 1)
            )
    }
}
