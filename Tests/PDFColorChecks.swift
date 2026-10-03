import Foundation
import AppKit
import PDFKit
import CoreText
import CoreImage
import CryptoKit
import SwiftUI

/// A local, synthetic paper lets the color checks distinguish rendered pixels
/// from searchable content and from bytes saved on disk.
private enum ColorFixture {
    static let size = CGSize(width: 600, height: 800)
    static let phrase = "Fishbook searchable color fixture"
    static let swatches: [CGColor] = [
        CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1),
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1),
        CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1),
        CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1),
        CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
    ]
    static func write(to url: URL, title: String = phrase) {
        var bounds = CGRect(origin: .zero, size: size)
        let context = CGContext(url as CFURL, mediaBox: &bounds, nil)!
        let font = CTFontCreateWithName("Helvetica" as CFString, 19, nil)
        for index in 1...3 {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(bounds)
            for (column, color) in swatches.enumerated() {
                context.setFillColor(color)
                context.fill(CGRect(x: 30 + column * 90, y: 560, width: 70, height: 70))
            }
            let text = NSAttributedString(string: "\(title) — page \(index)", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
            ])
            context.textPosition = CGPoint(x: 30, y: 700)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
            context.endPDFPage()
        }
        context.closePDF()
    }
    static func hash(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
    static func render(_ page: PDFPage) -> CGImage {
        let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                bitsPerComponent: 8, bytesPerRow: Int(size.width) * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()!
    }
    static func rgba(_ color: NSColor) -> [Double] {
        let rgb = color.usingColorSpace(.sRGB)!
        return [Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent), Double(rgb.alphaComponent)]
    }
    static func luminance(_ color: [Double]) -> Double {
        func linear(_ channel: Double) -> Double { channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(color[0]) + 0.7152 * linear(color[1]) + 0.0722 * linear(color[2])
    }
    static func contrast(_ first: [Double], _ second: [Double]) -> Double {
        let a = luminance(first), b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
    static func near(_ first: [Double], _ second: [Double], tolerance: Double = 0.03) -> Bool {
        zip(first.prefix(3), second.prefix(3)).allSatisfy { abs($0 - $1) <= tolerance }
    }
    static func pixel(_ image: CGImage, x: Int, y: Int) -> [Double] {
        // These contexts explicitly produce sRGB RGBA8. NSBitmapImageRep's
        // colorAt returns calibrated RGB, which would apply a second conversion.
        pixel(image.dataProvider!.data! as Data, stride: image.bytesPerRow, x: x, y: y)
    }
    static func pixel(_ bytes: Data, stride: Int, x: Int, y: Int) -> [Double] {
        let offset = y * stride + x * 4
        return (0..<4).map { Double(bytes[offset + $0]) / 255 }
    }
    @MainActor static func render(_ page: PDFPage, preset: PDFColorPreset) -> CGImage {
        let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                bitsPerComponent: 8, bytesPerRow: Int(size.width) * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        PDFColorRenderer.draw(preset: preset, in: context, bounds: page.bounds(for: .mediaBox)) {
            page.draw(with: .mediaBox, to: context)
        }
        return context.makeImage()!
    }
    @MainActor static func renderNative(_ page: PDFPage, preset: PDFColorPreset) -> CGImage {
        let view = StudyPDFView()
        view.displayBox = .cropBox
        view.colorPreset = preset
        let context = CGContext(data: nil, width: 1024, height: 1024,
                                bitsPerComponent: 8, bytesPerRow: 4096,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        context.translateBy(x: 80, y: 80)
        view.draw(page, to: context)
        return context.makeImage()!
    }
}

@main struct PDFColorChecks {
    @MainActor private static func wait(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<120 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        fatalError("Timed out: " + message)
    }
    private static func samePassage(_ first: ReadingPosition?, _ second: ReadingPosition) -> Bool {
        guard let first else { return false }
        return first.page == second.page && abs(first.x - second.x) < 3 && abs(first.y - second.y) < 3
    }
    @MainActor private static func verifyPreference() {
        let suite = "com.fishbook.color-check." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preference = AppStorage(wrappedValue: PDFColorPreset.original.rawValue, "ReaderPDFColor", store: defaults)
        precondition(preference.wrappedValue == PDFColorPreset.original.rawValue,
                     "a fresh preference domain must begin with the original paper")
        for preset in PDFColorPreset.allCases {
            preference.wrappedValue = preset.rawValue
            defaults.synchronize()
            let reopened = UserDefaults(suiteName: suite)!
            let reloaded = AppStorage(wrappedValue: PDFColorPreset.original.rawValue, "ReaderPDFColor", store: reopened)
            precondition(PDFColorPreset(rawValue: reloaded.wrappedValue) == preset,
                         "each stored color ID must reopen as the same palette")
        }
        precondition(PDFColorPreset(rawValue: "removed-or-unknown-preset") == nil,
                     "unrecognized preference values can fall back to original without guessing")
    }
    @MainActor private static func verifyPixels(_ page: PDFPage) {
        let original = ColorFixture.render(page)
        let untouched = ColorFixture.render(page, preset: .original)
        precondition(original.dataProvider!.data! as Data == untouched.dataProvider!.data! as Data,
                     "original mode must bypass recoloring byte-for-byte")
        var paperPixels = Set<String>()
        for preset in PDFColorPreset.allCases {
            let rendered = ColorFixture.render(page, preset: preset)
            let pixels = (0..<6).map { ColorFixture.pixel(rendered, x: 65 + $0 * 90, y: 205) }
            precondition(ColorFixture.near(pixels[0], ColorFixture.rgba(preset.inkColor)),
                         "\(preset.title) maps actual black PDF pixels to its reading ink")
            precondition(ColorFixture.near(pixels[1], ColorFixture.rgba(preset.paperColor)),
                         "\(preset.title) maps actual white PDF pixels to its paper color")
            precondition(ColorFixture.contrast(pixels[0], pixels[1]) >= 7,
                         "actual rendered text retains strong contrast, not just palette constants")
            let luma = pixels.map(ColorFixture.luminance)
            precondition(luma[5] > min(luma[0], luma[1]) && luma[5] < max(luma[0], luma[1]),
                         "gray antialiased text retains a tone between ink and paper")
            for first in 2...4 {
                for second in (first + 1)..<5 {
                    precondition(!ColorFixture.near(pixels[first], pixels[second], tolerance: 0.1),
                                 "colored plot series remain distinguishable after recoloring")
                }
            }
            paperPixels.insert(pixels[1].map { String(format: "%.3f", $0) }.joined(separator: ","))
            let restored = ColorFixture.render(page, preset: .original)
            precondition(original.dataProvider!.data! as Data == restored.dataProvider!.data! as Data,
                         "returning to original restores every figure and text pixel")
        }
        precondition(paperPixels.count == PDFColorPreset.allCases.count, "each named theme must produce a distinct visible paper color")

        // Exercise the same PDFView hook as the application with shifted crop
        // boxes and PDF rotation metadata; compare the region PDFKit drew.
        for rotation in [0, 90, 180, 270] {
            let rotated = page.copy() as! PDFPage
            let crop = CGRect(x: 20, y: 35, width: 540, height: 700)
            rotated.setBounds(crop, for: .cropBox)
            rotated.rotation = rotation
            let plain = ColorFixture.renderNative(rotated, preset: .original)
            let themed = ColorFixture.renderNative(rotated, preset: .sepia)
            let plainBytes = plain.dataProvider!.data! as Data
            let themedBytes = themed.dataProvider!.data! as Data
            var paperSamples = 0, outsideSamples = 0
            for y in stride(from: 4, to: 1024, by: 11) {
                for x in stride(from: 4, to: 1024, by: 11) {
                    let before = ColorFixture.pixel(plainBytes, stride: plain.bytesPerRow, x: x, y: y)
                    let after = ColorFixture.pixel(themedBytes, stride: themed.bytesPerRow, x: x, y: y)
                    if ColorFixture.near(before, [1, 1, 1], tolerance: 0.002) {
                        paperSamples += 1
                        precondition(ColorFixture.near(after, ColorFixture.rgba(PDFColorPreset.sepia.paperColor)),
                                     "shifted crop and \(rotation)° page rotation cannot leave an uncolored strip")
                    } else if ColorFixture.near(before, [1, 0, 1], tolerance: 0.002) {
                        outsideSamples += 1
                        if !ColorFixture.near(after, before, tolerance: 0.002) {
                            print("crop draw mismatch rotation=\(rotation) pixel=\(x),\(y) before=\(before) after=\(after) crop=\(crop)")
                        }
                        precondition(ColorFixture.near(after, before, tolerance: 0.002),
                                     "recoloring must not paint outside the PDF page/tile")
                    }
                }
            }
            precondition(paperSamples > 100 && outsideSamples > 100)
            precondition(rotated.rotation == rotation && rotated.bounds(for: .cropBox) == crop,
                         "display tint cannot alter PDF rotation or crop geometry")
        }
        print("actual PDF pixels, original color restoration, chart distinction, shifted crop and all right-angle rotations verified")
    }
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fishbook-pdf-colors-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("content"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try JSONEncoder().encode(Catalog(papers: [], guides: []))
            .write(to: root.appendingPathComponent("content/library.json"))
        let source = root.appendingPathComponent("color-fixture.pdf")
        ColorFixture.write(to: source)
        let originalHash = try ColorFixture.hash(source)
        let store = StudyStore(resourceDirectory: root, dataDirectory: root.appendingPathComponent("records"))
        precondition(store.ready)
        store.importPDF([source])
        guard let paper = store.paper else { fatalError("synthetic paper was not imported") }
        precondition(paper.pages == 3 && paper.sha256 == originalHash)
        let importedURL = store.fileURL(paper)
        let controller = PDFController()
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 700, height: 780),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 780))
        window.contentView = host
        controller.view.frame = host.bounds
        host.addSubview(controller.view)
        controller.load(paper, store: store)
        try await wait("synthetic PDF loaded") { controller.view.document?.pageCount == 3 }
        try await Task.sleep(nanoseconds: 100_000_000)
        let document = controller.view.document!
        let pages = (0..<document.pageCount).map { document.page(at: $0)! }
        verifyPixels(pages[0])
        let searchableText = document.string
        precondition(document.findString(ColorFixture.phrase, withOptions: []).count == 3,
                     "the fixture has real searchable text on every page")
        controller.goPage(2)
        let selection = document.findString(ColorFixture.phrase, withOptions: [])[1]
        controller.view.setCurrentSelection(selection, animate: false)
        controller.view.highlightedSelections = [selection]
        let hiddenAnnotation = PDFAnnotation(bounds: CGRect(x: 25, y: 25, width: 40, height: 20), forType: .text, withProperties: nil)
        hiddenAnnotation.shouldDisplay = false
        pages[0].addAnnotation(hiddenAnnotation)
        pages[2].displaysAnnotations = false
        controller.view.go(to: PDFDestination(page: pages[1], at: CGPoint(x: 0, y: 760)))
        controller.flush()
        let position = store.readingPosition(for: paper.id)!
        let initialPageNumber = controller.pageNumber
        let initialScale = controller.view.scaleFactor
        let initialAutoScales = controller.view.autoScales
        let selectionText = selection.string
        let selectionBounds = selection.bounds(for: pages[1])
        let historyBefore = (controller.canBack, controller.canForward)
        precondition(position.page == 1 && !selectionBounds.isEmpty)

        precondition(Set(PDFColorPreset.allCases.map(\.rawValue)).count == PDFColorPreset.allCases.count)
        precondition(Set(PDFColorPreset.allCases.map(\.title)).count == PDFColorPreset.allCases.count)
        precondition(PDFColorPreset.allCases.count >= 6, "all requested reading colors must be available")
        for preset in PDFColorPreset.allCases {
            let ink = ColorFixture.rgba(preset.inkColor), paperColor = ColorFixture.rgba(preset.paperColor)
            precondition((ink + paperColor).allSatisfy { $0.isFinite && (0...1).contains($0) })
            precondition(ColorFixture.contrast(ink, paperColor) >= 7,
                         "\(preset.title) must retain strong text/paper contrast")
            controller.setColorPreset(preset)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 100_000_000)
            controller.flush()
            precondition(controller.view.document === document && document.pageCount == 3 && document.string == searchableText,
                         "changing reading colors is presentation-only, not document replacement")
            for (index, page) in pages.enumerated() {
                precondition(document.page(at: index) === page, "the same page objects retain source anchors")
            }
            precondition(document.findString(ColorFixture.phrase, withOptions: []).count == 3)
            precondition(controller.view.currentSelection?.string == selectionText &&
                         controller.view.currentSelection?.bounds(for: pages[1]) == selectionBounds,
                         "a color change cannot discard or move the current text selection")
            precondition(controller.view.highlightedSelections?.count == 1 &&
                         controller.view.highlightedSelections?.first?.string == selectionText,
                         "existing search highlights survive a page tile refresh")
            precondition(!pages[2].displaysAnnotations && !hiddenAnnotation.shouldDisplay &&
                         pages[0].annotations.contains(where: { $0 === hiddenAnnotation }),
                         "color refresh cannot expose annotations that the PDF keeps hidden")
            if controller.pageNumber != initialPageNumber || !samePassage(store.readingPosition(for: paper.id), position) {
                print("position mismatch \(preset.title): page \(controller.pageNumber)/\(initialPageNumber), actual \(String(describing: store.readingPosition(for: paper.id))) expected \(position), auto \(controller.view.autoScales)")
            }
            precondition(controller.pageNumber == initialPageNumber && samePassage(store.readingPosition(for: paper.id), position),
                         "a color change must preserve page number and the in-page reading coordinate")
            precondition(abs(controller.view.scaleFactor - initialScale) < 0.001 &&
                         controller.canBack == historyBefore.0 && controller.canForward == historyBefore.1,
                         "color controls must not change zoom or inject navigation history")
            precondition(controller.view.autoScales == initialAutoScales,
                         "refreshing PDF tiles must not silently disable automatic fit")
            let remainingSourceHash = try ColorFixture.hash(source)
            let remainingImportedHash = try ColorFixture.hash(importedURL)
            precondition(remainingSourceHash == originalHash && remainingImportedHash == originalHash,
                         "neither the source PDF nor its imported copy may be rewritten")
            controller.setColorPreset(.original)
        }
        print("all palette switches preserve searchable text, page identity, selection, position, zoom, history and source bytes")

        func resize(_ width: CGFloat, _ height: CGFloat) {
            controller.preservePositionForLayoutChange()
            window.setContentSize(NSSize(width: width, height: height))
            host.frame = CGRect(x: 0, y: 0, width: width, height: height)
            controller.view.frame = host.bounds
            host.layoutSubtreeIfNeeded()
        }
        controller.view.autoScales = true
        resize(1200, 900)
        try await Task.sleep(nanoseconds: 180_000_000)
        let wideScale = controller.view.scaleFactor
        controller.setColorPreset(.sepia)
        try await Task.sleep(nanoseconds: 180_000_000)
        precondition(controller.view.autoScales)
        resize(430, 600)
        try await Task.sleep(nanoseconds: 180_000_000)
        precondition(controller.view.autoScales && controller.view.scaleFactor < wideScale * 0.85,
                     "a recolored fullscreen PDF must fit its narrower pane after returning to split view")
        controller.view.autoScales = false
        controller.view.scaleFactor = 1.2
        controller.setColorPreset(.night)
        try await Task.sleep(nanoseconds: 180_000_000)
        precondition(!controller.view.autoScales && abs(controller.view.scaleFactor - 1.2) < 0.001,
                     "a user's deliberate manual zoom survives theme changes too")
        controller.view.autoScales = true
        print("automatic fit survives wide-to-narrow layout; explicit manual zoom survives recoloring")

        controller.find(ColorFixture.phrase)
        controller.nextMatch()
        precondition(controller.searchResult == "2/3")
        controller.setColorPreset(.green)
        try await Task.sleep(nanoseconds: 160_000_000)
        precondition(controller.searchResult == "2/3" && controller.matchCount == 3)
        controller.nextMatch()
        precondition(controller.searchResult == "3/3" && controller.view.currentSelection?.string == ColorFixture.phrase,
                     "next search match continues the existing query after recoloring")
        controller.setColorPreset(.blue)
        try await Task.sleep(nanoseconds: 160_000_000)
        guard let scroll = controller.view.documentView?.enclosingScrollView else { fatalError("PDF scroll view unavailable") }
        let clip = scroll.contentView
        precondition(clip.postsBoundsChangedNotifications, "the replacement PDF scroll view must keep reporting reading movement")
        let beforeScroll = store.readingPosition(for: paper.id)!
        let limit = max(0, (controller.view.documentView?.bounds.height ?? 0) - clip.bounds.height)
        let y = clip.bounds.origin.y + 180 < limit ? clip.bounds.origin.y + 180 : max(0, clip.bounds.origin.y - 180)
        clip.scroll(to: CGPoint(x: clip.bounds.origin.x, y: y))
        scroll.reflectScrolledClipView(clip)
        try await wait("native scrolling still persists after recoloring") {
            guard let saved = store.readingPosition(for: paper.id) else { return false }
            return saved.page != beforeScroll.page || abs(saved.y - beforeScroll.y) > 20
        }
        controller.flush()
        let scrolled = store.readingPosition(for: paper.id)!
        controller.setColorPreset(.gray)
        try await Task.sleep(nanoseconds: 180_000_000)
        controller.flush()
        precondition(samePassage(store.readingPosition(for: paper.id), scrolled),
                     "native inner-scroll-view movement must replace a stale layout anchor before the next color change")
        let reloadedStore = StudyStore(resourceDirectory: root, dataDirectory: root.appendingPathComponent("records"))
        precondition(samePassage(reloadedStore.readingPosition(for: paper.id), scrolled),
                     "the post-theme scroll position is actually saved on disk")

        let secondSource = root.appendingPathComponent("second-fixture.pdf")
        ColorFixture.write(to: secondSource, title: "A different paper with persistent reading colors")
        store.importPDF([secondSource])
        let second = store.paper!
        precondition(second.id != paper.id)
        controller.load(second, store: store)
        try await Task.sleep(nanoseconds: 160_000_000)
        precondition(controller.loadedID == second.id && controller.view.document !== document && controller.view.colorPreset == .gray,
                     "opening another paper keeps the user's chosen display palette")
        print("active search, post-refresh scroll persistence, hidden annotations and next-paper palette verified")
        verifyPreference()
        print("PASS: PDF color contrast and persistent preference; all six themes preserve source document, selection and reading context.")
    }
}
