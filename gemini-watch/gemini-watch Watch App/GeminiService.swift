import Foundation

enum GeminiError: LocalizedError {
    case missingAPIKey
    case badURL

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "No API key found. Add GEMINI_API_KEY to Secrets.plist."
        case .badURL:        return "Invalid request URL."
        }
    }
}

/// Events surfaced from a streaming request. Grounding sources typically arrive
/// in later chunks, so consumers should be prepared for either case at any point.
enum StreamEvent: Sendable {
    case text(String)
    case sources([GroundingSource])
    /// The model asked for a web search; carries the query it chose.
    case searching(String)
    /// Discard anything streamed so far — text emitted before a tool call is
    /// preamble, not part of the answer.
    case reset
}

/// Audio attached to the newest user turn. Gemini transcribes it server-side,
/// so nothing depends on the watch's own speech recognition.
struct AudioAttachment: Sendable {
    let mimeType: String
    let base64Data: String

    init?(fileURL: URL, mimeType: String) {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        self.mimeType = mimeType
        self.base64Data = data.base64EncodedString()
    }
}

actor GeminiService {
    private let baseURL = "https://generativelanguage.googleapis.com/v1beta/models/"

    /// One search is almost always enough for a watch-sized answer, and each
    /// extra round is another API round trip plus another search credit.
    private static let maxToolRounds = 2
    private static let searchResultCount = 5

    /// Flattened for the model: titles and snippets are what it needs to answer,
    /// URLs so it can cite. Sending raw JSON would just cost more tokens.
    private static func render(_ results: [SearchResult]) -> String {
        guard !results.isEmpty else { return "No results found." }
        return results.enumerated().map { index, result in
            "[\(index + 1)] \(result.title)\n\(result.url)\n\(result.snippet)"
        }.joined(separator: "\n\n")
    }

    /// Nil when the key is absent — callers receive a descriptive error instead of a crash. (#1)
    private let apiKey: String?

    init() {
        if let filePath = Bundle.main.path(forResource: "Secrets", ofType: "plist"),
           let plist = NSDictionary(contentsOfFile: filePath),
           let value = plist.object(forKey: "GEMINI_API_KEY") as? String,
           !value.isEmpty {
            apiKey = value
        } else {
            apiKey = nil
        }
    }

    // MARK: - Streaming

    func streamGenerateContent(
        messages: [Message],
        model: String = AppSettings.defaultFastModel,
        systemPrompt: String = AppSettings.defaultSystemPrompt,
        temperature: Double = 0.7,
        enableWebSearch: Bool = false,
        audio: AudioAttachment? = nil,
        searchProvider: SearchProvider? = nil
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        return AsyncThrowingStream { continuation in
            let requestTask = Task {
                guard let key = apiKey else {
                    continuation.finish(throwing: GeminiError.missingAPIKey)
                    return
                }

                let urlString = "\(baseURL)\(model):streamGenerateContent?alt=sse"
                guard let url = URL(string: urlString) else {
                    continuation.finish(throwing: GeminiError.badURL)
                    return
                }

                // Build a properly alternating user↔model context (#2):
                // Strip any leading model messages, then ensure strict alternation.
                var contextMessages = Array(messages.suffix(20))
                while contextMessages.first?.role == .model {
                    contextMessages.removeFirst()
                }
                var deduped: [Message] = []
                for msg in contextMessages {
                    if deduped.last?.role == msg.role {
                        deduped[deduped.count - 1] = msg
                    } else {
                        deduped.append(msg)
                    }
                }
                contextMessages = deduped

                var contents = contextMessages.map { message in
                    Content(role: message.role.rawValue, parts: [Part(text: message.text)])
                }

                // Attach audio to the newest user turn. A voice turn usually
                // carries no text at all, so drop the empty text part rather
                // than sending a blank string alongside the clip.
                if let audio {
                    let audioPart = Part(inline_data: InlineData(
                        mime_type: audio.mimeType,
                        data: audio.base64Data
                    ))
                    if var last = contents.last, last.role == MessageRole.user.rawValue {
                        last.parts = (last.parts ?? []).filter { !($0.text ?? "").isEmpty } + [audioPart]
                        contents[contents.count - 1] = last
                    } else {
                        contents.append(Content(role: MessageRole.user.rawValue, parts: [audioPart]))
                    }
                }

                // Two ways to search. An external provider is preferred because
                // it leaves the Gemini key on the free tier; `google_search`
                // grounding is the fallback for billing-enabled projects.
                let tools: [Tool]?
                if enableWebSearch {
                    tools = searchProvider == nil
                        ? [Tool(google_search: GoogleSearchTool())]
                        : [Tool(functionDeclarations: [FunctionDeclaration.webSearch])]
                } else {
                    tools = nil
                }

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.addValue("application/json", forHTTPHeaderField: "Content-Type")
                request.addValue(key, forHTTPHeaderField: "x-goog-api-key")
                // A voice turn ships a few hundred KB of PCM; 20s is fine for
                // text but can strand an audio upload on watch LTE.
                request.timeoutInterval = audio == nil ? 20 : 45

                do {
                    // Accumulate grounding across chunks — newer chunks supersede earlier ones.
                    var latestSources: [GroundingSource] = []
                    var round = 0

                    // Each pass is one streamed completion. A pass that ends in
                    // a tool call runs the search, appends the result, and goes
                    // round again; anything else is the final answer.
                    toolLoop: while true {
                        let geminiRequest = GeminiRequest(
                            contents: contents,
                            system_instruction: Content(role: "system", parts: [
                                Part(text: systemPrompt)
                            ]),
                            generationConfig: GenerationConfig(temperature: temperature),
                            tools: tools
                        )
                        request.httpBody = try JSONEncoder().encode(geminiRequest)

                        let (bytes, response) = try await URLSession.shared.bytes(for: request)

                        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                            let code = httpResponse.statusCode
                            let detail: String
                            switch code {
                            case 429: detail = "Rate limited. Wait a moment."
                            case 401, 403: detail = "API key invalid."
                            case 500...599: detail = "Server error. Try again."
                            default: detail = "Error \(code)"
                            }
                            continuation.finish(throwing: NSError(domain: "Gemini", code: code, userInfo: [NSLocalizedDescriptionKey: detail]))
                            return
                        }

                        var pendingCall: FunctionCall?
                        var textThisRound = ""

                        for try await line in bytes.lines {
                            if Task.isCancelled {
                                continuation.finish()
                                return
                            }
                            guard line.hasPrefix("data: ") else { continue }
                            let jsonString = String(line.dropFirst(6))
                            guard let data = jsonString.data(using: .utf8) else { continue }

                            do {
                                let decoded = try JSONDecoder().decode(GeminiResponse.self, from: data)
                                guard let candidate = decoded.candidates?.first else { continue }

                                for part in candidate.content?.parts ?? [] {
                                    if let call = part.functionCall {
                                        pendingCall = call
                                    } else if let text = part.text, !text.isEmpty {
                                        textThisRound += text
                                        continuation.yield(.text(text))
                                    }
                                }

                                if let chunks = candidate.groundingMetadata?.groundingChunks {
                                    let sources = chunks.compactMap { chunk -> GroundingSource? in
                                        guard let web = chunk.web,
                                              let uri = web.uri,
                                              !uri.isEmpty else { return nil }
                                        return GroundingSource(uri: uri, title: web.title ?? uri)
                                    }
                                    if !sources.isEmpty && sources != latestSources {
                                        latestSources = sources
                                        continuation.yield(.sources(sources))
                                    }
                                }
                            } catch {
                                // Ignore parse errors on individual stream chunks.
                            }
                        }

                        guard let call = pendingCall,
                              let provider = searchProvider,
                              round < Self.maxToolRounds else { break toolLoop }
                        round += 1

                        let query = call.args?["query"]?.value ?? ""
                        guard !query.isEmpty else { break toolLoop }

                        // Any preamble the model emitted before deciding to
                        // search is not part of the answer — tell the consumer
                        // to drop it so the two don't get concatenated.
                        if !textThisRound.isEmpty {
                            continuation.yield(.reset)
                        }
                        continuation.yield(.searching(query))

                        let results: [SearchResult]
                        do {
                            results = try await provider.search(query: query, maxResults: Self.searchResultCount)
                        } catch {
                            // A failed search shouldn't sink the whole answer —
                            // hand the model the failure and let it reply anyway.
                            results = []
                        }

                        if !results.isEmpty {
                            let sources = results.map { GroundingSource(uri: $0.url, title: $0.title) }
                            latestSources = sources
                            continuation.yield(.sources(sources))
                        }

                        contents.append(Content(role: "model", parts: [Part(functionCall: call)]))
                        contents.append(Content(role: "user", parts: [Part(
                            functionResponse: FunctionResponse(
                                name: call.name,
                                response: ["results": AnyCodable(Self.render(results))]
                            )
                        )]))
                    }

                    continuation.finish()
                } catch {
                    if !Task.isCancelled {
                        let msg = (error as? URLError)?.code == .timedOut
                            ? "Request timed out. Check connection."
                            : error.localizedDescription
                        continuation.finish(throwing: NSError(domain: "Gemini", code: -1, userInfo: [NSLocalizedDescriptionKey: msg]))
                    } else {
                        continuation.finish()
                    }
                }
            }

            // Cancelling the consumer (for example, tapping Stop) must also
            // cancel URLSession work so the watch does not keep using radio,
            // CPU, and battery for a response nobody is reading.
            continuation.onTermination = { @Sendable _ in
                requestTask.cancel()
            }
        }
    }

    // MARK: - List Available Models

    private var cachedModels: [String]?

    func listModels() async throws -> [String] {
        if let cached = cachedModels { return cached }

        guard let key = apiKey else { throw GeminiError.missingAPIKey }

        let urlString = "https://generativelanguage.googleapis.com/v1beta/models"
        guard let url = URL(string: urlString) else {
            throw GeminiError.badURL
        }

        var request = URLRequest(url: url)
        request.addValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw NSError(domain: "Gemini", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch models"])
        }

        let decoded = try JSONDecoder().decode(ModelsListResponse.self, from: data)

        let models = decoded.models
            .filter { model in
                model.name.hasPrefix("models/gemini-") &&
                model.supportedGenerationMethods?.contains("generateContent") == true
            }
            .map { $0.name.replacingOccurrences(of: "models/", with: "") }
            .sorted()

        cachedModels = models
        return models
    }
}

