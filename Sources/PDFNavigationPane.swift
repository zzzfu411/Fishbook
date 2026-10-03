import SwiftUI
import AppKit
import PDFKit

/// Keeps outline order intact, including skipped levels in publisher PDFs.
struct PDFOutlineNavigationIndex {
    let entries: [PDFOutlineEntry]
    let ancestors: [String: [String]]
    let parentIDs: Set<String>

    init(entries: [PDFOutlineEntry]) {
        self.entries = entries
        var stack: [PDFOutlineEntry] = []
        var paths: [String: [String]] = [:]
        var parents = Set<String>()
        for entry in entries {
            while let last = stack.last, last.level >= entry.level { stack.removeLast() }
            paths[entry.id] = stack.map(\.id)
            if let parent = stack.last { parents.insert(parent.id) }
            stack.append(entry)
        }
        ancestors = paths
        parentIDs = parents
    }

    func rows(query: String, collapsed: Set<String>) -> [PDFOutlineEntry] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if term.isEmpty {
            return entries.filter { entry in
                !(ancestors[entry.id] ?? []).contains(where: collapsed.contains)
            }
        }
        var included = Set<String>()
        for entry in entries where entry.title.localizedStandardContains(term) {
            included.insert(entry.id)
            included.formUnion(ancestors[entry.id] ?? [])
        }
        return entries.filter { included.contains($0.id) }
    }
}

struct PDFContentsPane: View {
    let paper: Paper
    @ObservedObject var pdf: PDFController
    @ObservedObject var features: LibraryFeatureStore
    let close: () -> Void
    @StateObject private var thumbnails = PDFNavigationThumbnailCache()
    @StoredState<NavigationTab> private var tab = .outline
    @StoredState<String> private var query = ""
    @StoredState<Set<String>> private var collapsed: Set<String> = []
    @StoredState<UUID?> private var editingBookmark = nil
    @StoredState<String> private var bookmarkTitle = ""
    @StoredState<String?> private var bookmarkError = nil
    @FocusState private var bookmarkTitleFocused: Bool

