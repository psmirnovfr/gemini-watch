import AppIntents
import Foundation

/// Powers the "press Action button → talk → text reply" flow.
///
/// Build a Shortcut with: Dictate Text → Ask Gemini (this intent, fed the
/// dictated text) → Show Result. Assign that Shortcut to the Action button
/// in Watch Settings → Action Button → Shortcut. `requestValueDialog` also
/// lets the intent be assigned directly without a Dictate Text step — the
/// system will prompt for the question itself when none is supplied.
struct AskGeminiIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask Gemini"
    static var description = IntentDescription(
        "Send a question to Gemini and get a short text reply — built for the Action button."
    )

    /// Runs headless so a quick Action-button question never has to open the app UI.
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Question", requestValueDialog: "What do you want to ask Gemini?")
    var question: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask Gemini: \(\.$question)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let settings = PersistenceManager.shared.loadSettings()
        let service = GeminiService()
        var responseText = ""

        do {
            let stream = await service.streamGenerateContent(
                messages: [Message(role: .user, text: question)],
                model: settings.modelName,
                systemPrompt: settings.systemPrompt,
                temperature: settings.temperature,
                enableWebSearch: settings.webSearchEnabled
            )
            for try await event in stream {
                if case .text(let chunk) = event {
                    responseText += chunk
                }
            }
        } catch {
            responseText = error.localizedDescription
        }

        if responseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            responseText = "No response. Try again."
        }

        saveAsConversation(question: question, answer: responseText)

        return .result(value: responseText)
    }

    /// Quick Asks land in one rolling "Quick Ask" conversation so an
    /// Action-button question is never lost, even though its own UI never opens.
    private func saveAsConversation(question: String, answer: String) {
        let quickAskTitle = "Quick Ask (Action Button)"
        let metadata = PersistenceManager.shared.loadConversationsMetadata()

        var conversation: Conversation
        if let existingMeta = metadata.first(where: { $0.title == quickAskTitle }),
           let existing = PersistenceManager.shared.loadConversation(id: existingMeta.id) {
            conversation = existing
        } else {
            conversation = Conversation(title: quickAskTitle)
        }

        conversation.messages.append(Message(role: .user, text: question))
        conversation.messages.append(Message(role: .model, text: answer))
        conversation.updatedAt = Date()

        PersistenceManager.shared.saveConversation(conversation)
    }
}

/// Registers "Ask Gemini" as a discoverable App Shortcut so it shows up
/// directly in the Shortcuts app gallery for the app — and can be assigned
/// to the Action button without the user having to build a Shortcut first.
struct GeminiWatchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskGeminiIntent(),
            phrases: [
                "Ask \(.applicationName) \(\.$question)",
                "Ask \(.applicationName) a question"
            ],
            shortTitle: "Ask Gemini",
            systemImageName: "sparkles"
        )
    }
}