// MARK: - API Models

private struct GeminiRequest: Codable, Sendable {
    let contents: [Content]
    let system_instruction: Content?
    let generationConfig: GenerationConfig?
    let tools: [Tool]?
}

private struct Tool: Codable, Sendable {
    var google_search: GoogleSearchTool?
    var functionDeclarations: [FunctionDeclaration]?

    init(google_search: GoogleSearchTool? = nil, functionDeclarations: [FunctionDeclaration]? = nil) {
        self.google_search = google_search
        self.functionDeclarations = functionDeclarations
    }
}

private struct GoogleSearchTool: Codable, Sendable {}

// MARK: - Function Calling

private struct FunctionDeclaration: Codable, Sendable {
    let name: String
    let description: String
    let parameters: Schema

    /// Letting the model decide when to search is the point: most messages
    /// need no search at all, so a declared tool costs nothing until it's
    /// actually called — unlike searching unconditionally on every turn.
    static let webSearch = FunctionDeclaration(
        name: "web_search",
        description: """
            Search the web for current information. Use this only when the \
            answer depends on recent events, live data, or facts you are not \
            confident about. Do not use it for general knowledge, reasoning, \
            or writing tasks.
            """,
        parameters: Schema(
            type: "object",
            properties: ["query": Schema.Property(
                type: "string",
                description: "The search query."
            )],
            required: ["query"]
        )
    )
}

