import Foundation

// MARK: - LocalizedStringResource + locale helper

extension LocalizedStringResource {
    /// Return a copy of this resource with an explicit locale override.
    /// Use this when `String(localized:)` is needed outside of a SwiftUI `Text(_:)`
    /// — e.g. for `LabeledContent`, `TextField`, and `alert` title arguments — so
    /// the resolved string honours the SwiftUI `\.locale` environment rather than
    /// `Locale.current` (the system locale).
    ///
    /// Usage:
    /// ```swift
    /// @Environment(\.locale) private var locale
    /// LabeledContent(String(localized: label.withLocale(locale))) { ... }
    /// ```
    func withLocale(_ locale: Locale) -> LocalizedStringResource {
        var copy = self
        copy.locale = locale
        return copy
    }
}

/// Compile-time namespace for all localizable strings. Organized by UI module.
///
/// - SwiftUI: use the `LocalizedStringResource` properties directly
///   → `Text(L10n.Sidebar.newWorkspace)`.
/// - AppKit:  use `L10n.string("key", args...)` helper → returns a `String`
///   resolved against `LanguageStore.shared.effectiveBundle`.
///
/// Keys are dotted namespaces mirroring UI structure; source language is English,
/// translations live in `mux0/Localization/Strings.xcstrings`.
enum L10n {
    // MARK: - AppKit helper

    /// Resolve `key` against the shared store's effective bundle. If `args`
    /// is non-empty, `String(format:)` the result. Intended for AppKit-side
    /// `stringValue`/`toolTip` assignments that can't use SwiftUI's `\.locale`.
    static func string(_ key: String, _ args: CVarArg...) -> String {
        let bundle = LanguageStore.shared.effectiveBundle
        let raw = bundle.localizedString(forKey: key, value: nil, table: nil)
        return args.isEmpty ? raw : String(format: raw, arguments: args)
    }

    // MARK: - Sidebar

    enum Sidebar {
        static let title                = LocalizedStringResource("sidebar.title")
        static let newWorkspace         = LocalizedStringResource("sidebar.newWorkspace")
        static let settingsTooltip      = LocalizedStringResource("sidebar.settings")
        static let deleteAlertTitle     = LocalizedStringResource("sidebar.deleteAlert.title")
        static let deleteAlertCancel    = LocalizedStringResource("sidebar.deleteAlert.cancel")
        static let deleteAlertConfirm   = LocalizedStringResource("sidebar.deleteAlert.confirm")
        static func deleteAlertMessage(_ name: String) -> LocalizedStringResource {
            // `LocalizedStringResource`'s string interpolation protocol converts
            // `\(name)` to a `%@` argument internally, so the resolved catalog key is
            // `"sidebar.deleteAlert.message %@"` and the argument is substituted at
            // `String(localized:)` / `Text(_:)` call sites automatically.
            LocalizedStringResource("sidebar.deleteAlert.message \(name)")
        }
        // Default-command edit alert (mirrors deleteAlert: SwiftUI .alert in shell,
        // AppKit row only bubbles the request up).
        static let commandAlertTitle       = LocalizedStringResource("sidebar.row.commandPanel.editTitle")
        static let commandAlertCancel      = LocalizedStringResource("sidebar.row.commandPanel.cancel")
        static let commandAlertSave        = LocalizedStringResource("sidebar.row.commandPanel.save")
        static let commandAlertPlaceholder = LocalizedStringResource("sidebar.row.commandPanel.placeholder")
        static let showSidebar          = LocalizedStringResource("sidebar.show")
        static let hideSidebar          = LocalizedStringResource("sidebar.hide")
        // Footer auto-update affordances (version pill + pulsing red dot).
        static let updateAvailable      = LocalizedStringResource("sidebar.updateAvailable")
        static let checkForUpdates      = LocalizedStringResource("sidebar.checkForUpdates")
    }

    // MARK: - Tab

