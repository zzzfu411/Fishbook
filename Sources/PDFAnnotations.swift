import AppKit
import PDFKit
import CryptoKit

enum PDFAnnotationSupport {
    static let ownerKey = PDFAnnotationKey(rawValue: "/PSOwner")

    /// Generate annotations without mutating the page. The caller checks the
    /// source fingerprint, then adds each note's results before generating the
    /// next note so page-level comment icons can avoid existing annotations.
    static func annotations(for note: StudyNote, on page: PDFPage, pageIndex: Int) -> [PDFAnnotation] {
        guard note.documentSource == nil, validHash(note.sourceSHA256), pageIndex >= 0,
              LibraryStorage.validNote(note), !note.anchors.isEmpty else { return [] }
        if let document = page.document {
            guard pageIndex < document.pageCount, document.index(for: page) == pageIndex,
                  validAnchors(note, in: document) else { return [] }
        }
        let anchors = note.anchors.filter { $0.page == pageIndex }
        guard !anchors.isEmpty else { return [] }
        let bounds = page.bounds(for: .cropBox)
        guard validPageBounds(bounds), anchors.allSatisfy({ anchor in
            anchor.rects.allSatisfy { validRectangle($0, in: bounds) }
        }) else { return [] }

        var result: [PDFAnnotation] = []
        var seen: [CGRect] = []
        for anchor in anchors {
            for box in anchor.rects {
                let rect = box.cg.intersection(bounds)
                guard !seen.contains(rect) else { continue }
                seen.append(rect)
                let type: PDFAnnotationSubtype
                switch note.effectiveMarkupStyle {
                case .highlight: type = .highlight
                case .underline: type = .underline
                case .strikeOut: type = .strikeOut
                }
                let annotation = PDFAnnotation(bounds: rect, forType: type, withProperties: nil)
                annotation.quadrilateralPoints = [
                    NSValue(point: CGPoint(x: 0, y: rect.height)),
                    NSValue(point: CGPoint(x: rect.width, y: rect.height)),
                    NSValue(point: .zero),
                    NSValue(point: CGPoint(x: rect.width, y: 0))
                ]
                configure(annotation, for: note, isHighlight: type == .highlight)
                result.append(annotation)
            }
        }
        if result.isEmpty, !note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let annotation = PDFAnnotation(bounds: commentBounds(on: page), forType: .text, withProperties: nil)
            annotation.iconType = .comment
            configure(annotation, for: note, isHighlight: false)
            result.append(annotation)
        }
        return result
    }

    /// Build a separate document from source bytes. Existing PDF annotations,
    /// including previously exported Fishbook annotations, are never removed.
    /// Unknown/mismatched sources and malformed anchors remain in Fishbook's
    /// records but are not projected onto an unrelated location in the PDF.
    static func annotatedDocument(source: Data, notes: [StudyNote]) throws -> PDFDocument {
        guard let document = PDFDocument(data: source), !document.isLocked, document.pageCount > 0 else {
            throw StudyError.message("原 PDF 无法读取，或尚未解锁。")
        }
        let sha = SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined()
        var seenIDs = Set<UUID>()
        for note in notes {
            guard note.documentSource == nil,
                  note.sourceSHA256?.lowercased() == sha, LibraryStorage.validNote(note),
                  validAnchors(note, in: document), seenIDs.insert(note.id).inserted else { continue }
            for pageIndex in Set(note.anchors.map(\.page)).sorted() {
                guard let page = document.page(at: pageIndex) else { continue }
                for annotation in annotations(for: note, on: page, pageIndex: pageIndex) {
                    page.addAnnotation(annotation)
                }
            }
        }
        return document
    }

    static func annotatedData(source: Data, notes: [StudyNote]) throws -> Data {
        let document = try annotatedDocument(source: source, notes: notes)
        guard let data = document.dataRepresentation() else {
            throw StudyError.message("未能生成带批注的 PDF，原文件没有改动。")
        }
        return data
    }

    private static func configure(_ annotation: PDFAnnotation, for note: StudyNote, isHighlight: Bool) {
        annotation.color = note.effectiveMarkupColor.nsColor.withAlphaComponent(isHighlight ? 0.38 : 1)
        annotation.contents = note.body
        annotation.userName = StudyBrand.name
        annotation.modificationDate = note.created
        annotation.shouldDisplay = true
        annotation.shouldPrint = true
        annotation.setValue(note.id.uuidString, forAnnotationKey: ownerKey)
    }

    private static func validHash(_ hash: String?) -> Bool {
        guard let hash else { return false }
        return hash.count == 64 && hash.allSatisfy(\.isHexDigit)
    }

    private static func validPageBounds(_ rect: CGRect) -> Bool {
        [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy(\.isFinite)
            && rect.width > 0 && rect.height > 0
    }

    private static func validRectangle(_ box: Box, in pageBounds: CGRect) -> Bool {
        guard [box.x, box.y, box.width, box.height].allSatisfy(\.isFinite),
              box.width > 0, box.height > 0 else { return false }
        let rect = box.cg
        // Small PDFKit selection-rounding overhangs are clipped; a rectangle
        // outside the page, or one spanning far beyond it, is not a valid anchor.
        return pageBounds.insetBy(dx: -1, dy: -1).contains(rect)
            && !rect.intersection(pageBounds).isEmpty
    }

    private static func validAnchors(_ note: StudyNote, in document: PDFDocument) -> Bool {
        guard !note.anchors.isEmpty else { return false }
        return note.anchors.allSatisfy { anchor in
            guard anchor.page >= 0, anchor.page < document.pageCount,
                  let page = document.page(at: anchor.page) else { return false }
            let bounds = page.bounds(for: .cropBox)
            return validPageBounds(bounds) && anchor.rects.allSatisfy { validRectangle($0, in: bounds) }
        }
    }

    private static func commentBounds(on page: PDFPage) -> CGRect {
        let bounds = page.bounds(for: .cropBox)
        let side = min(18, min(bounds.width, bounds.height) / 3)
        let inset = min(12, min(bounds.width, bounds.height) / 8)
        let step = side + 6
        let columns = max(1, Int(min(200, (bounds.width - 2 * inset) / step)))
        let rows = max(1, Int(min(200, (bounds.height - 2 * inset) / step)))
        let occupied = page.annotations.map(\.bounds)
        for column in 0..<columns {
            for row in 0..<rows {
                let rect = CGRect(x: bounds.maxX - inset - side - CGFloat(column) * step,
                                  y: bounds.maxY - inset - side - CGFloat(row) * step,
                                  width: side, height: side)
                if !occupied.contains(where: { $0.insetBy(dx: -2, dy: -2).intersects(rect) }) { return rect }
            }
        }
        // If the entire page is already occupied, keep the comment visible
        // inside the page and offset it from earlier page-level comment icons.
        let count = page.annotations.filter { $0.type == "Text" }.count
        let offset = min(CGFloat(count % 11) / 2, max(0, min(bounds.width, bounds.height) - side - inset))
        return CGRect(x: bounds.maxX - inset - side - offset,
                      y: bounds.maxY - inset - side - offset, width: side, height: side)
    }
}
