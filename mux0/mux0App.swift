import SwiftUI
import AppKit

@main
struct mux0App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var themeManager = ThemeManager()
    @State private var languageStore = LanguageStore.shared

    init() {
        // Disable macOS native NSWindow auto-tabbing. mux0 renders its own
        // in-app tab bar (TabBarView) and binds ⌘T to Terminal > New Tab.
        // Without this, AppKit overlays a native tab bar on the window and
        // hijacks ⌘T for its own "New Tab in Window" action.
        NSWindow.allowsAutomaticWindowTabbing = false

        let ok = GhosttyBridge.shared.initialize()
        if !ok { print("[mux0] Warning: libghostty initialization failed") }
    }

    var body: some Scene {
        _ = languageStore.tick  // touch @Observable to track; Commands rebuild when tick changes

        return WindowGroup {
            if GhosttyBridge.shared.isInitialized {
                ContentView()
                    .environment(themeManager)
                    .environment(languageStore)
                    .environment(\.locale, languageStore.locale)
            } else {
                GhosttyMissingView()
                    .environment(languageStore)
                    .environment(\.locale, languageStore.locale)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            // ── App menu (mux0 > …) ───────────────────────────────────
            CommandGroup(replacing: .appSettings) {
                Button(String(localized: L10n.Menu.settings.withLocale(LanguageStore.shared.locale))) {
                    post(.mux0OpenSettings)
                }
                .keyboardShortcut(",", modifiers: .command)

                Button(String(localized: L10n.Menu.editConfig.withLocale(LanguageStore.shared.locale))) {
                    post(.mux0EditConfigFile)
                }
            }

            // ── File ──────────────────────────────────────────────────
            CommandGroup(replacing: .newItem) {
                Button(String(localized: L10n.Menu.newWorkspace.withLocale(LanguageStore.shared.locale))) {
                    post(.mux0BeginCreateWorkspace)
                }
                .keyboardShortcut("n", modifiers: .command)
            }

            // Strip default macOS items that don't apply to a terminal workspace app.
            strippedDefaultCommands

            // ── Edit ──────────────────────────────────────────────────
            // Replace the default pasteboard group so we keep only the three items
            // that make sense for a terminal surface.
            //
            // 实现细节：闭包统一用 `NSApp.sendAction(_:to:nil)` 把动作沿 responder
            // chain 派发，而不是直接 `post(.mux0Paste)`。这样：
            //   · 当 first responder 是 NSText 子类（例如侧栏 / 标签的内联 rename
            //     字段、设置面板里的 TextField 的 field editor）时，由 NSText
            //     标准实现处理 —— rename 框里 ⌘V 真的会粘贴系统剪贴板。
            //   · 否则链上下走到终端的 GhosttyTerminalView，它实现了同名 selector
            //     转发给 ghostty binding action，行为与之前一致。
            //
            // 之前直接 post 通知会强制把动作打给当前焦点 pane，无视真正的 first
            // responder，导致 NSTextField 的 paste: 永远收不到 ⌘V。
            CommandGroup(replacing: .pasteboard) {
                Button(String(localized: L10n.Menu.copy.withLocale(LanguageStore.shared.locale))) {
                    NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("c", modifiers: .command)
                Button(String(localized: L10n.Menu.paste.withLocale(LanguageStore.shared.locale))) {
                    NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("v", modifiers: .command)
                Button(String(localized: L10n.Menu.selectAll.withLocale(LanguageStore.shared.locale))) {
                    NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("a", modifiers: .command)
            }

            workspaceCommands
            terminalCommands
        }
    }

    // Extracted to avoid hitting the @CommandsBuilder 10-element tuple limit.
    // Strip default macOS items that don't apply to a terminal workspace app.
    @CommandsBuilder private var strippedDefaultCommands: some Commands {
        CommandGroup(replacing: .saveItem)          { EmptyView() }  // Save / Save As / Revert / Page Setup / Print
        CommandGroup(replacing: .undoRedo)          { EmptyView() }  // Undo / Redo
        CommandGroup(replacing: .textEditing)       { EmptyView() }  // Find / Spelling
        CommandGroup(replacing: .textFormatting)    { EmptyView() }  // Substitutions / Transformations
        CommandGroup(replacing: .toolbar)           { EmptyView() }  // Show/Hide Toolbar / Customize Toolbar
        CommandGroup(replacing: .windowArrangement) { EmptyView() }  // NSWindow-tab items
        CommandGroup(replacing: .help) {
            Button(String(localized: L10n.Menu.help.withLocale(LanguageStore.shared.locale))) {}.disabled(true)  // placeholder; removes default Search field
        }
    }

    @CommandsBuilder private var workspaceCommands: some Commands {
        // 把 Cmd+1-9 绑成「切第 N 个 workspace」放在 File 菜单的 New Workspace 后面。
        // 旧的「Cmd+1-9 切第 N 个 Tab」被降级到 Cmd+Opt+1-9（见 terminalCommands 末尾）。
        // workspace 数量 < N 时由 SidebarView.onReceive 静默忽略，不弹 alert / 不 beep。
        CommandGroup(after: .newItem) {
            Divider()
            ForEach(1...9, id: \.self) { idx in
                Button(String(localized: L10n.Menu.selectWorkspaceN(idx)
                                  .withLocale(LanguageStore.shared.locale))) {
                    NotificationCenter.default.post(
                        name: .mux0SelectWorkspaceAtIndex,
                        object: nil,
                        userInfo: ["index": idx - 1])
                }
                .keyboardShortcut(KeyEquivalent(Character(String(idx))), modifiers: .command)
            }
        }
    }

    @CommandsBuilder private var terminalCommands: some Commands {
        // ── Terminal ──────────────────────────────────────────────
        // Replaces the old "Tab" top-level menu. Four sections:
        //   1) Tab / pane creation
        //   2) Split
        //   3) Pane focus navigation
        //   4) Tab navigation
        CommandMenu(String(localized: L10n.Menu.terminalMenu.withLocale(LanguageStore.shared.locale))) {
            Button(String(localized: L10n.Menu.newTab.withLocale(LanguageStore.shared.locale))) { post(.mux0NewTab) }
                .keyboardShortcut("t", modifiers: .command)

            Button(String(localized: L10n.Menu.closePane.withLocale(LanguageStore.shared.locale))) { post(.mux0ClosePane) }
                .keyboardShortcut("w", modifiers: .command)

            Divider()

            Button(String(localized: L10n.Menu.splitVertical.withLocale(LanguageStore.shared.locale))) { post(.mux0SplitVertical) }
                .keyboardShortcut("d", modifiers: .command)

            Button(String(localized: L10n.Menu.splitHorizontal.withLocale(LanguageStore.shared.locale))) { post(.mux0SplitHorizontal) }
                .keyboardShortcut("d", modifiers: [.command, .shift])

            Divider()

            Button(String(localized: L10n.Menu.focusNextPane.withLocale(LanguageStore.shared.locale))) { post(.mux0FocusNextPane) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])

            Button(String(localized: L10n.Menu.focusPrevPane.withLocale(LanguageStore.shared.locale))) { post(.mux0FocusPrevPane) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])

            Divider()

            Button(String(localized: L10n.Menu.selectNextTab.withLocale(LanguageStore.shared.locale))) { post(.mux0SelectNextTab) }
                .keyboardShortcut("]", modifiers: [.command, .shift])

            Button(String(localized: L10n.Menu.selectPrevTab.withLocale(LanguageStore.shared.locale))) { post(.mux0SelectPrevTab) }
                .keyboardShortcut("[", modifiers: [.command, .shift])

            Divider()

            ForEach(1...9, id: \.self) { idx in
                Button(String(localized: L10n.Menu.selectTabN(idx).withLocale(LanguageStore.shared.locale))) {
                    NotificationCenter.default.post(
                        name: .mux0SelectTabAtIndex,
                        object: nil,
                        userInfo: ["index": idx - 1])
                }
                .keyboardShortcut(KeyEquivalent(Character(String(idx))), modifiers: [.command, .option])
            }
        }
    }

    private func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }
}

