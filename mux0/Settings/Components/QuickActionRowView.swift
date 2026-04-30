import SwiftUI

/// One row in the Quick Actions Settings list. Renders icon + name (read-only
/// for built-ins, editable for custom) + command field + enabled toggle +
/// optional delete button (custom only). All edits flow through
/// `QuickActionsStore` mutate API; the view is a thin binding shell.
///
/// Built-in vs custom is decided by callers via `isBuiltin: Bool` rather than
/// recomputed inside this view, because the parent List already knows the
/// distinction (it filters and orders the full list).
struct QuickActionRowView: View {
    let id: QuickActionId
    let store: QuickActionsStore
    let theme: AppTheme
    let isBuiltin: Bool

    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: 8) {
            QuickActionIconView(source: store.iconSource(for: id),
                                size: 16,
                                color: Color(theme.textSecondary))
                .frame(width: 24)

            if isBuiltin {
                Text(store.displayName(for: id, locale: locale))
                    .frame(width: 110, alignment: .leading)
                    .foregroundColor(Color(theme.textPrimary))
            } else {
                TextField(
                    String(localized: L10n.Settings.QuickActions.customNamePlaceholder.withLocale(locale)),
                    text: nameBinding
                )
                .themedTextField(theme)
                .frame(width: 110)
            }

            TextField(commandPlaceholder, text: commandBinding)
                .themedTextField(theme)
                .frame(maxWidth: .infinity)

            Toggle("", isOn: enabledBinding)
                .toggleStyle(.switch)
                .labelsHidden()

            if !isBuiltin {
                Button {
                    store.removeCustomAction(id)
                } label: {
                    Image(systemName: "trash")
                        .foregroundColor(Color(theme.textTertiary))
                }
                .buttonStyle(.borderless)
                .help(String(localized: L10n.Settings.QuickActions.deleteCustomTooltip.withLocale(locale)))
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Bindings

    private var nameBinding: Binding<String> {
        Binding(
            get: { store.customActions.first(where: { $0.id == id })?.name ?? "" },
            set: { store.updateCustomAction(id, name: $0) }
        )
    }

    private var commandBinding: Binding<String> {
        Binding(
            get: {
                if isBuiltin {
                    return store.builtinCommandOverrides[id] ?? ""
                }
                return store.customActions.first(where: { $0.id == id })?.command ?? ""
            },
            set: { newValue in
                if isBuiltin {
                    store.setBuiltinCommand(id, newValue)
                } else {
                    store.updateCustomAction(id, command: newValue)
                }
            }
        )
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { store.isEnabled(id) },
            set: { store.setEnabled(id, $0) }
        )
    }

    private var commandPlaceholder: String {
        if let builtin = BuiltinQuickAction.from(id: id) {
            return builtin.defaultCommand
        }
        return String(localized: L10n.Settings.QuickActions.customCommandPlaceholder.withLocale(locale))
    }
}
