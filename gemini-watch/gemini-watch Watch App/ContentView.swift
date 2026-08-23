import SwiftUI
import WatchKit

struct ContentView: View {
    @StateObject private var viewModel: ChatViewModel
    @State private var inputText = ""
    @State private var didLoad = false
    @FocusState private var isInputFocused: Bool

    @EnvironmentObject private var settingsStore: AppSettingsStore
    @EnvironmentObject private var speaker: Speaker
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let conversationId: UUID
    /// Sent automatically once the conversation loads — used when a Quick Ask
    /// follow-up chip opens the chat.
    var initialMessage: String?
    var onUpdate: (() -> Void)?

    init(conversationId: UUID, initialMessage: String? = nil, onUpdate: (() -> Void)? = nil) {
        self.conversationId = conversationId
        self.initialMessage = initialMessage
        self.onUpdate = onUpdate
        // ViewModel created here; settingsStore injected after init via configure()
        _viewModel = StateObject(wrappedValue: ChatViewModel())
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // MARK: - Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        if viewModel.messages.isEmpty {
                            emptyState
                        }

                        ForEach(viewModel.messages) { msg in
                            HStack {
                                if msg.role == .user { Spacer(minLength: 16) }

                                MessageView(
                                    message: msg,
                                    isStreaming: viewModel.streamingMessageId == msg.id,
                                    onRegenerate: (msg.role == .model && msg.id == viewModel.messages.last?.id && !viewModel.isGenerating)
                                        ? { viewModel.regenerateLast() }
                                        : nil
                                )
                                .onLongPressGesture {
                                    guard msg.role == .user else { return }
                                    if settingsStore.settings.hapticsEnabled {
                                        WKInterfaceDevice.current().play(.click)
                                    }
                                    inputText = msg.text
                                    viewModel.editingMessageId = msg.id
                                    isInputFocused = true
                                }
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                            }
                            .padding(.horizontal, 3)
                            .id(msg.id)
                        }

