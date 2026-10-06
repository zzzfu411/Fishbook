import SwiftUI
import AppKit

struct CitationGraphPane: View {
    let paper: Paper
    let library: [Paper]
    let openPaper: (String) -> Void
    @StateObject private var model = CitationGraphModel()
    @StoredState<String> private var query = ""
    @StoredState<String> private var mode = "map"
    @StoredState<Bool> private var showSearch = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            if showSearch || model.graph == nil { searchBar }
            ReadingRule()
            Group {
                if let graph = model.graph {
                    VStack(spacing: 0) {
                        navigation
                        if mode == "map" { routeMap(graph) }
                        else { paperList(graph, direction: mode == "references" ? .references : .citations) }
                    }
                } else if model.searching {
                    VStack(spacing: 12) { ProgressView(); Text("正在查找论文…").foregroundStyle(StudyTheme.muted) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else { searchResults }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            ReadingRule()
            footer
        }
        .frame(width: 1000, height: 720)
        .background(StudyTheme.paper).foregroundStyle(StudyTheme.text).tint(StudyTheme.accent)
        .onAppear { query = paper.title; model.search(query, year: paper.year) }
        .onDisappear { model.cancel() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted").font(.title2).foregroundStyle(StudyTheme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text("引用路线图").font(.headline)
                Text(paper.name).font(.caption).foregroundStyle(StudyTheme.muted).lineLimit(1)
            }
            Spacer()
            Button { showSearch.toggle() } label: { Label("查找论文", systemImage: "magnifyingglass") }
                .help("匹配有误时，可用完整标题、DOI 或 arXiv 链接重新查找")
            if model.graph?.references.loading == true || model.graph?.citations.loading == true {
                ProgressView().controlSize(.small).accessibilityLabel("正在更新引用关系")
            }
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .disabled(model.graph == nil || model.graph?.references.loading == true || model.graph?.citations.loading == true)
                .accessibilityLabel("刷新引文数据").help("从 OpenAlex 更新引用关系")
            Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
        }.padding(.horizontal, 22).padding(.vertical, 16)
    }
    private var searchBar: some View {
        HStack(spacing: 10) {
            TextField("论文标题、DOI 或 arXiv 链接", text: $query).textFieldStyle(.roundedBorder)
                .accessibilityLabel("查找引文论文").onSubmit(search)
            Button("查找", action: search).disabled(model.searching || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }.padding(.horizontal, 22).padding(.bottom, 14)
    }
    private func search() { mode = "map"; model.search(query) }

    private var navigation: some View {
        HStack(spacing: 10) {
            Button { model.back() } label: { Label("返回", systemImage: "chevron.left") }
                .disabled(model.history.isEmpty).help(model.history.last.map { "返回 \($0.work.title)" } ?? "返回上一篇")
            Button("回到起点") { query = paper.title; model.search(query, year: paper.year); mode = "map" }
                .disabled(model.history.isEmpty)
            Spacer()
            Picker("显示方式", selection: $mode) {
                Text("路线图").tag("map")
                Text("它引用的").tag("references")
                Text("引用它的").tag("citations")
            }.pickerStyle(.segmented).labelsHidden().frame(width: 290)
        }.padding(.horizontal, 22).padding(.vertical, 12)
    }
    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = model.error {
                ContentUnavailableView("暂时无法获取引文", systemImage: "network.slash", description: Text(error))
                Button("重试") { model.search(query, refresh: true) }.frame(maxWidth: .infinity)
            } else if model.searched && model.candidates.isEmpty {
                ContentUnavailableView("暂未找到匹配论文", systemImage: "doc.text.magnifyingglass",
                    description: Text("试试完整标题或 DOI。新论文可能尚未被引文库收录。"))
            } else {
                Text("选择对应的论文版本").font(.headline)
                Text("预印本和正式版本可能分开收录，引用数量也会不同。")
                    .font(.callout).foregroundStyle(StudyTheme.muted)
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.candidates) { work in
                            Button { showSearch = false; model.explore(work) } label: {
                                HStack(spacing: 16) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(work.title).font(.system(size: 14, weight: .medium)).lineLimit(3)
                                        Text([work.detailLine, work.authorLine].filter { !$0.isEmpty }.joined(separator: " · "))
                                            .font(.caption).foregroundStyle(StudyTheme.muted).lineLimit(2)
                                        if let doi = work.doi { Text(doi).font(.caption).foregroundStyle(StudyTheme.muted).lineLimit(1) }
                                    }
                                    Spacer(minLength: 0)
                                    VStack(alignment: .trailing, spacing: 6) {
                                        Text("被引 \(work.citationCount.map(String.init) ?? "—")").font(.caption.monospacedDigit())
                                        Image(systemName: "chevron.right")
                                    }.foregroundStyle(StudyTheme.accent)
                                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(StudyTheme.canvas, in: RoundedRectangle(cornerRadius: 9))
                            }.buttonStyle(.plain).help("展开这篇论文的引用关系")
                        }
                    }
                }
            }
        }.padding(22).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func routeMap(_ graph: CitationNeighborhood) -> some View {
        VStack(spacing: 8) {
            HStack {
                branchHeading(graph.references, direction: .references)
                Spacer()
                Text("被引用的论文 → 引用它的论文").font(.caption).foregroundStyle(StudyTheme.muted)
                Spacer()
                branchHeading(graph.citations, direction: .citations)
            }
            GeometryReader { geometry in
                let width = geometry.size.width
                let column = (width - 96) / 3
                let height = geometry.size.height
                let cardHeight = min(82.0, (height - 40) / 5)
                ZStack {
                    Canvas { context, size in
                        drawEdges(context: &context, count: min(5, graph.references.papers.count),
                                  fromX: column, toX: column + 48, height: size.height, cardHeight: cardHeight, incoming: true)
                        drawEdges(context: &context, count: min(5, graph.citations.papers.count),
                                  fromX: column * 2 + 48, toX: column * 2 + 96, height: size.height, cardHeight: cardHeight, incoming: false)
                    }.accessibilityHidden(true)
                    HStack(spacing: 48) {
                        nodeColumn(graph.references, direction: .references, height: cardHeight).frame(width: column)
                        centerNode(graph.work).frame(width: column)
                        nodeColumn(graph.citations, direction: .citations, height: cardHeight).frame(width: column)
                    }.frame(height: height)
                }
            }
            Text("点击任一论文继续展开；列表可查看和加载更多结果。")
                .font(.caption).foregroundStyle(StudyTheme.muted).padding(.top, 4)
        }.padding(.horizontal, 22).padding(.bottom, 16)
    }
    private func branchHeading(_ branch: CitationBranch, direction: CitationDirection) -> some View {
        Button { mode = direction.rawValue } label: {
            HStack(spacing: 6) {
                Text(direction.title).font(.subheadline.weight(.medium))
                if let count = branch.total { Text("\(count)").monospacedDigit().foregroundStyle(StudyTheme.muted) }
                Image(systemName: "chevron.right").font(.caption2)
            }
        }.buttonStyle(.plain).help("查看\(direction.title)的完整列表")
    }
    private func nodeColumn(_ branch: CitationBranch, direction: CitationDirection, height: CGFloat) -> some View {
        VStack(spacing: 10) {
            if branch.papers.isEmpty { branchStatus(branch, direction: direction) }
            ForEach(Array(branch.papers.prefix(5))) { work in
                Button { model.explore(work) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(work.title).font(.system(size: 12, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading)
                        HStack {
                            Text(work.year.map(String.init) ?? "年份未知").monospacedDigit()
                            Spacer(minLength: 4)
                            if localPaper(work) != nil { Image(systemName: "books.vertical").help("已在资料库") }
                            Image(systemName: "arrow.right")
                        }.font(.caption).foregroundStyle(StudyTheme.muted)
                    }.padding(11).frame(maxWidth: .infinity, alignment: .leading).frame(height: height)
                        .background(StudyTheme.surface, in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(StudyTheme.line, lineWidth: 1))
                }.buttonStyle(.plain).help(work.title + "\n点击展开引用关系")
                    .accessibilityLabel("\(direction.title)：\(work.title)，\(work.year.map(String.init) ?? "年份未知")；展开")
                    .contextMenu { workActions(work) }
            }
        }
    }
    private func centerNode(_ work: CitationWork) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("当前论文", systemImage: "doc.text").font(.caption.weight(.semibold)).foregroundStyle(StudyTheme.accent)
            Text(work.title).font(.system(size: 16, weight: .semibold)).lineLimit(8).fixedSize(horizontal: false, vertical: true).help(work.title)
            if !work.authorLine.isEmpty { Text(work.authorLine).font(.caption).foregroundStyle(StudyTheme.muted) }
            Text(work.detailLine).font(.caption).foregroundStyle(StudyTheme.muted)
            Link("查看来源 ↗", destination: work.sourceURL).font(.caption)
            if let local = localPaper(work) {
                Button("在资料库中阅读") { dismiss(); openPaper(local.id) }.font(.caption)
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(StudyTheme.accentSoft, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(StudyTheme.accent.opacity(0.45), lineWidth: 1))
    }
    private func drawEdges(context: inout GraphicsContext, count: Int, fromX: CGFloat, toX: CGFloat,
                           height: CGFloat, cardHeight: CGFloat, incoming: Bool) {
        let totalHeight = CGFloat(count) * cardHeight + CGFloat(max(0, count - 1)) * 10
        for index in 0..<count {
            let nodeY = (height - totalHeight) / 2 + cardHeight / 2 + CGFloat(index) * (cardHeight + 10)
            let start = CGPoint(x: fromX, y: incoming ? nodeY : height / 2)
            let end = CGPoint(x: toX, y: incoming ? height / 2 : nodeY)
            var path = Path(); path.move(to: start)
            path.addCurve(to: end, control1: CGPoint(x: fromX + 24, y: start.y), control2: CGPoint(x: toX - 24, y: end.y))
            context.stroke(path, with: .color(StudyTheme.accent.opacity(0.45)), lineWidth: 1)
            var arrow = Path(); arrow.move(to: CGPoint(x: end.x - 5, y: end.y - 3)); arrow.addLine(to: end); arrow.addLine(to: CGPoint(x: end.x - 5, y: end.y + 3))
            context.stroke(arrow, with: .color(StudyTheme.accent.opacity(0.65)), lineWidth: 1)
        }
    }

    private func paperList(_ graph: CitationNeighborhood, direction: CitationDirection) -> some View {
        let branch = graph[direction]
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(graph.work.title).font(.headline).lineLimit(2)
                Spacer()
                Text("已载入 \(branch.papers.count) / \(branch.total.map(String.init) ?? "—")")
                    .font(.caption.monospacedDigit()).foregroundStyle(StudyTheme.muted)
            }
            Text(direction == .references ? "按被引次数排序" : "按发表时间从新到旧排列")
                .font(.caption).foregroundStyle(StudyTheme.muted)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(branch.papers) { work in
                        HStack(alignment: .top, spacing: 14) {
                            Text(work.year.map(String.init) ?? "—").font(.callout.monospacedDigit()).foregroundStyle(StudyTheme.muted).frame(width: 45)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(work.title).font(.system(size: 14, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                                Text([work.authorLine, work.venue ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(StudyTheme.muted).lineLimit(2)
                                HStack(spacing: 12) {
                                    Link("来源 ↗", destination: work.sourceURL)
                                    if let local = localPaper(work) { Button("在资料库中阅读") { dismiss(); openPaper(local.id) }.buttonStyle(.link) }
                                }.font(.caption)
                            }
                            Spacer(minLength: 6)
                            Button("展开") { model.explore(work) }.help("查看这篇论文的引用和被引")
                        }.padding(.vertical, 13)
                        ReadingRule()
                    }
                    branchStatus(branch, direction: direction).frame(maxWidth: .infinity).padding(.vertical, 16)
                    if branch.next != nil && !branch.loading && branch.error == nil {
                        Button("加载更多") { model.load(direction, more: true) }.frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                }
            }.id(graph.work.id + direction.rawValue)
        }.padding(.horizontal, 22).padding(.bottom, 12)
    }
    @ViewBuilder private func branchStatus(_ branch: CitationBranch, direction: CitationDirection) -> some View {
        if branch.loading {
            VStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在载入…").font(.caption).foregroundStyle(StudyTheme.muted) }
        } else if let error = branch.error {
            VStack(spacing: 10) {
                Text(error).font(.caption).foregroundStyle(StudyTheme.muted).multilineTextAlignment(.center)
                Button("重试") { model.load(direction, more: !branch.papers.isEmpty && branch.next != nil, refresh: true) }
            }
        } else if branch.papers.isEmpty {
            Text("OpenAlex 暂未收录\n\(direction == .references ? "它的参考文献关系" : "引用它的论文")")
                .font(.callout).foregroundStyle(StudyTheme.muted).multilineTextAlignment(.center)
        }
    }
    @ViewBuilder private func workActions(_ work: CitationWork) -> some View {
        Button("展开引用关系") { model.explore(work) }
        Link("在 OpenAlex 查看", destination: work.sourceURL)
        if let local = localPaper(work) { Button("在资料库中阅读") { dismiss(); openPaper(local.id) } }
    }
    private func localPaper(_ work: CitationWork) -> Paper? {
        let title = CitationWork.normalizedTitle(work.title)
        let matches = library.filter { CitationWork.normalizedTitle($0.title) == title && ($0.year == 0 || work.year == nil || $0.year == work.year) }
        return matches.count == 1 ? matches[0] : nil
    }
    private var footer: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Link("数据来自 OpenAlex", destination: URL(string: "https://help.openalex.org/data/works/citations/")!).font(.caption)
                if let graph = model.graph {
                    let branches = [graph.references, graph.citations]
                    if branches.contains(where: { $0.error != nil }) {
                        Label("部分关系未能载入，可在列表中重试", systemImage: "exclamationmark.circle")
                            .font(.caption).foregroundStyle(StudyTheme.muted)
                    }
                    if let date = branches.compactMap(\.fetchedAt).min() {
                        Text("· \(branches.contains(where: \.stale) ? "离线或刷新未成功，使用缓存" : branches.contains(where: \.cached) ? "缓存" : "获取于") \(date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(StudyTheme.muted)
                    }
                }
                Spacer()
            }
            Text("收录可能不全，数量以当前数据源为准。仅查询论文标题或标识符，不上传 PDF 和笔记。")
                .font(.caption).foregroundStyle(StudyTheme.muted)
        }.padding(.horizontal, 22).padding(.vertical, 12)
    }
}
