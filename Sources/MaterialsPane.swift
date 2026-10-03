import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct MaterialsPane: View {
    @ObservedObject var store: StudyStore
    @ObservedObject var documents: DocumentStore
    @Environment(\.dismiss) private var dismiss
    @StoredState<URL?> private var source = nil
    @StoredState<String> private var paperID = ""
    @StoredState<DocumentKind> private var kind = .explanation
    @StoredState<String> private var title = ""
    @StoredState<String> private var updateID = ""
    @StoredState<String?> private var failure = nil
    @StoredState<[Guide]> private var guidePreview = []
    private var paper: Paper? { store.papers.first { $0.id == paperID } }
    private var available: [StudyDocument] { paper.map { documents.currentList(for: $0, kind: kind) } ?? [] }
    private var isGuide: Bool { source?.pathExtension.lowercased() == "json" }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("添加学习材料").font(.title2.weight(.semibold))
            Text("把讲解或译文与论文放在一起。更新时保留旧稿和个人记录。")
                .font(.callout).foregroundStyle(StudyTheme.muted)
            HStack(spacing: 12) {
                Image(systemName: "doc.text").font(.title2).foregroundStyle(StudyTheme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(source?.lastPathComponent ?? "选择 Markdown、TXT 或讲解包").lineLimit(2)
                    if let source { Text(source.deletingLastPathComponent().lastPathComponent).font(.caption).foregroundStyle(StudyTheme.muted) }
                }
                Spacer()
                Button(source == nil ? "选择文件…" : "重新选择…", action: chooseFile)
            }.padding(16).background(StudyTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            if source != nil {
                if isGuide {
                    Label("交互讲解包 · \(guidePreview.count) 篇", systemImage: "book.pages")
                    ForEach(guidePreview, id: \.paperID) { guide in
                        Text(store.papers.first { $0.id == guide.paperID }?.name ?? guide.paperID).font(.callout)
                    }
                    Text("已核对论文版本和定位。导入后可从原文旁的问号展开。")
                        .font(.caption).foregroundStyle(StudyTheme.muted)
                } else {
                    Form {
                        Picker("对应论文", selection: $paperID) { ForEach(store.papers) { Text($0.name).tag($0.id) } }
                        Picker("材料类型", selection: $kind) {
                            Text("深度理解").tag(DocumentKind.explanation)
                            Text("全文翻译").tag(DocumentKind.translation)
                        }
                        TextField("材料名称", text: $title)
                        Picker("导入方式", selection: $updateID) {
                            Text("新增一份材料").tag("")
                            ForEach(available) { Text("更新：" + $0.title).tag($0.id) }
                        }
                    }.formStyle(.grouped).frame(height: 212)
                    Text(updateID.isEmpty ? "导入的材料会标为未校核；同目录中的本地配图一起保存。" : "新稿继承阅读位置，原稿留在历史版本中。段落变化时会提示重新定位。")
                        .font(.caption).foregroundStyle(StudyTheme.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let failure { Text(failure).font(.callout).foregroundStyle(.orange).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(updateID.isEmpty ? "添加材料" : "更新并保留旧稿", action: importMaterial)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(source == nil || (isGuide ? guidePreview.isEmpty : paper == nil || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || !documents.ready)
            }
        }.padding(28).frame(width: 530).background(StudyTheme.paper).foregroundStyle(StudyTheme.text).tint(StudyTheme.accent)
            .onAppear { paperID = store.selectedID ?? store.papers.first?.id ?? "" }
            .onChange(of: paperID) { _, _ in updateID = "" }
            .onChange(of: kind) { _, _ in updateID = "" }
    }
    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, UTType(filenameExtension: "markdown") ?? .plainText, .plainText, .json]
        panel.message = "选择本地讲解、译文或 Fishbook 讲解包。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        source = url; failure = nil; guidePreview = []; updateID = ""
        do {
            if url.pathExtension.lowercased() == "json" {
                let guides = try JSONDecoder().decode([Guide].self, from: Data(contentsOf: url))
                guard !guides.isEmpty, Set(guides.map(\.paperID)).count == guides.count else { throw StudyError.message("讲解包为空或包含重复论文。") }
                for guide in guides { try store.validate(guide) }
                guidePreview = guides
            } else {
                let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                guard ((attrs[.size] as? NSNumber)?.intValue ?? Int.max) <= 20 * 1024 * 1024 else { throw StudyError.message("材料超过 20 MB。") }
                let text = try String(contentsOf: url, encoding: .utf8)
                let heading = text.components(separatedBy: .newlines).first { $0.hasPrefix("# ") }?.dropFirst(2)
                title = heading.map(String.init) ?? url.deletingPathExtension().lastPathComponent
                let hint = (url.lastPathComponent + " " + String(text.prefix(600))).lowercased()
                if hint.contains("译文") || hint.contains("翻译") || hint.contains("paper_zh") || hint.contains("translation") { kind = .translation }
                let matches = store.papers.filter { !$0.name.isEmpty && hint.contains($0.name.lowercased()) }
                if matches.count == 1 { paperID = matches[0].id }
            }
        } catch { failure = error.localizedDescription; source = nil }
    }
    private func importMaterial() {
        guard let source else { return }
        failure = nil
        if isGuide {
            store.error = nil; store.importGuides(source)
            if let error = store.error { failure = error; store.error = nil } else { dismiss() }
        } else if let paper {
            let old = available.first { $0.id == updateID }
            guard documents.importMarkdown(source, paper: paper, kind: kind, updating: old, title: title) else {
                failure = documents.error ?? "材料没有保存成功，请重试。"; documents.error = nil; return
            }
            store.select(paper.id)
            store.notice = old == nil ? "已添加学习材料" : "材料已更新，旧稿与记录保留"
            dismiss()
        }
    }
}

struct NoteComposer: View {
    @Binding var note: StudyNote
    var error: String?
    let save: () -> Void
    let keep: () -> Void
    let discard: () -> Void
    @FocusState private var editing: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("我的\(note.pdfMarkTitle)", systemImage: note.pdfMarkSymbol).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: keep) { Image(systemName: "chevron.down") }.buttonStyle(.borderless).help("收起并保留草稿").accessibilityLabel("保留草稿并收起")
            }
            Text(note.documentSource.map { "来自：" + $0.documentTitle } ?? "来自原文 · 第 \((note.anchors.first?.page ?? 0) + 1) 页")
                .font(.caption).foregroundStyle(StudyTheme.muted).lineLimit(1)
            if !note.quote.isEmpty { Text(note.quote).font(.system(size: 11)).foregroundStyle(StudyTheme.muted).lineLimit(2).textSelection(.enabled) }
            if note.documentSource == nil {
                HStack(spacing: 10) {
                    if note.anchors.contains(where: { !$0.rects.isEmpty }) {
                        Picker("标记样式", selection: Binding(get: { note.effectiveMarkupStyle }, set: { note.markupStyle = $0 })) {
                            ForEach(PDFMarkupStyle.allCases) { style in Text(style.title).tag(style) }
                        }.labelsHidden().frame(maxWidth: 190)
                    }
                    Spacer(minLength: 0)
                    ForEach(PDFMarkupColor.allCases) { color in
                        Button { note.markupColor = color } label: {
                            Circle().fill(Color(nsColor: color.nsColor)).frame(width: 16, height: 16)
                                .overlay {
                                    if note.effectiveMarkupColor == color {
                                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.black.opacity(0.75))
                                    }
                                }.padding(3)
                        }.buttonStyle(.plain).accessibilityLabel("批注颜色：\(color.title)")
                            .accessibilityValue(note.effectiveMarkupColor == color ? "已选择" : "未选择")
                    }
                }.controlSize(.small)
            }
            TextEditor(text: $note.body).font(.system(size: 14)).scrollContentBackground(.hidden).focused($editing)
                .padding(7).frame(minHeight: 78, maxHeight: 125).background(StudyTheme.paper, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudyTheme.line, lineWidth: 0.5)).accessibilityLabel("批注内容")
            if let error { Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("放弃草稿", action: discard).buttonStyle(.borderless).foregroundStyle(StudyTheme.muted)
                Spacer()
                Button("保留草稿", action: keep).buttonStyle(.borderless)
                Button("保存记录", action: save).buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                    .disabled(note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && note.quote.isEmpty)
            }.font(.system(size: 12))
        }.padding(16).background(StudyTheme.surface).overlay(alignment: .top) { ReadingRule() }
            .onAppear { editing = true }
    }
}
