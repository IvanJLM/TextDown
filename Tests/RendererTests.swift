import AppKit
import XCTest
@testable import TextDown

final class RendererTests: XCTestCase {
    private func render(_ markdown: String, baseURL: URL? = nil) -> RenderedMarkdown {
        MarkdownRenderer(baseURL: baseURL).render(markdown)
    }

    private func paragraphs(_ rendered: RenderedMarkdown) -> [String] {
        rendered.text.string.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    func testBlocksBecomeSeparateParagraphs() {
        let rendered = render("# Title\n\nFirst paragraph.\n\nSecond paragraph.")
        XCTAssertEqual(paragraphs(rendered), ["Title", "First paragraph.", "Second paragraph."])
    }

    func testInlineStyles() {
        let text = render("Some **bold**, *italic* and `code` and ~~gone~~.").text
        func attributes(of word: String) -> [NSAttributedString.Key: Any] {
            let range = (text.string as NSString).range(of: word)
            return text.attributes(at: range.location, effectiveRange: nil)
        }
        XCTAssertTrue((attributes(of: "bold")[.font] as! NSFont).fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertTrue((attributes(of: "italic")[.font] as! NSFont).fontDescriptor.symbolicTraits.contains(.italic))
        XCTAssertTrue((attributes(of: "code")[.font] as! NSFont).isFixedPitch)
        XCTAssertNotNil(attributes(of: "gone")[.strikethroughStyle])
    }

    func testHardBreakStaysInParagraph() {
        let rendered = render("one  \ntwo\nthree")
        XCTAssertEqual(paragraphs(rendered), ["one\u{2028}two three"])
    }

    func testListMarkers() {
        let rendered = render("- apple\n- pear\n  - nested\n\n3. three\n4. four")
        XCTAssertEqual(paragraphs(rendered), ["\t•\tapple", "\t•\tpear", "\t◦\tnested", "\t3.\tthree", "\t4.\tfour"])
    }

    func testTaskList() {
        let rendered = render("- [ ] todo\n- [x] done")
        let lines = paragraphs(rendered)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix("todo") && !lines[0].contains("["))
        XCTAssertTrue(lines[1].hasSuffix("done") && !lines[1].contains("["))
        XCTAssertNotNil(rendered.text.attribute(.attachment, at: 1, effectiveRange: nil))
    }

    func testCodeBlockKeepsLinesAndBox() {
        let rendered = render("```\nlet a = 1\nlet b = 2\n```\n\nafter")
        XCTAssertEqual(paragraphs(rendered), ["let a = 1", "let b = 2", "after"])
        let style = rendered.text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as! NSParagraphStyle
        let second = rendered.text.attribute(.paragraphStyle, at: 10, effectiveRange: nil) as! NSParagraphStyle
        XCTAssertEqual(style.textBlocks.count, 1)
        XCTAssertTrue(style.textBlocks.first === second.textBlocks.first, "both lines share one box")
    }

    func testTableFillsEmptyCells() {
        let rendered = render("| A | B | C |\n|---|:-:|--:|\n| | 2 | |\n| x | | |")
        // Three columns times three rows, empty cells included.
        let cells = rendered.text.string.components(separatedBy: "\n").dropLast()
        XCTAssertEqual(Array(cells), ["A", "B", "C", "", "2", "", "x", "", ""])
        var positions: [String] = []
        rendered.text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: rendered.text.length)) { value, _, _ in
            if let block = (value as? NSParagraphStyle)?.textBlocks.last as? NSTextTableBlock {
                positions.append("\(block.startingRow),\(block.startingColumn)")
            }
        }
        XCTAssertEqual(positions, ["0,0", "0,1", "0,2", "1,0", "1,1", "1,2", "2,0", "2,1", "2,2"])
    }

    func testFrontMatterIsHidden() {
        XCTAssertEqual(paragraphs(render("---\ntitle: x\ntags: [a]\n---\n\nHello")), ["Hello"])
        // A rule at the top without YAML stays.
        XCTAssertEqual(MarkdownRenderer.stripFrontMatter("---\n\nText\n---\n"), "---\n\nText\n---\n")
    }

    func testFrontMatterWithWindowsLineEndingsIsHidden() {
        XCTAssertEqual(MarkdownRenderer.stripFrontMatter("---\r\ntitle: x\r\n---\r\n\r\nHello\r\n"), "\r\nHello\r\n")
        XCTAssertEqual(paragraphs(render("---\r\ntitle: x\r\ntags: [a]\r\n---\r\n\r\nHello\r\n")), ["Hello"])
        XCTAssertEqual(MarkdownRenderer.stripFrontMatter("---\r\n\r\nText\r\n---\r\n"), "---\r\n\r\nText\r\n---\r\n")
    }

    func testHeadingAnchors() {
        let rendered = render("# Getting Started\n\ntext\n\n## Getting Started\n\n## What's new?")
        XCTAssertEqual(rendered.anchors["getting-started"], 0)
        XCTAssertNotNil(rendered.anchors["getting-started-1"])
        XCTAssertNotNil(rendered.anchors["whats-new"])
    }

    func testLinksKeepTheirTarget() {
        let text = render("[Apple](https://www.apple.com) and [doc](other.md)").text
        XCTAssertEqual(text.attribute(.link, at: 0, effectiveRange: nil) as? URL, URL(string: "https://www.apple.com"))
        let doc = (text.string as NSString).range(of: "doc")
        XCTAssertEqual((text.attribute(.link, at: doc.location, effectiveRange: nil) as? URL)?.relativeString, "other.md")
    }

    func testResolveRelativePaths() {
        let renderer = MarkdownRenderer(baseURL: URL(fileURLWithPath: "/tmp/docs/readme.md"))
        XCTAssertEqual(renderer.resolve(URL(string: "img/a%20b.png")!)?.path, "/tmp/docs/img/a b.png")
        XCTAssertEqual(renderer.resolve(URL(string: "../x.md")!)?.path, "/tmp/x.md")
        XCTAssertNil(renderer.resolve(URL(string: "#section")!))
        XCTAssertEqual(renderer.resolve(URL(string: "https://a.b/c")!)?.absoluteString, "https://a.b/c")
    }

    func testLocalImagesAreShownRemoteOnesAreNot() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3000, pixelsHigh: 1000, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        try rep.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("wide.png"))
        let rendered = render("![wide](wide.png)\n\n![remote](https://example.com/x.png)",
                              baseURL: folder.appendingPathComponent("doc.md"))
        XCTAssertEqual(rendered.images.count, 1)
        let image = try XCTUnwrap(rendered.images.first)
        XCTAssertEqual(image.naturalSize, CGSize(width: 3000, height: 1000))
        XCTAssertEqual(image.attachment.bounds.width, Style.column, "never wider than the column")
        // Decoded at twice the column width at most, not at full size.
        let cgImage = try XCTUnwrap(image.attachment.image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertLessThanOrEqual(cgImage.width, Int(Style.column * 2))
        XCTAssertTrue(rendered.text.string.contains("remote"))
    }

    func testHTMLBlocks() {
        let pieces = HTMLText.pieces("<p align=\"center\">\n  <img src=\"logo.png\" alt=\"Logo\" width=\"120\">\n  <br>\n  <b>Title &amp; more</b>\n</p>\n<!-- hidden -->")
        XCTAssertEqual(pieces, [.image(URL(string: "logo.png")!, alt: "Logo", width: 120, height: nil), .lineBreak,
                                .text("Title & more", heading: nil)])
        XCTAssertEqual(paragraphs(render("<!-- only a comment -->\n\ntext")), ["text"])
        // A block that ends in a line break keeps none at its end.
        XCTAssertEqual(paragraphs(render("<p align=\"center\">\n  <b>Title</b>\n  <br>\n</p>\n\ntext")), ["Title", "text"])
    }

    func testSlug() {
        XCTAssertEqual(MarkdownRenderer.slug("Hello, World! 2"), "hello-world-2")
        XCTAssertEqual(MarkdownRenderer.slug("Ñandú y café"), "ñandú-y-café")
    }

    /// About 0.14 s on an M-series Mac. The fastest of three runs, with room to
    /// spare, so a busy CI runner does not fail it but a slower renderer does.
    func testRendersTheSampleQuickly() throws {
        let sample = try String(contentsOf: fixture("Sample.md"), encoding: .utf8)
        let big = String(repeating: sample + "\n\n", count: 100) // about 130 KB
        let fastest = (1...3).map { _ in
            let start = Date()
            let rendered = MarkdownRenderer(baseURL: fixture("Sample.md")).render(big)
            XCTAssertGreaterThan(rendered.text.length, 50_000)
            return Date().timeIntervalSince(start)
        }.min()!
        XCTAssertLessThan(fastest, 1, "the fastest of three runs took \(fastest) s")
    }

    /// READMEs put HTML blocks everywhere: their cost must not grow with the
    /// length of the text before them. Twice the blocks may take about twice
    /// as long, not four times (it took 3.8 times as long when each block
    /// copied the whole text). A ratio, so a slower machine does not matter.
    func testHTMLBlocksCostDoesNotGrowWithTheDocument() {
        let block = "<p align=\"center\"><b>Centered</b></p>\n\n" + String(repeating: "Some prose that fills the line. ", count: 12)
            + "\n\n- A list item, so the text is no longer plain ASCII\n\n"
        func seconds(_ count: Int) -> Double {
            let source = String(repeating: block, count: count)
            let start = Date()
            XCTAssertGreaterThan(render(source).text.length, count * 300)
            return Date().timeIntervalSince(start)
        }
        _ = seconds(200) // warm up
        let ratio = seconds(3000) / seconds(1500)
        XCTAssertLessThan(ratio, 2.8, "twice the HTML blocks took \(ratio) times as long")
    }
}

