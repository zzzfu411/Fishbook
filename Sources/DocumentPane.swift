import SwiftUI
import AppKit

struct DocumentPane: View {
    @ObservedObject var store: StudyStore
    @ObservedObject var documents: DocumentStore
    @ObservedObject var pdf: PDFController
    @ObservedObject var reader: MarkdownReaderController
    let paper: Paper
    let kind: DocumentKind
    var onFocus: () -> Void = {}
    var addMaterials: () -> Void = {}
    var onNoteSource: (DocumentNoteSource) -> Void = { _ in }
    var onPDFPage: (Int) -> Void = { _ in }
    @Environment(\.colorScheme) private var colorScheme
    @StoredState<Bool> private var showCoverage = false

    private var options: [StudyDocument] { documents.list(for: paper, kind: kind) }
    private var hasGuide: Bool { kind == .explanation && store.guide != nil }
    private var interactive: Bool { hasGuide && documents.prefersInteractiveGuide(for: paper) }
    private var document: StudyDocument? { documents.selected(for: paper, kind: kind) }

    var body: some View {
        VStack(spacing: 0) {
            if hasGuide || !options.isEmpty {
                    HStack(spacing: 8) {
                        if options.count + (hasGuide ? 1 : 0) > 1 {
                        Picker("阅读材料", selection: Binding(get: {
                            interactive ? "__interactive__" : document?.id ?? ""
                        }, set: { id in
                            documents.flushProgress()
                            if id == "__interactive__" { documents.selectInteractiveGuide(for: paper) }
                            else { documents.select(id, paper: paper, kind: kind) }
                        })) {
                            if hasGuide { Text("快速导读 · 概念逐层展开").tag("__interactive__") }
                            ForEach(options) { item in Text((documents.isHistorical(item) ? "旧稿 · " : "") + item.title).tag(item.id) }
                        }.labelsHidden().controlSize(.small).help("选择\(kind.title)材料")
                            .accessibilityLabel("选择\(kind.title)材料")
                        } else {
                            Text(interactive ? "交互导读" : document?.title ?? kind.title)
                                .font(.system(size: 11)).foregroundStyle(StudyTheme.muted).lineLimit(1).help(document?.title ?? kind.title)
                        }
                        Spacer(minLength: 0)
                        if interactive, let guide = store.guide {
                            Menu {
                                Button("整篇导读") { store.overview() }
                                Divider()
                                ForEach(guide.concepts) { concept in
                                    Button(concept.title) { store.showConcept(concept.id); onPDFPage(concept.anchor.page + 1) }
                                }
                            } label: { Label("概念", systemImage: "list.bullet") }
                                .controlSize(.small).fixedSize().help("整篇导读与关键概念").accessibilityLabel("概念目录")
                        } else if let doc = document {
                            Button { showCoverage.toggle() } label: {
                                HStack(spacing: 3) {
                                    Text(doc.statusTitle)
                                    Image(systemName: "info.circle").font(.system(size: 9))
                                }.font(.system(size: 10, weight: .medium)).foregroundStyle(StudyTheme.accent)
                                    .padding(.horizontal, 9).frame(height: 24)
                            }.buttonStyle(ReaderChromeButtonStyle(selected: true)).fixedSize().help("查看材料覆盖范围")
                                .accessibilityLabel("\(doc.statusTitle)，查看覆盖范围")
                                .popover(isPresented: $showCoverage) {
                                    VStack(alignment: .leading, spacing: 12) {
                                        Text(doc.statusTitle).font(.headline)
                                        Text(doc.title).font(.callout).foregroundStyle(StudyTheme.text)
                                        Text(doc.coverage).font(.system(size: 12)).lineSpacing(5).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                    }.padding(20).frame(width: 310)
                                }
                        }
                        Menu {
                            Button("添加或更新学习材料…", action: addMaterials)
                                .disabled(!documents.ready)
                            if !interactive, let doc = document, let url = documents.url(for: doc) {
                                Button("在访达中显示文档") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            }
                        } label: { Image(systemName: "ellipsis.circle") }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22).accessibilityLabel("文档操作")
                    }.padding(.horizontal, 18).frame(height: 38)
                ReadingRule()
            }
            if interactive {
                GuidePane(store: store, documents: documents, pdf: pdf, reader: reader, onFocus: onFocus, onNoteSource: onNoteSource, onPDFPage: onPDFPage)
            } else if let doc = document, let url = documents.url(for: doc) {
                MarkdownDocumentView(markdownURL: url, documentID: doc.id, fontSize: store.data.fontSize,
                    dark: colorScheme == .dark, initialProgress: documents.progress(for: doc.id),
                    onProgress: { progress in documents.setProgress(progress, documentID: doc.id) },
                    onPage: onPDFPage, documentTitle: doc.title, initialLocation: documents.location(for: doc.id),
                    onLocation: { documents.setLocation($0, documentID: doc.id) }, controller: reader, onFocus: onFocus,
                    noteSources: store.data.notes.filter { $0.paperID == paper.id && $0.sourceSHA256 == paper.sha256 }.compactMap(\.documentSource).filter { $0.documentID == doc.id },
                    onNoteSource: onNoteSource)
                    .id(doc.id)
            } else {
                VStack(spacing: 15) {
                    Image(systemName: kind == .translation ? "character.book.closed" : "text.book.closed")
                        .font(.system(size: 30, weight: .light)).foregroundStyle(StudyTheme.muted).accessibilityHidden(true)
                    Text(kind == .translation ? "全文翻译待补充" : "深度理解材料待补充")
                        .font(.system(size: 18, weight: .semibold))
                    Text(kind == .translation
                         ? "可以导入已有译文，也可以先读原文、留下疑问。"
                         : "导入解释文档，即可在这里与原文对照阅读。")
                        .font(.system(size: 13)).lineSpacing(6).multilineTextAlignment(.center).foregroundStyle(StudyTheme.muted)
                    Button("添加学习材料…", action: addMaterials)
                        .buttonStyle(.borderedProminent).disabled(!documents.ready)
                    Text("支持 Markdown 和 TXT，连同本地配图一起保存。")
                        .font(.system(size: 11)).foregroundStyle(StudyTheme.muted).multilineTextAlignment(.center)
                }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.background(StudyTheme.paper)
            .onChange(of: paper.id) { _, _ in showCoverage = false }
            .onChange(of: document?.id) { _, _ in showCoverage = false }
    }
}
