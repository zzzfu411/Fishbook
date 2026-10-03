import Foundation
import PDFKit

@main struct ReaderWorkflow {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("fishbook-workflow-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let store = StudyStore(resourceDirectory: root, dataDirectory: temp.appendingPathComponent("data"))
        let initial = store.papers.count
        func sample(_ name: String, pages: Int) throws -> URL {
            let pdf = PDFDocument()
            for index in 0..<pages {
                let page = PDFPage(); page.setBounds(CGRect(x: 0, y: 0, width: 600, height: 800), for: .mediaBox)
                pdf.insert(page, at: index)
            }
            let url = temp.appendingPathComponent(name + ".pdf")
            try pdf.dataRepresentation()!.write(to: url)
            return url
        }
        let first = try sample("first", pages: 1), second = try sample("second", pages: 2)
        let broken = temp.appendingPathComponent("broken.pdf")
        try Data("not a PDF".utf8).write(to: broken)
        await store.importPDFAsync([first, broken, second, first])
        precondition(!store.isImporting && store.importProgress.isEmpty)
        precondition(store.importResults.map(\.outcome) == [.added, .failed, .added, .existing])
        precondition(store.papers.count == initial + 2 && store.data.importedPapers.count == 2)
        let files = try FileManager.default.contentsOfDirectory(atPath: temp.appendingPathComponent("data/imports").path)
        precondition(files.count == 2, "Failed or duplicate imports must not leave extra copies")
        let restarted = StudyStore(resourceDirectory: root, dataDirectory: store.dataURL)
        precondition(restarted.papers.count == initial + 2 && restarted.paper?.name == "first")
        var question = StudyNote(paperID: "R01", sourceSHA256: "older-pdf", kind: "疑问", body: "这个机制为什么有效？", quote: "", anchors: [])
        precondition(store.upsert(question))
        precondition(store.unresolvedPaperIDs == ["R01"] && store.unresolvedCount(for: "R01") == 1)
        precondition(store.toggleResolved(question.id) && store.unresolvedPaperIDs.isEmpty)
        precondition(store.data.notes.first?.sourceSHA256 == "older-pdf", "Resolving does not silently rebind a source")
        precondition(store.toggleResolved(question.id) && store.unresolvedCount(for: "R01") == 1)
        question.id = UUID(); question.kind = "笔记"
        precondition(store.upsert(question) && !store.toggleResolved(question.id))
        precondition(store.unresolvedCount(for: "R01") == 1, "Notes must not count as unresolved questions")
        try FileManager.default.removeItem(at: store.stateURL)
        try FileManager.default.createDirectory(at: store.stateURL, withIntermediateDirectories: true)
        let id = store.data.notes.first!.id
        precondition(!store.toggleResolved(id) && store.data.notes.first?.resolved == false)
        precondition(store.saveFailed && store.notice == nil, "A failed resolve must retain the question and never claim success")
        print("PASS: async good/bad/good/duplicate import continues, deduplicates and survives restart; unresolved filters and resolve/reopen preserve source identity; failed resolve rolls back.")
    }
}
