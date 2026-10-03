import Foundation
import PDFKit
import CryptoKit

/// Exercises a clean public checkout, without the maintainer's bundled papers.
@main struct PublicLibrary {
    @MainActor static func main() async throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Fishbook-Public-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let data = temporary.appendingPathComponent("library")
        let store = StudyStore(resourceDirectory: resources, dataDirectory: data)
        precondition(store.ready && store.error == nil && store.contentWarnings.isEmpty)
        precondition(store.papers.isEmpty && store.selectedID == nil && store.guides.isEmpty)
        let documents = DocumentStore(resources: resources, dataURL: data)
        documents.load(papers: store.papers)
        precondition(documents.ready && documents.documents.isEmpty && documents.warnings.isEmpty)

        let vendor = resources.appendingPathComponent("content/reader-vendor")
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: vendor.appendingPathComponent("manifest.json"))) as! [String: Any]
        for (file, expected) in manifest["files"] as! [String: String] {
            let bytes = try Data(contentsOf: vendor.appendingPathComponent(file))
            precondition(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == expected)
        }

        let pdf = PDFDocument()
        for index in 0..<2 {
            let page = PDFPage()
            page.setBounds(CGRect(x: 0, y: 0, width: 600, height: 800), for: .mediaBox)
            pdf.insert(page, at: index)
        }
        let input = temporary.appendingPathComponent("original.pdf")
        let original = pdf.dataRepresentation()!
        try original.write(to: input)
        await store.importPDFAsync([input])
        precondition(store.error == nil && store.papers.count == 1 && store.paper?.pages == 2)
        let paper = store.paper!
        let note = StudyNote(paperID: paper.id, sourceSHA256: paper.sha256, kind: "笔记",
            body: "公开构建测试：保留中文批注。", quote: "",
            anchors: [Anchor(page: 1, rects: [], quote: "")], markupColor: .green)
        precondition(store.upsert(note))
        let markdown = temporary.appendingPathComponent("explanation.md")
        try "# 阅读笔记\n\n[查看原文](zhiye://page/2)\n\n用自己的话解释方法。\n".write(to: markdown, atomically: true, encoding: .utf8)
        documents.load(papers: store.papers)
        precondition(documents.importMarkdown(markdown, paper: paper, kind: .explanation, title: "我的讲解"))

        let reopened = StudyStore(resourceDirectory: resources, dataDirectory: data)
        precondition(reopened.ready && reopened.paper?.id == paper.id && reopened.notes.first?.body == note.body)
        let reopenedDocuments = DocumentStore(resources: resources, dataURL: data)
        reopenedDocuments.load(papers: reopened.papers)
        precondition(reopenedDocuments.selected(for: paper, kind: .explanation)?.title == "我的讲解")
        let exported = try PDFAnnotationSupport.annotatedData(source: original, notes: reopened.annotationNotes(for: paper.id))
        let exportDocument = PDFDocument(data: exported)!
        precondition(exportDocument.pageCount == 2 && exportDocument.page(at: 1)!.annotations.contains { $0.contents == note.body })
        let savedOriginal = try Data(contentsOf: store.fileURL(paper))
        precondition(savedOriginal == original)
        print("PASS: empty public library, vendored resource hashes, PDF import, companion material, restart and annotated export; original PDF unchanged.")
    }
}
