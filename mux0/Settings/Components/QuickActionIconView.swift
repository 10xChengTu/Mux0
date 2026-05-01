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
        // 三个分支统一到 (size+4) × (size+4) 外框。SF Symbol 用 size pt
        // .regular 与 chrome 按钮（sidebar toggle / 设置齿轮 / 关闭 X / "+"）
        // 一致；asset 在 (size-1)×(size-1) 内框里居中，留出 ~2.5pt 边距，
        // 使 PNG/PDF logo 不会边到边撑满；letter 用 (size-2)pt rounded
        // semibold + 17pt 圆环，保留"用户自定义"视觉标识。
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
                .frame(width: size - 1, height: size - 1)
                .frame(width: size + 4, height: size + 4)
        case .letter(let c):
            Text(String(c))
                .font(.system(size: size - 2, weight: .semibold, design: .rounded))
                .foregroundColor(color)
                .frame(width: size + 4, height: size + 4)
                .overlay(
                    // 给圆环加 2pt 内缩，让圆圈直径从 size+4 收到 size，
                    // 与 SF Symbol 分支的视觉直径一致，外圈与行内其他元素
                    // 之间留出 2pt 余白。
                    Circle()
                        .stroke(color.opacity(0.4), lineWidth: 1)
                        .padding(2)
                )
        }
    }
}