private struct Schema: Codable, Sendable {
    let type: String
    let properties: [String: Property]
    let required: [String]

    struct Property: Codable, Sendable {
        let type: String
        let description: String
    }
}

struct FunctionCall: Codable, Sendable {
    let name: String
    let args: [String: AnyCodable]?
}

private struct FunctionResponse: Codable, Sendable {
    let name: String
    let response: [String: AnyCodable]
}

/// Minimal dynamic JSON value — the function-calling payloads are the only
/// place this API needs one, and only for strings in practice.
struct AnyCodable: Codable, Sendable {
    let value: String

    init(_ value: String) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let int = try? container.decode(Int.self) {
            value = String(int)
        } else if let double = try? container.decode(Double.self) {
            value = String(double)
        } else if let bool = try? container.decode(Bool.self) {
            value = String(bool)
        } else {
            value = ""
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

private struct GenerationConfig: Codable, Sendable {
    let temperature: Double
}

private struct GeminiResponse: Decodable, Sendable {
    let candidates: [Candidate]?
}

private struct Candidate: Decodable, Sendable {
    let content: Content?
    let groundingMetadata: GroundingMetadata?
}

private struct Content: Codable, Sendable {
    var role: String?
    /// Optional so a trailing chunk that carries only `finishReason` or
    /// grounding metadata still decodes instead of being discarded whole.
    var parts: [Part]?

    init(role: String?, parts: [Part]?) {
        self.role = role
        self.parts = parts
    }
}

private struct Part: Codable, Sendable {
    var text: String?
    var inline_data: InlineData?
    var functionCall: FunctionCall?
    var functionResponse: FunctionResponse?

    init(text: String? = nil,
         inline_data: InlineData? = nil,
         functionCall: FunctionCall? = nil,
         functionResponse: FunctionResponse? = nil) {
        self.text = text
        self.inline_data = inline_data
        self.functionCall = functionCall
        self.functionResponse = functionResponse
    }
}

/// Base64 audio inlined in the request. `JSONEncoder` omits the nil sibling
/// field, so a text part never carries an empty `inline_data` and vice versa.
private struct InlineData: Codable, Sendable {
    let mime_type: String
    let data: String
}

// MARK: - Grounding

private struct GroundingMetadata: Decodable, Sendable {
    let groundingChunks: [GroundingChunk]?
}

private struct GroundingChunk: Decodable, Sendable {
    let web: WebSource?
}

private struct WebSource: Decodable, Sendable {
    let uri: String?
    let title: String?
}

// MARK: - Models List API

struct ModelsListResponse: Decodable {
    let models: [ModelInfo]
}

struct ModelInfo: Decodable {
    let name: String
    let supportedGenerationMethods: [String]?
}
