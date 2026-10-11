// Renders the app icon: kof22.com terminal prompt on zinc-950.
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
NSColor(red: 0.035, green: 0.035, blue: 0.043, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: size, height: size).fill()
let dots: [NSColor] = [.systemRed, .systemYellow, .systemGreen]
for (i, color) in dots.enumerated() {
   color.withAlphaComponent(0.85).setFill()
   NSBezierPath(ovalIn: NSRect(x: 150 + Double(i) * 95, y: size - 230, width: 64, height: 64)).fill()
}
let green = NSColor(red: 0.204, green: 0.827, blue: 0.6, alpha: 1)
let font = NSFont.monospacedSystemFont(ofSize: 430, weight: .bold)
let text = NSMutableAttributedString(string: "$_", attributes: [.font: font, .foregroundColor: green])
let bounds = text.size()
text.draw(at: NSPoint(x: (size - bounds.width) / 2, y: (size - bounds.height) / 2 - 70))
image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
