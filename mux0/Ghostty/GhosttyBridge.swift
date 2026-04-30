import Foundation
import AppKit

/// Singleton wrapper around the libghostty app instance.
/// Must call `GhosttyBridge.shared.initialize()` once at app startup.
final class GhosttyBridge {
    static let shared = GhosttyBridge()

    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?
    private(set) var isInitialized = false

    /// Called from the main queue whenever ghostty reports a surface's PWD (driven
    /// by OSC 7 from shell-integration). Wired from ContentView → TerminalPwdStore.
    /// Stored on the singleton because the C action callback is `@convention(c)`
    /// and can only reach Swift state through the shared instance.
    var onPwdChanged: ((UUID, String) -> Void)?

    /// When true, `writeClipboardCallback` skips writing to `NSPasteboard.general`.
    /// Set by `GhosttyTerminalView.makeFrontmost` during workspace/tab switches to
    /// prevent ghostty from syncing its internal selection into the system clipboard.
    static var suppressClipboardWrites = false

    private init() {}

    /// Returns true on success. Call once from mux0App.init().
    @discardableResult
    func initialize() -> Bool {
        // ghostty_init must be called before anything else
        let argc = CommandLine.argc
        let rawArgv = CommandLine.unsafeArgv
        guard ghostty_init(UInt(argc), rawArgv) == 0 else {
            print("[GhosttyBridge] ghostty_init failed")
            return false
        }

        // Export mux0-only env vars once at startup. These survive config reloads
        // because setenv writes to the process env; we never unset them.
        exportEnvVars()

        guard let cfg = buildConfig() else {
            print("[GhosttyBridge] buildConfig failed")
            return false
        }
        self.config = cfg

        // Build runtime callbacks — use @convention(c) static functions
        var rtConfig = ghostty_runtime_config_s()
        rtConfig.userdata = Unmanaged.passUnretained(self).toOpaque()
        rtConfig.supports_selection_clipboard = false
        rtConfig.wakeup_cb = GhosttyBridge.wakeupCallback
        rtConfig.action_cb = GhosttyBridge.actionCallback
        rtConfig.close_surface_cb = GhosttyBridge.closeSurfaceCallback
        rtConfig.read_clipboard_cb = GhosttyBridge.readClipboardCallback
        rtConfig.confirm_read_clipboard_cb = GhosttyBridge.confirmReadClipboardCallback
        rtConfig.write_clipboard_cb = GhosttyBridge.writeClipboardCallback

        guard let appHandle = ghostty_app_new(&rtConfig, cfg) else {
            print("[GhosttyBridge] ghostty_app_new failed")
            return false
        }
        self.app = appHandle
        self.isInitialized = true
        return true
    }

    func teardown() {
        if let a = app { ghostty_app_free(a) }
        if let c = config { ghostty_config_free(c) }
        app = nil
        config = nil
        isInitialized = false
    }

    // MARK: - Config build / reload

