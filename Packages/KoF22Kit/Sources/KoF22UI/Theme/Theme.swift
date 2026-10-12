/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import SwiftUI

#if canImport(UIKit)
   import UIKit
#endif

/// kof22.com's palette and layout tokens: Tailwind zinc neutrals with an emerald prompt
/// accent. Colour values come from Website-Frontend (`TerminalWindow.tsx`, `layout.tsx`);
/// spacing, radius, size and opacity tokens keep every screen on the same scale.
public enum Theme {
   /// Screen background behind scroll views and forms.
   public static let background = Color(light: Palette.zinc50, dark: Palette.black)
   /// Raised surfaces such as the editor, cards and image placeholders.
   public static let surface = Color(light: Palette.white, dark: Palette.zinc900)
   /// Body of a terminal panel.
   public static let terminal = Color(light: Palette.zinc50, dark: Palette.zinc950)
   /// Title bar of a terminal panel.
   public static let titleBar = Color(light: Palette.zinc100, dark: Palette.zinc900)
   /// Hairline borders and dividers.
   public static let border = Color(light: Palette.zinc200, dark: Palette.zinc800)
   /// Headings and post titles.
   public static let heading = Color(light: Palette.zinc800, dark: Palette.zinc100)
   /// Running text such as excerpts and descriptions.
   public static let body = Color(light: Palette.zinc600, dark: Palette.zinc400)
   /// Secondary labels, placeholders and timestamps.
   public static let muted = Color(light: Palette.zinc500, dark: Palette.zinc500)
   /// The emerald prompt accent used for actions, tags and the cursor.
   public static let accent = Color(light: Palette.emerald600, dark: Palette.emerald400)
   /// Links and the scheduled status.
   public static let link = Color(light: Palette.teal500, dark: Palette.teal400)
   /// Failures and destructive states.
   public static let danger = Color(light: Palette.red500, dark: Palette.red400)
   /// Warnings such as photos without alt text.
   public static let warning = Color(light: Palette.yellow600, dark: Palette.yellow400)

   /// Monospaced font for terminal accents. It is built from a text style so it scales
   /// with Dynamic Type like the rest of the interface.
   public static func mono(_ style: Font.TextStyle = .body, weight: Font.Weight = .regular) -> Font {
      .system(style, design: .monospaced, weight: weight)
   }

   /// Named hex values of the Tailwind colours the site uses, so colour tokens read as
   /// design names instead of raw numbers.
   public enum Palette {
      /// Tailwind zinc-50.
      public static let zinc50: UInt32 = 0xFAFAFA
      /// Tailwind zinc-100.
      public static let zinc100: UInt32 = 0xF4F4F5
      /// Tailwind zinc-200.
      public static let zinc200: UInt32 = 0xE4E4E7
      /// Tailwind zinc-400.
      public static let zinc400: UInt32 = 0xA1A1AA
      /// Tailwind zinc-500.
      public static let zinc500: UInt32 = 0x71717A
      /// Tailwind zinc-600.
      public static let zinc600: UInt32 = 0x52525B
      /// Tailwind zinc-800.
      public static let zinc800: UInt32 = 0x27272A
      /// Tailwind zinc-900.
      public static let zinc900: UInt32 = 0x18181B
      /// Tailwind zinc-950.
      public static let zinc950: UInt32 = 0x0A0A0A
      /// Pure white.
      public static let white: UInt32 = 0xFFFFFF
      /// Pure black.
      public static let black: UInt32 = 0x000000
      /// Tailwind emerald-400.
      public static let emerald400: UInt32 = 0x34D399
      /// Tailwind emerald-600.
      public static let emerald600: UInt32 = 0x059669
      /// Tailwind teal-400.
      public static let teal400: UInt32 = 0x2DD4BF
      /// Tailwind teal-500.
      public static let teal500: UInt32 = 0x14B8A6
      /// Tailwind red-400.
      public static let red400: UInt32 = 0xF87171
      /// Tailwind red-500.
      public static let red500: UInt32 = 0xEF4444
      /// Tailwind yellow-400.
      public static let yellow400: UInt32 = 0xFACC15
      /// Tailwind yellow-600.
      public static let yellow600: UInt32 = 0xCA8A04
   }

