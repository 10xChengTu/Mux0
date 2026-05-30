import XCTest
@testable import mux0

final class HookDispatcherSessionTitleTests: XCTestCase {

    private var tmpConfigPath: String!
    private var settings: SettingsConfigStore!
    private var statusStore: TerminalStatusStore!
    private var titleStore: TerminalSessionTitleStore!
    private let tid = UUID()

    override func setUpWithError() throws {
        tmpConfigPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("mux0-dispatch-\(UUID().uuidString).conf").path
        settings = SettingsConfigStore(filePath: tmpConfigPath)
        statusStore = TerminalStatusStore()
        titleStore = TerminalSessionTitleStore(persistenceKey: "test-\(UUID())")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: tmpConfigPath)
    }

    private func makeMsg(sessionTitle: String?) -> HookMessage {
        var fields = #"{"terminalId":"\#(tid.uuidString)","event":"running","agent":"claude","at":1.0"#
        if let t = sessionTitle {
            fields += #","sessionTitle":"\#(t)""#
        }
        fields += "}"
        return try! JSONDecoder().decode(HookMessage.self, from: Data(fields.utf8))
    }

    func testRoutesSessionTitleWhenAgentEnabled() {
        settings.set(HookMessage.Agent.claude.settingsKey, "true")
        settings.save()
        HookDispatcher.dispatch(makeMsg(sessionTitle: "Doing the thing"),
                                settings: settings, store: statusStore,
                                sessionTitleStore: titleStore)
        XCTAssertEqual(titleStore.title(for: tid), "Doing the thing")
    }

    func testRoutesSessionTitleEvenWhenStatusAgentDisabled() {
        // Title is independent of the per-agent "status notifications" toggle —
        // tab naming is unconditional once the field arrives.
        // (No settings.set — agent NOT enabled.)
        HookDispatcher.dispatch(makeMsg(sessionTitle: "Still applies"),
                                settings: settings, store: statusStore,
                                sessionTitleStore: titleStore)
        XCTAssertEqual(titleStore.title(for: tid), "Still applies")
    }

    func testSkipsWhenSessionTitleNil() {
        settings.set(HookMessage.Agent.claude.settingsKey, "true")
        settings.save()
        titleStore.update(terminalId: tid, title: "Previous", at: 1)
        HookDispatcher.dispatch(makeMsg(sessionTitle: nil),
                                settings: settings, store: statusStore,
                                sessionTitleStore: titleStore)
        XCTAssertEqual(titleStore.title(for: tid), "Previous",
                       "nil sessionTitle should not clobber existing value")
    }
}
