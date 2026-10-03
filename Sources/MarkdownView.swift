import SwiftUI
import AppKit
import WebKit
import CryptoKit

/// Owns commands, never document content. Commands waiting for a different paper
/// cannot accidentally act on the web view which is still being dismantled.
@MainActor final class MarkdownReaderController: ObservableObject {
    @Published private(set) var canBack = false
    @Published private(set) var canForward = false
    @Published private(set) var documentID: String?
    @Published var notice: String?
    private weak var view: WKWebView?
    private var attachedID = ""
    private var token = ""
    private var ready = false
    private var pendingSource: DocumentNoteSource?
    private var pendingSearch = false

    fileprivate func attach(_ view: WKWebView, documentID: String, token: String) {
        guard self.view !== view || attachedID != documentID || self.token != token else { return }
        self.view = view; attachedID = documentID; self.token = token; ready = false
        DispatchQueue.main.async { [weak self, weak view] in
            guard let self, self.view === view, self.token == token else { return }
            self.documentID = documentID; self.canBack = false; self.canForward = false
        }
    }

    fileprivate func detach(_ view: WKWebView) {
        guard self.view === view else { return }
        self.view = nil; ready = false
        DispatchQueue.main.async { [weak self] in
            guard let self, self.view == nil else { return }
            self.documentID = nil; self.canBack = false; self.canForward = false
        }
    }

    fileprivate func receive(_ body: [String: Any], from view: WKWebView?) {
        guard self.view === view, body["documentID"] as? String == attachedID,
              body["token"] as? String == token else { return }
        if let back = body["canBack"] as? Bool { canBack = back }
        if let forward = body["canForward"] as? Bool { canForward = forward }
        if let text = body["notice"] as? String, !text.isEmpty { notice = String(text.prefix(500)) }
        if body["event"] as? String == "ready" {
            ready = true
            if let source = pendingSource, source.documentID == attachedID {
                pendingSource = nil; sendLocation(source)
            }
            if pendingSearch { pendingSearch = false; focusSearch() }
        }
    }

    func captureSelection(_ completion: @escaping (DocumentNoteSource?) -> Void) {
        guard ready, let view else { completion(nil); return }
        let expectedID = attachedID, expectedToken = token
        view.evaluateJavaScript(guarded("window.ZhiyeReader.selectionSource()")) { [weak self, weak view] result, _ in
            guard let self, self.view === view, self.attachedID == expectedID, self.token == expectedToken,
                  let body = result as? [String: Any], body["documentID"] as? String == expectedID,
                  body["token"] as? String == expectedToken,
                  let data = try? JSONSerialization.data(withJSONObject: body),
                  let source = try? JSONDecoder().decode(DocumentNoteSource.self, from: data),
                  source.blockOffset.isFinite, source.progress.isFinite else { completion(nil); return }
            completion(source)
        }
    }

    /// Read the current viewport before SwiftUI removes the companion pane.
    /// Its normal scroll callback is debounced and may still describe an older paragraph.
    func captureReadingLocation(_ completion: @escaping (String, DocumentReadingLocation?) -> Void) {
        let expectedID = attachedID, expectedToken = token
        guard ready, let view else { completion(expectedID, nil); return }
        view.evaluateJavaScript(guarded("window.ZhiyeReader.snapshot()")) { [weak self, weak view] result, _ in
            guard let self, self.view === view, self.attachedID == expectedID, self.token == expectedToken,
                  let body = result as? [String: Any], body["documentID"] as? String == expectedID,
                  body["token"] as? String == expectedToken,
                  let data = try? JSONSerialization.data(withJSONObject: body),
                  var location = try? JSONDecoder().decode(DocumentReadingLocation.self, from: data),
                  !location.blockID.isEmpty, location.blockOffset.isFinite, location.progress.isFinite else {
                completion(expectedID, nil); return
            }
            location.blockOffset = min(1, max(0, location.blockOffset))
            location.progress = min(1, max(0, location.progress))
            location.quote = String(location.quote.prefix(2000))
            if let page = location.pdfPage, !(0..<100_000).contains(page) { location.pdfPage = nil }
            completion(expectedID, location)
        }
    }

    func go(to source: DocumentNoteSource) {
        notice = nil
        guard ready, attachedID == source.documentID else { pendingSource = source; return }
        pendingSource = nil; sendLocation(source)
    }
    private func sendLocation(_ source: DocumentNoteSource) {
        guard let encoded = try? JSONEncoder().encode(source), let json = String(data: encoded, encoding: .utf8) else { return }
        view?.evaluateJavaScript(guarded("window.ZhiyeReader.go(\(json))"))
    }
    func focusSearch() {
        guard ready else { pendingSearch = true; return }
        view?.window?.makeFirstResponder(view)
        view?.evaluateJavaScript(guarded("window.ZhiyeReader.focusSearch()"))
    }
    func goBack() { view?.evaluateJavaScript(guarded("window.ZhiyeReader.back()")) }
    func goForward() { view?.evaluateJavaScript(guarded("window.ZhiyeReader.forward()")) }

    private func guarded(_ expression: String) -> String {
        "window.ZhiyeReader?.matches(\(MarkdownRenderer.json(attachedID)),\(MarkdownRenderer.json(token))) ? (\(expression)) : null"
    }
}