   /// Padding and stack spacing, smallest to largest.
   public enum Spacing {
      /// 2 pt: badge vertical padding and post-row padding.
      public static let xxSmall: CGFloat = 2
      /// 3 pt: padding inside the ALT badge.
      public static let badgeInset: CGFloat = 3
      /// 4 pt: tight stacks and chip padding.
      public static let xSmall: CGFloat = 4
      /// 5 pt: blog-menu vertical padding and the editor placeholder's leading inset,
      /// which lines the placeholder up with the text view's caret.
      public static let compact: CGFloat = 5
      /// 6 pt: small stacks and badge horizontal padding.
      public static let small: CGFloat = 6
      /// 8 pt: default gap between related items.
      public static let medium: CGFloat = 8
      /// 10 pt: card padding and medium stacks.
      public static let regular: CGFloat = 10
      /// 12 pt: title-bar and details-card padding.
      public static let large: CGFloat = 12
      /// 14 pt: gap between composer sections and terminal padding.
      public static let xLarge: CGFloat = 14
      /// 18 pt: horizontal padding of the Post button.
      public static let buttonHorizontal: CGFloat = 18
      /// 24 pt: gap between the sign-in screen's blocks.
      public static let xxLarge: CGFloat = 24
      /// 40 pt: side inset of the sign-in backend picker.
      public static let pickerHorizontal: CGFloat = 40
   }

   /// Corner radii.
   public enum Radius {
      /// 3 pt: the ALT badge.
      public static let badge: CGFloat = 3
      /// 6 pt: post-list thumbnails.
      public static let small: CGFloat = 6
      /// 8 pt: cards, panels, the editor and photos.
      public static let card: CGFloat = 8
      /// 10 pt: the sign-in button.
      public static let button: CGFloat = 10
   }

   /// Fixed dimensions.
   public enum Size {
      /// Diameter of a terminal title-bar dot.
      public static let windowDot: CGFloat = 10
      /// Width of the clear spacer that balances the dots so the title stays centred.
      public static let titleBarBalanceWidth: CGFloat = 42
      /// Height of the title-bar balancing spacer.
      public static let titleBarBalanceHeight: CGFloat = 1
      /// Photo thumbnails in the composer strip.
      public static let stripThumbnail: CGFloat = 84
      /// The photo in the alt-text sheet.
      public static let detailThumbnail: CGFloat = 220
      /// Thumbnails in lists (arrange sheet, post list).
      public static let listThumbnail: CGFloat = 56
      /// Minimum height of the editor and the preview.
      public static let editorMinHeight: CGFloat = 160
      /// Placeholder height while a photo loads in the composer preview.
      public static let imagePlaceholder: CGFloat = 160
      /// Placeholder height while a photo loads in post detail.
      public static let detailImagePlaceholder: CGFloat = 200
      /// Maximum width of the Write/Preview switch.
      public static let modePickerMaxWidth: CGFloat = 220
   }

   /// Opacity levels.
   public enum Opacity {
      /// Terminal title-bar dots.
      public static let windowDot: Double = 0.8
      /// Accent outlines on chips and the blog menu.
      public static let outline: Double = 0.4
      /// Status badge outlines.
      public static let badgeOutline: Double = 0.5
      /// A disabled primary button.
      public static let disabled: Double = 0.5
      /// The editor border while it has focus.
      public static let focusRing: Double = 0.6
   }

   /// Line limits for text that is truncated.
   public enum LineLimit {
      /// Titles and summaries in lists.
      public static let title = 2
      /// Post excerpts in the list.
      public static let excerpt = 2
      /// Alt-text labels in the arrange sheet.
      public static let altTextLabel = 2
      /// The description in a link preview card.
      public static let linkDescription = 3
      /// Growth range of the alt-text field.
      public static let altTextField = 2...6
      /// Growth range of the caption field.
      public static let captionField = 1...4
   }
}

