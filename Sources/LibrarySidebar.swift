import SwiftUI
import AppKit

struct LibrarySidebar: View {
    @ObservedObject var store: StudyStore
    @ObservedObject var documents: DocumentStore
    @ObservedObject var features: LibraryFeatureStore
    let select: (String) -> Void
    let importPDF: () -> Void
    let showHelp: () -> Void
    let showImportResults: () -> Void
    let backup: () -> Void
    let showQuestions: (() -> Void)?
    let addMaterials: (() -> Void)?
    let showSettings: (() -> Void)?
    let onPaperHidden: ((String) -> Void)?
    let exportNotes: (() -> Void)?
    @StoredState<String> private var query = ""
    @StoredState<String> private var filter = "all"
    @StoredState<Paper?> private var editingPaper = nil
    init(store: StudyStore, documents: DocumentStore, features: LibraryFeatureStore,
         select: @escaping (String) -> Void, importPDF: @escaping () -> Void,
         showHelp: @escaping () -> Void, showImportResults: @escaping () -> Void,
         backup: @escaping () -> Void, showQuestions: (() -> Void)? = nil,
         addMaterials: (() -> Void)? = nil, showSettings: (() -> Void)? = nil,
         onPaperHidden: ((String) -> Void)? = nil, exportNotes: (() -> Void)? = nil) {
        self.store = store; self.documents = documents; self.features = features
        self.select = select; self.importPDF = importPDF; self.showHelp = showHelp
        self.showImportResults = showImportResults; self.backup = backup
        self.showQuestions = showQuestions; self.addMaterials = addMaterials
        self.showSettings = showSettings; self.onPaperHidden = onPaperHidden
        self.exportNotes = exportNotes
    }
    private var explained: Set<String> { Set(store.guides.keys).union(documents.documents.filter { $0.kind == .explanation }.map(\.paperID)) }
    private var translated: Set<String> { Set(documents.documents.filter { $0.kind == .translation }.map(\.paperID)) }
    private var filterTitle: String {
        switch filter {
        case "recent": return "最近阅读"
        case "queue": return "待读"
        case "archive": return "已归档"
        case "trash": return "最近移出"
        case "reading": return "阅读中"
        case "questions": return "有待解疑问"
        case "explanation": return "有深度理解"
        case "translation": return "有译文材料"
        default: return "全部论文"
        }
    }
    private var filtered: [Paper] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let papers = store.papers.filter { paper in
            let entry = features.entry(for: paper.id)
            if filter == "trash" { if !entry.removed { return false } }
            else if entry.removed { return false }
            if filter == "archive" { if !entry.archived { return false } }
            else if filter != "trash" && entry.archived { return false }
            let matchesFilter: Bool
            switch filter {
            case "recent": matchesFilter = entry.lastOpened != nil
            case "queue": matchesFilter = entry.queued
            case "reading": matchesFilter = store.data.stages[paper.id] == "阅读中"
            case "questions": matchesFilter = store.unresolvedPaperIDs.contains(paper.id)
            case "explanation": matchesFilter = explained.contains(paper.id)
            case "translation": matchesFilter = translated.contains(paper.id)
            default: matchesFilter = true
            }
            let display = features.displayPaper(paper)
            return matchesFilter && (term.isEmpty || (display.name + " " + display.title + " " + display.area).localizedCaseInsensitiveContains(term))
        }
        guard filter == "recent" || filter == "trash" else { return papers }
        return papers.enumerated().sorted { lhs, rhs in
            let left = features.entry(for: lhs.element.id), right = features.entry(for: rhs.element.id)
            let date1 = (filter == "trash" ? left.removedAt : left.lastOpened) ?? .distantPast
            let date2 = (filter == "trash" ? right.removedAt : right.lastOpened) ?? .distantPast
            if date1 != date2 { return date1 > date2 }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    BrandMark(size: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(StudyBrand.name).font(.system(size: 18, weight: .semibold, design: .rounded)).tracking(-0.3)
                        Text(StudyBrand.tagline).font(.system(size: 10)).foregroundStyle(StudyTheme.muted)
                    }
                }.padding(.vertical, 4)
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(StudyTheme.muted).accessibilityHidden(true)
                    TextField("搜索论文", text: $query).textFieldStyle(.plain).accessibilityLabel("检索文献库")
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(StudyTheme.muted).help("清除搜索").accessibilityLabel("清除文献库搜索")
                    }
                }.font(.system(size: 12)).padding(.horizontal, 12).frame(height: 34)
                    .background(.thinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(StudyTheme.line.opacity(0.6), lineWidth: 0.5).allowsHitTesting(false))
                HStack {
                    Menu {
                        Picker("筛选文献", selection: $filter) {
                            Text("最近阅读").tag("recent")
                            Text("待读").tag("queue")
                            Text("全部论文").tag("all")
                            Text("阅读中").tag("reading")
                            Text("有待解疑问 · \(store.unresolvedPaperIDs.count) 篇").tag("questions")
                            Divider()
                            Text("已归档").tag("archive")
                            Text("最近移出").tag("trash")
                        }
                    } label: { HStack(spacing: 5) { Text(filterTitle); Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)) } }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("筛选文献，当前\(filterTitle)")
                    Spacer()
                    Text("\(filtered.count) 篇").monospacedDigit().accessibilityLabel("显示 \(filtered.count) 篇，共 \(store.papers.count) 篇")
                }.font(.system(size: 11, weight: .medium)).foregroundStyle(StudyTheme.muted)
            }.padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 8)
            List(selection: Binding(get: { store.selectedID }, set: { id in if let id { select(id) } })) {
                ForEach(filtered) { paper in
                    row(paper).tag(paper.id)
                        .onDrag { NSItemProvider(contentsOf: store.fileURL(paper)) ?? NSItemProvider(object: paper.name as NSString) }
                        .contextMenu { paperMenu(paper) }
                }
            }.listStyle(.sidebar).scrollContentBackground(.hidden)
                .overlay {
                    if filtered.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: filter == "questions" ? "checkmark.bubble" : "magnifyingglass").font(.system(size: 25, weight: .light)).accessibilityHidden(true)
                            Text(emptyTitle).font(.system(size: 13, weight: .medium))
                            Text(emptyDetail)
                                .font(.system(size: 11)).multilineTextAlignment(.center).lineSpacing(4).foregroundStyle(StudyTheme.muted)
                            Button("显示全部") { query = ""; filter = "all" }.buttonStyle(.bordered).controlSize(.small)
                        }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            if let showQuestions {
                Button(action: showQuestions) {
                    HStack(spacing: 7) {
                        Image(systemName: "questionmark.bubble")
                        Text("待解疑问")
                        Spacer()
                        Text("\(store.data.notes.filter { $0.kind == "疑问" && !$0.resolved }.count)").monospacedDigit()
                    }.font(.system(size: 12)).padding(.horizontal, 12).frame(height: 32)
                }.buttonStyle(ReaderChromeButtonStyle()).padding(.horizontal, 12)
                    .help("查看所有论文中的待解问题")
            }
            HStack(spacing: 10) {
                ReaderControlGroup {
                    Button(action: importPDF) {
                        Label("导入 PDF", systemImage: "plus").padding(.horizontal, 11).frame(height: 28)
                    }.buttonStyle(ReaderChromeButtonStyle()).disabled(!store.ready || store.isImporting).help("导入论文 ⌘O；也可拖入 PDF")
                }
                Spacer()
                Menu {
                    if let addMaterials { Button("添加学习材料…", action: addMaterials).disabled(store.paper == nil || !documents.ready) }
                    if !store.importResults.isEmpty { Button("查看上次导入结果", action: showImportResults) }
                    Divider()
                    Button("导出全部学习记录…") { if let exportNotes { exportNotes() } else { Panels.exportNotes(store) } }
                    Button("备份学习资料…", action: backup)
                    if let showSettings { Button("资料库与设置…", action: showSettings) }
                    Divider()
                    Button("使用帮助", action: showHelp)
                } label: { Image(systemName: "ellipsis.circle").frame(height: 28) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 26).help("资料与帮助").accessibilityLabel("资料与帮助")
            }.font(.system(size: 12)).foregroundStyle(StudyTheme.muted).padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 14)
        }.foregroundStyle(StudyTheme.text).background { ReaderSidebarBackground() }
            .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 290)
            .onChange(of: store.isImporting) { old, new in
                if old && !new && store.importResults.contains(where: { $0.outcome != .failed }) { query = ""; filter = "all" }
            }
            .sheet(item: $editingPaper) { paper in
                PaperInfoEditor(paper: paper, features: features, close: { editingPaper = nil })
            }
    }
    private var emptyTitle: String {
        if !query.isEmpty { return "没有匹配的论文" }
        switch filter {
        case "questions": return "暂时没有待解疑问"
        case "queue": return "选几篇接下来想读的论文"
        case "recent": return "从一篇论文开始"
        case "archive": return "还没有归档论文"
        case "trash": return "没有移出的论文"
        default: return "没有匹配的论文"
        }
    }
    private var emptyDetail: String {
        switch filter {
        case "queue": return "右键点击论文，选择“加入待读”。"
        case "archive": return "读过的论文可以归档，记录和材料会保留。"
        case "trash": return "移出的论文会保留在这里，随时可以恢复。"
        case "recent": return "打开过的论文会自动出现在这里。"
        case "reading": return "右键点击论文，将阅读状态设为“阅读中”。"
        default: return "可以换个筛选，或搜索论文简称。"
        }
    }
    @ViewBuilder private func paperMenu(_ paper: Paper) -> some View {
        let entry = features.entry(for: paper.id)
        if entry.removed {
            Button("恢复论文") { features.setRemoved(paper.id, false) }
        } else {
            Button("打开论文") { select(paper.id) }
            Button("编辑论文信息…") { editingPaper = paper }.disabled(!features.ready)
            Button(entry.queued ? "移出待读" : "加入待读") { features.setQueued(paper.id, !entry.queued) }.disabled(!features.ready)
            Menu("阅读状态") {
                ForEach(["未开始", "阅读中", "已完成"], id: \.self) { stage in
                    Button { store.setStage(stage, for: paper.id) } label: {
                        if (store.data.stages[paper.id] ?? "未开始") == stage { Label(stage, systemImage: "checkmark") }
                        else { Text(stage) }
                    }
                }
            }
            Divider()
            Button(entry.archived ? "取消归档" : "归档") {
                if features.setArchived(paper.id, !entry.archived), !entry.archived { onPaperHidden?(paper.id) }
            }.disabled(!features.ready)
            Button("移出论文列表", role: .destructive) {
                if features.setRemoved(paper.id, true) { onPaperHidden?(paper.id) }
            }.disabled(!features.ready)
        }
        Divider()
        Button("在访达中显示 PDF") { NSWorkspace.shared.activateFileViewerSelecting([store.fileURL(paper)]) }
    }
    private func row(_ paper: Paper) -> some View {
        let display = features.displayPaper(paper)
        let entry = features.entry(for: paper.id)
        let count = store.unresolvedCount(for: paper.id)
        let stage = store.data.stages[paper.id] ?? "未开始"
        return HStack(alignment: .top, spacing: 9) {
            Image(systemName: stage == "已完成" ? "checkmark.circle" : "doc.text")
                .font(.system(size: 14)).frame(width: 17).padding(.top, 2).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(display.name).font(.system(size: 13, weight: store.selectedID == paper.id ? .semibold : .medium)).lineLimit(2)
                HStack(spacing: 5) {
                    Text(entry.removed ? "已移出 · 可恢复" : stage == "未开始" ? display.area : stage).lineLimit(1)
                    if entry.queued && !entry.removed { Image(systemName: "bookmark").help("待读") }
                    if translated.contains(paper.id) { Text("· 译文") }
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if count > 0 {
                Text("\(count)").font(.system(size: 10, weight: .medium).monospacedDigit()).padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.primary.opacity(0.08), in: Capsule()).help("\(count) 个待解疑问").accessibilityLabel("\(count) 个待解疑问")
            }
        }.padding(.vertical, 6).help(display.title + (explained.contains(paper.id) ? " · 有深度理解" : "") + (translated.contains(paper.id) ? " · 有译文材料" : ""))
    }
}
