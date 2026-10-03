import Foundation
import AppKit
import Combine

enum DocumentKind: String, Codable, CaseIterable {
    case explanation, translation
    var title: String { self == .explanation ? "深度理解" : "全文翻译" }
}

struct StudyDocument: Codable, Identifiable, Equatable {
    var id: String
    var paperID: String
    var sha256: String
    var kind: DocumentKind
    var title: String
    var status: String
    var coverage: String
    var relativePath: String
    var previousRevisionID: String? = nil
    var revision: Int? = nil
    var importedAt: Date? = nil
    var statusTitle: String {
        if status == "complete" { return kind == .translation ? "完整译稿" : "理解文档" }
        if status == "unverified" { return "导入材料 · 未校核" }
        return kind == .translation ? "部分译稿" : "重点讲解"
    }
}

struct DocumentUserState: Codable {
    var version = 1
    var imported: [StudyDocument] = []
    var modes: [String: String] = [:]
    var selections: [String: String] = [:]
    var progress: [String: Double] = [:]
    var locations: [String: DocumentReadingLocation] = [:]

    enum CodingKeys: String, CodingKey { case version, imported, modes, selections, progress, locations }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        imported = try c.decodeIfPresent([StudyDocument].self, forKey: .imported) ?? []
        modes = try c.decodeIfPresent([String:String].self, forKey: .modes) ?? [:]
        selections = try c.decodeIfPresent([String:String].self, forKey: .selections) ?? [:]
        progress = try c.decodeIfPresent([String:Double].self, forKey: .progress) ?? [:]
        locations = try c.decodeIfPresent([String:DocumentReadingLocation].self, forKey: .locations) ?? [:]
    }
}

