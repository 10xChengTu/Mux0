import SwiftUI

struct QuickActionsSectionView: View {
    let theme: AppTheme
    let settings: SettingsConfigStore
    let quickActionsStore: QuickActionsStore

    var body: some View {
        Form {
            // Real UI lands in Tasks 5-7. Placeholder for now so the section
            // is reachable from the tab strip and compile-checked.
            Text("Quick Actions UI — implemented in Tasks 5-7")
                .foregroundColor(Color(theme.textTertiary))
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
