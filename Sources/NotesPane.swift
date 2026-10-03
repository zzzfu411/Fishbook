import SwiftUI

struct NotesPane: View {
    @ObservedObject var store: StudyStore
    @ObservedObject var pdf: PDFController
    let edit: (StudyNote) -> Void
    let create: (String) -> Void
    let locate: ((StudyNote) -> Void)?
    let export: ((NoteExportScope) -> Void)?
    let showReflection: (() -> Void)?
    @StoredState<Bool> private var unresolvedOnly = false
    @StoredState<String> private var query = ""
    @StoredState<Set<UUID>> private var expanded = []
    @StoredState<Set<UUID>> private var selected = []
    @StoredState<Bool> private var selecting = false
    @FocusState private var searchFocused: Bool
    @Environment(\.undoManager) private var undo
    init(store: StudyStore, pdf: PDFController, edit: @escaping (StudyNote) -> Void,
         create: @escaping (String) -> Void, locate: ((StudyNote) -> Void)? = nil,
         export: ((NoteExportScope) -> Void)? = nil, showReflection: (() -> Void)? = nil) {
        self.store = store; self.pdf = pdf; self.edit = edit; self.create = create
        self.locate = locate; self.export = export; self.showReflection = showReflection
    }
    private var visibleNotes: [StudyNote] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.notes.filter {
            (!unresolvedOnly || ($0.kind == "疑问" && !$0.resolved)) &&
            (term.isEmpty || ($0.quote + " " + $0.body).localizedCaseInsensitiveContains(term))
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            if let showReflection {
                HStack {
                    Button(action: showReflection) { Label("自己讲一遍", systemImage: "text.bubble") }.buttonStyle(.borderless)
                    Spacer()
                    Text("问题 · 机制 · 证据").foregroundStyle(StudyTheme.muted)
                }.font(.system(size: 11)).padding(.horizontal, 16).padding(.vertical, 10)
                ReadingRule()
            }
            if !store.notes.isEmpty {
                VStack(spacing: 10) {
                    HStack {
                        Picker("筛选记录", selection: $unresolvedOnly) {
                            Text("全部 · \(store.notes.count)").tag(false)
                            Text("待解 · \(store.selectedID.map { store.unresolvedCount(for: $0) } ?? 0)").tag(true)
                        }.pickerStyle(.segmented).labelsHidden()
                        Menu {
                            Button("留下疑问") { create("疑问") }
                            Button("写笔记") { create("笔记") }
                            Divider()
                            Button(selecting ? "结束选择" : "选择多条记录") { selecting.toggle(); selected = [] }
                            if let export {
                                if let id = store.selectedID { Button("导出当前论文…") { export(.currentPaper(id)) } }
                                Button("导出全库待解疑问…") { export(.unresolved) }
                                Button("导出全部记录…") { export(.all) }
                                if !selected.isEmpty { Button("导出所选 \(selected.count) 条…") { export(.selection(selected)) } }
                            }
                        } label: { Image(systemName: "plus").frame(width: 24, height: 28) }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28).accessibilityLabel("新建或导出记录")
                    }
                    TextField("搜索我的摘录与笔记", text: $query).textFieldStyle(.roundedBorder).accessibilityLabel("搜索我的记录").focused($searchFocused)
                    if selecting {
                        HStack {
                            Button("全选当前结果") { selected = Set(visibleNotes.map(\.id)) }.buttonStyle(.borderless)
                            Spacer()
                            Button("导出所选 \(selected.count) 条…") { export?(.selection(selected)) }
                                .disabled(selected.isEmpty || export == nil)
                        }.font(.system(size: 11))
                    }
                }.controlSize(.small).padding(14)
                ReadingRule()
            }
            if visibleNotes.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: unresolvedOnly ? "checkmark.bubble" : "square.and.pencil").font(.system(size: 30, weight: .light)).foregroundStyle(StudyTheme.muted)
                    Text(store.notes.isEmpty ? "写下自己的理解" : unresolvedOnly && query.isEmpty ? "这篇的疑问都已处理" : "没有匹配的记录").font(.system(size: 18, weight: .semibold))
                    Text(store.notes.isEmpty ? "选中原文或中文材料留下疑问，也可以写下自己的想法。" : "可切回全部记录，或换个关键词。")
                        .font(.system(size: 13)).lineSpacing(5).multilineTextAlignment(.center).foregroundStyle(StudyTheme.muted)
                    if store.notes.isEmpty {
                        HStack(spacing: 10) {
                            Button("留下疑问") { create("疑问") }.buttonStyle(.borderedProminent)
                            Button("写笔记") { create("笔记") }.buttonStyle(.bordered)
                        }
                    } else { Button("显示全部记录") { unresolvedOnly = false; query = "" }.buttonStyle(.bordered) }
                }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(visibleNotes) { note in noteCard(note) }
                    }.padding(20)
                }
            }
        }.background(StudyTheme.paper)
            .onChange(of: store.selectedID) { _, _ in query = ""; expanded = []; unresolvedOnly = false; selecting = false; selected = [] }
            .onChange(of: store.data.notes.map(\.id)) { _, ids in selected.formIntersection(ids) }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("fishbook.findNotes"))) { _ in searchFocused = true }
    }
    private func noteCard(_ note: StudyNote) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if selecting {
                    Toggle("选择记录", isOn: Binding(get: { selected.contains(note.id) }, set: { value in
                        if value { selected.insert(note.id) } else { selected.remove(note.id) }
                    })).toggleStyle(.checkbox).labelsHidden().accessibilityLabel("选择此条\(note.kind)")
                }
                Label(note.pdfMarkTitle, systemImage: note.pdfMarkSymbol)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(StudyTheme.accent)
                if note.resolved { Label("已解决", systemImage: "checkmark").font(.system(size: 10)).foregroundStyle(StudyTheme.muted) }
                Spacer()
                Button("编辑") { edit(note) }.font(.system(size: 11)).buttonStyle(.borderless)
                Menu {
                    if let export { Button("导出此条…") { export(.selection([note.id])) } }
                    Button("删除记录", role: .destructive) { store.remove(note, undo: undo) }
                } label: { Image(systemName: "ellipsis").frame(height: 24) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 20).help("记录操作；删除后可 ⌘Z 撤销").accessibilityLabel("记录操作")
            }
            if !note.quote.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(note.quote).font(.system(size: 12)).foregroundStyle(StudyTheme.muted).lineSpacing(4)
                        .lineLimit(expanded.contains(note.id) ? nil : 4).textSelection(.enabled)
                    if note.quote.count > 100 || note.quote.split(separator: "\n", omittingEmptySubsequences: false).count > 4 {
                        Button(expanded.contains(note.id) ? "收起摘录" : "展开摘录") {
                            if expanded.contains(note.id) { expanded.remove(note.id) } else { expanded.insert(note.id) }
                        }.font(.caption).buttonStyle(.link)
                    }
                }.padding(.leading, 12).frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .leading) { StudyTheme.line.frame(width: 2) }
            }
            if !note.body.isEmpty { Text(note.body).font(.system(size: store.data.fontSize)).lineSpacing(6).textSelection(.enabled) }
            HStack {
                Button(NoteExport.sourceLabel(note)) {
                    if let locate { locate(note) }
                    else if note.documentSource == nil, let anchor = note.anchors.first, store.canLocate(note) { pdf.go(anchor) }
                }.buttonStyle(.link).lineLimit(1)
                    .disabled(!store.canLocate(note) || (note.documentSource != nil && locate == nil))
                    .help(!store.canLocate(note) ? "来源版本不同或位置未知，摘录仍保留" : note.documentSource != nil ? "回到中文材料中的摘录" : "定位原文摘录")
                Spacer()
                if note.kind == "疑问" {
                    Button(note.resolved ? "重新打开" : "标记解决") { store.toggleResolved(note.id) }.buttonStyle(.borderless)
                }
            }.font(.system(size: 11))
        }.padding(18).background(StudyTheme.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(StudyTheme.line.opacity(0.6), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.025), radius: 6, y: 2)
    }
}
