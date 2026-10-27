import AppKit
import SwiftUI

/// File overview:
/// Ghostype's ghost, drawn as a shape so one outline serves both the field indicator (SwiftUI)
/// and the menu bar (a template `NSImage`, which macOS tints for light and dark menu bars).
/// Fill it with the even-odd rule: the eyes are subpaths that cut holes in the body.
struct GhostGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = rect.width / 2
        let domeCenter = CGPoint(x: rect.midX, y: rect.minY + radius)
        let hem = rect.maxY
        path.move(to: CGPoint(x: rect.minX, y: hem))
        path.addLine(to: CGPoint(x: rect.minX, y: domeCenter.y))
        // In SwiftUI's y-down space, counter-clockwise from 180° to 0° passes over the top.
        path.addArc(center: domeCenter, radius: radius, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: hem))
        // Three tails along the hem, right to left; the curve rises between their points.
        let step = rect.width / 3
        let rise = rect.height * 0.26
        for index in 1...3 {
            let endX = rect.maxX - step * CGFloat(index)
            path.addQuadCurve(to: CGPoint(x: endX, y: hem), control: CGPoint(x: endX + step / 2, y: hem - rise))
        }
        path.closeSubpath()
        let eye = CGSize(width: rect.width * 0.17, height: rect.height * 0.2)
        let eyeTop = rect.minY + rect.height * 0.32
        for offset in [-0.19, 0.19] {
            let center = rect.midX + rect.width * offset
            path.addEllipse(in: CGRect(x: center - eye.width / 2, y: eyeTop, width: eye.width, height: eye.height))
        }
        return path
    }
}

/// The ghost menu bar icons, built once. 18 points square to match the pumpkin asset's canvas.
enum GhostMenuBarImage {
    static let ghost = make(winter: false)
    static let winterGhost = make(winter: true)

    private static func make(winter: Bool) -> NSImage {
        // `flipped: true` gives the drawing handler SwiftUI's y-down space, so the shape's path
        // can be used as is.
        let image = NSImage(size: CGSize(width: 18, height: 18), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let body = winter
                ? CGRect(x: 3.5, y: 4.5, width: 11, height: 12.5)
                : CGRect(x: 3.5, y: 2, width: 11, height: 14.5)
            context.addPath(GhostGlyph().path(in: body).cgPath)
            context.fillPath(using: .evenOdd)
            if winter {
                // A beanie: the top of the dome, split from the face by a cleared line, with a
                // pom-pom. A template image is a single-colour mask, so the gap draws the brim.
                context.setBlendMode(.clear)
                context.fill(CGRect(x: body.minX, y: body.minY + body.height * 0.2, width: body.width, height: 1))
                context.setBlendMode(.normal)
                context.fillEllipse(in: CGRect(x: body.midX - 2, y: body.minY - 3.5, width: 4, height: 4))
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