    private enum NavigationTab: String, CaseIterable {
        case outline = "目录", thumbnails = "缩略图", bookmarks = "书签"
    }
    private var paperKey: String { paper.id + ":" + paper.sha256 }
    private var pageCount: Int { pdf.loadedID == paper.id ? (pdf.view.document?.pageCount ?? 0) : 0 }
    private var bookmarks: [PDFBookmark] { features.bookmarks(for: paper) }
    private var currentPageBookmarked: Bool { bookmarks.contains { $0.page == pdf.pageNumber - 1 } }
    private var validCurrentPage: Bool { pageCount > 0 && (1...pageCount).contains(pdf.pageNumber) }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Text("原文导航").font(.system(size: 14, weight: .semibold))
                Text("\(pdf.pageNumber) / \(paper.pages)").font(.system(size: 11).monospacedDigit()).foregroundStyle(StudyTheme.muted)
                Spacer()
                Button(action: close) { Image(systemName: "xmark").frame(width: 22, height: 22) }
                    .buttonStyle(.borderless).help("关闭原文导航").accessibilityLabel("关闭原文导航")
            }
            Picker("原文导航方式", selection: $tab) {
                ForEach(NavigationTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            Group {
                switch tab {
                case .outline: outlinePane
                case .thumbnails: thumbnailPane
                case .bookmarks: bookmarkPane
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let bookmarkError {
                Label(bookmarkError, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(StudyTheme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16).frame(width: 360, height: 470)
        .foregroundStyle(StudyTheme.text).background(StudyTheme.paper).tint(StudyTheme.accent)
        .onAppear { configureThumbnails() }
        .onDisappear { thumbnails.reset() }
        .onChange(of: paperKey) { _, _ in
            query = ""; collapsed = []; editingBookmark = nil; bookmarkError = nil
            configureThumbnails()
        }
        .onChange(of: tab) { _, value in
            editingBookmark = nil; bookmarkError = nil
            if value == .thumbnails { configureThumbnails() }
            else { thumbnails.clearImages() }
        }
    }

    private var outlinePane: some View {
        let index = PDFOutlineNavigationIndex(entries: pdf.outline)
        let rows = index.rows(query: query, collapsed: collapsed)
        let searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(spacing: 10) {
            if !pdf.outline.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(StudyTheme.muted).accessibilityHidden(true)
                    TextField("搜索目录", text: $query).textFieldStyle(.plain).accessibilityLabel("搜索 PDF 目录")
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(StudyTheme.muted).accessibilityLabel("清除目录搜索")
                    }
                }.font(.system(size: 12)).padding(8).background(StudyTheme.canvas, in: RoundedRectangle(cornerRadius: 7))
                if !index.parentIDs.isEmpty && !searching {
                    HStack {
                        Text("原文内置目录").font(.caption).foregroundStyle(StudyTheme.muted)
                        Spacer()
                        Button(collapsed.isEmpty ? "全部折叠" : "全部展开") {
                            collapsed = collapsed.isEmpty ? index.parentIDs : []
                        }.buttonStyle(.link).font(.caption)
                    }
                }
            }
            if pdf.outline.isEmpty {
                emptyState("这份 PDF 没有内置目录", detail: "可以通过缩略图浏览，或收藏常看的页面。", symbol: "list.bullet.indent")
            } else if rows.isEmpty {
                emptyState("没有匹配的章节", detail: "试试标题中的其他词。", symbol: "magnifyingglass")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(rows) { entry in
                            outlineRow(entry, index: index, searching: searching)
                        }
                    }
                }
            }
        }
    }

    private func outlineRow(_ entry: PDFOutlineEntry, index: PDFOutlineNavigationIndex, searching: Bool) -> some View {
        HStack(spacing: 4) {
            if index.parentIDs.contains(entry.id) {
                Button {
                    if collapsed.contains(entry.id) { collapsed.remove(entry.id) }
                    else { collapsed.insert(entry.id) }
                } label: {
                    Image(systemName: !searching && collapsed.contains(entry.id) ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold)).frame(width: 18, height: 28)
                }.buttonStyle(.plain).disabled(searching)
                    .accessibilityLabel("\(collapsed.contains(entry.id) ? "展开" : "折叠") \(entry.title)")
            } else {
                Color.clear.frame(width: 18, height: 1).accessibilityHidden(true)
            }
            Button { pdf.goOutline(entry); close() } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.title).lineLimit(2).multilineTextAlignment(.leading)
                    Spacer(minLength: 4)
                    Text("\(entry.page + 1)").font(.system(size: 11).monospacedDigit()).foregroundStyle(StudyTheme.muted)
                }.frame(maxWidth: .infinity, minHeight: 30, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("\(entry.title)，第 \(entry.page + 1) 页")
        }
        .font(.system(size: 12))
        .padding(.leading, CGFloat(min(index.ancestors[entry.id]?.count ?? 0, 5)) * 12)
        .padding(.trailing, 6).padding(.vertical, 3)
        .background(entry.page == pdf.pageNumber - 1 ? StudyTheme.accentSoft.opacity(0.65) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder private var thumbnailPane: some View {
        if pageCount == 0 {
            emptyState("原文暂不可用", detail: "PDF 载入后会显示页面预览。", symbol: "doc.questionmark")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(0..<pageCount, id: \.self) { page in
                            PDFNavigationThumbnailCell(page: page, selected: page == pdf.pageNumber - 1, cache: thumbnails) {
                                pdf.goPage(page + 1); close()
                            }.id(page)
                        }
                    }.padding(3)
                }.onAppear { proxy.scrollTo(max(0, pdf.pageNumber - 1), anchor: .center) }
            }.id(paperKey)
        }
    }

    private var bookmarkPane: some View {
        VStack(spacing: 12) {
            HStack {
                Text("\(bookmarks.count) 个书签").font(.caption).foregroundStyle(StudyTheme.muted)
                Spacer()
                Button {
                    bookmarkError = nil
                    if !features.addBookmark(paper: paper, page: pdf.pageNumber - 1) {
                        bookmarkError = features.error ?? "书签未能保存，请重试。"
                    }
                } label: {
                    Label(currentPageBookmarked ? "当前页已收藏" : "收藏当前页", systemImage: currentPageBookmarked ? "bookmark.fill" : "bookmark.badge.plus")
                }.buttonStyle(.borderless).font(.system(size: 12))
                    .disabled(!features.ready || !validCurrentPage || currentPageBookmarked)
                    .accessibilityLabel(currentPageBookmarked ? "第 \(pdf.pageNumber) 页已收藏" : "收藏第 \(pdf.pageNumber) 页")
            }
            if bookmarks.isEmpty {
                emptyState("还没有书签", detail: "收藏当前页，下次可以从这里接着读。", symbol: "bookmark")
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(bookmarks) { bookmark in bookmarkRow(bookmark) }
                    }
                }
            }
            if features.obsoleteBookmarkCount(for: paper) > 0 {
                Text("其他 PDF 版本的书签仍保留在资料库中。").font(.caption).foregroundStyle(StudyTheme.muted)
            }
        }
    }

    private func bookmarkRow(_ bookmark: PDFBookmark) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "bookmark.fill").font(.system(size: 11)).foregroundStyle(StudyTheme.accent).accessibilityHidden(true)
            if editingBookmark == bookmark.id {
                TextField("书签名称", text: $bookmarkTitle).textFieldStyle(.roundedBorder)
                    .focused($bookmarkTitleFocused).accessibilityLabel("书签名称")
                    .onSubmit { saveBookmarkTitle(bookmark) }
                    .onExitCommand { editingBookmark = nil }
                Button("保存") { saveBookmarkTitle(bookmark) }.buttonStyle(.borderless)
                    .disabled(bookmarkTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                Button { pdf.goPage(bookmark.page + 1); close() } label: {
                    HStack(spacing: 8) {
                        Text(bookmark.title).lineLimit(2).multilineTextAlignment(.leading)
                        Spacer(minLength: 4)
                        Text("\(bookmark.page + 1)").font(.caption.monospacedDigit()).foregroundStyle(StudyTheme.muted)
                    }.frame(maxWidth: .infinity, minHeight: 30, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("\(bookmark.title)，第 \(bookmark.page + 1) 页")
                Menu {
                    Button("重命名") {
                        bookmarkTitle = bookmark.title; editingBookmark = bookmark.id; bookmarkError = nil
                        bookmarkTitleFocused = true
                    }
                    Button("移除书签", role: .destructive) {
                        bookmarkError = nil
                        if !features.removeBookmark(bookmark.id) { bookmarkError = features.error ?? "书签未能移除，请重试。" }
                    }
                } label: { Image(systemName: "ellipsis").frame(width: 20, height: 24) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .disabled(!features.ready).accessibilityLabel("管理书签：\(bookmark.title)")
            }
        }.font(.system(size: 12)).padding(.horizontal, 8).padding(.vertical, 5)
            .background(bookmark.page == pdf.pageNumber - 1 ? StudyTheme.accentSoft.opacity(0.65) : StudyTheme.canvas.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    private func saveBookmarkTitle(_ bookmark: PDFBookmark) {
        let title = bookmarkTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        if features.renameBookmark(bookmark.id, title: title) { editingBookmark = nil; bookmarkError = nil }
        else { bookmarkError = features.error ?? "书签名称未能保存，请重试。" }
    }

    private func configureThumbnails() {
        thumbnails.configure(document: pdf.loadedID == paper.id ? pdf.view.document : nil, key: paperKey)
    }

    private func emptyState(_ title: String, detail: String, symbol: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 25, weight: .light)).foregroundStyle(StudyTheme.muted)
            Text(title).font(.system(size: 13, weight: .medium))
            Text(detail).font(.system(size: 12)).foregroundStyle(StudyTheme.muted).multilineTextAlignment(.center)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A popover-local cache. The document is borrowed, never copied or kept alive.
@MainActor private final class PDFNavigationThumbnailCache: ObservableObject {
    @Published private(set) var generation = 0
    private weak var document: PDFDocument?
    private var key = ""
    private let images = NSCache<NSNumber, NSImage>()
    private var order: [Int] = []
    private let limit = 24

    init() {
        images.countLimit = limit
        images.totalCostLimit = limit * 160 * 208 * 4
    }

    func configure(document: PDFDocument?, key: String) {
        guard self.document !== document || self.key != key else { return }
        self.document = document; self.key = key
        clearImages()
    }

    func image(for page: Int) -> NSImage? {
        let cacheKey = NSNumber(value: page)
        if let image = images.object(forKey: cacheKey) {
            order.removeAll { $0 == page }; order.append(page)
            return image
        }
        guard let source = document?.page(at: page) else { return nil }
        let image = source.thumbnail(of: NSSize(width: 160, height: 208), for: .cropBox)
        while order.count >= limit { images.removeObject(forKey: NSNumber(value: order.removeFirst())) }
        images.setObject(image, forKey: cacheKey, cost: 160 * 208 * 4)
        order.append(page)
        return image
    }

    func clearImages() { images.removeAllObjects(); order.removeAll(); generation += 1 }
    func reset() { document = nil; key = ""; clearImages() }
}

@MainActor private struct PDFNavigationThumbnailCell: View {
    let page: Int
    let selected: Bool
    @ObservedObject var cache: PDFNavigationThumbnailCache
    let action: () -> Void
    @StoredState<NSImage?> private var image = nil

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4).fill(StudyTheme.canvas)
                    if let image { Image(nsImage: image).resizable().interpolation(.medium).scaledToFit().padding(4) }
                    else { Image(systemName: "doc").foregroundStyle(StudyTheme.muted) }
                }.frame(height: 174)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected ? StudyTheme.accent : StudyTheme.line, lineWidth: selected ? 2 : 0.5))
                Text("第 \(page + 1) 页").font(.system(size: 11, weight: selected ? .semibold : .regular).monospacedDigit())
                    .foregroundStyle(selected ? StudyTheme.accent : StudyTheme.muted)
            }.padding(2).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("跳转到第 \(page + 1) 页\(selected ? "，当前页" : "")")
            .task(id: cache.generation) { @MainActor in
                await Task.yield()
                guard !Task.isCancelled else { return }
                image = cache.image(for: page)
            }
            .onDisappear { image = nil }
    }
}
