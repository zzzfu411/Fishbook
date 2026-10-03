import Foundation
import SwiftUI

/// User edits are separate from the shipped catalog. A title change never changes a PDF's identity.
struct PaperMetadata: Codable, Equatable {
    var name: String? = nil
    var title: String? = nil
    var area: String? = nil
    var year: Int? = nil
}

struct PaperWorkspace: Codable, Equatable {
    var metadata = PaperMetadata()
    var lastOpened: Date? = nil
    var queued = false
    var archived = false
    var removedAt: Date? = nil
    var removed: Bool { removedAt != nil }

    init() {}
    private enum CodingKeys: String, CodingKey { case metadata, lastOpened, queued, archived, removedAt }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        metadata = try c.decodeIfPresent(PaperMetadata.self, forKey: .metadata) ?? PaperMetadata()
        lastOpened = try c.decodeIfPresent(Date.self, forKey: .lastOpened)
        queued = try c.decodeIfPresent(Bool.self, forKey: .queued) ?? false
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        removedAt = try c.decodeIfPresent(Date.self, forKey: .removedAt)
    }
}

struct PaperReflection: Codable, Equatable {
    var problem = ""
    var mechanism = ""
    var evidence = ""
    var uncertainty = ""
    var updated: Date? = nil
    var isEmpty: Bool { [problem, mechanism, evidence, uncertainty].allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }

    init() {}
    private enum CodingKeys: String, CodingKey { case problem, mechanism, evidence, uncertainty, updated }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        problem = try c.decodeIfPresent(String.self, forKey: .problem) ?? ""
        mechanism = try c.decodeIfPresent(String.self, forKey: .mechanism) ?? ""
        evidence = try c.decodeIfPresent(String.self, forKey: .evidence) ?? ""
        uncertainty = try c.decodeIfPresent(String.self, forKey: .uncertainty) ?? ""
        updated = try c.decodeIfPresent(Date.self, forKey: .updated)
    }
}

struct PDFBookmark: Codable, Identifiable, Equatable {
    var id = UUID()
    var paperID: String
    var sha256: String
    var page: Int
    var title: String
    var created = Date()
}

struct LibraryFeatureData: Codable {
    var version = 1
    var papers: [String: PaperWorkspace] = [:]
    var drafts: [String: StudyNote] = [:]
    var reflections: [String: PaperReflection] = [:]
    var bookmarks: [PDFBookmark] = []

    init() {}
    private enum CodingKeys: String, CodingKey { case version, papers, drafts, reflections, bookmarks }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard version == 1 else { throw StudyError.message("整理记录版本暂不支持。原文件已保留。") }
        papers = try c.decodeIfPresent([String: PaperWorkspace].self, forKey: .papers) ?? [:]
        drafts = try c.decodeIfPresent([String: StudyNote].self, forKey: .drafts) ?? [:]
        reflections = try c.decodeIfPresent([String: PaperReflection].self, forKey: .reflections) ?? [:]
        bookmarks = try c.decodeIfPresent([PDFBookmark].self, forKey: .bookmarks) ?? []
        guard Set(bookmarks.map(\.id)).count == bookmarks.count,
              Set(drafts.values.map(\.id)).count == drafts.count,
              drafts.allSatisfy({ UUID(uuidString: $0.key) == $0.value.id && LibraryStorage.validNote($0.value) }),
              bookmarks.allSatisfy({ !$0.paperID.isEmpty && $0.sha256.count == 64 && $0.sha256.allSatisfy(\.isHexDigit) && $0.page >= 0 && $0.created.timeIntervalSinceReferenceDate.isFinite }),
              papers.keys.allSatisfy({ !$0.isEmpty }), reflections.keys.allSatisfy({ !$0.isEmpty }),
              papers.values.allSatisfy({ $0.metadata.year == nil || (0...2200).contains($0.metadata.year!) }) else {
            throw StudyError.message("整理记录内容不完整。原文件已保留。")
        }
        drafts = Dictionary(uniqueKeysWithValues: drafts.values.map { ($0.id.uuidString, $0) })
    }
}

