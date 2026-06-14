// SPDX-License-Identifier: MIT
// Provenance: clean-room from Apple docs (NSView, Auto Layout, CATransaction).
import AppKit

/// The content view of a `DesktopWindow`. Hosts exactly one renderer's view and swaps it
/// atomically (no flash) when the wallpaper changes.
@MainActor
public final class RendererHostView: NSView {
    private var hosted: NSView?

    public override var isFlipped: Bool { true }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Replace the hosted content view, pinned to fill, inside a single transaction.
    public func setContent(_ view: NSView?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hosted?.removeFromSuperview()
        hosted = view
        if let view {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        CATransaction.commit()
    }
}