extension Color {
   /// Creates a colour that switches between two hex values with the interface style.
   /// Without UIKit there is no trait to follow, so the dark value is used.
   init(light: UInt32, dark: UInt32) {
      #if canImport(UIKit)
         self.init(
            uiColor: UIColor { traits in
               UIColor(rgb: traits.userInterfaceStyle == .dark ? dark : light)
            })
      #else
         self.init(rgb: dark)
      #endif
   }

   /// Creates an opaque sRGB colour from a `0xRRGGBB` value.
   init(rgb: UInt32) {
      self.init(red: RGBChannel.red.value(in: rgb), green: RGBChannel.green.value(in: rgb), blue: RGBChannel.blue.value(in: rgb))
   }
}

/// One 8-bit channel of a `0xRRGGBB` value, with the bit offset that selects it.
enum RGBChannel: UInt32 {
   /// Bits 16 to 23.
   case red = 16
   /// Bits 8 to 15.
   case green = 8
   /// Bits 0 to 7.
   case blue = 0

   /// Mask for one channel after shifting.
   private static let mask: UInt32 = 0xFF
   /// Largest channel value, used to scale to 0...1.
   private static let maximum: Double = 255

   /// The channel's intensity in `rgb`, scaled to 0...1.
   func value(in rgb: UInt32) -> Double {
      Double((rgb >> rawValue) & Self.mask) / Self.maximum
   }
}

#if canImport(UIKit)
   extension UIColor {
      /// Creates an opaque colour from a `0xRRGGBB` value.
      convenience init(rgb: UInt32) {
         self.init(
            red: CGFloat(RGBChannel.red.value(in: rgb)), green: CGFloat(RGBChannel.green.value(in: rgb)),
            blue: CGFloat(RGBChannel.blue.value(in: rgb)), alpha: 1)
      }
   }
#endif

/// The underscore cursor from the site: a 1.5 s cycle that is hard on and off.
public struct BlinkingCursor: View {
   /// Reduce Motion keeps the cursor visible instead of blinking.
   @Environment(\.accessibilityReduceMotion) private var reduceMotion
   /// UI tests wait for the app to go idle, which a running timeline prevents.
   private static let isStatic = ProcessInfo.processInfo.arguments.contains("-uitest")
   /// Half of the blink cycle: how long the cursor stays on or off.
   private static let blinkInterval: TimeInterval = 0.75
   /// Timeline period under UI tests, long enough that it never fires during a test.
   private static let staticInterval: TimeInterval = 3600
   /// The cycle has two phases, on and off.
   private static let phaseCount = 2

   /// Creates a cursor.
   public init() {}

   /// A timeline that toggles the underscore every half cycle.
   public var body: some View {
      TimelineView(.periodic(from: .now, by: Self.isStatic ? Self.staticInterval : Self.blinkInterval)) { context in
         let phase = Int(context.date.timeIntervalSinceReferenceDate / Self.blinkInterval)
         let visible = reduceMotion || Self.isStatic || phase.isMultiple(of: Self.phaseCount)
         Text("_")
            .font(Theme.mono(.body, weight: .bold))
            .foregroundStyle(Theme.accent)
            .opacity(visible ? 1 : 0)
      }
      .accessibilityHidden(true)
   }
}

/// `james@kof22:~/path$` styled like the site's breadcrumb.
public struct PromptLabel: View {
   /// Working directory shown after the host name.
   let path: String
   /// Whether a blinking cursor follows the prompt.
   let showCursor: Bool

   /// Creates a prompt for `path`, optionally followed by a blinking cursor.
   public init(_ path: String = "~", cursor: Bool = false) {
      self.path = path
      self.showCursor = cursor
   }

