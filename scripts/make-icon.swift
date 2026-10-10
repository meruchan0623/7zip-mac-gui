import AppKit
let destination = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let rect = NSRect(x: 0, y: 0, width: pixels, height: pixels)
        NSColor(calibratedRed: 0.08, green: 0.14, blue: 0.25, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: CGFloat(pixels) * 0.06, dy: CGFloat(pixels) * 0.06), xRadius: CGFloat(pixels) * 0.22, yRadius: CGFloat(pixels) * 0.22).fill()
        let text = "7z" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: CGFloat(pixels) * 0.53), .foregroundColor: NSColor.white]
        let measured = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: (CGFloat(pixels)-measured.width)/2, y: (CGFloat(pixels)-measured.height)/2), withAttributes: attributes)
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination).appendingPathComponent("icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"))
    }
}
