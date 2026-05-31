import AppKit

/// 链接 hover 提示气泡。一个无边框、不激活、不接收鼠标事件的浮层窗口，
/// 显示「⌘ + 单击打开链接」之类提示。由 GhosttyTerminalView 在普通 hover
/// 链接时显示，Cmd 按下或离开链接时隐藏。使用系统 toolTip 材质与语义色，
/// 不引入主题耦合。
final class LinkHintTooltip {
    private var label: NSTextField?

    private lazy var window: NSWindow = {
        let w = NSWindow(
            contentRect: .zero,
            styleMask: .borderless,
            backing: .buffered,
            defer: true
        )
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .floating
        w.ignoresMouseEvents = true
        w.hasShadow = true

        let blur = NSVisualEffectView()
        blur.material = .toolTip
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 5
        blur.layer?.masksToBounds = true

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .labelColor
        label.backgroundColor = .clear
        label.isBordered = false
        blur.addSubview(label)

        w.contentView = blur
        self.label = label
        return w
    }()

    /// 在屏幕坐标 `screenPoint` 附近显示提示。
    func show(_ text: String, at screenPoint: NSPoint) {
        _ = window
        guard let label else { return }
        label.stringValue = text
        label.sizeToFit()

        let padX: CGFloat = 8
        let padY: CGFloat = 5
        let size = NSSize(
            width: label.frame.width + padX * 2,
            height: label.frame.height + padY * 2
        )
        label.setFrameOrigin(NSPoint(x: padX, y: padY))
        window.setContentSize(size)
        window.contentView?.frame = NSRect(origin: .zero, size: size)
        // 放在光标右下方一点，避免遮住链接本身。
        window.setFrameOrigin(NSPoint(x: screenPoint.x + 12,
                                      y: screenPoint.y - size.height - 12))
        window.orderFront(nil)
    }

    func hide() {
        window.orderOut(nil)
    }
}