   /// The prompt text, the accent `$` and the optional cursor on one line.
   public var body: some View {
      HStack(spacing: 0) {
         Text("james@kof22:\(path)").foregroundStyle(Theme.muted)
         Text("$").foregroundStyle(Theme.accent).padding(.trailing, Theme.Spacing.xSmall)
         if showCursor { BlinkingCursor() }
      }
      .font(Theme.mono(.footnote))
      .lineLimit(1)
      .accessibilityLabel("kof22 \(path)")
   }
}

/// A macOS-style terminal panel with the three title-bar dots.
public struct TerminalPanel<Content: View>: View {
   /// Text centred in the title bar.
   let title: String
   /// The panel's body.
   let content: Content

   /// Creates a panel titled `title` around `content`.
   public init(_ title: String, @ViewBuilder content: () -> Content) {
      self.title = title
      self.content = content()
   }

   /// The title bar, a divider and the padded content, clipped to a rounded card.
   public var body: some View {
      VStack(spacing: 0) {
         titleBar
         Divider().overlay(Theme.border)
         content.frame(maxWidth: .infinity, alignment: .leading).padding(Theme.Spacing.xLarge).background(Theme.terminal)
      }
      .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
      .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.border))
   }

   /// Red, yellow and green dots, the centred title and a clear spacer that balances the dots.
   private var titleBar: some View {
      HStack(spacing: Theme.Spacing.small) {
         ForEach([Color.red, .yellow, .green], id: \.self) { color in
            Circle().fill(color.opacity(Theme.Opacity.windowDot)).frame(width: Theme.Size.windowDot, height: Theme.Size.windowDot)
         }
         Text(title).font(Theme.mono(.caption2)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity)
         Color.clear.frame(width: Theme.Size.titleBarBalanceWidth, height: Theme.Size.titleBarBalanceHeight)
      }
      .padding(.horizontal, Theme.Spacing.large)
      .padding(.vertical, Theme.Spacing.medium)
      .background(Theme.titleBar)
   }
}

/// Outlined emerald chip, as tags look on the site.
public struct TagChip: View {
   /// Tag name without the leading `#`.
   let name: String
   /// Called by the remove button; nil hides the button.
   let onRemove: (() -> Void)?

   /// Creates a chip for `name`, with a remove button when `onRemove` is given.
   public init(_ name: String, onRemove: (() -> Void)? = nil) {
      self.name = name
      self.onRemove = onRemove
   }

   /// `#name` and the optional remove button inside an accent capsule outline.
   public var body: some View {
      HStack(spacing: Theme.Spacing.xSmall) {
         Text("#\(name)")
         if let onRemove {
            Button(action: onRemove) { Image(systemName: "xmark").font(.caption2.bold()) }
               .buttonStyle(.plain)
               .accessibilityLabel("Remove tag \(name)")
         }
      }
      .font(Theme.mono(.caption))
      .foregroundStyle(Theme.accent)
      .padding(.horizontal, Theme.Spacing.medium)
      .padding(.vertical, Theme.Spacing.xSmall)
      .overlay(Capsule().stroke(Theme.accent.opacity(Theme.Opacity.outline)))
   }
}

/// A post's publication status as a small lowercase capsule.
public struct StatusBadge: View {
   /// Status to show.
   let status: PostStatus

   /// Creates a badge for `status`.
   public init(_ status: PostStatus) { self.status = status }

   /// The lowercase label in the status colour with a matching outline.
   public var body: some View {
      Text(status.label.lowercased())
         .font(Theme.mono(.caption2, weight: .medium))
         .foregroundStyle(color)
         .padding(.horizontal, Theme.Spacing.small)
         .padding(.vertical, Theme.Spacing.xxSmall)
         .overlay(Capsule().stroke(color.opacity(Theme.Opacity.badgeOutline)))
   }

   /// Accent for published, link teal for scheduled, muted for drafts.
   var color: Color {
      switch status {
      case .published: Theme.accent
      case .scheduled: Theme.link
      case .draft: Theme.muted
      }
   }
}
