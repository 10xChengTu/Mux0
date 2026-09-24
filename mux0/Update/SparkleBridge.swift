import Foundation
#if !DEBUG && !MUX0_UPDATES_DISABLED
import Sparkle
#endif

/// Wraps SPUUpdater + our custom SPUUserDriver. The only file (along with
/// UpdateUserDriver) that imports Sparkle — keeps the dependency surface
/// contained, matching how GhosttyBridge isolates libghostty.
///
/// Debug builds — and any build compiled with `MUX0_UPDATES_DISABLED` (this
/// fork's Release builds, whose appcast would otherwise point at the upstream
/// author's repo) — compile this class as a no-op stub:
///   - `isActive` returns false
///   - all action methods log and return
/// This avoids hitting the real appcast URL during development and keeps
/// the IDE green without a valid SUPublicEDKey.
final class SparkleBridge {
    static let shared = SparkleBridge()

    /// Injected by mux0App once the UpdateStore is created. The driver
    /// mutates store state; the bridge forwards user actions here so the
    /// driver can reach the store for consistency-check paths.
    weak var store: UpdateStore?

    /// True when the *build* forbids contacting the appcast, independent of
    /// configuration. Info.plist also ships `SUEnableAutomaticChecks = NO` with
    /// an empty `SUFeedURL`; this flag makes it structural — with the flag on,
    /// no file here imports Sparkle, so the binary has **zero undefined Sparkle
    /// symbols** (`nm -u mux0 | grep -ci Sparkle` → 0): there is no call site
    /// left that could issue a request, and the Update section can state the
    /// reason instead of showing a dead button.
    ///
    /// Linking is a separate matter from calling: the target still declares the
    /// Sparkle package dependency (xcodegen cannot attach a package product to
    /// one configuration only), so the Release binary keeps an
    /// `@rpath/Sparkle.framework` load command and the bundle still embeds the
    /// framework, which dyld maps at launch. Loading is not contacting: nothing
    /// instantiates `SPUUpdater`, starts its timer, or opens a socket — verified
    /// on the shipped build with `lsof -p <pid> -i` staying empty.
    static let updatesDisabledAtBuildTime: Bool = {
        #if MUX0_UPDATES_DISABLED
        return true
        #else
        return false
        #endif
    }()

    var isActive: Bool {
        #if DEBUG || MUX0_UPDATES_DISABLED
        return false
        #else
        return true
        #endif
    }

    // MARK: - Public API (UI calls these)

    @MainActor func start() {
        #if !DEBUG && !MUX0_UPDATES_DISABLED
        startUpdater()
        #endif
    }

    @MainActor func checkForUpdates(silently: Bool) {
        #if DEBUG || MUX0_UPDATES_DISABLED
        print("[SparkleBridge] DEBUG stub: checkForUpdates(silently: \(silently))")
        #else
        if silently {
            updater?.checkForUpdatesInBackground()
        } else {
            updater?.checkForUpdates()
        }
        #endif
    }

    @MainActor func downloadAndInstall() {
        #if DEBUG || MUX0_UPDATES_DISABLED
        print("[SparkleBridge] DEBUG stub: downloadAndInstall()")
        #else
        driver?.userRequestedDownloadAndInstall()
        #endif
    }

    @MainActor func skipVersion() {
        #if DEBUG || MUX0_UPDATES_DISABLED
        print("[SparkleBridge] DEBUG stub: skipVersion()")
        #else
        driver?.userRequestedSkipVersion()
        #endif
    }

    @MainActor func dismiss() {
        #if DEBUG || MUX0_UPDATES_DISABLED
        print("[SparkleBridge] DEBUG stub: dismiss()")
        #else
        driver?.userRequestedDismiss()
        store?.resetToIdle()
        #endif
    }

    @MainActor func retry() {
        #if DEBUG || MUX0_UPDATES_DISABLED
        print("[SparkleBridge] DEBUG stub: retry()")
        #else
        store?.resetToIdle()
        // If the initial startUpdater failed (e.g. missing SUFeedURL), updater
        // is nil and checkForUpdates would silently no-op. Re-attempt start()
        // so Retry recovers the user instead of going dead.
        if updater == nil { startUpdater() }
        checkForUpdates(silently: false)
        #endif
    }

    // MARK: - Release-only internals

    #if !DEBUG && !MUX0_UPDATES_DISABLED
    private var updater: SPUUpdater?
    private var driver: UpdateUserDriver?

    @MainActor private func startUpdater() {
        // Idempotent: re-entering start() (e.g. ContentView.onAppear firing
        // twice) must not create a second SPUUpdater.
        guard self.updater == nil else { return }
        guard let store = store else {
            print("[SparkleBridge] ERROR: startUpdater called before store injected")
            return
        }
        let driver = UpdateUserDriver(store: store)
        let updater = SPUUpdater(
            hostBundle: Bundle.main,
            applicationBundle: Bundle.main,
            userDriver: driver,
            delegate: nil
        )
        do {
            try updater.start()
        } catch {
            store.setError("Updater failed to start: \(error.localizedDescription)")
            return
        }
        self.updater = updater
        self.driver = driver
    }
    #endif
}
