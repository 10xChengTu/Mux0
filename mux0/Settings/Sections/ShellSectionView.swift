import SwiftUI

struct ShellSectionView: View {
    let theme: AppTheme
    let settings: SettingsConfigStore

    private static let managedKeys = [
        "shell-integration",
        "shell-integration-features",
        "command",
    ]

    var body: some View {
        Form {
            BoundSegmented(
                settings: settings,
                key: "shell-integration",
                options: ["detect", "none", "fish", "zsh", "bash"],
                label: L10n.Settings.Shell.integration
            )

            BoundMultiSelect(
                settings: settings,
                key: "shell-integration-features",
                allOptions: ["cursor", "sudo", "title", "ssh-env"],
                label: L10n.Settings.Shell.features
            )

            BoundTextField(
                settings: settings,
                theme: theme,
                key: "command",
                placeholder: L10n.Settings.Shell.defaultPlaceholder,
                label: L10n.Settings.Shell.customCommand
            )

            SettingsResetRow(settings: settings, keys: Self.managedKeys)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
