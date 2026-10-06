import Foundation

private final class CitationStub: URLProtocol {
    static let lock = NSLock()
    static var handler: (URLRequest) -> (Int, Data) = { _ in (500, Data()) }
    static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requests += 1; let result = Self.handler(request); Self.lock.unlock()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: result.0, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result.1)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func respond(_ handler: @escaping (URLRequest) -> (Int, Data)) {
        lock.lock(); self.handler = handler; lock.unlock()
    }
    static var count: Int { lock.lock(); defer { lock.unlock() }; return requests }
}

@main struct CitationGraphChecks {
    static func query(_ request: URLRequest, _ key: String) -> String? {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == key }?.value
    }
    static func work(_ id: String, title: String = "An Example of Verified Citation Relations") -> [String: Any] {
        ["id": "https://openalex.org/\(id)", "title": title, "publication_year": 2024,
         "authorships": [["author": ["display_name": "Example Author"]]], "cited_by_count": 30,
         "referenced_works": ["https://openalex.org/W2"], "primary_location": ["source": ["display_name": "Example Journal"]]]
    }
    static func page(_ works: [[String: Any]], next: String? = nil, total: Int? = nil) -> Data {
        var meta: [String: Any] = ["count": total ?? works.count]
        if let next { meta["next_cursor"] = next }
        return try! JSONSerialization.data(withJSONObject: ["meta": meta, "results": works])
    }
    @MainActor static func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        preconditionFailure("Timed out waiting for citation state")
    }
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fishbook-citations-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        if CommandLine.arguments.contains("--live") {
            let service = CitationService(cacheDirectory: directory)
            let title = "Efficient Memory Management for Large Language Model Serving with PagedAttention"
            let candidates = try await service.search(title)
            let paper = candidates.papers.first { CitationWork.normalizedTitle($0.title) == CitationWork.normalizedTitle(title) && ($0.referenceCount ?? 0) > 0 }!
            let references = try await service.relations(work: paper, direction: .references)
            let citations = try await service.relations(work: paper, direction: .citations)
            precondition(!references.papers.isEmpty && !citations.papers.isEmpty)
            precondition(citations.next != nil)
            print("PASS live OpenAlex: \(paper.id), \(references.papers.count)/\(references.total ?? 0) references, \(citations.papers.count)/\(citations.total ?? 0) citing papers; incoming pagination available.")
            return
        }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CitationStub.self]
        let session = URLSession(configuration: config)
        let service = CitationService(session: session, cacheDirectory: directory.appendingPathComponent("main"))
        let example = CitationWork(id: "W1", title: "An Example of Verified Citation Relations", year: 2024,
                                   authors: [], venue: nil, doi: nil, citationCount: 30, referenceCount: 1)
        precondition(query(CitationService.relationRequest(work: example, direction: .references), "filter") == "cited_by:W1")
        precondition(query(CitationService.relationRequest(work: example, direction: .citations), "filter") == "cites:W1")
        precondition(query(CitationService.relationRequest(work: example, direction: .citations, cursor: "a+/="), "cursor") == "a+/=")
        let encoded = try CitationService.searchRequest("Attention & Memory? x=1")
        precondition(query(encoded, "search") == "Attention & Memory? x=1" && query(encoded, "x") == nil)
        let arxivRequest = try CitationService.searchRequest("https://arxiv.org/pdf/2405.19888v2.pdf")
        let doiRequest = try CitationService.searchRequest("https://doi.org/10.1145/123.456")
        let idRequest = try CitationService.searchRequest("https://openalex.org/W1")
        precondition(query(arxivRequest, "filter") == "doi:10.48550/arXiv.2405.19888")
        precondition(query(doiRequest, "filter") == "doi:10.1145/123.456")
        precondition(idRequest.url!.path == "/works/W1")
        precondition(CitationWork.workID("https://example.org/W1") == nil)
        precondition(CitationWork.normalizedTitle("Café: LLM-based") == CitationWork.normalizedTitle("Cafe LLM based"))

        CitationStub.respond { _ in (200, page([work("W1"), work("W1"), ["id": "https://openalex.org/W3", "title": NSNull()]])) }
        let first = try await service.search("cache-me")
        precondition(first.papers.count == 1 && first.papers[0].authors == ["Example Author"] && !first.cached)
        let count = CitationStub.count
        let cached = try await service.search("cache-me")
        precondition(cached.cached && CitationStub.count == count)
        CitationStub.respond { _ in (429, Data()) }
        let offline = try await service.search("cache-me", refresh: true)
        precondition(offline.cached && offline.stale && offline.papers == first.papers)
        do { _ = try await service.search("uncached"); preconditionFailure("429 must not look like zero citations") }
        catch CitationFailure.rateLimited {}
        CitationStub.respond { _ in (200, Data("<html>bad gateway</html>".utf8)) }
        let malformed = try await service.search("cache-me", refresh: true)
        precondition(malformed.stale && malformed.papers == first.papers)

        var branch = CitationBranch()
        branch.accept(CitationPage(papers: [example, CitationWork(id: "W2", title: "Reference", year: nil, authors: [], venue: nil, doi: nil, citationCount: nil, referenceCount: nil)], total: 3, next: "next", fetchedAt: Date(), cached: false, stale: false), append: false, excluding: "W1")
        let nextPage = CitationPage(papers: branch.papers, total: 3, next: "next", fetchedAt: Date(), cached: false, stale: false)
        branch.accept(nextPage, append: true, excluding: "W1")
        precondition(branch.papers.count == 1 && branch.papers[0].id == "W2" && branch.next == nil)

        let cappedDirectory = directory.appendingPathComponent("capped")
        let capped = CitationService(session: session, cacheDirectory: cappedDirectory, cacheByteLimit: 4_000, cacheEntryLimit: 2)
        CitationStub.respond { _ in (200, page([work("W1")])) }
        for query in ["one", "two", "three"] { _ = try await capped.search(query) }
        let files = try FileManager.default.contentsOfDirectory(at: cappedDirectory, includingPropertiesForKeys: [.fileSizeKey])
        precondition(files.count <= 2)
        let size = try files.reduce(0) { try $0 + $1.resourceValues(forKeys: [.fileSizeKey]).fileSize! }
        precondition(size <= 4_000)

        let modelService = CitationService(session: session, cacheDirectory: directory.appendingPathComponent("model"))
        let model = CitationGraphModel(service: modelService)
        CitationStub.respond { request in
            if query(request, "search") != nil { return (200, page([work("W1"), work("W11")])) }
            return (200, page([work(query(request, "filter")?.hasPrefix("cites:") == true ? "W3" : "W2")], next: "second", total: 40))
        }
        model.search(example.title, year: 2024)
        try await settle { !model.searching }
        precondition(model.graph == nil && model.candidates.count == 2, "Do not silently choose between preprint and published versions")
        model.explore(model.candidates[0])
        try await settle { model.graph?.references.loading == false && model.graph?.citations.loading == false }
        precondition(model.graph?.references.papers.first?.id == "W2")
        precondition(model.graph?.citations.papers.first?.id == "W3")
        CitationStub.respond { _ in (429, Data()) }
        model.load(.citations, more: true)
        try await settle { model.graph?.citations.loading == false }
        precondition(model.graph?.citations.papers.count == 1 && model.graph?.citations.error != nil && model.graph?.citations.next == "second")

        CitationStub.respond { request in
            if query(request, "filter")?.hasPrefix("cited_by:") == true { return (429, Data()) }
            return (200, page([work("W5")]))
        }
        model.explore(CitationWork(id: "W4", title: "A different paper", year: 2025, authors: [], venue: nil, doi: nil, citationCount: 1, referenceCount: 2))
        try await settle { model.graph?.references.loading == false && model.graph?.citations.loading == false }
        precondition(model.graph?.references.error != nil && model.graph?.citations.papers.count == 1, "One failed direction must not erase the other")
        model.back()
        precondition(model.graph?.work.id == "W1" && model.graph?.citations.papers.first?.id == "W3")
        // Rapid traversal cancels obsolete work and must never attach old results to the new center.
        model.explore(CitationWork(id: "W8", title: "Superseded paper", year: nil, authors: [], venue: nil, doi: nil, citationCount: nil, referenceCount: nil))
        model.back()
        try await Task.sleep(nanoseconds: 80_000_000)
        precondition(model.graph?.work.id == "W1" && model.graph?.references.papers.first?.id == "W2")
        model.cancel()
        print("PASS: direction, query escaping, version ambiguity, decoding, deduplication, pagination, partial failures, offline cache, cache bounds, history and cancelled traversal.")
    }
}
