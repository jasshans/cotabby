import AppKit
import CoreText
import SwiftUI

/// File overview:
/// The small Ghostype mark shown just left of the line Ghostype is completing. The style is the
/// user's choice in Settings > Appearance (`FieldIndicatorStyle`). There is no background chip:
/// the mark draws in the label colour with a halo of the window background colour, which keeps it
/// readable on light and dark fields alike.
struct FieldEdgeIconIndicatorView: View {
    var style: FieldIndicatorStyle = .defaultStyle

    var body: some View {
        mark
            .foregroundStyle(.primary)
            .shadow(color: Color(nsColor: .windowBackgroundColor), radius: 0.6)
            .shadow(color: Color(nsColor: .windowBackgroundColor).opacity(0.8), radius: 1.2)
            .padding(2)
            .fixedSize()
            .accessibilityLabel("Ghostype")
    }

    @ViewBuilder private var mark: some View {
        switch style {
        case .letterAndCursor:
            // The "a" sits on the bottom of the I-beam: its baseline aligns with the beam's foot.
            HStack(alignment: .bottom, spacing: 1) {
                Text("a")
                    .font(UncialAntiquaFont.font(size: 11))
                    .alignmentGuide(.bottom) { dimensions in dimensions[.firstTextBaseline] }
                IBeamGlyph()
                    .stroke(lineWidth: 1)
                    .frame(width: 5, height: 11)
            }
        case .cursor:
            IBeamGlyph()
                .stroke(lineWidth: 1)
                .frame(width: 6, height: 12)
        case .ghost:
            GhostGlyph()
                .fill(style: FillStyle(eoFill: true))
                .frame(width: 10, height: 12)
        case .none:
            EmptyView()
        }
    }
}

/// Outlined I-beam text cursor: a thin stem with flared serif caps at top and bottom.
struct IBeamGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let width = rect.width
        let height = rect.height
        let stem = width * 0.34
        let cap = height * 0.14
        let midX = rect.midX
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + cap))
        path.addLine(to: CGPoint(x: midX + stem / 2, y: rect.minY + cap * 1.6))
        path.addLine(to: CGPoint(x: midX + stem / 2, y: rect.maxY - cap * 1.6))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - cap))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - cap))
        path.addLine(to: CGPoint(x: midX - stem / 2, y: rect.maxY - cap * 1.6))
        path.addLine(to: CGPoint(x: midX - stem / 2, y: rect.minY + cap * 1.6))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + cap))
        path.closeSubpath()
        return path
    }
}

/// Registers the bundled uncial face once per process and vends it for the indicator.
/// `GhostypeUncial-Regular.ttf` is Uncial Antiqua (c) 2011 Brian J. Bonislawsky DBA Astigmatic,
/// SIL Open Font License 1.1, subset to the letters a/A and renamed per the OFL's Reserved Font
/// Name clause; the full licence text is embedded in the font's name table.
enum UncialAntiquaFont {
    static let postScriptName = "GhostypeUncial-Regular"

    private static let isRegistered: Bool = {
        let bundle = Bundle.main
        guard let url = bundle.url(forResource: postScriptName, withExtension: "ttf")
            ?? bundle.url(forResource: postScriptName, withExtension: "ttf", subdirectory: "Fonts")
            ?? bundle.url(forResource: postScriptName, withExtension: "ttf", subdirectory: "Resources/Fonts")
        else {
            return false
        }
        if NSFont(name: postScriptName, size: 10) == nil {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        return NSFont(name: postScriptName, size: 10) != nil
    }()

    static func font(size: CGFloat) -> Font {
        if isRegistered {
            return .custom(postScriptName, fixedSize: size)
        }
        return .system(size: size, weight: .semibold, design: .serif)
    }
}
