import AppKit

/// A text view that keeps its text in a centered column of comfortable
/// width, however wide the window is.
final class ColumnTextView: NSTextView {
    /// The widest the text column gets.
    var maxColumnWidth: CGFloat = Style.column {
        didSet { updateInset() }
    }
    /// Called when the text column changes width, once a live resize ends.
    var onColumnWidthChange: ((CGFloat) -> Void)?
    private var lastReportedWidth: CGFloat = 0

    var columnWidth: CGFloat {
        bounds.width - textContainerInset.width * 2 - (textContainer?.lineFragmentPadding ?? 0) * 2
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateInset()
        if !inLiveResize { reportWidth() }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        reportWidth()
    }

    private func updateInset() {
        let side = max(Style.margin, ((bounds.width - maxColumnWidth) / 2).rounded(.down))
        let vertical: CGFloat = 26
        if textContainerInset.width != side || textContainerInset.height != vertical {
            textContainerInset = NSSize(width: side, height: vertical)
        }
    }

    private func reportWidth() {
        let width = columnWidth
        guard abs(width - lastReportedWidth) >= 1 else { return }
        lastReportedWidth = width
        onColumnWidthChange?(width)
    }
}

/// A scroll view that draws only what is on screen. AppKit's responsive
/// scrolling keeps rendered text above and below the window too, which costs
/// several megabytes per window and buys nothing for plain text.
final class LeanScrollView: NSScrollView {
    override class var isCompatibleWithResponsiveScrolling: Bool { false }
}
