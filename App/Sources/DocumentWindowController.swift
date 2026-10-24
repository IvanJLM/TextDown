import AppKit

/// The window of one document. Markdown is shown formatted and read-only
/// (the reader); ⌘E switches to its source (the editor) and back. Plain text
/// only has the editor. Each view is made the first time it is needed.
final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate, NSMenuItemValidation {
    enum Mode { case reading, editing }

    private(set) var mode: Mode = .editing
    private var reader: ColumnTextView?
    private var readerScroll: NSScrollView?
    private var editor: ColumnTextView?
    private var editorScroll: NSScrollView?
    private var anchors: [String: Int] = [:]
    private var images: [RenderedImage] = []
    private var zoom: CGFloat = 1
    private var shown = false
    /// What the reader shows, so an unchanged document is not formatted again.
    private var rendered: (source: String, zoom: CGFloat)?
    private var renderGeneration = 0
    /// True while a large document is being formatted in the background.
    private(set) var isRendering = false

    /// Documents larger than this (UTF-8 bytes, about 80 ms of work) are
    /// formatted off the main thread: the window stays responsive meanwhile.
    static let backgroundRenderSize = 64 * 1024
    private static let renderQueue = DispatchQueue(label: "com.ivanjlm.textdown.render", qos: .userInitiated,
                                                   autoreleaseFrequency: .workItem)

    private var textDocument: TextDocument? { document as? TextDocument }

    init() {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: min(Style.column + 2 * 60, screen.width * 0.9), height: min(screen.height * 0.82, 940))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: true)
        window.minSize = NSSize(width: 360, height: 240)
        window.backgroundColor = .textBackgroundColor
        window.tabbingMode = .disallowed
        window.isRestorable = false
        window.center()
        // Each new window sits a step below and to the right of the last one.
        if let previous = NSApp.orderedWindows.first(where: { $0.isVisible && $0.windowController is DocumentWindowController }) {
            let topLeft = NSPoint(x: previous.frame.minX + 26, y: previous.frame.maxY - 26)
            window.setFrameTopLeftPoint(topLeft)
            window.setFrame(window.constrainFrameRect(window.frame, to: previous.screen), display: false)
        }
        super.init(window: window)
        window.delegate = self
        shouldCascadeWindows = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var document: AnyObject? {
        didSet {
            guard !shown, let textDocument else { return }
            shown = true
            setMode(textDocument.isMarkdown ? .reading : .editing)
        }
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        textDocument?.undoManager
    }

    // MARK: Document

    /// The text to save: the editor's while it exists, otherwise the file's.
    func currentText() -> String? {
        guard let editor else { return nil }
        editor.breakUndoCoalescing()
        return editor.string
    }

    func documentDidReload() {
        guard let textDocument else { return }
        if let editor {
            let selection = editor.selectedRanges
            editor.string = textDocument.text
            let length = (editor.string as NSString).length
            editor.selectedRanges = selection.map { range in
                NSValue(range: NSIntersectionRange(range.rangeValue, NSRange(location: 0, length: length)))
            }
        }
        if mode == .reading { renderReader(keeping: currentPlace()) }
    }

    /// Saved under a new name that changes it from text to Markdown or back.
    func documentKindChanged() {
        guard let textDocument else { return }
        if !textDocument.isMarkdown && mode == .reading { setMode(.editing) }
        if let editor { styleEditor(editor) }
    }

    // MARK: Modes

    private func setMode(_ newMode: Mode) {
        guard let window else { return }
        let place = currentPlace()
        mode = newMode
        switch newMode {
        case .reading:
            let scroll = readerScroll ?? makeReader()
            window.contentView = scroll
            window.makeFirstResponder(reader)
            scroll.layoutSubtreeIfNeeded()
            renderReader(keeping: place)
        case .editing:
            let scroll = editorScroll ?? makeEditor()
            window.contentView = scroll
            window.makeFirstResponder(editor)
            scroll.layoutSubtreeIfNeeded()
            restore(place)
        }
    }

    @objc func toggleEditing(_ sender: Any?) {
        guard textDocument?.isMarkdown == true else { return }
        setMode(mode == .reading ? .editing : .reading)
    }

    private func makeScrollView(for textView: NSTextView) -> NSScrollView {
        let scroll = LeanScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        // One background, the window's: no extra layers to paint it again.
        scroll.drawsBackground = false
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.drawsBackground = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.delegate = self
        scroll.documentView = textView
        return scroll
    }

    /// The reader: TextKit 1, because tables and boxed blocks need it.
    private func makeReader() -> NSScrollView {
        let view = ColumnTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.importsGraphics = false
        view.layoutManager?.allowsNonContiguousLayout = true
        view.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        view.onColumnWidthChange = { [weak self] width in self?.fitImages(to: width) }
        let scroll = makeScrollView(for: view)
        reader = view
        readerScroll = scroll
        return scroll
    }

    /// The editor: plain text, TextKit 2, nothing changed behind your back.
    private func makeEditor() -> NSScrollView {
        let view = ColumnTextView(usingTextLayoutManager: true)
        view.isEditable = true
        view.isSelectable = true
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.smartInsertDeleteEnabled = false
        let scroll = makeScrollView(for: view)
        editor = view
        editorScroll = scroll
        styleEditor(view)
        view.string = textDocument?.text ?? ""
        view.setSelectedRange(NSRange(location: 0, length: 0))
        return scroll
    }

    private func styleEditor(_ view: ColumnTextView) {
        let markdown = textDocument?.isMarkdown == true
        let font = markdown ? Style.editorMonoFont(scale: zoom) : Style.editorFont(scale: zoom)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = markdown ? 1.2 : 1.25
        view.font = font
        view.textColor = .labelColor
        view.defaultParagraphStyle = paragraph
        view.typingAttributes = [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
        if let storage = view.textStorage, storage.length > 0 {
            storage.setAttributes(view.typingAttributes, range: NSRange(location: 0, length: storage.length))
        }
        view.maxColumnWidth = Style.column * zoom
    }

    /// Formats the Markdown for the reader, unless it already shows this text
    /// at this zoom. Large documents are formatted in the background; the
    /// reader keeps showing what it had until the new text is ready.
    private func renderReader(keeping place: Place?) {
        guard reader != nil, let textDocument else { return }
        let source = currentText() ?? textDocument.text
        let zoom = zoom
        if let rendered, rendered.zoom == zoom, rendered.source == source {
            restore(place)
            return
        }
        let renderer = MarkdownRenderer(baseURL: textDocument.fileURL, scale: zoom, columnWidth: Style.column * zoom)
        renderGeneration += 1
        let generation = renderGeneration
        guard source.utf8.count > Self.backgroundRenderSize else {
            isRendering = false
            show(renderer.render(source), of: source, zoom: zoom, keeping: place)
            return
        }
        isRendering = true
        Self.renderQueue.async { [weak self] in
            let result = renderer.render(source)
            DispatchQueue.main.async {
                // A newer render (another zoom, a reload) replaces this one.
                guard let self, generation == self.renderGeneration else { return }
                self.isRendering = false
                self.show(result, of: source, zoom: zoom, keeping: place)
            }
        }
    }

    private func show(_ result: RenderedMarkdown, of source: String, zoom: CGFloat, keeping place: Place?) {
        guard let reader else { return }
        reader.maxColumnWidth = Style.column * zoom
        if let storage = reader.textStorage {
            // Emptied first: replacing a long formatted text in place merges
            // the old and new attribute runs one by one (2 s for 1 MB);
            // filling an empty storage takes a few milliseconds.
            storage.beginEditing()
            storage.setAttributedString(NSAttributedString())
            storage.setAttributedString(result.text)
            storage.endEditing()
        }
        anchors = result.anchors
        images = result.images
        rendered = (source, zoom)
        fitImages(to: reader.columnWidth)
        // Parsing leaves free memory behind; give it back to the system.
        DispatchQueue.main.async { malloc_zone_pressure_relief(nil, 0) }
        if mode == .reading { restore(place) }
    }

    /// Images are never wider than the column; narrow the window and they
    /// shrink with it.
    private func fitImages(to columnWidth: CGFloat) {
        guard let storage = reader?.textStorage, columnWidth > 0, !images.isEmpty else { return }
        var changed = false
        // One layout pass for all the images, not one per image.
        storage.beginEditing()
        defer { storage.endEditing() }
        for image in images where image.location < storage.length {
            let width = min(image.naturalSize.width, columnWidth).rounded(.down)
            guard abs(image.attachment.bounds.width - width) >= 1 else { continue }
            image.attachment.bounds = CGRect(x: 0, y: 0, width: width,
                                             height: (image.naturalSize.height * width / image.naturalSize.width).rounded())
            storage.edited(.editedAttributes, range: NSRange(location: image.location, length: 1), changeInLength: 0)
            changed = true
        }
        if changed { reader?.needsDisplay = true }
    }

    private func activeScroll() -> NSScrollView? {
        mode == .reading ? readerScroll : editorScroll
    }

    // MARK: Keeping the place

    /// The first character on screen, and the length of the text it is in.
    /// Kept by character, not by height: finding a height means laying out
    /// the whole document, while finding a character only needs the lines
    /// around it.
    private struct Place {
        var character: Int
        var length: Int
        var mode: Mode
    }

    private func currentPlace() -> Place? {
        guard let scroll = activeScroll(), window?.contentView === scroll, let view = scroll.documentView as? NSTextView,
              let length = view.textStorage?.length, length > 0 else { return nil }
        let top = scroll.contentView.bounds.minY
        let character = top <= view.textContainerOrigin.y ? 0
            : view.characterIndexForInsertion(at: NSPoint(x: view.textContainerOrigin.x + 1, y: top + 1))
        return Place(character: min(character, length), length: length, mode: mode)
    }

    /// Scrolls back to a place: the same character when the text is the same,
    /// otherwise the same proportion of the text (the source and the
    /// formatted text are about as long as each other).
    private func restore(_ place: Place?) {
        guard let place, let view = activeScroll()?.documentView as? NSTextView,
              let length = view.textStorage?.length, length > 0 else { return }
        let character = place.mode == mode && place.length == length
            ? place.character
            : Int((Double(place.character) / Double(max(place.length, 1)) * Double(length)).rounded())
        scrollToCharacter(character)
    }

    /// Puts the line holding a character at the top of the window, laying out
    /// only the text up to it in TextKit 1 (the reader) or around it in
    /// TextKit 2 (the editor).
    func scrollToCharacter(_ character: Int) {
        guard let scroll = activeScroll(), let view = scroll.documentView as? NSTextView,
              let length = view.textStorage?.length else { return }
        let index = min(max(0, character), max(0, length - 1))
        // First let AppKit bring the character on screen: it lays out the
        // text around it and makes the view tall enough to scroll there.
        view.scrollRangeToVisible(NSRange(location: index, length: 0))
        var y: CGFloat = 0
        // TextKit 2 first: asking a TextKit 2 view for its layoutManager
        // would switch it to TextKit 1 for good.
        if index > 0, let layout = view.textLayoutManager {
            if let location = layout.location(layout.documentRange.location, offsetBy: index) {
                layout.ensureLayout(for: NSTextRange(location: location))
                layout.enumerateTextLayoutFragments(from: location, options: [.ensuresLayout]) { fragment in
                    y = fragment.layoutFragmentFrame.minY
                    return false
                }
            }
        } else if index > 0, let layout = view.layoutManager {
            layout.ensureLayout(forCharacterRange: NSRange(location: index, length: 1))
            y = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: index), effectiveRange: nil).minY
        }
        if index > 0 { y += view.textContainerOrigin.y }
        view.layoutSubtreeIfNeeded()
        let limit = max(0, view.frame.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, y), limit)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    // MARK: Links

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url: URL?
        switch link {
        case let value as URL: url = value
        case let value as String: url = URL(string: value)
        default: url = nil
        }
        guard let url else { return true }
        let string = url.relativeString
        if url.scheme == nil, string.hasPrefix("#") {
            let anchor = String(string.dropFirst()).removingPercentEncoding?.lowercased() ?? ""
            if let location = anchors[anchor] ?? anchors[MarkdownRenderer.slug(anchor)] {
                textView.scrollRangeToVisible(NSRange(location: location, length: 0))
                textView.showFindIndicator(for: NSRange(location: location, length: 1))
                if let scroll = readerScroll {
                    // Put the heading at the top, not just somewhere on screen.
                    let rect = textView.firstRect(forCharacterRange: NSRange(location: location, length: 1), actualRange: nil)
                    let inView = textView.convert(window?.convertFromScreen(rect) ?? .zero, from: nil)
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, inView.minY - 12)))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
            }
            return true
        }
        guard let target = MarkdownRenderer(baseURL: textDocument?.fileURL).resolve(url) else { return true }
        if target.isFileURL {
            let file = URL(fileURLWithPath: target.path)
            guard FileManager.default.fileExists(atPath: file.path) else { NSSound.beep(); return true }
            if ["md", "markdown", "txt", "text"].contains(file.pathExtension.lowercased()) {
                NSDocumentController.shared.openDocument(withContentsOf: file, display: true) { _, _, _ in }
            } else {
                NSWorkspace.shared.open(file)
            }
        } else {
            NSWorkspace.shared.open(target)
        }
        return true
    }

    // MARK: Zoom

    @objc func zoomIn(_ sender: Any?) { setZoom(Style.zoomLevels.first { $0 > zoom + 0.001 } ?? zoom) }
    @objc func zoomOut(_ sender: Any?) { setZoom(Style.zoomLevels.last { $0 < zoom - 0.001 } ?? zoom) }
    @objc func actualSize(_ sender: Any?) { setZoom(1) }

    private func setZoom(_ value: CGFloat) {
        guard value != zoom else { return }
        let place = currentPlace()
        zoom = value
        if let editor { styleEditor(editor) }
        if mode == .reading { renderReader(keeping: place) } else { restore(place) }
    }

    // MARK: Menu commands

    @objc func showInFinder(_ sender: Any?) {
        guard let url = textDocument?.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleEditing(_:)):
            menuItem.title = mode == .editing && textDocument?.isMarkdown == true ? "Show Formatted" : "Edit Markdown"
            return textDocument?.isMarkdown == true
        case #selector(showInFinder(_:)):
            return textDocument?.fileURL != nil
        case #selector(zoomIn(_:)):
            return zoom < Style.zoomLevels.last!
        case #selector(zoomOut(_:)):
            return zoom > Style.zoomLevels.first!
        case #selector(actualSize(_:)):
            return zoom != 1
        default:
            return true
        }
    }

    func windowWillClose(_ notification: Notification) {
        reader?.delegate = nil
        editor?.delegate = nil
    }
}