/// All mutations are copy → validate/write → publish. A failed write never changes the live model.
@MainActor final class LibraryFeatureStore: ObservableObject {
    @Published private(set) var data = LibraryFeatureData()
    @Published private(set) var ready = false
    @Published var error: String? = nil
    @Published var notice: String? = nil
    @Published private(set) var pendingReflections: [String: PaperReflection] = [:]
    let dataURL: URL
    var stateURL: URL { dataURL.appendingPathComponent("workspace.json") }
    private var persistedBytes: Data? = nil
    private var persistenceSuspended = false
    private let encoder: JSONEncoder = {
        let value = JSONEncoder(); value.outputFormatting = [.prettyPrinted, .sortedKeys]; return value
    }()

    init(dataDirectory: URL, enabled: Bool = true) {
        dataURL = dataDirectory
        guard enabled else {
            error = "主资料库尚未成功载入，整理记录暂不可用；没有创建或修改资料目录。"
            return
        }
        do {
            try FileManager.default.createDirectory(at: dataURL, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: stateURL.path) {
                let bytes = try Data(contentsOf: stateURL)
                data = try JSONDecoder().decode(LibraryFeatureData.self, from: bytes)
                persistedBytes = bytes
            }
            ready = true
        } catch {
            self.error = "整理记录未能读取；原文件已保留，暂不写入：\(error.localizedDescription)"
        }
    }

    func setPersistenceSuspended(_ value: Bool) { persistenceSuspended = value }
    func entry(for id: String) -> PaperWorkspace { data.papers[id] ?? PaperWorkspace() }
    func displayPaper(_ paper: Paper) -> Paper {
        let meta = entry(for: paper.id).metadata
        var result = paper
        if let value = meta.name, !value.isEmpty { result.name = value }
        if let value = meta.title, !value.isEmpty { result.title = value }
        if let value = meta.area { result.area = value }
        if let value = meta.year { result.year = value }
        return result
    }

    @discardableResult func recordOpened(_ id: String) -> Bool {
        guard !id.isEmpty else { return false }
        return updatePaper(id) { $0.lastOpened = Date() }
    }
    @discardableResult func setQueued(_ id: String, _ value: Bool) -> Bool {
        let ok = updatePaper(id) { item in
            item.queued = value
            if value { item.archived = false }
        }
        if ok { notice = value ? "已加入待读" : "已移出待读" }
        return ok
    }
    @discardableResult func setArchived(_ id: String, _ value: Bool) -> Bool {
        let ok = updatePaper(id) { item in
            item.archived = value
            if value { item.queued = false }
        }
        if ok { notice = value ? "已归档，可在归档中找回" : "已取消归档" }
        return ok
    }
    @discardableResult func setRemoved(_ id: String, _ value: Bool) -> Bool {
        let ok = updatePaper(id) { $0.removedAt = value ? Date() : nil }
        if ok { notice = value ? "已移出论文列表，可在最近移出中恢复" : "论文已恢复" }
        return ok
    }
    @discardableResult func updateMetadata(_ id: String, metadata: PaperMetadata) -> Bool {
        var clean = metadata
        clean.name = clean.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        clean.title = clean.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        clean.area = clean.area?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.name == nil || !clean.name!.isEmpty,
              clean.title == nil || !clean.title!.isEmpty,
              clean.year == nil || (0...2200).contains(clean.year!) else {
            error = "请填写论文简称和标题；年份留空或填写有效年份。"; return false
        }
        let ok = updatePaper(id) { $0.metadata = clean }
        if ok { notice = "论文信息已更新" }
        return ok
    }

