import SwiftUI

/// Render a `QuickActionIcon` at a configurable size and color. The view does
/// NOT read theme from environment — the caller passes the desired color so
/// the same component can be used in Settings rows (theme.textSecondary) and
/// in the top-bar button (theme.textSecondary, but plumbed via different
/// intermediate views).
///
/// Letter rendering uses a circular outline so user-defined custom actions
/// stay visually distinct from the SF-symbol/branded built-ins.
struct QuickActionIconView: View {
    let source: QuickActionIcon
    var size: CGFloat = 16
    var color: Color = .primary

    var body: some View {
        switch source {
        case .sfSymbol(let name):
            Image(systemName: name)
                .font(.system(size: size, weight: .regular))
                .foregroundColor(color)
                .frame(width: size + 4, height: size + 4)
        case .asset(let name):
            Image(name)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundColor(color)
                .frame(width: size, height: size)
        case .letter(let c):
            Text(String(c))
                .font(.system(size: size - 4, weight: .semibold, design: .rounded))
                .foregroundColor(color)
                .frame(width: size + 4, height: size + 4)
                .overlay(
                    Circle()
                        .stroke(color.opacity(0.4), lineWidth: 1)
                )
        }
    }
}
