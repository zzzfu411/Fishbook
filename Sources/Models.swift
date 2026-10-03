import Foundation
import SwiftUI
import AppKit
import PDFKit
import CryptoKit

enum StudyBrand {
    static let name="Fishbook"
    static let tagline="把论文读明白"
}

struct Box: Codable, Equatable {
    var x: Double; var y: Double; var width: Double; var height: Double
    var cg: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    init(_ r: CGRect) { x=r.origin.x; y=r.origin.y; width=r.width; height=r.height }
}
struct Anchor: Codable, Equatable {
    var page: Int
    var rects: [Box]
    var quote: String
}
struct Paper: Codable, Identifiable, Hashable {
    var id: String; var name: String; var title: String; var file: String
    var pages: Int; var sha256: String; var area: String; var year: Int
}
struct Section: Codable, Identifiable {
    var title: String; var body: String
    var id: String { title }
}
struct Concept: Codable, Identifiable {
    var id: String; var title: String; var summary: String
    var anchor: Anchor; var prerequisites: [String]; var sections: [Section]
}
struct Guide: Codable {
    var paperID: String; var sha256: String; var subtitle: String
    var overview: [Section]; var concepts: [Concept]
    var exercise: String; var answer: String
}
struct Catalog: Codable { var papers: [Paper]; var guides: [Guide] }
struct ReadingPosition: Codable {
    var page: Int; var x: Double; var y: Double
    var sourceSHA256: String? = nil
}
struct DocumentReadingLocation: Codable, Equatable {
    var blockID: String
    var quote: String
    var blockOffset: Double
    var progress: Double
    var pdfPage: Int? = nil
}
struct DocumentNoteSource: Codable, Equatable {
    var documentID: String
    var documentTitle: String
    var blockID: String
    var quote: String
    var blockOffset: Double
    var progress: Double
    var pdfPage: Int? = nil
}

enum PDFMarkupStyle: String, Codable, CaseIterable, Identifiable {
    case highlight, underline, strikeOut
    var id: String { rawValue }
    var title: String {
        switch self {
        case .highlight: return "高亮"
        case .underline: return "下划线"
        case .strikeOut: return "删除线"
        }
    }
    var symbol: String {
        switch self {
        case .highlight: return "highlighter"
        case .underline: return "underline"
        case .strikeOut: return "strikethrough"
        }
    }
}

enum PDFMarkupColor: String, Codable, CaseIterable, Identifiable {
    case yellow, green, blue, pink, purple, orange
    var id: String { rawValue }
    var title: String {
        switch self {
        case .yellow: return "黄色"
        case .green: return "绿色"
        case .blue: return "蓝色"
        case .pink: return "粉色"
        case .purple: return "紫色"
        case .orange: return "橙色"
        }
    }
    var nsColor: NSColor {
        let rgb: (CGFloat, CGFloat, CGFloat)
        switch self {
        case .yellow: rgb = (0.96, 0.77, 0.20)
        case .green: rgb = (0.28, 0.70, 0.43)
        case .blue: rgb = (0.29, 0.59, 0.88)
        case .pink: rgb = (0.92, 0.40, 0.62)
        case .purple: rgb = (0.62, 0.43, 0.83)
        case .orange: rgb = (0.94, 0.53, 0.20)
        }
        return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
    }
}

struct StudyNote: Codable, Identifiable {
    var id: UUID = UUID()
    var paperID: String
    var sourceSHA256: String? = nil
    var documentSource: DocumentNoteSource? = nil
    var kind: String
    var body: String
    var quote: String
    var anchors: [Anchor]
    var markupStyle: PDFMarkupStyle? = nil
    var markupColor: PDFMarkupColor? = nil
    var resolved: Bool = false
    var created: Date = Date()

    var effectiveMarkupStyle: PDFMarkupStyle {
        documentSource == nil ? (markupStyle ?? .highlight) : .highlight
    }
    var effectiveMarkupColor: PDFMarkupColor {
        let legacy: PDFMarkupColor = kind == "疑问" ? .orange : .yellow
        return documentSource == nil ? (markupColor ?? legacy) : legacy
    }
}
struct UserData: Codable {
    var version = 1
    var selectedID: String? = nil
    var positions: [String: ReadingPosition] = [:]
    var notes: [StudyNote] = []
    var stages: [String: String] = [:]
    var exercises: [String: String] = [:]
    var importedPapers: [Paper] = []
    var fontSize: Double = 15
    var welcomed = false
}
enum StudyError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(s) = self { return s }; return nil }
}

