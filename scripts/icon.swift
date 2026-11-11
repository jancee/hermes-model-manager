import AppKit
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = size * scale
        let image = NSImage(size: NSSize(width: px, height: px))
        image.lockFocus()
        let rect = NSRect(x: Double(px) * 0.055, y: Double(px) * 0.055, width: Double(px) * 0.89, height: Double(px) * 0.89)
        let shape = NSBezierPath(roundedRect: rect, xRadius: Double(px) * 0.20, yRadius: Double(px) * 0.20)
        let gradient = NSGradient(starting: NSColor(calibratedRed: 0.12, green: 0.58, blue: 0.52, alpha: 1), ending: NSColor(calibratedRed: 0.04, green: 0.27, blue: 0.27, alpha: 1))!
        gradient.draw(in: shape, angle: -70)
        let cpu = NSImage(systemSymbolName: "cpu", accessibilityDescription: nil)!
        let cfg = NSImage.SymbolConfiguration(pointSize: CGFloat(px) * 0.53, weight: .light)
        let symbol = cpu.withSymbolConfiguration(cfg)!
        let symbolRect = NSRect(x: Double(px) * 0.22, y: Double(px) * 0.22, width: Double(px) * 0.56, height: Double(px) * 0.56)
        let tinted = NSImage(size: symbol.size)
        tinted.lockFocus()
        symbol.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        tinted.draw(in: symbolRect)
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
    }
}
