import AppKit
import XCTest
@testable import TextDown

/// The document window: keeping the place on zoom and ⌘E, formatting large
/// documents in the background, and not formatting an unchanged one again.
final class WindowTests: XCTestCase {
    private func open(_ text: String, name: String) throws -> (TextDocument, DocumentWindowController) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        let document = try TextDocument(contentsOf: url, ofType: name.hasSuffix(".md") ? "net.daringfireball.markdown" : "public.plain-text")
        document.makeWindowControllers()
        let controller = try XCTUnwrap(document.windowControllers.first as? DocumentWindowController)
        controller.window?.setFrame(NSRect(x: 0, y: 0, width: 900, height: 700), display: false)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        addTeardownBlock {
            document.close()
            try? FileManager.default.removeItem(at: folder)
        }
        waitForRender(controller)
        return (document, controller)
    }

    private func waitForRender(_ controller: DocumentWindowController) {
        let deadline = Date().addingTimeInterval(20)
        while controller.isRendering && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertFalse(controller.isRendering)
    }

    private func view<T>(_ controller: DocumentWindowController, _ name: String) -> T? {
        Mirror(reflecting: controller).children.first { $0.label == name }?.value as? T
    }

    /// The first character on screen in the reader or the editor.
    private func firstVisible(_ controller: DocumentWindowController) throws -> Int {
        let scroll: NSScrollView = try XCTUnwrap(view(controller, controller.mode == .reading ? "readerScroll" : "editorScroll"))
        let text = try XCTUnwrap(scroll.documentView as? NSTextView)
        return text.characterIndexForInsertion(at: NSPoint(x: text.textContainerOrigin.x + 1, y: scroll.contentView.bounds.minY + 1))
    }

    private var largeMarkdown: String {
        get throws { String(repeating: try String(contentsOf: fixture("Sample.md"), encoding: .utf8) + "\n", count: 80) }
    }

    func testLargeDocumentsAreFormattedInTheBackground() throws {
        let source = try largeMarkdown
        XCTAssertGreaterThan(source.utf8.count, DocumentWindowController.backgroundRenderSize)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("big.md")
        try Data(source.utf8).write(to: url)
        let document = try TextDocument(contentsOf: url, ofType: "net.daringfireball.markdown")
        defer { document.close() }
        document.makeWindowControllers()
        let controller = try XCTUnwrap(document.windowControllers.first as? DocumentWindowController)
        XCTAssertTrue(controller.isRendering, "the window does not wait for the formatting")
        waitForRender(controller)
        let reader: NSTextView = try XCTUnwrap(view(controller, "reader"))
        XCTAssertGreaterThan(reader.textStorage?.length ?? 0, 50_000)
    }

    func testZoomKeepsTheReaderInPlace() throws {
        let (_, controller) = try open(try largeMarkdown, name: "big.md")
        let reader: NSTextView = try XCTUnwrap(view(controller, "reader"))
        controller.scrollToCharacter(reader.textStorage!.length / 2)
        let before = try firstVisible(controller)
        XCTAssertGreaterThan(before, 1000)
        controller.zoomIn(nil)
        waitForRender(controller)
        XCTAssertEqual(Double(try firstVisible(controller)), Double(before), accuracy: 150)
        controller.actualSize(nil)
        waitForRender(controller)
        XCTAssertEqual(Double(try firstVisible(controller)), Double(before), accuracy: 150)
    }

    func testZoomKeepsTheEditorInPlace() throws {
        let text = (1...20_000).map { "Line \($0) of a plain text file, long enough to look like real prose." }.joined(separator: "\n")
        let (_, controller) = try open(text, name: "big.txt")
        XCTAssertEqual(controller.mode, .editing)
        controller.scrollToCharacter((text as NSString).length / 2)
        let before = try firstVisible(controller)
        XCTAssertGreaterThan(before, 1000)
        controller.zoomIn(nil)
        XCTAssertEqual(Double(try firstVisible(controller)), Double(before), accuracy: 150)
        controller.zoomOut(nil)
        controller.zoomOut(nil)
        XCTAssertEqual(Double(try firstVisible(controller)), Double(before), accuracy: 150)
    }

    func testEditingAndBackKeepsTheProportionalPlace() throws {
        let (_, controller) = try open(try largeMarkdown, name: "big.md")
        let reader: NSTextView = try XCTUnwrap(view(controller, "reader"))
        let length = reader.textStorage!.length
        controller.scrollToCharacter(length / 2)
        controller.toggleEditing(nil)
        XCTAssertEqual(controller.mode, .editing)
        let editor: NSTextView = try XCTUnwrap(view(controller, "editor"))
        let fraction = Double(try firstVisible(controller)) / Double(editor.textStorage!.length)
        XCTAssertEqual(fraction, 0.5, accuracy: 0.02)
        XCTAssertNotNil(editor.textLayoutManager, "the editor stays on TextKit 2")
        controller.toggleEditing(nil)
        waitForRender(controller)
        XCTAssertEqual(Double(try firstVisible(controller)) / Double(length), 0.5, accuracy: 0.02)
    }

    func testUnchangedTextIsNotFormattedAgain() throws {
        let (_, controller) = try open("# Title\n\nSome text.\n", name: "small.md")
        let reader: NSTextView = try XCTUnwrap(view(controller, "reader"))
        let style = reader.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as AnyObject
        controller.toggleEditing(nil)
        controller.toggleEditing(nil)
        XCTAssertTrue(reader.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as AnyObject === style,
                      "the same formatted text, not a new one")
        controller.zoomIn(nil)
        XCTAssertFalse(reader.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as AnyObject === style,
                       "a new zoom formats again")
    }

    func testNewWindowsOpenWithTheLastWindowsFrame() throws {
        let name = DocumentWindowController.frameName
        DocumentWindowController.frameName = "Test \(UUID().uuidString)"
        let key = "NSWindow Frame \(DocumentWindowController.frameName)"
        defer {
            UserDefaults.standard.removeObject(forKey: key)
            DocumentWindowController.frameName = name
        }
        let (_, controller) = try open("Some text.\n", name: "first.txt")
        let window = try XCTUnwrap(controller.window)
        let screen = try XCTUnwrap(window.screen ?? NSScreen.main).visibleFrame
        let frame = NSRect(x: screen.minX + 40, y: screen.minY + 30, width: 520, height: 410)
        window.orderFront(nil)
        window.setFrame(frame, display: false)
        window.orderOut(nil)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        try Data("More text.\n".utf8).write(to: url)
        let next = try TextDocument(contentsOf: url, ofType: "public.plain-text")
        defer {
            next.close()
            try? FileManager.default.removeItem(at: url)
        }
        next.makeWindowControllers()
        XCTAssertEqual(next.windowControllers.first?.window?.frame, frame, "the same size and place")
        XCTAssertNotNil(UserDefaults.standard.string(forKey: key))
    }
}