final class EncodingTests: XCTestCase {
    func testUTF8WithAndWithoutBOM() {
        XCTAssertEqual(TextEncoding.decode(Data("año".utf8))?.text, "año")
        XCTAssertEqual(TextEncoding.decode(Data([0xEF, 0xBB, 0xBF] + Array("año".utf8)))?.text, "año")
    }

    /// Saving a file nobody changed writes back the same bytes, byte order
    /// mark and byte order included.
    func testSavesTheBytesItRead() throws {
        let files: [Data] = [
            Data("año\n".utf8),
            Data([0xEF, 0xBB, 0xBF] + Array("año\n".utf8)),
            Data([0xFF, 0xFE]) + "año\n".data(using: .utf16LittleEndian)!,
            Data([0xFE, 0xFF]) + "año\n".data(using: .utf16BigEndian)!,
            "Canción del niño\n".data(using: .windowsCP1252)!,
        ]
        for data in files {
            let decoded = try XCTUnwrap(TextEncoding.decode(data))
            XCTAssertTrue(decoded.text.contains("ñ"))
            XCTAssertEqual(TextEncoding.encode(decoded.text, as: decoded.format), data, "\(Array(data.prefix(4)))")
        }
    }

    func testUTF16() {
        let data = "año".data(using: .utf16)! // with a byte order mark
        let decoded = TextEncoding.decode(data)
        XCTAssertEqual(decoded?.text, "año")
        XCTAssertEqual(decoded?.format.byteOrderMark, true)
    }

    func testLatin1IsDetectedAndKept() {
        let data = "Canción del niño".data(using: .windowsCP1252)!
        let decoded = TextEncoding.decode(data)
        XCTAssertEqual(decoded?.text, "Canción del niño")
        XCTAssertEqual(TextEncoding.encode(decoded!.text, as: decoded!.format), data)
    }

    func testFallsBackToUTF8WhenTheEncodingCannotHoldTheText() {
        XCTAssertEqual(TextEncoding.encode("emoji 🙂", as: .init(encoding: .isoLatin1)), Data("emoji 🙂".utf8))
    }

    func testEmptyFile() {
        XCTAssertEqual(TextEncoding.decode(Data())?.text, "")
    }
}

func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")
}
