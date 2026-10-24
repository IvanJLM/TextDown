import AppKit
import ImageIO

/// A Markdown document laid out as formatted text for a TextKit 1 text view
/// (tables and boxed blocks need TextKit 1).
struct RenderedMarkdown {
    let text: NSAttributedString
    /// GitHub-style heading anchors ("getting-started") and where they start.
    let anchors: [String: Int]
    /// Images, so their size can follow the width of the window.
    let images: [RenderedImage]
}

struct RenderedImage {
    let location: Int
    let attachment: NSTextAttachment
    let naturalSize: CGSize
}

/// Formats Markdown with the parser built into Foundation (cmark-gfm, the one
/// GitHub uses): headings, emphasis, links, lists and task lists, quotes,
/// code, tables, rules, images and the HTML most READMEs use.
struct MarkdownRenderer {
    /// The document's own file, to find images and linked files next to it.
    var baseURL: URL?
    var scale: CGFloat = 1
    /// The widest the text gets; images are decoded for this width.
    var columnWidth: CGFloat = Style.column

    func render(_ source: String) -> RenderedMarkdown {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .full
        options.failurePolicy = .returnPartiallyParsedIfPossible
        let body = Self.stripFrontMatter(source)
        let parsed = (try? AttributedString(markdown: body, options: options)) ?? AttributedString(body)
        let builder = MarkdownBuilder(self)
        var runs = parsed.runs.makeIterator()
        var more = true
        while more {
            // Temporary objects are released every few hundred runs, not at the end.
            autoreleasepool {
                for _ in 0..<256 {
                    guard let run = runs.next() else { more = false; return }
                    builder.append(String(parsed[run.range].characters), intent: run.presentationIntent,
                                   inline: run.inlinePresentationIntent ?? [], link: run.link, image: run.imageURL)
                }
            }
        }
        return builder.finish()
    }

    /// Hides a YAML front matter block ("---" … "---" at the very top), which
    /// Markdown would otherwise show as a rule and a heading.
    static func stripFrontMatter(_ source: String) -> String {
        guard source.hasPrefix("---\n") || source.hasPrefix("---\r\n") else { return source }
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 2, lines[1].contains(":") else { return source }
        for index in 2..<lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if line == "---" || line == "..." {
                return lines[(index + 1)...].joined(separator: "\n")
            }
        }
        return source
    }

    /// The anchor GitHub gives a heading: lowercase, punctuation removed,
    /// spaces turned into hyphens.
    static func slug(_ title: String) -> String {
        var slug = ""
        for character in title.lowercased() {
            if character.isLetter || character.isNumber || character == "-" || character == "_" {
                slug.append(character)
            } else if character == " " {
                slug.append("-")
            }
        }
        return slug
    }

    /// Resolves a link or image path written in the document: relative paths
    /// are taken from the document's folder. Returns nil for "#anchors".
    func resolve(_ url: URL) -> URL? {
        if url.scheme != nil { return url }
        let relative = url.relativeString
        if relative.hasPrefix("#") || relative.isEmpty { return nil }
        guard let folder = baseURL?.deletingLastPathComponent() else { return nil }
        return URL(string: relative, relativeTo: folder)?.absoluteURL
            ?? folder.appendingPathComponent(relative.removingPercentEncoding ?? relative)
    }

    /// Decodes a local image at most twice as wide as the column (sharp on a
    /// Retina display), never larger. Remote images are not downloaded.
    func loadImage(_ url: URL) -> (image: NSImage, size: CGSize)? {
        guard url.isFileURL else { return nil }
        if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           var width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
           var height = properties[kCGImagePropertyPixelHeight] as? CGFloat, width > 0, height > 0 {
            if let orientation = properties[kCGImagePropertyOrientation] as? Int, orientation >= 5 {
                swap(&width, &height)
            }
            let factor = min(1, columnWidth * 2 / width)
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: Int((max(width, height) * factor).rounded(.up)),
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            let size = CGSize(width: width, height: height)
            return (NSImage(cgImage: image, size: size), size)
        }
        // SVG and other formats only AppKit reads.
        guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else { return nil }
        return (image, image.size)
    }
}

