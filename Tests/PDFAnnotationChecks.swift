import Foundation
import AppKit
import PDFKit
import CoreText
import CryptoKit

@main struct PDFAnnotationChecks {
    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func fixture() -> PDFDocument {
        let buffer = NSMutableData()
        var bounds = CGRect(x: 0, y: 0, width: 600, height: 800)
        let context = CGContext(consumer: CGDataConsumer(data: buffer)!, mediaBox: &bounds, nil)!
        let font = CTFontCreateWithName("Helvetica" as CFString, 17, nil)
        for index in 0..<3 {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(bounds)
            let line = NSAttributedString(string: "Original searchable paper page \(index + 1)", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
            ])
            context.textPosition = CGPoint(x: 40, y: 740)
            CTLineDraw(CTLineCreateWithAttributedString(line), context)
            context.endPDFPage()
        }
        context.closePDF()
        let document = PDFDocument(data: buffer as Data)!
        let original = PDFAnnotation(bounds: CGRect(x: 20, y: 700, width: 18, height: 18), forType: .text, withProperties: nil)
        original.contents = "原文件自带批注：勿删除。"
        original.color = .cyan
        document.page(at: 0)!.addAnnotation(original)
        let oldExport = PDFAnnotation(bounds: CGRect(x: 20, y: 670, width: 18, height: 18), forType: .text, withProperties: nil)
        oldExport.contents = "旧 Fishbook 导出内嵌批注"
        oldExport.setValue("already-in-the-source", forAnnotationKey: PDFAnnotationSupport.ownerKey)
        document.page(at: 0)!.addAnnotation(oldExport)
        let hidden = PDFAnnotation(bounds: CGRect(x: 20, y: 650, width: 30, height: 12), forType: .underline, withProperties: nil)
        hidden.contents = "原文件隐藏批注"
        hidden.shouldDisplay = false
        hidden.shouldPrint = false
        document.page(at: 2)!.addAnnotation(hidden)
        return document
    }

    static func makeNote(sha: String, body: String = "批注正文：中文、English 与 α₂。", page: Int = 0,
                         rects: [Box]? = nil, style: PDFMarkupStyle? = nil, color: PDFMarkupColor? = nil) -> StudyNote {
        StudyNote(paperID: "fixture", sourceSHA256: sha, kind: "高亮", body: body, quote: "searchable paper",
                  anchors: [Anchor(page: page, rects: rects ?? [Box(CGRect(x: 40, y: 640, width: 130, height: 17))], quote: "searchable paper")],
                  markupStyle: style, markupColor: color, created: Date(timeIntervalSince1970: 1_700_000_000))
    }

    static func allAnnotations(_ document: PDFDocument) -> [PDFAnnotation] {
        (0..<document.pageCount).flatMap { document.page(at: $0)!.annotations }
    }

    static func rgb(_ color: NSColor) -> [CGFloat] {
        let color = color.usingColorSpace(.sRGB)!
        return [color.redComponent, color.greenComponent, color.blueComponent]
    }

    static func verifyLegacyAndCoding(sha: String) throws {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        for kind in ["高亮", "笔记", "疑问"] {
            var note = makeNote(sha: sha)
            note.kind = kind
            var raw = try JSONSerialization.jsonObject(with: encoder.encode(note)) as! [String: Any]
            raw.removeValue(forKey: "markupStyle"); raw.removeValue(forKey: "markupColor")
            let decoded = try decoder.decode(StudyNote.self, from: JSONSerialization.data(withJSONObject: raw))
            precondition(decoded.markupStyle == nil && decoded.markupColor == nil)
            precondition(decoded.effectiveMarkupStyle == .highlight)
            precondition(decoded.effectiveMarkupColor == (kind == "疑问" ? .orange : .yellow))
            precondition(decoded.kind == kind && decoded.anchors == note.anchors && decoded.id == note.id)
        }
        for style in PDFMarkupStyle.allCases {
            for color in PDFMarkupColor.allCases {
                let note = makeNote(sha: sha, style: style, color: color)
                let decoded = try decoder.decode(StudyNote.self, from: encoder.encode(note))
                precondition(decoded.markupStyle == style && decoded.markupColor == color && decoded.kind == "高亮")
                precondition(decoded.effectiveMarkupStyle == style && decoded.effectiveMarkupColor == color)
            }
        }
        print("legacy records and all style/color combinations round-trip")
    }

    static func verifyPDFExport(source: Data, sourceDocument: PDFDocument, url: URL) throws {
        let sha = hash(source)
        var notes: [StudyNote] = []
        for (styleIndex, style) in PDFMarkupStyle.allCases.enumerated() {
            for (colorIndex, color) in PDFMarkupColor.allCases.enumerated() {
                let row = styleIndex * 6 + colorIndex
                notes.append(makeNote(sha: sha, body: "\(style.title)/\(color.title)：保留中文内容 α₂。",
                                      rects: [Box(CGRect(x: 55, y: 690 - row * 21, width: 150, height: 16))],
                                      style: style, color: color))
            }
        }
        var cross = makeNote(sha: sha, body: "跨页笔记：第一、第二行，以及下一页。", style: .underline, color: .blue)
        cross.anchors = [Anchor(page: 1, rects: [Box(CGRect(x: 55, y: 650, width: 130, height: 16)),
                                                  Box(CGRect(x: 55, y: 625, width: 170, height: 16))], quote: "two lines"),
                         Anchor(page: 2, rects: [Box(CGRect(x: 55, y: 650, width: 90, height: 16))], quote: "next page")]
        notes.append(cross)
        let comments = (0..<3).map { makeNote(sha: sha, body: "页级正文 \($0)：这里还有一个问题。", page: 1, rects: [], color: .pink) }
        notes += comments
        let accepted = notes
        func rejected(_ update: (inout StudyNote) -> Void) -> StudyNote {
            var note = makeNote(sha: sha)
            update(&note)
            return note
        }
        let invalid = [
            rejected { $0.sourceSHA256 = String(repeating: "0", count: 64) },
            rejected { $0.sourceSHA256 = nil },
            rejected { $0.anchors[0].page = 99 },
            rejected { $0.anchors[0].page = -1 },
            rejected { $0.anchors[0].rects[0].width = 0 },
            rejected { $0.anchors[0].rects[0].width = -10 },
            rejected { $0.anchors[0].rects[0].x = .nan },
            rejected { $0.anchors[0].rects[0].x = .infinity },
            rejected { $0.anchors[0].rects[0].x = 900 },
            rejected { $0.anchors.append(Anchor(page: 50, rects: [], quote: "")) },
            rejected { $0.documentSource = DocumentNoteSource(documentID: "chinese", documentTitle: "译文", blockID: "p1", quote: "段落", blockOffset: 0, progress: 0) }
        ]
        notes += invalid
        var unknownEmpty = makeNote(sha: sha, body: " \n ", page: 1, rects: [])
        unknownEmpty.kind = "笔记"
        notes.append(unknownEmpty)

        let originalObjects = allAnnotations(sourceDocument)
        sourceDocument.page(at: 2)!.displaysAnnotations = false
        let output = try PDFAnnotationSupport.annotatedDocument(source: source, notes: notes + [accepted[0]])
        precondition(output !== sourceDocument && output.pageCount == 3)
        precondition(output.string == sourceDocument.string)
        precondition(allAnnotations(sourceDocument).count == originalObjects.count)
        precondition(!sourceDocument.page(at: 2)!.displaysAnnotations)
        for annotation in originalObjects {
            precondition(allAnnotations(sourceDocument).contains { $0 === annotation }, "export cannot replace original annotation objects")
        }
        let textBounds = output.page(at: 1)!.annotations.filter { annotation in
            comments.contains { annotation.value(forAnnotationKey: PDFAnnotationSupport.ownerKey) as? String == $0.id.uuidString }
        }.map(\.bounds)
        precondition(textBounds.count == 3 && Set(textBounds.map { NSStringFromRect($0) }).count == 3,
                     "page-level notes must not occupy the same icon position")
        precondition(textBounds.allSatisfy { output.page(at: 1)!.bounds(for: .cropBox).contains($0) })
        let outputData = try PDFAnnotationSupport.annotatedData(source: source, notes: notes)
        let reopened = PDFDocument(data: outputData)!
        let annotations = allAnnotations(reopened)
        for note in accepted {
            let owned = annotations.filter { $0.value(forAnnotationKey: PDFAnnotationSupport.ownerKey) as? String == note.id.uuidString }
            let expectedCount = note.anchors.reduce(0) { $0 + max(1, $1.rects.count) }
            precondition(owned.count == expectedCount, "each selected line and each page-level note is serialized once")
            for annotation in owned {
                let expectedType: String
                if note.anchors.allSatisfy({ $0.rects.isEmpty }) { expectedType = "Text" }
                else {
                    switch note.effectiveMarkupStyle {
                    case .highlight: expectedType = "Highlight"
                    case .underline: expectedType = "Underline"
                    case .strikeOut: expectedType = "StrikeOut"
                    }
                }
                precondition(annotation.type == expectedType)
                precondition(annotation.contents == note.body && annotation.userName == StudyBrand.name)
                precondition(zip(rgb(annotation.color), rgb(note.effectiveMarkupColor.nsColor)).allSatisfy { abs($0 - $1) < 0.02 })
                precondition(annotation.shouldDisplay && annotation.shouldPrint)
                if expectedType != "Text" { precondition(annotation.quadrilateralPoints?.count == 4) }
            }
        }
        let rejectedIDs = Set((invalid + [unknownEmpty]).map { $0.id.uuidString })
        precondition(!annotations.contains { rejectedIDs.contains($0.value(forAnnotationKey: PDFAnnotationSupport.ownerKey) as? String ?? "") })
        precondition(annotations.contains { $0.contents == "原文件自带批注：勿删除。" })
        precondition(annotations.contains { $0.contents == "旧 Fishbook 导出内嵌批注" && $0.value(forAnnotationKey: PDFAnnotationSupport.ownerKey) as? String == "already-in-the-source" })
        let hidden = annotations.first { $0.contents == "原文件隐藏批注" }!
        precondition(!hidden.shouldDisplay && !hidden.shouldPrint)
        let unchangedFile = try Data(contentsOf: url)
        precondition(hash(unchangedFile) == sha && hash(source) == sha)
        do {
            _ = try PDFAnnotationSupport.annotatedDocument(source: Data("not PDF".utf8), notes: [])
            preconditionFailure("invalid PDF input must be rejected")
        } catch {}
        print("PDF save/reopen preserves markup types, colors, Chinese bodies, cross-page lines and all original annotations; invalid sources/anchors stay isolated")
    }

    @MainActor static func verifyStoreAndBackups(root: URL, source: URL) throws {
        try JSONEncoder().encode(Catalog(papers: [], guides: []))
            .write(to: root.appendingPathComponent("content/library.json"))
        let records = root.appendingPathComponent("records")
        let store = StudyStore(resourceDirectory: root, dataDirectory: records)
        precondition(store.ready)
        store.importPDF([source])
        let paper = store.paper!
        var note = makeNote(sha: paper.sha256, style: .underline, color: .purple)
        note.paperID = paper.id
        note.sourceSHA256 = nil
        let undo = UndoManager(); undo.groupsByEvent = false
        undo.beginUndoGrouping()
        precondition(store.upsert(note, undo: undo))
        undo.endUndoGrouping()
        let original = store.data.notes.first!
        precondition(original.sourceSHA256 == paper.sha256 && undo.canUndo)
        undo.undo(); precondition(store.data.notes.isEmpty && undo.canRedo)
        undo.redo(); precondition(store.data.notes.first?.markupStyle == .underline && store.data.notes.first?.markupColor == .purple)

        var edited = original
        edited.body = "编辑后的正文"; edited.markupStyle = .strikeOut; edited.markupColor = .green
        edited.paperID = "wrong-paper"; edited.sourceSHA256 = "wrong-source"
        edited.anchors = [Anchor(page: 99, rects: [], quote: "wrong")]
        edited.quote = "wrong quote"; edited.created = Date(timeIntervalSince1970: 1)
        undo.beginUndoGrouping()
        precondition(store.upsert(edited, undo: undo))
        undo.endUndoGrouping()
        let saved = store.data.notes.first!
        precondition(saved.paperID == original.paperID && saved.sourceSHA256 == original.sourceSHA256 && saved.anchors == original.anchors && saved.quote == original.quote && saved.created == original.created)
        precondition(saved.body == edited.body && saved.markupStyle == .strikeOut && saved.markupColor == .green)
        undo.undo(); precondition(store.data.notes.first?.body == original.body && store.data.notes.first?.markupStyle == .underline)
        undo.redo(); precondition(store.data.notes.first?.body == edited.body && store.data.notes.first?.markupStyle == .strikeOut)
        undo.beginUndoGrouping()
        precondition(store.remove(saved, undo: undo))
        undo.endUndoGrouping()
        undo.undo(); precondition(store.data.notes.first?.markupColor == .green)
        undo.redo(); precondition(store.data.notes.isEmpty)
        undo.undo(); precondition(store.data.notes.first?.markupStyle == .strikeOut)

        let failureUndo = UndoManager(); failureUndo.groupsByEvent = false
        let savedState = try Data(contentsOf: store.stateURL)
        try FileManager.default.removeItem(at: store.stateURL)
        try FileManager.default.createDirectory(at: store.stateURL, withIntermediateDirectories: false)
        var failed = store.data.notes.first!
        failed.body = "这个写入必须失败"
        precondition(!store.upsert(failed, undo: failureUndo))
        precondition(!failureUndo.canUndo && store.data.notes.first?.body != failed.body)
        try FileManager.default.removeItem(at: store.stateURL)
        try savedState.write(to: store.stateURL, options: .atomic)

        let backup = try LibraryStorage.createBackup(from: records, to: root.appendingPathComponent("backups"))
        let restoredPath = root.appendingPathComponent("restored")
        _ = try LibraryStorage.restore(from: backup.directory, to: restoredPath)
        let restored = StudyStore(resourceDirectory: root, dataDirectory: restoredPath)
        precondition(restored.ready && restored.data.notes.first?.markupStyle == .strikeOut && restored.data.notes.first?.markupColor == .green)

        let legacyPath = root.appendingPathComponent("legacy")
        try FileManager.default.copyItem(at: records, to: legacyPath)
        let legacyStateURL = legacyPath.appendingPathComponent("state.json")
        var state = try JSONSerialization.jsonObject(with: Data(contentsOf: legacyStateURL)) as! [String: Any]
        var rows = state["notes"] as! [[String: Any]]
        for index in rows.indices { rows[index].removeValue(forKey: "markupStyle"); rows[index].removeValue(forKey: "markupColor") }
        state["notes"] = rows
        try JSONSerialization.data(withJSONObject: state).write(to: legacyStateURL)
        let legacyBackup = try LibraryStorage.createBackup(from: legacyPath, to: root.appendingPathComponent("legacy-backups"))
        let legacyRestore = root.appendingPathComponent("legacy-restored")
        _ = try LibraryStorage.restore(from: legacyBackup.directory, to: legacyRestore)
        let legacy = StudyStore(resourceDirectory: root, dataDirectory: legacyRestore)
        precondition(legacy.ready && legacy.data.notes.first?.markupStyle == nil && legacy.data.notes.first?.effectiveMarkupStyle == .highlight && legacy.data.notes.first?.effectiveMarkupColor == .yellow)
        print("create/edit/delete undo-redo preserves source identity and styling; failed persistence registers no undo; current and legacy backups restore")
    }

    @MainActor static func main() throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fishbook-annotations-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("content"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceDocument = fixture()
        let source = sourceDocument.dataRepresentation()!
        let sourceURL = root.appendingPathComponent("original.pdf")
        try source.write(to: sourceURL)
        try verifyLegacyAndCoding(sha: hash(source))
        try verifyPDFExport(source: source, sourceDocument: sourceDocument, url: sourceURL)
        try verifyStoreAndBackups(root: root, source: sourceURL)
        print("PASS: PDF annotation serialization, source isolation, backward compatibility, undo/redo and backups.")
    }
}
