import Foundation
import SwiftUI
import Combine
import UserNotifications
import WatchKit

@MainActor
class ChatViewModel: ObservableObject {

    @Published var messages: [Message] = []
    @Published var isLoading = false
    @Published var errorMessage: String? 
    @Published var editingMessageId: UUID? = nil
    @Published var suggestions: [String] = []
    /// ID of the message currently being streamed — used to show a typing cursor.
    @Published var streamingMessageId: UUID? = nil
    /// Model that produced the newest reply, so the UI can badge it and decide
    /// whether escalating to the smart model would actually change anything.
    @Published var lastResponseModel: String? = nil

    private let geminiService: GeminiService
    private let persistence: PersistenceManager
    private var streamTask: Task<Void, Never>?

    /// Injected settings store — avoids repeated disk reads on every request (#5).
    private weak var settingsStore: AppSettingsStore?

    init(geminiService: GeminiService = GeminiService(),
         persistence: PersistenceManager = PersistenceManager.shared,
         settingsStore: AppSettingsStore? = nil) {
        self.geminiService = geminiService
        self.persistence = persistence
        self.settingsStore = settingsStore
    }

    /// Called from ContentView.onAppear after the view environment is available.
    func configure(settingsStore: AppSettingsStore) {
        self.settingsStore = settingsStore
    }

    // Debounce onUpdate so the conversation list doesn't reload on every streaming chunk
    private var updateWorkItem: DispatchWorkItem?

    var conversationId: UUID?

    // MARK: - Conversation Management

    func loadConversation(id: UUID) {
        if let convo = persistence.loadConversation(id: id) {
            conversationId = convo.id
            messages = convo.messages
        } else {
            conversationId = id
            messages = []
        }
        errorMessage = nil
        isLoading = false
        suggestions = []
        streamingMessageId = nil
        lastResponseModel = messages.last(where: { $0.role == .model })?.modelName
    }

    /// Entry point for the Action-button flow: opens a brand-new conversation
    /// seeded with the dictated question and immediately starts streaming.
    /// Kept separate from `resetChat` + `sendMessage` so the conversation is
    /// created and titled in one pass, before any UI observes an empty state.
    func startQuickAsk(_ question: String) {
        beginQuickAskConversation()
        sendMessage(question)
    }

    /// Voice variant: the question is a recording rather than text, so Gemini
    /// transcribes and answers in a single request. The user message starts
    /// empty and is backfilled with the transcript as it streams in.
    func startVoiceAsk(audioURL: URL, mimeType: String) {
        beginQuickAskConversation()

        guard let attachment = AudioAttachment(fileURL: audioURL, mimeType: mimeType) else {
            errorMessage = "Couldn't read the recording."
            return
        }

        let placeholder = Message(role: .user, text: "")
        messages = [placeholder]
        voiceMessageId = placeholder.id
        processRequest(audio: attachment)
    }

    private func beginQuickAskConversation() {
        streamTask?.cancel()
        streamTask = nil
        errorMessage = nil
        editingMessageId = nil
        suggestions = []
        streamingMessageId = nil
        lastResponseModel = nil
        voiceMessageId = nil
        messages = []

        let newConvo = Conversation()
        conversationId = newConvo.id
        persistence.saveConversation(newConvo)
    }

    func resetChat() {
        streamTask?.cancel()
        streamTask = nil
        messages = []
        errorMessage = nil
        isLoading = false
        editingMessageId = nil
        suggestions = []
        streamingMessageId = nil
        lastResponseModel = nil

        let newConvo = Conversation()
        conversationId = newConvo.id
        persistence.saveConversation(newConvo)
    }

    // MARK: - Messaging

    func sendMessage(_ text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        let userMessage = Message(role: .user, text: trimmedText)
        messages.append(userMessage)
        suggestions = []
        persistCurrentState()
        processRequest()
    }

    func editMessage(id: UUID, newText: String) {
        let trimmedText = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty,
              let index = messages.firstIndex(where: { $0.id == id }),
              messages[index].role == .user else { return }
        messages[index].text = trimmedText

        // Editing rewinds the conversation to that point. Keeping later turns
        // would attach replies generated from the old prompt to the new branch.
        if index + 1 < messages.count {
            messages.removeSubrange((index + 1)..<messages.endIndex)
        }

        suggestions = []
        persistCurrentState()
        processRequest()
        editingMessageId = nil
    }

    // MARK: - Streaming

    func retry() {
        // A failed stream may have left a partial model response. Remove it so
        // Gemini receives a conversation ending in the user's prompt.
        if messages.last?.role == .model {
            messages.removeLast()
        }
        processRequest()
    }

