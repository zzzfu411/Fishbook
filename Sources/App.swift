import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

@MainActor final class AppSession: ObservableObject {
    @Published private(set) var store: StudyStore
    @Published private(set) var documents: DocumentStore
    @Published private(set) var features: LibraryFeatureStore
    @Published private(set) var generation = UUID()
    init() {
        // The isolated UI-check bundle supplies this key; the normal app uses the
        // migration-aware resolver and never writes test records into the real library.
        let override = (Bundle.main.object(forInfoDictionaryKey: "FishbookDataDirectory") as? String).map { URL(fileURLWithPath: $0) }
        let study = StudyStore(dataDirectory: override)
        store = study
        let docs = DocumentStore(resources: study.resources, dataURL: study.dataURL)
        docs.setPersistenceSuspended(!study.ready)
        if study.ready { docs.load(papers: study.papers) }
        documents = docs
        features = LibraryFeatureStore(dataDirectory: study.dataURL, enabled: study.ready)
    }
    func reload() {
        let study = StudyStore(resourceDirectory: store.resources, dataDirectory: store.dataURL)
        let docs = DocumentStore(resources: study.resources, dataURL: study.dataURL)
        docs.setPersistenceSuspended(!study.ready)
        if study.ready { docs.load(papers: study.papers) }
        store = study; documents = docs
        features = LibraryFeatureStore(dataDirectory: study.dataURL, enabled: study.ready)
        generation = UUID()
    }
    func suspendPersistence(_ value: Bool) {
        store.setPersistenceSuspended(value)
        documents.setPersistenceSuspended(value || !store.ready)
        features.setPersistenceSuspended(value)
    }
}

enum ReaderAction {
    static let importPDF = Notification.Name("fishbook.importPDF")
    static let find = Notification.Name("fishbook.find")
    static let materials = Notification.Name("fishbook.materials")
    static let settings = Notification.Name("fishbook.settings")
    static let questions = Notification.Name("fishbook.questions")
    static let reflection = Notification.Name("fishbook.reflection")
    static let layout = Notification.Name("fishbook.layout")
    static let immersive = Notification.Name("fishbook.immersive")
    static let toggleLibrary = Notification.Name("fishbook.toggleLibrary")
    static let toggleCompanion = Notification.Name("fishbook.toggleCompanion")
    static let companionMode = Notification.Name("fishbook.companionMode")
}

@main struct PaperStudyApp: App {
    @StateObject private var session = AppSession()
    var body: some Scene {
        Window(StudyBrand.name,id:"reader") {
            Workspace(store: session.store, documents: session.documents, features: session.features, session: session)
                .id(session.generation).frame(minWidth:720,minHeight:540)
        }
            .defaultSize(width:1380,height:880)
        .windowToolbarStyle(.unified)
            .windowStyle(.titleBar)
            .commands {
                SidebarCommands()
                CommandGroup(replacing:.newItem) {
                    Button("导入 PDF…") { send(ReaderAction.importPDF) }.keyboardShortcut("o").disabled(!session.store.ready || session.store.isImporting)
                    Button("添加学习材料…") { send(ReaderAction.materials) }.keyboardShortcut("o",modifiers:[.command,.shift])
                }
                CommandGroup(replacing: .appSettings) {
                    Button("资料库设置…") { send(ReaderAction.settings) }.keyboardShortcut(",")
                }
                ReaderCommands(store: session.store, documents: session.documents)
            }
    }
    private func send(_ name: Notification.Name, value: String? = nil) { NotificationCenter.default.post(name: name, object: value) }
}

@MainActor private struct ReaderCommands: Commands {
    @ObservedObject var store: StudyStore
    @ObservedObject var documents: DocumentStore
    @AppStorage("ReaderImmersiveToolbarPinned") private var immersiveToolbarPinned = false

    var body: some Commands {
        CommandMenu("阅读") {
            Button("深度理解") { changeMode("explanation") }.keyboardShortcut("1").disabled(store.paper == nil)
            Button("全文翻译") { changeMode("translation") }.keyboardShortcut("2").disabled(store.paper == nil)
            Button("我的记录") { changeMode("notes") }.keyboardShortcut("3").disabled(store.paper == nil)
            Divider()
            Button("查找当前阅读区") { send(ReaderAction.find) }.keyboardShortcut("f").disabled(store.paper == nil)
            Button("全部待解疑问") { send(ReaderAction.questions) }.keyboardShortcut("q",modifiers:[.command,.option])
            Button("自己讲一遍") { send(ReaderAction.reflection) }.keyboardShortcut("r",modifiers:[.command,.shift]).disabled(store.paper == nil)
            Divider()
            Button("切换沉浸阅读") { send(ReaderAction.immersive) }.keyboardShortcut("f",modifiers:[.command,.shift]).disabled(store.paper == nil)
            Toggle("固定沉浸工具栏", isOn: $immersiveToolbarPinned).keyboardShortcut("t", modifiers: [.command, .option])
            Button("显示或隐藏文献栏") { send(ReaderAction.toggleLibrary) }.keyboardShortcut("b",modifiers:.command)
            Button("显示或隐藏笔记栏") { send(ReaderAction.toggleCompanion) }.keyboardShortcut("b",modifiers:[.command,.shift]).disabled(store.paper == nil)
            Divider()
            Button("对照阅读") { send(ReaderAction.layout,value:"split") }.keyboardShortcut("0",modifiers:[.command,.option]).disabled(store.paper == nil)
            Button("只看原文") { send(ReaderAction.layout,value:"original") }.keyboardShortcut("1",modifiers:[.command,.option]).disabled(store.paper == nil)
            Button("只看中文") { send(ReaderAction.layout,value:"companion") }.keyboardShortcut("2",modifiers:[.command,.option]).disabled(store.paper == nil)
        }
    }

