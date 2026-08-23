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

    // MARK: - Context Building

    /// Builds a properly alternating user↔model context (#2): strip any leading
    /// model messages, then collapse adjacent same-role turns.
    private func buildContents(from messages: [Message]) -> [Content] {
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
        return deduped.map { Content(role: $0.role.rawValue, parts: [Part(text: $0.text)]) }
    }

    private func request(for url: URL, key: String, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = timeout
        return request
    }

    private func mapError(status code: Int) -> NSError {
        let detail: String
        switch code {
        case 429: detail = "Rate limited. Wait a moment."
        case 401, 403: detail = "API key invalid."
        case 500...599: detail = "Server error. Try again."
        default: detail = "Error \(code)"
        }
        return NSError(domain: "Gemini", code: code, userInfo: [NSLocalizedDescriptionKey: detail])
    }

    // MARK: - Search Query Generation

    /// Asks the cheap model to turn the conversation into a handful of search
    /// queries. A flash-lite completion costs far less than a search credit, so
    /// spending one request to aim the searches is the cheaper trade — and it
    /// beats searching the user's raw phrasing, which is often a poor query.
    func generateSearchQueries(
        messages: [Message],
        count: Int,
        model: String
    ) async throws -> [String] {
        guard let key = apiKey else { throw GeminiError.missingAPIKey }
        guard let url = URL(string: "\(baseURL)\(model):generateContent") else {
            throw GeminiError.badURL
        }

        var contents = buildContents(from: messages)
        contents.append(Content(role: "user", parts: [Part(text: """
            Based on the conversation above, write \(count) web search queries \
            that would find the information needed to answer well.

            Rules:
            - One query per line, nothing else. No numbering, no bullets, no quotes.
            - Keep each query short and keyword-like, the way you'd type it into a \
            search engine.
            - Make them cover different angles rather than rephrasing each other.
            - Write them in the language most likely to surface good sources.
            """)]))

        var request = self.request(for: url, key: key, timeout: 20)
        request.httpBody = try JSONEncoder().encode(GeminiRequest(
            contents: contents,
            system_instruction: nil,
            // Deterministic: this is a mechanical rewrite, not a creative task.
            generationConfig: GenerationConfig(temperature: 0.2),
            tools: nil
        ))

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw mapError(status: http.statusCode)
        }

        let decoded = try JSONDecoder().decode(GeminiResponse.self, from: data)
        let raw = decoded.candidates?.first?.content?.parts?
            .compactMap(\.text).joined() ?? ""

        let queries = raw
            .split(separator: "\n")
            .map { line -> String in
                // Strip list markers the model may add despite instructions.
                line.trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "^[-*•\\d.)\\s]+", with: "", options: .regularExpression)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    .trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }

        // Fall back to the user's own words rather than failing the whole flow.
        if queries.isEmpty, let last = messages.last(where: { $0.role == .user })?.text, !last.isEmpty {
            return [last]
        }
        return Array(queries.prefix(count))
    }

    // MARK: - Streaming

    func streamGenerateContent(
        messages: [Message],
        model: String = AppSettings.defaultFastModel,
        systemPrompt: String = AppSettings.defaultSystemPrompt,
        temperature: Double = 0.7,
        audio: AudioAttachment? = nil,
        searchContext: String? = nil
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

                var contents = buildContents(from: messages)

                // Extra parts ride along with the newest user turn rather than
                // becoming conversation history, so they scope to this request.
                var extraParts: [Part] = []
                if let searchContext, !searchContext.isEmpty {
                    extraParts.append(Part(text: """
                        Web search results for this question:

                        \(searchContext)

                        Answer using these results. Cite sources inline as [1], [2] \
                        matching their numbers above. If they don't cover it, say so \
                        rather than guessing.
                        """))
                }
                if let audio {
                    extraParts.append(Part(inline_data: InlineData(
                        mime_type: audio.mimeType,
                        data: audio.base64Data
                    )))
                }

                if !extraParts.isEmpty {
                    if var last = contents.last, last.role == MessageRole.user.rawValue {
                        // A voice turn carries no text, so drop the empty part
                        // rather than sending a blank string with the clip.
                        last.parts = (last.parts ?? []).filter { !($0.text ?? "").isEmpty } + extraParts
                        contents[contents.count - 1] = last
                    } else {
                        contents.append(Content(role: MessageRole.user.rawValue, parts: extraParts))
                    }
                }

                var request = self.request(
                    for: url,
                    key: key,
                    // A voice turn ships a few hundred KB of PCM; 20s is fine
                    // for text but can strand an audio upload on watch LTE.
                    timeout: audio == nil ? 20 : 45
                )

                do {
                    request.httpBody = try JSONEncoder().encode(GeminiRequest(
                        contents: contents,
                        system_instruction: Content(role: "system", parts: [Part(text: systemPrompt)]),
                        generationConfig: GenerationConfig(temperature: temperature),
                        tools: nil
                    ))

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                        continuation.finish(throwing: mapError(status: httpResponse.statusCode))
                        return
                    }

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
                                if let text = part.text, !text.isEmpty {
                                    continuation.yield(.text(text))
                                }
                            }
                        } catch {
                            // Ignore parse errors on individual stream chunks.
                        }
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
    let tools: [String]?
}

private struct GenerationConfig: Codable, Sendable {
    let temperature: Double
}

private struct GeminiResponse: Decodable, Sendable {
    let candidates: [Candidate]?
}

private struct Candidate: Decodable, Sendable {
    let content: Content?
}

private struct Content: Codable, Sendable {
    var role: String?
    /// Optional so a trailing chunk that carries only `finishReason` still
    /// decodes instead of being discarded whole.
    var parts: [Part]?

    init(role: String?, parts: [Part]?) {
        self.role = role
        self.parts = parts
    }
}

private struct Part: Codable, Sendable {
    var text: String?
    var inline_data: InlineData?

    init(text: String? = nil, inline_data: InlineData? = nil) {
        self.text = text
        self.inline_data = inline_data
    }
}

/// Base64 audio inlined in the request. `JSONEncoder` omits the nil sibling
/// field, so a text part never carries an empty `inline_data` and vice versa.
private struct InlineData: Codable, Sendable {
    let mime_type: String
    let data: String
}

// MARK: - Models List API

struct ModelsListResponse: Decodable {
    let models: [ModelInfo]
}

struct ModelInfo: Decodable {
    let name: String
    let supportedGenerationMethods: [String]?
}
