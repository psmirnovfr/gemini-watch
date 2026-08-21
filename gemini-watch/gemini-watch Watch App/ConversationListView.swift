import SwiftUI

struct ConversationListView: View {
    @State private var conversations: [ConversationMetadata] = []
    @State private var activeConversation: ConversationMetadata?
    @State private var showSettings = false
    @State private var searchText = ""
    /// Follow-up handed over from Quick Ask, sent once the chat opens.
    @State private var pendingFollowUp: String?

    @EnvironmentObject private var settingsStore: AppSettingsStore
    @ObservedObject private var quickAsk = QuickAskRouter.shared

    private let persistence = PersistenceManager.shared
    private let geminiService = GeminiService()

    var filteredConversations: [ConversationMetadata] {
        guard !searchText.isEmpty else { return conversations }
        return conversations.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if conversations.isEmpty {
                    emptyState
                } else if filteredConversations.isEmpty {
                    searchEmptyState
                } else {
                    conversationList
                }
            }
            .navigationTitle("Gemini")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        startNewChat()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.caption)
                    }
                    .accessibilityLabel("New chat")
                }
            }
            .searchable(text: $searchText, prompt: "Search") // (#13)
            .navigationDestination(item: $activeConversation) { metadata in
                ContentView(
                    conversationId: metadata.id,
                    initialMessage: pendingFollowUp,
                    onUpdate: refreshList
                )
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(geminiService: geminiService, onClearAll: {
                    conversations = []
                })
            }
            .onAppear {
                refreshList()
                quickAsk.consumePendingIfNeeded()
            }
        }
        // Action-button asks take over the whole screen — a press should land
        // on the answer, not on whatever was last open.
        .fullScreenCover(item: $quickAsk.request) { request in
            NavigationStack {
                QuickAskView(
                    request: request,
                    onContinue: openFromQuickAsk,
                    onDismiss: {
                        quickAsk.clear()
                        refreshList()
                    }
                )
            }
            .id(request.id)
        }
    }

    /// Leaves Quick Ask and pushes the same conversation in the full chat UI.
    private func openFromQuickAsk(conversationId: UUID, followUp: String?) {
        let metadata = persistence.loadConversationsMetadata()
            .first(where: { $0.id == conversationId })
            ?? ConversationMetadata(
                id: conversationId,
                title: "New Chat",
                createdAt: Date(),
                updatedAt: Date()
            )

        pendingFollowUp = followUp
        quickAsk.clear()
        refreshList()

        // Dismissing the cover and pushing in the same tick can drop the push,
        // so let the cover finish tearing down first.
        DispatchQueue.main.async {
            activeConversation = metadata
        }
    }

    // MARK: - Subviews

    private var emptyState: some View {
        VStack(spacing: 8) {
            GeminiSpark(size: 28)
            Text("No Chats Yet")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(settingsStore.settings.modelName.shortModelLabel)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
            Button {
                startNewChat()
            } label: {
                Label("New Chat", systemImage: "plus")
                    .font(.caption2)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var conversationList: some View {
        List {
            ForEach(filteredConversations) { convo in
                Button {
                    pendingFollowUp = nil
                    activeConversation = convo
                } label: {
                    HStack(spacing: 4) {
                        if convo.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.yellow)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(convo.title)
                                .font(.caption)
                                .fontWeight(.medium)
                                .lineLimit(1)
                            Text(convo.updatedAt.relativeString)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 2)
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                // Swipe actions: pin/unpin (#9)
                .swipeActions(edge: .leading) {
                    Button {
                        togglePin(convo)
                    } label: {
                        Label(convo.isPinned ? "Unpin" : "Pin", systemImage: convo.isPinned ? "pin.slash" : "pin")
                    }
                    .tint(.yellow)
                }
            }
            .onDelete(perform: deleteConversations)
        }
        .listStyle(.plain)
    }

    private var searchEmptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("No Matches")
                .font(.caption)
                .fontWeight(.semibold)
            Text("Try another search")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func startNewChat() {
        pendingFollowUp = nil
        let newConvo = Conversation()
        persistence.saveConversation(newConvo)
        activeConversation = ConversationMetadata(
            id: newConvo.id,
            title: newConvo.title,
            createdAt: newConvo.createdAt,
            updatedAt: newConvo.updatedAt,
            isPinned: false
        )
        refreshList()
    }

    private func refreshList() {
        conversations = persistence.loadConversationsMetadata().sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return $0.updatedAt > $1.updatedAt
        }
    }

    private func deleteConversations(at offsets: IndexSet) {
        for idx in offsets {
            persistence.deleteConversation(id: filteredConversations[idx].id)
        }
        refreshList()
    }

    private func togglePin(_ convo: ConversationMetadata) {
        var updated = convo
        updated.isPinned.toggle()
        persistence.updateMetadata(updated)
        refreshList()
    }
}

// MARK: - Relative Date Formatting

extension Date {
    /// "Just now" / "3m ago" for very-recent, then clock time for earlier-today,
    /// weekday for this week, and month/day after that. Mirrors how Google's
    /// Gemini and Messages surfaces read.
    var relativeString: String {
        let interval = -self.timeIntervalSinceNow
        if interval < 60 { return "Just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }

        let calendar = Calendar.current
        if calendar.isDateInToday(self) {
            return Date.timeFormatter.string(from: self)
        }
        if calendar.isDateInYesterday(self) {
            return "Yesterday"
        }
        if interval < 604800 {
            return Date.weekdayFormatter.string(from: self)
        }
        return Date.monthDayFormatter.string(from: self)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("j:mm")
        return f
    }()

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f
    }()

    private static let monthDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()
}