    private func changeMode(_ mode: String) {
        guard store.paper != nil else { return }
        documents.flushProgress()
        documents.setMode(mode, paperID: store.selectedID)
        send(ReaderAction.companionMode, value: mode)
    }
    private func send(_ name: Notification.Name, value: String? = nil) { NotificationCenter.default.post(name: name, object: value) }
}

@MainActor enum Panels {
    static func importPDF(_ store:StudyStore) {
        guard store.ready, !store.isImporting else { return }
        let p=NSOpenPanel();p.allowedContentTypes=[.pdf];p.allowsMultipleSelection=true
        if p.runModal() == .OK { Task { await store.importPDFAsync(p.urls) } }
    }
    static func importGuides(_ store:StudyStore) {
        let p=NSOpenPanel();p.allowedContentTypes=[.json];p.message="选择我们补充的讲解 JSON；PDF 版本必须一致。"
        if p.runModal() == .OK,let u=p.url { store.importGuides(u) }
    }
    static func importDocument(_ store:StudyStore,_ documents:DocumentStore,kind:DocumentKind) {
        guard let paper=store.paper else {return}
        let p=NSOpenPanel()
        p.allowedContentTypes=[UTType(filenameExtension:"md") ?? .plainText,UTType(filenameExtension:"markdown") ?? .plainText,.plainText]
        p.message="将\(kind.title)文档关联到「\(paper.name)」。支持 UTF-8 Markdown 和同目录内的相对路径图片；导入后标记为未校核。"
        if p.runModal() == .OK,let u=p.url,documents.importMarkdown(u,paper:paper,kind:kind) {
            store.notice="已关联\(kind.title)文档 · 内容待校核"
        }
    }
    static func exportNotes(_ store:StudyStore) {
        let p=NSSavePanel();p.nameFieldStringValue=StudyBrand.name+"-学习笔记.md";p.allowedContentTypes=[.plainText]
        if p.runModal() == .OK,let u=p.url { store.exportMarkdown(u) }
    }
}


struct GuidePane: View {
    @ObservedObject var store: StudyStore
    @ObservedObject var documents: DocumentStore
    @ObservedObject var pdf: PDFController
    @ObservedObject var reader: MarkdownReaderController
    var onFocus: () -> Void = {}
    var onNoteSource: (DocumentNoteSource) -> Void = { _ in }
    var onPDFPage: (Int) -> Void = { _ in }
    @Environment(\.colorScheme) private var colorScheme
    @StoredState<Set<String>> private var revealed = []
    private var documentID: String { "guide:\(store.selectedID ?? ""):\(store.conceptID ?? "overview")" }
    var body: some View {
        if let guide = store.guide {
            let id = documentID
            let sources = store.data.notes.filter { $0.paperID == guide.paperID && $0.sourceSHA256 == guide.sha256 }.compactMap(\.documentSource).filter { $0.documentID == id }
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    if store.concept != nil {
                        Button { store.back() } label: { Label("返回上层", systemImage: "chevron.left") }
                        Button("整篇导读") { store.overview() }
                    }
                    if let concept = store.concept, !concept.prerequisites.isEmpty {
                        Menu("前置知识") {
                            ForEach(concept.prerequisites, id: \.self) { id in
                                if let prior = guide.concepts.first(where: { $0.id == id }) {
                                    Button(prior.title) { store.showConcept(id) }
                                }
                            }
                        }.menuStyle(.borderlessButton).fixedSize()
                    }
                    Spacer()
                    if store.concept == nil {
                        Button(revealed.contains(documentID) ? "收起参考推演" : "展开参考推演") {
                            if revealed.contains(documentID) { revealed.remove(documentID) } else { revealed.insert(documentID) }
                        }
                    }
                }.font(.system(size: 11)).buttonStyle(.borderless).foregroundStyle(StudyTheme.accent)
                    .padding(.horizontal, 18).frame(height: 32)
                MarkdownDocumentView(markdownURL: store.resources.appendingPathComponent("content/interactive-guide.md"),
                    documentID: id, fontSize: store.data.fontSize, dark: colorScheme == .dark,
                    initialProgress: documents.progress(for: id),
                    onProgress: { documents.setProgress($0, documentID: id) },
                    onPage: onPDFPage,
                    documentTitle: store.concept.map { "概念 · " + $0.title } ?? "快速导读 · " + (store.paper?.name ?? ""),
                    initialLocation: documents.location(for: id),
                    onLocation: { documents.setLocation($0, documentID: id) }, controller: reader, onFocus: onFocus,
                    markdownText: markdown(guide), noteSources: sources, onNoteSource: onNoteSource)
                    .id(id)
            }.background(StudyTheme.paper)
        }
    }
    private func markdown(_ guide: Guide) -> String {
        var parts: [String] = []
        if let concept = store.concept {
            parts = ["# " + concept.title, concept.summary, "[核对原文 · 第 \(concept.anchor.page + 1) 页](zhiye://page/\(concept.anchor.page + 1))"]
            parts += concept.sections.map { "## " + $0.title + "\n\n" + $0.body }
        } else {
            parts = ["# " + guide.subtitle, "先理解问题，再拆开机制。可从上方「概念」逐层展开。"]
            parts += guide.overview.map { "## " + $0.title + "\n\n" + $0.body }
            parts.append("## 自己推一遍\n\n" + guide.exercise)
            if revealed.contains(documentID) { parts.append("## 参考推演\n\n" + guide.answer) }
            if let legacy = store.data.exercises[guide.paperID], !legacy.isEmpty { parts.append("## 你之前的机制复述\n\n" + legacy) }
        }
        return parts.joined(separator: "\n\n")
    }
}