    /// Build a fresh `ghostty_config_t` from all sources (default ghostty files,
    /// recursive includes, bundled resources-dir, resolved theme file, mux0
    /// override). Always finalized. Returns nil only if `ghostty_config_new`
    /// itself failed. Caller owns the returned handle.
    private func buildConfig() -> ghostty_config_t? {
        guard let cfg = ghostty_config_new() else { return nil }
        ghostty_config_load_default_files(cfg)

        // mux0 内置默认值（覆盖 ghostty 自己的 default，但允许用户 ghostty config
        // 和 mux0 override 继续覆盖它们）。放在 default_files 之后、recursive_files
        // 之前，让 ~/.config/ghostty/config 仍可生效。
        let cacheDir = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Caches/mux0")
        try? FileManager.default.createDirectory(
            atPath: cacheDir,
            withIntermediateDirectories: true
        )
        let mux0DefaultsPath = (cacheDir as NSString).appendingPathComponent("mux0-defaults.conf")
        // `cursor-style-blink` 在 ghostty 里是三态 (?bool)：未设时由 shell 通过
        // DECSCUSR 请求决定，绝大多数 shell 会让光标闪烁。mux0 的设置 UI 把它展示
        // 为开关（默认 off）且文档承诺默认不闪，所以这里把未设等价到 `false`。
        // 用户在 GUI 打开开关会写 override 覆盖本行，用户自己的 ghostty config
        // 也能覆盖（load_recursive_files 发生在本默认层之后）。
        let mux0Defaults = """
        window-padding-x = 4
        window-padding-y = 4
        cursor-style-blink = false
        """
        try? mux0Defaults.write(toFile: mux0DefaultsPath, atomically: true, encoding: .utf8)
        mux0DefaultsPath.withCString { ghostty_config_load_file(cfg, $0) }

        ghostty_config_load_recursive_files(cfg)

        // Tell libghostty where to find bundled resources (shell-integration scripts,
        // terminfo, etc). Without this, OSC 133 injection can't happen: ghostty won't
        // auto-inject the shell hooks into zsh/bash/fish on surface start.
        // ghostty C API 没有 ghostty_config_load_string，使用临时文件 fallback。
        if let resourcesPath = Bundle.main.resourcePath {
            let ghosttyDir = (resourcesPath as NSString).appendingPathComponent("ghostty")
            if FileManager.default.fileExists(atPath: ghosttyDir) {
                let cacheDir = (NSHomeDirectory() as NSString)
                    .appendingPathComponent("Library/Caches/mux0")
                try? FileManager.default.createDirectory(
                    atPath: cacheDir,
                    withIntermediateDirectories: true
                )
                let tmpConf = (cacheDir as NSString).appendingPathComponent("resources-dir.conf")
                let confContent = "resources-dir = \(ghosttyDir)\nshell-integration = detect\n"
                try? confContent.write(toFile: tmpConf, atomically: true, encoding: .utf8)
                tmpConf.withCString { ghostty_config_load_file(cfg, $0) }
            } else {
                print("[GhosttyBridge] bundled resources-dir not found at \(ghosttyDir)")
            }
        }

        // libghostty 作为独立 dylib 嵌入时没有 resources-dir,无法解析用户 config
        // 里的 `theme = Catppuccin Latte` 之类引用,会静默 fallback 到内置深色默认。
        // 手动把主题文件路径喂回去,让 background/foreground/palette 作为 override 生效。
        if let themePath = GhosttyConfigReader.resolvedThemePath() {
            themePath.withCString { ghostty_config_load_file(cfg, $0) }
        }

        // mux0 override: 写在 GUI 设置里的字段覆盖以上所有来源。
        // 文件由 SettingsConfigStore 维护；不存在即跳过。
        let mux0ConfigPath = SettingsConfigStore.defaultPath
        if FileManager.default.fileExists(atPath: mux0ConfigPath) {
            mux0ConfigPath.withCString { ghostty_config_load_file(cfg, $0) }
        }

        // Final override: surface background fully transparent so the canvas
        // container behind the GhosttyTerminalView shows through directly. The
        // user-visible "Background Opacity" / "Content Opacity" sliders shape
        // that canvas color in ContentView; the terminal cell never paints its
        // own backdrop. Written as its own conf file because libghostty has no
        // single-key setter, and loaded last so it wins over user config.
        let transparentConf = (cacheDir as NSString)
            .appendingPathComponent("transparent-surface.conf")
        try? "background-opacity = 0\n".write(
            toFile: transparentConf, atomically: true, encoding: .utf8
        )
        transparentConf.withCString { ghostty_config_load_file(cfg, $0) }

        ghostty_config_finalize(cfg)
        return cfg
    }

    /// One-time setenv for mux0 agent-hook plumbing. Must run before any surface
    /// is created so spawned PTYs inherit these variables.
    private func exportEnvVars() {
        // Export the mux0 agent-hooks dir so child shells can bootstrap our hooks.
        // User adds one line to their rc:
        //   [ -f "$MUX0_AGENT_HOOKS_DIR/bootstrap.zsh" ] && source "$MUX0_AGENT_HOOKS_DIR/bootstrap.zsh"
        if let resourcesPath = Bundle.main.resourcePath {
            let hooksDir = (resourcesPath as NSString).appendingPathComponent("agent-hooks")
            if FileManager.default.fileExists(atPath: hooksDir) {
                setenv("MUX0_AGENT_HOOKS_DIR", hooksDir, 1)
            } else {
                print("[GhosttyBridge] agent-hooks dir not found at \(hooksDir)")
            }
        }

        // Path B: install ZDOTDIR hijack so child zsh shells read our shim first.
        // The shim restores ZDOTDIR and defers our bootstrap to first-prompt precmd.
        if let resourcesPath = Bundle.main.resourcePath {
            let shimDir = (resourcesPath as NSString).appendingPathComponent("agent-hooks/zdotdir")
            if FileManager.default.fileExists(atPath: shimDir) {
                if let orig = ProcessInfo.processInfo.environment["ZDOTDIR"], !orig.isEmpty {
                    setenv("MUX0_ORIG_ZDOTDIR", orig, 1)
                }
                setenv("ZDOTDIR", shimDir, 1)
            } else {
                print("[GhosttyBridge] zdotdir shim not found at \(shimDir)")
            }
        }

        // Set MUX0_HOOK_SOCK early so surfaces spawned before ContentView.onAppear still
        // inherit it. The listener itself is started later in ContentView.onAppear; any
        // hook emits in the gap fail silently (hook-emit.sh swallows connect errors).
        setenv("MUX0_HOOK_SOCK", HookSocketListener.defaultPath, 1)
    }

