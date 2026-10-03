import SwiftUI
import AppKit
import PDFKit
import CryptoKit

private let ownerKey=PDFAnnotationKey(rawValue:"/PSOwner")
@MainActor final class StudyPDFView: PDFView {
    var conceptTapped: ((String, CGRect) -> Void)?
    var recordSelection: ((String) -> Void)?
    var markupSelection: ((PDFMarkupStyle, PDFMarkupColor?) -> Void)?
    var readingFocused: (() -> Void)?
    var readingLayoutChanged: (() -> Void)?
    var colorPreset: PDFColorPreset = .original
    private var markers:[(button:NSButton,page:PDFPage,rect:CGRect)]=[]
    override func draw(_ page: PDFPage, to context: CGContext) {
        let preset: PDFColorPreset = NSPrintOperation.current == nil ? colorPreset : .original
        PDFColorRenderer.draw(preset: preset, in: context, bounds: PDFColorRenderer.drawingBounds(for: page, box: displayBox)) {
            super.draw(page, to: context)
        }
    }
    func setConceptMarkers(_ concepts:[Concept]) {
        for item in markers { item.button.removeFromSuperview() }
        markers=[]
        guard let document else {return}
        for c in concepts {
            guard let page=document.page(at:c.anchor.page),let b=c.anchor.rects.first else {continue}
            let crop=page.bounds(for:.cropBox)
            let rect=CGRect(x:max(crop.minX+3,b.x-19),y:b.y+b.height-14,width:13,height:13)
            let button=NSButton(image:NSImage(systemSymbolName:"questionmark.circle.fill",accessibilityDescription:c.title)!,target:self,action:#selector(openMarker(_:)))
            button.identifier=NSUserInterfaceItemIdentifier(c.id)
            button.isBordered=false;button.contentTintColor = colorPreset == .night ? colorPreset.inkColor : StudyTheme.pdfMarkerNS
            button.imageScaling = .scaleProportionallyUpOrDown
            button.setAccessibilityLabel("解释："+c.title);button.toolTip=c.summary
            addSubview(button,positioned:.above,relativeTo:nil)
            markers.append((button,page,rect))
        }
        updateMarkerPositions()
    }
    override func layout() { super.layout();updateMarkerPositions();readingLayoutChanged?() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow();readingLayoutChanged?() }
    override func mouseDown(with event: NSEvent) { readingFocused?();super.mouseDown(with:event) }
    override func rightMouseDown(with event: NSEvent) { readingFocused?();super.rightMouseDown(with:event) }
    override func scrollWheel(with event: NSEvent) { readingFocused?();super.scrollWheel(with:event) }
    override func keyDown(with event: NSEvent) { readingFocused?();super.keyDown(with:event) }
    func updateMarkerPositions() {
        for item in markers {
            let rect=convert(item.rect,from:item.page)
            item.button.frame=CGRect(x:rect.midX-10,y:rect.midY-10,width:20,height:20)
            item.button.isHidden = !bounds.intersects(item.button.frame)
            item.button.contentTintColor = colorPreset == .night ? colorPreset.inkColor : StudyTheme.pdfMarkerNS
        }
    }
    @objc private func openMarker(_ button:NSButton) {
        readingFocused?()
        if let id=button.identifier?.rawValue { conceptTapped?(id,button.frame) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let actions = [("留下疑问…", "疑问"), ("写批注…", "笔记")]
        menu.insertItem(.separator(), at: 0)
        for (title, kind) in actions.reversed() {
            let item = NSMenuItem(title: title, action: #selector(recordFromMenu(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = kind
            menu.insertItem(item, at: 0)
        }
        for style in PDFMarkupStyle.allCases.reversed() {
            let item = NSMenuItem(title: style.title, action: #selector(markupFromMenu(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = [style.rawValue]
            if style == .highlight {
                let colors = NSMenu()
                for color in PDFMarkupColor.allCases {
                    let choice = NSMenuItem(title: color.title, action: #selector(markupFromMenu(_:)), keyEquivalent: "")
                    choice.target = self; choice.representedObject = [style.rawValue, color.rawValue]
                    colors.addItem(choice)
                }
                item.submenu = colors
            }
            menu.insertItem(item, at: 0)
        }
        return menu
    }
    @objc private func markupFromMenu(_ item: NSMenuItem) {
        guard let values = item.representedObject as? [String], let first = values.first,
              let style = PDFMarkupStyle(rawValue: first) else { return }
        markupSelection?(style, values.count > 1 ? PDFMarkupColor(rawValue: values[1]) : nil)
    }
    @objc private func recordFromMenu(_ item: NSMenuItem) {
        if let kind = item.representedObject as? String { recordSelection?(kind) }
    }
}

struct PDFOutlineEntry: Identifiable, Equatable {
    let id: String
    let title: String
    /// PDF page indexes are zero-based everywhere except the visible page field.
    let page: Int
    let level: Int
    var point: CGPoint? = nil
}

struct PDFEmbeddedAnnotation: Identifiable {
    let id: String
    let page: Int
    let bounds: CGRect
    let title: String
    let body: String
    let quote: String
}

@MainActor final class PDFController: NSObject, ObservableObject {
    let view=StudyPDFView()
    @Published var pageNumber=1
    @Published var loadError: String? = nil
    @Published var searchResult = ""
    @Published private(set) var canBack=false
    @Published private(set) var canForward=false
    @Published private(set) var outline: [PDFOutlineEntry] = []
    @Published private(set) var embeddedAnnotations: [PDFEmbeddedAnnotation] = []
    @Published private(set) var hasTextSelection = false
    var hasReturnPoint: Bool { canBack }
    var onFocus: (() -> Void)?
    var onAnnotationTapped: ((UUID) -> Void)?
    @Published private(set) var matchCount = 0
    var loadedID: String?
    private var loadedFingerprint: String?
    var store: StudyStore?
    private var signature=""
    private var renderedMarks: [PDFAnnotation] = []
    private var bubble: NSPopover?
    private var saveWork: DispatchWorkItem?
    private var restoring=false
    private var matches: [PDFSelection]=[]
    private var activeSearchTerm = ""
    private var matchIndex=0
    private struct HistoryPoint {
        let page: Int
        let point: CGPoint
        func approximatelyEquals(_ other: HistoryPoint) -> Bool {
            page == other.page && abs(point.x-other.point.x)<2 && abs(point.y-other.point.y)<2
        }
    }
    private var previous: [HistoryPoint] = []
    private var following: [HistoryPoint] = []
    private var searchOriginRecorded = false
    private let historyLimit = 80
    private struct LayoutGeometry: Equatable {
        let width: CGFloat
        let height: CGFloat
        let scale: CGFloat
        let window: ObjectIdentifier
    }
    private var layoutAnchor: HistoryPoint?
    private var lastLayoutGeometry: LayoutGeometry?
    private var layoutRestoreWork: DispatchWorkItem?
    private var layoutGeneration = 0
    private var layoutRestoring = false

    override init() {
        super.init()
        view.autoScales=true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = StudyTheme.canvasNS
        view.setAccessibilityLabel("论文原文 PDF")
        view.readingFocused = { [weak self] in
            self?.cancelLayoutRestoration()
            self?.onFocus?()
        }
        view.readingLayoutChanged = { [weak self] in self?.readingLayoutChanged() }
        NotificationCenter.default.addObserver(self,selector:#selector(changed),name:.PDFViewPageChanged,object:view)
        NotificationCenter.default.addObserver(self,selector:#selector(changed),name:.PDFViewScaleChanged,object:view)
        NotificationCenter.default.addObserver(self,selector:#selector(selectionChanged),name:.PDFViewSelectionChanged,object:view)
        NotificationCenter.default.addObserver(self,selector:#selector(annotationHit(_:)),name:.PDFViewAnnotationHit,object:view)
        NotificationCenter.default.addObserver(self,selector:#selector(scrolled),name:NSView.boundsDidChangeNotification,object:nil)
        NotificationCenter.default.addObserver(self,selector:#selector(flush),name:NSApplication.willTerminateNotification,object:nil)
    }
    func setColorPreset(_ preset: PDFColorPreset) {
        guard view.colorPreset != preset else { return }
        if !layoutRestoring { cancelLayoutRestoration() }
        preservePositionForLayoutChange()
        let wasRestoring = restoring
        restoring = true
        view.colorPreset = preset
        view.backgroundColor = preset == .original ? StudyTheme.canvasNS : preset.canvasColor
        PDFColorRenderer.refresh(view)
        view.documentView?.enclosingScrollView?.contentView.postsBoundsChangedNotifications = true
        view.updateMarkerPositions()
        restoring = wasRestoring
        readingLayoutChanged()
    }
    func load(_ paper:Paper,store:StudyStore) {
        guard store.selectedID == paper.id else {return}
        self.store=store
        guard loadedID != paper.id || loadedFingerprint != paper.sha256 else { refreshMarks();return }
        flush();cancelLayoutRestoration();saveWork?.cancel();bubble?.close();loadedID=paper.id;loadedFingerprint=paper.sha256
        signature="";matches=[];activeSearchTerm="";matchCount=0;matchIndex=0;searchResult=""
        previous=[];following=[];searchOriginRecorded=false;outline=[];embeddedAnnotations=[];renderedMarks=[];hasTextSelection=false;publishHistory()
        do {
            let bytes=try Data(contentsOf:store.fileURL(paper))
            let hash=SHA256.hash(data:bytes).map { String(format:"%02x",$0) }.joined()
            guard hash == paper.sha256 else { throw StudyError.message("PDF 版本已变化。为避免错误定位，请重新导入这份 PDF。") }
            guard let document=PDFDocument(data:bytes),!document.isLocked else { throw StudyError.message("PDF 无法打开。") }
            restoring=true;view.setConceptMarkers([]);view.clearSelection();view.highlightedSelections=nil
            view.document=document;view.autoScales=true;pageNumber=1;loadError=nil
            outline=Self.flattenOutline(document)
            embeddedAnnotations=Self.readEmbeddedAnnotations(document)
            view.conceptTapped = { [weak self] id,rect in self?.showBubble(id,rect:rect) }
            refreshMarks()
            DispatchQueue.main.async { [weak self] in
                guard let self,self.loadedID == paper.id else { return }
                if let pos=store.readingPosition(for:paper.id),let page=document.page(at:pos.page) {
                    self.view.go(to:PDFDestination(page:page,at:CGPoint(x:pos.x,y:pos.y)))
                    self.pageNumber=pos.page+1
                }
                self.view.documentView?.enclosingScrollView?.contentView.postsBoundsChangedNotifications=true
                self.restoring=false
            }
        } catch { view.setConceptMarkers([]);view.document=nil;pageNumber=1;loadError=error.localizedDescription;restoring=false }
    }
    @objc private func selectionChanged() {
        hasTextSelection = !(view.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
    @objc private func annotationHit(_ notification: Notification) {
        guard let annotation = notification.userInfo?["PDFAnnotationHit"] as? PDFAnnotation,
              renderedMarks.contains(where: { $0 === annotation }),
              let value = annotation.value(forAnnotationKey: ownerKey) as? String,
              let id = UUID(uuidString: value) else { return }
        let paperID = loadedID
        DispatchQueue.main.async { [weak self] in
            guard let self, self.loadedID == paperID else { return }
            self.onAnnotationTapped?(id)
        }
    }
    private static func readEmbeddedAnnotations(_ document: PDFDocument) -> [PDFEmbeddedAnnotation] {
        let labels = ["Highlight": "高亮", "Underline": "下划线", "StrikeOut": "删除线", "Text": "便笺", "FreeText": "文本", "Ink": "手绘", "Circle": "圆形", "Square": "方框", "Line": "线条", "Stamp": "印章"]
        var result: [PDFEmbeddedAnnotation] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for (offset, annotation) in page.annotations.enumerated() {
                let type = (annotation.type ?? "").replacingOccurrences(of: "/", with: "")
                guard annotation.shouldDisplay, let title = labels[type], result.count < 10_000 else { continue }
                let quote = ["Highlight", "Underline", "StrikeOut"].contains(type) ? (page.selection(for: annotation.bounds)?.string ?? "") : ""
                result.append(PDFEmbeddedAnnotation(id: "\(index):\(offset)", page: index, bounds: annotation.bounds,
                    title: title, body: annotation.contents ?? "", quote: quote))
            }
        }
        return result
    }
    @objc private func changed() {
        view.updateMarkerPositions()
        readingLayoutChanged()
        updatePageNumber()
        scheduleSave()
    }
    @objc private func scrolled(_ note:Notification) {
        guard let clip=note.object as? NSClipView,
              clip == view.documentView?.enclosingScrollView?.contentView else { return }
        // PDFKit's internal scroll view can consume input before PDFView sees it.
        // A scroll after layout has settled must retire the old layout anchor.
        if !layoutRestoring, layoutAnchor != nil, layoutGeometry() == lastLayoutGeometry {
            cancelLayoutRestoration()
        }
        view.updateMarkerPositions()
        updatePageNumber()
        scheduleSave()
    }
    // PDFKit's currentPage can be the following page when the viewport spans
    // two pages. Save the page and point at the visible top edge instead.
    private func readingDestination()->PDFDestination? {
        guard view.document != nil,view.bounds.height > 0 else {return nil}
        let top=view.isFlipped ? view.bounds.minY : view.bounds.maxY
        let probe=CGPoint(x:view.bounds.midX,y:top + (view.isFlipped ? 1 : -1))
        guard let page=view.page(for:probe,nearest:true) else {return view.currentDestination}
        // Probe just inside the viewport to select the page, but save the actual
        // top edge. Saving the inset would lose one pixel on each color switch.
        let point=view.convert(CGPoint(x:view.bounds.minX,y:top),to:page)
        return PDFDestination(page:page,at:point)
    }
    private func historyPoint() -> HistoryPoint? {
        guard let destination=readingDestination(),let page=destination.page,let document=view.document,
              destination.point.x.isFinite,destination.point.y.isFinite else {return nil}
        let index=document.index(for:page)
        guard index>=0,index<document.pageCount else {return nil}
        return HistoryPoint(page:index,point:destination.point)
    }
    /// Keep the visible passage while SwiftUI moves this PDF view or changes its
    /// width. The anchor survives successive fullscreen animation frames, but
    /// any actual reading input or explicit navigation takes control immediately.
    func preservePositionForLayoutChange() {
        guard !restoring, loadedID != nil else { return }
        if layoutAnchor == nil {
            guard let point = historyPoint() else { return }
            flush()
            layoutAnchor = point
        }
        saveWork?.cancel()
        lastLayoutGeometry = nil
        layoutRestoring = true
        readingLayoutChanged()
    }
    private func layoutGeometry() -> LayoutGeometry? {
        guard let window = view.window, view.bounds.width > 1, view.bounds.height > 1,
              view.scaleFactor.isFinite, view.scaleFactor > 0 else { return nil }
        return LayoutGeometry(width: view.bounds.width, height: view.bounds.height,
                              scale: view.scaleFactor, window: ObjectIdentifier(window))
    }
    private func readingLayoutChanged() {
        guard layoutAnchor != nil else { return }
        guard let geometry = layoutGeometry() else {
            layoutGeneration += 1
            layoutRestoreWork?.cancel()
            lastLayoutGeometry = nil
            layoutRestoring = true
            return
        }
        guard lastLayoutGeometry != geometry else { return }
        lastLayoutGeometry = geometry
        layoutRestoring = true
        layoutGeneration += 1
        let generation = layoutGeneration
        layoutRestoreWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.layoutGeneration == generation,
                  let anchor = self.layoutAnchor,
                  let page = self.view.document?.page(at: anchor.page) else { return }
            self.view.layoutSubtreeIfNeeded()
            guard self.layoutGeneration == generation, self.layoutGeometry() == geometry else {
                self.readingLayoutChanged()
                return
            }
            self.view.go(to: PDFDestination(page: page, at: anchor.point))
            // PDFKit can adjust its scroll view during this go(). Keep the
            // intermediate bounds notification out of persisted reading progress.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.layoutGeneration == generation else { return }
                self.layoutRestoring = false
                self.updatePageNumber()
                self.flush()
            }
        }
        layoutRestoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }
    private func cancelLayoutRestoration() {
        layoutGeneration += 1
        layoutRestoreWork?.cancel()
        layoutRestoreWork = nil
        layoutAnchor = nil
        lastLayoutGeometry = nil
        layoutRestoring = false
    }
    private func append(_ point:HistoryPoint,to stack:inout [HistoryPoint]) {
        if let last=stack.last,last.approximatelyEquals(point) {return}
        stack.append(point)
        if stack.count>historyLimit {stack.removeFirst(stack.count-historyLimit)}
    }
    private func publishHistory() {canBack = !previous.isEmpty;canForward = !following.isEmpty}
    private func rememberCurrent() {
        guard let point=historyPoint() else {return}
        append(point,to:&previous);following=[];publishHistory()
    }
    private func restore(_ point:HistoryPoint) {
        guard let page=view.document?.page(at:point.page) else {return}
        view.clearSelection();view.go(to:PDFDestination(page:page,at:point.point))
        updatePageNumber();scheduleSave()
    }
    func goBack() {
        cancelLayoutRestoration()
        guard let target=previous.popLast() else {return}
        if let current=historyPoint() {append(current,to:&following)}
        restore(target);searchOriginRecorded=false;publishHistory()
    }
    func goForward() {
        cancelLayoutRestoration()
        guard let target=following.popLast() else {return}
        if let current=historyPoint() {append(current,to:&previous)}
        restore(target);searchOriginRecorded=false;publishHistory()
    }
    static func flattenOutline(_ document:PDFDocument) -> [PDFOutlineEntry] {
        guard let root=document.outlineRoot else {return []}
        var entries:[PDFOutlineEntry]=[],visited=Set<ObjectIdentifier>()
        func visit(_ node:PDFOutline,path:String,level:Int) {
            guard level<32,entries.count<2000,visited.count<5000,visited.insert(ObjectIdentifier(node)).inserted else {return}
            let destination=node.destination ?? (node.action as? PDFActionGoTo)?.destination
            if let page=destination?.page {
                let index=document.index(for:page)
                if index>=0,index<document.pageCount {
                    let title=node.label?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
                    let validPoint = destination.map { normalizedOutlinePoint($0.point, for: page) }
                    if !title.isEmpty {entries.append(PDFOutlineEntry(id:path,title:title,page:index,level:max(0,level-1),point:validPoint))}
                }
            }
            for childIndex in 0..<min(node.numberOfChildren,2000) {
                if let child=node.child(at:childIndex) {visit(child,path:path+"."+String(childIndex),level:level+1)}
            }
        }
        visit(root,path:"outline",level:0)
        return entries
    }
    static func normalizedOutlinePoint(_ point: CGPoint, for page: PDFPage) -> CGPoint {
        let crop = page.bounds(for: .cropBox)
        let x = !point.x.isFinite || point.x == kPDFDestinationUnspecifiedValue ? crop.minX : min(crop.maxX, max(crop.minX, point.x))
        let y = !point.y.isFinite || point.y == kPDFDestinationUnspecifiedValue ? crop.maxY : min(crop.maxY, max(crop.minY, point.y))
        return CGPoint(x: x, y: y)
    }
    private func updatePageNumber() {
        if let doc=view.document,let p=readingDestination()?.page {pageNumber=doc.index(for:p)+1}
    }
    private func scheduleSave() {
        guard !restoring, !layoutRestoring else { return }
        saveWork?.cancel()
        let work=DispatchWorkItem { [weak self] in self?.flush() };saveWork=work
        DispatchQueue.main.asyncAfter(deadline:.now()+0.4,execute:work)
    }
    @objc func flush() {
        guard !restoring,!layoutRestoring,let id=loadedID,let d=readingDestination(),let p=d.page,let doc=view.document,
              d.point.x.isFinite,d.point.y.isFinite else { return }
        store?.setPosition(id,ReadingPosition(page:doc.index(for:p),x:d.point.x,y:d.point.y,sourceSHA256:loadedFingerprint))
    }
    func refreshMarks() {
        guard let doc=view.document,let store,let id=loadedID else { return }
        let notes=store.annotationNotes(for:id)
        let concepts=store.guides[id]?.concepts ?? []
        let newSignature=(try? String(data:store.encoder.encode(notes),encoding:.utf8)) ?? ""
        let fullSignature=newSignature+((try? String(data:store.encoder.encode(concepts),encoding:.utf8)) ?? "")
        guard signature != fullSignature else { return };signature=fullSignature
        // Remove only annotations inserted by this controller. A source PDF can
        // already contain Fishbook annotations from an earlier exported copy.
        for annotation in renderedMarks { annotation.page?.removeAnnotation(annotation) }
        renderedMarks=[]
        view.setConceptMarkers(concepts)
        for n in notes {
            for pageIndex in Set(n.anchors.map(\.page)).sorted() {
                guard let page=doc.page(at:pageIndex) else { continue }
                for annotation in PDFAnnotationSupport.annotations(for: n, on: page, pageIndex: pageIndex) {
                    page.addAnnotation(annotation); renderedMarks.append(annotation)
                }
            }
        }
        view.needsDisplay=true
    }
    private func showBubble(_ id:String,rect:CGRect) {
        guard let store,let c=store.guide?.concepts.first(where:{$0.id == id}) else {return}
        bubble?.close()
        let pop=NSPopover();pop.behavior = .transient
        pop.contentViewController=NSHostingController(rootView:
            VStack(alignment:.leading,spacing:12) {
                Eyebrow(text:"原文旁的解释")
                Text(c.title).font(.system(size:15,weight:.semibold)).foregroundStyle(StudyTheme.text)
                Text(c.summary).font(.system(size:13)).foregroundStyle(StudyTheme.muted).lineSpacing(4).fixedSize(horizontal:false,vertical:true)
                Button("展开完整讲解") { store.showConcept(id);pop.close() }.buttonStyle(.borderedProminent)
            }.padding(20).frame(width:310).background(StudyTheme.paper).tint(StudyTheme.accent)
        )
        bubble=pop;pop.show(relativeTo:rect,of:view,preferredEdge:.maxX)
    }
    func go(_ anchor:Anchor,remember:Bool=true) {
        cancelLayoutRestoration()
        guard let doc=view.document,let page=doc.page(at:anchor.page) else {return}
        if remember { rememberCurrent() };searchOriginRecorded=false
        view.clearSelection()
        if let b=anchor.rects.first {
            view.go(to:b.cg.insetBy(dx:-10,dy:-35),on:page)
            if let selection=page.selection(for:b.cg) { view.setCurrentSelection(selection,animate:true) }
        } else { view.go(to:page) }
    }
    func goOutline(_ entry: PDFOutlineEntry) {
        cancelLayoutRestoration()
        guard let page = view.document?.page(at: entry.page) else { return }
        rememberCurrent(); searchOriginRecorded = false; view.clearSelection()
        if let point = entry.point {
            view.go(to: PDFDestination(page: page, at: Self.normalizedOutlinePoint(point, for: page)))
        } else { view.go(to: page) }
        updatePageNumber(); scheduleSave()
    }
    func goPage(_ number:Int) {
        cancelLayoutRestoration()
        guard let document=view.document,document.pageCount > 0 else {return}
        rememberCurrent();searchOriginRecorded=false
        view.clearSelection()
        if let p=document.page(at:min(document.pageCount-1,max(0,number-1))) { view.go(to:p) }
    }
    func returnToReading() {
        goBack()
    }
    func makeNote(kind:String) -> StudyNote? {
        guard let id=loadedID,let doc=view.document else {return nil}
        let selection=view.currentSelection.flatMap { candidate -> PDFSelection? in
            let belongsToDocument = candidate.pages.allSatisfy { doc.index(for:$0) < doc.pageCount }
            let visible = candidate.pages.contains { page in
                view.convert(candidate.bounds(for: page), from: page).intersects(view.bounds)
            }
            return belongsToDocument && visible ? candidate : nil
        }
        var anchors:[Anchor]=[]
        if let selection {
            for page in selection.pages {
                let boxes=selection.selectionsByLine().filter { $0.pages.contains(page) }.map { Box($0.bounds(for:page)) }.filter { $0.width>0 && $0.height>0 }
                anchors.append(Anchor(page:doc.index(for:page),rects:boxes,quote:selection.string ?? ""))
            }
        }
        if anchors.isEmpty { anchors=[Anchor(page:pageNumber-1,rects:[],quote:"")] }
        return StudyNote(paperID:id,sourceSHA256:loadedFingerprint,kind:kind,body:"",quote:selection?.string ?? "",anchors:anchors)
    }
    func find(_ query:String) {
        cancelLayoutRestoration()
        let term=query.trimmingCharacters(in:.whitespacesAndNewlines)
        activeSearchTerm = term
        view.clearSelection();view.highlightedSelections=nil;matches=[];matchCount=0;matchIndex=0
        guard !term.isEmpty else {searchResult="";searchOriginRecorded=false;return}
        matches=view.document?.findString(term,withOptions:.caseInsensitive) ?? []
        matchCount=matches.count
        showMatch()
    }
    func findOrAdvance(_ query: String) {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if term != activeSearchTerm { find(query) } else { nextMatch() }
    }
    func findIfChanged(_ query: String) {
        if query.trimmingCharacters(in: .whitespacesAndNewlines) != activeSearchTerm { find(query) }
    }
    func nextMatch() { cancelLayoutRestoration();guard !matches.isEmpty else {return};rememberCurrent();matchIndex=(matchIndex+1)%matches.count;showMatch() }
    func previousMatch() { cancelLayoutRestoration();guard !matches.isEmpty else {return};rememberCurrent();matchIndex=(matchIndex-1+matches.count)%matches.count;showMatch() }
    private func showMatch() {
        guard !matches.isEmpty else {searchResult="未找到";return}
        // A search field can change on every key. Remember the origin only once
        // per search session; explicit next/previous commands still have history.
        if !searchOriginRecorded {rememberCurrent();searchOriginRecorded=true}
        let m=matches[matchIndex];view.setCurrentSelection(m,animate:true);view.go(to:m)
        searchResult="\(matchIndex+1)/\(matches.count)"
    }
}

struct PDFReader: NSViewRepresentable {
    let paper:Paper
    @ObservedObject var store:StudyStore
    @ObservedObject var controller:PDFController
    func makeNSView(context:Context)->StudyPDFView { controller.view }
    func updateNSView(_ nsView:StudyPDFView,context:Context) {
        // Defer publication until SwiftUI's view update has finished.
        DispatchQueue.main.async { controller.load(paper,store:store) }
    }
}
