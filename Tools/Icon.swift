import AppKit

func fail(_ message: String) -> Never {
    fputs("Icon.swift: \(message)\n", stderr)
    exit(1)
}

guard CommandLine.arguments.count == 2 else { fail("usage: swift Tools/Icon.swift <output.iconset>") }
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let emoji = "🥔" as NSString

do {
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let pixels = points * scale
            let side = CGFloat(pixels)
            guard let font = NSFont(name: "Apple Color Emoji", size: side * 0.82),
                  let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
                fail("could not create an Apple Color Emoji drawing context")
            }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.cgContext.clear(CGRect(x: 0, y: 0, width: side, height: side))
            let attributes: [NSAttributedString.Key: Any] = [.font: font]
            let size = emoji.size(withAttributes: attributes)
            emoji.draw(at: NSPoint(x: (side - size.width) / 2, y: (side - size.height) / 2), withAttributes: attributes)
            NSGraphicsContext.restoreGraphicsState()
            guard let png = bitmap.representation(using: .png, properties: [:]) else { fail("could not encode PNG") }
            let suffix = scale == 2 ? "@2x" : ""
            try png.write(to: output.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
        }
    }
} catch {
    fail(error.localizedDescription)
}
