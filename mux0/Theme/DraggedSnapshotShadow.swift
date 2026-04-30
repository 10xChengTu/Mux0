import AppKit

/// Composes a "smooth shadow" stack under a row/tab snapshot for use as
/// the dragging ghost. Approach follows Josh Comeau's layered-shadow
/// recipe (https://www.joshwcomeau.com/css/designing-shadows/): four
/// stacked shadows with very low individual alpha (≈0.05) and
/// exponentially-doubling offset / blur. The effect: a soft natural
/// falloff that reads as "lifted" without the muddy, concentrated edge
/// that single-layer or Material-style stacks leave on translucent
/// macOS surfaces.
///
/// Returned image is `padding`-pt larger on every side than the source
/// snapshot. The accompanying frame is offset by `-padding` on x/y, so
/// callers pass it directly to `NSDraggingItem.setDraggingFrame(_:contents:)`
/// and the cursor stays anchored to the same point on the original row.
enum DraggedSnapshotShadow {
    /// Per-side padding reserved for the shadow halo. Sized so the
    /// largest layer (offset 8pt + blur 8pt) doesn't clip at the image
    /// edge — the visible reach of an NSShadow is ~1.5σ of its blur.
    static let padding: CGFloat = 20

    /// Four-layer smooth-shadow stack. Each pass is barely visible
    /// alone; only the accumulation reads as shadow. Doubling
    /// offset/blur produces a naturally-decaying falloff curve.
    /// AppKit's NSShadow uses an unflipped coordinate space, so a
    /// visually-down CSS offset becomes a negative `shadowOffset.height`.
    private static let layers: [(dy: CGFloat, blur: CGFloat, alpha: CGFloat)] = [
        (-1, 1, 0.05),
        (-2, 2, 0.05),
        (-4, 4, 0.05),
        (-8, 8, 0.05),
    ]

    static func compose(content snapshot: NSImage,
                        contentSize: NSSize,
                        cornerRadius: CGFloat) -> (image: NSImage, frame: NSRect) {
        let outerSize = NSSize(width: contentSize.width + padding * 2,
                                height: contentSize.height + padding * 2)
        let cardRect = NSRect(x: padding, y: padding,
                              width: contentSize.width,
                              height: contentSize.height)
        let path = NSBezierPath(roundedRect: cardRect,
                                 xRadius: cornerRadius,
                                 yRadius: cornerRadius)

        let composed = NSImage(size: outerSize)
        composed.lockFocus()
        defer { composed.unlockFocus() }

        // Each layer: fill `path` with opaque black under an NSShadow.
        // After the loop the card region is fully opaque black; we punch
        // it back out below so the snapshot's anti-aliased edges blend
        // cleanly with the surrounding shadow halo.
        for layer in layers {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowOffset = NSSize(width: 0, height: layer.dy)
            shadow.shadowBlurRadius = layer.blur
            shadow.shadowColor = NSColor.black.withAlphaComponent(layer.alpha)
            shadow.set()
            NSColor.black.set()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        if let cgctx = NSGraphicsContext.current?.cgContext {
            cgctx.saveGState()
            cgctx.setBlendMode(.clear)
            path.fill()
            cgctx.restoreGState()
        }

        // Clip the snapshot to the rounded card so any non-rounded
        // pixels in the source bitmap get masked into the same shape
        // the shadow was drawn for.
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        snapshot.draw(in: cardRect)
        NSGraphicsContext.restoreGraphicsState()

        let frame = NSRect(x: -padding, y: -padding,
                           width: outerSize.width, height: outerSize.height)
        return (composed, frame)
    }
}
