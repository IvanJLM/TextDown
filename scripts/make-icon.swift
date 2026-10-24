// Draws TextDown's app icon (same family as Visor's) and writes every size
// into the asset catalog.
// Usage: swift scripts/make-icon.swift
import AppKit

let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let context = NSGraphicsContext.current!.cgContext

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// Background: the same dark squircle as Visor.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGradient(starting: color(0x0F111A), ending: color(0x2C3350))!.draw(in: tilePath, angle: 90)

// The page.
let page = NSRect(x: 262, y: 196, width: 500, height: 632)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: NSColor(white: 0, alpha: 0.45).cgColor)
let pagePath = NSBezierPath(roundedRect: page, xRadius: 46, yRadius: 46)
NSGradient(starting: color(0xE4E3EA), ending: color(0xFBFAF7))!.draw(in: pagePath, angle: 90)
context.restoreGState()

// A heading in Visor's sunset colors, then lines of text.
let sunset = NSGradient(colors: [color(0xF2A35E), color(0xDC5A75), color(0x8E55C2)])!
let heading = NSBezierPath(roundedRect: NSRect(x: 330, y: 704, width: 250, height: 50), xRadius: 25, yRadius: 25)
sunset.draw(in: heading, angle: 0)
let lineColor = color(0x2C3350, 0.30)
for (index, width) in [364, 318, 250].enumerated() {
    let y = 612 - CGFloat(index) * 66
    lineColor.setFill()
    NSBezierPath(roundedRect: NSRect(x: 330, y: y, width: CGFloat(width), height: 26), xRadius: 13, yRadius: 13).fill()
}

// The arrow pointing down: "Down", as in Markdown.
let arrow = NSBezierPath()
arrow.lineWidth = 34
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.move(to: NSPoint(x: 512, y: 384))
arrow.line(to: NSPoint(x: 512, y: 250))
arrow.move(to: NSPoint(x: 452, y: 310))
arrow.line(to: NSPoint(x: 512, y: 250))
arrow.line(to: NSPoint(x: 572, y: 310))
context.saveGState()
context.addPath(arrow.cgPath)
context.setLineWidth(34)
context.setLineCap(.round)
context.setLineJoin(.round)
context.replacePathWithStrokedPath()
context.clip()
sunset.draw(in: NSRect(x: 430, y: 230, width: 164, height: 170), angle: -60)
context.restoreGState()

NSGraphicsContext.restoreGraphicsState()
let png = rep.representation(using: .png, properties: [:])!

let folder = URL(fileURLWithPath: "App/Resources/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let master = folder.appendingPathComponent("icon_512x512@2x.png")
try png.write(to: master)
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        let pixels = points * scale
        if pixels != 1024 {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
            task.arguments = ["-z", "\(pixels)", "\(pixels)", master.path, "--out", folder.appendingPathComponent(name).path]
            task.standardOutput = FileHandle.nullDevice
            try task.run()
            task.waitUntilExit()
        }
        images.append(["idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: folder.appendingPathComponent("Contents.json"))
try #"{"info":{"author":"xcode","version":1}}"#.write(
    to: folder.deletingLastPathComponent().appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("Icon written to \(folder.path)")
