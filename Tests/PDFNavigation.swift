import Foundation
import AppKit
import PDFKit

@main struct PDFHarness {
    @MainActor private static func verifyOutlineNavigation(_ controller: PDFController, store: StudyStore) {
        let document = controller.view.document!
        let outlineDocument = PDFDocument()
        for pageIndex in 0..<3 {
            outlineDocument.insert(document.page(at: pageIndex)!.copy() as! PDFPage, at: pageIndex)
        }
        let outlineRoot = PDFOutline(), section = PDFOutline(), subsection = PDFOutline()
        let actionSection = PDFOutline(), unspecifiedX = PDFOutline(), unspecifiedY = PDFOutline(), outside = PDFOutline()
        let page = outlineDocument.page(at: 1)!, crop = page.bounds(for: .cropBox)
        let upperPoint = CGPoint(x: crop.minX + 24, y: crop.maxY - 160)
        let lowerPoint = CGPoint(x: crop.minX + 24, y: crop.maxY - 430)
        section.label = "A section"; section.destination = PDFDestination(page: page, at: upperPoint)
        subsection.label = "A subsection"; subsection.destination = PDFDestination(page: page, at: lowerPoint)
        section.insertChild(subsection, at: 0)
        actionSection.label = "Action destination"
        actionSection.action = PDFActionGoTo(destination: PDFDestination(page: outlineDocument.page(at: 2)!, at: CGPoint(x: 36, y: 480)))
        unspecifiedX.label = "Only vertical position"
        unspecifiedX.destination = PDFDestination(page: page, at: CGPoint(x: kPDFDestinationUnspecifiedValue, y: lowerPoint.y))
        unspecifiedY.label = "Only horizontal position"
        unspecifiedY.destination = PDFDestination(page: page, at: CGPoint(x: upperPoint.x, y: kPDFDestinationUnspecifiedValue))
        outside.label = "Outside the crop box"
        outside.destination = PDFDestination(page: page, at: CGPoint(x: crop.minX - 500, y: crop.maxY + 500))
        for (index, node) in [section, actionSection, unspecifiedX, unspecifiedY, outside].enumerated() {
            outlineRoot.insertChild(node, at: index)
        }
        outlineDocument.outlineRoot = outlineRoot
        let entries = PDFController.flattenOutline(outlineDocument)
        precondition(entries.count == 6 && entries[0].level == 0 && entries[1].level == 1,
                     "nested outline retains hierarchy without losing siblings")
        precondition(entries[0].page == 1 && entries[1].page == 1 && entries[0].point == upperPoint && entries[1].point == lowerPoint,
                     "two sections on the same page must retain distinct in-page destinations")
        precondition(entries[2].page == 2 && entries[2].point == CGPoint(x: 36, y: 480),
                     "PDFActionGoTo outlines retain page and section coordinates")
        precondition(entries[3].point == CGPoint(x: crop.minX, y: lowerPoint.y),
                     "unspecified horizontal coordinates must not discard a valid vertical section position")
        precondition(entries[4].point == CGPoint(x: upperPoint.x, y: crop.maxY),
                     "PDFKit's finite unspecified sentinel is a page-top fallback, never a scroll coordinate")
        precondition(entries[5].point == CGPoint(x: crop.minX, y: crop.maxY),
                     "malformed outside-page destinations are bounded by the visible crop box")

        controller.find("")
        controller.goPage(1)
        controller.goOutline(entries[0]); controller.flush()
        let upper = store.readingPosition(for: "R01")!
        precondition(upper.page == 1 && abs(upper.y - upperPoint.y) < 3,
                     "section navigation lands at its heading rather than the page top")
        controller.goOutline(entries[1]); controller.flush()
        let lower = store.readingPosition(for: "R01")!
        precondition(lower.page == 1 && abs(lower.y - lowerPoint.y) < 3 && upper.y - lower.y > 200,
                     "two outline entries on one page must visibly land at different passages")
        controller.goBack(); controller.flush()
        precondition(abs(store.readingPosition(for: "R01")!.y - upper.y) < 3,
                     "Back restores the previous in-page section, not merely its page")
        controller.goForward(); controller.flush()
        precondition(abs(store.readingPosition(for: "R01")!.y - lower.y) < 3,
                     "Forward restores the second section's exact position")
        controller.goOutline(entries[2]); controller.flush()
        precondition(store.readingPosition(for: "R01")!.page == 2)
        controller.goBack(); controller.flush()
        precondition(store.readingPosition(for: "R01")!.page == 1 && abs(store.readingPosition(for: "R01")!.y - lower.y) < 3,
                     "a cross-page lookup returns to the section that launched it")
        controller.goOutline(PDFOutlineEntry(id: "bad", title: "Invalid page", page: document.pageCount, level: 0))
        controller.flush()
        precondition(controller.canForward && abs(store.readingPosition(for: "R01")!.y - lower.y) < 3,
                     "an invalid outline cannot move the reader or destroy its forward branch")
        print("precise same-page sections, action destinations, unspecified coordinates and outline history verified")
    }

