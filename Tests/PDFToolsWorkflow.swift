import Foundation
import AppKit
import PDFKit
import CoreText
import CryptoKit

/// The two catalog entries deliberately share the same PDF bytes. This catches
/// accidental sharing of personal marks when a hash matches but paper IDs do not.
private enum ToolsFixture {
    static let sourceOwner = UUID()
    static func write(to url: URL) throws -> Data {
        var bounds = CGRect(x: 0, y: 0, width: 600, height: 800)
        let context = CGContext(url as CFURL, mediaBox: &bounds, nil)!
        let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        for page in 0..<3 {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(bounds)
            for (label, y) in [("Opening", 700), ("Middle", 400), ("Closing", 120)] {
                let line = NSAttributedString(string: "\(label) passage on page \(page + 1). Searchable evidence.", attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
                ])
                context.textPosition = CGPoint(x: 30, y: CGFloat(y))
                CTLineDraw(CTLineCreateWithAttributedString(line), context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        let document = PDFDocument(url: url)!
        let priorFishbook = PDFAnnotation(bounds: CGRect(x: 530, y: 740, width: 18, height: 18), forType: .text, withProperties: nil)
        priorFishbook.contents = "Original embedded Fishbook comment"
        priorFishbook.setValue(sourceOwner.uuidString, forAnnotationKey: PDFAnnotationSupport.ownerKey)
        document.page(at: 0)!.addAnnotation(priorFishbook)
        let publisher = PDFAnnotation(bounds: CGRect(x: 30, y: 395, width: 180, height: 22), forType: .highlight, withProperties: nil)
        publisher.contents = "Publisher highlight"; publisher.color = .cyan
        document.page(at: 1)!.addAnnotation(publisher)
        let hidden = PDFAnnotation(bounds: CGRect(x: 30, y: 115, width: 150, height: 20), forType: .underline, withProperties: nil)
        hidden.contents = "Hidden source markup"; hidden.shouldDisplay = false; hidden.shouldPrint = false
        document.page(at: 2)!.addAnnotation(hidden)
        let bytes = document.dataRepresentation()!
        try bytes.write(to: url)
        return bytes
    }
    static func hash(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

@main struct PDFToolsWorkflow {
    @MainActor private static func wait(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<120 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        fatalError("Timed out: " + message)
    }
    private static func samePassage(_ first: ReadingPosition?, _ second: ReadingPosition) -> Bool {
        guard let first else { return false }
        return first.page == second.page && abs(first.y - second.y) < 3
    }
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fishbook-pdf-tools-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("content"), withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("content/source.pdf")
        let sourceBytes = try ToolsFixture.write(to: sourceURL)
        let sha = ToolsFixture.hash(sourceBytes)
        let paper = Paper(id: "tools-A", name: "A", title: "Tools fixture A", file: "source.pdf", pages: 3, sha256: sha, area: "Test", year: 2026)
        let other = Paper(id: "tools-B", name: "B", title: "Tools fixture B", file: "source.pdf", pages: 3, sha256: sha, area: "Test", year: 2026)
        try JSONEncoder().encode(Catalog(papers: [paper, other], guides: [])).write(to: root.appendingPathComponent("content/library.json"))
        let store = StudyStore(resourceDirectory: root, dataDirectory: root.appendingPathComponent("records"))
        precondition(store.ready && store.select(paper.id))
        let pdf = PDFController()
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 700, height: 780),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 780))
        window.contentView = host
        pdf.view.frame = host.bounds; pdf.view.autoresizingMask = [.width, .height]
        host.addSubview(pdf.view)
        pdf.load(paper, store: store)
        try await wait("synthetic PDF loads") { pdf.view.document != nil }
        try await Task.sleep(nanoseconds: 100_000_000)
        let document = pdf.view.document!
        let sourceAnnotations = (0..<3).flatMap { document.page(at: $0)!.annotations }
        let originalText = document.string
        precondition(sourceAnnotations.count == 3 && pdf.embeddedAnnotations.count == 2,
                     "source annotations are listed separately, with hidden ones omitted from the list")
        let hidden = sourceAnnotations.first { $0.contents == "Hidden source markup" }!
        func assertSourceAnnotations() {
            for annotation in sourceAnnotations {
                precondition(annotation.page?.annotations.contains(where: { $0 === annotation }) == true,
                             "refresh must preserve original annotation objects, including existing PSOwner tags")
            }
            precondition(!hidden.shouldDisplay && !hidden.shouldPrint,
                         "refresh and reading colors cannot expose or print hidden source annotations")
        }
        func owned(_ noteID: UUID) -> [PDFAnnotation] {
            (0..<document.pageCount).flatMap { document.page(at: $0)!.annotations }.filter { annotation in
                annotation.value(forAnnotationKey: PDFAnnotationSupport.ownerKey) as? String == noteID.uuidString
                    && !sourceAnnotations.contains(where: { $0 === annotation })
            }
        }

        // PDFKit creates the selection and the per-line rectangles; the fixture
        // spans a page boundary rather than supplying hand-written anchors.
        let firstPage = document.page(at: 0)!, secondPage = document.page(at: 1)!
        let selection = PDFSelection(document: document)
        selection.add(firstPage.selection(for: CGRect(x: 28, y: 104, width: 520, height: 36))!)
        selection.add(secondPage.selection(for: CGRect(x: 28, y: 684, width: 520, height: 36))!)
        pdf.view.go(to: PDFDestination(page: firstPage, at: CGPoint(x: 0, y: 230)))
        pdf.view.setCurrentSelection(selection, animate: false)
        precondition(pdf.hasTextSelection && selection.pages.count == 2)
        var note = pdf.makeNote(kind: "高亮")!
        note.id = ToolsFixture.sourceOwner // Same owner text as an embedded annotation, different identity.
        note.body = "Two passages belong to one thought."; note.markupStyle = .underline; note.markupColor = .purple
        precondition(Set(note.anchors.map(\.page)) == [0, 1] && note.anchors.allSatisfy { !$0.rects.isEmpty },
                     "a cross-page selection stores page-specific nonempty geometry")
        precondition(note.quote.contains("Closing passage on page 1") && note.quote.contains("Opening passage on page 2"))
        precondition(store.upsert(note), store.error ?? "cross-page note should persist"); pdf.refreshMarks()
        let initialMarks = owned(note.id)
        precondition(initialMarks.count == note.anchors.flatMap(\.rects).count && initialMarks.allSatisfy { $0.type == "Underline" },
                     "every selected line on both pages receives the selected markup style")
        assertSourceAnnotations()

        var tapped: [UUID] = []
        pdf.onAnnotationTapped = { tapped.append($0) }
        let embeddedOwner = sourceAnnotations.first { $0.value(forAnnotationKey: PDFAnnotationSupport.ownerKey) != nil }!
        let forged = PDFAnnotation(bounds: initialMarks[0].bounds, forType: .underline, withProperties: nil)
        forged.setValue(note.id.uuidString, forAnnotationKey: PDFAnnotationSupport.ownerKey)
        let unrelatedView = StudyPDFView()
        for (view, annotation) in [(pdf.view, embeddedOwner), (pdf.view, forged), (unrelatedView, initialMarks[0]), (pdf.view, initialMarks[0])] {
            NotificationCenter.default.post(name: .PDFViewAnnotationHit, object: view, userInfo: ["PDFAnnotationHit": annotation])
        }
        try await wait("owned annotation click arrives") { tapped.count == 1 }
        precondition(tapped == [note.id], "only an annotation owned by this controller may open its personal record")
        print("cross-page selection, source annotation preservation and click ownership verified")

        let undo = UndoManager(); undo.groupsByEvent = false
        var revised = note; revised.markupStyle = .strikeOut; revised.markupColor = .blue
        undo.beginUndoGrouping(); precondition(store.upsert(revised, undo: undo)); undo.endUndoGrouping()
        pdf.refreshMarks()
        precondition(initialMarks.allSatisfy { old in !owned(note.id).contains(where: { $0 === old }) } && owned(note.id).allSatisfy { $0.type == "StrikeOut" },
                     "style edits replace only runtime marks and cannot accumulate overlapping copies")
        undo.undo(); pdf.refreshMarks()
        precondition(owned(note.id).count == initialMarks.count && owned(note.id).allSatisfy { $0.type == "Underline" },
                     "undo restores visible markup geometry and style")
        undo.redo(); pdf.refreshMarks()
        precondition(owned(note.id).count == initialMarks.count && owned(note.id).allSatisfy { $0.type == "StrikeOut" })
        assertSourceAnnotations()

        pdf.view.go(to: PDFDestination(page: secondPage, at: CGPoint(x: 0, y: 490)))
        pdf.flush()
        let passage = store.readingPosition(for: paper.id)!
        let marksBeforeTheme = owned(note.id)
        pdf.setColorPreset(.night)
        try await Task.sleep(nanoseconds: 160_000_000)
        try await wait("markup and color refresh retain reading position") {
            pdf.flush(); return pdf.view.autoScales && samePassage(store.readingPosition(for: paper.id), passage)
        }
        pdf.preservePositionForLayoutChange()
        window.setContentSize(NSSize(width: 1080, height: 850)); host.frame.size = NSSize(width: 1080, height: 850)
        pdf.view.frame = host.bounds; host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 160_000_000)
        try await wait("wide reading with markup retains the passage") {
            pdf.flush(); return samePassage(store.readingPosition(for: paper.id), passage)
        }
        precondition(pdf.view.document === document && document.string == originalText,
                     "annotation and palette changes retain searchable document identity")
        precondition(marksBeforeTheme.allSatisfy { mark in owned(note.id).contains(where: { $0 === mark }) },
                     "color and layout refreshes preserve runtime annotation objects and their click ownership")
        assertSourceAnnotations()

