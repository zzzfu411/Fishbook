import Foundation

@main struct LibraryFeaturesSmoke {
    @MainActor static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("Fishbook-LibraryFeatures-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            if !value() { fatalError(message) }
        }
        let disabledURL = root.appendingPathComponent("failed-migration-target")
        let disabled = LibraryFeatureStore(dataDirectory: disabledURL, enabled: false)
        check(!disabled.ready && !disabled.setQueued("paper-one", true), "failed main library keeps features disabled")
        check(!fm.fileExists(atPath: disabledURL.path), "disabled feature initialization must not create migration target")
        let store = LibraryFeatureStore(dataDirectory: root.appendingPathComponent("valid"))
        let paper = Paper(id: "paper-one", name: "Original", title: "Original full title", file: "one.pdf", pages: 12,
                          sha256: String(repeating: "a", count: 64), area: "Systems", year: 2023)
        let other = Paper(id: "paper-two", name: "Other", title: "Other full title", file: "two.pdf", pages: 9,
                          sha256: String(repeating: "b", count: 64), area: "Storage", year: 2024)
        check(store.ready, "new workspace should load")
        check(store.updateMetadata(paper.id, metadata: PaperMetadata(name: "Renamed", title: "Readable title", area: "Inference", year: 2025)), "metadata saves")
        let display = store.displayPaper(paper)
        check(display.name == "Renamed" && display.year == 2025, "metadata overrides display")
        check(display.id == paper.id && display.sha256 == paper.sha256 && display.file == paper.file, "metadata never changes source identity")
        check(!store.updateMetadata(paper.id, metadata: PaperMetadata(name: " ")), "empty display name rejected")
        check(store.setQueued(paper.id, true), "queue")
        check(store.setArchived(paper.id, true) && !store.entry(for: paper.id).queued, "archive leaves queue")
        check(store.setQueued(paper.id, true) && !store.entry(for: paper.id).archived, "queue unarchives")
        check(store.recordOpened(paper.id) && store.entry(for: paper.id).lastOpened != nil, "recent timestamp")
        check(store.setRemoved(paper.id, true) && store.entry(for: paper.id).removed, "recoverable removal")
        check(store.entry(for: paper.id).queued, "removal preserves collection for recovery")
        check(store.setRemoved(paper.id, false) && !store.entry(for: paper.id).removed, "restore")

        var docNote = StudyNote(paperID: paper.id, sourceSHA256: paper.sha256, kind: "疑问", body: "Explain the mechanism", quote: "Chinese excerpt", anchors: [])
        docNote.documentSource = DocumentNoteSource(documentID: "doc-one", documentTitle: "全文翻译", blockID: "p-52", quote: "Chinese excerpt", blockOffset: 0.4, progress: 0.35, pdfPage: nil)
        check(store.saveDraft(docNote), "document draft saves")
        var reflection = PaperReflection(); reflection.problem = "Memory fragmentation"; reflection.mechanism = "Blocks"; reflection.evidence = "A controlled comparison"
        check(store.saveReflection(reflection, for: paper.id), "reflection saves")
        check(store.addBookmark(paper: paper, page: 4, title: "核心架构") && store.addBookmark(paper: paper, page: 4, title: "机制"), "bookmark saves and deduplicates")
        check(store.bookmarks(for: paper).count == 1 && store.bookmarks(for: paper).first?.title == "机制", "one bookmark per source page")
        check(!store.addBookmark(paper: paper, page: 12), "out of bounds bookmark rejected")
        var replacement = paper; replacement.sha256 = "replacement"
        check(store.bookmarks(for: replacement).isEmpty && store.obsoleteBookmarkCount(for: replacement) == 1, "bookmarks never rebound to changed PDF")

        let reloaded = LibraryFeatureStore(dataDirectory: store.dataURL)
        check(reloaded.ready && reloaded.displayPaper(paper).name == "Renamed", "metadata survives restart")
        check(reloaded.drafts(for: paper.id).first?.documentSource == docNote.documentSource, "draft keeps exact Chinese source without an invented PDF page")
        check(reloaded.drafts(for: paper.id).first?.sourceSHA256 == paper.sha256, "draft keeps PDF fingerprint")
        check(reloaded.reflection(for: paper.id).evidence == reflection.evidence && reloaded.bookmarks(for: paper).first?.page == 4, "study data survives restart")
        check(reloaded.removeDraft(docNote.id) && reloaded.drafts(for: paper.id).isEmpty, "discard removes only draft")
        check(reloaded.data.reflections[paper.id]?.problem == reflection.problem, "discard does not remove other study data")

        let before = try Data(contentsOf: reloaded.stateURL)
        reloaded.setPersistenceSuspended(true)
        check(!reloaded.setRemoved(paper.id, true) && !reloaded.entry(for: paper.id).removed, "restore suspension blocks mutation")
        check(tryData(reloaded.stateURL) == before, "suspension never touches disk")
        reloaded.setPersistenceSuspended(false)

