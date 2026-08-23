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
    @StateObject private var recorder = VoiceRecorder()
    @State private var didStart = false
    @State private var isFollowUpRecording = false
    @EnvironmentObject private var settingsStore: AppSettingsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if isRecording {
                    micIndicator
                } else {
                    questionHeader
                }

                if let error = recordingError {
                    errorBlock(error, retry: {
                        if isFollowUpRecording { startFollowUpVoiceCapture() }
                        else { startVoiceCapture() }
                    })
                } else if let error = viewModel.errorMessage {
                    errorBlock(error, retry: viewModel.retry)
                } else if !isRecording {
                    answerBlock
                }

                if !isRecording && !viewModel.isGenerating && viewModel.errorMessage == nil && hasAnswer {
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
                if isRecording {
                    // No stop button by design — the recorder ends on its own
                    // when you stop talking. This only backs out entirely.
                    Button {
                        recorder.cancel()
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Cancel")
                } else if viewModel.isGenerating {
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
            // fire a second request — or a second recording — for the same ask.
            guard !didStart else { return }
            didStart = true
            QuickAskRouter.shared.markDelivered()

            if let question = request.question, !question.isEmpty {
                viewModel.startQuickAsk(question)
            } else {
                startVoiceCapture()
            }
        }
        // The recorder ends the take itself; that's the cue to send.
        .onChange(of: recorder.state) {
            guard case .finished(let url) = recorder.state else { return }
            if settingsStore.settings.hapticsEnabled {
                WKInterfaceDevice.current().play(.click)
            }
            if isFollowUpRecording {
                viewModel.sendVoiceMessage(audioURL: url, mimeType: VoiceRecorder.mimeType)
            } else {
                viewModel.startVoiceAsk(audioURL: url, mimeType: VoiceRecorder.mimeType)
            }
            recorder.discardRecording()
        }
        .onDisappear {
            recorder.cancel()
        }
    }

    // MARK: - Recording

    /// Covers permission, session activation and the live take — the recorder
    /// owns the whole screen for all of it, so there is never a blank frame.
    private var isRecording: Bool { recorder.state.isBusy }

    private var recordingError: String? {
        if case .failed(let message) = recorder.state { return message }
        return nil
    }

    private func startVoiceCapture() {
        isFollowUpRecording = false
        Task { await recorder.start() }
    }

    /// The mic button: another spoken question, keeping this conversation's
    /// context rather than starting fresh.
    private func startFollowUpVoiceCapture() {
        isFollowUpRecording = true
        Task { await recorder.start() }
    }

    private var hasAnswer: Bool {
        viewModel.messages.contains { $0.role == .model && !$0.text.isEmpty }
    }

    // MARK: - Mic

    /// Shown while the mic is live. Deliberately has no controls — the take
    /// ends on its own, so there is nothing here to tap.
    private var micIndicator: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(GeminiBrand.gradient)
                    .opacity(recorder.state == .preparing ? 0.2 : 0.25 + 0.5 * recorder.level)
                    .frame(width: 46 + CGFloat(recorder.level) * 16)
                Image(systemName: "mic.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(height: 66)
            .animation(.easeOut(duration: 0.12), value: recorder.level)

            Text(micHeadline)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            if recorder.state != .preparing {
                Text("Stops when you do")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(recorder.state == .preparing
            ? "Preparing the microphone."
            : "Listening. Recording stops automatically when you stop speaking.")
    }

    private var micHeadline: String {
        switch recorder.state {
        case .preparing: return "Getting ready…"
        case .capturing: return "Listening…"
        default:         return "Speak now"
        }
    }

    // MARK: - Question

    @ViewBuilder
    private var questionHeader: some View {
        // For a voice ask this is the transcript Gemini returned, so it doubles
        // as confirmation of what was actually heard.
        let asked = viewModel.messages.first(where: { $0.role == .user })?.text
            ?? request.question
            ?? ""

        if !asked.isEmpty {
            HStack(alignment: .top, spacing: 4) {
                Image(systemName: request.isVoice ? "waveform" : "text.bubble")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
                Text(asked)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 2)
        }
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
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7)
                    Text(viewModel.searchStatus ?? "Thinking…")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                // Showing the generated queries makes it obvious what was
                // actually searched, and why an answer came back the way it did.
                ForEach(viewModel.searchQueries, id: \.self) { query in
                    Text("• \(query)")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
        }
    }

    private func errorBlock(_ error: String, retry: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(error)
                .font(.system(size: 10))
                .foregroundStyle(.red)

            Button("Retry", action: retry)
                .font(.system(size: 10, weight: .medium))
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.mini)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Actions

    /// A 2x2 grid of icon buttons. Icons carry the meaning at this size — a row
    /// of four would leave each target too narrow on a 40mm screen, and full
    /// text labels would push the answer off the top.
    private var actionButtons: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                if viewModel.isSearchAvailable {
                    actionButton(
                        icon: "magnifyingglass",
                        label: "Search",
                        tint: Color.green.opacity(0.3),
                        enabled: viewModel.canSearch,
                        hint: "Search the web and answer from the results"
                    ) {
                        viewModel.searchAndAnswer()
                    }
                }

                actionButton(
                    icon: "brain",
                    label: "Smart",
                    tint: Color.white.opacity(0.12),
                    enabled: viewModel.canEscalateToSmartModel,
                    bordered: true,
                    hint: "Re-ask the smarter model, \(viewModel.smartModelLabel)"
                ) {
                    viewModel.escalateToSmartModel()
                }
            }

            HStack(spacing: 4) {
                actionButton(
                    icon: "mic.fill",
                    label: "Ask",
                    tint: Color.white.opacity(0.12),
                    hint: "Record a new question"
                ) {
                    startFollowUpVoiceCapture()
                }

                actionButton(
                    icon: "bubble.left.and.bubble.right.fill",
                    label: "Chat",
                    tint: Color.blue.opacity(0.35),
                    hint: "Continue this chat in the app"
                ) {
                    if let id = viewModel.conversationId {
                        onContinue(id, nil)
                    }
                }
            }
        }
        .padding(.top, 2)
    }

    private func actionButton(
        icon: String,
        label: String,
        tint: Color,
        enabled: Bool = true,
        bordered: Bool = false,
        hint: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            if settingsStore.settings.hapticsEnabled {
                WKInterfaceDevice.current().play(.click)
            }
            action()
        } label: {
            VStack(spacing: 1) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                Text(label)
                    .font(.system(size: 9, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10).fill(tint))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(bordered ? AnyShapeStyle(GeminiBrand.gradient) : AnyShapeStyle(Color.clear),
                                  lineWidth: 1)
            )
            .opacity(enabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(hint)
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
