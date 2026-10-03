import SwiftUI

struct PaperInfoEditor: View {
    let paper: Paper
    @ObservedObject var features: LibraryFeatureStore
    let close: () -> Void
    @StoredState<String> private var name: String
    @StoredState<String> private var title: String
    @StoredState<String> private var area: String
    @StoredState<String> private var year: String
    @StoredState<String?> private var saveError = nil

    init(paper: Paper, features: LibraryFeatureStore, close: @escaping () -> Void) {
        self.paper = paper; self.features = features; self.close = close
        let display = features.displayPaper(paper)
        _name = StoredState(initialValue: display.name)
        _title = StoredState(initialValue: display.title)
        _area = StoredState(initialValue: display.area)
        _year = StoredState(initialValue: display.year > 0 ? String(display.year) : "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("论文信息").font(.system(size: 20, weight: .semibold))
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
                GridRow { Text("简称").foregroundStyle(.secondary); TextField("如 PagedAttention", text: $name) }
                GridRow(alignment: .top) { Text("标题").foregroundStyle(.secondary); TextField("论文完整标题", text: $title, axis: .vertical).lineLimit(2...4) }
                GridRow { Text("方向").foregroundStyle(.secondary); TextField("如大模型推理", text: $area) }
                GridRow { Text("年份").foregroundStyle(.secondary); TextField("可留空", text: $year).frame(width: 100) }
            }.textFieldStyle(.roundedBorder)
            if let saveError { Text(saveError).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("恢复原始信息") {
                    name = paper.name; title = paper.title; area = paper.area; year = paper.year > 0 ? String(paper.year) : ""; saveError = nil
                }.buttonStyle(.link)
                Spacer()
                Button("取消", action: close).keyboardShortcut(.cancelAction)
                Button("保存", action: save).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!features.ready)
            }
        }.padding(24).frame(width: 510).foregroundStyle(StudyTheme.text)
    }
    private func save() {
        let cleanYear = year.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = cleanYear.isEmpty ? 0 : Int(cleanYear)
        guard let parsed, (0...2200).contains(parsed) else { saveError = "年份请填写数字，也可以留空。"; return }
        let metadata = PaperMetadata(name: name, title: title, area: area, year: parsed)
        if features.updateMetadata(paper.id, metadata: metadata) { close() }
        else { saveError = features.error ?? "未能保存，请重试。" }
    }
}

struct QuestionsPane: View {
    @ObservedObject var store: StudyStore
    @ObservedObject var features: LibraryFeatureStore
    let open: (StudyNote) -> Void
    let export: (NoteExportScope) -> Void
    let close: () -> Void
    @StoredState<String> private var query = ""
    @StoredState<Bool> private var includeResolved = false
    @FocusState private var searchFocused: Bool
    private var questions: [StudyNote] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.data.notes.filter { note in
            guard note.kind == "疑问", includeResolved || !note.resolved else { return false }
            let name = store.papers.first(where: { $0.id == note.paperID }).map { features.displayPaper($0).name } ?? note.paperID
            return term.isEmpty || (name + " " + note.quote + " " + note.body).localizedCaseInsensitiveContains(term)
        }.sorted { lhs, rhs in
            if lhs.resolved != rhs.resolved { return !lhs.resolved }
            return lhs.created > rhs.created
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("待解疑问").font(.system(size: 20, weight: .semibold))
                    Text("从问题回到原文，继续理解。").font(.system(size: 12)).foregroundStyle(StudyTheme.muted)
                }
                Spacer()
                Menu {
                    Button("导出当前 \(questions.count) 条…") { export(.selection(Set(questions.map(\.id)))) }.disabled(questions.isEmpty)
                    Button("导出全部待解疑问…") { export(.unresolved) }
                } label: { Image(systemName: "square.and.arrow.up") }.menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .frame(width: 28).help("导出疑问").accessibilityLabel("导出疑问")
                Button("完成", action: close).keyboardShortcut(.cancelAction)
            }.padding(20)
            HStack(spacing: 14) {
                TextField("搜索论文、摘录或问题", text: $query).textFieldStyle(.roundedBorder).focused($searchFocused)
                    .accessibilityLabel("搜索全库疑问")
                Picker("疑问范围", selection: $includeResolved) {
                    Text("待解").tag(false)
                    Text("全部").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 130)
            }.padding(.horizontal, 20).padding(.bottom, 14)
            ReadingRule()
            if questions.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.bubble").font(.system(size: 30, weight: .light)).foregroundStyle(StudyTheme.muted)
                    Text(query.isEmpty ? "暂时没有待解问题" : "没有匹配的问题").font(.system(size: 17, weight: .medium))
                    Text(query.isEmpty ? "阅读时点“疑问”留下问题，它们会集中在这里。" : "可以搜索论文简称，或换一个关键词。")
                        .font(.system(size: 12)).foregroundStyle(StudyTheme.muted)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(questions) { question in questionCard(question) }
                    }.padding(20)
                }
            }
        }.background(StudyTheme.paper).foregroundStyle(StudyTheme.text).frame(minWidth: 490, minHeight: 420)
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("fishbook.findNotes"))) { _ in searchFocused = true }
    }
    private func questionCard(_ note: StudyNote) -> some View {
        let paper = store.papers.first { $0.id == note.paperID }
        let name = paper.map { features.displayPaper($0).name } ?? "暂未关联论文"
        let entry = features.entry(for: note.paperID)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if entry.removed { Text("已移出").font(.caption).foregroundStyle(.secondary) }
                else if entry.archived { Text("已归档").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if note.resolved { Label("已解决", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary) }
            }
            if !note.body.isEmpty { Text(note.body).font(.system(size: 14)).lineSpacing(4).textSelection(.enabled) }
            if !note.quote.isEmpty {
                Text(note.quote).font(.system(size: 12)).foregroundStyle(StudyTheme.muted).lineLimit(3)
                    .padding(.leading, 10).overlay(alignment: .leading) { StudyTheme.line.frame(width: 2) }
            }
            Text(NoteExport.sourceLabel(note)).font(.system(size: 11)).foregroundStyle(StudyTheme.muted).lineLimit(1)
            HStack {
                Button(store.canLocate(note) ? "查看来源" : "查看记录") { open(note) }.buttonStyle(.borderless).disabled(paper == nil)
                Spacer()
                Button(note.resolved ? "重新打开" : "标记解决") { store.toggleResolved(note.id) }.buttonStyle(.borderless)
            }.font(.system(size: 12))
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(StudyTheme.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(StudyTheme.line.opacity(0.6), lineWidth: 0.5))
    }
}

