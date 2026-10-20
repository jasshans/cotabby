import AppKit
import XCTest
@testable import Ghostype

/// Containment harness: for many box widths, caret positions and suggestions, every ghost row
/// must start inside the text box and its visible glyphs must end at or before the box's right
/// edge. Text that does not fit wraps to the next line (or is cut short), never past the box.
final class GhostTextContainmentHarnessTests: XCTestCase {
    private let fonts: [NSFont] = [
        NSFont.systemFont(ofSize: 13),
        NSFont.systemFont(ofSize: 17),
        NSFont(name: "Menlo-Regular", size: 14)!,
    ]
    private let suggestions = [
        " and then we can meet tomorrow afternoon",
        " supercalifragilisticexpialidocious words here",
        " ok",
        " the quick brown fox jumps over the lazy dog again and again",
    ]
    private let tolerance: CGFloat = 0.5

    private func visibleWidth(_ text: String, font: NSFont) -> CGFloat {
        let trimmed = text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        return (trimmed as NSString).size(withAttributes: [.font: font]).width
    }

    func testEveryRowStaysInsideTheBox() {
        for font in fonts {
            for boxWidth in stride(from: CGFloat(120), through: 600, by: 37) {
                let band: ClosedRange<CGFloat> = 100...(100 + boxWidth)
                for caretFraction in [0.0, 0.3, 0.7, 0.95, 1.0] {
                    let caretX = band.lowerBound + (band.upperBound - band.lowerBound) * caretFraction
                    for allowsMultipleRows in [true, false] {
                        for text in suggestions {
                            let input = GhostTextLayout.Input(
                                fullText: text,
                                consumedUTF16: 0,
                                font: font,
                                anchorTopLeft: CGPoint(x: caretX, y: 500),
                                boxHeight: 18,
                                baselineOffsetFromTop: 14,
                                linePitch: 20,
                                wrapBand: band,
                                allowsMultipleRows: allowsMultipleRows,
                                keycapWidth: 0
                            )
                            guard let layout = GhostTextLayout.make(input) else { continue }
                            for row in layout.rows where !row.text.isEmpty {
                                let context = "font=\(font.fontName) box=\(boxWidth) caret=\(caretX) multi=\(allowsMultipleRows) text=\(text) row=\(row.text)"
                                XCTAssertGreaterThanOrEqual(row.penX, band.lowerBound - tolerance, context)
                                XCTAssertLessThanOrEqual(
                                    row.penX + visibleWidth(row.text, font: font),
                                    band.upperBound + tolerance,
                                    context
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}
