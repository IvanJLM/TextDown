import AppKit
import XCTest
@testable import TextDown

final class DocumentTests: XCTestCase {
    private func makeDocument(_ text: String, name: String) throws -> TextDocument {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        let document = TextDocument()
        try document.read(from: url, ofType: name.hasSuffix(".md") ? "net.daringfireball.markdown" : "public.plain-text")
        document.fileURL = url
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return document
    }

    func testKindFollowsTheFileName() throws {
        XCTAssertTrue(try makeDocument("# Hi", name: "a.md").isMarkdown)
        XCTAssertTrue(try makeDocument("# Hi", name: "a.markdown").isMarkdown)
        XCTAssertFalse(try makeDocument("# Hi", name: "a.txt").isMarkdown)
        XCTAssertFalse(TextDocument().isMarkdown, "new documents are plain text")
    }

    func testSavesTheTextItRead() throws {
        let document = try makeDocument("Canción\n", name: "a.txt")
        XCTAssertEqual(try document.data(ofType: "public.plain-text"), Data("Canción\n".utf8))
    }

    /// Some apps and scripts delete a file and write it again a moment later:
    /// TextDown keeps following it.
    func testFollowsTheFileWhenItIsDeletedAndCreatedAgain() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("a.txt")
        try Data("one".utf8).write(to: url)
        let document = try TextDocument(contentsOf: url, ofType: "public.plain-text")
        defer { document.close() }
        func shows(_ text: String) -> Bool {
            let deadline = Date().addingTimeInterval(5)
            while document.text != text && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            return document.text == text
        }
        try Data("two".utf8).write(to: url)
        XCTAssertTrue(shows("two"), "a change in place")
        try FileManager.default.removeItem(at: url)
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        try Data("three".utf8).write(to: url)
        XCTAssertTrue(shows("three"), "the file came back a second after it was deleted")
        try Data("four".utf8).write(to: url)
        XCTAssertTrue(shows("four"), "and is followed from then on")
    }

    func testPrintsFormattedMarkdownToPDF() throws {
        let document = try makeDocument("# Title\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n```\ncode\n```\n", name: "p.md")
        let pdf = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: pdf) }
        let operation = try document.printOperation(withSettings: [
            .jobDisposition: NSPrintInfo.JobDisposition.save, .jobSavingURL: pdf,
        ])
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        XCTAssertTrue(operation.run())
        let size = try FileManager.default.attributesOfItem(atPath: pdf.path)[.size] as? Int ?? 0
        XCTAssertGreaterThan(size, 1000)
    }
}