    func drafts(for paperID: String) -> [StudyNote] {
        data.drafts.values.filter { $0.paperID == paperID }.sorted { $0.created > $1.created }
    }
    @discardableResult func saveDraft(_ note: StudyNote) -> Bool {
        guard !note.paperID.isEmpty else { return false }
        return commit { $0.drafts[note.id.uuidString] = note }
    }
    @discardableResult func removeDraft(_ id: UUID) -> Bool {
        guard data.drafts[id.uuidString] != nil else { return true }
        return commit { $0.drafts.removeValue(forKey: id.uuidString) }
    }
    func reflection(for paperID: String) -> PaperReflection { pendingReflections[paperID] ?? data.reflections[paperID] ?? PaperReflection() }
    var hasPendingChanges: Bool { !pendingReflections.isEmpty }
    @discardableResult func saveReflection(_ reflection: PaperReflection, for paperID: String) -> Bool {
        guard !paperID.isEmpty else { return false }
        var stamped = reflection; stamped.updated = Date()
        let ok = commit { $0.reflections[paperID] = stamped }
        if ok { pendingReflections.removeValue(forKey: paperID) }
        else if !persistenceSuspended { pendingReflections[paperID] = reflection }
        return ok
    }
    @discardableResult func flushPendingChanges() -> Bool {
        guard !pendingReflections.isEmpty else { return true }
        let pending = pendingReflections
        let ok = commit { next in
            for (id, reflection) in pending {
                var stamped = reflection; stamped.updated = Date(); next.reflections[id] = stamped
            }
        }
        if ok { pendingReflections = [:] }
        return ok
    }

    /// Only bookmarks belonging to the current PDF version can navigate to that PDF.
    func bookmarks(for paper: Paper) -> [PDFBookmark] {
        data.bookmarks.filter { $0.paperID == paper.id && $0.sha256 == paper.sha256 && $0.page < paper.pages }
            .sorted { $0.page == $1.page ? $0.created < $1.created : $0.page < $1.page }
    }
    func obsoleteBookmarkCount(for paper: Paper) -> Int {
        data.bookmarks.filter { $0.paperID == paper.id && ($0.sha256 != paper.sha256 || $0.page >= paper.pages) }.count
    }
    @discardableResult func addBookmark(paper: Paper, page: Int, title: String = "") -> Bool {
        guard (0..<paper.pages).contains(page) else { error = "此页不能添加书签。"; return false }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let ok = commit { next in
            if let index = next.bookmarks.firstIndex(where: { $0.paperID == paper.id && $0.sha256 == paper.sha256 && $0.page == page }) {
                if !name.isEmpty { next.bookmarks[index].title = name }
            } else {
                next.bookmarks.append(PDFBookmark(paperID: paper.id, sha256: paper.sha256, page: page,
                    title: name.isEmpty ? "第 \(page + 1) 页" : name))
            }
        }
        if ok { notice = "已添加书签" }
        return ok
    }
    @discardableResult func removeBookmark(_ id: UUID) -> Bool {
        commit { $0.bookmarks.removeAll { $0.id == id } }
    }
    @discardableResult func renameBookmark(_ id: UUID, title: String) -> Bool {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }
        return commit { next in
            if let index = next.bookmarks.firstIndex(where: { $0.id == id }) { next.bookmarks[index].title = clean }
        }
    }

    private func updatePaper(_ id: String, change: (inout PaperWorkspace) -> Void) -> Bool {
        guard !id.isEmpty else { return false }
        return commit { next in
            var entry = next.papers[id] ?? PaperWorkspace(); change(&entry); next.papers[id] = entry
        }
    }
    private func commit(_ change: (inout LibraryFeatureData) -> Void) -> Bool {
        guard ready, !persistenceSuspended else {
            if !persistenceSuspended { error = "整理记录暂不可写入，请先恢复资料库。" }
            return false
        }
        var next = data; change(&next)
        do {
            let current = FileManager.default.fileExists(atPath: stateURL.path) ? try Data(contentsOf: stateURL) : nil
            guard current == persistedBytes else {
                throw StudyError.message("整理记录已被其他窗口或应用更改。请重新打开 Fishbook 后再保存，避免覆盖新记录。")
            }
            let bytes = try encoder.encode(next)
            // Decode before committing so malformed imported source data cannot become a saved state.
            _ = try JSONDecoder().decode(LibraryFeatureData.self, from: bytes)
            try bytes.write(to: stateURL, options: .atomic)
            data = next; persistedBytes = bytes; error = nil
            return true
        } catch {
            self.error = "未能保存整理记录：\(error.localizedDescription)"
            return false
        }
    }
}

