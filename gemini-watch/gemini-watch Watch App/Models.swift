import Foundation

enum MessageRole: String, Codable {
    case user
    case model
}

struct GroundingSource: Codable, Equatable, Hashable, Identifiable {
    let uri: String
    let title: String

    var id: String { uri }
}

struct Message: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    let role: MessageRole
    var text: String
    let createdAt: Date
    /// Web-search grounding sources attached to this response, if any.
    /// Optional so older persisted messages (without the field) still decode.
    var sources: [GroundingSource]?
    /// Which Gemini model produced this reply. Optional for the same
    /// decode-compatibility reason, and always nil for user messages.
    var modelName: String?

    init(id: UUID = UUID(),
         role: MessageRole,
         text: String,
         createdAt: Date = Date(),
         sources: [GroundingSource]? = nil,
         modelName: String? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.sources = sources
        self.modelName = modelName
    }
}

extension String {
    /// Trims the redundant `gemini-` prefix for compact watch labels.
    var shortModelLabel: String {
        replacingOccurrences(of: "gemini-", with: "")
    }
}

struct Conversation: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [Message]
    var isPinned: Bool

    init(id: UUID = UUID(), title: String = "New Chat", messages: [Message] = [], isPinned: Bool = false) {
        self.id = id
        self.title = title
        self.createdAt = Date()
        self.updatedAt = Date()
        self.messages = messages
        self.isPinned = isPinned
    }

    /// Auto-generate title from first user message
    mutating func autoTitle() {
        if let first = messages.first(where: { $0.role == .user }) {
            let raw = first.text.prefix(40)
            title = raw.count < first.text.count ? "\(raw)…" : String(raw)
        }
    }
}

struct ConversationMetadata: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var isPinned: Bool

    init(id: UUID, title: String, createdAt: Date, updatedAt: Date, isPinned: Bool = false) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isPinned = isPinned
    }
}

struct AppSettings: Codable, Equatable {
    /// The everyday model. Defaults to a cheap "lite" tier so a free AI Studio
    /// key can absorb one request per message without burning quota.
    var modelName: String
    var speechRate: Float
    var hapticsEnabled: Bool
    var suggestionsEnabled: Bool
    var systemPrompt: String
    var temperature: Double
    /// How many search queries the cheap model writes when you tap Search.
    /// More angles cost more Tavily credits — one per query.
    var searchQueryCount: Int
    /// The escalation model behind the "Smart" button — used only when the
    /// cheap answer isn't good enough, so it stays a deliberate, occasional cost.
    var smartModelName: String

    // Codable back-compat — older persisted settings don't have the newer keys.
    private enum CodingKeys: String, CodingKey {
        case modelName, speechRate, hapticsEnabled, suggestionsEnabled
        case systemPrompt, temperature, searchQueryCount, smartModelName
    }

    init(modelName: String,
         speechRate: Float,
         hapticsEnabled: Bool,
         suggestionsEnabled: Bool,
         systemPrompt: String,
         temperature: Double,
         searchQueryCount: Int = AppSettings.defaultSearchQueryCount,
         smartModelName: String = AppSettings.defaultSmartModel) {
        self.modelName = modelName
        self.speechRate = speechRate
        self.hapticsEnabled = hapticsEnabled
        self.suggestionsEnabled = suggestionsEnabled
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.searchQueryCount = searchQueryCount
        self.smartModelName = smartModelName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modelName = try c.decode(String.self, forKey: .modelName)
        speechRate = try c.decode(Float.self, forKey: .speechRate)
        hapticsEnabled = try c.decode(Bool.self, forKey: .hapticsEnabled)
        suggestionsEnabled = try c.decode(Bool.self, forKey: .suggestionsEnabled)
        systemPrompt = try c.decode(String.self, forKey: .systemPrompt)
        temperature = try c.decode(Double.self, forKey: .temperature)
        searchQueryCount = try c.decodeIfPresent(Int.self, forKey: .searchQueryCount)
            ?? AppSettings.defaultSearchQueryCount
        smartModelName = try c.decodeIfPresent(String.self, forKey: .smartModelName) ?? AppSettings.defaultSmartModel
    }

    static let defaultSystemPrompt = "You are a helpful AI assistant. Be very concise — use short sentences, bullet points, and bold key terms. Avoid long paragraphs. Format for tiny screens."

    /// Both defaults are editable in Settings from the live model list, so a
    /// changed model lineup is a two-tap fix rather than a code change.
    static let defaultFastModel = "gemini-3.5-flash-lite"
    static let defaultSmartModel = "gemini-3.7-flash"

    static let defaultSearchQueryCount = 3
    static let searchQueryCountRange = 1...5

    static let `default` = AppSettings(
        modelName: defaultFastModel,
        speechRate: 0.5,
        hapticsEnabled: true,
        suggestionsEnabled: true,
        systemPrompt: defaultSystemPrompt,
        temperature: 0.7,
        searchQueryCount: defaultSearchQueryCount,
        smartModelName: defaultSmartModel
    )
}
