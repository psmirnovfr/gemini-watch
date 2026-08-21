import AppIntents
import Foundation

/// Powers the "press Action button → talk → read the reply" flow.
///
/// Build a Shortcut with: Dictate Text → Ask Gemini (fed the dictated text),
/// then assign it to the Action button in Watch Settings → Action Button →
/// Shortcut. `requestValueDialog` also lets the intent be assigned on its own —
/// the system prompts for the question when none is supplied.
///
/// The intent deliberately does **not** run the request itself. Shortcuts'
/// "Show Result" card is text-only — it can't carry the Continue and Smart
/// buttons — so the intent hands the question to `QuickAskRouter` and opens the
/// app, which streams the answer into `QuickAskView`.
struct AskGeminiIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask Gemini"
    static var description = IntentDescription(
        "Ask Gemini a question and read the reply on your watch, with follow-up options."
    )

    /// The answer needs scrollable text plus buttons, which only the app can draw.
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Question", requestValueDialog: "What do you want to ask Gemini?")
    var question: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask Gemini: \(\.$question)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        QuickAskRouter.shared.submit(question: question)
        return .result()
    }
}

/// Registers "Ask Gemini" as a discoverable App Shortcut so it appears in the
/// Shortcuts app gallery for the app — and can be assigned to the Action button
/// without the user having to build a Shortcut from scratch first.
struct GeminiWatchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskGeminiIntent(),
            phrases: [
                "Ask \(.applicationName) \(\.$question)",
                "Ask \(.applicationName) a question"
            ],
            shortTitle: "Ask Gemini",
            systemImageName: "sparkle"
        )
    }
}
