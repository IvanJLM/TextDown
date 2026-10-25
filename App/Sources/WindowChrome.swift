import AppKit

/// Hides the title bar into the page, as Vids does with video: the close,
/// minimize and zoom buttons and the document's name appear while the mouse
/// moves over the window and fade out two seconds after it stops. Scrolling
/// with the trackpad does not bring them back, so reading stays clean.
/// Nothing runs while the mouse is still: the timer exists only while the
/// mouse has just moved.
@MainActor
final class WindowChrome: NSResponder {
    static let idleDelay: TimeInterval = 2
    /// Height of the band at the top that keeps the buttons visible.
    private static let titleBand: CGFloat = 40

    private weak var window: NSWindow?
    private let shade = TopShade()
    private(set) var hideTimer: Timer?
    private(set) var isShown = true
    /// True in full screen, where macOS manages the title bar itself.
    private var isSuspended = false

    init(window: NSWindow, content: NSView) {
        self.window = window
        super.init()
        shade.frame = NSRect(x: 0, y: content.bounds.height - TopShade.height,
                             width: content.bounds.width, height: TopShade.height)
        shade.autoresizingMask = [.width, .minYMargin]
        content.addSubview(shade)
        content.addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var titlebar: NSView? { window?.standardWindowButton(.closeButton)?.superview }

    /// Keeps the shade above whatever view the window shows now.
    func bringShadeToFront() {
        guard let content = shade.superview else { return }
        content.addSubview(shade, positioned: .above, relativeTo: nil)
    }

    /// Shows the buttons and starts the countdown to hide them.
    func show() {
        if !isShown && !isSuspended {
            isShown = true
            titlebar?.isHidden = false
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                titlebar?.animator().alphaValue = 1
                shade.animator().alphaValue = 1
            }
        }
        restartTimer()
    }

    func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        guard isShown, !isSuspended else { return }
        isShown = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.35
            titlebar?.animator().alphaValue = 0
            shade.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isShown else { return }
                self.titlebar?.isHidden = true // no clicks on invisible buttons
            }
        })
    }

    /// Full screen: macOS shows the title bar when the pointer reaches the top.
    func suspend() {
        isSuspended = true
        isShown = true
        hideTimer?.invalidate()
        hideTimer = nil
        titlebar?.isHidden = false
        titlebar?.alphaValue = 1
        shade.alphaValue = 0
    }

    func resume() {
        isSuspended = false
        shade.alphaValue = 1
        show()
    }

    /// The window is closing: no timer outlives it.
    func stop() {
        hideTimer?.invalidate()
        hideTimer = nil
    }

    private func restartTimer() {
        let fire = Date().addingTimeInterval(Self.idleDelay)
        if let timer = hideTimer, timer.isValid {
            timer.fireDate = fire
        } else {
            let timer = Timer(timeInterval: Self.idleDelay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.hideIfIdle() }
            }
            timer.tolerance = 0.2 // lets macOS group the wake-up with others
            RunLoop.main.add(timer, forMode: .common)
            hideTimer = timer
        }
    }

    private func hideIfIdle() {
        hideTimer = nil
        guard let window, let content = window.contentView else { return }
        let point = content.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if content.bounds.contains(point) && point.y > content.bounds.height - Self.titleBand && !isSuspended {
            // The pointer rests on the buttons: they stay until it moves again,
            // without waking up every two seconds to check.
            return
        }
        hide()
    }

    override func mouseEntered(with event: NSEvent) { show() }
    override func mouseMoved(with event: NSEvent) { show() }
    override func mouseExited(with event: NSEvent) { hide() }
}

/// A soft band of the page's own color behind the buttons and the title, so
/// they read over the text scrolled beneath them.
private final class TopShade: NSView {
    /// The title bar's own height: the find bar, just below it, stays clear.
    static let height: CGFloat = 32

    override func draw(_ dirtyRect: NSRect) {
        let page = NSColor.textBackgroundColor
        NSGradient(colors: [page, page.withAlphaComponent(0.9), page.withAlphaComponent(0)],
                   atLocations: [0, 0.7, 1], colorSpace: .sRGB)?.draw(in: bounds, angle: -90)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
