import Foundation
import Darwin

/// Runs entirely in temporary fixtures; no bundled papers or user records are changed.
@main struct DocumentRevisions {
    @MainActor static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("Fishbook-DocumentRevisions-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let resources = root.appendingPathComponent("resources")
        let bundledRoot = resources.appendingPathComponent("content/documents")
        let inputs = root.appendingPathComponent("inputs")
        try fm.createDirectory(at: bundledRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: inputs, withIntermediateDirectories: true)
        let paper = Paper(id: "paper-one", name: "One", title: "First paper", file: "one.pdf", pages: 20,
                          sha256: String(repeating: "a", count: 64), area: "Systems", year: 2023)
        let other = Paper(id: "paper-two", name: "Two", title: "Second paper", file: "two.pdf", pages: 10,
                          sha256: String(repeating: "b", count: 64), area: "Systems", year: 2024)
        let papers = [paper, other]
        let baseTranslation = StudyDocument(id: "bundled-translation", paperID: paper.id, sha256: paper.sha256,
            kind: .translation, title: "内置全文译稿", status: "complete", coverage: "全文", relativePath: "translation.md")
        let baseExplanation = StudyDocument(id: "bundled-explanation", paperID: paper.id, sha256: paper.sha256,
            kind: .explanation, title: "内置机制导读", status: "partial", coverage: "关键机制", relativePath: "explanation.md")
        let bundledTranslationText = "# 内置译稿\n\n## 原文第 7 页\n\n原始内容，不应被更新覆盖。\n"
        try bundledTranslationText.write(to: bundledRoot.appendingPathComponent("translation.md"), atomically: true, encoding: .utf8)
        try "# 机制导读\n\n关键机制。\n".write(to: bundledRoot.appendingPathComponent("explanation.md"), atomically: true, encoding: .utf8)
        try JSONEncoder().encode([baseTranslation, baseExplanation]).write(to: bundledRoot.appendingPathComponent("index.json"))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var failures: [String] = []
        func expect(_ value: Bool, _ message: String) {
            if !value { failures.append(message); print("FAIL: " + message) }
        }
        func markdown(_ name: String, _ content: String) throws -> URL {
            let url = inputs.appendingPathComponent(name)
            try content.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        func folders(_ documents: DocumentStore) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: documents.importedRoot.path)) ?? []).sorted()
        }
        func bytes(_ url: URL) -> Data? { try? Data(contentsOf: url) }
        func store(_ name: String) -> DocumentStore {
            let value = DocumentStore(resources: resources, dataURL: root.appendingPathComponent(name))
            value.load(papers: papers)
            return value
        }
        let docs = store("state")
        expect(docs.ready && docs.warnings.isEmpty, "controlled bundled material loads")
        expect(docs.currentList(for: paper, kind: .translation) == [baseTranslation], "bundled document initially current")
        expect(docs.selectedID(for: paper, kind: .translation) == baseTranslation.id, "complete bundled translation selected by default")

        // A new material is a new independent document, and the copy survives removal of its source.
        let firstText = "# 新导读第一版\n\n## 原文第 7 页\n\n稳定段落文字：机制把连续空间拆成独立块。\n"
        let firstSource = try markdown("first.md", firstText)
        expect(docs.importMarkdown(firstSource, paper: paper, kind: .explanation, title: "我的机制笔记"), "new material import succeeds")
        guard let first = docs.selected(for: paper, kind: .explanation), first.id != baseExplanation.id,
              let firstURL = docs.url(for: first) else { throw StudyError.message("New document fixture not available") }
        expect(first.revision == 1 && first.previousRevisionID == nil && first.importedAt != nil, "new material starts revision 1 without a parent")
        expect(first.status == "unverified" && docs.mode(for: paper.id) == "explanation", "import selects correct mode without claiming translation completeness")
        expect(docs.currentList(for: paper, kind: .explanation).count == 2, "independent materials stay independently current")
        try fm.removeItem(at: firstSource)
        expect(bytes(firstURL) == Data(firstText.utf8), "imported original remains self-contained")
        let semantic = DocumentReadingLocation(blockID: "stable-paragraph-7", quote: "机制把连续空间拆成独立块", blockOffset: 0.27, progress: 0.43, pdfPage: 6)
        docs.setLocation(semantic, documentID: first.id)
        expect(docs.flushProgress(), "semantic position commits")
        expect(docs.progress(for: first.id) == semantic.progress, "semantic position also updates fallback progress")

        // Updating always creates a new revision; a selected old revision remains addressable.
        let secondText = "# 新导读第二版\n\n新增的前置解释。\n\n## 原文第 7 页\n\n稳定段落文字：机制把连续空间拆成独立块。\n"
        let secondSource = try markdown("second.md", secondText)
        expect(docs.importMarkdown(secondSource, paper: paper, kind: .explanation, updating: first, title: "我的机制笔记 · 修订"), "revision update succeeds")
        guard let second = docs.selected(for: paper, kind: .explanation), second.id != first.id,
              let secondURL = docs.url(for: second) else { throw StudyError.message("Second revision fixture not available") }
        expect(second.previousRevisionID == first.id && second.revision == 2, "revision records exact predecessor and number")
        expect(docs.isHistorical(first) && !docs.isHistorical(second), "only predecessor is historical")
        expect(bytes(firstURL) == Data(firstText.utf8) && bytes(secondURL) == Data(secondText.utf8), "update preserves original file and stores new copy")
        expect(docs.location(for: second.id) == semantic && docs.progress(for: second.id) == semantic.progress, "revision inherits exact semantic source and fallback progress")
        expect(!docs.currentList(for: paper, kind: .explanation).contains(first) && docs.currentList(for: paper, kind: .explanation).contains(second), "currentList hides superseded revision")
        expect(docs.list(for: paper, kind: .explanation).contains(first), "historical material stays in complete list")
        docs.select(first.id, paper: paper, kind: .explanation)
        expect(docs.selectedID(for: paper, kind: .explanation) == first.id, "user can explicitly select old revision")
        let oldPosition = DocumentReadingLocation(blockID: "old-introduction", quote: "旧版开头", blockOffset: 0.1, progress: 0.08)
        docs.setLocation(oldPosition, documentID: first.id); expect(docs.flushProgress(), "old revision keeps independent position")
        expect(docs.location(for: second.id) == semantic, "moving old revision does not move new revision")
        let restart = DocumentStore(resources: resources, dataURL: docs.dataURL); restart.load(papers: papers)
        expect(restart.selectedID(for: paper, kind: .explanation) == first.id, "historical selection survives restart")
        expect(restart.location(for: first.id) == oldPosition && restart.location(for: second.id) == semantic, "both revision positions survive restart")
        let thirdSource = try markdown("third.md", "# 新导读第三版\n\n整理后的内容。\n")
        expect(restart.importMarkdown(thirdSource, paper: paper, kind: .explanation, updating: second), "a second update succeeds")
        guard let third = restart.selected(for: paper, kind: .explanation), third.id != second.id else { throw StudyError.message("Third revision fixture not available") }
        expect(third.revision == 3 && third.previousRevisionID == second.id && restart.location(for: third.id) == semantic, "revision chain increments and keeps semantic position")
        let currentIDs = Set(restart.currentList(for: paper, kind: .explanation).map(\.id))
        expect(currentIDs == [baseExplanation.id, third.id], "current list retains independent material and latest chain head only")

        // Built-in materials can be revised without mutating app resources; progress-only states still work.
        restart.setProgress(0.61, documentID: baseTranslation.id); expect(restart.flushProgress(), "legacy progress commits")
        let translationSource = try markdown("translation-update.md", "# 校订全文\n\n校订后的译文。\n")
        expect(restart.importMarkdown(translationSource, paper: paper, kind: .translation, updating: baseTranslation), "built-in translation can be revised")
        guard let updatedTranslation = restart.selected(for: paper, kind: .translation) else { throw StudyError.message("Translation revision missing") }
        expect(updatedTranslation.previousRevisionID == baseTranslation.id && updatedTranslation.revision == 2, "unversioned built-in begins update at revision 2")
        expect(restart.progress(for: updatedTranslation.id) == 0.61 && restart.location(for: updatedTranslation.id) == nil, "progress-only fallback inherited without fabricated semantic location")
        expect(bytes(bundledRoot.appendingPathComponent("translation.md")) == Data(bundledTranslationText.utf8), "bundled source is never overwritten")
        expect(restart.currentList(for: paper, kind: .translation).map(\.id) == [updatedTranslation.id], "translation current list points at revised material")

        // Guide concepts use separate stable progress keys, including overview; unknown papers cannot write them.
        let guideOverview = "guide:\(paper.id):overview", guideConcept = "guide:\(paper.id):cache-blocks"
        let guideLocation = DocumentReadingLocation(blockID: "mechanism-step-3", quote: "给逻辑块寻找物理块", blockOffset: 0.32, progress: 0.72)
        restart.setLocation(guideLocation, documentID: guideConcept)
        restart.setProgress(0.25, documentID: guideOverview)
        restart.setLocation(guideLocation, documentID: "guide:unknown-paper:cache-blocks")
        restart.setProgress(0.5, documentID: "guide:\(paper.id)-extra:overview")
        expect(restart.flushProgress(), "guide positions flush")
        let guideRestart = DocumentStore(resources: resources, dataURL: restart.dataURL); guideRestart.load(papers: papers)
        expect(guideRestart.location(for: guideConcept) == guideLocation && guideRestart.progress(for: guideOverview) == 0.25, "concept and overview progress persist independently")
        expect(guideRestart.location(for: "guide:unknown-paper:cache-blocks") == nil && guideRestart.progress(for: "guide:\(paper.id)-extra:overview") == 0, "unknown guide papers cannot create positions")
        guideRestart.selectInteractiveGuide(for: paper)
        expect(guideRestart.prefersInteractiveGuide(for: paper), "explicit interactive guide selection supported alongside Markdown")
        guideRestart.select(first.id, paper: paper, kind: .explanation)
        expect(!guideRestart.prefersInteractiveGuide(for: paper) && guideRestart.selectedID(for: paper, kind: .explanation) == first.id, "explicit historical Markdown replaces interactive preference")

        // Legacy v0.6 JSON omits semantic locations and all revision fields.
        let legacyDir = root.appendingPathComponent("legacy"), legacyID = "legacy-import"
        let legacyFile = legacyDir.appendingPathComponent("documents/\(legacyID)/document.md")
        try fm.createDirectory(at: legacyFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# 旧版导读\n\n旧用户材料。\n".write(to: legacyFile, atomically: true, encoding: .utf8)
        let legacyObject: [String: Any] = ["version": 1,
            "imported": [["id": legacyID, "paperID": paper.id, "sha256": paper.sha256, "kind": "explanation", "title": "旧版导读", "status": "unverified", "coverage": "旧用户材料", "relativePath": "\(legacyID)/document.md"]],
            "modes": [paper.id: "explanation"], "selections": [paper.id + ":explanation": legacyID], "progress": [legacyID: 0.62]]
        try JSONSerialization.data(withJSONObject: legacyObject).write(to: legacyDir.appendingPathComponent("documents.json"))
        let legacy = DocumentStore(resources: resources, dataURL: legacyDir); legacy.load(papers: papers)
        expect(legacy.ready && legacy.warnings.isEmpty && legacy.location(for: legacyID) == nil, "legacy document JSON reads without new fields")
        expect(legacy.selectedID(for: paper, kind: .explanation) == legacyID && legacy.progress(for: legacyID) == 0.62, "legacy selected document and progress retained")
        guard let legacyItem = legacy.document(id: legacyID) else { throw StudyError.message("Legacy fixture missing") }
        expect(legacyItem.revision == nil && legacyItem.previousRevisionID == nil && legacyItem.importedAt == nil, "legacy document does not invent revision metadata")
        expect(legacy.importMarkdown(thirdSource, paper: paper, kind: .explanation, updating: legacyItem), "legacy imported material can be updated")
        if let revision = legacy.selected(for: paper, kind: .explanation) {
            expect(revision.revision == 2 && legacy.progress(for: revision.id) == 0.62, "legacy update continues at revision 2 with fallback position")
        }
        let minimal = try JSONDecoder().decode(DocumentUserState.self, from: Data("{}".utf8))
        expect(minimal.version == 1 && minimal.imported.isEmpty && minimal.locations.isEmpty, "missing optional state fields receive safe defaults")

        // Wrong paper, source version, kind, unknown predecessor and missing images leave state/files unchanged.
        let beforeReject = try encoder.encode(guideRestart.state)
        let rejectDisk = bytes(guideRestart.stateURL), rejectFolders = folders(guideRestart)
        expect(!guideRestart.importMarkdown(thirdSource, paper: other, kind: .explanation, updating: third), "cannot update a document using another paper")
        var wrongVersion = paper; wrongVersion.sha256 = String(repeating: "c", count: 64)
        expect(!guideRestart.importMarkdown(thirdSource, paper: wrongVersion, kind: .explanation, updating: third), "cannot update across PDF fingerprints")
        expect(!guideRestart.importMarkdown(thirdSource, paper: paper, kind: .translation, updating: third), "cannot update across material kinds")
        var unknown = third; unknown.id = "not-in-catalog"
        expect(!guideRestart.importMarkdown(thirdSource, paper: paper, kind: .explanation, updating: unknown), "unknown predecessor rejected")
        let missingImage = try markdown("missing-image.md", "# 更新失败\n\n![missing](assets/missing.png)\n")
        expect(!guideRestart.importMarkdown(missingImage, paper: paper, kind: .explanation, updating: third), "missing image aborts update")
        expect(try encoder.encode(guideRestart.state) == beforeReject, "invalid update leaves selections/progress/revisions unchanged")
        expect(bytes(guideRestart.stateURL) == rejectDisk && folders(guideRestart) == rejectFolders, "invalid update creates no persisted partial material")

        // Failed final JSON commit rolls back both model and newly copied resource directory.
        let writeSnapshot = try encoder.encode(guideRestart.state), writeDocuments = guideRestart.documents
        let writeBytes = try Data(contentsOf: guideRestart.stateURL), writeFolders = folders(guideRestart)
        try fm.removeItem(at: guideRestart.stateURL)
        try fm.createDirectory(at: guideRestart.stateURL, withIntermediateDirectories: false)
        expect(!guideRestart.importMarkdown(thirdSource, paper: paper, kind: .explanation, updating: third), "failed final commit returns failure")
        expect(try encoder.encode(guideRestart.state) == writeSnapshot && guideRestart.documents == writeDocuments, "failed final commit rolls back published model")
        expect(folders(guideRestart) == writeFolders && bytes(firstURL) == Data(firstText.utf8), "failed commit cleans new copy and preserves historical original")
        try fm.removeItem(at: guideRestart.stateURL)
        try writeBytes.write(to: guideRestart.stateURL, options: .atomic)
        expect(guideRestart.importMarkdown(thirdSource, paper: paper, kind: .explanation, updating: third), "update can retry after storage recovers")
        expect(guideRestart.selected(for: paper, kind: .explanation)?.revision == 4, "failed attempt does not consume a revision")

        // Restoration suspends every write, including imports and progress callbacks.
        let suspended = try encoder.encode(guideRestart.state), suspendedBytes = bytes(guideRestart.stateURL), suspendedFolders = folders(guideRestart)
        guideRestart.setPersistenceSuspended(true)
        guideRestart.setLocation(guideLocation, documentID: first.id)
        guideRestart.setProgress(0.95, documentID: guideOverview)
        expect(!guideRestart.importMarkdown(thirdSource, paper: paper, kind: .explanation), "suspended store refuses new materials")
        expect(!guideRestart.flushProgress(), "suspended progress cannot flush")
        expect(try encoder.encode(guideRestart.state) == suspended && bytes(guideRestart.stateURL) == suspendedBytes && folders(guideRestart) == suspendedFolders, "suspension leaves model and resources unchanged")
        guideRestart.setPersistenceSuspended(false)

        // The predecessor is a source record, not caller-supplied metadata with a matching id.
        let strict = store("strict-update")
        var forged = baseExplanation; forged.paperID = other.id; forged.sha256 = other.sha256
        let strictBefore = try encoder.encode(strict.state)
        expect(!strict.importMarkdown(thirdSource, paper: other, kind: .explanation, updating: forged), "matching id cannot forge predecessor into another paper")
        expect(try encoder.encode(strict.state) == strictBefore, "forged predecessor cannot change state")

        // Invalid semantic page indices must not poison future backup validation.
        let semanticStore = store("semantic-validation")
        semanticStore.setLocation(semantic, documentID: baseExplanation.id)
        expect(semanticStore.flushProgress(), "valid semantic fixture commits")
        var invalid = semantic; invalid.pdfPage = -1
        semanticStore.setLocation(invalid, documentID: baseExplanation.id)
        expect(semanticStore.location(for: baseExplanation.id) == semantic, "negative semantic PDF page rejected on write")
        invalid = semantic; invalid.blockOffset = 1.2
        semanticStore.setLocation(invalid, documentID: baseExplanation.id)
        expect(semanticStore.location(for: baseExplanation.id) == semantic, "out-of-range semantic offset rejected")
        invalid = semantic; invalid.progress = .nan
        semanticStore.setLocation(invalid, documentID: baseExplanation.id)
        expect(semanticStore.location(for: baseExplanation.id) == semantic, "nonfinite semantic progress rejected")
        let invalidDir = root.appendingPathComponent("invalid-semantic-on-disk")
        try fm.createDirectory(at: invalidDir, withIntermediateDirectories: true)
        var invalidState = DocumentUserState(); invalid = semantic; invalid.pdfPage = -1; invalidState.locations[baseExplanation.id] = invalid
        let invalidBytes = try encoder.encode(invalidState)
        try invalidBytes.write(to: invalidDir.appendingPathComponent("documents.json"))
        let invalidLoaded = DocumentStore(resources: resources, dataURL: invalidDir)
        expect(!invalidLoaded.ready && !invalidLoaded.save(), "negative semantic PDF page rejected on load")
        expect(bytes(invalidLoaded.stateURL) == invalidBytes, "invalid semantic state retained for recovery")

        if !failures.isEmpty {
            print("Document revisions checks: \(failures.count) failed.")
            exit(1)
        }
        print("PASS: document revisions/history, old-version selection, semantic inheritance/restart, legacy JSON, source identity rejection, guide progress, copy/commit rollback and restoration suspension")
    }
}