/// Documents are optional learning material. Their failure cannot disable PDFs or notes.
@MainActor final class DocumentStore: NSObject, ObservableObject {
    @Published private(set) var documents: [StudyDocument] = []
    @Published private(set) var warnings: [String] = []
    @Published private(set) var state = DocumentUserState()
    @Published var error: String?
    @Published private(set) var saveFailed = false
    @Published private(set) var ready = true
    let resources: URL
    let dataURL: URL
    private var knownPapers: [Paper] = []
    private var bundled: [StudyDocument] = []
    private var importedIDs = Set<String>()
    private var progressWork: DispatchWorkItem?
    private var persistenceSuspended = false
    private let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }()
    var stateURL: URL { dataURL.appendingPathComponent("documents.json") }
    var bundledRoot: URL { resources.appendingPathComponent("content/documents", isDirectory: true) }
    var importedRoot: URL { dataURL.appendingPathComponent("documents", isDirectory: true) }

    init(resources: URL, dataURL: URL) {
        self.resources = resources; self.dataURL = dataURL
        super.init()
        if FileManager.default.fileExists(atPath: stateURL.path) {
            do {
                state = try JSONDecoder().decode(DocumentUserState.self, from: Data(contentsOf: stateURL))
                guard state.version == 1, state.progress.values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }),
                      state.locations.values.allSatisfy({ !$0.blockID.isEmpty && $0.progress.isFinite && $0.progress >= 0 && $0.progress <= 1 && $0.blockOffset.isFinite && $0.blockOffset >= 0 && $0.blockOffset <= 1 && ($0.pdfPage == nil || $0.pdfPage! >= 0) }),
                      Set(state.imported.map(\.id)).count == state.imported.count else {
                    throw StudyError.message("文档记录版本或格式无效")
                }
            } catch {
                ready = false; saveFailed = true
                self.error = "文档记录无法载入，原文件已保留。内置文档和论文仍可阅读；请先备份后检查 documents.json。\n\(error.localizedDescription)"
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(flushProgress), name: NSApplication.willTerminateNotification, object: nil)
    }

    func load(papers: [Paper]) {
        knownPapers = papers
        var messages: [String] = []
        var valid: [StudyDocument] = []
        let index = bundledRoot.appendingPathComponent("index.json")
        if FileManager.default.fileExists(atPath: index.path) {
            do {
                // Decode entries separately so a single damaged optional document is isolated.
                guard let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [Any] else {
                    throw StudyError.message("内置文档清单不是数组")
                }
                for (i, row) in rows.enumerated() {
                    do {
                        guard let object = row as? [String: Any] else { throw StudyError.message("文档条目必须是对象") }
                        let item = try JSONDecoder().decode(StudyDocument.self, from: JSONSerialization.data(withJSONObject: object))
                        try validate(item, root: bundledRoot)
                        guard !valid.contains(where: { $0.id == item.id }) else { throw StudyError.message("重复文档 ID") }
                        valid.append(item)
                    } catch { messages.append("内置文档第 \(i + 1) 项未载入：\(error.localizedDescription)") }
                }
            } catch { messages.append("内置文档清单未载入：\(error.localizedDescription)") }
        }
        bundled = valid
        importedIDs = []
        if ready {
            for item in state.imported {
                do {
                    try validate(item, root: importedRoot)
                    guard !valid.contains(where: { $0.id == item.id }) else { throw StudyError.message("重复文档 ID") }
                    valid.append(item); importedIDs.insert(item.id)
                } catch { messages.append("「\(item.title)」未载入：\(error.localizedDescription)。原文件已保留。") }
            }
        }
        documents = valid; warnings = messages
    }

    private func validate(_ item: StudyDocument, root: URL) throws {
        guard let paper = knownPapers.first(where: { $0.id == item.paperID }), paper.sha256 == item.sha256 else {
            throw StudyError.message("文档与 PDF 版本不匹配")
        }
        guard !item.id.isEmpty, !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !item.coverage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ["complete", "partial", "unverified"].contains(item.status) else {
            throw StudyError.message("文档类型、标题或覆盖声明不完整")
        }
        let url = try Self.containedURL(item.relativePath, root: root)
        guard ["md", "markdown", "txt"].contains(url.pathExtension.lowercased()),
              FileManager.default.fileExists(atPath: url.path) else { throw StudyError.message("缺少 Markdown 文档") }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attrs[.size] as? NSNumber, size.intValue <= 20 * 1024 * 1024,
              let text = String(data: try Data(contentsOf: url), encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StudyError.message("文档为空、不是 UTF-8，或超过 20 MB")
        }
    }

    static func containedURL(_ path: String, root: URL) throws -> URL {
        let decoded = path.removingPercentEncoding ?? path
        guard !decoded.isEmpty, !decoded.hasPrefix("/"), !decoded.hasPrefix("~"),
              !decoded.contains(":"), !decoded.contains("\\"),
              !decoded.split(separator: "/").contains("..") else {
            throw StudyError.message("文档资源路径必须位于当前资料目录内")
        }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let url = base.appendingPathComponent(decoded).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(base.path + "/") else { throw StudyError.message("资源越出文档目录") }
        return url
    }

    private static func imageSource(_ markdown: String) -> String {
        var fence: String?
        var visible: [String] = []
        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let active = fence {
                if trimmed.hasPrefix(active) { fence = nil }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { fence = String(trimmed.prefix(3)); continue }
            visible.append(line)
        }
        return visible.joined(separator: "\n")
            .replacingOccurrences(of: #"(?s)<!--.*?-->"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(`+)[\s\S]*?\1"#, with: "", options: .regularExpression)
    }

    func url(for document: StudyDocument) -> URL? {
        try? Self.containedURL(document.relativePath, root: importedIDs.contains(document.id) ? importedRoot : bundledRoot)
    }
    func list(for paper: Paper, kind: DocumentKind) -> [StudyDocument] {
        documents.filter { $0.paperID == paper.id && $0.sha256 == paper.sha256 && $0.kind == kind }
    }
    func currentList(for paper: Paper, kind: DocumentKind) -> [StudyDocument] {
        let all = list(for: paper, kind: kind)
        let superseded = Set(all.compactMap(\.previousRevisionID))
        return all.filter { !superseded.contains($0.id) }
    }
    func document(id: String) -> StudyDocument? { documents.first { $0.id == id } }
    func isHistorical(_ item: StudyDocument) -> Bool { documents.contains { $0.previousRevisionID == item.id } }
    private func selectionKey(_ paperID: String, _ kind: DocumentKind) -> String { paperID + ":" + kind.rawValue }
    func selected(for paper: Paper, kind: DocumentKind) -> StudyDocument? {
        let options = list(for: paper, kind: kind)
        let key = selectionKey(paper.id, kind)
        if let id = state.selections[key], let item = options.first(where: { $0.id == id }) { return item }
        let current = currentList(for: paper, kind: kind)
        return current.first(where: { $0.status == "complete" }) ?? current.last ?? options.first
    }
    func selectedID(for paper: Paper, kind: DocumentKind) -> String? { selected(for: paper, kind: kind)?.id }
    func prefersInteractiveGuide(for paper: Paper) -> Bool {
        let selected = state.selections[selectionKey(paper.id, .explanation)]
        if selected == nil { return list(for: paper, kind: .explanation).isEmpty }
        return selected == "__interactive__" || !list(for: paper, kind: .explanation).contains(where: { $0.id == selected })
    }
    func selectInteractiveGuide(for paper: Paper) {
        let previous = state
        state.selections[selectionKey(paper.id, .explanation)] = "__interactive__"
        if !save() { state = previous }
    }
    func select(_ id: String, paper: Paper, kind: DocumentKind) {
        guard list(for: paper, kind: kind).contains(where: { $0.id == id }) else { return }
        let previous = state
        state.selections[selectionKey(paper.id, kind)] = id
        if !save() { state = previous }
    }
    func mode(for paperID: String?) -> String {
        guard let id = paperID, let value = state.modes[id], ["explanation", "translation", "notes"].contains(value) else { return "explanation" }
        return value
    }
    func setMode(_ value: String, paperID: String?) {
        guard let id = paperID, ["explanation", "translation", "notes"].contains(value) else { return }
        guard state.modes[id] != value else { return }
        let previous = state
        state.modes[id] = value
        if !save() { state = previous }
    }
    func progress(for id: String) -> Double { state.progress[id] ?? 0 }
    func location(for id: String) -> DocumentReadingLocation? { state.locations[id] }
    private func knownDocument(_ id: String) -> Bool {
        documents.contains { $0.id == id } || knownPapers.contains { id.hasPrefix("guide:\($0.id):") }
    }
    func setLocation(_ location: DocumentReadingLocation, documentID: String) {
        guard !persistenceSuspended, knownDocument(documentID), location.progress.isFinite,
              !location.blockID.isEmpty, location.pdfPage == nil || location.pdfPage! >= 0,
              location.blockOffset.isFinite, (0...1).contains(location.blockOffset), (0...1).contains(location.progress) else { return }
        guard state.locations[documentID] != location else { return }
        state.locations[documentID] = location
        state.progress[documentID] = location.progress
        scheduleProgressSave()
    }
    func setProgress(_ value: Double, documentID: String) {
        guard !persistenceSuspended, value.isFinite, knownDocument(documentID) else { return }
        let bounded = min(1, max(0, value))
        guard abs((state.progress[documentID] ?? 0) - bounded) > 0.0001 else { return }
        state.progress[documentID] = bounded
        scheduleProgressSave()
    }
    private func scheduleProgressSave() {
        progressWork?.cancel()
        let work = DispatchWorkItem { [weak self] in _ = self?.flushProgress() }
        progressWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }
    @objc @discardableResult func flushProgress() -> Bool {
        progressWork?.cancel(); progressWork = nil
        return save()
    }
    func setPersistenceSuspended(_ value: Bool) {
        persistenceSuspended = value
        if value { progressWork?.cancel(); progressWork = nil }
    }

    @discardableResult func save() -> Bool {
        guard ready, !persistenceSuspended else { return false }
        do {
            try FileManager.default.createDirectory(at: dataURL, withIntermediateDirectories: true)
            try encoder.encode(state).write(to: stateURL, options: .atomic)
            saveFailed = false; return true
        } catch {
            saveFailed = true; self.error = "文档阅读记录保存失败：\(error.localizedDescription)"; return false
        }
    }

    /// Copy a self-contained document; never retain an external file URL or execute input HTML.
    @discardableResult func importMarkdown(_ source: URL, paper: Paper, kind: DocumentKind, updating previousDocument: StudyDocument? = nil, title: String? = nil) -> Bool {
        guard ready else { error = "请先处理文档记录的载入错误，原资料仍然保留。"; return false }
        guard !persistenceSuspended else { return false }
        if let previousDocument {
            guard documents.contains(previousDocument), previousDocument.paperID == paper.id,
                  previousDocument.sha256 == paper.sha256, previousDocument.kind == kind else {
                error = "更新材料必须属于同一论文、同一 PDF 版本与同一材料类型。"; return false
            }
        }
        let id = "user-" + UUID().uuidString
        let destination = importedRoot.appendingPathComponent(id, isDirectory: true)
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: destination) } }
        do {
            guard ["md", "markdown", "txt"].contains(source.pathExtension.lowercased()) else { throw StudyError.message("请选择 Markdown 或纯文本文件") }
            let attrs = try FileManager.default.attributesOfItem(atPath: source.path)
            guard ((attrs[.size] as? NSNumber)?.intValue ?? Int.max) <= 20 * 1024 * 1024 else { throw StudyError.message("文档超过 20 MB") }
            let data = try Data(contentsOf: source)
            guard let markdown = String(data: data, encoding: .utf8), !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw StudyError.message("请选择有内容的 UTF-8 文档")
            }
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try data.write(to: destination.appendingPathComponent("document.md"), options: .atomic)
            // Only inline image references are copied. Reference-style images must be expanded first.
            let imagePattern = #"!\[[^\]]*\]\(\s*(?:<([^>]+)>|([^\s)]+))(?:\s+\"[^\"]*\")?\s*\)"#
            let regex = try NSRegularExpression(pattern: imagePattern)
            let imageText = Self.imageSource(markdown)
            let ns = imageText as NSString
            var seen = Set<String>()
            var totalImageBytes = 0
            for match in regex.matches(in: imageText, range: NSRange(location: 0, length: ns.length)) {
                let capture = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
                let relative = ns.substring(with: capture)
                guard !relative.lowercased().hasPrefix("http"), !relative.lowercased().hasPrefix("data:") else {
                    throw StudyError.message("文档包含远程或内嵌图片。请将图片保存到文档旁的 assets 文件夹，并改用相对路径。")
                }
                if !seen.insert(relative).inserted { continue }
                let from = try Self.containedURL(relative, root: source.deletingLastPathComponent())
                let to = try Self.containedURL(relative, root: destination)
                guard ["png", "jpg", "jpeg", "gif", "webp"].contains(from.pathExtension.lowercased()) else {
                    throw StudyError.message("只支持本地 PNG、JPEG、GIF、WebP 图片")
                }
                let imageAttrs = try FileManager.default.attributesOfItem(atPath: from.path)
                let count = (imageAttrs[.size] as? NSNumber)?.intValue ?? Int.max
                guard count <= 30 * 1024 * 1024, totalImageBytes <= 200 * 1024 * 1024 - count else {
                    throw StudyError.message("图片过大：单张上限 30 MB，整份文档上限 200 MB")
                }
                totalImageBytes += count
                try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: from, to: to)
            }
            let referenceImage = try NSRegularExpression(pattern: #"!\[[^\]]*\]\s*\["#)
            guard referenceImage.firstMatch(in: imageText, range: NSRange(location: 0, length: ns.length)) == nil else {
                throw StudyError.message("请先将引用式图片改为 ![说明](assets/图片.png)，以便连同图片完整导入。")
            }
            let item = StudyDocument(id: id, paperID: paper.id, sha256: paper.sha256, kind: kind,
                title: title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? title! : source.deletingPathExtension().lastPathComponent, status: "unverified",
                coverage: "你导入的本地材料；尚未核对是否覆盖全文。原文页码可使用“## 原文第 N 页”标题。",
                relativePath: id + "/document.md", previousRevisionID: previousDocument?.id,
                revision: (previousDocument?.revision ?? (previousDocument == nil ? 0 : 1)) + 1, importedAt: Date())
            try validate(item, root: importedRoot)
            let previous = state
            state.imported.append(item)
            state.selections[selectionKey(paper.id, kind)] = id
            state.modes[paper.id] = kind.rawValue
            if let old = previousDocument {
                state.progress[id] = state.progress[old.id]
                state.locations[id] = state.locations[old.id]
            }
            guard save() else { state = previous; return false }
            committed = true; importedIDs.insert(id); documents.append(item)
            return true
        } catch { self.error = "文档未导入：\(error.localizedDescription)"; return false }
    }
}
