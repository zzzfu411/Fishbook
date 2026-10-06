import Foundation
import SwiftUI
import CryptoKit

enum CitationDirection: String, CaseIterable, Identifiable {
    case references, citations
    var id: String { rawValue }
    var title: String { self == .references ? "它引用的论文" : "引用它的论文" }
    // OpenAlex's cited_by filter returns the bibliography; cites returns incoming citations.
    var filter: String { self == .references ? "cited_by" : "cites" }
}

struct CitationWork: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let year: Int?
    let authors: [String]
    let venue: String?
    let doi: String?
    let citationCount: Int?
    let referenceCount: Int?
    var sourceURL: URL { URL(string: "https://openalex.org/\(id)")! }
    var authorLine: String { authors.prefix(3).joined(separator: ", ") + (authors.count > 3 ? " 等" : "") }
    var detailLine: String { [year.map(String.init), venue].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ") }

    static func normalizedTitle(_ title: String) -> String {
        title.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
    static func workID(_ value: String) -> String? {
        let text = value.replacingOccurrences(of: "https://openalex.org/", with: "").replacingOccurrences(of: "http://openalex.org/", with: "")
        guard text.range(of: "^W[0-9]+$", options: .regularExpression) != nil else { return nil }
        return text
    }
}

private struct OpenAlexWork: Decodable {
    struct Authorship: Decodable { struct Author: Decodable { let display_name: String? }; let author: Author? }
    struct Location: Decodable { struct Source: Decodable { let display_name: String? }; let source: Source? }
    let id: String
    let title: String?
    let publication_year: Int?
    let authorships: [Authorship]?
    let primary_location: Location?
    let doi: String?
    let cited_by_count: Int?
    let referenced_works: [String]?

    var work: CitationWork? {
        guard let id = CitationWork.workID(id), let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return CitationWork(id: id, title: title, year: publication_year,
            authors: (authorships ?? []).compactMap { $0.author?.display_name }, venue: primary_location?.source?.display_name,
            doi: doi, citationCount: cited_by_count, referenceCount: referenced_works?.count)
    }
}

struct CitationPage: Equatable {
    var papers: [CitationWork]
    var total: Int?
    var next: String?
    var fetchedAt: Date
    var cached: Bool
    var stale: Bool
}

private struct OpenAlexPage: Decodable {
    struct Meta: Decodable { let count: Int?; let next_cursor: String? }
    let meta: Meta
    let results: [OpenAlexWork]
}

enum CitationFailure: LocalizedError {
    case invalidQuery, rateLimited, notFound, unavailable, invalidResponse, offline
    var errorDescription: String? {
        switch self {
        case .invalidQuery: return "请输入论文标题、DOI 或 arXiv 链接。"
        case .rateLimited: return "引文服务暂时限流，请稍后重试。已缓存的路线仍可查看。"
        case .notFound: return "暂未找到这篇论文，试试完整标题或 DOI。"
        case .unavailable: return "引文服务暂时不可用，请稍后重试。"
        case .invalidResponse: return "引文数据未能读取，请稍后重试。"
        case .offline: return "暂时无法连接引文服务，请检查网络后重试。"
        }
    }
}

/// Only public bibliographic queries leave the app. PDF bytes and reading records never do.
actor CitationService {
    static let fields = "id,title,publication_year,authorships,primary_location,doi,cited_by_count,referenced_works"
    static let pageSize = 20
    static let maximumCacheBytes = 12 * 1_024 * 1_024
    private let session: URLSession
    private let cacheDirectory: URL
    private let cacheByteLimit: Int
    private let cacheEntryLimit: Int
    private struct CachedResponse: Codable { let date: Date; let data: Data }
    private let freshAge: TimeInterval = 7 * 24 * 60 * 60
    private let maximumAge: TimeInterval = 30 * 24 * 60 * 60

    init(session: URLSession? = nil, cacheDirectory: URL? = nil,
         cacheByteLimit: Int = CitationService.maximumCacheBytes, cacheEntryLimit: Int = 160) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 25
        configuration.httpMaximumConnectionsPerHost = 2
        self.session = session ?? URLSession(configuration: configuration)
        self.cacheDirectory = cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "local.paperstudy.reader")
            .appendingPathComponent("CitationGraph-v1")
        self.cacheByteLimit = cacheByteLimit
        self.cacheEntryLimit = cacheEntryLimit
    }

    static func request(path: String = "/works", items: [URLQueryItem]) -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"; components.host = "api.openalex.org"; components.path = path
        components.queryItems = items + [URLQueryItem(name: "select", value: fields)]
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Fishbook/0.9 (https://github.com/zzzfu411/Fishbook)", forHTTPHeaderField: "User-Agent")
        return request
    }
    static func searchRequest(_ input: String) throws -> URLRequest {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, input.count <= 600 else { throw CitationFailure.invalidQuery }
        if let id = CitationWork.workID(input) { return request(path: "/works/\(id)", items: []) }
        var doi = input.replacingOccurrences(of: "https://doi.org/", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "http://doi.org/", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "doi:", with: "", options: [.caseInsensitive, .anchored])
        if let url = URL(string: input), ["arxiv.org", "www.arxiv.org", "export.arxiv.org"].contains(url.host?.lowercased() ?? "") {
            var identifier = url.path.replacingOccurrences(of: "^/(abs|pdf)/", with: "", options: .regularExpression)
            identifier = identifier.replacingOccurrences(of: "\\.pdf$", with: "", options: .regularExpression)
                .replacingOccurrences(of: "v[0-9]+$", with: "", options: .regularExpression)
            doi = "10.48550/arXiv.\(identifier)"
        }
        let isDOI = doi.range(of: "^10\\.[0-9]{4,9}/[^\\s]+$", options: .regularExpression) != nil
        return request(items: [URLQueryItem(name: isDOI ? "filter" : "search", value: isDOI ? "doi:\(doi)" : input),
                               URLQueryItem(name: "per_page", value: "8")])
    }
    static func relationRequest(work: CitationWork, direction: CitationDirection, cursor: String = "*") -> URLRequest {
        request(items: [URLQueryItem(name: "filter", value: "\(direction.filter):\(work.id)"),
                        URLQueryItem(name: "sort", value: direction == .references ? "cited_by_count:desc" : "publication_date:desc"),
                        URLQueryItem(name: "per_page", value: String(pageSize)), URLQueryItem(name: "cursor", value: cursor)])
    }

    func search(_ query: String, refresh: Bool = false) async throws -> CitationPage {
        let request = try Self.searchRequest(query)
        let response = try await fetch(request, refresh: refresh)
        if request.url!.path != "/works" {
            guard let work = try JSONDecoder().decode(OpenAlexWork.self, from: response.data).work else { throw CitationFailure.notFound }
            return CitationPage(papers: [work], total: 1, next: nil, fetchedAt: response.date, cached: response.cached, stale: response.stale)
        }
        return try decodePage(response)
    }
    func relations(work: CitationWork, direction: CitationDirection, cursor: String = "*", refresh: Bool = false) async throws -> CitationPage {
        try decodePage(await fetch(Self.relationRequest(work: work, direction: direction, cursor: cursor), refresh: refresh))
    }

    private struct Response { let data: Data; let date: Date; let cached: Bool; let stale: Bool }
    private func decodePage(_ response: Response) throws -> CitationPage {
        do {
            let page = try JSONDecoder().decode(OpenAlexPage.self, from: response.data)
            var seen = Set<String>()
            let papers = page.results.compactMap(\.work).filter { seen.insert($0.id).inserted }
            return CitationPage(papers: papers, total: page.meta.count,
                next: page.results.isEmpty ? nil : page.meta.next_cursor,
                fetchedAt: response.date, cached: response.cached, stale: response.stale)
        } catch { throw CitationFailure.invalidResponse }
    }
    private func cacheURL(_ url: URL) -> URL {
        let hash = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent(hash).appendingPathExtension("json")
    }
    private func fetch(_ request: URLRequest, refresh: Bool) async throws -> Response {
        try Task.checkCancellation()
        let url = cacheURL(request.url!)
        let saved = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(CachedResponse.self, from: $0) }
        let cached = saved.flatMap { saved -> CachedResponse? in
            guard Date().timeIntervalSince(saved.date) >= 0, Date().timeIntervalSince(saved.date) < maximumAge,
                  (try? validate(saved.data, for: request)) != nil else { return nil }
            return saved
        }
        if !refresh, let cached, Date().timeIntervalSince(cached.date) < freshAge {
            return Response(data: cached.data, date: cached.date, cached: true, stale: false)
        }
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { throw CitationFailure.invalidResponse }
            switch response.statusCode {
            case 200: break
            case 429: throw CitationFailure.rateLimited
            case 404: throw CitationFailure.notFound
            default: throw CitationFailure.unavailable
            }
            guard data.count <= 4 * 1_024 * 1_024 else { throw CitationFailure.invalidResponse }
            // Validate before caching: an HTML error or malformed response must never replace good data.
            try validate(data, for: request)
            let date = Date()
            if let bytes = try? JSONEncoder().encode(CachedResponse(date: date, data: data)), bytes.count <= cacheByteLimit {
                try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
                try? bytes.write(to: url, options: .atomic)
                trimCache()
            }
            return Response(data: data, date: date, cached: false, stale: false)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            if let cached { return Response(data: cached.data, date: cached.date, cached: true, stale: true) }
            if let failure = error as? CitationFailure { throw failure }
            if error is DecodingError { throw CitationFailure.invalidResponse }
            throw CitationFailure.offline
        }
    }
    private func validate(_ data: Data, for request: URLRequest) throws {
        if request.url!.path == "/works" { _ = try JSONDecoder().decode(OpenAlexPage.self, from: data) }
        else { _ = try JSONDecoder().decode(OpenAlexWork.self, from: data) }
    }
    private func trimCache() {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])) ?? []
        let files = urls.compactMap { url -> (URL, Int, Date)? in
            guard url.pathExtension == "json", let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]), values.isRegularFile == true else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 > $1.2 }
        var bytes = 0, entries = 0
        for (url, size, date) in files {
            if Date().timeIntervalSince(date) > maximumAge || bytes + size > cacheByteLimit || entries >= cacheEntryLimit { try? fm.removeItem(at: url) }
            else { bytes += size; entries += 1 }
        }
    }
}

