import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// kof22.com's palette: Tailwind zinc neutrals with an emerald prompt accent.
/// Values come from Website-Frontend (`TerminalWindow.tsx`, `layout.tsx`).
public enum Theme {
    public static let background = Color(light: 0xFAFAFA, dark: 0x000000)
    public static let surface = Color(light: 0xFFFFFF, dark: 0x18181B)
    public static let terminal = Color(light: 0xFAFAFA, dark: 0x0A0A0A)
    public static let titleBar = Color(light: 0xF4F4F5, dark: 0x18181B)
    public static let border = Color(light: 0xE4E4E7, dark: 0x27272A)
    public static let heading = Color(light: 0x27272A, dark: 0xF4F4F5)
    public static let body = Color(light: 0x52525B, dark: 0xA1A1AA)
    public static let muted = Color(light: 0x71717A, dark: 0x71717A)
    public static let accent = Color(light: 0x059669, dark: 0x34D399)
    public static let link = Color(light: 0x14B8A6, dark: 0x2DD4BF)
    public static let danger = Color(light: 0xEF4444, dark: 0xF87171)
    public static let warning = Color(light: 0xCA8A04, dark: 0xFACC15)

    /// Monospace accents scale with Dynamic Type.
    public static func mono(_ style: Font.TextStyle = .body, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .monospaced, weight: weight)
    }
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        #if canImport(UIKit)
        self.init(uiColor: UIColor { traits in
            UIColor(rgb: traits.userInterfaceStyle == .dark ? dark : light)
        })
        #else
        self.init(rgb: dark)
        #endif
    }

    init(rgb: UInt32) {
        self.init(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }
}

#if canImport(UIKit)
extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}
#endif

/// The underscore cursor from the site: 1.5 s cycle, hard on/off.
public struct BlinkingCursor: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// UI tests wait for the app to go idle, which a running timeline prevents.
    private static let isStatic = ProcessInfo.processInfo.arguments.contains("-uitest")

    public init() {}

    public var body: some View {
        TimelineView(.periodic(from: .now, by: Self.isStatic ? 3600 : 0.75)) { context in
            let visible = reduceMotion || Self.isStatic || Int(context.date.timeIntervalSinceReferenceDate / 0.75) % 2 == 0
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
    let path: String
    let showCursor: Bool

    public init(_ path: String = "~", cursor: Bool = false) {
        self.path = path
        self.showCursor = cursor
    }

    public var body: some View {
        HStack(spacing: 0) {
            Text("james@kof22:\(path)").foregroundStyle(Theme.muted)
            Text("$").foregroundStyle(Theme.accent).padding(.trailing, 4)
            if showCursor { BlinkingCursor() }
        }
        .font(Theme.mono(.footnote))
        .lineLimit(1)
        .accessibilityLabel("kof22 \(path)")
    }
}

/// A macOS-style terminal panel with the three title-bar dots.
public struct TerminalPanel<Content: View>: View {
    let title: String
    let content: Content

    public init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach([Color.red, .yellow, .green], id: \.self) { color in
                    Circle().fill(color.opacity(0.8)).frame(width: 10, height: 10)
                }
                Text(title).font(Theme.mono(.caption2)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity)
                Color.clear.frame(width: 42, height: 1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.titleBar)
            Divider().overlay(Theme.border)
            content.frame(maxWidth: .infinity, alignment: .leading).padding(14).background(Theme.terminal)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
    }
}

/// Outlined emerald chip, as tags look on the site.
public struct TagChip: View {
    let name: String
    let onRemove: (() -> Void)?

    public init(_ name: String, onRemove: (() -> Void)? = nil) {
        self.name = name
        self.onRemove = onRemove
    }

    public var body: some View {
        HStack(spacing: 4) {
            Text("#\(name)")
            if let onRemove {
                Button(action: onRemove) { Image(systemName: "xmark").font(.caption2.bold()) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove tag \(name)")
            }
        }
        .font(Theme.mono(.caption))
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .overlay(Capsule().stroke(Theme.accent.opacity(0.4)))
    }
}

public struct StatusBadge: View {
    let status: PostStatus

    public init(_ status: PostStatus) { self.status = status }

    public var body: some View {
        Text(status.label.lowercased())
            .font(Theme.mono(.caption2, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(Capsule().stroke(color.opacity(0.5)))
    }

    var color: Color {
        switch status {
        case .published: Theme.accent
        case .scheduled: Theme.link
        case .draft: Theme.muted
        }
    }
}
