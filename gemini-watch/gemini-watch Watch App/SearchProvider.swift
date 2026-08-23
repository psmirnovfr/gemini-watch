import Foundation

/// One web result, trimmed to what a language model actually needs.
struct SearchResult: Sendable, Hashable {
    let title: String
    let url: String
    let snippet: String
}

/// A web-search backend.
///
/// Gemini's own `google_search` grounding is the nicer integration, but its
/// free allowance is tied to billing-enabled projects — turning it on would
/// move the whole project off the free tier and start charging per token on
/// every ordinary chat message. Search is done externally instead, keeping the
/// Gemini key on the free tier.
///
/// Kept behind a protocol because the free-search landscape is unstable: Bing's
/// API was retired in 2025, Google's Custom Search JSON API closed to new
/// signups, and Brave dropped its free tier in 2026. Swapping backends should
/// mean writing one struct, not touching the client.
protocol SearchProvider: Sendable {
    /// Shown in Settings so it's obvious which backend is wired up.
    var name: String { get }
    func search(query: String, maxResults: Int) async throws -> [SearchResult]
}

enum SearchError: LocalizedError {
    case badResponse(Int)
    case badURL
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .badResponse(let code): return "Search failed (\(code))."
        case .badURL:                return "Invalid search URL."
        case .notConfigured:         return "No search key. Add TAVILY_API_KEY to Secrets.plist."
        }
    }
}

// MARK: - Tavily

/// Tavily returns clean extracted text rather than HTML, which is what makes it
/// worth the request: no scraping, no parsing, and snippets that are already
/// model-readable. Free tier is 1,000 searches/month.
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
    /// Reads the optional search key from the same `Secrets.plist` as the
    /// Gemini key. Nil means search simply isn't configured, and the Search
    /// button stays hidden rather than failing when tapped.
    static func configured() -> SearchProvider? {
        guard let path = Bundle.main.path(forResource: "Secrets", ofType: "plist"),
              let plist = NSDictionary(contentsOfFile: path),
              let key = plist.object(forKey: "TAVILY_API_KEY") as? String,
              !key.isEmpty else { return nil }
        return TavilySearchProvider(apiKey: key)
    }
}
