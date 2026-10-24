import AppKit
import UniformTypeIdentifiers

/// One text or Markdown file. Markdown opens formatted, read-only; plain text
/// opens ready to edit.
final class TextDocument: NSDocument {
    /// The contents as last read from disk. While the document is being
    /// edited, the window's editor holds the live text.
    private(set) var text = ""
    private var encoding: String.Encoding = .utf8
    /// Watches the file so changes made by other apps show up right away.
    private var watcher: DispatchSourceFileSystemObject?
    private var reloadPending = false

    override var fileURL: URL? {
        didSet { if fileURL != oldValue { watchFile() } }
    }

    override class var autosavesInPlace: Bool { true }

    /// Markdown is decided by the file's name, so a new document saved as
    /// "notes.md" becomes Markdown.
    var isMarkdown: Bool {
        guard let url = fileURL, let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: Self.markdown)
    }

    static let markdown = UTType("net.daringfireball.markdown") ?? .plainText

    private var windowController: DocumentWindowController? {
        windowControllers.first as? DocumentWindowController
    }

    override func makeWindowControllers() {
        addWindowController(DocumentWindowController())
    }

    override func read(from data: Data, ofType typeName: String) throws {
        guard let decoded = TextEncoding.decode(data) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        text = decoded.text
        encoding = decoded.encoding
    }

    override func data(ofType typeName: String) throws -> Data {
        TextEncoding.encode(windowController?.currentText() ?? text, preferred: encoding)
    }

    /// Reloaded from disk, after Revert or when another app changed the file.
    override func revert(toContentsOf url: URL, ofType typeName: String) throws {
        try super.revert(toContentsOf: url, ofType: typeName)
        undoManager?.removeAllActions()
        windowController?.documentDidReload()
    }

    override func close() {
        watcher?.cancel()
        watcher = nil
        super.close()
    }

    // MARK: Changes made by other apps

    /// One kernel event source per open file: no polling, no timers.
    private func watchFile() {
        watcher?.cancel()
        watcher = nil
        guard let url = fileURL else { return }
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self, unowned source] in
            guard let self else { return }
            // Editors usually save by replacing the file: follow the new one.
            let replaced = !source.data.isDisjoint(with: [.delete, .rename])
            self.scheduleReload(rewatch: replaced)
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
        watcher = source
    }

    private func scheduleReload(rewatch: Bool) {
        if rewatch {
            watcher?.cancel()
            watcher = nil
        }
        guard !reloadPending else { return }
        reloadPending = true
        // Let the other app finish writing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.reloadPending = false
            if self.watcher == nil { self.watchFile() }
            self.reloadIfChangedOnDisk()
        }
    }

    /// Reloads when the file on disk is newer than what is shown, unless
    /// there are changes here that would be lost.
    private func reloadIfChangedOnDisk() {
        guard let url = fileURL, let type = fileType, !isDocumentEdited,
              let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              date != fileModificationDate else { return }
        try? revert(toContentsOf: url, ofType: type)
    }

    /// Any name and extension can be typed; ".md" makes it Markdown.
    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        savePanel.allowedContentTypes = [.plainText, Self.markdown]
        savePanel.allowsOtherFileTypes = true
        savePanel.isExtensionHidden = false
        return true
    }

    override var shouldRunSavePanelWithAccessoryView: Bool { false }

    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                       completionHandler: @escaping (Error?) -> Void) {
        let wasMarkdown = isMarkdown
        super.save(to: url, ofType: typeName, for: saveOperation) { [weak self] error in
            if let self, error == nil, self.isMarkdown != wasMarkdown { self.windowController?.documentKindChanged() }
            completionHandler(error)
        }
    }

    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        let info = printInfo.copy() as! NSPrintInfo
        info.dictionary().addEntries(from: printSettings)
        info.horizontalPagination = .fit
        info.isVerticallyCentered = false
        info.topMargin = 54; info.bottomMargin = 54; info.leftMargin = 54; info.rightMargin = 54
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let current = windowController?.currentText() ?? text
        let content: NSAttributedString
        if isMarkdown && windowController?.mode != .editing {
            content = MarkdownRenderer(baseURL: fileURL, scale: 0.8, columnWidth: width).render(current).text
        } else {
            content = NSAttributedString(string: current, attributes: [
                .font: isMarkdown ? Style.editorMonoFont(scale: 0.85) : Style.editorFont(scale: 0.85),
                .foregroundColor: NSColor.black,
            ])
        }
        let view = NSTextView(usingTextLayoutManager: false)
        view.frame = NSRect(x: 0, y: 0, width: width, height: 100)
        view.appearance = NSAppearance(named: .aqua)
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textStorage?.setAttributedString(content)
        view.isVerticallyResizable = true
        view.sizeToFit()
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.jobTitle = displayName
        return operation
    }
}
