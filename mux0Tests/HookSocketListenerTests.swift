import XCTest
import Darwin
@testable import mux0

final class HookSocketListenerTests: XCTestCase {

    func testReceivesSingleMessage() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mux0-test-\(UUID().uuidString).sock")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let listener = try HookSocketListener(path: tmp.path)
        let received = XCTestExpectation(description: "message delivered")
        listener.onMessage = { msg in
            XCTAssertEqual(msg.event, .running)
            XCTAssertEqual(msg.agent, .claude)
            received.fulfill()
        }
        try listener.start()
        defer { listener.stop() }

        try sendViaUnixSocket(path: tmp.path,
            payload: #"{"terminalId":"\#(UUID().uuidString)","event":"running","agent":"claude","at":1}"# + "\n")

        wait(for: [received], timeout: 2)
    }

    func testMultipleMessagesOnSameConnection() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mux0-test-\(UUID().uuidString).sock")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let listener = try HookSocketListener(path: tmp.path)
        var count = 0
        let done = XCTestExpectation(description: "two messages")
        listener.onMessage = { _ in
            count += 1
            if count == 2 { done.fulfill() }
        }
        try listener.start()
        defer { listener.stop() }

        let tid = UUID().uuidString
        let payload =
            #"{"terminalId":"\#(tid)","event":"running","agent":"claude","at":1}"# + "\n" +
            #"{"terminalId":"\#(tid)","event":"idle","agent":"claude","at":2}"# + "\n"
        try sendViaUnixSocket(path: tmp.path, payload: payload)

        wait(for: [done], timeout: 2)
        XCTAssertEqual(count, 2)
    }

    // MARK: helper

    private func sendViaUnixSocket(path: String, payload: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "TestSocket", code: Int(errno)) }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { sunPathPtr in
                sunPathPtr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: sunPathPtr.pointee)) { dst in
                    strncpy(dst, src, MemoryLayout.size(ofValue: sunPathPtr.pointee) - 1)
                }
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, size)
            }
        }
        guard ok == 0 else { throw NSError(domain: "TestConnect", code: Int(errno)) }
        _ = payload.withCString { Darwin.send(fd, $0, strlen($0), 0) }
    }

    // MARK: - defaultPath / socketPath(forBundlePath:)

    func testSocketPathIsDeterministicForSameBundle() {
        let a = HookSocketListener.socketPath(forBundlePath: "/Applications/mux0.app")
        let b = HookSocketListener.socketPath(forBundlePath: "/Applications/mux0.app")
        XCTAssertEqual(a, b)
    }

    func testSocketPathDiffersAcrossBundles() {
        // Prod (/Applications) vs Debug (DerivedData) must not collide —
        // that's the whole point of bundle-path hashing.
        let prod = HookSocketListener.socketPath(forBundlePath: "/Applications/mux0.app")
        let debug = HookSocketListener.socketPath(
            forBundlePath: "/Users/me/Library/Developer/Xcode/DerivedData/mux0-abc/Build/Products/Debug/mux0.app")
        XCTAssertNotEqual(prod, debug)
    }

    func testSocketPathShape() {
        let p = HookSocketListener.socketPath(forBundlePath: "/Applications/mux0.app")
        XCTAssertTrue(p.hasSuffix(".sock"), "expected .sock suffix, got \(p)")
        let name = (p as NSString).lastPathComponent
        XCTAssertTrue(name.hasPrefix("hooks-"), "expected hooks- prefix, got \(name)")
        // hooks-<hash8>.sock → "hooks-" + 8 hex + ".sock" = 19 chars
        XCTAssertEqual(name.count, "hooks-".count + 8 + ".sock".count)
    }
}
