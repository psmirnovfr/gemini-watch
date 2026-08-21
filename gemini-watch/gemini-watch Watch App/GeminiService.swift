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

    // MARK: - Streaming

    func streamGenerateContent(
        messages: [Message],
        model: String = AppSettings.defaultFastModel,
        systemPrompt: String = AppSettings.defaultSystemPrompt,
        temperature: Double = 0.7,
        enableWebSearch: Bool = false,
        audio: AudioAttachment? = nil
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
                        last.parts = last.parts.filter { !($0.text ?? "").isEmpty } + [audioPart]
                        contents[contents.count - 1] = last
                    } else {
                        contents.append(Content(role: MessageRole.user.rawValue, parts: [audioPart]))
                    }
                }

                let geminiRequest = GeminiRequest(
                    contents: contents,
                    system_instruction: Content(role: "system", parts: [
                        Part(text: systemPrompt)
                    ]),
                    generationConfig: GenerationConfig(temperature: temperature),
                    tools: enableWebSearch ? [Tool(google_search: GoogleSearchTool())] : nil
                )

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.addValue("application/json", forHTTPHeaderField: "Content-Type")
                request.addValue(key, forHTTPHeaderField: "x-goog-api-key")
                // A voice turn ships a few hundred KB of PCM; 20s is fine for
                // text but can strand an audio upload on watch LTE.
                request.timeoutInterval = audio == nil ? 20 : 45

                do {
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

                    // Accumulate grounding across chunks — newer chunks supersede earlier ones.
                    var latestSources: [GroundingSource] = []

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
                            if let candidate = decoded.candidates?.first {
                                if let text = candidate.content?.parts.first?.text {
                                    continuation.yield(.text(text))
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
    let tools: [Tool]?
}

private struct Tool: Codable, Sendable {
    let google_search: GoogleSearchTool
}

private struct GoogleSearchTool: Codable, Sendable {}

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
    var parts: [Part]
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