                        // Loading indicator
                        if viewModel.isLoading {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .scaleEffect(0.7)
                                if let query = viewModel.searchQuery {
                                    Text("Searching “\(query)”…")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                } else {
                                    Text("Thinking…")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .id("loader")
                        }

                        // Escalation + quick-reply suggestions
                        if viewModel.canEscalateToSmartModel {
                            smartChip
                                .id("smart_chip")
                                .transition(.opacity)
                        }

                        if !viewModel.suggestions.isEmpty {
                            suggestionChips
                                .id("suggestions")
                                .transition(.opacity)
                        }

                        Color.clear.frame(height: 80)
                            .id("bottom_anchor")
                    }
                    .padding(.top, 4)
                }
                .onChange(of: viewModel.messages.count) {
                    guard let lastMsg = viewModel.messages.last else { return }

                    DispatchQueue.main.async {
                        let scroll = {
                            if lastMsg.role == .model {
                                proxy.scrollTo(lastMsg.id, anchor: .top)
                            } else {
                                proxy.scrollTo("bottom_anchor", anchor: .bottom)
                            }
                        }
                        if reduceMotion {
                            scroll()
                        } else {
                            withAnimation(.spring(response: 0.3, dampingFraction: 1.0)) {
                                scroll()
                            }
                        }
                    }

                    viewModel.scheduleUpdate(onUpdate)
                }
                .onChange(of: viewModel.suggestions) {
                    guard !viewModel.suggestions.isEmpty else { return }
                    DispatchQueue.main.async {
                        let scroll = {
                            if let lastMsg = viewModel.messages.last, lastMsg.role == .model {
                                proxy.scrollTo(lastMsg.id, anchor: .top)
                            } else {
                                proxy.scrollTo("bottom_anchor", anchor: .bottom)
                            }
                        }
                        if reduceMotion {
                            scroll()
                        } else {
                            withAnimation(.spring(response: 0.3, dampingFraction: 1.0)) {
                                scroll()
                            }
                        }
                    }
                }
            }

            // MARK: - Input Bar
            inputBar

            // MARK: - Error
            if let error = viewModel.errorMessage {
                errorBanner(error)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: viewModel.errorMessage)
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
                        viewModel.resetChat()
                        onUpdate?()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.caption)
                    }
                    .accessibilityLabel("New chat")
                }
            }
        }
        .onAppear {
            viewModel.configure(settingsStore: settingsStore)
            // Load once. Re-appearing (returning from a sheet, or after the
            // "+" button started a different conversation) must not reload over
            // live state — and must never re-send the handed-over follow-up.
            guard !didLoad else { return }
            didLoad = true
            viewModel.loadConversation(id: conversationId)
            if let initialMessage, !initialMessage.isEmpty {
                viewModel.sendMessage(initialMessage)
            }
        }
        .ignoresSafeArea(edges: .bottom)
    }

    // MARK: - Empty State

    private static let examplePrompts = [
        "Explain a concept",
        "Summarize this idea",
        "Translate to Spanish",
        "Help me decide",
    ]

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer().frame(height: 14)
            GeminiSpark(size: 22)
            Text("Ask Gemini anything")
                .font(.caption2)
                .foregroundStyle(.secondary)

            VStack(spacing: 4) {
                ForEach(Self.examplePrompts, id: \.self) { prompt in
                    Button {
                        inputText = prompt
                        isInputFocused = true
                        if settingsStore.settings.hapticsEnabled {
                            WKInterfaceDevice.current().play(.click)
                        }
                    } label: {
                        Text(prompt)
                            .font(.system(size: 10, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.white.opacity(0.08))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)
            .padding(.horizontal, 4)

            Spacer().frame(height: 14)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Smart Escalation Chip

    /// Re-runs the whole conversation through the smarter model. Sits above the
    /// quick replies because it acts on the answer you just read.
    private var smartChip: some View {
        Button {
            if settingsStore.settings.hapticsEnabled {
                WKInterfaceDevice.current().play(.click)
            }
            viewModel.escalateToSmartModel()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "sparkle")
                    .font(.system(size: 9))
                Text("Smart · \(viewModel.smartModelLabel)")
                    .font(.system(size: 10, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.1))
            .clipShape(Capsule())
            .overlay(
                Capsule().strokeBorder(GeminiBrand.gradient, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Re-ask the smarter model, \(viewModel.smartModelLabel)")
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    // MARK: - Suggestion Chips

    private var suggestionChips: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(viewModel.suggestions, id: \.self) { suggestion in
                Button {
                    viewModel.sendMessage(suggestion)
                    if settingsStore.settings.hapticsEnabled {
                        WKInterfaceDevice.current().play(.click)
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
        .padding(.horizontal, 4)
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        TextField(viewModel.editingMessageId == nil ? "Ask Gemini…" : "Editing…", text: $inputText)
            .textFieldStyle(.plain)
            .buttonStyle(.plain)
            .font(.caption2)
            .frame(height: 28)
            .focused($isInputFocused)
            .handGestureShortcut(.primaryAction)
            .onSubmit {
                sendOrEdit()
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 14)
            .background(.ultraThinMaterial)
            .clipShape(ContainerRelativeShape())
            .ignoresSafeArea(edges: .bottom)
    }

    // MARK: - Error Banner

    private func errorBanner(_ error: String) -> some View {
        VStack(spacing: 6) {
            Text(error)
                .font(.system(size: 9))
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)

            Button("Retry") {
                viewModel.retry()
            }
            .font(.system(size: 10, weight: .medium))
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.mini)
        }
        .padding(6)
        .frame(maxWidth: .infinity)
        .background(Color.red.opacity(0.1))
        .cornerRadius(6)
        .padding(.horizontal, 6)
        .padding(.bottom, 46)
        .transition(.opacity)
    }

    // MARK: - Actions

    private func sendOrEdit() {
        let trimmedText = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        if let id = viewModel.editingMessageId {
            viewModel.editMessage(id: id, newText: trimmedText)
            viewModel.editingMessageId = nil
        } else {
            viewModel.sendMessage(trimmedText)
        }
        if settingsStore.settings.hapticsEnabled {
            WKInterfaceDevice.current().play(.click)
        }
        inputText = ""
    }
}