// MARK: - Building the text

private final class MarkdownBuilder {
    private enum Leaf: Equatable {
        case paragraph, heading(Int), code, rule, html, cell(header: Bool, alignment: NSTextAlignment)
    }

    /// Where a block sits: what it is and what it is nested in.
    private struct Context {
        var leaf: Leaf = .paragraph
        var key: Int
        var blocks: [NSTextBlock] = []
        /// List nesting inside the innermost box (quote, code), for indents.
        var depth = 0
        /// Unordered list nesting, for the bullet glyph.
        var bulletDepth = 0
        var item: (id: Int, ordinal: Int, ordered: Bool)?
        var outerList: Int?
        /// The quotes it sits in, outermost first.
        var quotes: [Int] = []
        var cell: (table: Int, row: Int, column: Int)?
    }

    private let renderer: MarkdownRenderer
    private let scale: CGFloat
    private let out = NSMutableAttributedString()
    private var anchors: [String: Int] = [:]
    private var slugCounts: [String: Int] = [:]
    private var images: [RenderedImage] = []

    // The paragraph being written.
    private var current: Context?
    private var paragraphStart = 0
    private var style = NSMutableParagraphStyle()
    private var pendingMarker: (ordinal: Int, ordered: Bool, bulletDepth: Int)?

    private var seenItems = Set<Int>()
    private var boxes: [Int: NSTextBlock] = [:]
    private var tables: [Int: (table: NSTextTable, columns: [PresentationIntent.TableColumn])] = [:]
    /// The next cell a table expects, to fill in cells Markdown leaves empty.
    private var tableCursor: (table: Int, row: Int, column: Int)?
    private var htmlKey = -1
    private var fonts: [String: NSFont] = [:]
    /// Each image file is decoded once, however often the document shows it.
    private var decoded: [URL: (image: NSImage, size: CGSize)?] = [:]

    private let body: NSFont
    private let gap: CGFloat
    private let step: CGFloat

    init(_ renderer: MarkdownRenderer) {
        self.renderer = renderer
        scale = renderer.scale
        body = Style.bodyFont(scale: scale)
        gap = 12 * scale
        step = 26 * scale
    }

    func finish() -> RenderedMarkdown {
        closeParagraph(next: nil)
        finishTable()
        return RenderedMarkdown(text: out, anchors: anchors, images: images)
    }

    func append(_ text: String, intent: PresentationIntent?, inline: InlinePresentationIntent, link: URL?, image: URL?) {
        if inline.contains(.blockHTML) {
            appendHTMLBlock(text)
            return
        }
        let context = intent.map(makeContext) ?? Context(key: -2)
        if context.key != current?.key {
            closeParagraph(next: context)
            if let cell = context.cell {
                enterCell(cell, context: context)
            } else {
                finishTable()
                openParagraph(context)
            }
        }
        appendInline(text, inline: inline, link: link, image: image)
    }

    // MARK: Context

