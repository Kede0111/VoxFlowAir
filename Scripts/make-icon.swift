// Generates Resources/AppIcon.icns (run by Scripts/make-icon.sh).
import AppKit
let out = CommandLine.arguments[1]
let sizes = [16, 32, 64, 128, 256, 512, 1024]
for s in sizes {
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    let r = NSRect(x: 0, y: 0, width: s, height: s).insetBy(dx: CGFloat(s) * 0.09, dy: CGFloat(s) * 0.09)
    let path = NSBezierPath(roundedRect: r, xRadius: CGFloat(s) * 0.2, yRadius: CGFloat(s) * 0.2)
    NSGradient(colors: [NSColor(srgbRed: 0.09, green: 0.10, blue: 0.13, alpha: 1), NSColor(srgbRed: 0.16, green: 0.18, blue: 0.23, alpha: 1)])!.draw(in: path, angle: 90)
    let cfg = NSImage.SymbolConfiguration(pointSize: CGFloat(s) * 0.5, weight: .semibold)
        .applying(.init(paletteColors: [NSColor(srgbRed: 0.31, green: 0.64, blue: 1, alpha: 1)]))
    if let sym = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let sz = sym.size
        sym.draw(in: NSRect(x: (CGFloat(s) - sz.width) / 2, y: (CGFloat(s) - sz.height) / 2, width: sz.width, height: sz.height))
    }
    img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    let png = rep.representation(using: .png, properties: [:])!
    let names: [Int: [String]] = [16: ["16x16"], 32: ["16x16@2x", "32x32"], 64: ["32x32@2x"], 128: ["128x128"], 256: ["128x128@2x", "256x256"], 512: ["256x256@2x", "512x512"], 1024: ["512x512@2x"]]
    for n in names[s]! { try! png.write(to: URL(fileURLWithPath: "\(out)/icon_\(n).png")) }
}
