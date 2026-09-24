import XCTest
@testable import mux0

/// Covers `AgentPreferences.migrate` — the one-shot opt-in migration that turns
/// on status notifications for agents that shipped after the user already
/// started using the feature (0.8.5 added pi + grok).
final class AgentPreferencesTests: XCTestCase {
    private var tmpPath: String!
    private var settings: SettingsConfigStore!

    override func setUpWithError() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mux0-agentprefs-\(UUID().uuidString).conf")
        tmpPath = tmp.path
        settings = SettingsConfigStore(filePath: tmpPath)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: tmpPath)
    }

    func test_freshInstall_enablesNothing() {
        // No toggle keys at all → the user never opted in, so pi / grok stay off
        // (matching docs/settings-reference.md's documented defaults).
        let switched = AgentPreferences.migrate(settings: settings)
        XCTAssertTrue(switched.isEmpty)
        XCTAssertNil(settings.get(HookMessage.Agent.pi.settingsKey))
        XCTAssertNil(settings.get(HookMessage.Agent.grok.settingsKey))
    }

    func test_upgradeWithClaudeOn_switchesPiAndGrokOn() {
        settings.set(HookMessage.Agent.claude.settingsKey, "true")
        settings.save()

        let switched = AgentPreferences.migrate(settings: settings)
        XCTAssertEqual(Set(switched.map(\.rawValue)), ["pi", "grok"])
        XCTAssertEqual(settings.get(HookMessage.Agent.pi.settingsKey), "true")
        XCTAssertEqual(settings.get(HookMessage.Agent.grok.settingsKey), "true")
        // Untouched agents keep their value.
        XCTAssertEqual(settings.get(HookMessage.Agent.codex.settingsKey), nil)
    }

    func test_resumeTogglesAreNeverAutoEnabled() {
        settings.set(HookMessage.Agent.claude.settingsKey, "true")
        settings.save()
        _ = AgentPreferences.migrate(settings: settings)
        // Resume persists session ids to disk → always explicit opt-in.
        XCTAssertNil(settings.get(HookMessage.Agent.pi.resumeSettingsKey))
        XCTAssertNil(settings.get(HookMessage.Agent.grok.resumeSettingsKey))
    }

    func test_migrationRunsOnlyOncePerAgent() {
        settings.set(HookMessage.Agent.claude.settingsKey, "true")
        settings.save()
        XCTAssertEqual(AgentPreferences.migrate(settings: settings).count, 2)

        // User turns pi back off; a later launch must not flip it on again.
        settings.set(HookMessage.Agent.pi.settingsKey, nil)
        settings.save()
        let again = AgentPreferences.migrate(settings: settings)
        XCTAssertTrue(again.isEmpty, "seen-list must prevent re-enabling")
        XCTAssertNil(settings.get(HookMessage.Agent.pi.settingsKey))
    }

    func test_seenKeyRecordsEveryKnownAgent() {
        _ = AgentPreferences.migrate(settings: settings)
        let raw = try! XCTUnwrap(settings.get(AgentPreferences.seenKey))
        let seen = try! JSONDecoder().decode([String].self,
                                             from: raw.data(using: .utf8)!)
        XCTAssertEqual(Set(seen), Set(HookMessage.Agent.allCases.map(\.rawValue)))
    }

    func test_previouslyEnabledMeansTrueNotMerelyPresent() {
        // `codex = false` is an explicit opt-OUT, not evidence the user uses
        // the feature — nothing should be switched on.
        settings.set(HookMessage.Agent.codex.settingsKey, "false")
        settings.save()
        XCTAssertTrue(AgentPreferences.migrate(settings: settings).isEmpty)
        XCTAssertNil(settings.get(HookMessage.Agent.grok.settingsKey))
    }

    func test_statusIndicatorGateSeesMigratedAgents() {
        settings.set(HookMessage.Agent.opencode.settingsKey, "true")
        settings.save()
        _ = AgentPreferences.migrate(settings: settings)
        settings.save()
        XCTAssertTrue(StatusIndicatorGate.anyAgentEnabled(settings))
    }
}