    private func makeContext(_ intent: PresentationIntent) -> Context {
        let components = intent.components // innermost first
        var context = Context(key: components.first?.identity ?? -2)
        var table: (id: Int, columns: [PresentationIntent.TableColumn])?
        var row = 0
        var header = false
        for (index, component) in components.enumerated().reversed() {
            switch component.kind {
            case .orderedList, .unorderedList:
                if context.outerList == nil { context.outerList = component.identity }
            case .listItem(let ordinal):
                var ordered = false
                if index + 1 < components.count, case .orderedList = components[index + 1].kind { ordered = true }
                if !ordered { context.bulletDepth += 1 }
                context.depth += 1
                context.item = (component.identity, ordinal, ordered)
            case .blockQuote:
                context.blocks.append(box(component.identity) { self.quoteBox(indent: context.depth) })
                context.depth = 0
                context.quotes.append(component.identity)
            case .codeBlock:
                context.leaf = .code
                context.blocks.append(box(component.identity) { self.codeBox(indent: context.depth) })
                context.depth = 0
            case .table(let columns):
                if tables[component.identity] == nil {
                    tables[component.identity] = (makeTable(columns: columns.count, indent: context.depth), columns)
                }
                table = (component.identity, columns)
            case .tableHeaderRow:
                row = 0
                header = true
            case .tableRow(let index):
                row = index
            case .tableCell(let column):
                let alignment: NSTextAlignment
                switch table?.columns[safe: column]?.alignment {
                case .center: alignment = .center
                case .right: alignment = .right
                default: alignment = .natural
                }
                context.leaf = .cell(header: header, alignment: alignment)
                if let table { context.cell = (table.id, row, column) }
            case .header(let level):
                context.leaf = .heading(level)
            case .thematicBreak:
                context.leaf = .rule
            default:
                break
            }
        }
        return context
    }

    private func box(_ id: Int, make: () -> NSTextBlock) -> NSTextBlock {
        if let existing = boxes[id] { return existing }
        let block = make()
        boxes[id] = block
        return block
    }

    /// A block as wide as the column (without a width, a block shrinks to
    /// its text).
    private func fullWidthBlock() -> BoxBlock {
        let block = BoxBlock()
        block.setContentWidth(100, type: .percentageValueType)
        return block
    }

    private func quoteBox(indent depth: Int) -> NSTextBlock {
        let block = fullWidthBlock()
        block.bar = (Style.rule, 3 * scale)
        block.setWidth(16 * scale, type: .absoluteValueType, for: .padding, edge: .minX)
        block.setWidth(CGFloat(depth) * step, type: .absoluteValueType, for: .margin, edge: .minX)
        block.setWidth(gap, type: .absoluteValueType, for: .margin, edge: .maxY)
        return block
    }

    private func codeBox(indent depth: Int) -> NSTextBlock {
        let block = fullWidthBlock()
        block.fill = Style.codeBackground
        block.cornerRadius = 6 * scale
        block.setWidth(10 * scale, type: .absoluteValueType, for: .padding, edge: .minY)
        block.setWidth(10 * scale, type: .absoluteValueType, for: .padding, edge: .maxY)
        block.setWidth(14 * scale, type: .absoluteValueType, for: .padding, edge: .minX)
        block.setWidth(14 * scale, type: .absoluteValueType, for: .padding, edge: .maxX)
        block.setWidth(CGFloat(depth) * step, type: .absoluteValueType, for: .margin, edge: .minX)
        block.setWidth(gap, type: .absoluteValueType, for: .margin, edge: .maxY)
        return block
    }

    private func makeTable(columns: Int, indent depth: Int) -> NSTextTable {
        let table = NSTextTable()
        table.numberOfColumns = max(columns, 1)
        table.layoutAlgorithm = .automatic
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        table.setWidth(CGFloat(depth) * step, type: .absoluteValueType, for: .margin, edge: .minX)
        table.setWidth(gap, type: .absoluteValueType, for: .margin, edge: .maxY)
        return table
    }

    // MARK: Paragraphs