        // Simulate a failed atomic destination without modifying the persisted checkpoint.
        try fm.removeItem(at: reloaded.stateURL)
        try fm.createDirectory(at: reloaded.stateURL, withIntermediateDirectories: false)
        check(!reloaded.setRemoved(paper.id, true) && !reloaded.entry(for: paper.id).removed, "failed write rolls back removal")
        var unsaved = reflection; unsaved.mechanism = "Keep this unsaved explanation"
        check(!reloaded.saveReflection(unsaved, for: paper.id), "reflection write failure is explicit")
        check(reloaded.data.reflections[paper.id]?.mechanism == reflection.mechanism, "failed reflection is not presented as persisted")
        check(reloaded.reflection(for: paper.id).mechanism == unsaved.mechanism && reloaded.hasPendingChanges, "failed reflection text remains available for retry")
        try fm.removeItem(at: reloaded.stateURL)
        try before.write(to: reloaded.stateURL, options: .atomic)
        check(reloaded.flushPendingChanges() && !reloaded.hasPendingChanges, "pending reflection can retry transactionally")

        // A stale second instance must not overwrite another instance's successful save.
        let otherInstance = LibraryFeatureStore(dataDirectory: reloaded.dataURL)
        check(reloaded.setQueued(other.id, true), "first instance commits")
        let newer = try Data(contentsOf: reloaded.stateURL)
        check(!otherInstance.setRemoved(paper.id, true), "stale second instance refuses overwrite")
        check(tryData(reloaded.stateURL) == newer, "newer state preserved")

        let legacyURL = root.appendingPathComponent("defaults")
        try fm.createDirectory(at: legacyURL, withIntermediateDirectories: true)
        try Data("{\"version\":1,\"papers\":{\"paper-one\":{\"queued\":true}}}".utf8).write(to: legacyURL.appendingPathComponent("workspace.json"))
        let defaults = LibraryFeatureStore(dataDirectory: legacyURL)
        check(defaults.ready && defaults.entry(for: paper.id).queued && defaults.data.bookmarks.isEmpty, "missing optional fields decode to safe defaults")
        let lowercaseURL = root.appendingPathComponent("lowercase-draft")
        try fm.createDirectory(at: lowercaseURL, withIntermediateDirectories: true)
        var lowercaseData = LibraryFeatureData(); lowercaseData.drafts[docNote.id.uuidString.lowercased()] = docNote
        try JSONEncoder().encode(lowercaseData).write(to: lowercaseURL.appendingPathComponent("workspace.json"))
        let lowercase = LibraryFeatureStore(dataDirectory: lowercaseURL)
        check(lowercase.ready && lowercase.removeDraft(docNote.id) && lowercase.drafts(for: paper.id).isEmpty, "draft UUID keys normalize without losing deletion")
        for (name, body) in [("damaged", "{broken"), ("future", "{\"version\":999}"), ("wrong-type", "{\"version\":1,\"bookmarks\":\"wrong\"}")] {
            let dir = root.appendingPathComponent(name)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("workspace.json"), bytes = Data(body.utf8)
            try bytes.write(to: file)
            let broken = LibraryFeatureStore(dataDirectory: dir)
            check(!broken.ready && !broken.setQueued(paper.id, true), "bad workspace disabled")
            check(tryData(file) == bytes, "bad workspace retained exactly")
        }

        var solved = docNote; solved.id = UUID(); solved.resolved = true; solved.body = "Resolved explanation"
        var second = docNote; second.id = UUID(); second.paperID = other.id; second.body = "Other paper problem"
        let free = StudyNote(paperID: paper.id, kind: "笔记", body: "Unanchored idea", quote: "", anchors: [])
        let notes = [docNote, solved, second, free]
        check(NoteExport.select(.currentPaper(paper.id), notes: notes).count == 3, "current paper export excludes other papers")
        check(NoteExport.select(.unresolved, notes: notes).count == 2, "unresolved export excludes solved and ordinary notes")
        check(NoteExport.select(.selection([solved.id]), notes: notes).map(\.id) == [solved.id], "selected export exact")
        check(NoteExport.sourceLabel(docNote) == "全文翻译" && NoteExport.sourceLabel(free) == "自由记录", "source labels do not invent p1")
        let output = NoteExport.markdown(scope: .selection([docNote.id]), notes: notes, papers: [paper, other], reflections: [paper.id: reflection])
        check(output.contains("Chinese excerpt") && output.contains("来源：全文翻译") && !output.contains("Other paper problem") && !output.contains("Memory fragmentation") && !output.contains("p-52"), "selection export preserves readable source without internal IDs or unrelated data")
        let all = NoteExport.markdown(scope: .all, notes: notes, papers: [paper, other], reflections: [paper.id: reflection])
        check(all.contains("Memory fragmentation") && all.contains("Other paper problem") && !all.contains("PDF 第 1 页"), "all export includes reflections without invented page")
        print("PASS: library metadata, recoverable organization, transactional writes, damaged/stale protection, drafts, reflections, source bookmarks and scoped exports")
    }
    static func tryData(_ url: URL) -> Data? { try? Data(contentsOf: url) }
}