    enum Tab {
        static let newTabTooltip        = LocalizedStringResource("tab.newTab")
        // Row rename/close (context menu) and close-tab alert strings are resolved
        // at runtime via L10n.string("tab.row.rename") etc. — they live only in
        // AppKit call sites (NSMenuItem, NSAlert), so no typed constant is needed.
        // See Strings.xcstrings for the full key list.
    }

    // MARK: - Settings

    enum Settings {
        // Sections
        static let sectionAppearance    = LocalizedStringResource("settings.section.appearance")
        static let sectionFont          = LocalizedStringResource("settings.section.font")
        static let sectionTerminal      = LocalizedStringResource("settings.section.terminal")
        static let sectionShell         = LocalizedStringResource("settings.section.shell")
        static let sectionAgents        = LocalizedStringResource("settings.section.agents")
        static let sectionUpdate        = LocalizedStringResource("settings.section.update")

        // Shell (chrome)
        static let close                = LocalizedStringResource("settings.close")
        static let footerEdit           = LocalizedStringResource("settings.footer.edit")
        static let footerLive           = LocalizedStringResource("settings.footer.live")

        // Appearance fields
        static let theme                = LocalizedStringResource("settings.appearance.theme")
        static let backgroundOpacity    = LocalizedStringResource("settings.appearance.backgroundOpacity")
        static let backgroundBlur       = LocalizedStringResource("settings.appearance.backgroundBlur")
        static let contentOpacity       = LocalizedStringResource("settings.appearance.contentOpacity")
        static let windowPaddingX       = LocalizedStringResource("settings.appearance.windowPaddingX")
        static let windowPaddingY       = LocalizedStringResource("settings.appearance.windowPaddingY")
        static let cursorStyle          = LocalizedStringResource("settings.appearance.cursorStyle")
        static let cursorBlink          = LocalizedStringResource("settings.appearance.cursorBlink")
        static let unfocusedPaneOpacity = LocalizedStringResource("settings.appearance.unfocusedPaneOpacity")

        // Language picker
        static let language             = LocalizedStringResource("settings.appearance.language")
        static let languageSystem       = LocalizedStringResource("settings.language.system")

        // Font
        static let fontFamily           = LocalizedStringResource("settings.font.family")
        static let fontSize             = LocalizedStringResource("settings.font.size")
        static let fontThicken          = LocalizedStringResource("settings.font.thicken")
        static let fontDefault          = LocalizedStringResource("settings.font.default")
        static let fontCustom           = LocalizedStringResource("settings.font.custom")
        static let fontCustomPlaceholder = LocalizedStringResource("settings.font.customPlaceholder")
        static let fontListButton       = LocalizedStringResource("settings.font.listButton")

        // Reset row
        static let resetMessage         = LocalizedStringResource("settings.reset.message")
        static let resetButton          = LocalizedStringResource("settings.reset.button")
        static let resetRowLabel        = LocalizedStringResource("settings.reset.rowLabel")
        static let resetAlertTitle      = LocalizedStringResource("settings.reset.alertTitle")
        static let resetCancel          = LocalizedStringResource("settings.reset.cancel")

        // Theme picker
        static let themeSingle          = LocalizedStringResource("settings.theme.single")
        static let themeFollowSystem    = LocalizedStringResource("settings.theme.followSystem")
        static let themeName            = LocalizedStringResource("settings.theme.name")
        static let themeLight           = LocalizedStringResource("settings.theme.light")
        static let themeDark            = LocalizedStringResource("settings.theme.dark")
        static let themeSearchPlaceholder = LocalizedStringResource("settings.theme.searchPlaceholder")
        static let themeInherit         = LocalizedStringResource("settings.theme.inherit")