    /// Rebuild ghostty config from disk and push it to the app + all live surfaces.
    /// Safe to call from the main thread on any settings change. Fields that
    /// require a fresh surface (e.g., `command`, already-injected shell env) won't
    /// affect live terminals — they'll apply to the next new surface.
    func reloadConfig() {
        guard isInitialized, let appHandle = app else { return }
        guard let newCfg = buildConfig() else {
            print("[GhosttyBridge] reloadConfig: buildConfig failed")
            return
        }
        ghostty_app_update_config(appHandle, newCfg)
        // Iterate live surfaces ourselves and push the new config to each. Ghostty
        // will fire CONFIG_CHANGE actions during these calls; our action callback
        // treats those as notifications only (see actionCallback). Calling
        // ghostty_surface_update_config from inside the action callback causes
        // infinite recursion — we fix that by doing the push here, where re-entry
        // can't occur.
        for surface in GhosttyTerminalView.allLiveSurfaces() {
            ghostty_surface_update_config(surface, newCfg)
        }
        if let old = config { ghostty_config_free(old) }
        self.config = newCfg
    }

    // MARK: - Surface factory

    private static let envLock = NSLock()

    /// Create a new terminal surface backed by an NSView.
    /// Caller is responsible for calling ghostty_surface_free().
    /// Sets MUX0_TERMINAL_ID in process env under a lock so the spawned PTY shell
    /// inherits the correct UUID. The lock prevents concurrent calls from racing.
    func newSurface(nsView: NSView,
                    scaleFactor: Double,
                    workingDirectory: String?,
                    command: String?,
                    terminalId: UUID) -> ghostty_surface_t? {
        guard isInitialized, let appHandle = app else { return nil }
        Self.envLock.lock()
        defer { Self.envLock.unlock() }

        setenv("MUX0_TERMINAL_ID", terminalId.uuidString, 1)
        // When the caller hasn't provided a working directory (e.g. a freshly
        // created terminal whose pwdStore has no record yet), fall back to
        // $HOME instead of letting ghostty inherit the spawning process's
        // cwd. macOS Launch Services starts an .app with cwd = `/`, which
        // breaks tools that refuse to run from a non-readable directory
        // (Homebrew prints "current working directory must be readable to
        // <user> to run brew", which then aborts a typical .zshrc midway and
        // leaves $NVM_DIR / $PATH unset).
        let resolvedWorkingDirectory = workingDirectory ?? NSHomeDirectory()
        let initialInput = WorkspaceDefaultCommand.startupInput(for: command)

        var surfCfg = ghostty_surface_config_new()
        surfCfg.scale_factor = scaleFactor

        // Platform: macOS — pass unretained; GhosttyTerminalView outlives its surface
        surfCfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        surfCfg.platform.macos.nsview = Unmanaged.passUnretained(nsView).toOpaque()

        // Per-surface userdata is what the read_clipboard_cb receives; set it to the
        // owning view so the callback can look up the surface and answer paste requests.
        surfCfg.userdata = Unmanaged.passUnretained(nsView).toOpaque()

        // Both `working_directory` and `initial_input` must reference buffers that stay
        // valid for the whole `ghostty_surface_new` call. Use nested `withCString`
        // calls to keep the UTF-8 bytes pinned. We intentionally send workspace
        // commands as initial shell input instead of Ghostty's `command` field:
        // if an SSH command exits quickly, the user lands back in their shell
        // rather than Ghostty treating the surface's main process as failed.
        return resolvedWorkingDirectory.withCString { wdPtr in
            surfCfg.working_directory = wdPtr
            guard let input = initialInput else {
                return ghostty_surface_new(appHandle, &surfCfg)
            }
            return input.withCString { inputPtr in
                surfCfg.initial_input = inputPtr
                return ghostty_surface_new(appHandle, &surfCfg)
            }
        }
    }

