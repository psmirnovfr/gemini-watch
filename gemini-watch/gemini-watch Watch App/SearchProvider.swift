import Foundation

/// One web result, trimmed to what a language model actually needs.
struct SearchResult: Sendable {
    let title: String
    let url: String
    let snippet: String
}

/// A web-search backend.
///
/// Gemini's own `google_search` grounding is the nicer integration, but its
/// free allowance is tied to billing-enabled projects — turning it on would
/// move the whole project off the free tier and start charging per token on
/// every ordinary chat message. So search is done externally instead, keeping
/// the Gemini key on the free tier.
///
/// The landscape of free search APIs is unstable (Bing's API was retired in
/// 2025, Google's Custom Search JSON API closed to new signups and is being
/// shut down, Brave dropped its free tier in 2026), so this stays a protocol:
/// swapping backends should mean writing one struct, not touching the client.
protocol SearchProvider: Sendable {
    /// Shown in Settings so it's obvious which backend is wired up.
    var name: String { get }
    func search(query: String, maxResults: Int) async throws -> [SearchResult]
}

enum SearchError: LocalizedError {
    case badResponse(Int)
    case badURL
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .badResponse(let code): return "Search failed (\(code))."
        case .badURL:                return "Invalid search URL."
        case .rateLimited:           return "Search rate-limited. Try again shortly."
        }
    }
}

// MARK: - DuckDuckGo (keyless)

/// Zero-setup search: no account, no key, no card.
///
/// There is no DuckDuckGo search API — the well-known Python `ddgs` package
/// isn't an API client either, it POSTs to the same lite endpoint used here and
/// parses the HTML. This is that technique in Swift, which is the only way to
/// get it onto a watch with no server in the loop.
///
/// The tradeoffs are real and worth knowing:
/// - It parses HTML, so a markup change upstream breaks it. There is no
///   versioned contract to rely on.
/// - Automated querying is against DuckDuckGo's terms of service.
/// - It rate-limits (HTTP 202/403). The complaints you'll find online are
///   mostly from cloud and CI addresses doing bulk queries; a watch on a
///   residential or cellular address asking a few questions a day is a very
///   different pattern, but there's no guarantee.
///
/// Use `TavilySearchProvider` instead when reliability matters more than
/// avoiding a signup.
struct DuckDuckGoSearchProvider: SearchProvider {
    let name = "DuckDuckGo"
    private let endpoint = "https://lite.duckduckgo.com/lite/"

    /// The lite endpoint returns an empty page to a default URLSession agent.
    private let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    func search(query: String, maxResults: Int) async throws -> [SearchResult] {
        do {
            return try await fetch(query: query, maxResults: maxResults)
        } catch SearchError.rateLimited {
            // A single backoff covers the common transient throttle without
            // turning a slow answer into a stalled one.
            try await Task.sleep(nanoseconds: 1_200_000_000)
            return try await fetch(query: query, maxResults: maxResults)
        }
    }

    private func fetch(query: String, maxResults: Int) async throws -> [SearchResult] {
        guard let url = URL(string: endpoint) else { throw SearchError.badURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        request.httpBody = "q=\(encoded)".data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200: break
            case 202, 403, 429: throw SearchError.rateLimited
            default: throw SearchError.badResponse(http.statusCode)
            }
        }