        enum Terminal {
            static let scrollbackLimit        = LocalizedStringResource("settings.terminal.scrollbackLimit")
            static let copyOnSelect           = LocalizedStringResource("settings.terminal.copyOnSelect")
            static let hideMouseWhileTyping   = LocalizedStringResource("settings.terminal.hideMouseWhileTyping")
            static let confirmClose           = LocalizedStringResource("settings.terminal.confirmClose")
        }
        enum Shell {
            static let integration         = LocalizedStringResource("settings.shell.integration")
            static let features            = LocalizedStringResource("settings.shell.features")
            static let customCommand       = LocalizedStringResource("settings.shell.customCommand")
            static let defaultPlaceholder  = LocalizedStringResource("settings.shell.defaultPlaceholder")
        }
        enum Agents {
            static let claude            = LocalizedStringResource("settings.agents.claude")
            static let codex             = LocalizedStringResource("settings.agents.codex")
            static let opencode          = LocalizedStringResource("settings.agents.opencode")
            static let betaBadge         = LocalizedStringResource("settings.agents.betaBadge")
            static let codexAlertTitle   = LocalizedStringResource("settings.agents.codexAlertTitle")
            static let codexAlertMessage = LocalizedStringResource("settings.agents.codexAlertMessage")
            static let codexAlertOK      = LocalizedStringResource("settings.agents.codexAlertOK")
        }
        enum Update {
            // Labels on the left column of the Form rows.
            static let currentVersion      = LocalizedStringResource("settings.update.currentVersion")
            static let status              = LocalizedStringResource("settings.update.status")
            static let availableUpdate     = LocalizedStringResource("settings.update.availableUpdate")
            static let downloading         = LocalizedStringResource("settings.update.downloading")
            static let error               = LocalizedStringResource("settings.update.error")
            static let action              = LocalizedStringResource("settings.update.action")
            static let debugBuild          = LocalizedStringResource("settings.update.debugBuild")
            static let releaseNotes        = LocalizedStringResource("settings.update.releaseNotes")

            // Status-row values + action buttons.
            static let checkForUpdates     = LocalizedStringResource("settings.update.checkForUpdates")
            static let checking            = LocalizedStringResource("settings.update.checking")
            static let upToDate            = LocalizedStringResource("settings.update.upToDate")
            static let installing          = LocalizedStringResource("settings.update.installing")
            static let downloadInstall     = LocalizedStringResource("settings.update.downloadInstall")
            static let skipThisVersion     = LocalizedStringResource("settings.update.skipThisVersion")
            static let dismiss             = LocalizedStringResource("settings.update.dismiss")
            static let retry               = LocalizedStringResource("settings.update.retry")
            static let debugDisabled       = LocalizedStringResource("settings.update.debugDisabled")

            /// "Version X.Y.Z" formatted at the call site.
            static func versionNumber(_ version: String) -> LocalizedStringResource {
                LocalizedStringResource("settings.update.version \(version)")
            }
        }
    }

    // MARK: - App

    enum App {
        static let ghosttyNotFoundTitle     = LocalizedStringResource("app.ghostty.notFound.title")
        static let ghosttyNotFoundDetail    = LocalizedStringResource("app.ghostty.notFound.detail")
    }

    // MARK: - Menu

    enum Menu {
        static let settings             = LocalizedStringResource("menu.settings")
        static let editConfig           = LocalizedStringResource("menu.editConfig")
        static let newWorkspace         = LocalizedStringResource("menu.newWorkspace")
        static let newTab               = LocalizedStringResource("menu.newTab")
        static let closePane            = LocalizedStringResource("menu.closePane")
        static let splitVertical        = LocalizedStringResource("menu.splitVertical")
        static let splitHorizontal      = LocalizedStringResource("menu.splitHorizontal")
        static let focusNextPane        = LocalizedStringResource("menu.focusNextPane")
        static let focusPrevPane        = LocalizedStringResource("menu.focusPrevPane")
        static let selectNextTab        = LocalizedStringResource("menu.selectNextTab")
        static let selectPrevTab        = LocalizedStringResource("menu.selectPrevTab")
        static let terminalMenu         = LocalizedStringResource("menu.terminal")
        static let copy                 = LocalizedStringResource("menu.copy")
        static let paste                = LocalizedStringResource("menu.paste")
        static let selectAll            = LocalizedStringResource("menu.selectAll")
        static let help                 = LocalizedStringResource("menu.help")
        /// `%lld` will be formatted at call site in mux0App.
        static func selectTabN(_ n: Int) -> LocalizedStringResource {
            LocalizedStringResource("menu.selectTab \(n)")
        }
    }
}