    private func openParagraph(_ context: Context) {
        current = context
        paragraphStart = out.length
        let first = out.length == 0
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.28
        style.paragraphSpacing = gap
        var blocks = context.blocks
        let indent = CGFloat(context.depth) * step
        style.headIndent = indent
        style.firstLineHeadIndent = indent
        style.defaultTabInterval = step

        switch context.leaf {
        case .paragraph, .html:
            break
        case .heading(let level):
            style.lineHeightMultiple = 1.12
            style.paragraphSpacing = gap * 0.8
            if level <= 2 {
                let block = fullWidthBlock()
                block.underline = Style.rule
                block.setWidth(7 * scale, type: .absoluteValueType, for: .padding, edge: .maxY)
                block.setWidth(first ? 0 : gap * 1.6, type: .absoluteValueType, for: .margin, edge: .minY)
                block.setWidth(gap * 1.2, type: .absoluteValueType, for: .margin, edge: .maxY)
                blocks.append(block)
                style.paragraphSpacing = 0
            } else if !first {
                style.paragraphSpacingBefore = gap * 1.3
            }
        case .code:
            style.lineHeightMultiple = 1.15
            style.paragraphSpacing = 0
            style.lineBreakMode = .byCharWrapping
            let space = (" " as NSString).size(withAttributes: [.font: Style.codeFont(scale: scale)]).width
            style.tabStops = []
            style.defaultTabInterval = space * 4
        case .rule:
            let block = fullWidthBlock()
            block.underline = Style.rule
            block.setWidth(gap * 1.2, type: .absoluteValueType, for: .margin, edge: .minY)
            block.setWidth(gap * 1.6, type: .absoluteValueType, for: .margin, edge: .maxY)
            blocks.append(block)
            style.paragraphSpacing = 0
            style.lineHeightMultiple = 1
        case .cell(let header, let alignment):
            style.paragraphSpacing = 0
            style.lineHeightMultiple = 1.15
            style.alignment = alignment
            style.headIndent = 0
            style.firstLineHeadIndent = 0
            if let cell = context.cell, let table = tables[cell.table]?.table {
                let block = NSTextTableBlock(table: table, startingRow: cell.row, rowSpan: 1,
                                             startingColumn: cell.column, columnSpan: 1)
                block.setWidth(1, type: .absoluteValueType, for: .border)
                block.setBorderColor(Style.rule)
                block.setWidth(5 * scale, type: .absoluteValueType, for: .padding, edge: .minY)
                block.setWidth(5 * scale, type: .absoluteValueType, for: .padding, edge: .maxY)
                block.setWidth(10 * scale, type: .absoluteValueType, for: .padding, edge: .minX)
                block.setWidth(10 * scale, type: .absoluteValueType, for: .padding, edge: .maxX)
                if header { block.backgroundColor = Style.codeBackground }
                blocks.append(block)
            }
        }
        style.textBlocks = blocks

        // The first paragraph of a list item carries its bullet or number,
        // hanging in the margin to the left of the text.
        if let item = context.item, !seenItems.contains(item.id) {
            seenItems.insert(item.id)
            if context.leaf == .paragraph || context.leaf == .html || isHeading(context.leaf) {
                pendingMarker = (item.ordinal, item.ordered, context.bulletDepth)
                style.firstLineHeadIndent = indent - step
                style.tabStops = [NSTextTab(textAlignment: .right, location: indent - 8 * scale),
                                  NSTextTab(textAlignment: .left, location: indent)]
            }
        }
        self.style = style
    }

    private func isHeading(_ leaf: Leaf) -> Bool {
        if case .heading = leaf { return true }
        return false
    }

