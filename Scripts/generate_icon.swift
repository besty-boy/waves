import AppKit

let assets = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

func render(size: Int, mac: Bool, filename: String) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    let context = graphics.cgContext
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let inset: CGFloat = mac ? 72 : 0
    let plate = CGRect(x: inset, y: inset, width: 1024 - 2 * inset, height: 1024 - 2 * inset)
    let path = CGPath(roundedRect: plate, cornerWidth: mac ? 192 : 0, cornerHeight: mac ? 192 : 0, transform: nil)
    if mac { context.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: NSColor.black.withAlphaComponent(0.12).cgColor) }
    context.setFillColor(NSColor.white.cgColor)
    context.addPath(path)
    context.fillPath()
    context.setShadow(offset: .zero, blur: 0, color: nil)
    context.saveGState()
    context.addPath(path)
    context.clip()
    let colors = [NSColor.white.cgColor, NSColor(calibratedWhite: 0.955, alpha: 1).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 940), end: CGPoint(x: 512, y: 80), options: [])
    context.restoreGState()
    let wave = CGMutablePath()
    wave.move(to: CGPoint(x: 254, y: 512))
    wave.addCurve(to: CGPoint(x: 370, y: 512), control1: CGPoint(x: 302, y: 512), control2: CGPoint(x: 322, y: 512))
    wave.addCurve(to: CGPoint(x: 462, y: 728), control1: CGPoint(x: 420, y: 512), control2: CGPoint(x: 422, y: 728))
    wave.addCurve(to: CGPoint(x: 562, y: 300), control1: CGPoint(x: 508, y: 728), control2: CGPoint(x: 510, y: 300))
    wave.addCurve(to: CGPoint(x: 658, y: 512), control1: CGPoint(x: 608, y: 300), control2: CGPoint(x: 612, y: 512))
    wave.addCurve(to: CGPoint(x: 770, y: 512), control1: CGPoint(x: 706, y: 512), control2: CGPoint(x: 732, y: 512))
    context.setStrokeColor(NSColor(calibratedRed: 0, green: 0.478, blue: 1, alpha: 1).cgColor)
    context.setLineWidth(48)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.addPath(wave)
    context.strokePath()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: assets.appendingPathComponent(filename))
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let filename = "mac-\(points)@\(scale)x.png"
        try render(size: points * scale, mac: true, filename: filename)
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": filename])
    }
}
try render(size: 1024, mac: false, filename: "ios-1024.png")
images.append(["idiom": "universal", "platform": "ios", "size": "1024x1024", "filename": "ios-1024.png"])
let manifest: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    .write(to: assets.appendingPathComponent("Contents.json"))
