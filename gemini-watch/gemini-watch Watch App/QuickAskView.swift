import SwiftUI
import WatchKit

/// The screen you land on after pressing the Action button and speaking.
///
/// Deliberately read-only and silent: the answer arrives as scrollable text
/// (the Digital Crown scrolls it), never as speech. Everything below the answer
/// is an exit into the full chat — "Smart" re-asks the same context with the
/// better model, "Continue" opens the conversation in `ContentView`, and the
/// suggestion chips do both at once (open the chat, having sent the follow-up).
struct QuickAskView: View {
    let request: QuickAskRequest
    /// Hands the conversation to the parent so it can push `ContentView`.
    /// `followUp` is sent as a new message once the chat opens.
    var onContinue: (UUID, String?) -> Void
    var onDismiss: () -> Void

    @StateObject private var viewModel = ChatViewModel()
    @State private var didStart = false
    @EnvironmentObject private var settingsStore: AppSettingsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                questionHeader

                if let error = viewModel.errorMessage {
                    errorBlock(error)
                } else {
                    answerBlock
                }

                if !viewModel.isGenerating && viewModel.errorMessage == nil && hasAnswer {
                    actionButtons

                    if settingsStore.settings.suggestionsEnabled && !viewModel.suggestions.isEmpty {
                        followUpChips
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 10)
        }
        .navigationTitle("Ask Gemini")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if viewModel.isGenerating {
                    Button {
                        viewModel.stopGeneration()
                        if settingsStore.settings.hapticsEnabled {
                            WKInterfaceDevice.current().play(.stop)
                        }
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    .accessibilityLabel("Stop generating")
                } else {
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
        .onAppear {
            viewModel.configure(settingsStore: settingsStore)
            // Guard against re-entry: the cover can re-appear and must never
            // fire a second request for the same question.
            guard !didStart else { return }
            didStart = true
            QuickAskRouter.shared.markDelivered()
            viewModel.startQuickAsk(request.question)
        }
    }

    private var hasAnswer: Bool {
        viewModel.messages.contains { $0.role == .model && !$0.text.isEmpty }
    }

    // MARK: - Question

    private var questionHeader: some View {
        HStack(alignment: .top, spacing: 4) {
            Image(systemName: "mic.fill")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
            Text(request.question)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 2)
    }

    // MARK: - Answer

    @ViewBuilder
    private var answerBlock: some View {
        if let reply = viewModel.messages.last(where: { $0.role == .model }) {
            VStack(alignment: .leading, spacing: 4) {
                MarkdownContent(
                    text: reply.text,
                    isStreaming: viewModel.streamingMessageId == reply.id
                )

                if let sources = reply.sources, !sources.isEmpty {
                    Text("\(sources.count) source\(sources.count == 1 ? "" : "s") · open in chat")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }

                if let modelName = reply.modelName {
                    Text(modelName.shortModelLabel)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if viewModel.isLoading {
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.7)
                Text("Thinking…")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
        }
    }

    private func errorBlock(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(error)
                .font(.system(size: 10))
                .foregroundStyle(.red)

            Button("Retry") {
                viewModel.retry()
            }
            .font(.system(size: 10, weight: .medium))
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.mini)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Actions

    private var actionButtons: some View {
        VStack(spacing: 4) {
            if viewModel.canEscalateToSmartModel {
                Button {
                    if settingsStore.settings.hapticsEnabled {
                        WKInterfaceDevice.current().play(.click)
                    }
                    viewModel.escalateToSmartModel()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkle")
                            .font(.system(size: 10))
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Smart")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Re-ask \(viewModel.smartModelLabel)")
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.white.opacity(0.1))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(GeminiBrand.gradient, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Ask the smarter model, \(viewModel.smartModelLabel)")
            }

            Button {
                if settingsStore.settings.hapticsEnabled {
                    WKInterfaceDevice.current().play(.click)
                }
                if let id = viewModel.conversationId {
                    onContinue(id, nil)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 10))
                    Text("Continue")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.blue.opacity(0.35))
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Continue this chat in the app")
        }
        .padding(.top, 2)
    }

    // MARK: - Follow-ups

    private var followUpChips: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(viewModel.suggestions, id: \.self) { suggestion in
                Button {
                    if settingsStore.settings.hapticsEnabled {
                        WKInterfaceDevice.current().play(.click)
                    }
                    if let id = viewModel.conversationId {
                        onContinue(id, suggestion)
                    }
                } label: {
                    Text(suggestion)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.2))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity)
    }
}
