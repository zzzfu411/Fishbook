import Foundation

@main struct DocumentsSmoke {
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("zhiye-documents-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let store = StudyStore(resourceDirectory: root, dataDirectory: temp.appendingPathComponent("data"))
        precondition(store.ready)
        let docs = DocumentStore(resources: root, dataURL: store.dataURL)
        docs.load(papers: store.papers)
        precondition(docs.ready && docs.warnings.isEmpty, docs.warnings.joined(separator: "\n"))
        let paper = store.papers.first(where: { $0.id == "R01" })!
        // Content grows independently of the app. Exercise the empty translation
        // case with a controlled explanation-only library, not a real paper ID.
        let explanationRoot = temp.appendingPathComponent("explanation-only/content/documents")
        try FileManager.default.createDirectory(at: explanationRoot, withIntermediateDirectories: true)
        try "# 重点导读\n这是一份解释。".write(to: explanationRoot.appendingPathComponent("guide.md"), atomically: true, encoding: .utf8)
        let explanation = StudyDocument(id: "fixture-guide", paperID: paper.id, sha256: paper.sha256, kind: .explanation,
                                        title: "重点导读", status: "partial", coverage: "仅解释关键机制", relativePath: "guide.md")
        try JSONEncoder().encode([explanation]).write(to: explanationRoot.appendingPathComponent("index.json"))
        let explanationOnly = DocumentStore(resources: temp.appendingPathComponent("explanation-only"), dataURL: temp.appendingPathComponent("explanation-state"))
        explanationOnly.load(papers: store.papers)
        precondition(explanationOnly.list(for: paper, kind: .explanation).count == 1)
        precondition(explanationOnly.list(for: paper, kind: .translation).isEmpty, "Do not label an explanation as full translation")

        let source = temp.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("assets"), withIntermediateDirectories: true)
        let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=")!
        try image.write(to: source.appendingPathComponent("assets/example.png"))
        let markdown = "# 我的译文\n\n## 原文第 3 页\n\n这是测试文档。\n\n![测试图](assets/example.png)\n"
        let original = source.appendingPathComponent("test.md")
        try markdown.write(to: original, atomically: true, encoding: .utf8)
        precondition(docs.importMarkdown(original, paper: paper, kind: .translation), docs.error ?? "import failed")
        let imported = docs.selected(for: paper, kind: .translation)!
        precondition(imported.status == "unverified" && imported.sha256 == paper.sha256)
        precondition(docs.mode(for: paper.id) == "translation")
        let copy = docs.url(for: imported)!
        try FileManager.default.removeItem(at: source)
        let importedText = try String(contentsOf: copy, encoding: .utf8)
        precondition(importedText == markdown)
        precondition(FileManager.default.fileExists(atPath: copy.deletingLastPathComponent().appendingPathComponent("assets/example.png").path))
        docs.setProgress(0.63, documentID: imported.id); docs.flushProgress()
        let restarted = DocumentStore(resources: root, dataURL: store.dataURL)
        restarted.load(papers: store.papers)
        precondition(restarted.selectedID(for: paper, kind: .translation) == imported.id)
        precondition(restarted.progress(for: imported.id) == 0.63)
        precondition(restarted.mode(for: paper.id) == "translation")
        precondition(!FileManager.default.fileExists(atPath: store.stateURL.path), "Document import must not rewrite personal notes")

        // Different PDF version cannot reuse the old material.
        var replaced = paper; replaced.sha256 = String(repeating: "a", count: 64)
        restarted.load(papers: store.papers.map { $0.id == paper.id ? replaced : $0 })
        precondition(restarted.list(for: replaced, kind: .translation).isEmpty)
        precondition(!restarted.warnings.isEmpty)
        precondition(FileManager.default.fileExists(atPath: copy.path))