    private static func verifyOutlineRows() {
        let entries = [
            PDFOutlineEntry(id: "a", title: "Method", page: 0, level: 0),
            PDFOutlineEntry(id: "a1", title: "Experiment", page: 1, level: 1),
            PDFOutlineEntry(id: "a1i", title: "Result details", page: 1, level: 3),
            PDFOutlineEntry(id: "a2", title: "Limitations", page: 2, level: 1),
            PDFOutlineEntry(id: "b", title: "Appendix", page: 3, level: 0),
            PDFOutlineEntry(id: "b1", title: "Dataset", page: 3, level: 1)
        ]
        let index = PDFOutlineNavigationIndex(entries: entries)
        precondition(index.ancestors["a1i"] == ["a", "a1"] && index.parentIDs == ["a", "a1", "b"],
                     "publisher outlines may skip numeric levels without inventing ancestors")
        precondition(index.rows(query: "", collapsed: ["a"]).map(\.id) == ["a", "b", "b1"],
                     "collapsing one branch hides all its descendants and retains the next branch")
        precondition(index.rows(query: "  ", collapsed: ["a1"]).map(\.id) == ["a", "a1", "a2", "b", "b1"],
                     "nested collapse retains its parent and neighboring siblings")
        precondition(index.rows(query: "  result  ", collapsed: ["a", "a1"]).map(\.id) == ["a", "a1", "a1i"],
                     "search reveals a matching hidden heading with its ancestor path")
        precondition(index.rows(query: "missing-section", collapsed: []).isEmpty)
        precondition(index.rows(query: "", collapsed: ["a", "a1", "b"]).map(\.id) == ["a", "b"],
                     "clearing search reapplies the existing collapse state")
    }

    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        _=NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let root=URL(fileURLWithPath:CommandLine.arguments[1])
        let temp=FileManager.default.temporaryDirectory.appendingPathComponent("zhiye-pdf-test-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:temp)}
        let s=StudyStore(resourceDirectory:root,dataDirectory:temp)
        s.select("R01")
        let c=PDFController()
        c.view.frame=CGRect(x:0,y:0,width:700,height:850)
        c.load(s.paper!,store:s)
        print("loaded R01")
        try await Task.sleep(nanoseconds:100_000_000)
        precondition(c.view.document != nil,c.loadError ?? "no PDF")
        c.find("  PagedAttention  ")
        precondition(c.searchResult.contains("/") && c.view.currentSelection != nil)
        let count = c.matchCount
        precondition(count > 1)
        c.previousMatch()
        precondition(c.searchResult == "\(count)/\(count)")
        c.nextMatch()
        precondition(c.searchResult == "1/\(count)")
        c.findOrAdvance("PagedAttention")
        c.findIfChanged("  PagedAttention  ")
        precondition(c.searchResult == "2/\(count)", "debounce must not reset an Enter navigation")
        print("matched")
        c.find("__NO_SUCH_PHRASE_20261002__")
        precondition(c.searchResult=="未找到" && c.view.currentSelection==nil && c.matchCount==0)
        c.find("  ")
        precondition(c.searchResult.isEmpty && c.view.currentSelection==nil)
        print("cleared")
        c.goPage(-100)
        let first=c.view.currentPage!
        precondition(c.view.document!.index(for:first)==0)
        print("first page")
        c.goPage(1_000_000)
        precondition(c.view.document!.index(for:c.view.currentPage!)==c.view.document!.pageCount-1)
        c.goPage(1)
        let anchor=s.guide!.concepts[0].anchor
        c.go(anchor)
        precondition(c.hasReturnPoint)
        let priorSelection = c.view.currentSelection!
        precondition(!c.makeNote(kind: "疑问")!.quote.isEmpty, "visible source text remains recordable")
        c.goPage(7)
        precondition(c.view.currentSelection == nil && c.makeNote(kind: "疑问")!.quote.isEmpty)
        c.view.setCurrentSelection(priorSelection, animate: false)
        precondition(c.makeNote(kind: "疑问")!.quote.isEmpty, "an offscreen old selection cannot tag a new note")
        c.returnToReading()
        precondition(c.canForward && c.view.currentSelection == nil, "return preserves a forward path and clears the old selection")
        print("return")
        // Several unrelated lookups can be retraced, with a new jump replacing
        // only the forward branch. The paper's ordinary scroll is not history.
        c.goPage(2);c.goPage(6);c.goPage(10)
        c.goBack()
        precondition(c.view.document!.index(for:c.view.currentPage!) == 5,"first back returns to page 6")
        c.goBack()
        precondition(c.view.document!.index(for:c.view.currentPage!) == 1,"second back returns to page 2")
        c.goForward()
        precondition(c.view.document!.index(for:c.view.currentPage!) == 5)
        c.goPage(8)
        precondition(!c.canForward,"new jump drops the obsolete forward branch")
        c.find("")
        c.goPage(12)
        c.find("Paged");c.find("PagedAtt");c.find("PagedAttention")
        c.goBack()
        precondition(c.view.document!.index(for:c.view.currentPage!) == 11,"incremental search remembers one origin, not each typed prefix")
        verifyOutlineNavigation(c, store: s)
        verifyOutlineRows()
        print("history and outline")
        let note=c.makeNote(kind:"笔记")!
        precondition(note.sourceSHA256==s.paper!.sha256)
        let marked=StudyNote(paperID:"R01",sourceSHA256:s.paper!.sha256,kind:"高亮",body:"",quote:anchor.quote,anchors:[anchor])
        s.upsert(marked);c.refreshMarks()
        let page=c.view.document!.page(at:anchor.page)!
        let owner=PDFAnnotationKey(rawValue:"/PSOwner")
        precondition(page.annotations.contains {$0.value(forAnnotationKey:owner) != nil})
        s.data.notes[0].sourceSHA256="another-version";c.refreshMarks()
        precondition(!page.annotations.contains {$0.value(forAnnotationKey:owner) != nil})
        print("version mismatch removed")
        c.go(anchor)
        let second=s.papers.first {$0.id=="R02"}!
        s.select(second.id);c.load(second,store:s)
        print("loaded R02")
        try await Task.sleep(nanoseconds:100_000_000)
        precondition(!c.hasReturnPoint && !c.canForward && c.searchResult.isEmpty && c.loadedID==second.id)
        print("PASS: PDF search trim/reset/wrap/debounce; one origin for incremental query; bounded back/forward branches; precise section destinations; outline hierarchy/collapse/search; page bounds; stale selection rejected; visible selection retained; source tagging; version mismatch and paper switch reset.")
    }
}
