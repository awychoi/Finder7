import AppKit
import SwiftUI

// MARK: - Brand

/// Finder7 is the product; wychoi is the maker. Keep both palettes here so the
/// app icon, window chrome and About panel cannot drift apart.
enum Brand {
    // Finder7 (paper-crease mark)
    static let purple = Color(.sRGB, red: 0.318, green: 0.267, blue: 0.898, opacity: 1)        // #5144E5
    static let lavender = Color(.sRGB, red: 0.663, green: 0.596, blue: 0.980, opacity: 1)      // #A998FA
    static let wash = Color(.sRGB, red: 0.847, green: 0.808, blue: 1.000, opacity: 1)          // #D8CEFF
    static let fold = Color(.sRGB, red: 0.710, green: 0.639, blue: 1.000, opacity: 1)          // #B5A3FF
    static let paper = Color(.sRGB, red: 1.000, green: 0.988, blue: 1.000, opacity: 1)         // #FFFCFF
    static let ink = Color(.sRGB, red: 0.094, green: 0.125, blue: 0.184, opacity: 1)           // #18202F

    /// Accessible purple for text and small glyphs in both appearances.
    static let purpleText = dynamic(
        light: NSColor(srgbRed: 0.318, green: 0.267, blue: 0.898, alpha: 1),
        dark: NSColor(srgbRed: 0.690, green: 0.635, blue: 0.992, alpha: 1)
    )

    // wychoi (abacus)
    static let makerInk = Color(.sRGB, red: 0.027, green: 0.035, blue: 0.051, opacity: 1)      // #07090D
    static let makerBlue = dynamic(
        light: NSColor(srgbRed: 0.184, green: 0.373, blue: 0.878, alpha: 1),   // #2F5FE0
        dark: NSColor(srgbRed: 0.541, green: 0.678, blue: 1.000, alpha: 1)     // #8AADFF
    )
    static let makerSky = Color(.sRGB, red: 0.357, green: 0.553, blue: 1.000, opacity: 1)      // #5B8DFF
    static let abacusStroke = Color(.sRGB, red: 0.494, green: 0.576, blue: 0.722, opacity: 1)  // #7E93B8

    /// Finder7 is an independent GUI; keep the maker's blue available for the
    /// About section without tinting the whole utility blue.
    static let surface = Color(nsColor: .controlBackgroundColor)

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

// MARK: - Type

/// One type ramp for the whole app. The system face keeps the app native and
/// crisp at every size; monospaced styles are reserved for paths and versions.
enum AppFont {
    static let sectionTitle = Font.system(size: 14.5, weight: .semibold)
    static let rowTitle = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 13, weight: .regular)
    static let bodyMedium = Font.system(size: 13, weight: .medium)
    static let secondary = Font.system(size: 12, weight: .regular)
    static let caption = Font.system(size: 11, weight: .regular)
    static let eyebrow = Font.system(size: 11, weight: .semibold)
    static let mono = Font.system(size: 11, weight: .regular, design: .monospaced)
    static let monoValue = Font.system(size: 11.5, weight: .medium, design: .monospaced)
}

// MARK: - Logo

/// The official paper-crease 7, drawn from the same 128 × 128 geometry as
/// the app icon.
struct Finder7Glyph: View {
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 128
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: x * scale, y: y * scale)
            }
            func path(_ points: [(CGFloat, CGFloat)], close: Bool = true) -> Path {
                var path = Path()
                guard let first = points.first else { return path }
                path.move(to: point(first.0, first.1))
                for value in points.dropFirst() {
                    path.addLine(to: point(value.0, value.1))
                }
                if close { path.closeSubpath() }
                return path
            }

            // Paper body, its crease shadow, the folded top bar, then the fold.
            context.fill(
                path([(98, 32), (95, 52), (55, 103), (39, 91), (70, 51)]),
                with: .color(Brand.wash)
            )
            context.fill(
                path([(98, 32), (95, 52), (55, 103), (49, 98)]),
                with: .color(Brand.lavender)
            )
            context.fill(
                path([(29, 32), (98, 32), (77, 51), (29, 51)]),
                with: .color(Brand.paper)
            )
            context.fill(
                path([(98, 32), (95, 52), (77, 51)]),
                with: .color(Brand.fold)
            )
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// The mark on its purple tile. This is the "7" in the wordmark and the art in
/// the app icon, so both stay identical.
struct Finder7Mark: View {
    var size: CGFloat
    var showsTile = true

