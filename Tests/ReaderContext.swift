import Foundation
import SwiftUI
import AppKit
import WebKit

/// Uses a temporary Markdown fixture in an offscreen test window. Does not open
/// Fishbook, read its defaults, or write the user's library.
@main struct ReaderContextChecks {
    @MainActor static func evaluate(_ view: WKWebView, _ code: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            view.evaluateJavaScript(code) { value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value) }
            }
        }
    }
    @MainActor static func wait(_ label: String, _ predicate: () async -> Bool) async throws {
        for _ in 0..<160 {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        fatalError("Timed out: " + label)
    }
    @MainActor static func webView(in view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        for child in view.subviews { if let web = webView(in: child) { return web } }
        return nil
    }
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fishbook-context-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("reader.md")
        let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6EYAAAAAASUVORK5CYII=")!
        try image.write(to: root.appendingPathComponent("figure.png"))
        let paragraphs = (0..<32).map { i in
            "Paragraph \(i): " + String(repeating: "This distinct section explains memory ordering and a reproducible systems experiment. ", count: 4)
        }
        let mathParagraph = #"公式摘录测试：缓存块 $B$，索引 $k_i$，比例 $\frac{x}{y}$。"#
        let mathQuote = #"公式摘录测试：缓存块 B，索引 k_i，比例 \frac{x}{y}。"#
        let source = "# 原文第 3 页\n\n" + mathParagraph + "\n\n" + paragraphs.joined(separator: "\n\n") + "\n\n![测试架构图](figure.png)"
        try source.write(to: file, atomically: true, encoding: .utf8)
        let controller = MarkdownReaderController()
        var locations: [DocumentReadingLocation] = []
        var focusCount = 0
        var receivedNoteSource: DocumentNoteSource?
        func reader(_ id: String, location: DocumentReadingLocation? = nil, font: Double = 15, notes: [DocumentNoteSource] = []) -> MarkdownDocumentView {
            MarkdownDocumentView(markdownURL: file, documentID: id, fontSize: font, dark: false,
                                 initialProgress: location?.progress ?? 0, onProgress: { _ in }, onPage: { _ in },
                                 documentTitle: "测试译文", initialLocation: location,
                                 onLocation: { locations.append($0) }, controller: controller, onFocus: { focusCount += 1 },
                                 noteSources: notes, onNoteSource: { receivedNoteSource = $0 })
        }
        let host = NSHostingView(rootView: reader("fixture-one"))
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 580, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 580, height: 700)
        host.layoutSubtreeIfNeeded()
        defer { window.close() }
        try await wait("web view exists") { webView(in: host) != nil }
        let web = webView(in: host)!
        try await wait("initial document ready") {
            ((try? await evaluate(web, "window.ZhiyeReader?.snapshot()?.documentID")) as? String) == "fixture-one"
        }
        print("reader loaded")
        // Command-line test bundles do not carry the application's vendor folder.
        // Load the exact shipped KaTeX into the fixture so extraction is tested
        // against real parallel MathML/annotation/HTML, not a plain-text fallback.
        let vendor = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("content/reader-vendor")
        if (try await evaluate(web, "Boolean(window.katex)")) as? Bool != true {
            _ = try await evaluate(web, try String(contentsOf: vendor.appendingPathComponent("katex.min.js"), encoding: .utf8) + "\n;true")
            let css = try String(contentsOf: vendor.appendingPathComponent("katex.min.css"), encoding: .utf8)
            _ = try await evaluate(web, "(()=>{const style=document.createElement('style');style.textContent=\(MarkdownRenderer.json(css));document.head.append(style);return true;})()")
        }
        let mathBlockID = try await evaluate(web, "document.querySelector('.math').closest('[data-block-id]').dataset.blockId") as! String
        _ = try await evaluate(web, "document.querySelectorAll('.math').forEach(el=>katex.render(el.dataset.readerFormula,el,{displayMode:el.classList.contains('display'),throwOnError:false,trust:false})); true")
        let rawFormulaText = try await evaluate(web, "document.querySelector('.math').textContent") as? String
        precondition(rawFormulaText == "BBB", "fixture must reproduce duplicated KaTeX text")
        let mathSource = DocumentNoteSource(documentID: "fixture-one", documentTitle: "测试译文", blockID: mathBlockID,
                                             quote: mathQuote, blockOffset: 0, progress: 0, pdfPage: 2)
        controller.go(to: mathSource)
        try await wait("formula paragraph ready") {
            ((try? await evaluate(web, "window.ZhiyeReader.snapshot()?.blockID")) as? String) == mathBlockID
        }
        let contextQuote = await withCheckedContinuation { continuation in controller.captureSelection { continuation.resume(returning: $0) } }
        precondition(contextQuote?.quote == mathQuote, "no-selection quote contains each original formula exactly once")
        let mathJSON = String(data: try JSONEncoder().encode([mathSource]), encoding: .utf8)!
        _ = try await evaluate(web, """
        (()=>{window.ZhiyeReader.setNoteSources(\(mathJSON));
        const block=document.querySelector('.math').closest('[data-block-id]');block.querySelector('.note-marker').textContent='2 条记录';
        const range=document.createRange();range.selectNodeContents(block);
        const selection=window.getSelection();selection.removeAllRanges();selection.addRange(range);document.dispatchEvent(new Event('selectionchange'));return true;})()
        """)
        let selectedMath = await withCheckedContinuation { continuation in controller.captureSelection { continuation.resume(returning: $0) } }
        precondition(selectedMath?.quote == mathQuote, "selected paragraph uses one formula and excludes record-marker text")
        _ = try await evaluate(web, """
        (()=>{const math=document.querySelectorAll('.math')[1],walker=document.createTreeWalker(math.querySelector('.katex-html'),NodeFilter.SHOW_TEXT);
        walker.nextNode();const range=document.createRange();range.selectNodeContents(walker.currentNode);
        const selection=window.getSelection();selection.removeAllRanges();selection.addRange(range);document.dispatchEvent(new Event('selectionchange'));return true;})()
        """)
        let partialMath = await withCheckedContinuation { continuation in controller.captureSelection { continuation.resume(returning: $0) } }
        precondition(partialMath?.quote == "k_i", "selection inside a KaTeX glyph retains one complete formula")
        let stableMathID = try await evaluate(web, "document.querySelector('.math').closest('[data-block-id]').dataset.blockId") as? String
        precondition(stableMathID == mathBlockID, "rendering and extraction never rewrite a stable block ID")
        print("KaTeX excerpt normalization verified")
        let targetID = try await evaluate(web, "Array.from(document.querySelectorAll('[data-block-id]')).find(e=>e.textContent.startsWith('Paragraph 14:')).dataset.blockId") as! String
        let target = DocumentNoteSource(documentID: "fixture-one", documentTitle: "测试译文", blockID: targetID,
                                        quote: paragraphs[14], blockOffset: 0.25, progress: 0.4, pdfPage: 2)
        controller.go(to: target)
        try await wait("source jump") {
            ((try? await evaluate(web, "window.ZhiyeReader.snapshot()?.blockID")) as? String) == targetID
        }
        _ = try await evaluate(web, """
        (()=>{const p=Array.from(document.querySelectorAll('[data-block-id]')).find(e=>e.dataset.blockId===\(MarkdownRenderer.json(targetID))).querySelector('p');
        const range=document.createRange();range.setStart(p.firstChild,160);range.setEnd(p.firstChild,192);
        const selection=window.getSelection();selection.removeAllRanges();selection.addRange(range);document.dispatchEvent(new Event('selectionchange'));return true;})()
        """)
        let captured = await withCheckedContinuation { continuation in controller.captureSelection { continuation.resume(returning: $0) } }
        precondition(captured?.documentID == "fixture-one" && captured?.blockID == targetID && captured?.pdfPage == 2)
        precondition(captured?.quote == String(paragraphs[14].dropFirst(160).prefix(32)).trimmingCharacters(in:.whitespacesAndNewlines), "Chinese selection preserves the actual excerpt")
        precondition(controller.canBack, "native history controls receive state")
        print("selection captured")
        host.rootView = reader("fixture-one", notes: [target, target])
        host.layoutSubtreeIfNeeded()
        try await wait("persistent paragraph marker") {
            ((try? await evaluate(web, "document.querySelector('.note-marker')?.getAttribute('aria-label')")) as? String) == "此段有 2 条记录"
        }
        _ = try await evaluate(web, "document.querySelector('.note-marker').click(); true")
        try await wait("marker routes to its own record source") { receivedNoteSource?.blockID == targetID }
        // Native toolbar focus must not swap in a PDF selection or lose a visible
        // selected excerpt. A collapsed in-document click intentionally clears it.
        _ = try await evaluate(web, "window.dispatchEvent(new Event('blur')); true")
        let blurred = await withCheckedContinuation { continuation in controller.captureSelection { continuation.resume(returning: $0) } }
        precondition(blurred?.quote == captured?.quote)
        let original = try await evaluate(web, "window.ZhiyeReader.snapshot()") as! [String: Any]
        let location = try JSONDecoder().decode(DocumentReadingLocation.self, from: JSONSerialization.data(withJSONObject: original))
        let capturedLocation: (String, DocumentReadingLocation?) = await withCheckedContinuation { continuation in
            controller.captureReadingLocation { id, value in continuation.resume(returning: (id, value)) }
        }
        precondition(capturedLocation.0 == "fixture-one" && capturedLocation.1?.blockID == targetID &&
                     abs((capturedLocation.1?.blockOffset ?? 99) - location.blockOffset) < 0.04,
                     "the pre-layout capture reads the live semantic viewport with the correct document identity")
        _ = try await evaluate(web, "window.ZhiyeReader.appearance(22,false); true")
        try await wait("font preserves paragraph") {
            guard let snapshot = try? await evaluate(web, "window.ZhiyeReader.snapshot()") as? [String: Any] else { return false }
            return snapshot["blockID"] as? String == targetID &&
                abs((snapshot["blockOffset"] as? Double ?? 99) - location.blockOffset) < 0.04
        }
        print("font preserves context")
        try ("# 新增说明\n\n" + String(repeating: "A newly added explanation before the article. ", count: 150) + "\n\n" + source)
            .write(to: file, atomically: true, encoding: .utf8)
        host.rootView = reader("fixture-one", location: location, font: 22)
        host.layoutSubtreeIfNeeded()
        try await wait("new revision restores semantic paragraph") {
            guard let snapshot = try? await evaluate(web, "window.ZhiyeReader.snapshot()") as? [String: Any] else { return false }
            let heading = try? await evaluate(web, "document.querySelector('h1').textContent")
            return snapshot["blockID"] as? String == targetID && heading as? String == "新增说明"
        }
        let blockExists = try await evaluate(web, "document.querySelector('[data-block-id=\"\(targetID)\"]')!==null")
        precondition(blockExists as? Bool == true)
        window.setContentSize(NSSize(width: 430, height: 700))
        host.frame = NSRect(x: 0, y: 0, width: 430, height: 700)
        host.layoutSubtreeIfNeeded()
        try await wait("native window width preserves semantic paragraph") {
            guard let snapshot = try? await evaluate(web, "window.ZhiyeReader.snapshot()") as? [String: Any] else { return false }
            let width = try? await evaluate(web, "innerWidth")
            return snapshot["blockID"] as? String == targetID && (width as? Double ?? 1000) < 500
        }
        controller.focusSearch()
        try await wait("native context search focuses Chinese field") {
            ((try? await evaluate(web, "document.activeElement?.id")) as? String) == "find"
        }
        precondition(focusCount > 0, "native controls focus the correct reading context")
        _ = try await evaluate(web, "document.getElementById('close-search').click(); true")
        let countBefore = locations.count
        _ = try await evaluate(web, "window.webkit.messageHandlers.readerProgress.postMessage({documentID:'wrong-paper',token:'stale',event:'location',progress:.9,blockID:'forged',quote:'wrong',blockOffset:0}); true")
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(!locations.dropFirst(countBefore).contains(where: { $0.blockID == "forged" }))
        print("identity and search verified")
        // Queued navigation must wait for its own document, never jump the one
        // whose WebKit load is still alive.
        var next = target; next.documentID = "fixture-two"
        controller.go(to: next)
        precondition(controller.documentID == "fixture-one")
        host.rootView = reader("fixture-two")
        host.layoutSubtreeIfNeeded()
        try await wait("queued different-document source") {
            guard let snapshot = try? await evaluate(web, "window.ZhiyeReader.snapshot()") as? [String: Any] else { return false }
            return snapshot["documentID"] as? String == "fixture-two" && snapshot["blockID"] as? String == targetID
        }
        var missing = next; missing.blockID = "removed-block"; missing.quote = "This paragraph was removed completely."; missing.progress = 0.7
        controller.go(to: missing)
        try await wait("missing source is disclosed") { controller.notice?.contains("无法精确定位") == true }
        let beforeImage = try await evaluate(web, "window.ZhiyeReader.snapshot()?.blockID") as? String
        _ = try await evaluate(web, "document.querySelector('article img').click(); true")
        try await wait("image modal opens") { ((try? await evaluate(web, "document.getElementById('image-viewer').open")) as? Bool) == true }
        let width = try await evaluate(web, "parseFloat(document.querySelector('.image-canvas img').style.width)") as! Double
        _ = try await evaluate(web, "document.getElementById('image-plus').click(); true")
        let zoomWidth = try await evaluate(web, "parseFloat(document.querySelector('.image-canvas img').style.width)") as! Double
        precondition(zoomWidth > width)
        _ = try await evaluate(web, "document.getElementById('image-close').click(); true")
        let modalOpen = try await evaluate(web, "document.getElementById('image-viewer').open")
        precondition(modalOpen as? Bool == false)
        let afterImage = try await evaluate(web, "window.ZhiyeReader.snapshot()?.blockID") as? String
        precondition(beforeImage == afterImage, "closing the image returns to the same paragraph")
        // SwiftUI actually dismantles the right pane when it is collapsed.
        // Capture the live location first, then recreate WebKit at a new width.
        let remountHost = NSHostingView(rootView: AnyView(reader("fixture-remount", font: 22)))
        window.contentView = remountHost
        remountHost.frame = NSRect(x: 0, y: 0, width: 430, height: 700)
        remountHost.layoutSubtreeIfNeeded()
        try await wait("remount fixture ready") {
            guard let visible = webView(in: remountHost) else { return false }
            return ((try? await evaluate(visible, "window.ZhiyeReader?.snapshot()?.documentID")) as? String) == "fixture-remount"
        }
        let beforeHide = webView(in: remountHost)!
        var hideSource = target; hideSource.documentID = "fixture-remount"
        controller.go(to: hideSource)
        try await wait("paragraph ready to collapse") {
            ((try? await evaluate(beforeHide, "window.ZhiyeReader.snapshot()?.blockID")) as? String) == targetID
        }
        let hiddenLocation: (String, DocumentReadingLocation?) = await withCheckedContinuation { continuation in
            controller.captureReadingLocation { id, value in continuation.resume(returning: (id, value)) }
        }
        precondition(hiddenLocation.0 == "fixture-remount" && hiddenLocation.1?.blockID == targetID)
        remountHost.rootView = AnyView(EmptyView())
        remountHost.layoutSubtreeIfNeeded()
        try await wait("companion really dismantled") { webView(in: remountHost) == nil && controller.documentID == nil }
        let detached: (String, DocumentReadingLocation?) = await withCheckedContinuation { continuation in
            controller.captureReadingLocation { id, value in continuation.resume(returning: (id, value)) }
        }
        precondition(detached.1 == nil, "a hidden reader cannot fabricate a live viewport")
        window.setContentSize(NSSize(width: 660, height: 700))
        remountHost.frame = NSRect(x: 0, y: 0, width: 660, height: 700)
        remountHost.rootView = AnyView(reader("fixture-remount", location: hiddenLocation.1, font: 22))
        remountHost.layoutSubtreeIfNeeded()
        try await wait("expanded companion restores the captured passage") {
            guard let rebuilt = webView(in: remountHost),
                  let snapshot = try? await evaluate(rebuilt, "window.ZhiyeReader?.snapshot()") as? [String: Any] else { return false }
            return rebuilt !== beforeHide && snapshot["documentID"] as? String == "fixture-remount" &&
                snapshot["blockID"] as? String == targetID &&
                abs((snapshot["blockOffset"] as? Double ?? 99) - hiddenLocation.1!.blockOffset) < 0.04
        }
        print("PASS: real KaTeX formula excerpts without MathML/HTML duplication; partial formula selection; stable IDs; toolbar blur; source identity; record markers; font/width/revision continuation; queued navigation; contextual search; image zoom/close; pre-layout capture and actual collapse/recreation restore the same paragraph.")
    }
}