/// Companion delegate for app-level lifecycle hooks SwiftUI doesn't expose.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let mainMenu = NSApp.mainMenu else { return }

        // Drop top-level menus that AppKit auto-injects but mux0 doesn't use:
        // - Format: Font / Text submenus, only relevant to text editors
        // - View:   Show Toolbar / Customize / Enter Full Screen, none of which
        //          we want surfaced (full-screen still works via the green
        //          window button and the ⌃⌘F system shortcut)
        let topLevelMenusToRemove: Set<String> = ["Format", "View"]
        mainMenu.items.removeAll { topLevelMenusToRemove.contains($0.title) }

        // Defensive cleanup: even with allowsAutomaticWindowTabbing = false,
        // AppKit can still inject "Show Tab Bar" / "Show All Tabs" entries
        // (typically into the Window menu) and may try to register ⌘T against
        // them. Strip their shortcuts and hide them so our menu shortcuts win.
        walkMenuItems(in: mainMenu) { item in
            switch item.action {
            case #selector(NSWindow.toggleTabBar(_:)),
                 #selector(NSWindow.toggleTabOverview(_:)):
                item.keyEquivalent = ""
                item.keyEquivalentModifierMask = []
                item.isHidden = true
            default:
                break
            }
        }
    }

    private func walkMenuItems(in menu: NSMenu, _ visit: (NSMenuItem) -> Void) {
        for item in menu.items {
            visit(item)
            if let submenu = item.submenu { walkMenuItems(in: submenu, visit) }
        }
    }
}

/// Shown when libghostty is not available at launch.
struct GhosttyMissingView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundColor(.orange)
            Text(L10n.App.ghosttyNotFoundTitle)
                .font(.title2.bold())
            Text(L10n.App.ghosttyNotFoundDetail)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
        }
        .padding(40)
        .frame(width: 400, height: 280)
    }
}