    private func closeParagraph(next: Context?) {
        guard let context = current else { return }
        if context.leaf == .rule && out.length == paragraphStart {
            out.append(NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: 2)]))
        }
        out.append(NSAttributedString(string: "\n", attributes: [.font: baseFont(context.leaf)]))
        let range = NSRange(location: paragraphStart, length: out.length - paragraphStart)

        if context.leaf == .paragraph || context.leaf == .html {
            // Items of one list sit close together; the list ends with a full gap.
            if let list = context.outerList, list == next?.outerList {
                style.paragraphSpacing = gap * 0.35
            }
            // The last paragraph of a quote: the quote's own margin spaces it.
            if let quote = context.quotes.last, next?.quotes.contains(quote) != true {
                style.paragraphSpacing = 0
            }
        }
        out.addAttribute(.paragraphStyle, value: style, range: range)

        if case .heading = context.leaf {
            let title = out.attributedSubstring(from: range).string.trimmingCharacters(in: .whitespacesAndNewlines)
            var slug = MarkdownRenderer.slug(title)
            if let count = slugCounts[slug] {
                slugCounts[slug] = count + 1
                slug += "-\(count + 1)"
            } else {
                slugCounts[slug] = 0
            }
            if anchors[slug] == nil { anchors[slug] = range.location }
        }
        current = nil
        pendingMarker = nil
    }

    // MARK: Tables

    /// Opens a table cell, first adding any cells Markdown skipped because
    /// they were empty, so every row has all its columns.
    private func enterCell(_ cell: (table: Int, row: Int, column: Int), context: Context) {
        if tableCursor?.table != cell.table {
            finishTable()
            tableCursor = (cell.table, 0, 0)
        }
        while let cursor = tableCursor, (cursor.row, cursor.column) < (cell.row, cell.column) {
            emptyCell(row: cursor.row, column: cursor.column, template: context)
        }
        openParagraph(context)
        advanceCursor()
    }

    private func finishTable() {
        while let cursor = tableCursor, cursor.column != 0 {
            emptyCell(row: cursor.row, column: cursor.column, template: nil)
        }
        tableCursor = nil
    }

    private func emptyCell(row: Int, column: Int, template: Context?) {
        guard let cursor = tableCursor else { return }
        var context = template ?? Context(key: -3)
        context.key = -3
        context.cell = (cursor.table, row, column)
        context.leaf = .cell(header: row == 0, alignment: .natural)
        if template == nil { context.blocks = [] }
        openParagraph(context)
        closeParagraph(next: nil)
        advanceCursor()
    }

    private func advanceCursor() {
        guard var cursor = tableCursor, let columns = tables[cursor.table]?.table.numberOfColumns else { return }
        cursor.column += 1
        if cursor.column >= columns {
            cursor.column = 0
            cursor.row += 1
        }
        tableCursor = cursor
    }

    // MARK: Inline text

    private func baseFont(_ leaf: Leaf) -> NSFont {
        switch leaf {
        case .heading(let level): return Style.headingFont(level: level, scale: scale)
        case .code: return Style.codeFont(scale: scale)
        case .cell(let header, _): return header ? font(body, bold: true, italic: false, code: false) : body
        default: return body
        }
    }

    private func font(_ base: NSFont, bold: Bool, italic: Bool, code: Bool) -> NSFont {
        let key = "\(base.fontName)|\(base.pointSize)|\(bold)|\(italic)|\(code)"
        if let cached = fonts[key] { return cached }
        var font = base
        if code {
            font = .monospacedSystemFont(ofSize: (base.pointSize * 0.87).rounded(), weight: bold ? .semibold : .regular)
        }
        var traits = font.fontDescriptor.symbolicTraits
        if bold && !code { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        if traits != font.fontDescriptor.symbolicTraits {
            font = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: font.pointSize) ?? font
        }
        fonts[key] = font
        return font
    }

    private var textColor: NSColor {
        if current?.quotes.isEmpty == false { return .secondaryLabelColor }
        if case .heading(6) = current?.leaf { return .secondaryLabelColor }
        return .labelColor
    }

    private func attributes(_ inline: InlinePresentationIntent) -> [NSAttributedString.Key: Any] {
        let leaf = current?.leaf ?? .paragraph
        let code = inline.contains(.code)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font(baseFont(leaf), bold: inline.contains(.stronglyEmphasized),
                        italic: inline.contains(.emphasized), code: code),
            .foregroundColor: textColor,
        ]
        if code { attributes[.backgroundColor] = Style.codeBackground }
        if inline.contains(.strikethrough) {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        return attributes
    }

    private func appendInline(_ raw: String, inline: InlinePresentationIntent, link: URL?, image: URL?) {
        guard let context = current else { return }
        var text = raw
        switch context.leaf {
        case .code:
            if text.hasSuffix("\n") { text.removeLast() }
            out.append(NSAttributedString(string: text, attributes: [
                .font: Style.codeFont(scale: scale), .foregroundColor: NSColor.labelColor,
            ]))
            return
        case .rule:
            return
        default:
            break
        }
        if inline.contains(.lineBreak) { text = "\u{2028}" }
        if inline.contains(.inlineHTML) {
            for piece in HTMLText.pieces(text) {
                switch piece {
                case .lineBreak: appendText("\u{2028}", attributes: attributes([]))
                case .image(let url, let alt, let width, let height):
                    appendImage(url, alt: alt, link: link, width: width, height: height)
                case .text: break // Inline tags are dropped; the text between them stays.
                }
            }
            return
        }
        if let image {
            appendImage(image, alt: text, link: link)
            return
        }
        var attributes = attributes(inline)
        if let link {
            if text.hasPrefix("^") {
                // A footnote reference: shown as a superscript, not a link.
                text.removeFirst()
                attributes[.baselineOffset] = body.pointSize * 0.35
                attributes[.font] = NSFont.systemFont(ofSize: body.pointSize * 0.7)
            } else {
                attributes[.link] = link
            }
        }
        appendText(text, attributes: attributes)
    }

    /// Appends text, writing the list marker first when the paragraph opens
    /// a list item. "[ ]" and "[x]" turn the item into a checkbox.
    private func appendText(_ text: String, attributes: [NSAttributedString.Key: Any]) {
        var text = text
        if let marker = pendingMarker {
            pendingMarker = nil
            let markerAttributes: [NSAttributedString.Key: Any] = [
                .font: body, .foregroundColor: NSColor.secondaryLabelColor,
            ]
            out.append(NSAttributedString(string: "\t", attributes: markerAttributes))
            if !marker.ordered, let checked = Self.taskState(text) {
                text.removeFirst(4)
                out.append(checkbox(checked))
            } else {
                let bullets = ["•", "◦", "▪"]
                let glyph = marker.ordered ? "\(marker.ordinal)." : bullets[(max(marker.bulletDepth, 1) - 1) % 3]
                out.append(NSAttributedString(string: glyph, attributes: markerAttributes))
            }
            out.append(NSAttributedString(string: "\t", attributes: markerAttributes))
        }
        out.append(NSAttributedString(string: text, attributes: attributes))
    }

    static func taskState(_ text: String) -> Bool? {
        if text.hasPrefix("[ ] ") { return false }
        if text.hasPrefix("[x] ") || text.hasPrefix("[X] ") { return true }
        return nil
    }

    private var checkboxes: [Bool: NSAttributedString] = [:]

    private func checkbox(_ checked: Bool) -> NSAttributedString {
        if let cached = checkboxes[checked] { return cached }
        let box = makeCheckbox(checked)
        checkboxes[checked] = box
        return box
    }

    private func makeCheckbox(_ checked: Bool) -> NSAttributedString {
        let name = checked ? "checkmark.square.fill" : "square"
        let configuration = NSImage.SymbolConfiguration(pointSize: body.pointSize * 0.95, weight: .regular)
            .applying(.init(paletteColors: [checked ? .controlAccentColor : .secondaryLabelColor]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: checked ? "done" : "to do")?
            .withSymbolConfiguration(configuration) else {
            return NSAttributedString(string: checked ? "☑" : "☐", attributes: [.font: body])
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        let descender = body.descender
        attachment.bounds = CGRect(x: 0, y: descender * 0.6, width: image.size.width, height: image.size.height)
        return NSAttributedString(attachment: attachment)
    }

    /// An image, at the size HTML asks for, if any, or its own size; never
    /// wider than the column.
    private func appendImage(_ url: URL, alt: String, link: URL?, width: CGFloat? = nil, height: CGFloat? = nil) {
        if let file = renderer.resolve(url), var loaded = cachedImage(file) {
            let aspect = loaded.size.height / loaded.size.width
            if let width, width > 0 {
                loaded.size = CGSize(width: width, height: height ?? width * aspect)
            } else if let height, height > 0 {
                loaded.size = CGSize(width: height / aspect, height: height)
            }
            if pendingMarker != nil { appendText("", attributes: attributes([])) }
            let attachment = NSTextAttachment()
            attachment.image = loaded.image
            let width = min(loaded.size.width, renderer.columnWidth)
            attachment.bounds = CGRect(x: 0, y: 0, width: width, height: loaded.size.height * width / loaded.size.width)
            let image = NSMutableAttributedString(attachment: attachment)
            if let link { image.addAttribute(.link, value: link, range: NSRange(location: 0, length: image.length)) }
            images.append(RenderedImage(location: out.length, attachment: attachment, naturalSize: loaded.size))
            out.append(image)
        } else {
            // Remote or missing: the description, linked to the image.
            var attributes = attributes([])
            attributes[.foregroundColor] = NSColor.secondaryLabelColor
            if let target = link ?? (url.scheme != nil ? url : nil) { attributes[.link] = target }
            appendText(alt.isEmpty ? "image" : alt, attributes: attributes)
        }
    }

    private func cachedImage(_ url: URL) -> (image: NSImage, size: CGSize)? {
        if let cached = decoded[url] { return cached }
        let loaded = renderer.loadImage(url)
        decoded[url] = loaded
        return loaded
    }

    // MARK: HTML

    /// HTML blocks (READMEs use them for centered logos and titles): images
    /// are shown, headings keep their size, other tags are dropped.
    private func appendHTMLBlock(_ html: String) {
        let pieces = HTMLText.pieces(html)
        guard pieces.contains(where: { if case .lineBreak = $0 { return false }; return true }) else { return }
        htmlKey -= 1
        var context = Context(key: htmlKey)
        context.leaf = .html
        closeParagraph(next: context)
        finishTable()
        openParagraph(context)
        if html.range(of: #"align\s*=\s*["']?center"#, options: [.regularExpression, .caseInsensitive]) != nil {
            style.alignment = .center
        }
        var atLineStart = true
        for piece in pieces {
            switch piece {
            case .text(let text, let level):
                var attributes = attributes([])
                if let level { attributes[.font] = Style.headingFont(level: level, scale: scale) }
                appendText(text, attributes: attributes)
                atLineStart = false
            case .image(let url, let alt, let width, let height):
                appendImage(url, alt: alt, link: nil, width: width, height: height)
                atLineStart = false
            case .lineBreak:
                if !atLineStart { appendText("\u{2028}", attributes: attributes([])) }
                atLineStart = true
            }
        }
        // No trailing line break inside the paragraph.
        if out.string.hasSuffix("\u{2028}") { out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1)) }
    }
}