/// A local document reader. Markdown is parsed into a small allowed HTML vocabulary;
/// source HTML never enters the web view as markup.
struct MarkdownDocumentView: NSViewRepresentable {
    let markdownURL: URL
    let documentID: String
    let fontSize: Double
    let dark: Bool
    let initialProgress: Double
    let onProgress: (Double) -> Void
    let onPage: (Int) -> Void
    var documentTitle: String = ""
    var initialLocation: DocumentReadingLocation? = nil
    var onLocation: (DocumentReadingLocation) -> Void = { _ in }
    var controller: MarkdownReaderController? = nil
    var onFocus: () -> Void = {}
    var markdownText: String? = nil
    var noteSources: [DocumentNoteSource] = []
    var onNoteSource: (DocumentNoteSource) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(context.coordinator.resources, forURLScheme: ReaderResources.scheme)
        config.userContentController.add(context.coordinator, name: "readerProgress")
        let view = ReaderWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        view.allowsBackForwardNavigationGestures = false
        view.setAccessibilityLabel("中文文档阅读区")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        let attrs = try? FileManager.default.attributesOfItem(atPath: markdownURL.path)
        let revision = "\(attrs?[.modificationDate] as? Date ?? .distantPast):\(attrs?[.size] ?? 0)"
        let textRevision = markdownText.map { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() } ?? ""
        let key = documentID + "|" + markdownURL.path + "|" + revision + "|" + textRevision
        let size = min(26, max(13, fontSize))
        coordinator.onNoteSource = onNoteSource
        coordinator.noteSources = noteSources.filter { $0.documentID == documentID }
        if coordinator.key != key {
            coordinator.flush(view)
            coordinator.key = key
            coordinator.documentID = documentID
            coordinator.onProgress = onProgress
            coordinator.onPage = onPage
            coordinator.onLocation = onLocation
            coordinator.onFocus = onFocus
            coordinator.controller = controller
            coordinator.lastSize = size
            coordinator.lastDark = dark
            coordinator.resources.token = UUID().uuidString
            coordinator.resources.documentRoot = markdownURL.deletingLastPathComponent().resolvingSymlinksInPath()
            let source: String
            do {
                let bytes = try markdownText.map { Data($0.utf8) } ?? Data(contentsOf: markdownURL)
                guard bytes.count <= 20 * 1024 * 1024,
                      let decoded = String(data: bytes, encoding: .utf8) else {
                    throw CocoaError(.fileReadInapplicableStringEncoding)
                }
                source = decoded
            } catch {
                source = "# 文档暂不可用\n\n无法读取这份本地文档。请检查文件，或重新导入材料。"
            }
            coordinator.resources.html = MarkdownRenderer.document(
                source, documentID: documentID, fontSize: size, dark: dark,
                progress: initialProgress, assetRoot: coordinator.resources.documentRoot,
                resourceToken: coordinator.resources.token, documentTitle: documentTitle,
                initialLocation: initialLocation
            )
            controller?.attach(view, documentID: documentID, token: coordinator.resources.token)
            var address = URLComponents(url: ReaderResources.documentURL, resolvingAgainstBaseURL: false)!
            address.queryItems = [URLQueryItem(name: "revision", value: coordinator.resources.token)]
            var request = URLRequest(url: address.url!)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            if let reader = view as? ReaderWebView { reader.loadWhenVisible(request) }
            else { view.load(request) }
        } else {
            coordinator.onProgress = onProgress
            coordinator.onPage = onPage
            coordinator.onLocation = onLocation
            coordinator.onFocus = onFocus
            coordinator.controller = controller
            controller?.attach(view, documentID: documentID, token: coordinator.resources.token)
            if coordinator.lastSize != size || coordinator.lastDark != dark {
                coordinator.lastSize = size
                coordinator.lastDark = dark
                view.evaluateJavaScript("window.ZhiyeReader?.appearance(\(size), \(dark ? "true" : "false"))")
            }
            coordinator.updateNoteMarkers(view)
        }
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.flush(view)
        coordinator.controller?.detach(view)
        (view as? ReaderWebView)?.cancelPendingLoad()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "readerProgress")
        view.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let resources = ReaderResources()
        var key = ""
        var documentID = ""
        var lastSize: Double = 15
        var lastDark = false
        var onProgress: (Double) -> Void = { _ in }
        var onPage: (Int) -> Void = { _ in }
        var onLocation: (DocumentReadingLocation) -> Void = { _ in }
        var onFocus: () -> Void = {}
        var onNoteSource: (DocumentNoteSource) -> Void = { _ in }
        var noteSources: [DocumentNoteSource] = []
        var renderedNotes = ""
        weak var controller: MarkdownReaderController?

        func flush(_ view: WKWebView) {
            guard !key.isEmpty else { return }
            let save = onProgress
            let saveLocation = onLocation
            let expectedID = documentID
            let expectedToken = resources.token
            view.evaluateJavaScript("window.ZhiyeReader?.snapshot() ?? null") { result, _ in
                if let snapshot = result as? [String: Any], snapshot["documentID"] as? String == expectedID,
                   snapshot["token"] as? String == expectedToken,
                   let value = snapshot["progress"] as? Double, value.isFinite {
                    save(min(1, max(0, value)))
                    if let location = Self.location(snapshot) { saveLocation(location) }
                }
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame,
                  message.frameInfo.request.url?.scheme == ReaderResources.scheme,
                  message.frameInfo.request.url?.host == "local",
                  let body = message.body as? [String: Any],
                  body["documentID"] as? String == documentID,
                  body["token"] as? String == resources.token else { return }
            controller?.receive(body, from: message.webView)
            if body["event"] as? String == "focus" { onFocus() }
            if body["event"] as? String == "noteSource", let sourceBody = body["source"] as? [String: Any],
               sourceBody["documentID"] as? String == documentID,
               let bytes = try? JSONSerialization.data(withJSONObject: sourceBody),
               let source = try? JSONDecoder().decode(DocumentNoteSource.self, from: bytes) { onNoteSource(source) }
            if body["event"] as? String == "page", let page = body["page"] as? Int, page > 0, page <= 100_000 { onPage(page) }
            if let value = body["progress"] as? Double, value.isFinite {
                onProgress(min(1, max(0, value)))
                if let location = Self.location(body) { onLocation(location) }
            }
        }

        private static func location(_ body: [String: Any]) -> DocumentReadingLocation? {
            guard let data = try? JSONSerialization.data(withJSONObject: body),
                  var location = try? JSONDecoder().decode(DocumentReadingLocation.self, from: data),
                  !location.blockID.isEmpty, location.blockOffset.isFinite, location.progress.isFinite else { return nil }
            location.blockOffset = min(1, max(0, location.blockOffset))
            location.progress = min(1, max(0, location.progress))
            if let page = location.pdfPage, !(0..<100_000).contains(page) { location.pdfPage = nil }
            location.quote = String(location.quote.prefix(2000))
            return location
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("window.ZhiyeReader?.appearance(\(lastSize), \(lastDark ? "true" : "false")); window.ZhiyeReader?.layoutChanged()")
            renderedNotes = ""
            updateNoteMarkers(webView)
        }

        func updateNoteMarkers(_ webView: WKWebView) {
            guard let bytes = try? JSONEncoder().encode(noteSources),
                  let notes = String(data: bytes, encoding: .utf8), renderedNotes != notes else { return }
            renderedNotes = notes
            webView.evaluateJavaScript("if(window.ZhiyeReader?.matches(\(MarkdownRenderer.json(documentID)),\(MarkdownRenderer.json(resources.token)))) window.ZhiyeReader.setNoteSources(\(notes))")
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            if url.scheme == ReaderResources.scheme,
               url.host == "local", url.path == "/document.html" {
                decisionHandler(.allow)
                return
            }
            // Source-page jumps and external links require a user click. Imported
            // Markdown cannot invoke arbitrary application schemes or file URLs.
            if action.navigationType == .linkActivated {
                if url.scheme == "zhiye", url.host == "page",
                   let page = Int(url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
                   page > 0, page <= 100_000 {
                    onPage(page)
                } else if ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
                    NSWorkspace.shared.open(url)
                }
            }
            decisionHandler(.cancel)
        }
    }
}

/// SwiftUI can configure a representable before it has a window or a usable frame.
/// Loading after attachment avoids WebKit restoring against a zero-sized viewport.
final class ReaderWebView: WKWebView {
    private var pendingRequest: URLRequest?
    private var notifiedSize = CGSize.zero

    func loadWhenVisible(_ request: URLRequest) {
        pendingRequest = request
        loadIfReady()
    }

    func cancelPendingLoad() { pendingRequest = nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        loadIfReady()
    }

    override func layout() {
        super.layout()
        loadIfReady()
    }

    private func loadIfReady() {
        guard window != nil, bounds.width >= 40, bounds.height >= 40 else { return }
        if let request = pendingRequest {
            pendingRequest = nil
            notifiedSize = bounds.size
            load(request)
        } else if notifiedSize != bounds.size {
            notifiedSize = bounds.size
            evaluateJavaScript("window.ZhiyeReader?.layoutChanged()")
        }
    }
}