        // Path traversal and symlink escapes are rejected.
        for path in ["../outside.png", "/etc/passwd", "%2e%2e/outside.png", "assets/../../outside.png"] {
            do { _ = try DocumentStore.containedURL(path, root: temp); preconditionFailure("Accepted unsafe path") }
            catch { }
        }
        try FileManager.default.createSymbolicLink(at: temp.appendingPathComponent("escape"), withDestinationURL: URL(fileURLWithPath: "/etc"))
        do { _ = try DocumentStore.containedURL("escape/passwd", root: temp); preconditionFailure("Accepted symlink escape") }
        catch { }

        let badMD = temp.appendingPathComponent("remote.md")
        try "# Test\n![image](https://example.invalid/track.png)".write(to: badMD, atomically: true, encoding: .utf8)
        let before = docs.documents.count
        precondition(!docs.importMarkdown(badMD, paper: paper, kind: .explanation))
        precondition(docs.documents.count == before)
        try "# Markdown 语法讲解\n\n```markdown\n![例子](https://example.invalid/only-code.png)\n```\n\n`![图](missing.png)`\n".write(to: badMD, atomically: true, encoding: .utf8)
        precondition(docs.importMarkdown(badMD, paper: paper, kind: .explanation), "Image examples in code must not be imported")
        let exampleDocument = docs.selected(for: paper, kind: .explanation)!
        precondition(!docs.prefersInteractiveGuide(for: paper))
        try FileManager.default.removeItem(at: docs.url(for: exampleDocument)!)
        docs.load(papers: store.papers)
        precondition(docs.prefersInteractiveGuide(for: paper), "Missing selected Markdown must fall back to usable interactive guide")

        // A broken optional index does not destroy previously imported material.
        let fixture = temp.appendingPathComponent("fixture/content/documents")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        try Data("{broken".utf8).write(to: fixture.appendingPathComponent("index.json"))
        let badIndex = DocumentStore(resources: temp.appendingPathComponent("fixture"), dataURL: store.dataURL)
        badIndex.load(papers: store.papers)
        precondition(badIndex.ready && badIndex.documents.contains(where: { $0.id == imported.id }))
        precondition(!badIndex.warnings.isEmpty)
        try Data("[null,42,\"invalid\",{}]".utf8).write(to: fixture.appendingPathComponent("index.json"))
        badIndex.load(papers: store.papers)
        precondition(badIndex.ready && badIndex.warnings.filter { $0.hasPrefix("内置文档第") }.count == 4)
        precondition(badIndex.documents.contains(where: { $0.id == imported.id }))

        // Corrupt persistent state must never be replaced by defaults.
        let corrupt = temp.appendingPathComponent("corrupt")
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        let broken = Data("do not overwrite".utf8)
        try broken.write(to: corrupt.appendingPathComponent("documents.json"))
        let brokenStore = DocumentStore(resources: root, dataURL: corrupt)
        brokenStore.load(papers: store.papers)
        precondition(!brokenStore.ready && !brokenStore.save())
        let retainedBroken = try Data(contentsOf: corrupt.appendingPathComponent("documents.json"))
        precondition(retainedBroken == broken)

        // A failed commit does not publish or retain a half-imported document.
        let failData = temp.appendingPathComponent("unwritable")
        let failStore = DocumentStore(resources: root, dataURL: failData)
        failStore.load(papers: store.papers)
        try FileManager.default.createDirectory(at: failData.appendingPathComponent("documents.json"), withIntermediateDirectories: true)
        try "# 保存失败测试\n正文。".write(to: badMD, atomically: true, encoding: .utf8)
        precondition(!failStore.importMarkdown(badMD, paper: paper, kind: .explanation))
        precondition(failStore.state.imported.isEmpty && failStore.saveFailed)
        precondition(!failStore.flushProgress(), "Backup preflight must observe a failed document save")
        let remnants = try FileManager.default.contentsOfDirectory(atPath: failData.appendingPathComponent("documents").path)
        precondition(remnants.isEmpty)
        print("PASS: real document coverage, local image copy, source removal, selection/progress restart, PDF fingerprint mismatch, path/symlink bounds, remote image rejection, bad index isolation, corrupt-state preservation, failed-import rollback.")
    }
}
