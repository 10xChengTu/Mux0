import SwiftUI

struct QuickActionsSectionView: View {
    let theme: AppTheme
    let settings: SettingsConfigStore
    let quickActionsStore: QuickActionsStore

    @Environment(\.locale) private var locale

    private var managedKeys: [String] {
        var keys = [
            "mux0-quickactions-enabled",
            "mux0-quickactions-custom",
            "mux0-quickactions-order",
        ]
        keys.append(contentsOf: BuiltinQuickAction.allCases.map {
            "mux0-quickactions-builtin-command-\($0.id)"
        })
        return keys
    }

    var body: some View {
        Form {
            Section {
                List {
                    ForEach(quickActionsStore.fullList, id: \.self) { id in
                        QuickActionRowView(
                            id: id,
                            store: quickActionsStore,
                            theme: theme,
                            isBuiltin: BuiltinQuickAction.from(id: id) != nil
                        )
                    }
                    .onMove { src, dst in
                        quickActionsStore.reorderFull(from: src, to: dst)
                    }
                }
                .frame(minHeight: 240)
                .scrollContentBackground(.hidden)
            } header: {
                Text(L10n.Settings.QuickActions.heading)
            } footer: {
                Text(L10n.Settings.QuickActions.headingFooter)
                    .font(Font(DT.Font.small))
                    .foregroundColor(Color(theme.textTertiary))
            }

            Section {
                Button {
                    _ = quickActionsStore.addCustomAction()
                } label: {
                    Label(
                        String(localized: L10n.Settings.QuickActions.addCustomButton.withLocale(locale)),
                        systemImage: "plus.circle"
                    )
                }
                .buttonStyle(.borderless)
            }

            SettingsResetRow(
                settings: settings,
                keys: managedKeys,
                additionalAction: {
                    // SettingsResetRow only wipes the on-disk keys; the
                    // @Observable QuickActionsStore still holds the old
                    // arrays in memory. Reload so the top-bar buttons,
                    // Settings list, and command resolution all snap to
                    // the cleared state immediately instead of waiting
                    // for the next app launch.
                    quickActionsStore.reloadFromSettings()
                }
            )
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