    /// Cancel an in-flight stream and surface whatever was generated so far.
    func stopGeneration() {
        streamTask?.cancel()
        streamTask = nil
        isLoading = false
        streamingMessageId = nil
        // A stopped stream still leaves a usable partial reply, so record which
        // model produced it — otherwise "Smart" can't tell it has work to do.
        lastResponseModel = messages.last(where: { $0.role == .model })?.modelName
        persistCurrentState()
    }

    /// Drop the last model response and re-request. Called from the "Regenerate"
    /// context-menu action on a model message.
    func regenerateLast() {
        streamTask?.cancel()
        if let last = messages.last, last.role == .model {
            messages.removeLast()
        }
        suggestions = []
        processRequest()
    }

    /// Whether a stream is currently producing tokens.
    var isGenerating: Bool {
        isLoading || streamingMessageId != nil
    }

    // MARK: - Smart Escalation

    private var currentSettings: AppSettings {
        settingsStore?.settings ?? persistence.loadSettings()
    }

    /// True when the latest reply came from the cheap model and re-running the
    /// same context through the smart model would actually produce something new.
    var canEscalateToSmartModel: Bool {
        let settings = currentSettings
        guard !isGenerating,
              !settings.smartModelName.isEmpty,
              messages.contains(where: { $0.role == .model }) else { return false }
        return lastResponseModel != settings.smartModelName
    }

    var smartModelLabel: String {
        currentSettings.smartModelName.shortModelLabel
    }

    /// Drop the cheap reply and re-send the *whole* conversation to the smart
    /// model. One extra request, on demand — the escape hatch for when the
    /// lite-tier answer isn't good enough.
    func escalateToSmartModel() {
        let smartModel = currentSettings.smartModelName
        guard !smartModel.isEmpty else { return }

        streamTask?.cancel()
        if messages.last?.role == .model {
            messages.removeLast()
        }
        suggestions = []
        processRequest(modelOverride: smartModel)
    }

    // MARK: - Voice Turns

    /// The user message awaiting a transcript, if this turn started as audio.
    private var voiceMessageId: UUID?

    /// Appended to the user's own system prompt for voice turns. Asking for the
    /// transcript on the first line means it streams in before the answer — the
    /// user sees what Gemini heard almost immediately, which is the confirmation
    /// Apple's dictation sheet used to provide.
    private static let voiceInstruction = """

        The user's message is spoken audio. Reply in exactly this shape:
        First line: `TRANSCRIPT: ` followed by a verbatim transcript of what \
        the user said, in the language they said it. Then a blank line. Then \
        your answer, following all the formatting rules above.
        """

    /// Guard against a model that ignores the format — don't withhold the
    /// answer forever waiting for a first line that will never come.
    private static let transcriptGiveUpLength = 400

    private func applyTranscript(_ transcript: String) {
        defer { voiceMessageId = nil }
        guard let id = voiceMessageId,
              let index = messages.firstIndex(where: { $0.id == id }) else { return }

        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        messages[index].text = cleaned.isEmpty ? "🎤 Voice message" : cleaned
    }