    var body: some View {
        ZStack {
            if showsTile {
                RoundedRectangle(cornerRadius: size * 29 / 128, style: .continuous)
                    .fill(Brand.purple)
            }
            Finder7Glyph()
                .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The Finder7 wordmark: "Finder" set tight, with the paper-crease tile sitting
/// exactly where the 7 belongs. The official file is composed the same way; the
/// only difference is that the logo no longer stands apart on the left.
struct FinderWordmark: View {
    var size: CGFloat = 22
    var tint: Color? = nil

    var body: some View {
        HStack(alignment: .center, spacing: size * 0.085) {
            Text("Finder")
                .font(.system(size: size, weight: .bold))
                .tracking(-size * 0.052)
                .foregroundStyle(tint ?? Color.primary)
            Finder7Mark(size: size * 1.18)
                .offset(y: -size * 0.01)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Finder7")
    }
}

/// The abacus — wychoi's maker mark — redrawn from the official 1024 × 1024
/// artwork. Pass `tint` for a single-colour version (the compact maker pill);
/// the default white-on-black version is used on the maker tile.
struct AbacusGlyph: View {
    var tint: Color? = nil

    var body: some View {
        Canvas { context, size in
            let strokeColor = tint ?? .white
            let wireColor = tint?.opacity(0.5) ?? Brand.abacusStroke.opacity(0.6)
            let beadColor = tint ?? .white
            let accentColor = tint ?? Brand.makerSky
            let scale = min(size.width, size.height) / 1024
            func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
                CGRect(x: x * scale, y: y * scale, width: width * scale, height: height * scale)
            }
            func lineWidth(_ value: CGFloat) -> CGFloat { value * scale }

            // Frame
            let frame = Path(
                roundedRect: rect(160, 250, 704, 524),
                cornerSize: CGSize(width: 88 * scale, height: 88 * scale)
            )
            context.stroke(frame, with: .color(strokeColor), lineWidth: lineWidth(46))

            // Wires
            for y in [CGFloat(400), 512, 624] {
                var wire = Path()
                wire.move(to: CGPoint(x: 216 * scale, y: y * scale))
                wire.addLine(to: CGPoint(x: 808 * scale, y: y * scale))
                context.stroke(
                    wire,
                    with: .color(wireColor),
                    lineWidth: lineWidth(14)
                )
            }

            // Beads
            func bead(_ x: CGFloat, _ y: CGFloat, color: Color) {
                let circle = Path(ellipseIn: rect(x - 68, y - 68, 136, 136))
                context.fill(circle, with: .color(color))
            }
            bead(320, 400, color: beadColor)
            bead(512, 400, color: beadColor)
            bead(704, 400, color: beadColor)
            bead(416, 624, color: beadColor)
            bead(608, 624, color: beadColor)
            bead(512, 400, color: accentColor)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

// MARK: - Shared views

struct SectionEyebrow: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(AppFont.eyebrow)
            .tracking(0.9)
            .foregroundStyle(.secondary)
    }
}

struct PanelHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Brand.purpleText)
                .frame(width: 15)
            Text(title)
                .font(AppFont.sectionTitle)
        }
        .accessibilityElement(children: .combine)
    }
}

struct BrandPill: View {
    let text: String
    var filled = true

    var body: some View {
        Text(text)
            .font(AppFont.caption.weight(.medium))
            .foregroundStyle(filled ? Brand.purpleText : Color.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(
                Capsule().fill(filled ? Brand.purpleText.opacity(0.12) : Color.secondary.opacity(0.10))
            )
    }
}

struct Panel<Content: View>: View {
    var padding: CGFloat
    let content: Content

    init(padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Brand.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.62), lineWidth: 0.75)
            )
    }
}

/// Section card used by Settings and About.
struct SettingsCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Brand.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.62), lineWidth: 0.75)
        )
    }
}

struct SettingsDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 16)
    }
}

struct SettingsRow<Content: View>: View {
    let title: String
    var subtitle: String?
    let content: Content

    init(
        _ title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppFont.bodyMedium)
                if let subtitle {
                    Text(subtitle)
                        .font(AppFont.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            content
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    var footnote: String?
    let content: Content

    init(
        _ title: String,
        footnote: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.footnote = footnote
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionEyebrow(text: title)
                .padding(.horizontal, 2)
            SettingsCard { content }
            if let footnote {
                Text(footnote)
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }
}

struct SettingsPage<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }
}

struct SettingsHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(AppFont.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Small helpers

/// A small external link with an explicit brand color. `Link` otherwise uses
/// the system accent, which ignores our tint on macOS.
struct BrandLink: View {
    let title: String
    let destination: URL
    var color: Color = Brand.purpleText
    var font: Font = AppFont.secondary

    var body: some View {
        Link(destination: destination) {
            Text(title)
                .font(font)
                .foregroundStyle(color)
        }
        .buttonStyle(.plain)
    }
}

/// A compact purple switch. Native `Toggle` switches follow the system accent
/// and are not reliably captured off-screen, which left the Settings pane
/// showing the wrong state in docs.
struct BrandSwitch: View {
    @Binding var isOn: Bool
    var accessibilityText: String

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.14)) {
                isOn.toggle()
            }
        } label: {
            Capsule()
                .fill(isOn ? Brand.purple : Color.primary.opacity(0.16))
                .frame(width: 36, height: 21)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .frame(width: 17, height: 17)
                        .padding(2)
                        .shadow(color: .black.opacity(0.20), radius: 1.5, y: 0.5)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// The primary action. SwiftUI's `.borderedProminent` follows the system accent
/// and renders gray whenever the window is not key; this keeps the Finder7
/// purple and white at all times, including screenshots and inactive windows.
struct BrandProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BrandProminentBody(configuration: configuration)
    }

    private struct BrandProminentBody: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isEnabled ? Color.white : Color.secondary)
                .padding(.horizontal, 15)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                        .fill(isEnabled ? Brand.purple : Color.primary.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                        .strokeBorder(
                            isEnabled ? Color.white.opacity(0.14) : Color.clear,
                            lineWidth: 0.75
                        )
                )
                .opacity(configuration.isPressed ? 0.82 : 1)
                .contentShape(Rectangle())
        }
    }
}

/// A purple text button. The native `.link` style always uses the system
/// accent, which is blue (or graphite), so Finder7 draws its own.
struct BrandLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BrandLinkBody(configuration: configuration)
    }

    private struct BrandLinkBody: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .foregroundStyle(isEnabled ? Brand.purpleText : Color.secondary.opacity(0.55))
                .opacity(configuration.isPressed ? 0.55 : 1)
                .contentShape(Rectangle())
        }
    }
}

extension View {
    /// A purple link-style button that stays readable in both appearances.
    func brandLink() -> some View {
        buttonStyle(BrandLinkButtonStyle())
    }

    func brandProminent() -> some View {
        buttonStyle(BrandProminentButtonStyle())
    }

}