/// Only serves generated HTML, known vendor resources, and raster images below the
/// current document directory. Resolving symlinks prevents a relative asset escaping.
final class ReaderResources: NSObject, WKURLSchemeHandler {
    static let scheme = "zhiye-reader"
    static let documentURL = URL(string: "zhiye-reader://local/document.html")!
    var documentRoot = URL(fileURLWithPath: "/")
    var html = ""
    var token = UUID().uuidString
    var vendorRoot: URL {
        (Bundle.main.resourceURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .appendingPathComponent("content/reader-vendor").resolvingSymlinksInPath()
    }

    static func safeFile(_ path: String, under root: URL) -> URL? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
              !path.split(separator: "/").contains("..") else { return nil }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let url = base.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(base.path + "/") else { return nil }
        return url
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, url.scheme == Self.scheme, url.host == "local" else {
            task.didFailWithError(URLError(.unsupportedURL)); return
        }
        let bytes: Data
        let mime: String
        if url.path == "/document.html" {
            bytes = Data(html.utf8)
            mime = "text/html"
        } else {
            let isVendor = url.path.hasPrefix("/vendor/")
            let prefix = isVendor ? "/vendor/" : "/asset/\(token)/"
            guard url.path.hasPrefix(prefix) else { task.didFailWithError(URLError(.noPermissionsToReadFile)); return }
            let relative = String(url.path.dropFirst(prefix.count))
            guard let file = Self.safeFile(relative, under: isVendor ? vendorRoot : documentRoot) else {
                task.didFailWithError(URLError(.noPermissionsToReadFile)); return
            }
            let allowed: [String: String] = isVendor
                ? ["js":"text/javascript", "css":"text/css", "woff2":"font/woff2", "woff":"font/woff", "ttf":"font/ttf"]
                : ["png":"image/png", "jpg":"image/jpeg", "jpeg":"image/jpeg", "gif":"image/gif", "webp":"image/webp"]
            guard let type = allowed[file.pathExtension.lowercased()],
                  let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= 32 * 1024 * 1024,
                  let data = try? Data(contentsOf: file) else {
                task.didFailWithError(URLError(.fileDoesNotExist)); return
            }
            bytes = data
            mime = type
        }
        let response = URLResponse(url: url, mimeType: mime, expectedContentLength: bytes.count, textEncodingName: mime.hasPrefix("text/") ? "utf-8" : nil)
        task.didReceive(response)
        task.didReceive(bytes)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

enum MarkdownRenderer {
    struct Heading { let id: String; let title: String; let level: Int }
    struct Parsed { let html: String; let headings: [Heading] }

    // Kept separate from DOM wiring so lifecycle ordering is deterministically tested.
    static let restorationScript = #"""
    function normalizeReaderQuote(text) { return String(text || '').replace(/\s+/g, ' ').trim(); }
    function resolveReaderLocation(location, blocks, extent, inset = 0) {
      const bounded = n => Math.min(1, Math.max(0, Number.isFinite(n) ? n : 0));
      const quote = normalizeReaderQuote(location?.quote), offset = bounded(location?.blockOffset);
      let block = blocks.find(b => b.id === location?.blockID), matchedBy = block ? 'block' : '';
      if (!block && quote.length >= 8) {
        const matches = blocks.filter(b => normalizeReaderQuote(b.text).includes(quote));
        // Repeated source labels or quotations cannot identify an exact paragraph.
        if (matches.length === 1) { block = matches[0]; matchedBy = 'quote'; }
      }
      const target = block ? block.top + offset * block.height - inset : bounded(location?.progress) * extent;
      return {target: Math.min(Math.max(0, extent), Math.max(0, target)), exact: Boolean(block),
        matchedBy: matchedBy || 'progress', blockID: block?.id || ''};
    }
    function makeReaderHistory(limit = 80) {
      let previous = [], following = [];
      const same = (a,b) => Boolean(a && b && a.blockID === b.blockID &&
        Math.abs((a.blockOffset || 0) - (b.blockOffset || 0)) < .002 &&
        Math.abs((a.progress || 0) - (b.progress || 0)) < .0001);
      const append = (stack, value) => { if (value && !same(stack[stack.length - 1], value)) {
        stack.push({...value}); if (stack.length > limit) stack.shift();
      }};
      return {
        remember(value) { append(previous,value); following=[]; },
        back(current) { if (!previous.length) return null; append(following,current); return previous.pop(); },
        forward(current) { if (!following.length) return null; append(previous,current); return following.pop(); },
        state() { return {canBack:previous.length>0,canForward:following.length>0}; }
      };
    }
    function makeReaderRestoreController(initial, location = null) {
      const desired = Number.isFinite(initial) ? Math.min(1, Math.max(0, initial)) : 0;
      let phase = 'waiting', geometry = '', stableSince = null;
      return {
        cancel() { phase = 'user'; stableSince = null; },
        recheck() { if (phase !== 'user') { phase = 'waiting'; stableSince = null; } },
        userControlled() { return phase === 'user'; },
        sample({width, height, extent, y, contentReady, now, blocks = [], inset = 0}) {
          if (phase === 'user') return {ready: contentReady, pending: false, target: null};
          if (!contentReady || width < 40 || height < 40) {
            phase = 'waiting'; stableSince = null;
            return {ready: false, pending: true, target: null};
          }
          const target = location ? resolveReaderLocation(location, blocks, extent, inset).target : desired * Math.max(0, extent);
          const shape = [Math.round(width), Math.round(height), Math.round(extent), Math.round(target)].join(':');
          if (shape !== geometry) { geometry = shape; stableSince = null; phase = 'waiting'; }
          if (Math.abs(y - target) > 2) {
            phase = 'waiting'; stableSince = null;
            return {ready: false, pending: true, target};
          }
          if (stableSince === null) stableSince = now;
          if (now - stableSince < 560) return {ready: false, pending: true, target: null};
          phase = 'ready';
          return {ready: true, pending: false, target: null};
        }
      };
    }
    """#

    static func json(_ value: Any) -> String {
        String(data: (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])) ?? Data("null".utf8), encoding: .utf8)!
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    static func matches(_ pattern: String, _ text: String) -> [NSTextCheckingResult] {
        (try? NSRegularExpression(pattern: pattern).matches(in: text, range: NSRange(text.startIndex..., in: text))) ?? []
    }

    static func group(_ match: NSTextCheckingResult, _ index: Int, in text: String) -> String {
        guard let range = Range(match.range(at: index), in: text) else { return "" }
        return String(text[range])
    }

    static func safeHref(_ raw: String) -> String? {
        let raw = raw.hasPrefix("<") && raw.hasSuffix(">") ? String(raw.dropFirst().dropLast()) : raw
        if raw.hasPrefix("#") { return raw }
        guard let url = URL(string: raw) else { return nil }
        if ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil { return raw }
        if url.scheme == "zhiye", url.host == "page",
           let n = Int(url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))), n > 0, n <= 100_000 { return raw }
        return nil
    }

    static func imageURL(_ raw: String, assetRoot: URL) -> String? {
        let raw = raw.hasPrefix("<") && raw.hasSuffix(">") ? String(raw.dropFirst().dropLast()) : raw
        guard let decoded = raw.removingPercentEncoding,
              URL(string: raw)?.scheme == nil,
              !raw.hasPrefix("//"),
              let local = ReaderResources.safeFile(decoded, under: assetRoot),
              ["png", "jpg", "jpeg", "gif", "webp"].contains(local.pathExtension.lowercased()) else { return nil }
        var components = URLComponents()
        components.scheme = ReaderResources.scheme
        components.host = "local"
        components.path = "/asset/" + decoded
        return components.url?.absoluteString
    }

    static func inline(_ text: String, assetRoot: URL, depth: Int = 0) -> String {
        guard depth < 6 else { return escape(text) }
        let pattern = #"`([^`\n]+)`|!\[([^\]\n]*)\]\((<[^>\n]+>|[^\s\)]+)(?:\s+"[^"]*")?\)|\[([^\]\n]*)\]\((<[^>\n]+>|[^\s\)]+)(?:\s+"[^"]*")?\)|\$([^$\n]+)\$|\\\((.+?)\\\)|\*\*(.+?)\*\*|__(.+?)__|(?<!\*)\*([^*\n]+)\*(?!\*)"#
        var result = ""
        var position = text.startIndex
        for match in matches(pattern, text) {
            guard let range = Range(match.range, in: text) else { continue }
            result += escape(String(text[position..<range.lowerBound]))
            if match.range(at: 1).location != NSNotFound {
                result += "<code>\(escape(group(match, 1, in: text)))</code>"
            } else if match.range(at: 2).location != NSNotFound {
                let alt = group(match, 2, in: text)
                if let url = imageURL(group(match, 3, in: text), assetRoot: assetRoot) {
                    result += "<img src=\"\(escape(url))\" alt=\"\(escape(alt))\" decoding=\"async\">"
                } else {
                    result += "<span class=\"image-unavailable\">图片未载入\(alt.isEmpty ? "" : "：" + escape(alt))</span>"
                }
            } else if match.range(at: 4).location != NSNotFound {
                let label = inline(group(match, 4, in: text), assetRoot: assetRoot, depth: depth + 1)
                if let href = safeHref(group(match, 5, in: text)) {
                    result += "<a href=\"\(escape(href))\">\(label)</a>"
                } else { result += label }
            } else if match.range(at: 6).location != NSNotFound || match.range(at: 7).location != NSNotFound {
                let formula = group(match, match.range(at: 6).location != NSNotFound ? 6 : 7, in: text)
                result += "<span class=\"math\">\(escape(formula))</span>"
            } else {
                let index = match.range(at: 8).location != NSNotFound ? 8 : (match.range(at: 9).location != NSNotFound ? 9 : 10)
                let tag = index == 10 ? "em" : "strong"
                result += "<\(tag)>\(inline(group(match, index, in: text), assetRoot: assetRoot, depth: depth + 1))</\(tag)>"
            }
            position = range.upperBound
        }
        result += escape(String(text[position...]))
        return result
    }

    static func slug(_ title: String) -> String {
        var value = ""
        for scalar in title.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" { value.unicodeScalars.append(scalar) }
            else if CharacterSet.whitespaces.contains(scalar) { value += "-" }
        }
        return value.isEmpty ? "section" : value
    }

    static func parse(_ markdown: String, assetRoot: URL) -> Parsed {
        // Remove standalone source metadata without touching fenced code examples.
        let clean = withoutSourceMetadata(markdown)
        let lines = clean.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var result: [String] = []
        var paragraph: [String] = []
        var headings: [Heading] = []
        var ids: [String: Int] = [:]
        var index = 0
        func flush() {
            if !paragraph.isEmpty {
                let text = paragraph.joined(separator: "\n")
                let sourceOnly = !matches(#"^原文[：:]\s*(?:\[PDF\s*第\s*\d+\s*页\]\(zhiye://page/\d+\)(?:\s*[·、,，]\s*)?)+$"#, text).isEmpty
                let fragment = "<p\(sourceOnly ? " class=\"source-note\"" : "")>\(inline(text, assetRoot: assetRoot))</p>"
                // Consecutive identical source labels add no provenance. Keep the
                // link once, without changing the document or removing body text.
                if !sourceOnly || result.last != fragment { result.append(fragment) }
                paragraph.removeAll()
            }
        }
        func cells(_ line: String) -> [String] {
            var parts = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.first == "" { parts.removeFirst() }
            if parts.last == "" { parts.removeLast() }
            return parts
        }
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { flush(); index += 1; continue }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                let fence = String(trimmed.prefix(3))
                var code: [String] = []
                index += 1
                while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[index]); index += 1
                }
                result.append("<pre><code>\(escape(code.joined(separator: "\n")))</code></pre>")
                if index < lines.count { index += 1 }
                continue
            }
            if trimmed.hasPrefix("$$") || trimmed == "\\[" {
                flush()
                let delimiter = trimmed.hasPrefix("$$") ? "$$" : "\\]"
                var formula = trimmed == "\\[" ? "" : String(trimmed.dropFirst(2))
                if delimiter == "$$" && formula.hasSuffix("$$") && formula.count >= 2 {
                    formula = String(formula.dropLast(2)); index += 1
                } else {
                    index += 1
                    while index < lines.count {
                        let next = lines[index].trimmingCharacters(in: .whitespaces)
                        if next.hasSuffix(delimiter) {
                            formula += "\n" + String(next.dropLast(delimiter.count)); index += 1; break
                        }
                        formula += "\n" + lines[index]; index += 1
                    }
                }
                result.append("<div class=\"math display\">\(escape(formula))</div>")
                continue
            }
            if let match = matches(#"^(#{1,6})\s+(.+?)\s*#*\s*$"#, trimmed).first {
                flush()
                let level = group(match, 1, in: trimmed).count
                let title = group(match, 2, in: trimmed)
                let base = slug(title)
                let count = ids[base, default: 0]
                ids[base] = count + 1
                let id = count == 0 ? base : base + "-\(count)"
                headings.append(Heading(id: id, title: title, level: level))
                result.append("<h\(level) id=\"\(escape(id))\">\(inline(title, assetRoot: assetRoot))</h\(level)>")
                if let page = matches(#"^(?:原文|PDF)\s*第\s*(\d+)\s*页"#, title).first,
                   let n = Int(group(page, 1, in: title)), n > 0 {
                    var next = index + 1
                    while next < lines.count && lines[next].trimmingCharacters(in: .whitespaces).isEmpty { next += 1 }
                    let alreadyLinked = next < lines.count && lines[next].trimmingCharacters(in: .whitespaces) == "[查看此页原文](zhiye://page/\(n))"
                    result.append("<a class=\"page-source\" href=\"zhiye://page/\(n)\">查看原文 · 第 \(n) 页 ↗</a>")
                    if alreadyLinked { index = next + 1; continue }
                }
                index += 1; continue
            }
            if index + 1 < lines.count, trimmed.contains("|"), !cells(lines[index + 1]).isEmpty,
               cells(lines[index + 1]).allSatisfy({ !matches(#"^:?-{3,}:?$"#, $0).isEmpty }) {
                flush()
                let header = cells(line).map { "<th>\(inline($0, assetRoot: assetRoot))</th>" }.joined()
                index += 2
                var rows: [String] = []
                while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append("<tr>" + cells(lines[index]).map { "<td>\(inline($0, assetRoot: assetRoot))</td>" }.joined() + "</tr>")
                    index += 1
                }
                result.append("<div class=\"table-wrap\"><table><thead><tr>\(header)</tr></thead><tbody>\(rows.joined())</tbody></table></div>")
                continue
            }
            if trimmed.hasPrefix(">") {
                flush()
                var quote: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quote.append(String(lines[index].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                result.append("<blockquote>\(inline(quote.joined(separator: "\n"), assetRoot: assetRoot))</blockquote>")
                continue
            }
            let listPattern = #"^\s*(?:([-+*])|(\d+)[.)])\s+(.+)$"#
            if let first = matches(listPattern, line).first {
                flush()
                let ordered = first.range(at: 2).location != NSNotFound
                let tag = ordered ? "ol" : "ul"
                let start = ordered ? " start=\"\(Int(group(first, 2, in: line)) ?? 1)\"" : ""
                var items: [String] = []
                while index < lines.count, let item = matches(listPattern, lines[index]).first,
                      (item.range(at: 2).location != NSNotFound) == ordered {
                    items.append("<li>\(inline(group(item, 3, in: lines[index]), assetRoot: assetRoot))</li>")
                    index += 1
                }
                result.append("<\(tag)\(start)>\(items.joined())</\(tag)>")
                continue
            }
            if !matches(#"^(?:---+|\*\*\*+|___+)\s*$"#, trimmed).isEmpty {
                flush(); result.append("<hr>"); index += 1; continue
            }
            paragraph.append(line)
            index += 1
        }
        flush()
        // IDs depend on normalized block content, not the number of paragraphs
        // preceding it. Revisions inserting new paragraphs therefore retain notes
        // and continuation points. Only identical blocks need an occurrence suffix.
        var occurrences: [String: Int] = [:]
        var pageContext: Int?
        let anchored = result.map { fragment -> String in
            if (fragment.hasPrefix("<h") || fragment.hasPrefix("<p class=\"source-note\"")),
               let page = matches(#"(?:原文|PDF)\s*第\s*(\d+)\s*页|zhiye://page/(\d+)"#, fragment).first {
                let value = group(page, 1, in: fragment).isEmpty ? group(page, 2, in: fragment) : group(page, 1, in: fragment)
                if let number = Int(value), number > 0, number <= 100_000 { pageContext = number - 1 }
            }
            let normalized = fragment.replacingOccurrences(of: #"\s+id=\"[^\"]*\""#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let hash = SHA256.hash(data: Data(normalized.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
            let occurrence = occurrences[hash, default: 0]; occurrences[hash] = occurrence + 1
            let id = "b-\(hash)-\(occurrence)"
            let page = pageContext.map { " data-pdf-page=\"\($0)\"" } ?? ""
            return "<section class=\"reader-block\" data-block-id=\"\(id)\"\(page)>\(fragment)</section>"
        }
        return Parsed(html: anchored.joined(separator: "\n"), headings: headings)
    }

    static func withoutSourceMetadata(_ markdown: String) -> String {
        var result: [String] = []
        var fence: String?
        var comment = false
        for sourceLine in markdown.components(separatedBy: "\n") {
            var line = sourceLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marker = fence {
                result.append(line)
                if trimmed.hasPrefix(marker) { fence = nil }
                continue
            }
            if comment {
                guard let end = line.range(of: "-->") else { continue }
                line = String(line[end.upperBound...])
                comment = false
            }
            while line.trimmingCharacters(in: .whitespaces).hasPrefix("<!--") {
                if let end = line.range(of: "-->") { line = String(line[end.upperBound...]) }
                else { comment = true; break }
            }
            if comment { continue }
            if !matches(#"(?i)^\s*<a\s+(?:id|name)\s*=\s*["'][^"']*["']\s*>\s*</a>\s*$"#, line).isEmpty { continue }
            let clean = line.trimmingCharacters(in: .whitespaces)
            if clean.hasPrefix("```") || clean.hasPrefix("~~~") { fence = String(clean.prefix(3)) }
            result.append(line)
        }
        return result.joined(separator: "\n")
    }

    static func document(_ markdown: String, documentID: String, fontSize: Double, dark: Bool, progress: Double, assetRoot: URL, resourceToken: String = UUID().uuidString, documentTitle: String = "", initialLocation: DocumentReadingLocation? = nil) -> String {
        let parsed = parse(markdown, assetRoot: assetRoot)
        let body = parsed.html.replacingOccurrences(of: "zhiye-reader://local/asset/", with: "zhiye-reader://local/asset/" + resourceToken + "/")
        let nonce = UUID().uuidString
        let idJSON = json(documentID)
        let locationJSON = initialLocation.flatMap { try? JSONEncoder().encode($0) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) }.map(json) ?? "null"
        let restored = progress.isFinite ? min(1, max(0, progress)) : 0
        let directory = parsed.headings.filter { $0.level <= 3 }.map {
            "<option value=\"\(escape($0.id))\">\(String(repeating: "　", count: max(0, $0.level - 1)))\(escape($0.title))</option>"
        }.joined()
        return #"""
        <!doctype html><html lang="zh-Hans" data-dark="\#(dark ? "true" : "false")"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'nonce-\#(nonce)' zhiye-reader:; style-src 'unsafe-inline' zhiye-reader:; img-src zhiye-reader:; font-src zhiye-reader:; connect-src 'none'; object-src 'none'; frame-src 'none'; base-uri 'none'; form-action 'none'">
        <link rel="stylesheet" href="zhiye-reader://local/vendor/katex.min.css">
        <style>
        :root{color-scheme:light;--paper:#FFFFFF;--chrome:rgba(255,255,255,.9);--text:#22343E;--muted:#60717B;--accent:#146E85;--line:#DFE6E9;--soft:#E6F2F5;--code:#F1F5F6;font-size:\#(fontSize)px}
        :root[data-dark=true]{color-scheme:dark;--paper:#1D2429;--chrome:rgba(29,36,41,.92);--text:#E9EFF2;--muted:#A6B8C2;--accent:#7CCADC;--line:#38474F;--soft:#253F49;--code:#29333A}
        *{box-sizing:border-box}html{scroll-padding-top:88px}body{margin:0;background:var(--paper);color:var(--text);font-family:-apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif;line-height:1.88;overflow-wrap:anywhere}
        .reader-tools{position:sticky;top:0;z-index:2;padding:5px 18px;background:var(--chrome);-webkit-backdrop-filter:blur(16px);backdrop-filter:blur(16px);border-bottom:.5px solid var(--line);font-size:11px}.reader-main,.search-panel{display:flex;gap:6px;align-items:center}.search-panel{padding:7px 0 3px}[hidden]{display:none!important}.reader-main select{border-color:transparent;background:transparent;color:var(--muted)}.reader-main button{border-color:transparent;background:transparent;color:var(--muted);padding-inline:12px}
        select,input,button{font:inherit;color:var(--text);background:var(--paper);border:.5px solid var(--line);border-radius:16px;padding:5px 9px;min-height:28px}
        select{min-width:0;width:0;flex:1 1 auto}input{width:80px;min-width:60px;flex:1 1 auto}button{cursor:pointer;flex-shrink:0}button:disabled{opacity:.4;cursor:default}.search-panel button{border-color:transparent}#search-status{flex-shrink:0}button:hover{background:var(--soft)}:focus-visible{outline:2px solid var(--accent);outline-offset:2px}#search-status{color:var(--muted);font-size:11px;min-width:25px}
        article{padding:18px 28px 56px;max-width:900px;margin:auto}h1,h2,h3,h4,h5,h6{line-height:1.5;letter-spacing:.01em;margin:1.65em 0 .65em;scroll-margin-top:88px}h1{font-size:1.65rem;margin-top:.5em}h2{font-size:1.3rem;border-top:1px solid var(--line);padding-top:1.3em}h3{font-size:1.12rem}p{margin:.95em 0}a{color:var(--accent);text-underline-offset:3px}li+li{margin-top:.42em}ul,ol{padding-left:1.6em}blockquote{margin:1.2em 0;padding:.5em 1em;border-left:3px solid var(--accent);color:var(--muted);background:var(--soft);border-radius:0 6px 6px 0}
        .reader-block{position:relative}.reader-block.reader-source-target{background:var(--soft);border-radius:8px;outline:2px solid var(--accent);outline-offset:5px}article img[role=button]{cursor:zoom-in}.note-marker{position:absolute;left:-25px;top:4px;width:24px;min-height:24px;padding:0;border:0;background:transparent;color:var(--accent)}.note-marker::before{content:'●';font-size:8px}.note-marker:hover{background:var(--soft)}
        code,pre{font-family:"SFMono-Regular",Menlo,monospace;font-size:.9em}code{background:var(--code);border-radius:4px;padding:.12em .3em}pre{background:var(--code);padding:14px;border-radius:8px;overflow:auto;line-height:1.65}pre code{padding:0;background:none;white-space:pre;overflow-wrap:normal}
        img{display:block;max-width:100%;height:auto;margin:18px auto;background:white;border-radius:4px}.image-unavailable{display:block;padding:16px;border:1px dashed var(--line);color:var(--muted)}.table-wrap{overflow-x:auto;margin:18px 0}table{border-collapse:collapse;min-width:100%;font-size:.88rem}th,td{padding:8px 11px;border:1px solid var(--line);text-align:left;vertical-align:top;min-width:80px}th{background:var(--soft)}hr{border:0;border-top:1px solid var(--line);margin:24px 0}.page-source{display:inline-block;font-size:.8rem;text-decoration:none;padding:3px 11px;border-radius:16px;background:var(--soft);margin-bottom:6px}
        .source-note{font-size:.75rem;line-height:1.5;color:var(--muted);margin:.7em 0 .3em}.source-note a{text-decoration:none}.source-note a:hover{text-decoration:underline}.math.display{overflow-x:auto;margin:1em 0;white-space:pre-wrap}.katex-display{overflow-x:auto;overflow-y:hidden;padding:4px 0}.katex{font-size:1.1em}.math-fallback{font-family:Menlo,monospace;color:var(--muted);font-size:.9em}mark{background:#EBD985;color:#252D28;border-radius:2px}mark.current-match{outline:2px solid var(--accent);outline-offset:1px}footer{padding-top:24px;color:var(--muted);font-size:11px}
        @media(max-width:390px){article{padding:15px 18px 40px}.reader-tools{padding:8px 12px}}
        @media(prefers-reduced-transparency:reduce){.reader-tools{background:var(--paper);-webkit-backdrop-filter:none;backdrop-filter:none}}
        #image-viewer{width:calc(100vw - 24px);max-width:1200px;height:calc(100vh - 24px);max-height:100vh;padding:0;border:.5px solid var(--line);border-radius:16px;background:var(--paper);color:var(--text);box-shadow:0 15px 60px #0004}#image-viewer::backdrop{background:#14202bb3;-webkit-backdrop-filter:blur(7px);backdrop-filter:blur(7px)}.image-controls{height:52px;padding:8px 12px;display:flex;align-items:center;gap:7px;border-bottom:.5px solid var(--line);font-size:12px}.image-controls strong{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.image-controls button{min-width:30px}.image-stage{height:calc(100% - 52px);overflow:auto;overscroll-behavior:contain;cursor:grab;touch-action:none}.image-stage.dragging{cursor:grabbing}.image-canvas{min-width:100%;min-height:100%;display:grid;place-items:center}.image-canvas img{display:block;max-width:none;max-height:none;margin:20px;border-radius:2px;user-select:none;-webkit-user-drag:none}
        </style><script nonce="\#(nonce)" src="zhiye-reader://local/vendor/katex.min.js" defer></script></head><body>
        <nav class="reader-tools" aria-label="文档工具"><div class="reader-main"><select id="contents" aria-label="章节目录"><option value="">章节目录</option>\#(directory)</select><button id="toggle-search" aria-expanded="false" aria-controls="search-panel" aria-label="查找中文文档">查找</button></div><div class="search-panel" id="search-panel" hidden><input id="find" type="search" placeholder="搜索此文档" aria-label="搜索此文档"><span id="search-status" aria-live="polite"></span><button id="previous" title="上一个结果" aria-label="上一个搜索结果" disabled>↑</button><button id="next" title="下一个结果" aria-label="下一个搜索结果" disabled>↓</button><button id="close-search" title="关闭查找" aria-label="关闭文档查找">×</button></div></nav>
        <article id="document">\#(body)<footer>文档已载入本机 · 点击页码可定位左侧原文</footer></article>
        <dialog id="image-viewer" aria-labelledby="image-title"><div class="image-controls"><strong id="image-title">图片</strong><button id="image-minus" aria-label="缩小图片">−</button><span id="image-scale" aria-live="polite">100%</span><button id="image-plus" aria-label="放大图片">＋</button><button id="image-fit">适合窗口</button><button id="image-close" aria-label="关闭图片">×</button></div><div class="image-stage" tabindex="0" aria-label="放大图片，拖动或滚动查看"><div class="image-canvas"></div></div></dialog>
        <script nonce="\#(nonce)">
        \#(restorationScript)
        (()=>{
          const documentID=\#(idJSON), documentTitle=\#(json(documentTitle)), token=\#(json(resourceToken));
          const restored=\#(restored), initialLocation=\#(locationJSON), article=document.getElementById('document');
          const tools=document.querySelector('.reader-tools'), history=makeReaderHistory();
          const readingBlocks=Array.from(article.querySelectorAll('[data-block-id]'));
          let ready=false, contentReady=false, didAnnounceReady=false, restoreTimer, saveTimer, searchTimer;
          let marks=[], cursor=-1, lastReported='', lastLocation=null, layoutAnchor=null, reflowGeneration=0;
          let cachedSelection=null, searchOrigin=null, sourceHighlightTimer;
          const restoreController=makeReaderRestoreController(restored,initialLocation);
          const range=()=>Math.max(0,document.documentElement.scrollHeight-innerHeight);
          const progress=()=>range()>0?Math.min(1,Math.max(0,scrollY/range())):0;
          const inset=()=>tools.getBoundingClientRect().height+8;
          const elements=()=>readingBlocks;
          // KaTeX includes parallel MathML, TeX annotations and visual HTML.
          // Their combined textContent is not a readable or stable excerpt.
          const readerText=node=>{
            if(!node)return '';
            const copy=node.cloneNode(true);
            if(copy.nodeType===Node.ELEMENT_NODE && copy.matches('.note-marker'))return '';
            if(copy.nodeType===Node.ELEMENT_NODE && copy.matches('.math'))return copy.dataset.readerFormula??copy.textContent;
            copy.querySelectorAll?.('.note-marker').forEach(el=>el.remove());
            copy.querySelectorAll?.('.math').forEach(el=>el.replaceWith(document.createTextNode(el.dataset.readerFormula??el.textContent)));
            copy.querySelectorAll?.('p,h1,h2,h3,h4,h5,h6,li,blockquote,pre,tr,.reader-block').forEach(el=>el.append(document.createTextNode('\n')));
            return (copy.textContent||'').replace(/\n[ \t]*\n+/g,'\n\n');
          };
          // Blocks are immutable for one document load. Search wraps text but does
          // not change it, and record markers must not alter a paragraph's quote.
          const blockTextCache=new WeakMap();
          const blockText=el=>{
            if(!el)return '';
            if(!blockTextCache.has(el))blockTextCache.set(el,normalizeReaderQuote(readerText(el)));
            return blockTextCache.get(el);
          };
          const blocks=()=>elements().map(el=>{const r=el.getBoundingClientRect();return {id:el.dataset.blockId,text:blockText(el),top:r.top+scrollY,height:r.height};});
          const locationFor=(el,offset=0,quote=null)=>({
            blockID:el?.dataset.blockId||'',quote:quote??blockText(el).slice(0,240),
            blockOffset:Math.max(0,Math.min(1,offset)),progress:progress(),
            pdfPage:el?.hasAttribute('data-pdf-page')?Number(el.dataset.pdfPage):null
          });
          const captureLocation=()=>{
            const all=elements(), probe=inset();
            const el=all.find(el=>el.getBoundingClientRect().bottom>probe) || all[all.length-1];
            if(!el)return {blockID:'',quote:'',blockOffset:0,progress:progress(),pdfPage:null};
            const rect=el.getBoundingClientRect();
            return locationFor(el,rect.height>0?(probe-rect.top)/rect.height:0);
          };
          const post=(event,extra={})=>window.webkit?.messageHandlers.readerProgress.postMessage({documentID,token,event,...history.state(),...extra});
          const snapshot=()=>ready?{documentID,token,...captureLocation()}:null;
          const report=()=>{
            if(!ready)return;
            const location=captureLocation();lastLocation=location;
            const key=JSON.stringify(location);
            if(key===lastReported)return;lastReported=key;post('location',location);
          };
          const announceReady=()=>{
            if(!ready || didAnnounceReady)return;
            didAnnounceReady=true;lastLocation=captureLocation();
            post('ready',lastLocation);
            if(initialLocation && !resolveReaderLocation(initialLocation,blocks(),range(),inset()).exact){
              post('notice',{notice:'这份材料的原段落已变化，已恢复到附近位置。'});
            }
          };
          // A WKWebView in a background/temporarily hidden native pane may pause
          // animation frames. A bounded fallback still completes the transaction.
          const afterLayout=callback=>{
            let called=false;
            const run=()=>{if(called)return;called=true;callback();};
            requestAnimationFrame(run);setTimeout(run,100);
          };
          const restore=()=>{
            clearTimeout(restoreTimer);
            const result=restoreController.sample({width:innerWidth,height:innerHeight,extent:range(),y:scrollY,contentReady,now:performance.now(),blocks:blocks(),inset:inset()});
            ready=result.ready;
            if(result.target!==null)scrollTo(0,result.target);
            if(result.pending)restoreTimer=setTimeout(restore,80);
            else if(ready){lastLocation=captureLocation();announceReady();report();}
          };
          const preserveLayout=(location)=>{
            if(!contentReady || !location)return;
            layoutAnchor=location;ready=false;const generation=++reflowGeneration;
            afterLayout(()=>{
              if(generation!==reflowGeneration)return;
              scrollTo(0,resolveReaderLocation(location,blocks(),range(),inset()).target);
              afterLayout(()=>{if(generation!==reflowGeneration)return;layoutAnchor=null;ready=true;lastLocation=captureLocation();announceReady();report();});
            });
          };
          const layoutChanged=()=>{
            if(!restoreController.userControlled()){ready=false;restoreController.recheck();clearTimeout(restoreTimer);restoreTimer=setTimeout(restore,80);}
            else preserveLayout(layoutAnchor||lastLocation||captureLocation());
          };
          const userIntent=()=>{restoreController.cancel();clearTimeout(restoreTimer);reflowGeneration++;layoutAnchor=null;ready=contentReady;announceReady();};
          const focus=()=>post('focus');
          addEventListener('scroll',()=>{if(!ready)return;lastLocation=captureLocation();clearTimeout(saveTimer);saveTimer=setTimeout(report,220);},{passive:true});
          addEventListener('wheel',()=>{userIntent();focus();},{passive:true,capture:true});
          addEventListener('touchstart',()=>{userIntent();focus();},{passive:true,capture:true});
          addEventListener('pointerdown',e=>{userIntent();focus();if(article.contains(e.target))cachedSelection=null;},{passive:true,capture:true});
          addEventListener('keydown',e=>{focus();if(['ArrowDown','ArrowUp','PageDown','PageUp','Home','End',' '].includes(e.key))userIntent();},{capture:true});
          addEventListener('resize',layoutChanged);new ResizeObserver(layoutChanged).observe(article);
          addEventListener('blur',report);addEventListener('pagehide',report);
          const clearSourceHighlight=()=>{clearTimeout(sourceHighlightTimer);article.querySelectorAll('.reader-source-target').forEach(el=>el.classList.remove('reader-source-target'));};
          const remember=()=>{history.remember(captureLocation());post('history');};
          const navigate=(location,rememberCurrent=true,highlight=false)=>{
            if(!location)return;
            if(rememberCurrent)remember();
            userIntent();cachedSelection=null;window.getSelection()?.removeAllRanges();clearSourceHighlight();
            const resolved=resolveReaderLocation(location,blocks(),range(),inset());
            scrollTo(0,resolved.target);lastLocation=captureLocation();
            if(highlight && resolved.exact){
              const el=elements().find(el=>el.dataset.blockId===resolved.blockID);
              if(el){el.classList.add('reader-source-target');sourceHighlightTimer=setTimeout(clearSourceHighlight,3500);}
            }
            if(highlight && !resolved.exact)post('notice',{notice:'原段落已修改或移除，无法精确定位；已打开附近位置，请核对摘录。'});
            post('history');report();
          };
          const navigateElement=el=>{
            const block=el?.closest('[data-block-id]');
            if(block)navigate(locationFor(block,0));
          };
          const selectedSource=()=>{
            const selection=window.getSelection();
            if(!selection?.rangeCount || selection.isCollapsed)return null;
            const selectedRange=selection.getRangeAt(0);
            if(!article.contains(selectedRange.startContainer) || !article.contains(selectedRange.endContainer))return null;
            const container=selectedRange.startContainer.nodeType===Node.ELEMENT_NODE?selectedRange.startContainer:selectedRange.startContainer.parentElement;
            const block=container?.closest('[data-block-id]'), rect=selectedRange.getBoundingClientRect();
            if(!block || rect.bottom<inset() || rect.top>innerHeight)return null;
            const blockRect=block.getBoundingClientRect();
            const quoteRange=selectedRange.cloneRange();
            const enclosingMath=node=>(node.nodeType===Node.ELEMENT_NODE?node:node.parentElement)?.closest('.math');
            const firstMath=enclosingMath(quoteRange.startContainer),lastMath=enclosingMath(quoteRange.endContainer);
            // A visual formula is one semantic unit even when a selection starts
            // inside a nested KaTeX glyph or subscript.
            if(firstMath)quoteRange.setStartBefore(firstMath);
            if(lastMath)quoteRange.setEndAfter(lastMath);
            const quote=readerText(quoteRange.cloneContents()).trim().slice(0,8000);
            return {...locationFor(block,blockRect.height>0?(rect.top-blockRect.top)/blockRect.height:0,quote),documentID,documentTitle,token};
          };
          const updateSelection=()=>{const source=selectedSource();if(source)cachedSelection=source;else if(document.hasFocus() && window.getSelection()?.isCollapsed)cachedSelection=null;};
          document.addEventListener('selectionchange',updateSelection);
          article.addEventListener('pointerup',updateSelection);
          const selectionSource=()=>{
            if(!ready)return null;
            const active=selectedSource();if(active){cachedSelection=active;return active;}
            if(cachedSelection){
              const block=elements().find(el=>el.dataset.blockId===cachedSelection.blockID), rect=block?.getBoundingClientRect();
              if(rect && rect.bottom>=inset() && rect.top<=innerHeight)return {...cachedSelection,progress:progress()};
            }
            return {documentID,documentTitle,token,...captureLocation()};
          };
          const setNoteSources=sources=>{
            article.querySelectorAll('.note-marker').forEach(el=>el.remove());
            const byBlock=new Map();
            for(const source of sources||[]){
              if(source?.documentID!==documentID || typeof source.blockID!=='string')continue;
              const list=byBlock.get(source.blockID)||[];list.push(source);byBlock.set(source.blockID,list);
            }
            for(const block of elements()){
              const sources=byBlock.get(block.dataset.blockId);if(!sources?.length)continue;
              const marker=document.createElement('button');marker.className='note-marker';
              marker.type='button';marker.setAttribute('aria-label','此段有 '+sources.length+' 条记录');marker.title='查看此段记录';
              marker.addEventListener('click',e=>{e.stopPropagation();post('noteSource',{source:sources[0]});});
              block.append(marker);
            }
          };
          const clearMarks=()=>{marks.forEach(mark=>mark.replaceWith(document.createTextNode(mark.textContent)));article.normalize();marks=[];cursor=-1;};
          const selectMatch=(direction)=>{
            if(!marks.length)return;
            userIntent();cachedSelection=null;
            if(searchOrigin){history.remember(searchOrigin);searchOrigin=null;post('history');}
            marks.forEach(m=>m.classList.remove('current-match'));cursor=(cursor+direction+marks.length)%marks.length;
            marks[cursor].classList.add('current-match');marks[cursor].scrollIntoView({block:'center'});
            document.getElementById('search-status').textContent=(cursor+1)+'/'+marks.length;lastLocation=captureLocation();report();
          };
          const search=()=>{
            clearMarks();document.getElementById('previous').disabled=true;document.getElementById('next').disabled=true;
            const q=document.getElementById('find').value.trim().toLocaleLowerCase(),status=document.getElementById('search-status');
            status.textContent='';if(!q)return;
            const walker=document.createTreeWalker(article,NodeFilter.SHOW_TEXT,{acceptNode:node=>node.parentElement.closest('.katex,.math,footer')?NodeFilter.FILTER_REJECT:NodeFilter.FILTER_ACCEPT}),nodes=[];
            while(walker.nextNode())nodes.push(walker.currentNode);
            for(const node of nodes){
              const text=node.nodeValue,lower=text.toLocaleLowerCase();let from=0,hit=lower.indexOf(q),found=false;const fragment=document.createDocumentFragment();
              while(hit>=0&&marks.length<500){found=true;fragment.append(document.createTextNode(text.slice(from,hit)));const mark=document.createElement('mark');mark.textContent=text.slice(hit,hit+q.length);fragment.append(mark);marks.push(mark);from=hit+q.length;hit=lower.indexOf(q,from);}
              if(found){fragment.append(document.createTextNode(text.slice(from)));node.replaceWith(fragment);}if(marks.length>=500)break;
            }
            status.textContent=marks.length?'0/'+marks.length:'无结果';document.getElementById('previous').disabled=!marks.length;document.getElementById('next').disabled=!marks.length;if(marks.length)selectMatch(1);
          };
          const focusSearch=()=>{
            userIntent();focus();const panel=document.getElementById('search-panel');
            if(panel.hidden){searchOrigin=captureLocation();panel.hidden=false;document.getElementById('toggle-search').setAttribute('aria-expanded','true');}
            document.getElementById('find').focus();document.getElementById('find').select();
          };
          const closeSearch=()=>{
            clearTimeout(searchTimer);document.getElementById('find').value='';search();
            const location=captureLocation();document.getElementById('search-panel').hidden=true;document.getElementById('toggle-search').setAttribute('aria-expanded','false');
            searchOrigin=null;document.getElementById('toggle-search').focus({preventScroll:true});preserveLayout(location);
          };
          window.ZhiyeReader={
            matches:(id,generation)=>id===documentID&&generation===token,
            getProgress:()=>ready?progress():null,snapshot,selectionSource,layoutChanged,focusSearch,setNoteSources,
            go:source=>{if(source?.documentID===documentID)navigate(source,true,true);},
            back:()=>navigate(history.back(captureLocation()),false),
            forward:()=>navigate(history.forward(captureLocation()),false),
            appearance:(size,dark)=>{
              const location=layoutAnchor||lastLocation||captureLocation(),sizeChanged=parseFloat(getComputedStyle(document.documentElement).fontSize)!==size,darkChanged=document.documentElement.dataset.dark!==String(dark);
              if(!sizeChanged&&!darkChanged)return;
              document.documentElement.style.fontSize=size+'px';document.documentElement.dataset.dark=String(dark);
              if(!restoreController.userControlled()){layoutChanged();return;}
              if(sizeChanged)preserveLayout(location);
            }
          };
          document.getElementById('contents').addEventListener('change',e=>navigateElement(document.getElementById(e.target.value)));
          article.addEventListener('click',e=>{
            const link=e.target.closest('a');if(!link)return;userIntent();
            const href=link.getAttribute('href')||'';
            if(href.startsWith('#')){e.preventDefault();let id;try{id=decodeURIComponent(href.slice(1));}catch{return;}navigateElement(document.getElementById(id));}
            else if(/^zhiye:\/\/page\/\d+$/.test(href)){e.preventDefault();report();post('page',{page:Number(href.split('/').pop())});}
          });
          document.getElementById('toggle-search').addEventListener('click',()=>{if(!document.getElementById('search-panel').hidden)closeSearch();else focusSearch();});
          document.getElementById('close-search').addEventListener('click',closeSearch);
          document.getElementById('find').addEventListener('input',()=>{userIntent();clearTimeout(searchTimer);searchTimer=setTimeout(search,220);});
          document.getElementById('find').addEventListener('keydown',e=>{if(e.key==='Enter'){e.preventDefault();clearTimeout(searchTimer);if(!marks.length)search();else selectMatch(e.shiftKey?-1:1);}if(e.key==='Escape'){e.preventDefault();closeSearch();}});
          document.getElementById('next').addEventListener('click',()=>selectMatch(1));document.getElementById('previous').addEventListener('click',()=>selectMatch(-1));
          // Local raster images stay inside this non-networked reader. The modal
          // does not replace the document or modify its scroll position.
          const viewer=document.getElementById('image-viewer'),stage=viewer.querySelector('.image-stage'),canvas=viewer.querySelector('.image-canvas');
          let imageTrigger=null,zoomImage=null,imageScale=1,drag=null,priorOverflow='';
          const setImageScale=value=>{
            if(!zoomImage)return;
            imageScale=Math.min(8,Math.max(.08,value));
            zoomImage.style.width=zoomImage.naturalWidth*imageScale+'px';zoomImage.style.height=zoomImage.naturalHeight*imageScale+'px';
            document.getElementById('image-scale').textContent=Math.round(imageScale*100)+'%';
            document.getElementById('image-minus').disabled=imageScale<=.08;document.getElementById('image-plus').disabled=imageScale>=8;
          };
          const fitImage=()=>{if(zoomImage)setImageScale(Math.min(1,(stage.clientWidth-40)/zoomImage.naturalWidth,(stage.clientHeight-40)/zoomImage.naturalHeight));};
          const openImage=img=>{
            if(!img.complete || !img.naturalWidth || !img.src.startsWith('zhiye-reader://local/asset/'))return;
            userIntent();report();imageTrigger=img;zoomImage=img.cloneNode();
            zoomImage.removeAttribute('tabindex');zoomImage.removeAttribute('role');zoomImage.removeAttribute('aria-label');zoomImage.draggable=false;
            canvas.replaceChildren(zoomImage);document.getElementById('image-title').textContent=img.alt||'论文图片';
            priorOverflow=document.body.style.overflow;document.body.style.overflow='hidden';viewer.showModal();fitImage();document.getElementById('image-close').focus();
          };
          const closeImage=()=>{if(viewer.open)viewer.close();};
          viewer.addEventListener('close',()=>{document.body.style.overflow=priorOverflow;imageTrigger?.focus({preventScroll:true});imageTrigger=null;zoomImage=null;drag=null;stage.classList.remove('dragging');});
          document.getElementById('image-close').addEventListener('click',closeImage);
          document.getElementById('image-plus').addEventListener('click',()=>setImageScale(imageScale*1.25));
          document.getElementById('image-minus').addEventListener('click',()=>setImageScale(imageScale/1.25));
          document.getElementById('image-fit').addEventListener('click',fitImage);
          viewer.addEventListener('keydown',e=>{if(e.key==='+'||e.key==='='){e.preventDefault();setImageScale(imageScale*1.25);}else if(e.key==='-'){e.preventDefault();setImageScale(imageScale/1.25);}});
          stage.addEventListener('pointerdown',e=>{if(e.button!==0)return;drag={x:e.clientX,y:e.clientY,left:stage.scrollLeft,top:stage.scrollTop};stage.setPointerCapture(e.pointerId);stage.classList.add('dragging');e.preventDefault();});
          stage.addEventListener('pointermove',e=>{if(drag){stage.scrollLeft=drag.left+drag.x-e.clientX;stage.scrollTop=drag.top+drag.y-e.clientY;}});
          const stopDrag=()=>{drag=null;stage.classList.remove('dragging');};
          stage.addEventListener('pointerup',stopDrag);stage.addEventListener('pointercancel',stopDrag);
          article.querySelectorAll('img').forEach(img=>{
            img.tabIndex=0;img.setAttribute('role','button');img.setAttribute('aria-label','放大图片：'+(img.alt||'论文图片'));
            img.addEventListener('click',()=>openImage(img));
            img.addEventListener('keydown',e=>{if(e.key==='Enter'||e.key===' '){e.preventDefault();openImage(img);}});
            img.addEventListener('error',()=>{img.alt='图片暂不可用：'+img.alt;img.removeAttribute('role');img.removeAttribute('tabindex');});
          });
          addEventListener('load',async()=>{
            article.querySelectorAll('.math').forEach(el=>{const source=el.textContent;el.dataset.readerFormula=source;try{if(!window.katex)throw Error();katex.render(source,el,{displayMode:el.classList.contains('display'),throwOnError:false,trust:false,strict:'ignore',maxExpand:500,maxSize:20});}catch{el.textContent=source;el.classList.add('math-fallback');el.title='公式未能排版，请对照左侧原文';}});
            await Promise.all([document.fonts?.ready??Promise.resolve(),...Array.from(article.querySelectorAll('img')).map(img=>img.complete?Promise.resolve():new Promise(resolve=>{img.addEventListener('load',resolve,{once:true});img.addEventListener('error',resolve,{once:true});}))]);
            contentReady=true;restore();
          },{once:true});
        })();
        </script></body></html>
        """#
    }
}
