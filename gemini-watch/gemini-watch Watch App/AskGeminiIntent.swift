import AppIntents
import Foundation

/// Powers the "press Action button → talk → read the reply" flow.
///
/// Assign it to the Action button in Watch Settings → Action Button → Shortcut.
/// The `question` parameter decides who does the speech recognition:
///
/// - **Left empty** (a Shortcut that is just this action): the app records your
///   voice and sends the audio to Gemini, which transcribes and answers in one
///   request. Better with accents and code-switching than on-device dictation.
/// - **Filled in** (Dictate Text → Ask Gemini): watchOS transcribes first and
///   only text is sent. Faster and smaller, but limited to whatever language
///   dictation is currently set to.
///
/// The intent deliberately does **not** run the request itself. Shortcuts'
/// "Show Result" card is text-only — it can't carry the Continue and Smart
/// buttons — so the intent hands off to `QuickAskRouter` and opens the app,
/// which streams the answer into `QuickAskView`.
struct AskGeminiIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask Gemini"
    static var description = IntentDescription(
        "Ask Gemini a question and read the reply on your watch. Leave the question empty to speak it instead."
    )

    /// The answer needs scrollable text plus buttons, which only the app can draw.
    static var openAppWhenRun: Bool = true

    /// Optional on purpose: an empty question is the signal to record instead
    /// of prompting, which is what keeps the voice flow at zero taps.
    @Parameter(title: "Question")
    var question: String?

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
                "Ask \(.applicationName)",
                "Ask \(.applicationName) a question"
            ],
            shortTitle: "Ask Gemini",
            systemImageName: "sparkle"
        )
    }
}