    // MARK: - Window effects

    /// Hand the main NSWindow pointer to ghostty so it can apply/update the
    /// `background-blur-radius` from the current config. Ghostty reads the radius
    /// itself from the last `ghostty_app_update_config`; we only supply the window.
    /// Passing radius = 0 (via config) makes ghostty tear the blur down, so the
    /// call is idempotent and safe to invoke on every settings change.
    func applyWindowBackgroundBlur(to window: NSWindow) {
        guard let appHandle = app else { return }
        let ptr = Unmanaged.passUnretained(window).toOpaque()
        ghostty_set_window_background_blur(appHandle, ptr)
    }

    // MARK: - Color scheme

    func applyColorScheme(_ isDark: Bool) {
        guard let appHandle = app else { return }
        let scheme: ghostty_color_scheme_e = isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
        ghostty_app_set_color_scheme(appHandle, scheme)
    }

    // MARK: - Read colors from ghostty config

    /// 从 ghostty config 读颜色字段。失败返回 nil。
    private func readColor(key: String) -> ghostty_config_color_s? {
        guard let cfg = config else { return nil }
        var out = ghostty_config_color_s()
        let ok = key.withCString { keyPtr in
            ghostty_config_get(cfg, &out, keyPtr, UInt(key.utf8.count))
        }
        return ok ? out : nil
    }

    func readBackground() -> ghostty_config_color_s? { readColor(key: "background") }
    func readForeground() -> ghostty_config_color_s? { readColor(key: "foreground") }

    /// 读 256-color palette。失败返回 nil。
    func readPalette() -> ghostty_config_palette_s? {
        guard let cfg = config else { return nil }
        var out = ghostty_config_palette_s()
        let key = "palette"
        let ok = key.withCString { keyPtr in
            ghostty_config_get(cfg, &out, keyPtr, UInt(key.utf8.count))
        }
        return ok ? out : nil
    }

    // MARK: - C callbacks (@convention(c) static functions)

    private static let wakeupCallback: ghostty_runtime_wakeup_cb = { userdata in
        guard let ptr = userdata else { return }
        let bridge = Unmanaged<GhosttyBridge>.fromOpaque(ptr).takeUnretainedValue()
        DispatchQueue.main.async {
            guard let appHandle = bridge.app else { return }
            ghostty_app_tick(appHandle)
        }
    }

    // ghostty_runtime_action_cb: (ghostty_app_t, ghostty_target_s, ghostty_action_s) -> bool
    //
    // Most actions are handled via Unix-socket IPC from wrapper hooks, not here.
    //
    // CONFIG_CHANGE is a NOTIFICATION, not a request. Ghostty fires it from inside
    // ghostty_app_update_config and ghostty_surface_update_config to tell the apprt
    // "this target's config was reloaded". Calling ghostty_surface_update_config
    // from this handler causes infinite recursion (each call fires another
    // CONFIG_CHANGE). The correct response is to acknowledge and return.
    private static let actionCallback: ghostty_runtime_action_cb = { _, target, action in
        switch action.tag {
        case GHOSTTY_ACTION_CONFIG_CHANGE:
            return true
        case GHOSTTY_ACTION_CELL_SIZE:
            guard target.tag == GHOSTTY_TARGET_SURFACE,
                  let surface = target.target.surface
            else { return true }
            let cs = action.action.cell_size
            let w = Double(cs.width)
            let h = Double(cs.height)
            DispatchQueue.main.async {
                guard let view = GhosttyTerminalView.view(forSurface: surface) else { return }
                view.applyCellSize(backingWidth: w, backingHeight: h)
            }
            return true
        case GHOSTTY_ACTION_SCROLLBAR:
            guard target.tag == GHOSTTY_TARGET_SURFACE,
                  let surface = target.target.surface
            else { return true }
            let sb = action.action.scrollbar
            let state = GhosttyTerminalView.ScrollbarState(
                total: sb.total, offset: sb.offset, len: sb.len
            )
            DispatchQueue.main.async {
                guard let view = GhosttyTerminalView.view(forSurface: surface) else { return }
                view.applyScrollbar(state)
            }
            return true
        case GHOSTTY_ACTION_PWD:
            guard target.tag == GHOSTTY_TARGET_SURFACE,
                  let surface = target.target.surface,
                  let cstr = action.action.pwd.pwd
            else { return true }
            let raw = String(cString: cstr)
            // Bounce to main to touch view/store state. `view(forSurface:)` reads
            // GhosttyTerminalView.viewBySurface which is main-queue-only.
            DispatchQueue.main.async {
                guard let view = GhosttyTerminalView.view(forSurface: surface),
                      let terminalId = view.terminalId
                else { return }
                let pwd = sanitizedPwd(raw) ?? raw
                GhosttyBridge.shared.onPwdChanged?(terminalId, pwd)
            }
            return true
        default:
            return false
        }
    }

