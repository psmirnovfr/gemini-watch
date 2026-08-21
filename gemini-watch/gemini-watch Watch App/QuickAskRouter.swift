import Foundation
import Combine

/// A single Action-button ask, waiting to be shown.
struct QuickAskRequest: Identifiable, Equatable {
    let id: UUID
    /// Nil when the Shortcut supplied no text — the app records instead and
    /// lets Gemini do the transcription.
    let question: String?

    init(id: UUID = UUID(), question: String?) {
        self.id = id
        self.question = question
    }

    var isVoice: Bool { (question ?? "").isEmpty }
}

/// Hands the dictated question from `AskGeminiIntent` to the UI.
///
/// `perform()` can run before SwiftUI has mounted anything, so the request is
/// also mirrored to UserDefaults: whichever side wins the race, the question
/// still gets picked up. The in-memory path covers the app-already-running
/// case; the persisted path covers a cold launch.
@MainActor
final class QuickAskRouter: ObservableObject {
    static let shared = QuickAskRouter()

    @Published var request: QuickAskRequest?

    private let defaults = UserDefaults.standard
    private let pendingKey = "pending_quick_ask"
    /// Marks a pending voice ask, which has no text to store.
    private static let voiceSentinel = "\u{0}voice"

    private init() {}

    /// Called from the App Intent. A nil or empty question means "record it".
    func submit(question: String?) {
        let trimmed = (question ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(trimmed.isEmpty ? Self.voiceSentinel : trimmed, forKey: pendingKey)
        request = QuickAskRequest(question: trimmed.isEmpty ? nil : trimmed)
    }

    /// Called by the root view on appear, to catch an ask that arrived before
    /// the UI existed.
    func consumePendingIfNeeded() {
        guard request == nil,
              let pending = defaults.string(forKey: pendingKey),
              !pending.isEmpty else { return }
        request = QuickAskRequest(question: pending == Self.voiceSentinel ? nil : pending)
    }

    /// Called once the question is actually on screen. Drops only the persisted
    /// copy, so a later cold launch doesn't replay an ask that was already
    /// answered — the live request stays put until the user dismisses it.
    func markDelivered() {
        defaults.removeObject(forKey: pendingKey)
    }

    /// Dismisses the Quick Ask screen.
    func clear() {
        defaults.removeObject(forKey: pendingKey)
        request = nil
    }
}