        let otherNote = StudyNote(paperID: other.id, sourceSHA256: sha, kind: "高亮", body: "Other paper's private note", quote: "", anchors: [Anchor(page: 2, rects: [Box(CGRect(x: 30, y: 395, width: 150, height: 22))], quote: "")])
        precondition(store.upsert(otherNote)); pdf.refreshMarks()
        precondition(owned(otherNote.id).isEmpty, "matching file hashes do not share marks across paper records")
        let exported = try PDFAnnotationSupport.annotatedDocument(source: sourceBytes, notes: store.annotationNotes(for: paper.id))
        let exportedMarks = (0..<exported.pageCount).flatMap { exported.page(at: $0)!.annotations }
        precondition(exported.pageCount == document.pageCount && exported.string == originalText)
        precondition(exportedMarks.count == sourceAnnotations.count + owned(note.id).count,
                     "export contains the original embedded annotations plus each current personal markup exactly once")
        precondition(!exportedMarks.contains { $0.contents == otherNote.body },
                     "exported PDF is scoped to the selected paper, even when another record has identical source bytes")
        precondition(exported !== document && exported.page(at: 0) !== firstPage,
                     "export uses an independent document and cannot recolor or mutate the live reader")
        let bytesAfterExport = try Data(contentsOf: sourceURL)
        precondition(bytesAfterExport == sourceBytes, "reading, editing, undo and export never rewrite the source PDF")

        let oldMark = owned(note.id)[0]
        NotificationCenter.default.post(name: .PDFViewAnnotationHit, object: pdf.view, userInfo: ["PDFAnnotationHit": oldMark])
        precondition(store.select(other.id)); pdf.load(other, store: store)
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(tapped == [note.id], "an asynchronously delivered click cannot reopen a record from the previous paper")
        let otherDocument = pdf.view.document!
        let currentOtherMarks = (0..<otherDocument.pageCount).flatMap { otherDocument.page(at: $0)!.annotations }
        precondition(currentOtherMarks.contains { $0.contents == otherNote.body } && !currentOtherMarks.contains { $0.contents == revised.body })
        precondition(pdf.view.colorPreset == .night && !pdf.canBack && !pdf.canForward,
                     "paper switching preserves display preference while resetting navigation ownership")
        let bytesAfterSwitch = try Data(contentsOf: sourceURL)
        precondition(bytesAfterSwitch == sourceBytes)
        print("PASS: native source marks/hidden flags/PSOwner preserved; cross-page selection; owned click routing; visible edit/undo/redo; annotation plus color/resize position; paper and export isolation; source bytes unchanged.")
    }
}