struct ReflectionPane: View {
    let paper: Paper
    @ObservedObject var features: LibraryFeatureStore
    let showReference: () -> Void
    let close: (() -> Void)?
    @StoredState<PaperReflection> private var response: PaperReflection
    @StoredState<Bool> private var dirty = false
    @StoredState<String?> private var saveError = nil
    @StoredState<Task<Void, Never>?> private var saveTask = nil

    init(paper: Paper, features: LibraryFeatureStore, showReference: @escaping () -> Void, close: (() -> Void)? = nil) {
        self.paper = paper; self.features = features; self.showReference = showReference; self.close = close
        _response = StoredState(initialValue: features.reflection(for: paper.id))
        _dirty = StoredState(initialValue: features.pendingReflections[paper.id] != nil)
        _saveError = StoredState(initialValue: features.pendingReflections[paper.id] != nil ? features.error : nil)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("自己讲一遍").font(.system(size: 20, weight: .semibold))
                    Text(features.displayPaper(paper).name).font(.system(size: 12)).foregroundStyle(StudyTheme.muted)
                }
                Spacer()
                Button("查看参考讲解") { if flush() { showReference() } }.buttonStyle(.borderless)
                if let close { Button("完成") { if flush() { close() } }.keyboardShortcut(.cancelAction) }
            }.padding(20)
            ReadingRule()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("先用自己的话写下来，再对照论文。能举例、能说清限制，比记住术语更有用。")
                        .font(.system(size: 13)).lineSpacing(4).foregroundStyle(StudyTheme.muted)
                    responseField("1", title: "解决什么问题", hint: "没有这项工作会怎样？谁会遇到这个问题？", text: $response.problem)
                    responseField("2", title: "机制怎么运作", hint: "把输入到输出的过程分成几步，用一个例子走一遍。", text: $response.mechanism)
                    responseField("3", title: "证据能说明什么", hint: "最关键的实验比较了什么？结论在哪些条件下成立？", text: $response.evidence)
                    responseField(nil, title: "还说不清的地方", hint: "可选：先记下疑点，下次从这里继续。", text: $response.uncertainty)
                }.padding(24)
            }
            ReadingRule()
            HStack(spacing: 10) {
                if let saveError {
                    Text(saveError).foregroundStyle(.red).lineLimit(2)
                    Spacer()
                    Button("重试保存") { flush() }
                } else {
                    Image(systemName: dirty ? "pencil" : "checkmark.circle")
                    Text(dirty ? "正在保存…" : "内容会自动保存")
                    Spacer()
                }
            }.font(.system(size: 11)).foregroundStyle(StudyTheme.muted).padding(.horizontal, 20).padding(.vertical, 12)
        }.background(StudyTheme.paper).foregroundStyle(StudyTheme.text).frame(minWidth: 420, minHeight: 460)
            .onChange(of: response) { _, value in
                dirty = true; saveTask?.cancel()
                let id = paper.id
                saveTask = Task { @MainActor in
                    do { try await Task.sleep(nanoseconds: 600_000_000) } catch { return }
                    let success = features.saveReflection(value, for: id)
                    saveError = success ? nil : features.error ?? "尚未保存，请重试。"
                    if success && response == value { dirty = false }
                }
            }
            .onDisappear { flush() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in flush() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in flush() }
            .interactiveDismissDisabled(dirty || saveError != nil)
    }
    private func responseField(_ number: String?, title: String, hint: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let number { Text(number).font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22).background(StudyTheme.accentSoft, in: Circle()).foregroundStyle(StudyTheme.accent) }
                Text(title).font(.system(size: 15, weight: .semibold))
            }
            Text(hint).font(.system(size: 12)).foregroundStyle(StudyTheme.muted).lineSpacing(3)
            TextEditor(text: text).font(.system(size: 14)).scrollContentBackground(.hidden)
                .padding(8).frame(minHeight: number == nil ? 76 : 110)
                .background(StudyTheme.canvas, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(StudyTheme.line, lineWidth: 0.5))
                .accessibilityLabel(title)
        }
    }
    @discardableResult private func flush() -> Bool {
        saveTask?.cancel()
        guard dirty else { return true }
        if features.saveReflection(response, for: paper.id) { dirty = false; saveError = nil; return true }
        else { saveError = features.error ?? "尚未保存，请重试。"; return false }
    }
}
