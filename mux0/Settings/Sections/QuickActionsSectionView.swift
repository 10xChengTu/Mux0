import SwiftUI

struct QuickActionsSectionView: View {
    let theme: AppTheme
    let settings: SettingsConfigStore
    let quickActionsStore: QuickActionsStore

    @Environment(\.locale) private var locale

    private var managedKeys: [String] {
        var keys = ["mux0-quickactions-enabled", "mux0-quickactions-custom"]
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

            SettingsResetRow(settings: settings, keys: managedKeys)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
