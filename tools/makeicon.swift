import AppKit

// AppIcon.icns üretir: kırmızı-turuncu gradyanlı yuvarlak kare + beyaz kilit simgesi.
// Kullanım: swiftc tools/makeicon.swift -o /tmp/makeicon && /tmp/makeicon AppIcon.iconset

func render(size: Int) -> Data? {
    let s = CGFloat(size)
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    let rect = NSRect(x: s * 0.06, y: s * 0.06, width: s * 0.88, height: s * 0.88)
    let path = NSBezierPath(roundedRect: rect, xRadius: s * 0.2, yRadius: s * 0.2)
    NSGradient(colors: [NSColor(red: 1.0, green: 0.36, blue: 0.30, alpha: 1),
                        NSColor(red: 0.80, green: 0.10, blue: 0.20, alpha: 1)])?
        .draw(in: path, angle: -90)

    let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.46, weight: .bold)
        .applying(.init(paletteColors: [.white]))
    if let sym = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) {
        let w = sym.size.width, h = sym.size.height
        sym.draw(in: NSRect(x: (s - w) / 2, y: (s - h) / 2, width: w, height: h))
    }
    img.unlockFocus()

    guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
    return rep.representation(using: .png, properties: [:])
}

let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in sizes {
    if let png = render(size: px) {
        try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }
}
print("iconset hazır: \(dir)")