struct CitationBranch {
    var papers: [CitationWork] = []
    var total: Int?
    var next: String?
    var fetchedAt: Date?
    var cached = false
    var stale = false
    var loading = true
    var error: String?
    mutating func accept(_ page: CitationPage, append: Bool, excluding id: String) {
        var seen = Set(append ? papers.map(\.id) : [])
        let incoming = page.papers.filter { $0.id != id && seen.insert($0.id).inserted }
        papers = (append ? papers : []) + incoming
        next = page.next == next && append ? nil : page.next
        total = page.total; fetchedAt = page.fetchedAt; cached = page.cached; stale = page.stale
        error = nil; loading = false
    }
}
struct CitationNeighborhood {
    let work: CitationWork
    var references = CitationBranch()
    var citations = CitationBranch()
    subscript(_ direction: CitationDirection) -> CitationBranch {
        get { direction == .references ? references : citations }
        set { if direction == .references { references = newValue } else { citations = newValue } }
    }
}

@MainActor final class CitationGraphModel: ObservableObject {
    @Published private(set) var graph: CitationNeighborhood?
    @Published private(set) var candidates: [CitationWork] = []
    @Published private(set) var searching = false
    @Published private(set) var searched = false
    @Published private(set) var error: String?
    @Published private(set) var history: [CitationNeighborhood] = []
    private let service: CitationService
    private var generation = UUID()
    private var tasks: [String: Task<Void, Never>] = [:]
    init(service: CitationService = CitationService()) { self.service = service }

