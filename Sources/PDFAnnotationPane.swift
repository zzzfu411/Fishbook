import SwiftUI
import PDFKit

extension StudyNote {
    var pdfMarkTitle: String { kind == "高亮" && documentSource == nil ? effectiveMarkupStyle.title : kind }
    var pdfMarkSymbol: String {
        kind == "疑问" ? "questionmark.bubble" : kind == "高亮" ? effectiveMarkupStyle.symbol : "text.bubble"
    }
}

struct PDFMarkupBar: View {
    @Binding var color: PDFMarkupColor
    let canMark: Bool
    let count: Int
    let mark: (PDFMarkupStyle) -> Void
    let comment: (String) -> Void
    let showAnnotations: () -> Void
    let export: () -> Void

    private var colorSwatch: NSImage {
        let fill = color.nsColor
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { bounds in
            fill.setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(PDFMarkupStyle.allCases) { style in
                ReaderIconButton(style.title, symbol: style.symbol, disabled: !canMark) { mark(style) }
                    .help("\(style.title)所选文字 · \(color.title)")
            }
            Menu {
                ForEach(PDFMarkupColor.allCases) { choice in
                    Button { color = choice } label: {
                        Label(choice.title + (choice == color ? " ✓" : ""), systemImage: "circle.fill")
                            .foregroundStyle(Color(nsColor: choice.nsColor))
                    }
                }
            } label: {
                Image(nsImage: colorSwatch).renderingMode(.original)
                    .frame(width: 28, height: 30)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28)
                .help("标记颜色 · \(color.title)").accessibilityLabel("标记颜色").accessibilityValue(color.title)
            StudyTheme.line.frame(width: 0.5, height: 16).padding(.horizontal, 3)
            ReaderIconButton("写批注", symbol: "text.bubble") { comment("笔记") }
            ReaderIconButton("留下疑问", symbol: "questionmark.bubble") { comment("疑问") }
            Spacer(minLength: 0)
            Button(action: showAnnotations) {
                HStack(spacing: 4) {
                    Image(systemName: "list.bullet.rectangle")
                    if count > 0 { Text("\(count)").font(.system(size: 10).monospacedDigit()) }
                }.frame(minWidth: 28, minHeight: 30)
            }.buttonStyle(ReaderChromeButtonStyle()).help("查看、查找和编辑批注").accessibilityLabel("批注列表，共 \(count) 条")
            Menu {
                Button("导出带批注的 PDF…", action: export)
            } label: { Image(systemName: "ellipsis").frame(width: 24, height: 30) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24)
                .help("导出带批注的 PDF 副本").accessibilityLabel("PDF 批注操作")
        }.padding(.horizontal, 12).frame(height: 40).foregroundStyle(StudyTheme.text)
            .background { ReaderChromeBackground() }
    }
}

struct PDFAnnotationPane: View {
    let paper: Paper
    @ObservedObject var store: StudyStore
    @ObservedObject var pdf: PDFController
    let edit: (StudyNote) -> Void
    let locate: (Anchor) -> Void
    let export: () -> Void
    @StoredState<String> private var query = ""
    @StoredState<String> private var filter = "all"
    @StoredState<Bool> private var sourcePDF = false
    @Environment(\.undoManager) private var undo
    @Environment(\.dismiss) private var dismiss