enum NoteExportScope: Equatable {
    case currentPaper(String)
    case unresolved
    case all
    case selection(Set<UUID>)
}

enum NoteExport {
    static func select(_ scope: NoteExportScope, notes: [StudyNote]) -> [StudyNote] {
        notes.filter { note in
            switch scope {
            case .all: return true
            case .currentPaper(let id): return note.paperID == id
            case .unresolved: return note.kind == "疑问" && !note.resolved
            case .selection(let ids): return ids.contains(note.id)
            }
        }.sorted { $0.created < $1.created }
    }
    static func sourceLabel(_ note: StudyNote) -> String {
        if let source = note.documentSource {
            let title = source.documentTitle.isEmpty ? "中文材料" : source.documentTitle
            return title + (source.pdfPage.map { " · 原文第 \($0 + 1) 页" } ?? "")
        }
        if let page = note.anchors.first?.page { return "原文 · 第 \(page + 1) 页" }
        return "自由记录"
    }
    static func markdown(scope: NoteExportScope, notes: [StudyNote], papers: [Paper], reflections: [String: PaperReflection] = [:]) -> String {
        let selected = select(scope, notes: notes)
        let knownIDs = papers.map(\.id)
        let paperIDs = Set(selected.map(\.paperID))
        let orphaned = paperIDs.subtracting(knownIDs).sorted()
        let reflectionIDs: Set<String>
        switch scope {
        case .all: reflectionIDs = Set(reflections.filter { !$0.value.isEmpty }.keys)
        case .currentPaper(let id): reflectionIDs = [id]
        default: reflectionIDs = []
        }
        let allIDs = (knownIDs + orphaned + reflectionIDs.subtracting(knownIDs).subtracting(orphaned).sorted())
            .filter { paperIDs.contains($0) || reflectionIDs.contains($0) }
        var text = "# 我的论文学习记录\n\n"
        if selected.isEmpty && reflectionIDs.allSatisfy({ reflections[$0]?.isEmpty ?? true }) {
            return text + "此范围没有可导出的记录。\n"
        }
        for id in allIDs {
            let paper = papers.first { $0.id == id }
            text += "## \(singleLine(paper?.name ?? id))\n\n"
            if let paper { text += "论文：\(singleLine(paper.title))\n\n" }
            for note in selected.filter({ $0.paperID == id }) {
                text += "### \(singleLine(note.kind))\(note.resolved ? " · 已解决" : "")\n\n"
                text += "来源：\(singleLine(sourceLabel(note)))\n\n"
                if let hash = note.sourceSHA256, paper?.sha256 != hash {
                    text += "原文版本与当前 PDF 不同；此记录保留原始摘录。\n\n"
                }
                if !note.quote.isEmpty { text += "> " + note.quote.replacingOccurrences(of: "\n", with: "\n> ") + "\n\n" }
                if !note.body.isEmpty { text += note.body + "\n\n" }
            }
            if reflectionIDs.contains(id), let reflection = reflections[id], !reflection.isEmpty {
                text += "### 我的复述\n\n"
                for (title, body) in [("解决什么问题", reflection.problem), ("机制怎么运作", reflection.mechanism),
                                      ("证据能说明什么", reflection.evidence), ("还说不清的地方", reflection.uncertainty)] where !body.isEmpty {
                    text += "**\(title)**\n\n\(body)\n\n"
                }
            }
        }
        return text
    }
    private static func singleLine(_ text: String) -> String { text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ") }
}