    func cancel() { generation = UUID(); tasks.values.forEach { $0.cancel() }; tasks.removeAll() }
    func search(_ query: String, year: Int? = nil, refresh: Bool = false) {
        cancel(); let token = generation
        graph = nil; candidates = []; history = []; error = nil; searching = true; searched = false
        tasks["search"] = Task {
            do {
                let result = try await service.search(query, refresh: refresh)
                guard token == generation, !Task.isCancelled else { return }
                searching = false; searched = true
                candidates = result.papers
                let normalized = CitationWork.normalizedTitle(query)
                let exact = candidates.filter { normalized.count >= 16 && CitationWork.normalizedTitle($0.title) == normalized && (year == nil || year == 0 || $0.year == year) }
                if exact.count == 1 { explore(exact[0]) }
                else if candidates.count == 1, let request = try? CitationService.searchRequest(query),
                    let url = request.url, URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "filter" }) == true { explore(candidates[0]) }
                else if candidates.count == 1, CitationWork.workID(query) != nil { explore(candidates[0]) }
            } catch {
                guard token == generation, !Task.isCancelled else { return }
                searching = false; searched = true; self.error = error.localizedDescription
            }
        }
    }
    func explore(_ work: CitationWork) {
        if let graph, graph.work.id == work.id { return }
        if let graph { history.append(graph); if history.count > 24 { history.removeFirst() } }
        cancel(); candidates = []; error = nil; graph = CitationNeighborhood(work: work)
        for direction in CitationDirection.allCases { load(direction) }
    }
    func back() {
        guard let previous = history.popLast() else { return }
        cancel(); graph = previous
        for direction in CitationDirection.allCases where previous[direction].loading { load(direction) }
    }
    func refresh() {
        guard graph != nil else { return }
        cancel()
        for direction in CitationDirection.allCases { load(direction, refresh: true) }
    }
    func load(_ direction: CitationDirection, more: Bool = false, refresh: Bool = false) {
        guard let current = graph, !more || (!current[direction].loading && current[direction].next != nil) else { return }
        let token = generation, work = current.work
        let cursor = more ? current[direction].next! : "*"
        graph?[direction].loading = true; graph?[direction].error = nil
        tasks[direction.rawValue] = Task {
            do {
                let page = try await service.relations(work: work, direction: direction, cursor: cursor, refresh: refresh)
                guard token == generation, !Task.isCancelled else { return }
                graph?[direction].accept(page, append: more, excluding: work.id)
            } catch {
                guard token == generation, !Task.isCancelled else { return }
                graph?[direction].loading = false; graph?[direction].error = error.localizedDescription
            }
        }
    }
}