    /// ghostty forwards OSC 7 payloads as-is. zsh integration emits
    /// `kitty-shell-cwd://HOST/path` and `file://HOST/path` is the classic form;
    /// strip the scheme+host so we end up with a plain filesystem path usable by
    /// `cd` / `git -C`. Returns nil if the input doesn't look like a URL (caller
    /// falls back to the raw string).
    private static func sanitizedPwd(_ raw: String) -> String? {
        for scheme in ["kitty-shell-cwd://", "file://"] {
            guard raw.hasPrefix(scheme) else { continue }
            let afterScheme = raw.dropFirst(scheme.count)
            guard let slash = afterScheme.firstIndex(of: "/") else { return nil }
            return String(afterScheme[slash...])
        }
        return nil
    }

    // ghostty_runtime_close_surface_cb: (void*, bool) -> void
    private static let closeSurfaceCallback: ghostty_runtime_close_surface_cb = { _, _ in }

    // ghostty_runtime_read_clipboard_cb: (void*, ghostty_clipboard_e, void*) -> bool
    //
    // Ghostty hands us the owning surface's userdata (set in newSurface above) plus an
    // opaque `state` pointer. We read NSPasteboard and hand the text back via
    // ghostty_surface_complete_clipboard_request — otherwise Cmd+V pastes nothing.
    private static let readClipboardCallback: ghostty_runtime_read_clipboard_cb = { userdata, _, state in
        guard let userdata else { return false }
        let view = Unmanaged<GhosttyTerminalView>.fromOpaque(userdata).takeUnretainedValue()
        guard let surface = view.rawSurface else { return false }
        guard let str = NSPasteboard.general.string(forType: .string), !str.isEmpty else { return false }
        str.withCString { ptr in
            ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
        }
        return true
    }

    // ghostty_runtime_confirm_read_clipboard_cb: (void*, const char*, void*, ghostty_clipboard_request_e) -> void
    private static let confirmReadClipboardCallback: ghostty_runtime_confirm_read_clipboard_cb = { _, _, _, _ in }

    // ghostty_runtime_write_clipboard_cb: (void*, ghostty_clipboard_e, const ghostty_clipboard_content_s*, size_t, bool) -> void
    private static let writeClipboardCallback: ghostty_runtime_write_clipboard_cb = { _, _, content, count, _ in
        guard !GhosttyBridge.suppressClipboardWrites else { return }
        guard let content = content, count > 0 else { return }

        // Ghostty hands us the selection as multiple MIME-tagged entries (typically
        // text/plain + text/html). The old implementation ignored `mime` and wrote
        // every entry as .string after clearing the pasteboard, so text/html was
        // pasted as raw markup. Instead: clear once, map mime → PasteboardType, and
        // let the receiving app pick the representation it prefers.
        var items: [(NSPasteboard.PasteboardType, String)] = []
        for i in 0..<count {
            let item = content[i]
            guard let dataPtr = item.data,
                  let str = String(cString: dataPtr, encoding: .utf8) else { continue }
            let mime: String = item.mime.flatMap { String(cString: $0, encoding: .utf8) } ?? "text/plain"
            let type: NSPasteboard.PasteboardType
            switch mime {
            case "text/plain": type = .string
            case "text/html":  type = .html
            default:           type = NSPasteboard.PasteboardType(mime)
            }
            items.append((type, str))
        }
        guard !items.isEmpty else { return }

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes(items.map { $0.0 }, owner: nil)
        for (type, str) in items {
            pb.setString(str, forType: type)
        }
    }
}
