import Foundation

/// What a PDF export should look like.
///
/// Pure and in the core so the settings can be round-tripped and tested
/// without a print system. The one that matters is `scalePercent`: everything
/// else is paper handling.
public struct PDFExportOptions: Equatable, Sendable, Codable {

    public enum Paper: String, CaseIterable, Sendable, Identifiable, Codable {
        case a4, letter, legal, tabloid
        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .a4: "A4"
            case .letter: "US Letter"
            case .legal: "US Legal"
            case .tabloid: "Tabloid"
            }
        }

        /// Portrait size in points, at the 72dpi the print system works in.
        public var size: (width: Double, height: Double) {
            switch self {
            case .a4: (595, 842)
            case .letter: (612, 792)
            case .legal: (612, 1008)
            case .tabloid: (792, 1224)
            }
        }
    }

    public enum Margin: String, CaseIterable, Sendable, Identifiable, Codable {
        case narrow, normal, wide
        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .narrow: "Narrow"
            case .normal: "Normal"
            case .wide: "Wide"
            }
        }

        /// White space from the paper's edge to the text, in points.
        ///
        /// Nothing below 28pt is offered, because the text view imposes a
        /// 28pt gutter of its own that no print margin can take back.
        public var points: Double {
            switch self {
            case .narrow: 28
            case .normal: 56
            case .wide: 84
            }
        }
    }

    public var paper: Paper
    public var isLandscape: Bool
    public var margin: Margin
    /// The size body text is printed at, in points.
    ///
    /// Absolute, not a percentage of what the editor shows. A point is 1/72
    /// inch and the print system works in them, so 12pt here is 12pt on A4 on
    /// any Mac — no display, resolution or scale factor enters into it. Said
    /// as a percentage it was the same number, but it read as though it might
    /// depend on the screen, and it would have quietly changed meaning the day
    /// the editor gained a font-size setting.
    ///
    /// Everything else on the page scales with it: headings, code, tables,
    /// formulae and line spacing keep their relationship to the body.
    ///
    /// The default is **12**, against an editor that draws body text at 15.
    /// The editor's size is chosen to be read on a display at arm's length and
    /// is too big for A4 — a book sets its body around 10pt. At 15 the same
    /// note ran to four pages where Obsidian took three.
    public var bodyPointSize: Double
    /// Whether to put the note's filename at the top as a heading.
    public var includesTitle: Bool

    public static let bodySizeRange: ClosedRange<Double> = 7...20

    public init(
        paper: Paper = .a4,
        isLandscape: Bool = false,
        margin: Margin = .normal,
        bodyPointSize: Double = 12,
        includesTitle: Bool = false
    ) {
        self.paper = paper
        self.isLandscape = isLandscape
        self.margin = margin
        self.bodyPointSize = bodyPointSize.clamped(to: Self.bodySizeRange)
        self.includesTitle = includesTitle
    }

    /// How much the laid-out view has to shrink to put body text on paper at
    /// `bodyPointSize`, given the size the editor draws it at.
    ///
    /// Taking the editor's size as a *parameter* rather than a constant is
    /// what keeps the printed size honest: change what the editor draws, or
    /// let someone set it, and 12pt on paper is still 12pt.
    public func scale(forEditorBodySize editorBodySize: Double) -> Double {
        guard editorBodySize > 0 else { return 1 }
        return bodyPointSize / editorBodySize
    }

    /// The paper's size with the orientation applied.
    public var paperSize: (width: Double, height: Double) {
        let size = paper.size
        return isLandscape ? (size.height, size.width) : size
    }
}

extension Double {
    fileprivate func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

extension PDFExportOptions {
    /// Round-tripped through JSON rather than a hand-written dictionary, so a
    /// field added later cannot be forgotten in one direction and silently
    /// stop being remembered.
    public var encoded: Data? { try? JSONEncoder().encode(self) }

    /// Decodes, falling back to the defaults for anything missing or corrupt:
    /// a settings file from an older version must not stop the export working.
    public init(decoding data: Data?) {
        guard let data else { self = PDFExportOptions(); return }
        guard let decoded = try? JSONDecoder().decode(Self.self, from: data) else {
            // A settings file written while this was still a percentage of the
            // editor's size. Converted rather than discarded, so nobody's
            // choice is silently thrown away by the rename.
            if let legacy = try? JSONDecoder().decode(LegacyScale.self, from: data) {
                self = PDFExportOptions(
                    paper: legacy.paper,
                    isLandscape: legacy.isLandscape,
                    margin: legacy.margin,
                    bodyPointSize: legacy.scalePercent / 100 * LegacyScale.editorBodySize,
                    includesTitle: legacy.includesTitle
                )
                return
            }
            self = PDFExportOptions()
            return
        }
        // Re-run through the initialiser so a hand-edited or stale file cannot
        // put an out-of-range scale into the print system.
        self = PDFExportOptions(
            paper: decoded.paper,
            isLandscape: decoded.isLandscape,
            margin: decoded.margin,
            bodyPointSize: decoded.bodyPointSize,
            includesTitle: decoded.includesTitle
        )
    }

    /// The shape settings were stored in before the size became absolute.
    private struct LegacyScale: Decodable {
        /// What the editor drew body text at when this format was written.
        static let editorBodySize: Double = 15

        let paper: Paper
        let isLandscape: Bool
        let margin: Margin
        let scalePercent: Double
        let includesTitle: Bool
    }
}
