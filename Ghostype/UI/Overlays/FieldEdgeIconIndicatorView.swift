import AppKit
import CoreText
import SwiftUI

/// File overview:
/// The small Ghostype affordance shown just outside a supported text field: an uncial "a"
/// beside an outlined text-cursor (I-beam) glyph on Ghostype's dark rounded chip.
struct FieldEdgeIconIndicatorView: View {
    private let width: CGFloat = 20
    private let height: CGFloat = 14
    private let cornerRadius: CGFloat = 3.5

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(red: 0.18, green: 0.19, blue: 0.21))
            HStack(alignment: .center, spacing: 1) {
                Text("a")
                    .font(UncialAntiquaFont.font(size: 10))
                    .foregroundStyle(.white)
                    .baselineOffset(1)
                IBeamGlyph()
                    .fill(Color(red: 0.18, green: 0.19, blue: 0.21))
                    .overlay(IBeamGlyph().stroke(Color.white, lineWidth: 0.9))
                    .frame(width: 5, height: 10)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
        .fixedSize()
        .accessibilityLabel("Ghostype")
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