/// Just enough HTML for Markdown files: text, images, line breaks and the
/// size of headings.
enum HTMLText {
    enum Piece: Equatable {
        case text(String, heading: Int?)
        case image(URL, alt: String, width: CGFloat?, height: CGFloat?)
        case lineBreak
    }

    private static let breakingTags: Set<String> = [
        "br", "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "tr", "table", "details", "summary", "hr",
        "ul", "ol", "blockquote", "pre",
    ]

    private static let comment = try! NSRegularExpression(pattern: #"<!--[\s\S]*?-->"#)
    private static let whitespace = try! NSRegularExpression(pattern: #"\s+"#)
    private static var attributePatterns: [String: NSRegularExpression] = [:]

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    static func pieces(_ html: String) -> [Piece] {
        let source = html.contains("<!--") ? replace(comment, in: html, with: "") : html
        var pieces: [Piece] = []
        var heading: Int?
        var rest = source[...]
        while !rest.isEmpty {
            guard let open = rest.firstIndex(of: "<") else {
                addText(String(rest), heading: heading, to: &pieces)
                break
            }
            addText(String(rest[..<open]), heading: heading, to: &pieces)
            guard let close = rest[open...].firstIndex(of: ">") else {
                addText(String(rest[open...]), heading: heading, to: &pieces)
                break
            }
            let tag = rest[rest.index(after: open)..<close]
            rest = rest[rest.index(after: close)...]
            let closing = tag.hasPrefix("/")
            let name = tag.drop(while: { $0 == "/" }).prefix(while: { $0.isLetter || $0.isNumber }).lowercased()
            if name == "img", let src = attribute("src", in: tag), let url = URL(string: src) {
                pieces.append(.image(url, alt: attribute("alt", in: tag) ?? "",
                                     width: attribute("width", in: tag).flatMap { Double($0) }.map { CGFloat($0) },
                                     height: attribute("height", in: tag).flatMap { Double($0) }.map { CGFloat($0) }))
            } else if name.count == 2, name.hasPrefix("h"), let level = Int(name.dropFirst()) {
                heading = closing ? nil : level
                pieces.append(.lineBreak)
            } else if breakingTags.contains(name) {
                if pieces.last != .lineBreak { pieces.append(.lineBreak) }
            }
        }
        while pieces.first == .lineBreak { pieces.removeFirst() }
        while pieces.last == .lineBreak { pieces.removeLast() }
        return pieces
    }

    private static func addText(_ raw: String, heading: Int?, to pieces: inout [Piece]) {
        let collapsed = replace(whitespace, in: raw, with: " ")
        let text = decodeEntities(collapsed)
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let trimmed = pieces.last == .lineBreak || pieces.isEmpty
            ? String(text.drop(while: { $0 == " " })) : text
        pieces.append(.text(trimmed, heading: heading))
    }

    private static func attribute(_ name: String, in tag: Substring) -> String? {
        let regex: NSRegularExpression
        if let cached = attributePatterns[name] {
            regex = cached
        } else {
            let pattern = #"\b"# + name + #"\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
            guard let made = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
            attributePatterns[name] = made
            regex = made
        }
        let text = String(tag)
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        for group in 1...3 {
            if let range = Range(match.range(at: group), in: text) { return decodeEntities(String(text[range])) }
        }
        return nil
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        for (entity, value) in [("&nbsp;", "\u{00A0}"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
                                ("&#39;", "'"), ("&apos;", "'"), ("&copy;", "©"), ("&mdash;", "—"),
                                ("&ndash;", "–"), ("&hellip;", "…"), ("&amp;", "&")] {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        return result
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// A box around blocks (code, quotes, big headings, rules) drawn inside its
/// margins: NSTextBlock paints its background over the margins too, and has
/// no rounded corners.
final class BoxBlock: NSTextBlock {
    var fill: NSColor?
    var cornerRadius: CGFloat = 0
    /// A bar along the left edge, as beside quotes.
    var bar: (color: NSColor, width: CGFloat)?
    /// A hairline along the bottom edge.
    var underline: NSColor?

    override func drawBackground(withFrame frameRect: NSRect, in controlView: NSView?,
                                 characterRange charRange: NSRange, layoutManager: NSLayoutManager) {
        var rect = frameRect
        let left = width(for: .margin, edge: .minX), right = width(for: .margin, edge: .maxX)
        let top = width(for: .margin, edge: .minY), bottom = width(for: .margin, edge: .maxY)
        rect.origin.x += left
        rect.origin.y += top
        rect.size.width -= left + right
        rect.size.height -= top + bottom
        if let textView = controlView as? NSTextView, let container = textView.textContainer {
            let limit = textView.textContainerOrigin.x + container.size.width - container.lineFragmentPadding
            rect.size.width = min(rect.width, limit - rect.minX)
        }
        guard rect.width > 0, rect.height > 0 else { return }
        if let fill {
            fill.setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
        }
        if let bar {
            bar.color.setFill()
            NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY, width: bar.width, height: rect.height),
                         xRadius: bar.width / 2, yRadius: bar.width / 2).fill()
        }
        if let underline {
            underline.setFill()
            let line = 1 / (controlView?.window?.backingScaleFactor ?? 2)
            NSRect(x: rect.minX, y: rect.maxY - line, width: rect.width, height: line).fill()
        }
    }

    override func copy(with zone: NSZone? = nil) -> Any {
        let copy = super.copy(with: zone)
        if let box = copy as? BoxBlock {
            box.fill = fill
            box.cornerRadius = cornerRadius
            box.bar = bar
            box.underline = underline
        }
        return copy
    }
}