        guard let html = String(data: data, encoding: .utf8) else {
            throw SearchError.badResponse(-1)
        }
        return Self.parse(html: html, limit: maxResults)
    }

    // MARK: - Parsing

    private static let linkRegex = try! NSRegularExpression(
        pattern: "<a[^>]+class=['\"]result-link['\"][^>]*>([\\s\\S]*?)</a>",
        options: .caseInsensitive
    )
    private static let hrefRegex = try! NSRegularExpression(
        pattern: "<a[^>]+class=['\"]result-link['\"][^>]*href=['\"]([^'\"]+)['\"]|<a[^>]+href=['\"]([^'\"]+)['\"][^>]+class=['\"]result-link['\"]",
        options: .caseInsensitive
    )
    private static let snippetRegex = try! NSRegularExpression(
        pattern: "<td[^>]+class=['\"]result-snippet['\"][^>]*>([\\s\\S]*?)</td>",
        options: .caseInsensitive
    )

    static func parse(html: String, limit: Int) -> [SearchResult] {
        let titles = matches(Self.linkRegex, in: html, groups: [1]).map(stripTags)
        let hrefs = matches(Self.hrefRegex, in: html, groups: [1, 2]).map(resolve)
        let snippets = matches(Self.snippetRegex, in: html, groups: [1]).map(stripTags)

        var results: [SearchResult] = []
        for index in 0..<min(titles.count, hrefs.count) where results.count < limit {
            let title = titles[index]
            let url = hrefs[index]
            guard !title.isEmpty, !url.isEmpty else { continue }
            results.append(SearchResult(
                title: title,
                url: url,
                snippet: index < snippets.count ? snippets[index] : ""
            ))
        }
        return results
    }

    /// Returns the first non-empty capture group per match, so one pattern can
    /// cover both attribute orderings.
    private static func matches(_ regex: NSRegularExpression, in html: String, groups: [Int]) -> [String] {
        let range = NSRange(html.startIndex..., in: html)
        return regex.matches(in: html, range: range).compactMap { match in
            for group in groups where group < match.numberOfRanges {
                if let r = Range(match.range(at: group), in: html) {
                    return String(html[r])
                }
            }
            return nil
        }
    }

    /// DuckDuckGo wraps outbound links in a redirect carrying the real target
    /// in `uddg`; unwrap it so citations point somewhere useful.
    private static func resolve(_ href: String) -> String {
        // Decode first: the raw attribute separates params with `&amp;`, which
        // would otherwise survive into the parsed query.
        let decoded = decodeEntities(href)
        let absolute = decoded.hasPrefix("//") ? "https:\(decoded)" : decoded
        guard absolute.contains("uddg="),
              let components = URLComponents(string: absolute),
              let target = components.queryItems?.first(where: { $0.name == "uddg" })?.value
        else { return absolute }
        return target
    }

    private static func stripTags(_ raw: String) -> String {
        let withoutTags = raw.replacingOccurrences(
            of: "<[^>]+>", with: "", options: .regularExpression
        )
        return decodeEntities(withoutTags)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ raw: String) -> String {
        var out = raw
        for (entity, character) in [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
            ("&#x27;", "'"), ("&#39;", "'"), ("&nbsp;", " "), ("&hellip;", "…")
        ] {
            out = out.replacingOccurrences(of: entity, with: character)
        }
        return out
    }
}

// MARK: - Tavily

/// Tavily returns clean extracted text rather than HTML, which is what makes it
/// worth the request: no scraping, no parsing, and snippets that are already
/// model-readable. Free tier is 1,000 searches/month with no card on file.
struct TavilySearchProvider: SearchProvider {
    let name = "Tavily"
    private let apiKey: String
    private let endpoint = "https://api.tavily.com/search"

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func search(query: String, maxResults: Int) async throws -> [SearchResult] {
        guard let url = URL(string: endpoint) else { throw SearchError.badURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        request.httpBody = try JSONEncoder().encode(
            TavilyRequest(query: query, max_results: maxResults)
        )

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw SearchError.badResponse(http.statusCode)
        }

        let decoded = try JSONDecoder().decode(TavilyResponse.self, from: data)
        return decoded.results.map {
            SearchResult(title: $0.title, url: $0.url, snippet: $0.content)
        }
    }

    private struct TavilyRequest: Encodable {
        let query: String
        let max_results: Int
        /// "basic" costs one credit; "advanced" costs two. Not worth double for
        /// answers that have to fit a watch screen.
        let search_depth = "basic"
        let include_answer = false
    }

    private struct TavilyResponse: Decodable {
        let results: [Item]

        struct Item: Decodable {
            let title: String
            let url: String
            let content: String
        }
    }
}

// MARK: - Resolution

enum SearchBackend {
    /// Picks a backend from `Secrets.plist`, defaulting to something that works
    /// with no configuration at all.
    ///
    /// Order:
    /// 1. `SEARCH_BACKEND` forces a choice (`tavily`, `duckduckgo`, `gemini`).
    /// 2. A `TAVILY_API_KEY` selects Tavily — the reliable option.
    /// 3. Otherwise DuckDuckGo, which needs no account, key, or card.
    ///
    /// Returning nil means "use Gemini's own `google_search` grounding", which
    /// requires billing enabled on the Google Cloud project.
    static func configured() -> SearchProvider? {
        let plist = Bundle.main.path(forResource: "Secrets", ofType: "plist")
            .flatMap { NSDictionary(contentsOfFile: $0) }

        let tavilyKey = (plist?.object(forKey: "TAVILY_API_KEY") as? String) ?? ""

        switch (plist?.object(forKey: "SEARCH_BACKEND") as? String)?.lowercased() {
        case "gemini":
            return nil
        case "duckduckgo", "ddg":
            return DuckDuckGoSearchProvider()
        case "tavily":
            return tavilyKey.isEmpty ? DuckDuckGoSearchProvider() : TavilySearchProvider(apiKey: tavilyKey)
        default:
            return tavilyKey.isEmpty ? DuckDuckGoSearchProvider() : TavilySearchProvider(apiKey: tavilyKey)
        }
    }
}
