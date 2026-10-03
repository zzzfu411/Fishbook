import AppKit
import PDFKit

/// A display preference, independent of the surrounding application's appearance.
enum PDFColorPreset: String, CaseIterable, Identifiable {
    case original, sepia, green, blue, gray, night

    static let preferenceKey = "ReaderPDFColor"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return "原色"
        case .sepia: return "米黄"
        case .green: return "豆绿"
        case .blue: return "雾蓝"
        case .gray: return "暖灰"
        case .night: return "夜读"
        }
    }

    var paperColor: NSColor { Self.color(paperRGB) }
    var inkColor: NSColor { Self.color(inkRGB) }
    var canvasColor: NSColor {
        let factor: CGFloat = self == .night ? 0.74 : 0.91
        return NSColor(srgbRed: paperRGB[0] * factor,
                       green: paperRGB[1] * factor,
                       blue: paperRGB[2] * factor, alpha: 1)
    }

    fileprivate var paperRGB: [CGFloat] {
        switch self {
        case .original: return Self.rgb(255, 255, 255)
        case .sepia: return Self.rgb(245, 235, 215)
        case .green: return Self.rgb(227, 237, 223)
        case .blue: return Self.rgb(228, 236, 243)
        case .gray: return Self.rgb(232, 230, 225)
        case .night: return Self.rgb(36, 42, 49)
        }
    }

    fileprivate var inkRGB: [CGFloat] {
        switch self {
        case .original: return Self.rgb(0, 0, 0)
        case .sepia: return Self.rgb(49, 42, 32)
        case .green: return Self.rgb(40, 52, 42)
        case .blue: return Self.rgb(36, 49, 61)
        case .gray: return Self.rgb(48, 47, 44)
        case .night: return Self.rgb(220, 225, 230)
        }
    }

    private static func rgb(_ red: Int, _ green: Int, _ blue: Int) -> [CGFloat] {
        [CGFloat(red) / 255, CGFloat(green) / 255, CGFloat(blue) / 255]
    }

    private static func color(_ rgb: [CGFloat]) -> NSColor {
        NSColor(srgbRed: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1)
    }
}

enum PDFColorRenderer {
    /// PDFView's draw-page hook uses the displayed page's zero-based coordinates.
    /// PDFPage.draw applies the crop offset and rotation to the source content.
    static func drawingBounds(for page: PDFPage, box: PDFDisplayBox) -> CGRect {
        let source = page.bounds(for: box)
        let rotation = ((page.rotation % 360) + 360) % 360
        let size = rotation == 90 || rotation == 270
            ? CGSize(width: source.height, height: source.width)
            : source.size
        return CGRect(origin: .zero, size: size)
    }

    /// Wrap PDFView's native page drawing inside its existing page/tile context.
    /// The original PDF, text layer, geometry, and annotation objects are untouched.
    /// Color figures are mapped too; `.original` bypasses the mapping entirely.
    static func draw(preset: PDFColorPreset, in context: CGContext,
                     bounds: CGRect, drawOriginal: () -> Void) {
        guard preset != .original, !bounds.isEmpty, !bounds.isInfinite, !bounds.isNull else {
            drawOriginal()
            return
        }

        // Respect PDFKit's tile clip. There is no document-wide bitmap or image cache.
        let region = bounds.intersection(context.boundingBoxOfClipPath)
        guard !region.isEmpty, !region.isNull else { return }
        let paper = preset.paperRGB, ink = preset.inkRGB
        let inverted = preset == .night
        let low = inverted ? paper : ink
        let high = inverted ? ink : paper
        let multiplier = zip(low, high).map { ($1 - $0) / (1 - $0) }

        context.saveGState()
        context.clip(to: region)
        context.beginTransparencyLayer(in: region, auxiliaryInfo: nil)
        context.setBlendMode(.normal)
        context.setAlpha(1)
        context.setFillColor(rgb: [1, 1, 1])
        context.fill(region)
        drawOriginal()

        if inverted {
            context.setBlendMode(.difference)
            context.setFillColor(rgb: [1, 1, 1])
            context.fill(region)
        }
        // Multiplication followed by screen gives low + (high - low) * source.
        // For night reading, the initial inversion swaps the white/black endpoints.
        context.setBlendMode(.multiply)
        context.setFillColor(rgb: multiplier)
        context.fill(region)
        context.setBlendMode(.screen)
        context.setFillColor(rgb: low)
        context.fill(region)
        context.endTransparencyLayer()
        context.restoreGState()
    }

    /// Discard PDFKit's old display tiles by rebinding the very same document.
    /// Returns true when a document was refreshed. Selection, highlights, zoom, and
    /// the native destination are restored synchronously before returning. PDFKit
    /// can still perform later layout; the caller should retain its precise reading
    /// anchor across that layout and suppress intermediate progress saves.
    @MainActor @discardableResult
    static func refresh(_ view: PDFView) -> Bool {
        guard let document = view.document else { return false }
        let destination = view.currentDestination.flatMap { current -> PDFDestination? in
            guard let page = current.page else { return nil }
            return PDFDestination(page: page, at: current.point)
        }
        let selection = view.currentSelection
        let highlights = view.highlightedSelections
        let scale = view.scaleFactor
        let autoScales = view.autoScales

        view.document = nil
        view.document = document
        view.autoScales = false
        if scale.isFinite, scale > 0 { view.scaleFactor = scale }
        view.layoutSubtreeIfNeeded()
        if let destination { view.go(to: destination) }
        // A destination can carry the old zoom and disable automatic fitting.
        // Restore the fitting policy last, after navigation has applied its zoom.
        if autoScales {
            view.autoScales = true
        } else {
            view.autoScales = false
            if scale.isFinite, scale > 0 { view.scaleFactor = scale }
        }
        view.layoutSubtreeIfNeeded()
        view.highlightedSelections = highlights
        view.setCurrentSelection(selection, animate: false)
        view.needsDisplay = true
        return true
    }
}

private extension CGContext {
    func setFillColor(rgb: [CGFloat]) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        setFillColor(CGColor(colorSpace: space, components: rgb + [1])!)
    }
}
