import Foundation
import CryptoKit
import PDFKit

struct LibraryLocationResolution {
    let directory: URL
    let migratedFrom: URL?
    let notice: String?
}
struct BackupPreview: Identifiable {
    var id: String { directory.path }
    let directory: URL
    let createdAt: Date?
    let importedPaperCount: Int
    let noteCount: Int
    let unresolvedCount: Int
    let documentCount: Int
    let bookmarkCount: Int
    let fileCount: Int
    let byteCount: Int64
    let isLegacy: Bool
    let scopeDescription: String
}
/// This error means the original directory has not been proved safely active again.
/// Callers must keep every existing store suspended until a fresh verified session loads.
enum LibraryRestoreError: LocalizedError {
    case recoveryRequired(String)
    var errorDescription: String? {
        if case let .recoveryRequired(message) = self { return message }
        return nil
    }
}

struct LibraryRestoreResult {
    let previousLibrary: URL?
    let restoredDirectory: URL
    let preview: BackupPreview
}

/// File operations are independent of UI state. The caller suspends every live store
/// before restoring and constructs a fresh session after the directory swap.
enum LibraryStorage {
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Fishbook", isDirectory: true)
    }
    private static let fm = FileManager.default
    private static let manifestName = "backup-manifest.json"
    private static let scope = "personal-and-imported"
    private static let scopeDescription = "个人记录、整理与草稿、自行导入的 PDF 和学习材料。内置论文与材料由 Fishbook 应用提供，未重复包含在备份中。"
    private struct BackupFile: Codable, Equatable {
        var path: String
        var bytes: Int64
        var sha256: String
    }
    private struct Manifest: Codable {
        var format: String = "FishbookBackup"
        var version: Int = 1
        var scope: String = LibraryStorage.scope
        var createdAt: Date
        var files: [BackupFile]
    }
    private struct RestoreJournal: Codable {
        var version = 1
        var destination: String
        var staging: String
        var previous: String
        var hadPrevious: Bool
        var originalFingerprint: String? = nil
        var restoredFingerprint: String? = nil
    }
    private struct DirectoryIdentity: Codable {
        var files: [BackupFile]
        var directories: [String]
        var manifestSHA256: String?
    }
    private struct Counts {
        var papers = 0; var notes = 0; var questions = 0; var documents = 0; var bookmarks = 0
    }
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return encoder
    }()

    static func resolve(dataDirectory: URL? = nil,
                        environment: [String: String] = ProcessInfo.processInfo.environment,
                        defaultDirectory: URL? = nil, legacyDirectory: URL? = nil) throws -> LibraryLocationResolution {
        let explicit = dataDirectory ?? environment["PAPER_STUDY_DATA_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        let destination = (explicit ?? defaultDirectory ?? Self.defaultDirectory).standardizedFileURL
        try recoverInterruptedRestore(at: destination)
        if explicit != nil {
            try prepareDirectory(destination)
            return LibraryLocationResolution(directory: destination, migratedFrom: nil, notice: nil)
        }
        let legacy = (legacyDirectory ?? Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("学习资料", isDirectory: true)).standardizedFileURL
        var replaceEmptyDestination = false
        if exists(destination) {
            try requireDirectory(destination)
            let oldLibraryExists = canonical(legacy).path != canonical(destination).path &&
                ["state.json", "documents.json", "workspace.json", "guides.json", "imports", "documents"].contains {
                    exists(legacy.appendingPathComponent($0))
                }
            if !exists(destination.appendingPathComponent("state.json")), oldLibraryExists {
                // A companion store from an earlier failed startup may have created the
                // target directory. Its existence alone does not prove migration finished.
                guard try fm.contentsOfDirectory(atPath: destination.path).isEmpty else {
                    throw StudyError.message("固定资料位置尚未完成初始化，应用旁仍有旧资料。为避免误用空资料库，暂不切换或合并；请从资料库设置恢复旧资料。两处文件均已保留。")
                }
                replaceEmptyDestination = true
            } else {
                // A second library is never silently merged into the active library.
                return LibraryLocationResolution(directory: destination, migratedFrom: nil,
                    notice: exists(legacy) && canonical(legacy).path != canonical(destination).path
                        ? "已使用固定资料库。应用旁的旧资料仍保留，可在需要时通过恢复备份导入。" : nil)
            }
        }
        guard exists(legacy), canonical(legacy).path != canonical(destination).path else {
            try prepareDirectory(destination)
            return LibraryLocationResolution(directory: destination, migratedFrom: nil, notice: nil)
        }
        try rejectOverlap(legacy, destination)
        _ = try validateLibrary(at: legacy, requireState: false)
        let before = try inventory(legacy)
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".fishbook-migration-" + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: legacy, to: staging)
        guard try inventory(staging) == before, try inventory(legacy) == before else {
            throw StudyError.message("旧资料在迁移时发生变化；尚未切换资料库，请关闭其他 Fishbook 窗口后重试。")
        }
        _ = try validateLibrary(at: staging, requireState: false)
        // Same-volume rename activates only a complete, verified copy. Stale staging
        // directories from an interrupted copy are ignored; the original remains safe.
        if replaceEmptyDestination {
            try requireDirectory(destination)
            guard try fm.contentsOfDirectory(atPath: destination.path).isEmpty else {
                throw StudyError.message("固定位置已出现新的资料，未合并或覆盖。请重新打开 Fishbook。")
            }
            // Only the verified-empty shell is removed, after the complete migration
            // copy has been checked. The untouched legacy directory is always retained.
            try fm.removeItem(at: destination)
        }
        guard !exists(destination) else { throw StudyError.message("固定位置已出现资料库，未合并或覆盖。请重新打开 Fishbook。") }
        try fm.moveItem(at: staging, to: destination)
        return LibraryLocationResolution(directory: destination, migratedFrom: legacy,
            notice: "学习资料已安全复制到固定位置；应用旁的旧资料仍保留。移动或升级应用不会移动你的资料。")
    }

    static func createBackup(from source: URL, to parent: URL) throws -> BackupPreview {
        try requireDirectory(source)
        let sourceRoot = canonical(source), parentRoot = canonical(parent)
        guard sourceRoot.path != parentRoot.path, !isWithin(parentRoot, sourceRoot) else {
            throw StudyError.message("请将备份保存到学习资料目录之外。")
        }
        _ = try validateLibrary(at: source, requireState: true)
        let before = try inventory(source)
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        try requireDirectory(parent)
        let staging = parent.appendingPathComponent(".fishbook-backup-" + UUID().uuidString, isDirectory: true)
        let destination = parent.appendingPathComponent("Fishbook备份-" + timestamp() + "-" + UUID().uuidString.prefix(8), isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: source, to: staging)
        // A restored library may carry a previous backup manifest. It describes that
        // snapshot, not the current files, so every new backup writes a fresh manifest.
        let files = try inventory(staging)
        guard before == files, try inventory(source) == before else {
            throw StudyError.message("备份过程中资料发生变化，请等待当前保存完成后重试。")
        }
        let manifest = Manifest(createdAt: Date(), files: files)
        try encoder.encode(manifest).write(to: staging.appendingPathComponent(manifestName), options: .atomic)
        _ = try inspectBackup(at: staging)
        try fm.moveItem(at: staging, to: destination)
        return try inspectBackup(at: destination)
    }

    static func inspectBackup(at directory: URL) throws -> BackupPreview {
        try requireDirectory(directory)
        let manifestURL = directory.appendingPathComponent(manifestName)
        let files = try inventory(directory)
        var createdAt: Date?
        let legacy = !exists(manifestURL)
        if !legacy {
            let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
            guard manifest.format == "FishbookBackup", manifest.version == 1, manifest.scope == scope,
                  manifest.createdAt.timeIntervalSinceReferenceDate.isFinite else {
                throw StudyError.message("备份格式或版本暂不支持，尚未修改当前资料。")
            }
            guard Set(manifest.files.map(\.path)).count == manifest.files.count,
                  manifest.files.allSatisfy({ validRelativePath($0.path) && $0.bytes >= 0 && validHash($0.sha256) }),
                  manifest.files.sorted(by: { $0.path < $1.path }) == files else {
                throw StudyError.message("备份文件清单、大小或校验值不一致，不能恢复。")
            }
            createdAt = manifest.createdAt
        }
        let counts = try validateLibrary(at: directory, requireState: true)
        return BackupPreview(directory: directory, createdAt: createdAt,
            importedPaperCount: counts.papers, noteCount: counts.notes, unresolvedCount: counts.questions,
            documentCount: counts.documents, bookmarkCount: counts.bookmarks,
            fileCount: files.count, byteCount: files.reduce(0) { $0 + $1.bytes }, isLegacy: legacy,
            scopeDescription: scopeDescription + (legacy ? " 此为旧版目录备份；已检查记录格式和引用资源，但没有历史文件校验清单。" : ""))
    }

    /// `checkpoint` is used by isolated failure tests to simulate an interrupted swap.
    static func restore(from backup: URL, to destination: URL,
                        checkpoint: ((String) throws -> Void)? = nil) throws -> LibraryRestoreResult {
        try rejectOverlap(backup, destination)
        let preview = try inspectBackup(at: backup)
        let before = try inventory(backup)
        try recoverInterruptedRestore(at: destination)
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        if exists(destination) { try requireDirectory(destination) }
        let token = UUID().uuidString
        let staging = parent.appendingPathComponent(".fishbook-restore-" + token, isDirectory: true)
        let previous = parent.appendingPathComponent("Fishbook恢复前-" + timestamp() + "-" + token, isDirectory: true)
        let journalURL = self.journalURL(for: destination)
        let hadPrevious = exists(destination)
        var archived = false, activated = false, complete = false, preserveRecoveryArtifacts = false
        defer { if !complete && !preserveRecoveryArtifacts { try? fm.removeItem(at: staging) } }
        let originalFingerprint = hadPrevious ? try directoryFingerprint(destination) : nil
        try fm.copyItem(at: backup, to: staging)
        guard try inventory(staging) == before, try inventory(backup) == before else {
            throw StudyError.message("备份在恢复过程中发生变化，尚未修改当前资料。")
        }
        _ = try inspectBackup(at: staging)
        let journal = RestoreJournal(destination: destination.lastPathComponent, staging: staging.lastPathComponent,
                                     previous: previous.lastPathComponent, hadPrevious: hadPrevious,
                                     originalFingerprint: originalFingerprint, restoredFingerprint: try directoryFingerprint(staging))
        try encoder.encode(journal).write(to: journalURL, options: .atomic)
        do {
            try checkpoint?("prepared")
            if hadPrevious { try fm.moveItem(at: destination, to: previous); archived = true }
            try checkpoint?("archived")
            try fm.moveItem(at: staging, to: destination); activated = true
            try checkpoint?("activated")
            try fm.removeItem(at: journalURL)
            complete = true
            return LibraryRestoreResult(previousLibrary: hadPrevious ? previous : nil,
                                        restoredDirectory: destination, preview: preview)
        } catch {
            // Roll back only directories this operation moved. Never remove an unrelated
            // target that appeared before activation, and retain the journal on rollback failure.
            do {
                if activated { try fm.removeItem(at: destination) }
                if archived { try fm.moveItem(at: previous, to: destination) }
                if exists(journalURL) { try fm.removeItem(at: journalURL) }
            } catch let rollbackError {
                preserveRecoveryArtifacts = true
                throw LibraryRestoreError.recoveryRequired("恢复中断且自动回退未完成。已暂停资料写入；请保留以下目录和日志，勿手动覆盖。重新打开后会检查目录身份，无法确认时不会自动启用。\n原资料副本：\(previous.path)\n当前目标：\(destination.path)\n待恢复副本：\(staging.path)\n恢复日志：\(journalURL.path)\n\(rollbackError.localizedDescription)")
            }
            throw StudyError.message("恢复未完成，原资料已保留：\(error.localizedDescription)")
        }
    }

    /// A crash between archiving and activation leaves the old library next to the
    /// target. Resolve the journal before choosing any default or legacy directory.
    private static func recoverInterruptedRestore(at destination: URL) throws {
        let url = journalURL(for: destination)
        guard exists(url) else { return }
        var recoveryContext = "当前目标：\(destination.path)\n恢复日志：\(url.path)\n请同时保留该目录旁的 Fishbook恢复前 和 .fishbook-restore 副本。"
        do {
            let attrs = try fm.attributesOfItem(atPath: url.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular else { throw StudyError.message("资料恢复日志不是普通文件。") }
            let journal = try JSONDecoder().decode(RestoreJournal.self, from: Data(contentsOf: url))
            guard journal.version == 1, journal.destination == destination.lastPathComponent,
                  validSingleName(journal.staging), journal.staging.hasPrefix(".fishbook-restore-"),
                  validSingleName(journal.previous), journal.previous.hasPrefix("Fishbook恢复前-"),
                  journal.staging != journal.destination, journal.previous != journal.destination,
                  journal.originalFingerprint.map(validHash) ?? true,
                  journal.restoredFingerprint.map(validHash) ?? true else {
                throw StudyError.message("资料恢复日志的格式或目录身份无效。")
            }
            let parent = destination.deletingLastPathComponent()
            let staging = parent.appendingPathComponent(journal.staging), previous = parent.appendingPathComponent(journal.previous)
            recoveryContext = "原资料副本：\(previous.path)\n当前目标：\(destination.path)\n待恢复副本：\(staging.path)\n恢复日志：\(url.path)"
            // Verify the staged copy before considering it disposable or activatable.
            // Unknown files in a transaction directory are retained for manual recovery.
            if exists(staging) {
                try requireDirectory(staging)
                if let expected = journal.restoredFingerprint {
                    guard try directoryFingerprint(staging) == expected else { throw StudyError.message("待恢复副本已经变化。") }
                }
                _ = try inspectBackup(at: staging)
            }
            if exists(destination) {
                try requireDirectory(destination)
                let identity = try directoryFingerprint(destination)
                let isOriginal = journal.hadPrevious && journal.originalFingerprint == identity
                let isRestored = journal.restoredFingerprint == identity
                guard isOriginal || isRestored else {
                    throw StudyError.message("当前目标目录与恢复前记录或待恢复备份不一致，不能确认资料身份。旧版恢复日志缺少校验值时也不会猜测。")
                }
                if isRestored && !isOriginal {
                    _ = try inspectBackup(at: destination)
                    if journal.hadPrevious {
                        guard exists(previous), let expected = journal.originalFingerprint,
                              try directoryFingerprint(previous) == expected else {
                            throw StudyError.message("完整新资料已存在，但无法确认恢复前副本，暂不清理恢复日志。")
                        }
                    }
                }
                // Preserve the prior copy on every successful activation. Never infer
                // success from the existence of an empty, corrupt or unrelated target.
            } else if journal.hadPrevious {
                guard exists(previous) else { throw StudyError.message("暂时找不到恢复前的资料副本。") }
                try requireDirectory(previous)
                if let expected = journal.originalFingerprint {
                    guard try directoryFingerprint(previous) == expected else { throw StudyError.message("恢复前的资料副本已经变化。") }
                } else {
                    // Legacy journals have no exact identity proof. A complete semantic
                    // check is the minimum required before reactivating their old copy.
                    _ = try validateLibrary(at: previous, requireState: true)
                }
                try fm.moveItem(at: previous, to: destination)
            } else {
                guard exists(staging), journal.restoredFingerprint != nil else {
                    throw StudyError.message("无法确认可激活的完整备份，尚未创建空资料库。")
                }
                try fm.moveItem(at: staging, to: destination)
            }
            if exists(staging) { try fm.removeItem(at: staging) }
            try fm.removeItem(at: url)
        } catch {
            throw LibraryRestoreError.recoveryRequired("上次恢复尚未安全完成，已停止启用资料库。请保留以下目录及日志，检查后再恢复。\n\(recoveryContext)\n\(error.localizedDescription)")
        }
    }

    /// Proves both file bytes and directory shape, including the manifest itself.
    /// Hashes do not treat an empty shell or a different backup as the original target.
    private static func directoryFingerprint(_ root: URL) throws -> String {
        let files = try inventory(root)
        var directories: [String] = []
        func walk(_ directory: URL, prefix: String) throws {
            for item in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                let attrs = try fm.attributesOfItem(atPath: item.path)
                if attrs[.type] as? FileAttributeType == .typeDirectory {
                    let path = prefix + item.lastPathComponent
                    directories.append(path); try walk(item, prefix: path + "/")
                }
            }
        }
        try walk(root, prefix: "")
        let manifest = root.appendingPathComponent(manifestName)
        let identity = DirectoryIdentity(files: files, directories: directories.sorted(),
                                         manifestSHA256: exists(manifest) ? try hashFile(manifest) : nil)
        return SHA256.hash(data: try encoder.encode(identity)).map { String(format: "%02x", $0) }.joined()
    }

    static func validateUserData(_ data: UserData) throws {
        guard data.version == 1, data.fontSize.isFinite, (8...72).contains(data.fontSize),
              Set(data.notes.map(\.id)).count == data.notes.count,
              Set(data.importedPapers.map(\.id)).count == data.importedPapers.count,
              data.positions.values.allSatisfy({ $0.page >= 0 && $0.x.isFinite && $0.y.isFinite }),
              data.stages.values.allSatisfy({ ["未开始", "阅读中", "已完成", "仍有疑问"].contains($0) }),
              data.notes.allSatisfy({ validNote($0) }) else {
            throw StudyError.message("学习记录版本或格式无效。原文件已保留。")
        }
        for paper in data.importedPapers {
            guard !paper.id.isEmpty, paper.pages > 0, validHash(paper.sha256),
                  paper.file.hasPrefix("imports/"), validRelativePath(paper.file) else {
                throw StudyError.message("导入论文记录的路径或格式无效。")
            }
        }
    }
    static func validNote(_ note: StudyNote) -> Bool {
        guard !note.paperID.isEmpty, ["高亮", "笔记", "疑问"].contains(note.kind), note.created.timeIntervalSinceReferenceDate.isFinite,
              note.anchors.allSatisfy({ anchor in anchor.page >= 0 && anchor.rects.allSatisfy {
                  $0.x.isFinite && $0.y.isFinite && $0.width.isFinite && $0.height.isFinite && $0.width >= 0 && $0.height >= 0
              } }) else { return false }
        if let source = note.documentSource {
            return !source.documentID.isEmpty && !source.documentTitle.isEmpty &&
                source.blockOffset.isFinite && (0...1).contains(source.blockOffset) &&
                source.progress.isFinite && (0...1).contains(source.progress) && (source.pdfPage.map { $0 >= 0 } ?? true)
        }
        return true
    }
    private static func validateLibrary(at root: URL, requireState: Bool) throws -> Counts {
        try requireDirectory(root)
        _ = try inventory(root) // Includes symlink/type validation for every resource.
        let state = root.appendingPathComponent("state.json")
        var counts = Counts()
        if exists(state) {
            let data = try JSONDecoder().decode(UserData.self, from: Data(contentsOf: state))
            try validateUserData(data)
            counts.notes = data.notes.count; counts.questions = data.notes.filter { $0.kind == "疑问" && !$0.resolved }.count
            counts.papers = data.importedPapers.count
            for paper in data.importedPapers {
                let file = try contained(paper.file, root: root)
                guard try hashFile(file) == paper.sha256, let pdf = PDFDocument(url: file), !pdf.isLocked, pdf.pageCount == paper.pages else {
                    throw StudyError.message("导入论文“\(paper.name)”缺失或与记录版本不一致。")
                }
            }
        } else if requireState { throw StudyError.message("此目录缺少 Fishbook 学习记录 state.json，不能作为资料备份恢复。") }
        let documents = root.appendingPathComponent("documents.json")
        if exists(documents) {
            let object = try objectFile(documents)
            try checkVersion(object, name: "文档记录")
            let imported = try array(object, "imported")
            var ids = Set<String>()
            for row in imported {
                guard let item = row as? [String: Any], let id = item["id"] as? String, !id.isEmpty, ids.insert(id).inserted,
                      let paperID = item["paperID"] as? String, !paperID.isEmpty,
                      let sha = item["sha256"] as? String, validHash(sha),
                      let kind = item["kind"] as? String, ["explanation", "translation"].contains(kind),
                      let title = item["title"] as? String, !title.isEmpty,
                      let status = item["status"] as? String, ["complete", "partial", "unverified"].contains(status),
                      let coverage = item["coverage"] as? String, !coverage.isEmpty,
                      let path = item["relativePath"] as? String else { throw StudyError.message("导入材料的记录不完整。") }
                let file = try contained(path.removingPercentEncoding ?? path, root: root.appendingPathComponent("documents"))
                guard ["md", "markdown", "txt"].contains(file.pathExtension.lowercased()),
                      let text = String(data: try Data(contentsOf: file), encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw StudyError.message("导入材料“\(title)”为空或格式无效。")
                }
                try validateImageReferences(text, beside: file.deletingLastPathComponent())
                try optionalString(item, "previousRevisionID")
                try optionalNumber(item, "importedAt")
                if let revision = item["revision"], !(revision is NSNull) {
                    guard let value = finiteNumber(revision), value >= 1, value.rounded() == value else { throw StudyError.message("文档修订版本无效。") }
                }
            }
            counts.documents = imported.count
            for key in ["modes", "selections"] { _ = try stringDictionary(object, key) }
            if let progress = object["progress"] as? [String: Any] {
                guard progress.values.allSatisfy({ finiteNumber($0).map { (0...1).contains($0) } ?? false }) else { throw StudyError.message("文档阅读进度无效。") }
            } else if object["progress"] != nil { throw StudyError.message("文档阅读进度格式无效。") }
            for key in ["locations", "readingLocations"] {
                if let locations = object[key] as? [String: Any] {
                    for row in locations.values { try validateLocation(row) }
                } else if object[key] != nil { throw StudyError.message("文档段落位置格式无效。") }
            }
        }
        let workspace = root.appendingPathComponent("workspace.json")
        if exists(workspace) {
            let object = try objectFile(workspace)
            try checkVersion(object, name: "工作台记录")
            if let entries = try optionalObject(object, "papers") {
                for (paperID, row) in entries {
                    guard !paperID.isEmpty, let item = row as? [String: Any] else { throw StudyError.message("论文整理记录格式无效。") }
                    for key in ["queued", "archived"] {
                        if let value = item[key], !(value is NSNull) {
                            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw StudyError.message("论文整理状态格式无效。") }
                        }
                    }
                    for key in ["lastOpened", "removedAt"] { try optionalNumber(item, key) }
                    if let metadata = try optionalObject(item, "metadata") {
                        for key in ["name", "title", "area"] { try optionalString(metadata, key) }
                        if let year = metadata["year"], !(year is NSNull) {
                            guard let value = finiteNumber(year), value.rounded() == value, (0...2200).contains(value) else { throw StudyError.message("论文学年格式无效。") }
                        }
                    }
                }
            }
            if let entries = try optionalObject(object, "reflections") {
                for (paperID, row) in entries {
                    guard !paperID.isEmpty, let item = row as? [String: Any] else { throw StudyError.message("机制复述格式无效。") }
                    for key in ["problem", "mechanism", "evidence", "uncertainty"] { try optionalString(item, key) }
                    try optionalNumber(item, "updated")
                }
            }
            if let drafts = object["drafts"] as? [String: Any] {
                var noteIDs = Set<UUID>()
                for (id, row) in drafts {
                    let note = try JSONDecoder().decode(StudyNote.self, from: JSONSerialization.data(withJSONObject: row))
                    guard UUID(uuidString: id) == note.id, noteIDs.insert(note.id).inserted, validNote(note) else { throw StudyError.message("笔记草稿格式无效。") }
                }
            } else if object["drafts"] != nil { throw StudyError.message("笔记草稿格式无效。") }
            let bookmarks = try array(object, "bookmarks")
            var bookmarkIDs = Set<UUID>()
            for row in bookmarks {
                guard let item = row as? [String: Any], let rawID = item["id"] as? String, let id = UUID(uuidString: rawID), bookmarkIDs.insert(id).inserted,
                      let paper = item["paperID"] as? String, !paper.isEmpty,
                      let sha = item["sha256"] as? String, validHash(sha),
                      let page = finiteNumber(item["page"]), page >= 0, page.rounded() == page,
                      item["title"] is String, finiteNumber(item["created"]) != nil else { throw StudyError.message("PDF 书签格式无效。") }
            }
            counts.bookmarks = bookmarks.count
        }
        let guides = root.appendingPathComponent("guides.json")
        if exists(guides) {
            let items = try JSONDecoder().decode([Guide].self, from: Data(contentsOf: guides))
            guard Set(items.map(\.paperID)).count == items.count, items.allSatisfy({ guide in
                !guide.paperID.isEmpty && validHash(guide.sha256) && !guide.subtitle.isEmpty && !guide.overview.isEmpty &&
                guide.overview.allSatisfy({ !$0.title.isEmpty && !$0.body.isEmpty }) && !guide.concepts.isEmpty &&
                Set(guide.concepts.map(\.id)).count == guide.concepts.count && guide.concepts.allSatisfy({ concept in
                    !concept.id.isEmpty && !concept.title.isEmpty && concept.sections.count == 7 &&
                    concept.sections.allSatisfy({ !$0.title.isEmpty && !$0.body.isEmpty }) &&
                    concept.anchor.page >= 0 && !concept.anchor.quote.isEmpty && !concept.anchor.rects.isEmpty &&
                    concept.anchor.rects.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0 }) &&
                    concept.prerequisites.allSatisfy({ ref in guide.concepts.contains { $0.id == ref } })
                })
            }) else {
                throw StudyError.message("补充讲解包记录无效。")
            }
        }
        return counts
    }

    private static func validateLocation(_ value: Any) throws {
        guard let item = value as? [String: Any], item["blockID"] is String, item["quote"] is String,
              let offset = finiteNumber(item["blockOffset"]), (0...1).contains(offset),
              let progress = finiteNumber(item["progress"]), (0...1).contains(progress) else { throw StudyError.message("文档段落定位无效。") }
        if let page = item["pdfPage"], !(page is NSNull) {
            guard let number = finiteNumber(page), number >= 0, number.rounded() == number else { throw StudyError.message("文档原文页码无效。") }
        }
    }
    private static func validateImageReferences(_ text: String, beside root: URL) throws {
        // Match the importer's supported inline image format. Fenced code and comments
        // are examples, not resources, and therefore are ignored.
        var fence: String?, lines: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let active = fence { if trimmed.hasPrefix(active) { fence = nil }; continue }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { fence = String(trimmed.prefix(3)); continue }
            lines.append(line)
        }
        let visible = lines.joined(separator: "\n").replacingOccurrences(of: #"(?s)<!--.*?-->"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(`+)[\s\S]*?\1"#, with: "", options: .regularExpression)
        let regex = try NSRegularExpression(pattern: #"!\[[^\]]*\]\(\s*(?:<([^>]+)>|([^\s)]+))(?:\s+\"[^\"]*\")?\s*\)"#)
        let ns = visible as NSString
        for match in regex.matches(in: visible, range: NSRange(location: 0, length: ns.length)) {
            let range = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
            let path = ns.substring(with: range)
            let file = try contained(path.removingPercentEncoding ?? path, root: root)
            guard exists(file) else { throw StudyError.message("学习材料缺少引用图片：\(path)") }
        }
    }
    private static func objectFile(_ url: URL) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else { throw StudyError.message("\(url.lastPathComponent) 格式无效。") }
        return object
    }
    private static func checkVersion(_ object: [String: Any], name: String) throws {
        guard finiteNumber(object["version"]) == 1 else { throw StudyError.message("\(name)版本暂不支持。") }
    }
    private static func array(_ object: [String: Any], _ key: String) throws -> [Any] {
        guard let value = object[key] else { return [] }
        guard let array = value as? [Any] else { throw StudyError.message("\(key) 应当是列表。") }
        return array
    }
    private static func stringDictionary(_ object: [String: Any], _ key: String) throws -> [String: String] {
        guard let value = object[key] else { return [:] }
        guard let dictionary = value as? [String: String] else { throw StudyError.message("\(key) 应当是文字映射。") }
        return dictionary
    }
    private static func optionalObject(_ object: [String: Any], _ key: String) throws -> [String: Any]? {
        guard let value = object[key], !(value is NSNull) else { return nil }
        guard let dictionary = value as? [String: Any] else { throw StudyError.message("\(key) 应当是记录对象。") }
        return dictionary
    }
    private static func optionalString(_ object: [String: Any], _ key: String) throws {
        guard let value = object[key], !(value is NSNull) else { return }
        guard value is String else { throw StudyError.message("\(key) 应当是文字。") }
    }
    private static func optionalNumber(_ object: [String: Any], _ key: String) throws {
        guard let value = object[key], !(value is NSNull) else { return }
        guard finiteNumber(value) != nil else { throw StudyError.message("\(key) 应当是有限数值。") }
    }
    private static func finiteNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
    private static func inventory(_ root: URL) throws -> [BackupFile] {
        try requireDirectory(root)
        var files: [BackupFile] = []
        func walk(_ directory: URL, prefix: String) throws {
            for item in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                let path = prefix + item.lastPathComponent
                guard validRelativePath(path) else { throw StudyError.message("资料中包含不支持的路径：\(path)") }
                let attrs = try fm.attributesOfItem(atPath: item.path)
                switch attrs[.type] as? FileAttributeType {
                case .typeDirectory: try walk(item, prefix: path + "/")
                case .typeRegular:
                    if prefix.isEmpty && item.lastPathComponent == manifestName { continue }
                    let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
                    guard size >= 0 else { throw StudyError.message("无法读取资源大小：\(path)") }
                    files.append(BackupFile(path: path, bytes: size, sha256: try hashFile(item)))
                default: throw StudyError.message("资料中包含符号链接或特殊文件，不能自动复制：\(path)")
                }
            }
        }
        try walk(root, prefix: "")
        return files.sorted { $0.path < $1.path }
    }
    private static func hashFile(_ url: URL) throws -> String {
        let attrs = try fm.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular else { throw StudyError.message("资源不是普通文件：\(url.lastPathComponent)") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hasher.update(data: data) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func contained(_ path: String, root: URL) throws -> URL {
        guard validRelativePath(path) else { throw StudyError.message("资源路径越出资料目录：\(path)") }
        let url = root.appendingPathComponent(path).standardizedFileURL
        guard isWithin(canonical(url), canonical(root)) else { throw StudyError.message("资源路径越出资料目录：\(path)") }
        return url
    }
    private static func validRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains("\\"), !path.contains(":"), !path.contains("\0") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    private static func validSingleName(_ path: String) -> Bool { validRelativePath(path) && !path.contains("/") }
    private static func validHash(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { $0.isHexDigit } }
    private static func prepareDirectory(_ url: URL) throws {
        if !exists(url) { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
        try requireDirectory(url)
    }
    private static func requireDirectory(_ url: URL) throws {
        guard url.isFileURL else { throw StudyError.message("学习资料必须位于本机文件夹。") }
        let attrs = try fm.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeDirectory else { throw StudyError.message("资料位置不是普通文件夹，未读取或覆盖。") }
    }
    private static func exists(_ url: URL) -> Bool { (try? fm.attributesOfItem(atPath: url.path)) != nil }
    private static func canonical(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }
    private static func isWithin(_ child: URL, _ parent: URL) -> Bool { child.path.hasPrefix(parent.path + "/") }
    private static func rejectOverlap(_ a: URL, _ b: URL) throws {
        let first = canonical(a), second = canonical(b)
        guard first.path != second.path, !isWithin(first, second), !isWithin(second, first) else {
            throw StudyError.message("来源与目标目录不能相同或互相包含。")
        }
    }
    private static func journalURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent("." + destination.lastPathComponent + "-restore-journal.json")
    }
    private static func timestamp() -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