    private func processRequest(modelOverride: String? = nil, audio: AudioAttachment? = nil) {
        streamTask?.cancel()
        isLoading = true
        errorMessage = nil

        // Read from the injected store (reactive, no disk I/O) or fall back (#5)
        let settings = settingsStore?.settings ?? persistence.loadSettings()
        let requestModel = modelOverride ?? settings.modelName
        let isVoiceTurn = audio != nil
        let systemPrompt = isVoiceTurn
            ? settings.systemPrompt + Self.voiceInstruction
            : settings.systemPrompt

        // Subtle "request sent" cue — matches Google's own Gemini apps.
        if settings.hapticsEnabled {
            WKInterfaceDevice.current().play(.start)
        }

        streamTask = Task {
            var fullResponse = ""
            var messageIndex: Int? = nil
            var lastUpdate = Date()
            var latestSources: [GroundingSource] = []
            // Voice turns prepend a TRANSCRIPT line; hold text back until that
            // line resolves so it never leaks into the visible answer.
            var transcriptBuffer = ""
            var transcriptResolved = !isVoiceTurn

            do {
                let stream = await geminiService.streamGenerateContent(
                    messages: messages,
                    model: requestModel,
                    systemPrompt: systemPrompt,
                    temperature: settings.temperature,
                    enableWebSearch: settings.webSearchEnabled,
                    audio: audio
                )
                for try await event in stream {
                    if Task.isCancelled { return }

                    switch event {
                    case .sources(let sources):
                        latestSources = sources
                        if let idx = messageIndex {
                            messages[idx].sources = sources
                        }

                    case .text(let chunk):
                        if !transcriptResolved {
                            transcriptBuffer += chunk
                            if let newline = transcriptBuffer.firstIndex(of: "\n") {
                                let firstLine = String(transcriptBuffer[..<newline])
                                    .trimmingCharacters(in: .whitespaces)
                                let remainder = String(transcriptBuffer[transcriptBuffer.index(after: newline)...])

                                if let range = firstLine.range(of: "TRANSCRIPT:", options: .caseInsensitive) {
                                    applyTranscript(String(firstLine[range.upperBound...]))
                                    // Drop the blank separator line so the
                                    // answer doesn't render with a leading gap.
                                    fullResponse += remainder.drop(while: \.isNewline)
                                } else {
                                    // Model ignored the format — keep every
                                    // token as answer rather than losing it.
                                    applyTranscript("")
                                    fullResponse += transcriptBuffer
                                }
                                transcriptResolved = true
                                transcriptBuffer = ""
                            } else if transcriptBuffer.count > Self.transcriptGiveUpLength {
                                applyTranscript("")
                                fullResponse += transcriptBuffer
                                transcriptResolved = true
                                transcriptBuffer = ""
                            } else {
                                continue
                            }
                        } else {
                            fullResponse += chunk
                        }
                        let now = Date()
                        if !fullResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            if messageIndex == nil || now.timeIntervalSince(lastUpdate) > 0.1 {
                                isLoading = false
                                if messageIndex == nil {
                                    let modelMessage = Message(role: .model, text: fullResponse, sources: latestSources.isEmpty ? nil : latestSources, modelName: requestModel)
                                    messages.append(modelMessage)
                                    messageIndex = messages.count - 1
                                    streamingMessageId = modelMessage.id
                                } else {
                                    messages[messageIndex!].text = fullResponse
                                }
                                lastUpdate = now
                            }
                        }
                    }
                }

                // A short reply can end before any newline arrives — flush what
                // was held back rather than dropping it.
                if !transcriptResolved {
                    if let range = transcriptBuffer.range(of: "TRANSCRIPT:", options: .caseInsensitive) {
                        applyTranscript(String(transcriptBuffer[range.upperBound...]))
                    } else {
                        applyTranscript("")
                        fullResponse += transcriptBuffer
                    }
                    transcriptResolved = true
                    transcriptBuffer = ""
                }

                // Final update
                if !fullResponse.isEmpty {
                    if let idx = messageIndex {
                        messages[idx].text = fullResponse
                        if !latestSources.isEmpty {
                            messages[idx].sources = latestSources
                        }
                    } else {
                        let msg = Message(role: .model, text: fullResponse, sources: latestSources.isEmpty ? nil : latestSources, modelName: requestModel)
                        messages.append(msg)
                    }
                    lastResponseModel = requestModel
                }

                streamingMessageId = nil
                isLoading = false
                persistCurrentState()

                if fullResponse.isEmpty {
                    errorMessage = "No response. Try again."
                } else {
                    if settings.hapticsEnabled,
                       WKExtension.shared().applicationState == .active {
                        WKInterfaceDevice.current().play(.success)
                    }

                    // Schedule local notification if app is backgrounded (#15)
                    scheduleReplyNotificationIfNeeded()

                    if settings.suggestionsEnabled {
                        generateSuggestions()
                    }
                }
            } catch {
                streamingMessageId = nil
                // Don't strand a voice turn behind an empty user bubble — a
                // failed upload must still leave something retryable on screen.
                if !transcriptResolved {
                    applyTranscript("")
                }
                if !Task.isCancelled {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

    // MARK: - Suggestions

    private func generateSuggestions() {
        guard let lastModel = messages.last(where: { $0.role == .model }) else { return }
        let text = lastModel.text.lowercased()

        if text.contains("```") || text.contains("func ") || text.contains("var ") || text.contains("class ") {
            suggestions = ["Explain this code", "Show an example", "How do I use this?"]
        } else if text.contains("• ") || text.contains("1.") || text.contains("step") {
            suggestions = ["Tell me more", "Summarize this", "Why?"]
        } else if text.hasSuffix("?") || text.contains("you can") || text.contains("you could") {
            suggestions = ["Yes, do it", "Explain further", "Give an example"]
        } else {
            suggestions = ["Explain more", "Simplify", "Give an example"]
        }
    }

    // MARK: - Local Notification (#15)

    private func scheduleReplyNotificationIfNeeded() {
        guard WKExtension.shared().applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = "Gemini replied"
        content.body = messages.last(where: { $0.role == .model })?.text.prefix(80).description ?? "New response ready."
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Persistence

    func scheduleUpdate(_ onUpdate: (() -> Void)?) {
        updateWorkItem?.cancel()
        let item = DispatchWorkItem { onUpdate?() }
        updateWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    private func persistCurrentState() {
        guard let id = conversationId else { return }
        var convo = Conversation(id: id, messages: messages)
        convo.updatedAt = Date()
        convo.autoTitle()

        if let existing = persistence.loadConversationsMetadata().first(where: { $0.id == id }) {
            convo.createdAt = existing.createdAt
            convo.isPinned = existing.isPinned
        }

        persistence.saveConversation(convo)
    }
}
