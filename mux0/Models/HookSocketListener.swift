import Foundation
import Darwin
import CryptoKit

/// Unix domain socket server that receives newline-delimited JSON hook messages
/// from shell/agent wrappers and dispatches them to `onMessage`.
///
/// Lifetime: create once per app, call `start()` at launch, `stop()` at termination.
/// The listener runs on its own background queue; `onMessage` is called on main.
final class HookSocketListener {
    let path: String
    var onMessage: ((HookMessage) -> Void)?

    private var listenFd: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clientSources: [Int32: DispatchSourceRead] = [:]
    private var clientBuffers: [Int32: Data] = [:]
    private let queue = DispatchQueue(label: "mux0.hookSocket", qos: .userInitiated)

    init(path: String) throws {
        self.path = path
    }

    func start() throws {
        // Ensure parent dir exists
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Remove stale socket file
        unlink(path)

        listenFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFd >= 0 else {
            throw NSError(domain: "HookSocketListener", code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "socket() failed"])
        }

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
        let bindOK = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listenFd, $0, size)
            }
        }
        guard bindOK == 0 else {
            close(listenFd); listenFd = -1
            throw NSError(domain: "HookSocketListener", code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "bind() failed"])
        }

        guard Darwin.listen(listenFd, 32) == 0 else {
            close(listenFd); listenFd = -1
            throw NSError(domain: "HookSocketListener", code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "listen() failed"])
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: listenFd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClient() }
        source.setCancelHandler { [weak self] in
            if let self, self.listenFd >= 0 { close(self.listenFd); self.listenFd = -1 }
        }
        source.resume()
        acceptSource = source
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        clientSources.values.forEach { $0.cancel() }
        clientSources.removeAll()
        clientBuffers.removeAll()
        unlink(path)
    }

    private func acceptClient() {
        let client = Darwin.accept(listenFd, nil, nil)
        guard client >= 0 else { return }
        clientBuffers[client] = Data()

        let src = DispatchSource.makeReadSource(fileDescriptor: client, queue: queue)
        src.setEventHandler { [weak self] in self?.readClient(fd: client) }
        src.setCancelHandler { [weak self] in
            close(client)
            self?.clientBuffers.removeValue(forKey: client)
            self?.clientSources.removeValue(forKey: client)
        }
        clientSources[client] = src
        src.resume()
    }

    private func readClient(fd: Int32) {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &buf, buf.count)
        if n <= 0 {
            clientSources[fd]?.cancel()
            return
        }
        clientBuffers[fd, default: Data()].append(buf, count: n)
        flushBuffer(fd: fd)
    }

    private func flushBuffer(fd: Int32) {
        guard var buf = clientBuffers[fd] else { return }
        while let newlineIdx = buf.firstIndex(of: 0x0a) {
            let line = buf.subdata(in: 0..<newlineIdx)
            buf.removeSubrange(0...newlineIdx)
            guard !line.isEmpty else { continue }
            if let msg = try? JSONDecoder().decode(HookMessage.self, from: line) {
                DispatchQueue.main.async { [weak self] in self?.onMessage?(msg) }
            }
            // Decode failure = silent drop. Hook scripts are our own code; garbled
            // input means someone else is writing to our socket → ignore.
        }
        clientBuffers[fd] = buf
    }

    deinit { stop() }
}

extension HookSocketListener {
    /// Default socket path, namespaced per install bundle:
    /// `~/Library/Caches/mux0/hooks-<bundle-hash>.sock` where `<bundle-hash>`
    /// is the first 8 hex chars of SHA256(Bundle.main.bundlePath).
    ///
    /// Keeps Release (/Applications/mux0.app) and Debug (Xcode DerivedData)
    /// builds on separate sockets so they don't hijack each other's hook
    /// stream when run simultaneously. macOS blocks double-launching the same
    /// bundle, so same-path collisions aren't a concern in practice.
    static var defaultPath: String {
        socketPath(forBundlePath: Bundle.main.bundlePath)
    }

    /// Deterministic hash-based path derivation. Exposed for tests.
    static func socketPath(forBundlePath bundlePath: String) -> String {
        let cache = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Caches/mux0")
        let digest = SHA256.hash(data: Data(bundlePath.utf8))
        let hash8 = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return (cache as NSString).appendingPathComponent("hooks-\(hash8).sock")
    }
}
