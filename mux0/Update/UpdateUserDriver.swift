#if !DEBUG && !MUX0_UPDATES_DISABLED
import Foundation
import Sparkle

/// Implements Sparkle's SPUUserDriver protocol, the interface through which
/// Sparkle notifies the app of update-lifecycle events and receives user
/// decisions. Every callback mutates UpdateStore on the main actor so the
/// SwiftUI views observe the change; every user action (downloadAndInstall,
/// skip, dismiss) is routed here via SparkleBridge, which stores the
/// pending reply blocks and calls them when the user clicks.
///
/// Lifecycle (happy path):
///   showUpdateFound(...) → (user click Download & Install)
///   → showDownloadInitiated → showDownloadDidReceiveData(progress) x N
///   → showDownloadDidStartExtractingUpdate → showReady(toInstallAndRelaunch)
///   → Sparkle quits + relaunches.
///
/// Compiled only in Release (`#if !DEBUG && !MUX0_UPDATES_DISABLED`) — Debug has no Sparkle in scope.
@MainActor
final class UpdateUserDriver: NSObject, SPUUserDriver {

    private weak var store: UpdateStore?

    // Pending reply from Sparkle's showUpdateFound; consumed by a user click
    // (Download / Skip / Dismiss). Sparkle requires this block to be called
    // exactly once per update check — failing to call it hangs the state
    // machine.
    private var pendingUpdateReply: ((SPUUserUpdateChoice) -> Void)?

    init(store: UpdateStore) {
        self.store = store
        super.init()
    }

    // MARK: - Public (called by SparkleBridge when user clicks)

    func userRequestedDownloadAndInstall() {
        pendingUpdateReply?(.install)
        pendingUpdateReply = nil
    }

    func userRequestedSkipVersion() {
        pendingUpdateReply?(.skip)
        pendingUpdateReply = nil
        store?.resetToIdle()
    }

    func userRequestedDismiss() {
        pendingUpdateReply?(.dismiss)
        pendingUpdateReply = nil
    }

    // MARK: - SPUUserDriver

    // Required by SPUUserDriver in Sparkle 2.9: ask user permission for
    // automatic update checks (typically first-launch only). We auto-grant
    // permission with the system profile disabled to stay non-intrusive.
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        store?.setChecking()
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        // Defensive: if a prior update check's reply is still stashed (user
        // closed Settings without clicking any button), resolve it with
        // .dismiss so Sparkle's state machine doesn't deadlock.
        pendingUpdateReply?(.dismiss)
        pendingUpdateReply = reply
        store?.setUpdateAvailable(
            version: appcastItem.displayVersionString ?? appcastItem.versionString,
            releaseNotes: appcastItem.itemDescription
        )
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // Not used: we render notes from appcastItem.itemDescription at the
        // moment of showUpdateFound(...). If a release ships notes as a
        // separate HTML asset via sparkle:releaseNotesLink, Sparkle would
        // call this; we'd optionally plumb it into UpdateStore later.
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        // Non-fatal — we already have the inline release notes.
    }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        store?.setUpToDate()
        acknowledgement()
        // Auto-transition back to idle after 3 s.
        Task { @MainActor [weak store] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if case .upToDate = store?.state {
                store?.resetToIdle()
            }
        }
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        store?.setError(error.localizedDescription)
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        // Reset byte counters — they are instance state that persists across
        // multiple download cycles (rare, but possible if user cancels and
        // Sparkle retries).
        receivedBytes = 0
        expectedTotalBytes = 0
        store?.setDownloading(progress: 0)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        // Stored for progress % calculation in showDownloadDidReceiveData.
        expectedTotalBytes = expectedContentLength
    }

    private var expectedTotalBytes: UInt64 = 0
    private var receivedBytes: UInt64 = 0

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedBytes += length
        // If Sparkle never called the expectedContentLength path, fall back
        // to indeterminate 0% — avoids divide-by-zero.
        let total = expectedTotalBytes > 0 ? expectedTotalBytes : max(receivedBytes, 1)
        let progress = min(1.0, Double(receivedBytes) / Double(total))
        store?.setDownloading(progress: progress)
    }

    func showDownloadDidStartExtractingUpdate() {
        store?.setDownloading(progress: 1.0)
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        store?.setDownloading(progress: progress)
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        store?.setReadyToInstall()
        // Auto-install: match input0 behaviour.
        reply(.install)
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        // Sparkle is about to quit + install. UI unchanged from readyToInstall.
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        // Only called if Sparkle ran the installer in-process without quitting
        // (uncommon for .dmg installs). Acknowledge and reset.
        store?.resetToIdle()
        acknowledgement()
    }

    func showUpdateInFocus() {
        // Reserved for bringing focus to the update UI; our settings panel
        // is reached by the user clicking the sidebar version number, so
        // no-op here.
    }

    func dismissUpdateInstallation() {
        // Sparkle telling us the install flow ended (success or user cancel).
    }
}
#endif