    private var notes: [StudyNote] {
        store.annotationNotes(for: paper.id).sorted {
            let a = $0.anchors.first?.page ?? 0, b = $1.anchors.first?.page ?? 0
            return a == b ? $0.created < $1.created : a < b
        }
    }
    private var visibleNotes: [StudyNote] {
        notes.filter { note in
            let matchesType = filter == "all" || (filter == "question" && note.kind == "疑问") ||
                (filter == "comment" && note.kind == "笔记") ||
                (note.kind == "高亮" && note.effectiveMarkupStyle.rawValue == filter)
            return matchesType && matches(note.body + " " + note.quote)
        }
    }
    private var sourceNotes: [PDFEmbeddedAnnotation] { pdf.embeddedAnnotations.filter { matches($0.body + " " + $0.quote + " " + $0.title) } }
    private func matches(_ text: String) -> Bool {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty || text.localizedCaseInsensitiveContains(term)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("批注").font(.headline)
                Text("\(notes.count)").font(.callout.monospacedDigit()).foregroundStyle(StudyTheme.muted)
                Spacer()
                Button("导出 PDF…", action: export).buttonStyle(.link).font(.system(size: 12))
            }
            if !pdf.embeddedAnnotations.isEmpty {
                Picker("批注来源", selection: $sourcePDF) {
                    Text("我的批注").tag(false)
                    Text("PDF 自带 · \(pdf.embeddedAnnotations.count)").tag(true)
                }.pickerStyle(.segmented).labelsHidden()
            }
            HStack(spacing: 8) {
                TextField("搜索摘录与批注", text: $query).textFieldStyle(.roundedBorder).accessibilityLabel("搜索 PDF 批注")
                if !sourcePDF {
                    Menu {
                        Button("全部类型") { filter = "all" }
                        ForEach(PDFMarkupStyle.allCases) { style in
                            Button(style.title) { filter = style.rawValue }
                        }
                        Button("笔记") { filter = "comment" }
                        Button("疑问") { filter = "question" }
                    } label: { Image(systemName: filter == "all" ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24).accessibilityLabel("筛选批注类型")
                }
            }
            if sourcePDF {
                Text("原文件中的批注，可定位查看。")
                    .font(.system(size: 11)).foregroundStyle(StudyTheme.muted)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if sourcePDF {
                        ForEach(sourceNotes) { annotation in embeddedCard(annotation) }
                    } else {
                        ForEach(visibleNotes) { note in noteCard(note) }
                    }
                    if sourcePDF ? sourceNotes.isEmpty : visibleNotes.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "text.bubble").font(.system(size: 28, weight: .light))
                            Text(query.isEmpty && filter == "all" ? "这里还没有批注" : "没有找到匹配的批注").font(.system(size: 13, weight: .medium))
                            if notes.isEmpty && !sourcePDF {
                                Text("选中文字做标记，或写下读到这里的想法。")
                                    .font(.system(size: 12)).multilineTextAlignment(.center)
                            }
                        }.foregroundStyle(StudyTheme.muted).frame(maxWidth: .infinity).padding(.vertical, 60)
                    }
                }.padding(.trailing, 2)
            }.frame(height: 330)
        }.padding(18).frame(width: 360).foregroundStyle(StudyTheme.text).background(StudyTheme.paper)
            .onExitCommand { dismiss() }
    }

    private func noteCard(_ note: StudyNote) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(Color(nsColor: note.effectiveMarkupColor.nsColor)).frame(width: 8, height: 8)
                Label(note.pdfMarkTitle, systemImage: note.pdfMarkSymbol).font(.system(size: 11, weight: .medium))
                Spacer()
                Button("第 \((note.anchors.first?.page ?? 0) + 1) 页") {
                    if let anchor = note.anchors.first { locate(anchor) }
                }.buttonStyle(.link).font(.system(size: 11))
            }
            if !note.quote.isEmpty { Text(note.quote).font(.system(size: 12)).foregroundStyle(StudyTheme.muted).lineLimit(3) }
            if !note.body.isEmpty { Text(note.body).font(.system(size: 13)).lineLimit(5) }
            HStack {
                Button("编辑") { edit(note) }.buttonStyle(.link)
                Spacer()
                if note.kind == "疑问" {
                    Button(note.resolved ? "已解决" : "标记解决") { store.toggleResolved(note.id) }.buttonStyle(.borderless)
                }
                Menu {
                    Menu("颜色") {
                        ForEach(PDFMarkupColor.allCases) { color in
                            Button(color.title + (color == note.effectiveMarkupColor ? " ✓" : "")) {
                                var changed = note; changed.markupColor = color; store.upsert(changed, undo: undo)
                            }
                        }
                    }
                    if note.anchors.contains(where: { !$0.rects.isEmpty }) {
                        Menu("标记样式") {
                            ForEach(PDFMarkupStyle.allCases) { style in
                                Button(style.title + (style == note.effectiveMarkupStyle ? " ✓" : "")) {
                                    var changed = note; changed.markupStyle = style; store.upsert(changed, undo: undo)
                                }
                            }
                        }
                    }
                    Divider()
                    Button("删除批注", role: .destructive) { store.remove(note, undo: undo) }
                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 22) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24).accessibilityLabel("此条批注的颜色、样式与删除")
            }.font(.system(size: 11))
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(StudyTheme.surface, in: RoundedRectangle(cornerRadius: 9))
    }

    private func embeddedCard(_ annotation: PDFEmbeddedAnnotation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(annotation.title).font(.system(size: 11, weight: .medium))
                Spacer()
                Button("第 \(annotation.page + 1) 页") {
                    locate(Anchor(page: annotation.page, rects: [Box(annotation.bounds)], quote: annotation.quote))
                }.buttonStyle(.link).font(.system(size: 11))
            }
            if !annotation.quote.isEmpty { Text(annotation.quote).font(.system(size: 12)).foregroundStyle(StudyTheme.muted).lineLimit(3) }
            if !annotation.body.isEmpty { Text(annotation.body).font(.system(size: 13)).lineLimit(5).textSelection(.enabled) }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(StudyTheme.surface, in: RoundedRectangle(cornerRadius: 9))
    }
}