struct PDFImportResult: Identifiable {
    enum Outcome { case added, existing, failed }
    let id = UUID()
    let filename: String
    let outcome: Outcome
    let detail: String
}

/// PDF parsing and hashing can run away from the UI; catalog commits stay on the main actor.
private struct PreparedPDF {
    let name: String
    let title: String
    let bytes: Data
    let hash: String
    let pages: Int
    static func read(_ url: URL) throws -> PreparedPDF {
        guard url.isFileURL, url.pathExtension.lowercased() == "pdf" else {
            throw StudyError.message("请选择 PDF 文件。")
        }
        let bytes = try Data(contentsOf: url)
        guard let doc = PDFDocument(data: bytes), !doc.isLocked, doc.pageCount > 0 else {
            throw StudyError.message("文件无法读取，或 PDF 已加密。")
        }
        let name = url.deletingPathExtension().lastPathComponent
        return PreparedPDF(name: name,
            title: (doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String) ?? name,
            bytes: bytes, hash: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), pages: doc.pageCount)
    }
}

@MainActor final class StudyStore: ObservableObject {
    @Published var papers: [Paper] = []
    @Published var guides: [String: Guide] = [:]
    @Published var selectedID: String? = nil
    @Published var conceptID: String? = nil
    @Published var guideRequest = UUID()
    @Published var trail: [String?] = []
    @Published var data = UserData()
    @Published var error: String? = nil
    @Published var notice: String? = nil
    @Published var saveFailed = false
    @Published var ready = false
    @Published var contentWarnings: [String] = []
    @Published private(set) var isImporting = false
    @Published private(set) var importProgress = ""
    @Published private(set) var importResults: [PDFImportResult] = []
    let dataURL: URL
    let resources: URL
    private var overrides: [Guide] = []
    private var damagedOverrides = false
    private var committedData = UserData()
    private var persistenceSuspended = false
    let storageNotice: String?
    let migratedFrom: URL?
    func setPersistenceSuspended(_ value: Bool) { persistenceSuspended = value }
    var paper: Paper? { papers.first { $0.id == selectedID } }
    var guide: Guide? { selectedID.flatMap { guides[$0] } }
    var concept: Concept? { guide?.concepts.first { $0.id == conceptID } }
    var notes: [StudyNote] { data.notes.filter { $0.paperID == selectedID }.sorted { $0.created > $1.created } }
    var unresolvedPaperIDs: Set<String> { Set(data.notes.filter { $0.kind == "疑问" && !$0.resolved }.map(\.paperID)) }
    func unresolvedCount(for paperID: String) -> Int { data.notes.filter { $0.paperID == paperID && $0.kind == "疑问" && !$0.resolved }.count }
    var stateURL: URL { dataURL.appendingPathComponent("state.json") }
    let encoder: JSONEncoder = {
        let e=JSONEncoder(); e.outputFormatting=[.prettyPrinted, .sortedKeys]; return e
    }()
    init(resourceDirectory:URL?=nil,dataDirectory:URL?=nil) {
        resources = resourceDirectory ?? Bundle.main.resourceURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let location = Result { try LibraryStorage.resolve(dataDirectory: dataDirectory) }
        switch location {
        case .success(let resolved):
            dataURL = resolved.directory; storageNotice = resolved.notice; migratedFrom = resolved.migratedFrom
        case .failure:
            dataURL = dataDirectory ?? ProcessInfo.processInfo.environment["PAPER_STUDY_DATA_DIR"].map { URL(fileURLWithPath: $0) } ?? LibraryStorage.defaultDirectory
            storageNotice = nil; migratedFrom = nil
        }
        do {
            _ = try location.get()
            let catalog=try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: resources.appendingPathComponent("content/library.json")))
            try FileManager.default.createDirectory(at:dataURL,withIntermediateDirectories:true)
            if FileManager.default.fileExists(atPath:stateURL.path) {
                data=try JSONDecoder().decode(UserData.self,from:Data(contentsOf:stateURL))
                try LibraryStorage.validateUserData(data)
            }
            guard Set(catalog.papers.map(\.id)).count == catalog.papers.count else { throw StudyError.message("内置文献目录存在重复 ID。") }
            papers=catalog.papers
            loadSupplementalPapers()
            for p in data.importedPapers {
                guard !papers.contains(where:{$0.id == p.id}) else { throw StudyError.message("学习资料中存在重复文献 ID：\(p.id)。") }
                papers.append(p)
            }
            migrateLegacySources()
            for id in data.stages.keys where data.stages[id] == "仍有疑问" { data.stages[id] = "阅读中" }
            for g in catalog.guides {
                do { try validate(g); guides[g.paperID]=g }
                catch { contentWarnings.append("内置讲解 \(g.paperID)：\(error.localizedDescription)") }
            }
            let url=dataURL.appendingPathComponent("guides.json")
            if FileManager.default.fileExists(atPath:url.path) {
                do {
                    let loaded=try JSONDecoder().decode([Guide].self,from:Data(contentsOf:url))
                    var seen=Set<String>()
                    for g in loaded {
                        do {
                            guard seen.insert(g.paperID).inserted else { throw StudyError.message("补充讲解包含重复论文：\(g.paperID)。") }
                            try validate(g);overrides.append(g);guides[g.paperID]=g
                        } catch { damagedOverrides=true;contentWarnings.append("补充讲解 \(g.paperID)：\(error.localizedDescription)") }
                    }
                } catch { damagedOverrides=true;contentWarnings.append("补充讲解包无法读取，已保留原文件并使用可用的内置讲解：\(error.localizedDescription)") }
            }
            if data.selectedID == nil, FileManager.default.fileExists(atPath: stateURL.path) {
                selectedID = nil // An explicitly cleared selection survives reopening.
            } else {
                selectedID = papers.contains { $0.id == data.selectedID } ? data.selectedID : papers.first?.id
            }
            data.selectedID = selectedID
            committedData = data
            ready=true
            notice = storageNotice
            if !contentWarnings.isEmpty { self.error="部分内容暂不可用，原文和个人记录仍可使用。\n"+contentWarnings.joined(separator:"\n") }
        } catch { self.error="载入失败：\(error.localizedDescription)\n原有学习资料没有被覆盖。"; saveFailed=true }
    }
    private func loadSupplementalPapers() {
        let url=resources.appendingPathComponent("content/supplemental-papers.json")
        guard FileManager.default.fileExists(atPath:url.path) else { return }
        do {
            let extra=try JSONDecoder().decode([Paper].self,from:Data(contentsOf:url))
            for p in extra {
                let components=p.file.split(separator:"/",omittingEmptySubsequences:false)
                guard !p.id.isEmpty, !papers.contains(where:{$0.id == p.id}), p.pages > 0,
                      p.sha256.count == 64, p.sha256.allSatisfy({$0.isHexDigit}),
                      p.file.hasPrefix("papers/"), !components.contains(".."), !components.contains("") else {
                    contentWarnings.append("附加文献格式不完整或 ID 重复：\(p.id)。");continue
                }
                papers.append(p)
            }
        } catch { contentWarnings.append("附加文献目录未载入：\(error.localizedDescription)") }
    }
    private func migrateLegacySources() {
        // Only a known old manifest can identify old bundled records. Never infer
        // their version from a possibly newer current catalog.
        let url=resources.appendingPathComponent("content/legacy-paper-fingerprints.json")
        var known=(try? JSONDecoder().decode([String:String].self,from:Data(contentsOf:url))) ?? [:]
        for p in data.importedPapers { known[p.id]=p.sha256 }
        for i in data.notes.indices where data.notes[i].sourceSHA256 == nil {
            data.notes[i].sourceSHA256=known[data.notes[i].paperID]
        }
        for id in Array(data.positions.keys) where data.positions[id]?.sourceSHA256 == nil {
            data.positions[id]?.sourceSHA256=known[id]
        }
    }
    func canLocate(_ note:StudyNote)->Bool {
        guard let p=papers.first(where:{$0.id == note.paperID}) else { return false }
        guard note.sourceSHA256 == p.sha256 else { return false }
        if let source = note.documentSource {
            return !source.documentID.isEmpty && source.blockOffset.isFinite && source.progress.isFinite
        }
        return true
    }
    func annotationNotes(for paperID:String)->[StudyNote] {
        data.notes.filter { $0.paperID == paperID && $0.documentSource == nil && canLocate($0) }
    }
    func readingPosition(for paperID:String)->ReadingPosition? {
        guard let p=papers.first(where:{$0.id == paperID}),let pos=data.positions[paperID],
              pos.sourceSHA256 == p.sha256, pos.page >= 0, pos.page < p.pages,
              pos.x.isFinite,pos.y.isFinite else {return nil}
        return pos
    }
    func validate(_ g: Guide) throws {
        guard let p=papers.first(where:{$0.id == g.paperID}), p.sha256 == g.sha256 else {
            throw StudyError.message("讲解 \(g.paperID) 与当前 PDF 版本不匹配。")
        }
        func validSections(_ sections:[Section])->Bool {
            !sections.isEmpty && Set(sections.map(\.id)).count == sections.count &&
            sections.allSatisfy { !$0.title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && !$0.body.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }
        }
        guard !g.subtitle.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              validSections(g.overview),Set(g.concepts.map(\.id)).count == g.concepts.count,
              !g.concepts.isEmpty,
              g.concepts.allSatisfy({ c in !c.id.isEmpty && !c.title.isEmpty && c.sections.count == 7 && validSections(c.sections) &&
                  c.anchor.page >= 0 && c.anchor.page < p.pages &&
                  !c.anchor.rects.isEmpty &&
                  c.anchor.rects.allSatisfy { $0.width > 0 && $0.height > 0 } &&
                  c.prerequisites.allSatisfy { ref in g.concepts.contains { $0.id == ref } }
              }) else { throw StudyError.message("讲解格式或原文定位不完整：\(g.paperID)") }
        let bytes=try Data(contentsOf:fileURL(p))
        guard SHA256.hash(data:bytes).map({String(format:"%02x",$0)}).joined() == p.sha256,
              let document=PDFDocument(data:bytes),!document.isLocked,document.pageCount == p.pages else {
            throw StudyError.message("讲解对应的原文文件或页数不匹配：\(g.paperID)。")
        }
        func normal(_ text:String)->String { text.lowercased().filter {$0.isLetter || $0.isNumber} }
        for c in g.concepts {
            guard let page=document.page(at:c.anchor.page),
                  c.anchor.rects.allSatisfy({page.bounds(for:.cropBox).insetBy(dx:-2,dy:-2).contains($0.cg)}) else {
                throw StudyError.message("概念“\(c.title)”的定位超出 PDF 页面。")
            }
            let actual=c.anchor.rects.compactMap {page.selection(for:$0.cg)?.string}.joined(separator:" ")
            let quote=normal(c.anchor.quote)
            guard !quote.isEmpty,normal(actual).contains(quote) else { throw StudyError.message("概念“\(c.title)”的引文与原文定位不一致。") }
        }
    }
    func fileURL(_ p: Paper) -> URL {
        p.file.hasPrefix("imports/") ? dataURL.appendingPathComponent(p.file) : resources.appendingPathComponent("content/\(p.file)")
    }
    /// A failed write never promotes a draft or an optimistic UI mutation into saved state.
    @discardableResult private func commit(_ candidate: UserData) -> Bool {
        guard ready, !persistenceSuspended else { return false }
        do {
            try LibraryStorage.validateUserData(candidate)
            try encoder.encode(candidate).write(to: stateURL, options: .atomic)
            data = candidate; committedData = candidate; selectedID = candidate.selectedID
            saveFailed = false
            return true
        } catch {
            data = committedData; selectedID = committedData.selectedID
            self.error = "保存失败：\(error.localizedDescription)。本次修改未写入，已保存的记录保持不变。"
            saveFailed = true; notice = nil; return false
        }
    }
    @discardableResult func save() -> Bool {
        var candidate = data; candidate.selectedID = selectedID
        return commit(candidate)
    }
    @discardableResult func select(_ id: String?) -> Bool {
        guard ready, let id, papers.contains(where: { $0.id == id }) else { return false }
        var candidate = data; candidate.selectedID = id
        guard commit(candidate) else { return false }
        conceptID = nil; trail = []; notice = nil; return true
    }
    @discardableResult func clearSelection() -> Bool {
        var candidate = data; candidate.selectedID = nil
        guard commit(candidate) else { return false }
        conceptID = nil; trail = []; notice = nil; return true
    }
    @discardableResult func setStage(_ stage: String, for paperID: String) -> Bool {
        guard ["未开始", "阅读中", "已完成"].contains(stage), papers.contains(where: { $0.id == paperID }) else { return false }
        var candidate = data; candidate.stages[paperID] = stage
        return commit(candidate)
    }
    @discardableResult func setFontSize(_ size: Double) -> Bool {
        guard size.isFinite, (13...22).contains(size) else { return false }
        var candidate = data; candidate.fontSize = size
        return commit(candidate)
    }
    @discardableResult func setExercise(_ text: String, for paperID: String) -> Bool {
        guard papers.contains(where: { $0.id == paperID }) else { return false }
        var candidate = data; candidate.exercises[paperID] = text
        return commit(candidate)
    }
    @discardableResult func markWelcomed() -> Bool {
        var candidate = data; candidate.welcomed = true
        return commit(candidate)
    }
    func showConcept(_ id: String) {
        guard guide?.concepts.contains(where:{$0.id == id}) == true else {return}
        if conceptID != id { trail.append(conceptID); conceptID=id }
        guideRequest=UUID()
    }
    func back() { if let last=trail.popLast() { conceptID=last } else { conceptID=nil } }
    func overview() { conceptID=nil; trail=[] }
    func setPosition(_ id:String,_ position:ReadingPosition) {
        guard let p=papers.first(where:{$0.id == id}),position.page >= 0,position.page < p.pages,
              position.x.isFinite,position.y.isFinite,
              position.sourceSHA256 == nil || position.sourceSHA256 == p.sha256 else {return}
        var stamped=position;stamped.sourceSHA256=p.sha256
        var candidate=data;candidate.positions[id]=stamped
        _ = commit(candidate)
    }
    @discardableResult func upsert(_ note:StudyNote, undo:UndoManager? = nil)->Bool {
        guard ready, !persistenceSuspended else { return false }
        var candidate = data
        var stamped = note
        let original = candidate.notes.first(where: { $0.id == note.id })
        if let i = candidate.notes.firstIndex(where: { $0.id == note.id }) {
            // Source identity is immutable on a text edit, including unknown legacy sources.
            let original = candidate.notes[i]
            stamped.paperID = original.paperID; stamped.sourceSHA256 = original.sourceSHA256
            stamped.documentSource = original.documentSource; stamped.anchors = original.anchors
            stamped.quote = original.quote; stamped.created = original.created
            candidate.notes[i] = stamped
        } else {
            if stamped.sourceSHA256 == nil { stamped.sourceSHA256 = papers.first(where: { $0.id == note.paperID })?.sha256 }
            candidate.notes.append(stamped)
        }
        guard commit(candidate) else { return false }
        if let undo, original == nil || noteHasChanged(original!, stamped) {
            registerNoteUndo(original, id: stamped.id, undo: undo,
                             actionName: original == nil ? "创建批注" : "编辑批注")
        }
        let label = stamped.kind == "高亮" && stamped.documentSource == nil ? stamped.effectiveMarkupStyle.title : stamped.kind
        notice = "已保存\(label)"; return true
    }

    private func noteHasChanged(_ first: StudyNote, _ second: StudyNote) -> Bool {
        first.kind != second.kind || first.body != second.body || first.resolved != second.resolved
            || first.markupStyle != second.markupStyle || first.markupColor != second.markupColor
    }

    private func registerNoteUndo(_ previous: StudyNote?, id: UUID, undo: UndoManager, actionName: String) {
        undo.registerUndo(withTarget: self) { [weak undo] target in
            MainActor.assumeIsolated { target.restoreNote(previous, id: id, undo: undo, actionName: actionName) }
        }
        undo.setActionName(actionName)
    }

    private func restoreNote(_ previous: StudyNote?, id: UUID, undo: UndoManager?, actionName: String) {
        guard ready, !persistenceSuspended else { return }
        let current = data.notes.first(where: { $0.id == id })
        guard current != nil || previous != nil else { return }
        var candidate = data
        if let previous {
            if let index = candidate.notes.firstIndex(where: { $0.id == id }) {
                candidate.notes[index] = previous
            } else {
                candidate.notes.append(previous)
            }
        } else {
            candidate.notes.removeAll { $0.id == id }
        }
        guard commit(candidate) else { return }
        if let undo { registerNoteUndo(current, id: id, undo: undo, actionName: actionName) }
        notice = previous == nil ? "已撤销批注" : "已恢复批注"
    }
    @discardableResult func remove(_ note:StudyNote,undo:UndoManager?)->Bool {
        guard let original = data.notes.first(where: { $0.id == note.id }) else { return false }
        var candidate = data; candidate.notes.removeAll { $0.id == note.id }
        guard commit(candidate) else { return false }
        notice="已删除批注，⌘Z 可撤销"
        undo?.registerUndo(withTarget:self) { target in
            MainActor.assumeIsolated { target.restoreDeleted(original,undo:undo) }
        }
        undo?.setActionName("删除批注")
        return true
    }
    @discardableResult func toggleResolved(_ id: UUID) -> Bool {
        guard let index = data.notes.firstIndex(where: { $0.id == id && $0.kind == "疑问" }) else { return false }
        var candidate = data; candidate.notes[index].resolved.toggle()
        guard commit(candidate) else { return false }
        notice = candidate.notes[index].resolved ? "疑问已标记为解决" : "疑问已重新打开"
        return true
    }
    private func restoreDeleted(_ note:StudyNote,undo:UndoManager?) {
        var candidate = data
        // Append directly so an unknown legacy source stays unknown on undo.
        if !candidate.notes.contains(where: { $0.id == note.id }) { candidate.notes.append(note) }
        guard commit(candidate) else { return }
        notice="已恢复批注"
        undo?.registerUndo(withTarget:self) { target in
            MainActor.assumeIsolated { target.remove(note,undo:undo) }
        }
    }
    func importPDF(_ urls:[URL]) {
        guard ready, !persistenceSuspended, !isImporting, !urls.isEmpty else { return }
        importResults = []
        for url in urls {
            do { importResults.append(try commitPDF(PreparedPDF.read(url), filename: url.lastPathComponent)) }
            catch { importResults.append(PDFImportResult(filename: url.lastPathComponent, outcome: .failed, detail: error.localizedDescription)) }
        }
        finishImport()
    }
    func importPDFAsync(_ urls: [URL]) async {
        guard ready, !persistenceSuspended, !isImporting, !urls.isEmpty else { return }
        isImporting = true; importResults = []; notice = nil
        defer { isImporting = false; importProgress = "" }
        for (index, url) in urls.enumerated() {
            importProgress = "正在导入 \(index + 1) / \(urls.count) · \(url.lastPathComponent)"
            do {
                let prepared = try await Task.detached(priority: .userInitiated) { try PreparedPDF.read(url) }.value
                importResults.append(try commitPDF(prepared, filename: url.lastPathComponent))
            } catch { importResults.append(PDFImportResult(filename: url.lastPathComponent, outcome: .failed, detail: error.localizedDescription)) }
        }
        finishImport()
    }
    private func commitPDF(_ prepared: PreparedPDF, filename: String) throws -> PDFImportResult {
        guard ready, !persistenceSuspended else { throw StudyError.message("资料库正在恢复，本次导入未写入。") }
        if let existing = papers.first(where: { $0.sha256 == prepared.hash }) {
            var candidate = data; candidate.selectedID = existing.id
            guard commit(candidate) else { throw StudyError.message("阅读记录未能保存。") }
            conceptID = nil; trail = []
            return PDFImportResult(filename: filename, outcome: .existing, detail: "资料库已有此论文，已打开")
        }
        let dir = dataURL.appendingPathComponent("imports")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = "local-" + UUID().uuidString, file = "imports/\(id).pdf"
        try prepared.bytes.write(to: dataURL.appendingPathComponent(file), options: .atomic)
        let p = Paper(id: id, name: prepared.name, title: prepared.title, file: file,
                      pages: prepared.pages, sha256: prepared.hash, area: "我的论文", year: 0)
        var candidate = data; candidate.importedPapers.append(p); candidate.selectedID = p.id
        guard commit(candidate) else {
            try? FileManager.default.removeItem(at: dataURL.appendingPathComponent(file))
            throw StudyError.message("学习记录未能保存，此论文未加入资料库。")
        }
        papers.append(p); conceptID = nil; trail = []
        return PDFImportResult(filename: filename, outcome: .added, detail: "已导入 · \(p.pages) 页")
    }
    private func finishImport() {
        let added = importResults.filter { $0.outcome == .added }.count
        let existing = importResults.filter { $0.outcome == .existing }.count
        let failed = importResults.filter { $0.outcome == .failed }.count
        notice = [added > 0 ? "已导入 \(added) 篇" : nil,
                  existing > 0 ? "\(existing) 篇已在资料库" : nil,
                  failed > 0 ? "\(failed) 篇未导入，请查看详情" : nil].compactMap { $0 }.joined(separator: " · ")
    }
    func importGuides(_ url:URL) {
        guard ready, !persistenceSuspended else {return}
        do {
            let new=try JSONDecoder().decode([Guide].self,from:Data(contentsOf:url))
            guard Set(new.map(\.paperID)).count == new.count else { throw StudyError.message("内容包含重复论文。") }
            for g in new { try validate(g) }
            var merged=overrides.filter { old in !new.contains { $0.paperID == old.paperID } };merged+=new
            if damagedOverrides {
                let original=dataURL.appendingPathComponent("guides.json")
                let recovery=dataURL.appendingPathComponent("guides-recovery-"+UUID().uuidString+".json")
                try FileManager.default.copyItem(at:original,to:recovery)
            }
            try encoder.encode(merged).write(to:dataURL.appendingPathComponent("guides.json"),options:.atomic)
            damagedOverrides=false;overrides=merged;for g in new { guides[g.paperID]=g };overview();notice="讲解已更新，个人记录保留"
        } catch { self.error="未导入：\(error.localizedDescription)" }
    }
    func exportMarkdown(_ url:URL) {
        do {
            var s="# 我的论文学习记录\n\n"
            let known=Set(papers.map(\.id))
            let orphaned=Set(data.notes.map(\.paperID)+Array(data.exercises.keys)).subtracting(known).sorted()
            for id in papers.map(\.id)+orphaned {
                let p=papers.first {$0.id == id}
                let notes=data.notes.filter { $0.paperID == id }
                let response=data.exercises[id] ?? ""
                if notes.isEmpty && response.isEmpty { continue }
                if let p {s+="## \(p.name)\n\n论文：\(p.title)\n\n当前 PDF SHA-256：\(p.sha256)\n\n"}
                else {s+="## \(id)\n\n论文当前不在资料库中；以下记录仍予以保留。\n\n"}
                for n in notes {
                    let location: String
                    if let source = n.documentSource {
                        location = " · " + source.documentTitle + (source.pdfPage.map { " · 对应原文第 \($0 + 1) 页" } ?? "")
                    } else { location = n.anchors.first.map { " · PDF 第 \($0.page + 1) 页" } ?? "" }
                    s+="### \(n.kind)\(n.resolved ? " · 已解决" : "")\(location)\n\n"
                    if !canLocate(n) {s+="来源版本：\(n.sourceSHA256 ?? "未确认")。与当前原文不匹配或无法确认，不自动定位。\n\n"}
                    if !n.quote.isEmpty { s+="> "+n.quote.replacingOccurrences(of:"\n",with:"\n> ")+"\n\n" }
                    s+=n.body+"\n\n"
                }
                if !response.isEmpty { s+="### 我的机制复述\n\n\(response)\n\n" }
            }
            try s.write(to:url,atomically:true,encoding:.utf8); notice="学习记录已导出"
        } catch { self.error=error.localizedDescription }
    }
    func backup(to parent:URL) {
        guard save() else { return }
        do {
            let preview = try LibraryStorage.createBackup(from: dataURL, to: parent)
            notice = "已备份 \(preview.noteCount) 条记录与 \(preview.importedPaperCount) 篇导入论文；内置材料随应用提供"
        } catch { self.error=error.localizedDescription }
    }
}
