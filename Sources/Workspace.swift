import SwiftUI
import AppKit
import PDFKit
import CryptoKit
import UniformTypeIdentifiers

struct Workspace: View {
    @ObservedObject var store: StudyStore
    @ObservedObject var documents: DocumentStore
    @ObservedObject var features: LibraryFeatureStore
    @ObservedObject var session: AppSession
    @StateObject private var pdf = PDFController()
    @StateObject private var reader = MarkdownReaderController()
    @StateObject private var window = ReaderWindowController()
    @StoredState<ImmersiveReadingSession> private var immersive = ImmersiveReadingSession()
    @StoredState<String> private var previousActivePane = "original"
    @StoredState<UUID> private var layoutChangeToken = UUID()
    @StoredState<NavigationSplitViewVisibility> private var columns = .all
    @StoredState<StudyNote?> private var editNote: StudyNote?
    @StoredState<Bool> private var welcome = false
    @StoredState<Bool> private var showInfo = false
    @StoredState<Bool> private var showImportResults = false
    @StoredState<Bool> private var dropTarget = false
    @StoredState<Bool> private var showSearch = false
    @StoredState<String> private var pdfQuery = ""
    @StoredState<Bool> private var showPageJump = false
    @StoredState<Bool> private var showReadingOptions = false
    @StoredState<Bool> private var showPDFColors = false
    @StoredState<Bool> private var showPDFAnnotations = false
    @StoredState<Bool> private var showPDFComposer = false
    @StoredState<Bool> private var exportingPDF = false
    @StoredState<String> private var pageDraft = ""
    @StoredState<Bool> private var showMaterials = false
    @StoredState<Bool> private var showSettings = false
    @StoredState<Bool> private var showQuestions = false
    @StoredState<Bool> private var showReflection = false
    @StoredState<Bool> private var editPaperInfo = false
    @StoredState<Bool> private var showContents = false
    @StoredState<String> private var activePane = "original"
    @StoredState<String?> private var composerError = nil
    @AppStorage("ReaderLayout") private var readingLayout = "split"
    @AppStorage("ReaderLibraryVisible") private var libraryVisible = true
    @AppStorage("ReaderAppearance") private var appearanceName = "system"
    @AppStorage("ReaderPDFColor") private var pdfColorName = "original"
    @AppStorage("ReaderPDFMarkupTools") private var showPDFMarkup = false
    @AppStorage("ReaderPDFMarkupColor") private var markupColorName = "yellow"
    @Environment(\.undoManager) private var undo
    @FocusState private var searchFocused: Bool
    private var appearance: ReaderAppearance { ReaderAppearance(rawValue: appearanceName) ?? .system }
    private var pdfColor: PDFColorPreset { PDFColorPreset(rawValue: pdfColorName) ?? .original }
    private var markupColor: PDFMarkupColor { PDFMarkupColor(rawValue: markupColorName) ?? .yellow }
    private var mode: String { documents.mode(for: store.selectedID) }
    private var warningCount: Int { store.contentWarnings.count + documents.warnings.count }
    private var hasSaveError: Bool { store.saveFailed || documents.saveFailed || features.hasPendingChanges || !features.ready }
    private var canRecord: Bool { store.ready && features.ready && store.paper != nil && !showQuestions && ((activePane == "companion" && mode != "notes" && reader.documentID != nil) || (pdf.loadedID == store.selectedID && pdf.loadError == nil)) }
    private var displayPaper: Paper? { store.paper.map { features.displayPaper($0) } }
    private var effectiveLayout: String { immersive.isActive ? "original" : readingLayout }
    private var companionVisible: Bool { effectiveLayout != "original" && !showQuestions }
    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(get: { immersive.isActive ? .detailOnly : columns }, set: { value in
            guard value != (immersive.isActive ? .detailOnly : columns) else { return }
            preserveReadingPosition {
                endImmersive()
                columns = value
                libraryVisible = value != .detailOnly
            }
        })
    }

    private var workspacePresentation: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            LibrarySidebar(store: store, documents: documents, features: features, select: selectPaper,
                importPDF: importPDF, showHelp: { welcome = true }, showImportResults: { showImportResults = true },
                backup: openSettings, showQuestions: openQuestions, addMaterials: openMaterials, showSettings: openSettings,
                onPaperHidden: { id in
                    guard id == store.selectedID, preserveDraft() else { return }
                    if let next = store.papers.first(where: { !features.entry(for: $0.id).removed && !features.entry(for: $0.id).archived }) { selectPaper(next.id) }
                    else { pdf.flush(); documents.flushProgress(); store.clearSelection() }
                }, exportNotes: { exportNotes(.all) })
        } detail: {
            if showQuestions {
                QuestionsPane(store: store, features: features, open: locateNote, export: exportNotes, close: { showQuestions = false })
            } else if let paper = store.paper {
                HSplitView {
                    if effectiveLayout != "companion" {
                        originalPane(paper).frame(minWidth: 350)
                    }
                    if effectiveLayout != "original" {
                        companionPane(paper).frame(minWidth: 355, idealWidth: 470, maxWidth: 720)
                    }
                }
            } else {
                VStack(spacing: 16) {
                    BrandMark(size: 80)
                    Text("从一篇论文开始").font(.title2.weight(.semibold))
                    Text("导入 PDF，或直接从访达拖进来。").foregroundStyle(StudyTheme.muted)
                    Button("导入 PDF…", action: importPDF).buttonStyle(.borderedProminent).disabled(!store.ready || store.isImporting)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(StudyTheme.paper)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle(showQuestions ? "待解疑问" : displayPaper?.name ?? StudyBrand.name)
        .navigationSubtitle(displayPaper.map { $0.year > 0 ? "\($0.area) · \($0.year)" : $0.area } ?? StudyBrand.tagline)
        .tint(StudyTheme.accent).preferredColorScheme(appearance.scheme)
        .background(ReaderWindowAccessor(controller: window).frame(width: 0, height: 0))
        .toolbar(immersive.isActive ? .hidden : .visible, for: .windowToolbar)
        .toolbar {
            ToolbarItemGroup {
                Button { showInfo.toggle() } label: { Label("论文信息", systemImage: "info.circle") }
                    .disabled(store.paper == nil).help("论文信息与阅读状态")
                    .popover(isPresented: $showInfo) { if let paper = store.paper { paperInfo(paper) } }
                Menu {
                    Button("对照阅读") { changeLayout("split") }
                    Button("只看原文") { changeLayout("original") }
                    Button("只看中文") { changeLayout("companion") }
                    Divider()
                    Button(immersive.isActive ? "退出沉浸阅读" : "沉浸阅读", action: toggleImmersive)
                    Button("自己讲一遍", action: openReflection)
                } label: { Label("阅读布局", systemImage: effectiveLayout == "split" ? "rectangle.split.2x1" : "rectangle") }
                    .help("专注阅读与复述").disabled(store.paper == nil)
                Button(action: toggleCompanion) { Label(companionVisible ? "收起笔记栏" : "展开笔记栏", systemImage: "sidebar.right") }
                    .help("\(companionVisible ? "收起" : "展开")笔记栏 ⌥⌘N").disabled(store.paper == nil || showQuestions)
                Button { addNote("高亮") } label: { Label("高亮", systemImage: "highlighter") }
                    .keyboardShortcut("h", modifiers: [.command, .shift]).help("高亮原文选中文字 ⇧⌘H").disabled(!canRecord || activePane == "companion")
                Button { addNote("疑问") } label: { Label("疑问", systemImage: "questionmark.bubble") }
                    .labelStyle(.titleAndIcon).keyboardShortcut("q", modifiers: [.command, .shift]).help("留下疑问 ⇧⌘Q").disabled(!canRecord)
                Button { addNote("笔记") } label: { Label("笔记", systemImage: "square.and.pencil") }
                    .labelStyle(.titleAndIcon).keyboardShortcut("n", modifiers: [.command, .shift]).help("写笔记 ⇧⌘N").disabled(!canRecord)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if hasSaveError || warningCount > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    Text(hasSaveError ? "有更改尚未保存" : "\(warningCount) 项材料未能载入").font(.caption)
                    Spacer()
                    Button("查看详情") { store.error = hasSaveError ? "请保留应用，检查学习资料保存位置后重试。\n\(store.dataURL.path)" : (store.contentWarnings + documents.warnings).joined(separator: "\n\n") }
                        .buttonStyle(.link).font(.caption)
                }.padding(.horizontal, 16).padding(.vertical, 7).background(StudyTheme.canvas)
            }
        }
        .overlay(alignment: .bottom) { feedback.padding(16) }
        .overlay {
            if dropTarget {
                RoundedRectangle(cornerRadius: 12).fill(StudyTheme.accentSoft.opacity(0.94))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(StudyTheme.accent, style: StrokeStyle(lineWidth: 2, dash: [8])))
                    .overlay { Label("松开以导入 PDF", systemImage: "arrow.down.doc").font(.title2.weight(.medium)).foregroundStyle(StudyTheme.accent) }
                    .padding(10).allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $showMaterials) { MaterialsPane(store: store, documents: documents) }
        .sheet(isPresented: $showSettings) { LibrarySettingsPane(session: session) }
        .sheet(isPresented: $editPaperInfo) { if let paper = store.paper { PaperInfoEditor(paper: paper, features: features, close: { editPaperInfo = false }) } }
        .sheet(isPresented: $showReflection) {
            if let paper = displayPaper {
                ReflectionPane(paper: paper, features: features, showReference: {
                    showReflection = false
                    revealCompanion("explanation")
                }, close: { showReflection = false }).id(paper.id)
            }
        }
        .sheet(isPresented: $welcome) { welcomePane }
        .sheet(isPresented: $showImportResults) { ImportResultsPane(results: store.importResults) }
        .sheet(isPresented: $showPDFComposer, onDismiss: { _ = preserveDraft() }) {
            if let note = editNote { noteComposer(note).frame(width: 460).padding(12).background(StudyTheme.paper) }
        }
        .alert("需要处理", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("好", role: .cancel) { store.error = nil }
        } message: { Text(store.error ?? "") }
    }

    var body: some View {
        workspacePresentation
        .onAppear {
            appearance.apply()
            pdf.setColorPreset(pdfColor)
            columns = libraryVisible ? .all : .detailOnly
            window.onEscape = handleEscape
            window.onExitFullScreen = {
                guard immersive.isActive else { return }
                preserveReadingPosition { endImmersive(leaveFullScreen: false) }
            }
            pdf.view.recordSelection = { kind in activePane = "original"; addNote(kind) }
            pdf.view.markupSelection = { style, color in addMarkup(style, color: color) }
            pdf.onAnnotationTapped = { id in
                guard let note = store.data.notes.first(where: { $0.id == id && $0.paperID == store.selectedID }), preserveDraft() else { return }
                showPDFAnnotations = false; startEditing(note)
            }
            pdf.onFocus = { activePane = "original" }
            if let id = store.selectedID { features.recordOpened(id) }
            if let notice = store.storageNotice { store.notice = notice }
            if let error = documents.error { store.error = error; documents.error = nil }
            if store.ready && !store.data.welcomed { welcome = true }
        }
        .onDisappear {
            pdf.onAnnotationTapped = nil
            pdf.view.recordSelection = nil; pdf.view.markupSelection = nil
            window.onEscape = nil
            window.onExitFullScreen = nil
            window.attach(nil)
        }
        .onChange(of: appearanceName) { _, _ in appearance.apply() }
        .onChange(of: pdfColorName) { _, _ in pdf.setColorPreset(pdfColor) }
        .onChange(of: store.guideRequest) { _, _ in
            setMode("explanation")
            if let paper = store.paper { documents.selectInteractiveGuide(for: paper) }
        }
        .onChange(of: store.papers) { _, papers in documents.load(papers: papers) }
        .onChange(of: features.notice) { _, value in if let value { store.notice = value; features.notice = nil } }
        .onChange(of: features.error) { _, value in
            if let value, editNote == nil, !showReflection { store.error = value; features.error = nil }
        }
        .onChange(of: reader.notice) { _, value in if let value { store.notice = value; reader.notice = nil } }
        .onChange(of: documents.error) { _, value in if let value { store.error = value; documents.error = nil } }
        .onChange(of: store.selectedID) { _, id in
            layoutChangeToken = UUID()
            if id == nil { endImmersive() }
            if let note = editNote, note.paperID != id { _ = preserveDraft() }
            pdfQuery = ""; showSearch = false; showPageJump = false; showInfo = false; showPDFAnnotations = false; showContents = false
            if let id { features.recordOpened(id) }
        }
        .onReceive(NotificationCenter.default.publisher(for: ReaderAction.importPDF)) { _ in importPDF() }
        .onReceive(NotificationCenter.default.publisher(for: ReaderAction.find)) { _ in findCurrentPane() }
        .onReceive(NotificationCenter.default.publisher(for: ReaderAction.materials)) { _ in openMaterials() }
        .onReceive(NotificationCenter.default.publisher(for: ReaderAction.settings)) { _ in openSettings() }
        .onReceive(NotificationCenter.default.publisher(for: ReaderAction.questions)) { _ in openQuestions() }
        .onReceive(NotificationCenter.default.publisher(for: ReaderAction.reflection)) { _ in openReflection() }
        .onReceive(NotificationCenter.default.publisher(for: ReaderAction.layout)) { value in if let layout = value.object as? String { changeLayout(layout) } }
        .onReceive(NotificationCenter.default.publisher(for: ReaderAction.immersive)) { _ in toggleImmersive() }
        .onReceive(NotificationCenter.default.publisher(for: ReaderAction.toggleLibrary)) { _ in toggleLibrary() }
        .onReceive(NotificationCenter.default.publisher(for: ReaderAction.toggleCompanion)) { _ in toggleCompanion() }
        .onReceive(NotificationCenter.default.publisher(for: ReaderAction.companionMode)) { _ in
            revealCompanion()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { value in
            if let source = value.object as? NSWindow, source === window.window { pdf.preservePositionForLayoutChange() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { value in
            if let source = value.object as? NSWindow, source === window.window { pdf.preservePositionForLayoutChange() }
        }
        .onChange(of: store.isImporting) { old, new in
            if old && !new && store.importResults.contains(where: { $0.outcome == .failed }) { showImportResults = true }
        }
        .task(id: store.notice) {
            guard let notice = store.notice else { return }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, store.notice == notice else { return }
            store.notice = nil
        }
        .onOpenURL { importURLs([$0]) }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTarget) { providers in
            guard store.ready, !store.isImporting else { return false }
            Task { @MainActor in
                var urls: [URL] = []
                for provider in providers {
                    let url: URL? = await withCheckedContinuation { continuation in
                        _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
                    }
                    if let url { urls.append(url) }
                }
                importURLs(urls)
            }
            return true
        }
    }

    private func selectPaper(_ id: String) {
        guard preserveDraft() else { return }
        showQuestions = false
        if id != store.selectedID { pdf.flush(); documents.flushProgress(); store.select(id) }
        guard store.selectedID == id else { return }
        features.recordOpened(id)
        if let paper = store.paper { pdf.load(paper, store: store) }
    }
    private func setMode(_ value: String) { documents.flushProgress(); documents.setMode(value, paperID: store.selectedID); activePane = "companion" }
    private func importPDF() { guard preserveDraft() else { return }; pdf.flush(); documents.flushProgress(); Panels.importPDF(store) }
    private func importURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { store.notice = "请拖入可读取的 PDF 文件"; return }
        guard preserveDraft() else { return }
        pdf.flush(); documents.flushProgress()
        Task { await store.importPDFAsync(urls) }
    }
    private func addNote(_ kind: String) {
        if kind == "高亮", activePane != "companion" { addMarkup(.highlight); return }
        guard canRecord, preserveDraft(), let paper = store.paper else { store.notice = "阅读区尚未载入，请稍后记录"; return }
        if activePane == "companion", mode != "notes" {
            let expectedDocument = reader.documentID
            reader.captureSelection { source in
                guard store.selectedID == paper.id, reader.documentID == expectedDocument else { return }
                guard let source else { store.notice = "中文材料尚未载入，请稍后记录"; return }
                let anchors = source.pdfPage.map { [Anchor(page: $0, rects: [], quote: "")] } ?? []
                let note = StudyNote(paperID: paper.id, sourceSHA256: paper.sha256, documentSource: source, kind: kind, body: "", quote: source.quote, anchors: anchors)
                startEditing(note)
            }
            return
        }
        guard let note = pdf.makeNote(kind: kind) else { store.notice = "原文尚未载入，请稍后记录"; return }
        startEditing(note)
    }
    private func addMarkup(_ style: PDFMarkupStyle, color: PDFMarkupColor? = nil) {
        activePane = "original"
        guard canRecord, preserveDraft(), var note = pdf.makeNote(kind: "高亮") else {
            store.notice = "原文尚未载入，请稍后标记"; return
        }
        guard !note.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              note.anchors.contains(where: { !$0.rects.isEmpty }) else {
            store.notice = "先在原文中选中文字，再点击\(style.title)"; return
        }
        note.markupStyle = style; note.markupColor = color ?? markupColor
        if let color { markupColorName = color.rawValue }
        if store.upsert(note, undo: undo) {
            pdf.refreshMarks(); pdf.view.clearSelection()
            store.notice = "已添加\(style.title)"
        }
    }

    private func startEditing(_ note: StudyNote) {
        guard preserveDraft() else { return }
        showPDFAnnotations = false
        composerError = nil; editNote = note
        if immersive.isActive {
            showPDFComposer = true
        } else {
            pdf.preservePositionForLayoutChange()
            if readingLayout == "original" { readingLayout = "split" }
        }
        if !features.saveDraft(note) { composerError = features.error }
    }
    @discardableResult private func preserveDraft() -> Bool {
        guard let note = editNote else { return true }
        guard features.saveDraft(note) else { composerError = features.error ?? "草稿未保存，请重试。"; return false }
        editNote = nil; composerError = nil; showPDFComposer = false; return true
    }
    private func saveNote() {
        guard let note = editNote else { return }
        guard store.upsert(note, undo: undo) else { composerError = "记录未保存成功，草稿仍在。检查资料位置后可重试或放弃。"; store.error = nil; return }
        guard features.removeDraft(note.id) else { composerError = "记录已保存，草稿清理失败；重试不会产生重复记录。"; return }
        editNote = nil; composerError = nil; showPDFComposer = false
    }
    private func discardDraft() {
        guard let note = editNote, features.removeDraft(note.id) else { composerError = features.error; return }
        editNote = nil; composerError = nil; showPDFComposer = false
    }
    private func locateNote(_ note: StudyNote) {
        guard store.canLocate(note), preserveDraft(), let paper = store.papers.first(where: { $0.id == note.paperID }) else {
            store.notice = "原文版本或来源已变化，原记录仍保留。"; return
        }
        selectPaper(note.paperID)
        guard store.selectedID == note.paperID else { return }
        endImmersive()
        showQuestions = false
        if let source = note.documentSource {
            if source.documentID.hasPrefix("guide:\(paper.id):") {
                let conceptID = String(source.documentID.dropFirst("guide:\(paper.id):".count))
                if conceptID == "overview" { store.overview() }
                else if store.guide?.concepts.contains(where: { $0.id == conceptID }) == true { store.showConcept(conceptID) }
                else { store.notice = "此概念材料暂不可用，摘录和笔记仍保留。"; return }
                setMode("explanation"); documents.selectInteractiveGuide(for: paper)
            } else if let doc = documents.document(id: source.documentID), doc.paperID == paper.id, doc.sha256 == note.sourceSHA256 {
                setMode(doc.kind.rawValue); documents.select(doc.id, paper: paper, kind: doc.kind)
            } else { store.notice = "来源材料暂不可用，摘录和笔记仍保留。"; return }
            if readingLayout == "original" { readingLayout = "split" }
            reader.go(to: source); activePane = "companion"
        } else if let anchor = note.anchors.first {
            if readingLayout == "companion" { readingLayout = "split" }
            pdf.go(anchor); activePane = "original"
        }
    }
    private func exportNotes(_ scope: NoteExportScope) {
        guard preserveDraft(), features.flushPendingChanges() else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Fishbook-学习记录.md"; panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = NoteExport.markdown(scope: scope, notes: store.data.notes, papers: store.papers.map { features.displayPaper($0) }, reflections: features.data.reflections)
            try text.write(to: url, atomically: true, encoding: .utf8); store.notice = "学习记录已导出"
        } catch { store.error = error.localizedDescription }
    }
    private func exportAnnotatedPDF() {
        guard let paper = store.paper, let owner = window.window, !exportingPDF, preserveDraft() else { return }
        exportingPDF = true
        showPDFAnnotations = false
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(features.displayPaper(paper).name)-批注.pdf"
        panel.title = "导出带批注的 PDF"
        // Present after the popover closes, attached to the reading window even in full screen.
        DispatchQueue.main.async {
            panel.beginSheetModal(for: owner) { response in
                panel.orderOut(nil)
                guard response == .OK, let destination = panel.url else { exportingPDF = false; return }
                writeAnnotatedPDF(paper, to: destination)
            }
        }
    }
    private func writeAnnotatedPDF(_ paper: Paper, to destination: URL) {
        let resolved = destination.standardizedFileURL.resolvingSymlinksInPath()
        guard !store.papers.contains(where: { store.fileURL($0).standardizedFileURL.resolvingSymlinksInPath() == resolved }) else {
            exportingPDF = false; store.error = "请选择一个新文件名，保留资料库中的原始 PDF。"; return
        }
        let source = store.fileURL(paper)
        let notes = store.annotationNotes(for: paper.id)
        store.notice = "正在导出 PDF…"
        Task { @MainActor in
            defer { exportingPDF = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    let bytes = try Data(contentsOf: source)
                    guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == paper.sha256 else {
                        throw StudyError.message("原文版本已变化，暂未导出。请重新导入这份 PDF 后再试。")
                    }
                    let annotated = try PDFAnnotationSupport.annotatedData(source: bytes, notes: notes)
                    try annotated.write(to: destination, options: .atomic)
                }.value
                store.notice = "已导出带批注的 PDF"
            } catch { store.notice = nil; store.error = error.localizedDescription }
        }
    }
    private func openSettings() { guard preserveDraft() else { return }; pdf.flush(); documents.flushProgress(); showSettings = true }
    private func openMaterials() { guard preserveDraft() else { return }; documents.flushProgress(); showMaterials = true }
    private func openSourceNote(_ source: DocumentNoteSource) {
        guard let note = store.data.notes.first(where: { $0.paperID == store.selectedID && $0.documentSource == source }) else { return }
        startEditing(note)
    }
    private func showPDFPage(_ page: Int) {
        guard let paper = store.paper, page >= 1, page <= paper.pages else { store.notice = "该页码超出了当前 PDF 范围"; return }
        if readingLayout == "companion" { readingLayout = "split" }
        pdf.load(paper, store: store)
        guard pdf.loadError == nil else { return }
        pdf.go(Anchor(page: page - 1, rects: [], quote: ""))
    }
    private func openQuestions() {
        guard preserveDraft() else { return }
        preserveReadingPosition { endImmersive(); showQuestions = true }
    }
    private func openReflection() {
        guard preserveDraft(), let id = store.selectedID else { return }
        if features.reflection(for: id).isEmpty, let legacy = store.data.exercises[id], !legacy.isEmpty {
            var reflection = PaperReflection(); reflection.mechanism = legacy
            guard features.saveReflection(reflection, for: id) else { store.error = features.error; return }
        }
        showReflection = true
    }
    private func changeLayout(_ value: String) {
        guard ["split", "original", "companion"].contains(value), preserveDraft() else { return }
        preserveReadingPosition {
            endImmersive(); showQuestions = false; readingLayout = value
            activePane = value == "companion" ? "companion" : "original"
        }
    }
    private func preserveReadingPosition(_ change: @escaping () -> Void) {
        let token = UUID(), paperID = store.selectedID
        layoutChangeToken = token
        pdf.preservePositionForLayoutChange()
        reader.captureReadingLocation { documentID, location in
            if let location { documents.setLocation(location, documentID: documentID) }
            documents.flushProgress()
            guard layoutChangeToken == token, store.selectedID == paperID else { return }
            change()
        }
    }
    private func toggleLibrary() {
        preserveReadingPosition {
            let wasVisible = !immersive.isActive && columns != .detailOnly
            endImmersive()
            libraryVisible = !wasVisible
            columns = libraryVisible ? .all : .detailOnly
        }
    }
    private func toggleCompanion() {
        guard store.paper != nil, preserveDraft() else { return }
        preserveReadingPosition {
            let wasVisible = companionVisible
            endImmersive(); showQuestions = false
            readingLayout = wasVisible ? "original" : "split"
            activePane = wasVisible ? "original" : "companion"
        }
    }
    private func revealCompanion(_ value: String? = nil) {
        preserveReadingPosition {
            endImmersive(); showQuestions = false
            if let value { setMode(value) }
            if readingLayout == "original" { readingLayout = "split" }
            activePane = "companion"
        }
    }
    private func toggleImmersive() {
        guard store.paper != nil, preserveDraft() else { return }
        preserveReadingPosition {
            if immersive.isActive { endImmersive(); return }
            previousActivePane = activePane
            showQuestions = false; showInfo = false; showContents = false
            showPageJump = false; showReadingOptions = false; showPDFColors = false; showPDFAnnotations = false
            immersive.begin(windowIsFullScreen: window.intendedFullScreen)
            activePane = "original"
            window.setFullScreen(true)
        }
    }
    private func endImmersive(leaveFullScreen: Bool = true) {
        guard immersive.isActive else { return }
        let ownedFullScreen = immersive.end()
        activePane = previousActivePane
        if ownedFullScreen && leaveFullScreen { window.setFullScreen(false) }
    }
    private func handleEscape() -> Bool {
        if showPDFColors { showPDFColors = false; return true }
        if showPDFAnnotations { showPDFAnnotations = false; return true }
        guard immersive.isActive else { return false }
        // Popovers and sheets get their usual Escape behavior first.
        if showContents || showPageJump || showReadingOptions || showPDFColors || showPDFComposer || showInfo || welcome || showMaterials || showSettings || showReflection || editPaperInfo || showImportResults || store.error != nil { return false }
        if showSearch {
            showSearch = false; pdfQuery = ""; pdf.find("")
        } else {
            preserveReadingPosition { endImmersive() }
        }
        return true
    }
    private func findCurrentPane() {
        if showQuestions || (mode == "notes" && activePane == "companion") { NotificationCenter.default.post(name: Notification.Name("fishbook.findNotes"), object: nil) }
        else if activePane == "companion" || effectiveLayout == "companion" { reader.focusSearch() }
        else { showSearch = true; searchFocused = true }
    }

    private func originalPane(_ paper: Paper) -> some View {
        VStack(spacing: 0) {
            originalToolbar(paper)
            ReadingRule()
            if showPDFMarkup {
                PDFMarkupBar(color: Binding(get: { markupColor }, set: { markupColorName = $0.rawValue }),
                    canMark: pdf.hasTextSelection && canRecord, count: store.annotationNotes(for: paper.id).count + pdf.embeddedAnnotations.count,
                    mark: { addMarkup($0) }, comment: { kind in activePane = "original"; addNote(kind) },
                    showAnnotations: { showPDFAnnotations.toggle() }, export: exportAnnotatedPDF)
                    .popover(isPresented: $showPDFAnnotations, arrowEdge: .bottom) {
                        PDFAnnotationPane(paper: paper, store: store, pdf: pdf, edit: startEditing,
                            locate: { anchor in pdf.go(anchor); showPDFAnnotations = false; activePane = "original" }, export: exportAnnotatedPDF)
                    }
                ReadingRule()
            }
            if showSearch {
                HStack(spacing: 6) {
                    TextField("搜索原文", text: $pdfQuery).textFieldStyle(.roundedBorder).focused($searchFocused)
                        .accessibilityLabel("搜索原文文字").onSubmit { pdf.findOrAdvance(pdfQuery) }
                    Text(pdf.searchResult).font(.caption.monospacedDigit()).foregroundStyle(StudyTheme.muted)
                    ReaderIconButton("上一个原文结果", symbol: "chevron.up", disabled: pdf.matchCount == 0) { pdf.previousMatch() }
                    ReaderIconButton("下一个原文结果", symbol: "chevron.down", disabled: pdf.matchCount == 0) { pdf.nextMatch() }
                    ReaderIconButton("关闭原文搜索", symbol: "xmark") { showSearch = false; pdfQuery = ""; pdf.find("") }
                }.padding(.horizontal, 14).padding(.vertical, 8).background { ReaderChromeBackground() }
                    .task(id: pdfQuery) {
                        try? await Task.sleep(nanoseconds: 220_000_000)
                        guard !Task.isCancelled else { return }; pdf.findIfChanged(pdfQuery)
                    }
                    .onExitCommand { showSearch = false; pdfQuery = ""; pdf.find("") }
            }
            ZStack {
                PDFReader(paper: paper, store: store, controller: pdf)
                if let error = pdf.loadError { ContentUnavailableView("原文暂不可用", systemImage: "doc.questionmark", description: Text(error)) }
            }
        }
    }
    private func originalToolbar(_ paper: Paper) -> some View {
        GeometryReader { geometry in
            if geometry.size.width >= 550 { widePDFToolbar(paper) }
            else { compactPDFToolbar(paper) }
        }.frame(height: 52).foregroundStyle(StudyTheme.text).background { ReaderChromeBackground() }
    }
    private func widePDFToolbar(_ paper: Paper) -> some View {
        HStack(spacing: 8) {
                if immersive.isActive {
                    Button(action: toggleImmersive) {
                        Label("退出沉浸", systemImage: "arrow.down.right.and.arrow.up.left")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 9).frame(height: 30)
                    }.buttonStyle(ReaderChromeButtonStyle()).help("退出沉浸阅读 Esc 或 ⇧⌘F")
                        .accessibilityLabel("退出沉浸阅读")
                    Text("Esc").font(.system(size: 11)).foregroundStyle(StudyTheme.muted).accessibilityHidden(true)
                }
                Button { showContents.toggle() } label: { Image(systemName: "list.bullet").frame(width: 26, height: 30) }
                    .buttonStyle(ReaderChromeButtonStyle(selected: showContents)).help("目录、缩略图与书签").accessibilityLabel("原文目录与书签")
                    .popover(isPresented: $showContents) { PDFContentsPane(paper: paper, pdf: pdf, features: features, close: { showContents = false }) }
                Spacer(minLength: 4)
                ReaderControlGroup {
                    HStack(spacing: 0) {
                        ReaderIconButton("上一页", symbol: "chevron.left", disabled: pdf.pageNumber <= 1) { pdf.goPage(pdf.pageNumber - 1) }
                        Button { pageDraft = String(pdf.pageNumber); showPageJump = true } label: {
                            Text("\(pdf.pageNumber) / \(paper.pages)").font(.system(size: 12, weight: .medium).monospacedDigit()).frame(minWidth: 46, minHeight: 30)
                        }.buttonStyle(ReaderChromeButtonStyle()).help("跳转到指定页").accessibilityLabel("第 \(pdf.pageNumber) 页，共 \(paper.pages) 页；跳转页码")
                            .popover(isPresented: $showPageJump) { pageJump(paper) }
                        ReaderIconButton("下一页", symbol: "chevron.right", disabled: pdf.pageNumber >= paper.pages) { pdf.goPage(pdf.pageNumber + 1) }
                    }
                }
                if !immersive.isActive {
                    ReaderIconButton("沉浸阅读", symbol: "arrow.up.left.and.arrow.down.right", action: toggleImmersive)
                        .help("全屏阅读原文，收起文献栏和笔记栏 ⇧⌘F")
                }
                Spacer(minLength: 4)
                if pdf.canBack || pdf.canForward {
                    HStack(spacing: 0) {
                        ReaderIconButton("返回上一个原文位置", symbol: "arrow.uturn.backward", disabled: !pdf.canBack) { pdf.goBack() }
                        ReaderIconButton("前进到下一个原文位置", symbol: "arrow.uturn.forward", disabled: !pdf.canForward) { pdf.goForward() }
                    }
                }
                ReaderControlGroup {
                    HStack(spacing: 2) {
                        Button {
                            pdf.preservePositionForLayoutChange(); showPDFMarkup.toggle()
                        } label: {
                            Image(systemName: "pencil.tip.crop.circle").font(.system(size: 13)).frame(width: 30, height: 30)
                        }.buttonStyle(ReaderChromeButtonStyle(selected: showPDFMarkup))
                            .help(showPDFMarkup ? "收起标记工具" : "显示标记工具").accessibilityLabel("PDF 标记工具").accessibilityValue(showPDFMarkup ? "已展开" : "已收起")
                        Button { showSearch.toggle(); searchFocused = showSearch; if !showSearch { pdfQuery = ""; pdf.find("") } } label: {
                            Image(systemName: "magnifyingglass").font(.system(size: 13)).frame(width: 30, height: 30)
                        }.buttonStyle(ReaderChromeButtonStyle(selected: showSearch)).help("搜索原文；⌘F 查找当前阅读区").accessibilityLabel("搜索原文")
                        Button { showPDFColors.toggle() } label: {
                            Image(systemName: "paintpalette").font(.system(size: 13)).frame(width: 30, height: 30)
                        }.buttonStyle(ReaderChromeButtonStyle(selected: showPDFColors)).help("PDF 配色 · \(pdfColor.title)").accessibilityLabel("PDF 配色")
                            .accessibilityValue(pdfColor.title)
                            .popover(isPresented: $showPDFColors, arrowEdge: .bottom) { pdfColorOptions }
                        StudyTheme.line.frame(width: 0.5, height: 16).accessibilityHidden(true)
                        Menu {
                            Button("放大原文") { pdf.view.zoomIn(nil) }
                            Button("缩小原文") { pdf.view.zoomOut(nil) }
                            Button("适合页面") { pdf.view.autoScales = true }
                        } label: { Image(systemName: "viewfinder").frame(width: 30, height: 30) }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 30).help("原文缩放").accessibilityLabel("原文缩放")
                    }
                }
            }.padding(.horizontal, 14).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func compactPDFToolbar(_ paper: Paper) -> some View {
        HStack(spacing: 6) {
            ReaderIconButton(immersive.isActive ? "退出沉浸阅读" : "沉浸阅读",
                symbol: immersive.isActive ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", action: toggleImmersive)
            Button { showContents.toggle() } label: { Image(systemName: "list.bullet").frame(width: 26, height: 30) }
                .buttonStyle(ReaderChromeButtonStyle(selected: showContents)).help("目录、缩略图与书签").accessibilityLabel("原文目录与书签")
                .popover(isPresented: $showContents) { PDFContentsPane(paper: paper, pdf: pdf, features: features, close: { showContents = false }) }
            Button { pageDraft = String(pdf.pageNumber); showPageJump = true } label: {
                Text("\(pdf.pageNumber) / \(paper.pages)").font(.system(size: 12).monospacedDigit()).frame(minWidth: 48, minHeight: 30)
            }.buttonStyle(ReaderChromeButtonStyle()).accessibilityLabel("第 \(pdf.pageNumber) 页，共 \(paper.pages) 页；跳转页码")
                .popover(isPresented: $showPageJump) { pageJump(paper) }
            Spacer(minLength: 0)
            Button { pdf.preservePositionForLayoutChange(); showPDFMarkup.toggle() } label: {
                Image(systemName: "pencil.tip.crop.circle").frame(width: 30, height: 30)
            }.buttonStyle(ReaderChromeButtonStyle(selected: showPDFMarkup)).accessibilityLabel("PDF 标记工具")
                .accessibilityValue(showPDFMarkup ? "已展开" : "已收起").help("显示或收起标记工具")
            Button { showSearch.toggle(); searchFocused = showSearch; if !showSearch { pdfQuery = ""; pdf.find("") } } label: {
                Image(systemName: "magnifyingglass").frame(width: 30, height: 30)
            }.buttonStyle(ReaderChromeButtonStyle(selected: showSearch)).accessibilityLabel("搜索原文").help("搜索原文 ⌘F")
            Menu {
                Button("上一页") { pdf.goPage(pdf.pageNumber - 1) }.disabled(pdf.pageNumber <= 1)
                Button("下一页") { pdf.goPage(pdf.pageNumber + 1) }.disabled(pdf.pageNumber >= paper.pages)
                Divider()
                Button("返回上一个位置") { pdf.goBack() }.disabled(!pdf.canBack)
                Button("前进到下一个位置") { pdf.goForward() }.disabled(!pdf.canForward)
                Divider()
                Button("PDF 配色…") { showPDFColors = true }
                Button("放大原文") { pdf.view.zoomIn(nil) }
                Button("缩小原文") { pdf.view.zoomOut(nil) }
                Button("适合页面") { pdf.view.autoScales = true }
                Divider()
                Button("导出带批注的 PDF…", action: exportAnnotatedPDF)
            } label: { Image(systemName: "ellipsis").frame(width: 26, height: 30) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 26).accessibilityLabel("更多 PDF 阅读工具")
                .popover(isPresented: $showPDFColors) { pdfColorOptions }
        }.padding(.horizontal, 12).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func companionPane(_ paper: Paper) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ReaderModePicker(selection: Binding(get: { mode }, set: setMode)).frame(maxWidth: 370)
                Spacer(minLength: 0)
                ReaderControlGroup {
                    Button { showReadingOptions.toggle() } label: {
                        Image(systemName: "textformat.size").font(.system(size: 13)).frame(width: 30, height: 30)
                    }
                    .buttonStyle(ReaderChromeButtonStyle(selected: showReadingOptions)).help("字号与外观").accessibilityLabel("字号与外观")
                    .popover(isPresented: $showReadingOptions, arrowEdge: .bottom) { readingOptions }
                }
                ReaderIconButton("收起笔记栏", symbol: "sidebar.right", action: toggleCompanion)
                    .help("收起笔记栏 ⌥⌘N")
            }.controlSize(.small).padding(.horizontal, 14).frame(height: 52).background { ReaderChromeBackground() }
            ReadingRule()
            if editNote == nil, !features.drafts(for: paper.id).isEmpty {
                HStack {
                    Image(systemName: "square.and.pencil").foregroundStyle(StudyTheme.accent)
                    Menu("继续草稿 · \(features.drafts(for: paper.id).count)") {
                        ForEach(features.drafts(for: paper.id)) { draft in
                            Button(draft.body.isEmpty ? "\(draft.kind) · \(draft.documentSource?.documentTitle ?? "原文")" : String(draft.body.prefix(40))) { startEditing(draft) }
                        }
                    }.menuStyle(.borderlessButton).fixedSize()
                    Spacer()
                }.font(.system(size: 11)).padding(.horizontal, 18).padding(.vertical, 7).background(StudyTheme.accentSoft.opacity(0.6))
            }
            if mode == "notes" {
                NotesPane(store: store, pdf: pdf, edit: startEditing, create: addNote, locate: locateNote, export: exportNotes, showReflection: openReflection)
                    .simultaneousGesture(TapGesture().onEnded { activePane = "companion" })
            } else {
                if reader.canBack || reader.canForward {
                    HStack(spacing: 8) {
                        Button { reader.goBack() } label: { Label("返回", systemImage: "chevron.left") }.disabled(!reader.canBack)
                        Button { reader.goForward() } label: { Image(systemName: "chevron.right") }.disabled(!reader.canForward).accessibilityLabel("前进到下一个中文位置")
                        Spacer()
                    }.font(.system(size: 11)).buttonStyle(.borderless).padding(.horizontal, 18).frame(height: 28)
                }
                DocumentPane(store: store, documents: documents, pdf: pdf, reader: reader, paper: paper, kind: mode == "translation" ? .translation : .explanation,
                    onFocus: { activePane = "companion" }, addMaterials: openMaterials, onNoteSource: openSourceNote, onPDFPage: showPDFPage)
            }
            if let note = editNote, !showPDFComposer { noteComposer(note) }
        }.background(StudyTheme.paper)
    }
    private func noteComposer(_ note: StudyNote) -> some View {
        NoteComposer(note: Binding(get: { editNote ?? note }, set: { value in
            editNote = value
            if !features.saveDraft(value) { composerError = features.error }
        }), error: composerError, save: saveNote, keep: { preserveDraft() }, discard: discardDraft).id(note.id)
    }
    private var pdfColorOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("PDF 配色").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(pdfColor.title).font(.system(size: 12)).foregroundStyle(StudyTheme.muted)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 12) {
                ForEach(PDFColorPreset.allCases) { preset in
                    Button { pdfColorName = preset.rawValue } label: {
                        VStack(spacing: 7) {
                            ZStack(alignment: .topTrailing) {
                                RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: preset.paperColor))
                                Text("Aa").font(.system(size: 25, weight: .medium, design: .serif))
                                    .foregroundStyle(Color(nsColor: preset.inkColor))
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                if pdfColor == preset {
                                    Image(systemName: "checkmark.circle.fill").font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Color(nsColor: preset.inkColor)).padding(6)
                                }
                            }.frame(height: 56)
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(pdfColor == preset ? StudyTheme.accent : StudyTheme.line, lineWidth: pdfColor == preset ? 2 : 0.5))
                            Text(preset.title).font(.system(size: 12, weight: pdfColor == preset ? .semibold : .regular))
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel("PDF 配色：\(preset.title)")
                        .accessibilityValue(pdfColor == preset ? "已选择" : "未选择")
                        .accessibilityAddTraits(pdfColor == preset ? [.isSelected] : [])
                }
            }
            Text("只改变阅读时的显示。查看彩图时，可切回原色。")
                .font(.system(size: 11)).foregroundStyle(StudyTheme.muted).fixedSize(horizontal: false, vertical: true)
        }.padding(20).frame(width: 320).foregroundStyle(StudyTheme.text).background(StudyTheme.paper)
            .onExitCommand { showPDFColors = false }
    }
    private var readingOptions: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("阅读设置").font(.system(size: 14, weight: .semibold))
            HStack {
                Text("文字大小").font(.system(size: 12)).foregroundStyle(StudyTheme.muted)
                Spacer()
                ReaderControlGroup {
                    HStack(spacing: 3) {
                        ReaderIconButton("缩小中文文字", symbol: "minus", disabled: store.data.fontSize <= 13) {
                            store.setFontSize(max(13, store.data.fontSize - 1))
                        }
                        Text("\(Int(store.data.fontSize))").font(.system(size: 12, weight: .medium).monospacedDigit()).frame(width: 26)
                            .accessibilityLabel("字号 \(Int(store.data.fontSize))")
                        ReaderIconButton("放大中文文字", symbol: "plus", disabled: store.data.fontSize >= 22) {
                            store.setFontSize(min(22, store.data.fontSize + 1))
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("外观").font(.system(size: 12)).foregroundStyle(StudyTheme.muted)
                Picker("阅读外观", selection: $appearanceName) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }.pickerStyle(.segmented).labelsHidden().controlSize(.regular)
            }
            Button("恢复默认字号") { store.setFontSize(15) }
                .font(.system(size: 11)).buttonStyle(.link).disabled(store.data.fontSize == 15)
        }.padding(20).frame(width: 290).foregroundStyle(StudyTheme.text)
    }
    private func pageJump(_ paper: Paper) -> some View {
        let number = Int(pageDraft.trimmingCharacters(in: .whitespaces))
        let valid = number.map { (1...paper.pages).contains($0) } ?? false
        return VStack(alignment: .leading, spacing: 12) {
            Text("跳转页码").font(.headline)
            HStack {
                TextField("1–\(paper.pages)", text: $pageDraft).textFieldStyle(.roundedBorder).frame(width: 80).accessibilityLabel("目标 PDF 页码")
                    .onSubmit { if valid, let number { pdf.goPage(number); showPageJump = false } }
                Text("/ \(paper.pages)").foregroundStyle(StudyTheme.muted)
                Button("前往") { if let number { pdf.goPage(number); showPageJump = false } }.buttonStyle(.borderedProminent).disabled(!valid)
            }
            Text("按 PDF 页序定位").font(.caption).foregroundStyle(StudyTheme.muted)
        }.padding(20)
    }
    private func paperInfo(_ paper: Paper) -> some View {
        let paper = features.displayPaper(paper)
        return VStack(alignment: .leading, spacing: 16) {
            Text(paper.name).font(.title3.weight(.semibold))
            Text(paper.title).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Text("\(paper.area) · \(paper.pages) 页" + (paper.year > 0 ? " · \(paper.year)" : "")).font(.caption).foregroundStyle(StudyTheme.muted)
            Divider()
            Picker("阅读状态", selection: Binding(get: { store.data.stages[paper.id] ?? "未开始" }, set: { store.setStage($0, for: paper.id) })) {
                ForEach(["未开始", "阅读中", "已完成"], id: \.self) { Text($0) }
            }
            Text("\(store.unresolvedCount(for: paper.id)) 个待解疑问").font(.caption).foregroundStyle(StudyTheme.muted)
            HStack {
                Button("编辑论文信息…") { showInfo = false; editPaperInfo = true }.buttonStyle(.link)
                Spacer()
                Button(features.entry(for: paper.id).queued ? "移出待读" : "加入待读") { features.setQueued(paper.id, !features.entry(for: paper.id).queued) }.buttonStyle(.link)
            }
            Button("在访达中显示 PDF") { NSWorkspace.shared.activateFileViewerSelecting([store.fileURL(paper)]) }.buttonStyle(.link)
        }.padding(22).frame(width: 340)
    }
    @ViewBuilder private var feedback: some View {
        if store.isImporting {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(store.importProgress).font(.callout).lineLimit(1)
            }.padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)).shadow(color: .black.opacity(0.08), radius: 12, y: 3)
        } else if let notice = store.notice, !hasSaveError {
            HStack(spacing: 10) {
                Text(notice).font(.callout).lineLimit(2)
                if notice.contains("已保存") { Button("查看记录") { revealCompanion("notes"); store.notice = nil }.buttonStyle(.link) }
                if !store.importResults.isEmpty && notice.contains("导入") { Button("详情") { showImportResults = true }.buttonStyle(.link) }
                ReaderIconButton("关闭提示", symbol: "xmark") { store.notice = nil }
            }.padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)).shadow(color: .black.opacity(0.08), radius: 12, y: 3)
        }
    }
    private var welcomePane: some View {
        VStack(alignment: .leading, spacing: 24) {
            BrandMark(size: 88)
            VStack(alignment: .leading, spacing: 8) {
                Text("把论文读明白").font(.system(size: 25, weight: .semibold))
                Text("一页原文，一步理解。").foregroundStyle(StudyTheme.muted)
            }
            VStack(alignment: .leading, spacing: 18) {
                Label("左侧选论文，右侧切讲解或译文", systemImage: "rectangle.split.2x1")
                Label("选中文字，点“疑问”或“笔记”", systemImage: "square.and.pencil")
                Label("下次打开，继续上次的阅读位置", systemImage: "bookmark")
            }.font(.system(size: 14))
            Text("⌘O 导入    ⌘F 查找    ⌘1 / 2 / 3 切换辅助\n⇧⌘F 沉浸阅读    Esc 退出\n⌥⌘S 文献栏    ⌥⌘N 笔记栏")
                .font(.system(size: 11)).foregroundStyle(StudyTheme.muted).lineSpacing(6)
            Text("个人记录保存在本机固定资料库。⌘, 打开备份与恢复；从“我的记录”按范围导出。")
                .font(.caption).foregroundStyle(StudyTheme.muted).fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button("开始阅读") { if store.markWelcomed() { welcome = false } }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
        }.padding(32).frame(width: 440).foregroundStyle(StudyTheme.text).background(StudyTheme.paper).tint(StudyTheme.accent)
    }
}

struct ReaderIconButton: View {
    let title: String
    let symbol: String
    var disabled = false
    let action: () -> Void
    init(_ title: String, symbol: String, disabled: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.disabled = disabled; self.action = action
    }
    var body: some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 12, weight: .medium)).frame(width: 30, height: 30).contentShape(Capsule()) }
            .buttonStyle(ReaderChromeButtonStyle()).help(title).accessibilityLabel(title).disabled(disabled)
    }
}

struct ImportResultsPane: View {
    let results: [PDFImportResult]
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("导入结果").font(.title2.weight(.semibold))
            Text("成功的论文已保留；未导入的文件可以修复后重新选择。").font(.callout).foregroundStyle(StudyTheme.muted)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(results) { result in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: result.outcome == .failed ? "exclamationmark.circle" : "checkmark.circle").foregroundStyle(result.outcome == .failed ? Color.orange : StudyTheme.accent)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(result.filename).font(.system(size: 13, weight: .medium)).textSelection(.enabled)
                                Text(result.detail).font(.caption).foregroundStyle(StudyTheme.muted).textSelection(.enabled)
                            }
                            Spacer()
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 320)
            HStack { Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width: 470).background(StudyTheme.paper)
    }
}
