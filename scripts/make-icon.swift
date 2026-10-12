/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

/////////////////////////////////////////////////////////////////////
// Renders the app icon: kof22.com terminal prompt on zinc-950.    //
// Usage: swift scripts/make-icon.swift <output.png>               //
/////////////////////////////////////////////////////////////////////
import AppKit

/// Icon geometry and colours, in points of the 1024-pt App Store icon.
enum IconSpec {
   /// Edge length of the square icon.
   static let size = 1024.0
   /// sRGB components of the zinc-950 background.
   static let backgroundRGB = (red: 0.035, green: 0.035, blue: 0.043)
   /// sRGB components of the emerald prompt colour.
   static let promptRGB = (red: 0.204, green: 0.827, blue: 0.6)
   /// Zinc-950 background.
   static let background = NSColor(red: backgroundRGB.red, green: backgroundRGB.green, blue: backgroundRGB.blue, alpha: 1)
   /// Prompt green for the `$_` glyphs.
   static let prompt = NSColor(red: promptRGB.red, green: promptRGB.green, blue: promptRGB.blue, alpha: 1)
   /// Opacity of the window-control dots.
   static let dotAlpha = 0.85
   /// Left edge of the first window-control dot.
   static let dotOriginX = 150.0
   /// Distance from the top edge to the bottom of the dots.
   static let dotInsetFromTop = 230.0
   /// Horizontal distance between the left edges of neighbouring dots.
   static let dotPitch = 95.0
   /// Diameter of each dot.
   static let dotDiameter = 64.0
   /// Font size of the `$_` prompt.
   static let promptFontSize = 430.0
   /// How far the prompt sits below the optical centre.
   static let promptDrop = 70.0
}

/// Writes `message` to standard error and stops with a failure status.
func fail(_ message: String) -> Never {
   FileHandle.standardError.write(Data("make-icon: \(message)\n".utf8))
   exit(EXIT_FAILURE)
}

/// Draws the icon into a bitmap and returns it as PNG data.
func renderIcon() -> Data {
   let size = IconSpec.size
   let image = NSImage(size: NSSize(width: size, height: size))
   image.lockFocus()
   IconSpec.background.setFill()
   NSRect(x: 0, y: 0, width: size, height: size).fill()
   let dots: [NSColor] = [.systemRed, .systemYellow, .systemGreen]
   for (index, color) in dots.enumerated() {
      color.withAlphaComponent(IconSpec.dotAlpha).setFill()
      let originX = IconSpec.dotOriginX + Double(index) * IconSpec.dotPitch
      NSBezierPath(
         ovalIn: NSRect(
            x: originX, y: size - IconSpec.dotInsetFromTop,
            width: IconSpec.dotDiameter, height: IconSpec.dotDiameter)
      )
      .fill()
   }
   let font = NSFont.monospacedSystemFont(ofSize: IconSpec.promptFontSize, weight: .bold)
   let text = NSMutableAttributedString(string: "$_", attributes: [.font: font, .foregroundColor: IconSpec.prompt])
   let bounds = text.size()
   let half = 2.0
   text.draw(at: NSPoint(x: (size - bounds.width) / half, y: (size - bounds.height) / half - IconSpec.promptDrop))
   image.unlockFocus()
   guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
      fail("could not rasterise the icon")
   }
   guard let png = rep.representation(using: .png, properties: [:]) else {
      fail("could not encode the icon as PNG")
   }
   return png
}

guard CommandLine.arguments.count > 1 else { fail("usage: swift scripts/make-icon.swift <output.png>") }
let outputPath = CommandLine.arguments[1]
do {
   try renderIcon().write(to: URL(fileURLWithPath: outputPath))
}
catch {
   fail("could not write \(outputPath): \(error.localizedDescription)")
}
