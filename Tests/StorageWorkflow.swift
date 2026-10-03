import Foundation
import PDFKit
import CryptoKit

@main struct StorageWorkflow {
    @MainActor static func main() throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("fishbook-storage-v07-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        func write<T: Encodable>(_ value: T, _ url: URL) throws {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(value).write(to: url, options: .atomic)
        }
        func object(_ value: [String: Any], _ url: URL) throws {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url, options: .atomic)
        }
        func rejected(_ label: String, _ body: () throws -> Void) {
            do { try body(); fatalError("Expected rejection: " + label) }
            catch { print("PASS rejection: " + label) }
        }
        func check(_ value: Bool, _ message: String = "Storage assertion failed", file: StaticString = #file, line: UInt = #line) { precondition(value, message, file: file, line: line) }
        func needsRecovery(_ label: String, _ body: () throws -> Void) {
            do { try body(); fatalError("Expected recoveryRequired: " + label) }
            catch let error as LibraryRestoreError {
                if case .recoveryRequired = error { print("PASS recoveryRequired: " + label) }
            }
            catch { fatalError("Expected typed recoveryRequired, got: \(error)") }
        }
        func bytes(_ url: URL) throws -> Data { try Data(contentsOf: url) }
        func samplePDF(_ pages: Int) -> Data {
            let document = PDFDocument()
            for index in 0..<pages {
                let page = PDFPage(); page.setBounds(CGRect(x: 0, y: 0, width: 612, height: 792), for: .mediaBox)
                document.insert(page, at: index)
            }
            return document.dataRepresentation()!
        }
        let pdf = samplePDF(1), secondPDF = samplePDF(2)
        let hash = SHA256.hash(data: pdf).map { String(format: "%02x", $0) }.joined()
        let hash2 = SHA256.hash(data: secondPDF).map { String(format: "%02x", $0) }.joined()
        let resource = temp.appendingPathComponent("resources")
        let content = resource.appendingPathComponent("content")
        try fm.createDirectory(at: content.appendingPathComponent("papers"), withIntermediateDirectories: true)
        try pdf.write(to: content.appendingPathComponent("papers/a.pdf"))
        try secondPDF.write(to: content.appendingPathComponent("papers/b.pdf"))
        let papers = [Paper(id: "A", name: "A", title: "A paper", file: "papers/a.pdf", pages: 1, sha256: hash, area: "Systems", year: 2026),
                      Paper(id: "B", name: "B", title: "B paper", file: "papers/b.pdf", pages: 2, sha256: hash2, area: "Systems", year: 2026)]
        try write(Catalog(papers: papers, guides: []), content.appendingPathComponent("library.json"))
        try write(["A": hash, "B": hash2], content.appendingPathComponent("legacy-paper-fingerprints.json"))

        let store = StudyStore(resourceDirectory: resource, dataDirectory: temp.appendingPathComponent("transactions"))
        check(store.ready && store.select("A") && store.setStage("阅读中", for: "A"))
        let note = StudyNote(paperID: "A", kind: "疑问", body: "Saved question", quote: "source", anchors: [Anchor(page: 0, rects: [], quote: "source")])
        check(store.upsert(note))
        let savedURL = temp.appendingPathComponent("committed-state.json")
        let persisted = try bytes(store.stateURL)
        try fm.moveItem(at: store.stateURL, to: savedURL)
        try fm.createDirectory(at: store.stateURL, withIntermediateDirectories: true)
        let draft = StudyNote(paperID: "A", kind: "笔记", body: "Canceled failed draft", quote: "", anchors: [])
        check(!store.upsert(draft) && store.data.notes.count == 1 && store.saveFailed && store.notice == nil)
        check(!store.upsert(draft) && store.data.notes.count == 1)
        check(!store.select("B") && store.selectedID == "A" && store.data.selectedID == "A")
        check(!store.clearSelection() && store.selectedID == "A")
        check(!store.setStage("已完成", for: "A") && store.data.stages["A"] == "阅读中")
        check(!store.setFontSize(20) && store.data.fontSize == 15)
        check(!store.setExercise("must stay draft", for: "A") && store.data.exercises["A"] == nil)
        check(!store.toggleResolved(note.id) && store.data.notes[0].resolved == false)
        check(!store.remove(note, undo: nil) && store.data.notes.count == 1)
        try fm.removeItem(at: store.stateURL); try fm.moveItem(at: savedURL, to: store.stateURL)
        check(store.save())
        let recovered = StudyStore(resourceDirectory: resource, dataDirectory: store.dataURL)
        check(recovered.ready && recovered.data.notes.count == 1 && recovered.data.notes[0].id == note.id)
        try check(bytes(recovered.stateURL) == persisted, "A canceled failed upsert cannot return on a later successful save")
        var edit = recovered.data.notes[0]
        edit.body = "edited"; edit.paperID = "B"; edit.sourceSHA256 = hash2
        edit.anchors = [Anchor(page: 1, rects: [], quote: "wrong")]; edit.quote = "wrong"
        check(recovered.upsert(edit))
        check(recovered.data.notes[0].paperID == "A" && recovered.data.notes[0].sourceSHA256 == hash && recovered.data.notes[0].quote == "source")
        let suspensionBytes = try bytes(recovered.stateURL)
        recovered.setPersistenceSuspended(true)
        recovered.error = nil
        check(!recovered.upsert(draft) && !recovered.select("B") && !recovered.save() && recovered.error == nil)
        try check(bytes(recovered.stateURL) == suspensionBytes)
        recovered.setPersistenceSuspended(false)
        check(recovered.select("B"))
        let chinese = DocumentNoteSource(documentID: "doc-A", documentTitle: "中文解释", blockID: "paragraph-1", quote: "中文摘录", blockOffset: 0.2, progress: 0.5, pdfPage: nil)
        let chineseNote = StudyNote(paperID: "A", documentSource: chinese, kind: "疑问", body: "为什么", quote: chinese.quote, anchors: [])
        check(recovered.upsert(chineseNote))
        check(recovered.canLocate(recovered.data.notes.last!) && recovered.annotationNotes(for: "A").count == 1)
        var oldVersion = recovered.data.notes.last!; oldVersion.sourceSHA256 = hash2
        check(!recovered.canLocate(oldVersion))
        let exported = temp.appendingPathComponent("export.md")
        recovered.exportMarkdown(exported)
        let markdown = try String(contentsOf: exported, encoding: .utf8)
        check(markdown.contains("中文解释") && !markdown.contains("中文解释 · PDF 第 1 页"))
        check(!recovered.setStage("仍有疑问", for: "A"))
        check(recovered.clearSelection() && recovered.selectedID == nil && recovered.data.selectedID == nil)
        let cleared = StudyStore(resourceDirectory: resource, dataDirectory: recovered.dataURL)
        check(cleared.ready && cleared.selectedID == nil && cleared.paper == nil)
        check(recovered.select("A"))
        print("PASS: failed upsert/select/stage/font/exercise/resolve/delete preserve committed memory and disk; canceled draft cannot resurrect; source identity and restore suspension")

        var legacy = recovered.data; legacy.stages["A"] = "仍有疑问"
        let legacyStateDir = temp.appendingPathComponent("legacy-state")
        var legacyJSON = try JSONSerialization.jsonObject(with: encoder.encode(legacy)) as! [String: Any]
        var legacyNotes = legacyJSON["notes"] as! [[String: Any]]
        for index in legacyNotes.indices { legacyNotes[index].removeValue(forKey: "documentSource") }
        legacyJSON["notes"] = legacyNotes
        try object(legacyJSON, legacyStateDir.appendingPathComponent("state.json"))
        let migratedState = StudyStore(resourceDirectory: resource, dataDirectory: legacyStateDir)
        check(migratedState.ready && migratedState.data.stages["A"] == "阅读中" && migratedState.data.notes[0].documentSource == nil)
        let corruptDir = temp.appendingPathComponent("corrupt-state")
        try fm.createDirectory(at: corruptDir, withIntermediateDirectories: true)
        try Data("bad JSON".utf8).write(to: corruptDir.appendingPathComponent("state.json"))
        let corrupt = StudyStore(resourceDirectory: resource, dataDirectory: corruptDir)
        try check(!corrupt.ready && !corrupt.save() && (bytes(corrupt.stateURL)) == Data("bad JSON".utf8))

        // A self-contained personal library includes imports, document assets, revision
        // metadata, semantic reading location, note drafts, bookmarks and reflections.
        let source = temp.appendingPathComponent("legacy-library")
        let importedPaper = Paper(id: "local-paper", name: "Imported", title: "Imported paper", file: "imports/local-paper.pdf", pages: 1, sha256: hash, area: "My papers", year: 0)
        var personal = UserData(); personal.importedPapers = [importedPaper]
        var personalNote = chineseNote; personalNote.paperID = importedPaper.id; personalNote.sourceSHA256 = hash
        personal.notes = [personalNote]; personal.selectedID = importedPaper.id
        try write(personal, source.appendingPathComponent("state.json"))
        try fm.createDirectory(at: source.appendingPathComponent("imports"), withIntermediateDirectories: true)
        try pdf.write(to: source.appendingPathComponent(importedPaper.file))
        let docDir = source.appendingPathComponent("documents/doc-A")
        try fm.createDirectory(at: docDir.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try Data("image-content".utf8).write(to: docDir.appendingPathComponent("assets/figure.png"))
        try Data("# 中文讲解\n\n![图](assets/figure.png)\n".utf8).write(to: docDir.appendingPathComponent("document.md"))
        let documentRow: [String: Any] = ["id": "doc-A", "paperID": importedPaper.id, "sha256": hash, "kind": "explanation", "title": "中文解释", "status": "unverified", "coverage": "Import", "relativePath": "doc-A/document.md", "revision": 1, "importedAt": 1000.0]
        let documents: [String: Any] = ["version": 1, "imported": [documentRow], "modes": [:], "selections": [:], "progress": ["doc-A": 0.5], "locations": ["doc-A": ["blockID": "paragraph-1", "quote": "摘录", "blockOffset": 0.2, "progress": 0.5]]]
        try object(documents, source.appendingPathComponent("documents.json"))
        var localDraft = draft; localDraft.paperID = importedPaper.id
        let draftJSON = try JSONSerialization.jsonObject(with: encoder.encode(localDraft))
        let bookmarkID = UUID()
        let workspace: [String: Any] = ["version": 1,
            "papers": [importedPaper.id: ["queued": true, "archived": false, "metadata": ["name": "My name", "year": 2026], "lastOpened": 123.0]],
            "reflections": [importedPaper.id: ["problem": "Problem", "mechanism": "Mechanism", "evidence": "Evidence", "uncertainty": "Question"]],
            "drafts": [localDraft.id.uuidString: draftJSON],
            "bookmarks": [["id": bookmarkID.uuidString, "paperID": importedPaper.id, "sha256": hash, "page": 0, "title": "First", "created": 123.0]]]
        try object(workspace, source.appendingPathComponent("workspace.json"))
        let initialSourceState = try bytes(source.appendingPathComponent("state.json"))
        let active = temp.appendingPathComponent("support/Fishbook")
        // An interrupted old copy is ignored, never mistaken for the active library.
        try fm.createDirectory(at: active.deletingLastPathComponent().appendingPathComponent(".fishbook-migration-old"), withIntermediateDirectories: true)
        let resolution = try LibraryStorage.resolve(environment: [:], defaultDirectory: active, legacyDirectory: source)
        check(resolution.migratedFrom?.path == source.path && resolution.directory.path == active.path && fm.fileExists(atPath: source.path))
        try check(bytes(active.appendingPathComponent("state.json")) == initialSourceState)
        // A dependent store used to create an empty target after a failed migration.
        // An empty shell is retried only after validating the old data; a populated
        // shell is not mistaken for an active library or merged automatically.
        let emptyShell = temp.appendingPathComponent("empty-migration-shell")
        try fm.createDirectory(at: emptyShell, withIntermediateDirectories: true)
        let retriedShell = try LibraryStorage.resolve(environment: [:], defaultDirectory: emptyShell, legacyDirectory: source)
        check(retriedShell.migratedFrom?.path == source.path)
        try check(bytes(emptyShell.appendingPathComponent("state.json")) == initialSourceState)
        let partialShell = temp.appendingPathComponent("partial-migration-shell")
        try object(["version": 1, "imported": [], "modes": [:], "selections": [:], "progress": [:]], partialShell.appendingPathComponent("documents.json"))
        let partialBefore = try bytes(partialShell.appendingPathComponent("documents.json"))
        rejected("partially initialized target cannot hide legacy library") {
            _ = try LibraryStorage.resolve(environment: [:], defaultDirectory: partialShell, legacyDirectory: source)
        }
        try check(bytes(partialShell.appendingPathComponent("documents.json")) == partialBefore)
        check(!fm.fileExists(atPath: partialShell.appendingPathComponent("state.json").path))
        personal.notes[0].body = "legacy modified after migration"
        try write(personal, source.appendingPathComponent("state.json"))
        let repeated = try LibraryStorage.resolve(environment: [:], defaultDirectory: active, legacyDirectory: source)
        check(repeated.migratedFrom == nil && repeated.notice != nil)
        try check(bytes(active.appendingPathComponent("state.json")) == initialSourceState, "Two existing libraries must never auto-merge")
        let explicit = temp.appendingPathComponent("override")
        let override = try LibraryStorage.resolve(dataDirectory: explicit, environment: ["PAPER_STUDY_DATA_DIR": temp.appendingPathComponent("env").path], defaultDirectory: active, legacyDirectory: source)
        check(override.directory.path == explicit.path && override.migratedFrom == nil)
        let envOnly = temp.appendingPathComponent("env-only")
        try check(LibraryStorage.resolve(environment: ["PAPER_STUDY_DATA_DIR": envOnly.path], defaultDirectory: active, legacyDirectory: source).directory.path == envOnly.path)
        let badDefault = temp.appendingPathComponent("file-not-directory")
        try Data("blocking file".utf8).write(to: badDefault)
        rejected("default location is a regular file") { _ = try LibraryStorage.resolve(environment: [:], defaultDirectory: badDefault, legacyDirectory: source) }
        let invalidMigration = temp.appendingPathComponent("corrupt-migration-target")
        rejected("corrupt legacy migration keeps original and target absent") { _ = try LibraryStorage.resolve(environment: [:], defaultDirectory: invalidMigration, legacyDirectory: corruptDir) }
        try check(!fm.fileExists(atPath: invalidMigration.path) && (bytes(corrupt.stateURL)) == Data("bad JSON".utf8))
        print("PASS: legacy state compatibility, old question-stage migration, explicit/environment precedence, staged copy, interrupted-copy retry, no implicit merge, failed migration preserves original")

        let backupParent = temp.appendingPathComponent("backups")
        let backup = try LibraryStorage.createBackup(from: active, to: backupParent)
        check(!backup.isLegacy && backup.importedPaperCount == 1 && backup.noteCount == 1 && backup.unresolvedCount == 1 && backup.documentCount == 1 && backup.bookmarkCount == 1)
        check(backup.scopeDescription.contains("内置") && backup.fileCount >= 6 && backup.byteCount > 0)
        let legacyPreview = try LibraryStorage.inspectBackup(at: source)
        check(legacyPreview.isLegacy && legacyPreview.noteCount == 1)
        rejected("backup cannot recursively contain itself") { _ = try LibraryStorage.createBackup(from: active, to: active.appendingPathComponent("backup")) }
        let destination = temp.appendingPathComponent("restore-target")
        var oldData = UserData(); oldData.exercises["A"] = "Before restore"
        try write(oldData, destination.appendingPathComponent("state.json"))
        let oldBytes = try bytes(destination.appendingPathComponent("state.json"))
        let restored = try LibraryStorage.restore(from: backup.directory, to: destination)
        check(restored.previousLibrary != nil)
        try check(bytes(restored.previousLibrary!.appendingPathComponent("state.json")) == oldBytes)
        try check(bytes(destination.appendingPathComponent("state.json")) == initialSourceState)
        let restoredStore = StudyStore(resourceDirectory: resource, dataDirectory: destination)
        check(restoredStore.ready && restoredStore.data.notes.count == 1 && restoredStore.data.importedPapers.count == 1)
        // A saved library changes after restore: a second backup refreshes its manifest.
        check(restoredStore.setStage("已完成", for: importedPaper.id))
        let secondBackup = try LibraryStorage.createBackup(from: destination, to: backupParent)
        check(!secondBackup.isLegacy)
        for phase in ["prepared", "archived", "activated"] {
            let before = try bytes(destination.appendingPathComponent("state.json"))
            rejected("restore rollback at " + phase) {
                _ = try LibraryStorage.restore(from: backup.directory, to: destination) { at in
                    if at == phase { throw StudyError.message("simulated interruption") }
                }
            }
            try check(bytes(destination.appendingPathComponent("state.json")) == before)
        }
        // Cause a real rollback failure: while the old directory is archived, place
        // unrelated data at the destination. The restore must not delete that target
        // to force a rollback, and callers must be told to keep persistence suspended.
        let blockedTarget = temp.appendingPathComponent("blocked-rollback")
        try write(oldData, blockedTarget.appendingPathComponent("state.json"))
        let foreignBytes = Data("Unrelated target must never be overwritten".utf8)
        needsRecovery("rollback cannot move old library over a foreign target") {
            _ = try LibraryStorage.restore(from: backup.directory, to: blockedTarget) { phase in
                if phase == "archived" {
                    try fm.createDirectory(at: blockedTarget, withIntermediateDirectories: true)
                    try foreignBytes.write(to: blockedTarget.appendingPathComponent("foreign.txt"))
                    throw StudyError.message("simulated interruption after foreign target appeared")
                }
            }
        }
        let blockedJournalURL = temp.appendingPathComponent(".blocked-rollback-restore-journal.json")
        let blockedJournalBytes = try bytes(blockedJournalURL)
        let blockedJournal = try JSONSerialization.jsonObject(with: blockedJournalBytes) as! [String: Any]
        let blockedPrevious = temp.appendingPathComponent(blockedJournal["previous"] as! String)
        let blockedStage = temp.appendingPathComponent(blockedJournal["staging"] as! String)
        try check(bytes(blockedPrevious.appendingPathComponent("state.json")) == oldBytes)
        try check(bytes(blockedTarget.appendingPathComponent("foreign.txt")) == foreignBytes)
        check(fm.fileExists(atPath: blockedStage.appendingPathComponent("state.json").path))
        needsRecovery("reopen cannot activate a foreign target or erase recovery evidence") {
            _ = try LibraryStorage.resolve(dataDirectory: blockedTarget, environment: [:])
        }
        let blockedStore = StudyStore(resourceDirectory: resource, dataDirectory: blockedTarget)
        check(!blockedStore.ready && !blockedStore.save())
        check(!fm.fileExists(atPath: blockedTarget.appendingPathComponent("state.json").path))
        try check(bytes(blockedJournalURL) == blockedJournalBytes)
        try check(bytes(blockedPrevious.appendingPathComponent("state.json")) == oldBytes)
        // Merely changing the foreign target into an empty shell, corrupt state, or
        // a different but structurally valid library still cannot prove its identity.
        try fm.removeItem(at: blockedTarget)
        try fm.createDirectory(at: blockedTarget, withIntermediateDirectories: true)
        needsRecovery("reopen rejects empty target with pending journal") {
            _ = try LibraryStorage.resolve(dataDirectory: blockedTarget, environment: [:])
        }
        try Data("damaged state".utf8).write(to: blockedTarget.appendingPathComponent("state.json"))
        needsRecovery("reopen rejects corrupt target with pending journal") {
            _ = try LibraryStorage.resolve(dataDirectory: blockedTarget, environment: [:])
        }
        var otherValidData = oldData; otherValidData.exercises["A"] = "Different unrelated library"
        try write(otherValidData, blockedTarget.appendingPathComponent("state.json"))
        let otherValidBytes = try bytes(blockedTarget.appendingPathComponent("state.json"))
        needsRecovery("reopen rejects unrelated but valid target") {
            _ = try LibraryStorage.resolve(dataDirectory: blockedTarget, environment: [:])
        }
        try check(bytes(blockedTarget.appendingPathComponent("state.json")) == otherValidBytes)
        try check(bytes(blockedPrevious.appendingPathComponent("state.json")) == oldBytes)
        try check(bytes(blockedJournalURL) == blockedJournalBytes)
        // Once the unrelated target is deliberately moved away, the verified original
        // can be restored. Test cleanup is explicit and never performed by recovery.
        try fm.moveItem(at: blockedTarget, to: temp.appendingPathComponent("retained-foreign-library"))
        _ = try LibraryStorage.resolve(dataDirectory: blockedTarget, environment: [:])
        try check(bytes(blockedTarget.appendingPathComponent("state.json")) == oldBytes)
        check(!fm.fileExists(atPath: blockedJournalURL.path) && !fm.fileExists(atPath: blockedStage.path))

        // A crash after successful activation but before deleting the journal is
        // distinguishable from a foreign target by the recorded complete fingerprint.
        let activationTarget = temp.appendingPathComponent("activation-recovery")
        try write(oldData, activationTarget.appendingPathComponent("state.json"))
        let activationJournalURL = temp.appendingPathComponent(".activation-recovery-restore-journal.json")
        var activationJournal: Data?
        let activatedResult = try LibraryStorage.restore(from: backup.directory, to: activationTarget) { phase in
            if phase == "activated" { activationJournal = try bytes(activationJournalURL) }
        }
        try activationJournal!.write(to: activationJournalURL)
        _ = try LibraryStorage.resolve(dataDirectory: activationTarget, environment: [:])
        try check(bytes(activationTarget.appendingPathComponent("state.json")) == initialSourceState)
        try check(bytes(activatedResult.previousLibrary!.appendingPathComponent("state.json")) == oldBytes)
        check(!fm.fileExists(atPath: activationJournalURL.path))
        print("PASS: typed rollback failure retains old copy/stage/journal; unknown empty/corrupt/foreign targets cannot reopen or write; fingerprint-proven original and completed activation recover safely")

        // Simulate a real process crash after the old library was renamed, before the
        // new staging directory was activated. Resolver rolls back before any load.
        let interrupted = temp.appendingPathComponent("crash-library")
        try write(oldData, interrupted.appendingPathComponent("state.json"))
        let prior = temp.appendingPathComponent("Fishbook恢复前-simulated")
        let stage = temp.appendingPathComponent(".fishbook-restore-simulated")
        try fm.copyItem(at: backup.directory, to: stage)
        try fm.moveItem(at: interrupted, to: prior)
        try object(["version": 1, "destination": interrupted.lastPathComponent, "staging": stage.lastPathComponent, "previous": prior.lastPathComponent, "hadPrevious": true], temp.appendingPathComponent(".crash-library-restore-journal.json"))
        _ = try LibraryStorage.resolve(dataDirectory: interrupted, environment: [:])
        try check(bytes(interrupted.appendingPathComponent("state.json")) == oldBytes)
        check(!fm.fileExists(atPath: stage.path) && !fm.fileExists(atPath: prior.path))
        print("PASS: verified backup counts/scope, legacy directory preview, restore preserves old library, fresh manifests, staged swap rollback at three phases, crash journal rollback on reopen")

        func corruptCopy(_ suffix: String) throws -> URL {
            let copy = temp.appendingPathComponent("bad-" + suffix)
            try fm.copyItem(at: backup.directory, to: copy); return copy
        }
        let damaged = try corruptCopy("hash")
        try Data("tampered".utf8).write(to: damaged.appendingPathComponent("documents/doc-A/assets/figure.png"))
        rejected("modified content hash") { _ = try LibraryStorage.inspectBackup(at: damaged) }
        let missing = try corruptCopy("missing")
        try fm.removeItem(at: missing.appendingPathComponent("imports/local-paper.pdf"))
        rejected("missing imported resource") { _ = try LibraryStorage.inspectBackup(at: missing) }
        let linked = try corruptCopy("symlink")
        try fm.createSymbolicLink(at: linked.appendingPathComponent("outside"), withDestinationURL: resource)
        rejected("symlink resource") { _ = try LibraryStorage.inspectBackup(at: linked) }
        let traversal = try corruptCopy("traversal")
        var manifest = try JSONSerialization.jsonObject(with: bytes(traversal.appendingPathComponent("backup-manifest.json"))) as! [String: Any]
        var files = manifest["files"] as! [[String: Any]]; files[0]["path"] = "../outside"; manifest["files"] = files
        try object(manifest, traversal.appendingPathComponent("backup-manifest.json"))
        rejected("manifest traversal path") { _ = try LibraryStorage.inspectBackup(at: traversal) }
        let future = try corruptCopy("version")
        manifest = try JSONSerialization.jsonObject(with: bytes(future.appendingPathComponent("backup-manifest.json"))) as! [String: Any]
        manifest["version"] = 99; try object(manifest, future.appendingPathComponent("backup-manifest.json"))
        rejected("future backup version") { _ = try LibraryStorage.inspectBackup(at: future) }
        // Legacy backups have no hash manifest, so semantic validation must catch
        // corrupt JSON, unsafe resource references, impossible records and missing assets.
        let semantic = temp.appendingPathComponent("bad-legacy")
        try fm.copyItem(at: source, to: semantic)
        var invalidWorkspace = workspace
        invalidWorkspace["papers"] = ["local-paper": ["queued": "not a bool"]]
        try object(invalidWorkspace, semantic.appendingPathComponent("workspace.json"))
        rejected("legacy workspace wrong type") { _ = try LibraryStorage.inspectBackup(at: semantic) }
        try object(workspace, semantic.appendingPathComponent("workspace.json"))
        var invalidDocuments = documents; var invalidRow = documentRow; invalidRow["relativePath"] = "../outside.md"
        invalidDocuments["imported"] = [invalidRow]
        try object(invalidDocuments, semantic.appendingPathComponent("documents.json"))
        rejected("legacy document traversal") { _ = try LibraryStorage.inspectBackup(at: semantic) }
        try object(documents, semantic.appendingPathComponent("documents.json"))
        try fm.removeItem(at: semantic.appendingPathComponent("documents/doc-A/assets/figure.png"))
        rejected("legacy missing inline image") { _ = try LibraryStorage.inspectBackup(at: semantic) }
        let intact = try bytes(destination.appendingPathComponent("state.json"))
        rejected("preflight rejects before touching active library") { _ = try LibraryStorage.restore(from: damaged, to: destination) }
        try check(bytes(destination.appendingPathComponent("state.json")) == intact)
        print("PASS: manifest hashes/file inventory/version, legacy semantic validation, traversal and symlink rejection, missing PDF/image rejection, unchanged current library on preflight failure")
        print("PASS: StorageWorkflow only used isolated temporary paths; no real Application Support library or user documents read or changed.")
    }
}
